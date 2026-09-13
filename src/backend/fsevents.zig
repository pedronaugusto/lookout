//! The Apple backend: FSEvents.
//!
//! FSEvents is the only mechanism here that recurses in the kernel. A
//! whole tree costs one stream and no descriptors, where `kqueue` costs
//! one descriptor per directory and per file; it names the entry that
//! changed, where `kqueue` says only that a directory moved; and it pairs
//! the two halves of a rename. That is why it, and not `kqueue`, is
//! `lookout.default_backend` on Apple targets.
//!
//! What it costs in exchange:
//!
//! * FSEvents delivers on a dispatch queue, which is a thread the system
//!   owns. lookout starts none of its own and never calls the caller back
//!   on it: the delivery thread appends to a fixed buffer and writes one
//!   byte to a pipe, and everything else happens on the thread that calls
//!   `lookout.Watcher.poll`. `lookout.Watcher.fd` hands out the read end of
//!   that pipe, so a program with a wait loop of its own still works.
//! * FSEvents coalesces on its own, before lookout sees anything, over a
//!   window of `lookout.Options.latency_ms`. Several changes to one path
//!   inside that window can arrive as one event with several flags set,
//!   which is why a single delivery can produce a `created` and a
//!   `modified` for one path.
//! * It is not a queue of facts but a report of what changed, so it can
//!   say "I lost track, look again": `kFSEventStreamEventFlagMustScanSubDirs`
//!   and the two dropped-event flags all become `lookout.Kind.overflow`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const posix = std.posix;

const lookout = @import("../lookout.zig");
const Batch = @import("../Batch.zig");
const WatchId = lookout.WatchId;

const FsEvents = @This();

gpa: Allocator,
io: Io,
/// The serial queue every stream delivers on.
queue: c.dispatch_queue_t,
/// Shared with the delivery thread. Heap-allocated because its address is
/// handed to the streams and must outlive any reordering of this struct.
sink: *Sink,
/// One stream per watch.
streams: std.AutoArrayHashMapUnmanaged(WatchId, *Stream),
/// Scratch the drain copies the sink into, reused between polls.
staging: std.ArrayList(u8),
/// Mirrors `lookout.Options.max_dir_entries`.
max_dir_entries: usize,
/// Every path the backend believes exists, seeded by walking each watch
/// when it is added and kept current from what it reports. Keys owned
/// here.
///
/// This is the price of FSEvents' flags. They are not a sequence of
/// things that happened: FSEvents keeps them per path and does not clear
/// them, so a file created an hour ago and written now still arrives
/// with `ItemCreated` set beside `ItemModified`, and no reading of the
/// flags alone can tell a creation from a write. What can tell them
/// apart is whether lookout has seen the path before. It costs one string
/// per watched file -- still nothing against `kqueue`'s descriptor per
/// watched file, which is the comparison that matters on this platform.
known: std.StringArrayHashMapUnmanaged(void),
/// How many entries each directory lookout has been told about holds,
/// counted the first time it is mentioned and kept current afterwards.
/// Keys are owned here.
///
/// FSEvents needs no listing to name what changed, so this exists for one
/// reason: `lookout.Options.max_dir_entries` is a budget the caller set,
/// and a directory past it must say `lookout.Kind.overflow` here exactly
/// as it does on the backends that compare listings.
counts: std.StringArrayHashMapUnmanaged(usize),

/// How much of a delivery burst the watcher can hold between polls.
/// Past this the delivery thread stops copying and raises `overflowed`,
/// which the drain turns into `lookout.Kind.overflow`: losing a name is
/// recoverable, blocking the delivery thread is not.
const sink_buffer_len = 64 * 1024;

/// The lock between the delivery thread and the polling one.
///
/// A spin lock rather than `std.Io.Mutex`, which needs an `Io` to block
/// on and cannot be taken from a system callback that has none. Both
/// critical sections are a bounded `memcpy` and nothing else -- no
/// syscall, no allocation, no lookout logic -- so there is nothing to wait
/// through.
const SpinLock = struct {
    held: std.atomic.Value(bool) = .init(false),

    fn acquire(l: *SpinLock) void {
        while (l.held.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    fn release(l: *SpinLock) void {
        l.held.store(false, .release);
    }
};

/// What the delivery thread writes and `drain` reads.
///
/// Deliberately a byte buffer and not a list of allocations: the thread
/// filling it is not lookout's, and a backend that allocates there would
/// be holding a general-purpose allocator's lock inside a system
/// callback.
const Sink = struct {
    lock: SpinLock,
    buffer: [sink_buffer_len]u8,
    len: usize,
    /// Set when a delivery did not fit. Cleared by the drain that reports
    /// it.
    overflowed: bool,
    /// Read end, handed out by `fd`. Non-blocking.
    wake_r: posix.fd_t,
    /// Write end, poked once per delivery. Non-blocking, so a full pipe
    /// costs nothing: one byte pending is as good as a thousand.
    wake_w: posix.fd_t,

    /// Record layout: watch id, flags, path length, path. Read back with
    /// unaligned loads, because the path lengths do not align.
    const header_len = 12;

    fn append(s: *Sink, id: WatchId, flags: u32, path: []const u8) void {
        if (s.len + header_len + path.len > s.buffer.len) {
            s.overflowed = true;
            return;
        }
        std.mem.writeInt(u32, s.buffer[s.len..][0..4], @intFromEnum(id), .little);
        std.mem.writeInt(u32, s.buffer[s.len + 4 ..][0..4], flags, .little);
        std.mem.writeInt(u32, s.buffer[s.len + 8 ..][0..4], @intCast(path.len), .little);
        @memcpy(s.buffer[s.len + header_len ..][0..path.len], path);
        s.len += header_len + path.len;
    }

    fn signal(s: *Sink) void {
        const byte: [1]u8 = .{0};
        _ = std.c.write(s.wake_w, &byte, 1);
    }
};

/// One watch: one FSEvents stream, and what the caller asked it to mean.
const Stream = struct {
    id: WatchId,
    sink: *Sink,
    ref: c.FSEventStreamRef,
    /// The path the caller named, absolute and canonical.
    root: []u8,
    /// Which paths under the stream's own root this watch is about.
    /// FSEvents is always recursive, so a narrower watch is a filter.
    scope: Scope,

    const Scope = enum {
        /// Everything under `root`.
        tree,
        /// `root` and its immediate entries.
        directory,
        /// Only `root` itself. The stream is created on the parent
        /// directory, because FSEvents watches directories.
        file,
    };

    fn wants(st: *const Stream, path: []const u8) bool {
        if (!std.mem.startsWith(u8, path, st.root)) return false;
        if (path.len == st.root.len) return true;
        if (st.scope == .file) return false;
        if (path[st.root.len] != std.fs.path.sep) return false;
        if (st.scope == .tree) return true;
        return std.mem.indexOfScalar(u8, path[st.root.len + 1 ..], std.fs.path.sep) == null;
    }
};

/// Creates the delivery queue and the pipe the watcher is woken through.
pub fn init(gpa: Allocator, io: Io, options: lookout.Options) lookout.Watcher.InitError!FsEvents {
    var fds: [2]posix.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return switch (posix.errno(@as(c_int, -1))) {
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        else => error.Unexpected,
    };
    errdefer {
        _ = std.c.close(fds[0]);
        _ = std.c.close(fds[1]);
    }
    // Both ends non-blocking: the delivery thread must never block on a
    // full pipe, and the drain must never block on an empty one.
    for (fds) |end| {
        const flags = std.c.fcntl(end, c.F_GETFL, @as(c_int, 0));
        if (flags < 0) return error.Unexpected;
        if (std.c.fcntl(end, c.F_SETFL, flags | c.O_NONBLOCK) < 0) return error.Unexpected;
    }

    const sink = gpa.create(Sink) catch return error.SystemResources;
    errdefer gpa.destroy(sink);
    sink.* = .{
        .lock = .{},
        .buffer = undefined,
        .len = 0,
        .overflowed = false,
        .wake_r = fds[0],
        .wake_w = fds[1],
    };

    const queue = c.dispatch_queue_create("dev.lookout.fsevents", null) orelse
        return error.SystemResources;

    return .{
        .gpa = gpa,
        .io = io,
        .queue = queue,
        .sink = sink,
        .streams = .empty,
        .staging = .empty,
        .max_dir_entries = options.max_dir_entries,
        .known = .empty,
        .counts = .empty,
    };
}

/// Stops every stream, waits for the delivery thread to be done with
/// them, and closes the pipe.
pub fn deinit(f: *FsEvents) void {
    for (f.streams.values()) |stream| f.destroy(stream);
    f.streams.deinit(f.gpa);
    f.staging.deinit(f.gpa);
    for (f.counts.keys()) |path| f.gpa.free(path);
    f.counts.deinit(f.gpa);
    for (f.known.keys()) |path| f.gpa.free(path);
    f.known.deinit(f.gpa);
    c.dispatch_release(f.queue);
    _ = std.c.close(f.sink.wake_r);
    _ = std.c.close(f.sink.wake_w);
    f.gpa.destroy(f.sink);
    f.* = undefined;
}

/// The read end of the wake pipe. Readable when a delivery has arrived
/// that `lookout.Watcher.poll` has not drained yet.
pub fn fd(f: *const FsEvents) ?posix.fd_t {
    return f.sink.wake_r;
}

/// Registers `abs_path`, a copy of which the backend keeps.
pub fn add(f: *FsEvents, id: WatchId, abs_path: []const u8, options: lookout.AddOptions) lookout.Watcher.AddError!void {
    for (f.streams.values()) |stream| {
        if (std.mem.eql(u8, stream.root, abs_path)) return error.PathAlreadyWatched;
    }
    const stat = try Io.Dir.cwd().statFile(f.io, abs_path, .{});
    const scope: Stream.Scope = if (stat.kind != .directory)
        .file
    else if (options.recursive)
        .tree
    else
        .directory;

    // FSEvents watches directories, so a watch on a file is a stream on
    // its parent filtered down to the one name.
    const stream_path = if (scope == .file)
        std.fs.path.dirname(abs_path) orelse abs_path
    else
        abs_path;

    const stream = try f.gpa.create(Stream);
    errdefer f.gpa.destroy(stream);
    const root = try f.gpa.dupe(u8, abs_path);
    errdefer f.gpa.free(root);
    stream.* = .{ .id = id, .sink = f.sink, .ref = undefined, .root = root, .scope = scope };

    stream.ref = try createStream(stream, stream_path, f.io);
    errdefer {
        c.FSEventStreamSetDispatchQueue(stream.ref, null);
        c.FSEventStreamInvalidate(stream.ref);
        c.FSEventStreamRelease(stream.ref);
    }
    c.FSEventStreamSetDispatchQueue(stream.ref, f.queue);
    if (c.FSEventStreamStart(stream.ref) == 0) return error.WatchLimitReached;

    try f.streams.put(f.gpa, id, stream);
    if (scope != .file) f.seedCount(abs_path) catch {};
    f.seedKnown(stream) catch {};
}

/// Builds the CoreFoundation array FSEvents wants and creates the stream.
fn createStream(stream: *Stream, path: []const u8, io: Io) lookout.Watcher.AddError!c.FSEventStreamRef {
    _ = io;
    const cf_path = c.CFStringCreateWithBytes(
        null,
        path.ptr,
        @intCast(path.len),
        c.kCFStringEncodingUTF8,
        0,
    ) orelse return error.SystemResources;
    defer c.CFRelease(cf_path);

    const values: [1]?*const anyopaque = .{cf_path};
    const paths = c.CFArrayCreate(null, &values, 1, &c.kCFTypeArrayCallBacks) orelse
        return error.SystemResources;
    defer c.CFRelease(paths);

    var context: c.FSEventStreamContext = .{ .info = stream };
    // `kFSEventStreamCreateFlagFileEvents` is what makes FSEvents name
    // files rather than only the directories containing them.
    // `NoDefer` makes the first event of a burst arrive at once rather
    // than after the latency window, which is what a caller expects from
    // something that already has its own coalescing. `WatchRoot` is what
    // reports the watched path itself being moved.
    const flags: u32 = c.kFSEventStreamCreateFlagFileEvents |
        c.kFSEventStreamCreateFlagNoDefer |
        c.kFSEventStreamCreateFlagWatchRoot;
    // The latency here is FSEvents' own coalescing window. lookout keeps it
    // short and does its own in `Batch`, so that every backend coalesces
    // by the same rule rather than by whichever one the kernel has.
    return c.FSEventStreamCreate(null, deliver, &context, paths, c.kFSEventStreamEventIdSinceNow, 0.01, flags) orelse
        error.SystemResources;
}

/// Stops watching `id`.
pub fn remove(f: *FsEvents, id: WatchId) void {
    const entry = f.streams.fetchSwapRemove(id) orelse return;
    f.destroy(entry.value);
}

fn destroy(f: *FsEvents, stream: *Stream) void {
    c.FSEventStreamStop(stream.ref);
    // Detaching the queue is what waits for a delivery already in flight;
    // without it `stream` could be freed under the thread reading it.
    c.FSEventStreamSetDispatchQueue(stream.ref, null);
    c.FSEventStreamInvalidate(stream.ref);
    c.FSEventStreamRelease(stream.ref);
    f.gpa.free(stream.root);
    f.gpa.destroy(stream);
}

/// What FSEvents calls on the dispatch queue. Copies and gets out: no
/// allocation, no parsing, no lookout logic on a thread lookout does not
/// own.
fn deliver(
    ref: c.FSEventStreamRef,
    info: ?*anyopaque,
    count: usize,
    paths: ?*anyopaque,
    flags: [*]const u32,
    ids: [*]const u64,
) callconv(.c) void {
    _ = ref;
    _ = ids;
    const stream: *Stream = @ptrCast(@alignCast(info.?));
    const list: [*]const [*:0]const u8 = @ptrCast(@alignCast(paths.?));

    stream.sink.lock.acquire();
    defer stream.sink.lock.release();
    for (0..count) |i| stream.sink.append(stream.id, flags[i], std.mem.span(list[i]));
    stream.sink.signal();
}

/// Waits on the wake pipe until the drain produces something `batch` did
/// not already hold, or `timeout_ms` expires. `null` never gives up.
pub fn wait(f: *FsEvents, batch: *Batch, timeout_ms: ?u32) lookout.Watcher.PollError!void {
    const before = batch.events.items.len;
    const started: Io.Timestamp = .now(f.io, .awake);

    while (true) {
        try f.drain(batch);
        if (batch.events.items.len > before) return;

        // Clamped rather than returned on, so that a `timeout_ms` of zero
        // still performs one non-blocking check.
        const timeout: i32 = timeout: {
            const total = timeout_ms orelse break :timeout -1;
            const elapsed = started.durationTo(Io.Timestamp.now(f.io, .awake)).toMilliseconds();
            break :timeout @intCast(@max(0, @as(i64, total) - elapsed));
        };
        var fds: [1]posix.pollfd = .{.{ .fd = f.sink.wake_r, .events = posix.POLL.IN, .revents = 0 }};
        const ready = posix.poll(&fds, timeout) catch |err| switch (err) {
            error.SystemResources => return error.SystemResources,
            else => return error.Unexpected,
        };
        if (ready == 0) return;

        var scratch: [256]u8 = undefined;
        while (std.c.read(f.sink.wake_r, &scratch, scratch.len) > 0) {}
    }
}

/// Takes everything the delivery thread has left and turns it into
/// events.
fn drain(f: *FsEvents, batch: *Batch) lookout.Watcher.PollError!void {
    f.staging.clearRetainingCapacity();
    var overflowed = false;
    {
        f.sink.lock.acquire();
        defer f.sink.lock.release();
        overflowed = f.sink.overflowed;
        f.sink.overflowed = false;
        f.staging.appendSlice(f.gpa, f.sink.buffer[0..f.sink.len]) catch {
            // The buffer stays where it is: a drain that cannot allocate
            // reports the loss and tries again next time rather than
            // throwing the delivery away.
            f.sink.overflowed = overflowed;
            return error.OutOfMemory;
        };
        f.sink.len = 0;
    }
    if (overflowed) {
        for (f.streams.values()) |stream| {
            try batch.push(f.gpa, stream.id, stream.root, .overflow);
        }
    }

    var records: std.ArrayList(Record) = .empty;
    defer records.deinit(f.gpa);
    var offset: usize = 0;
    while (offset + Sink.header_len <= f.staging.items.len) {
        const bytes = f.staging.items;
        const id: WatchId = @enumFromInt(std.mem.readInt(u32, bytes[offset..][0..4], .little));
        const flags = std.mem.readInt(u32, bytes[offset + 4 ..][0..4], .little);
        const len = std.mem.readInt(u32, bytes[offset + 8 ..][0..4], .little);
        offset += Sink.header_len;
        if (offset + len > bytes.len) break;
        try records.append(f.gpa, .{ .id = id, .flags = flags, .path = bytes[offset..][0..len] });
        offset += len;
    }

    var i: usize = 0;
    while (i < records.items.len) : (i += 1) {
        i += try f.report(batch, records.items[i..]);
    }
}

/// One delivered change, still pointing into `staging`.
const Record = struct {
    id: WatchId,
    flags: u32,
    path: []const u8,
};

/// Reports `run[0]`, and returns how many further records it consumed --
/// one, when it paired the two halves of a rename.
///
/// The flags are not a sequence of things that happened. FSEvents keeps
/// them per path and does not clear them, so a file created an hour ago
/// and written now still arrives with `ItemCreated` set alongside
/// `ItemModified`. What resolves them is the file: whether it is there,
/// and how old it is. A path that is gone was removed; a path younger
/// than the window being reported was created in it; anything else that
/// is still there was modified.
fn report(f: *FsEvents, batch: *Batch, run: []const Record) lookout.Watcher.PollError!usize {
    const record = run[0];
    const stream = f.streams.get(record.id) orelse return 0;
    if (!stream.wants(record.path)) return 0;

    if (record.flags & (c.kFSEventStreamEventFlagMustScanSubDirs |
        c.kFSEventStreamEventFlagUserDropped |
        c.kFSEventStreamEventFlagKernelDropped) != 0)
    {
        try batch.push(f.gpa, record.id, stream.root, .overflow);
    }
    // The watched path itself moved or vanished. FSEvents reports this
    // against the root rather than as an item event, and keeps watching
    // the inode; lookout reports it and lets the caller decide.
    if (record.flags & c.kFSEventStreamEventFlagRootChanged != 0) {
        try batch.push(f.gpa, record.id, stream.root, .renamed);
        return 0;
    }

    if (record.flags & c.kFSEventStreamEventFlagItemRenamed != 0) {
        const consumed = try f.reportRename(batch, run, stream);
        if (consumed != 0) {
            try f.recount(batch, record, stream);
            return consumed;
        }
    }

    const there = f.exists(record.path);
    const seen = f.known.contains(record.path);

    if (!there) {
        // Gone. Whatever the flags remember about it, the fact now is
        // that the path is not there. A path lookout never knew about came
        // and went between two polls, and the tree is as it was.
        if (seen) {
            try batch.push(f.gpa, record.id, record.path, .removed);
            f.forget(record.path);
            try f.recount(batch, record, stream);
        }
        return 0;
    }
    if (!seen) {
        try batch.push(f.gpa, record.id, record.path, .created);
        try f.remember(record.path);
        try f.recount(batch, record, stream);
        return 0;
    }
    if (record.flags & c.kFSEventStreamEventFlagItemModified != 0) {
        try batch.push(f.gpa, record.id, record.path, .modified);
    } else if (record.flags & (c.kFSEventStreamEventFlagItemInodeMetaMod |
        c.kFSEventStreamEventFlagItemChangeOwner |
        c.kFSEventStreamEventFlagItemXattrMod |
        c.kFSEventStreamEventFlagItemFinderInfoMod) != 0)
    {
        try batch.push(f.gpa, record.id, record.path, .attributes);
    }
    try f.recount(batch, record, stream);
    return 0;
}

/// Records that a path exists.
fn remember(f: *FsEvents, path: []const u8) Allocator.Error!void {
    if (f.known.contains(path)) return;
    const owned = try f.gpa.dupe(u8, path);
    errdefer f.gpa.free(owned);
    try f.known.put(f.gpa, owned, {});
}

/// Records that a path does not.
fn forget(f: *FsEvents, path: []const u8) void {
    if (f.known.fetchSwapRemove(path)) |entry| f.gpa.free(entry.key);
}

/// Walks a watch once, so that everything already there is known and the
/// first thing to happen to it is not reported as its creation.
///
/// Listing only: no descriptor is kept, which is the difference between
/// this and what the `kqueue` backend has to do.
fn seedKnown(f: *FsEvents, stream: *const Stream) Allocator.Error!void {
    if (stream.scope == .file) {
        if (f.exists(stream.root)) try f.remember(stream.root);
        return;
    }
    var frontier: std.ArrayList([]u8) = .empty;
    defer {
        for (frontier.items) |path| f.gpa.free(path);
        frontier.deinit(f.gpa);
    }
    try frontier.append(f.gpa, try f.gpa.dupe(u8, stream.root));

    var i: usize = 0;
    while (i < frontier.items.len) : (i += 1) {
        var dir = Io.Dir.openDirAbsolute(f.io, frontier.items[i], .{ .iterate = true }) catch continue;
        defer dir.close(f.io);
        var it = dir.iterate();
        var seen: usize = 0;
        while (it.next(f.io) catch null) |entry| {
            if (seen >= f.max_dir_entries) break;
            seen += 1;
            const child = try std.fs.path.join(f.gpa, &.{ frontier.items[i], entry.name });
            errdefer f.gpa.free(child);
            try f.remember(child);
            if (entry.kind == .directory and stream.scope == .tree) {
                try frontier.append(f.gpa, child);
            } else {
                f.gpa.free(child);
            }
        }
    }
}

/// The flags that say something happened to the item rather than to the
/// stream.
const itemChangeFlags: u32 = c.kFSEventStreamEventFlagItemCreated |
    c.kFSEventStreamEventFlagItemRemoved |
    c.kFSEventStreamEventFlagItemRenamed |
    c.kFSEventStreamEventFlagItemModified;

/// Pairs the two halves of a rename.
///
/// FSEvents reports a rename as two `ItemRenamed` events in one delivery,
/// one for each name, and does not say which is which. The one that no
/// longer exists is the name it came from -- the inode moved, so exactly
/// one of the two paths resolves. When that test does not settle it --
/// the file was renamed and then deleted, or renamed out of the watch --
/// there is nothing to pair, and the caller gets the removal and the
/// creation the other backends would have given.
fn reportRename(f: *FsEvents, batch: *Batch, run: []const Record, stream: *const Stream) lookout.Watcher.PollError!usize {
    if (run.len < 2) return 0;
    const next = run[1];
    if (next.id != run[0].id) return 0;
    if (next.flags & c.kFSEventStreamEventFlagItemRenamed == 0) return 0;
    if (!stream.wants(next.path)) return 0;

    const first_exists = f.exists(run[0].path);
    const second_exists = f.exists(next.path);
    if (first_exists == second_exists) return 0;

    if (second_exists) {
        try batch.pushRename(f.gpa, run[0].id, next.path, run[0].path);
        f.forget(run[0].path);
        try f.remember(next.path);
    } else {
        try batch.pushRename(f.gpa, run[0].id, run[0].path, next.path);
        f.forget(next.path);
        try f.remember(run[0].path);
    }
    return 1;
}

fn exists(f: *const FsEvents, path: []const u8) bool {
    _ = Io.Dir.cwd().statFile(f.io, path, .{ .follow_symlinks = false }) catch return false;
    return true;
}

/// Keeps the entry budget of the directory a change happened in, and
/// reports `lookout.Kind.overflow` when it is past.
fn recount(f: *FsEvents, batch: *Batch, record: Record, stream: *const Stream) lookout.Watcher.PollError!void {
    const appeared = record.flags & c.kFSEventStreamEventFlagItemCreated != 0;
    const vanished = record.flags & c.kFSEventStreamEventFlagItemRemoved != 0;
    const renamed = record.flags & c.kFSEventStreamEventFlagItemRenamed != 0;
    if (!appeared and !vanished and !renamed) return;

    const parent = std.fs.path.dirname(record.path) orelse return;
    const gop = f.counts.getOrPut(f.gpa, parent) catch return error.OutOfMemory;
    if (!gop.found_existing) {
        const owned = f.gpa.dupe(u8, parent) catch {
            _ = f.counts.swapRemove(parent);
            return error.OutOfMemory;
        };
        gop.key_ptr.* = owned;
        gop.value_ptr.* = f.countEntries(parent);
    } else if (appeared) {
        gop.value_ptr.* += 1;
    } else if (vanished) {
        gop.value_ptr.* -|= 1;
    }
    if (gop.value_ptr.* > f.max_dir_entries) {
        try batch.push(f.gpa, record.id, stream.root, .overflow);
    }
}

/// Seeds the budget for a directory the caller just asked to watch, so
/// that one that is already too big says so at the first sign of life.
fn seedCount(f: *FsEvents, path: []const u8) Allocator.Error!void {
    if (f.counts.contains(path)) return;
    const owned = try f.gpa.dupe(u8, path);
    errdefer f.gpa.free(owned);
    try f.counts.put(f.gpa, owned, f.countEntries(path));
}

fn countEntries(f: *FsEvents, path: []const u8) usize {
    var dir = Io.Dir.openDirAbsolute(f.io, path, .{ .iterate = true }) catch return 0;
    defer dir.close(f.io);
    var it = dir.iterate();
    var count: usize = 0;
    while (it.next(f.io) catch null) |_| count += 1;
    return count;
}

/// The CoreFoundation, CoreServices and libdispatch surface lookout uses.
///
/// Hand-written rather than `@cImport`ed: this is nine functions and a
/// handful of constants against a stable system ABI, and declaring them
/// here keeps the package free of a C compilation step.
const c = struct {
    const CFAllocatorRef = ?*anyopaque;
    const CFStringRef = *anyopaque;
    const CFArrayRef = *anyopaque;
    const FSEventStreamRef = *anyopaque;
    const dispatch_queue_t = *anyopaque;

    const kCFStringEncodingUTF8: u32 = 0x0800_0100;
    const kFSEventStreamEventIdSinceNow: u64 = 0xFFFF_FFFF_FFFF_FFFF;

    const kFSEventStreamCreateFlagNoDefer: u32 = 0x00000002;
    const kFSEventStreamCreateFlagWatchRoot: u32 = 0x00000004;
    const kFSEventStreamCreateFlagFileEvents: u32 = 0x00000010;

    const kFSEventStreamEventFlagMustScanSubDirs: u32 = 0x00000001;
    const kFSEventStreamEventFlagUserDropped: u32 = 0x00000002;
    const kFSEventStreamEventFlagKernelDropped: u32 = 0x00000004;
    const kFSEventStreamEventFlagRootChanged: u32 = 0x00000020;
    const kFSEventStreamEventFlagItemCreated: u32 = 0x00000100;
    const kFSEventStreamEventFlagItemRemoved: u32 = 0x00000200;
    const kFSEventStreamEventFlagItemInodeMetaMod: u32 = 0x00000400;
    const kFSEventStreamEventFlagItemRenamed: u32 = 0x00000800;
    const kFSEventStreamEventFlagItemModified: u32 = 0x00001000;
    const kFSEventStreamEventFlagItemFinderInfoMod: u32 = 0x00002000;
    const kFSEventStreamEventFlagItemChangeOwner: u32 = 0x00004000;
    const kFSEventStreamEventFlagItemXattrMod: u32 = 0x00008000;

    const F_GETFL: c_int = 3;
    const F_SETFL: c_int = 4;
    const O_NONBLOCK: c_int = 0x0004;

    const FSEventStreamContext = extern struct {
        version: c_long = 0,
        info: ?*anyopaque = null,
        retain: ?*const anyopaque = null,
        release: ?*const anyopaque = null,
        copyDescription: ?*const anyopaque = null,
    };

    const FSEventStreamCallback = *const fn (
        stream: FSEventStreamRef,
        info: ?*anyopaque,
        num_events: usize,
        event_paths: ?*anyopaque,
        event_flags: [*]const u32,
        event_ids: [*]const u64,
    ) callconv(.c) void;

    extern var kCFTypeArrayCallBacks: anyopaque;

    extern "c" fn CFStringCreateWithBytes(
        alloc: CFAllocatorRef,
        bytes: [*]const u8,
        num_bytes: c_long,
        encoding: u32,
        is_external_representation: u8,
    ) ?CFStringRef;
    extern "c" fn CFArrayCreate(
        allocator: CFAllocatorRef,
        values: [*]const ?*const anyopaque,
        num_values: c_long,
        call_backs: ?*const anyopaque,
    ) ?CFArrayRef;
    extern "c" fn CFRelease(cf: *anyopaque) void;

    extern "c" fn FSEventStreamCreate(
        allocator: CFAllocatorRef,
        callback: FSEventStreamCallback,
        context: ?*FSEventStreamContext,
        paths_to_watch: CFArrayRef,
        since_when: u64,
        latency: f64,
        flags: u32,
    ) ?FSEventStreamRef;
    extern "c" fn FSEventStreamSetDispatchQueue(stream: FSEventStreamRef, q: ?dispatch_queue_t) void;
    extern "c" fn FSEventStreamStart(stream: FSEventStreamRef) u8;
    extern "c" fn FSEventStreamStop(stream: FSEventStreamRef) void;
    extern "c" fn FSEventStreamInvalidate(stream: FSEventStreamRef) void;
    extern "c" fn FSEventStreamRelease(stream: FSEventStreamRef) void;

    extern "c" fn dispatch_queue_create(label: ?[*:0]const u8, attr: ?*anyopaque) ?dispatch_queue_t;
    extern "c" fn dispatch_release(object: *anyopaque) void;
};
