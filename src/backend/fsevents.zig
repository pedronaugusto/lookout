//! The Apple backend: FSEvents.
//!
//! FSEvents is the only mechanism here that recurses in the kernel. A
//! whole tree costs one stream and no descriptors, where `kqueue` costs
//! one descriptor per directory and per file; it names the entry that
//! changed, where `kqueue` says only that a directory moved; it pairs
//! the two halves of a rename; and it is the only one of the five that
//! can say what happened before the watch existed, which is
//! `lookout.Options.since`. That is why it, and not `kqueue`, is
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
//!   How much that buffer holds is `lookout.Options.buffer_bytes`.
//! * FSEvents coalesces on its own, before lookout sees anything, over a
//!   window of about ten milliseconds. Several changes to one path
//!   inside that window can arrive as one event with several flags set,
//!   which is why a single delivery can produce a `created` and a
//!   `modified` for one path. It is also a floor under
//!   `lookout.Options.latency_ms` that cannot be lowered.
//! * It is not a queue of facts but a report of what changed, so it can
//!   say "I lost track, look again": `kFSEventStreamEventFlagMustScanSubDirs`
//!   and the two dropped-event flags all become `lookout.Kind.overflow`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const posix = std.posix;

const lookout = @import("../lookout.zig");
const Batch = @import("../Batch.zig");
const Budget = @import("../Budget.zig");
const Deadline = @import("../Deadline.zig");
const Filter = @import("../Filter.zig");
const buffer = @import("../buffer.zig");
const path_cmp = @import("../path.zig");
const trace = @import("../trace.zig");
const walk = @import("../walk.zig");
const Target = lookout.Target;
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
/// How many entries each watched directory holds, against
/// `lookout.Options.max_dir_entries`.
budget: Budget,
/// Where every stream is started from: `since_now`, or the event id a
/// caller kept from an earlier watcher. See `lookout.Options.since`.
since: u64,
/// Every path the backend believes exists, seeded by walking each watch
/// when it is added and kept current from what it reports. Keys owned
/// here, and compared the way the file system compares them.
///
/// This is the price of FSEvents' flags. They are not a sequence of
/// things that happened: FSEvents keeps them per path and does not clear
/// them, so a file created an hour ago and written now still arrives
/// with `ItemCreated` set beside `ItemModified`, and no reading of the
/// flags alone can tell a creation from a write. What can tell them
/// apart is whether lookout has seen the path before. It costs one string
/// per watched file -- still nothing against `kqueue`'s descriptor per
/// watched file, which is the comparison that matters on this platform.
known: path_cmp.Set(void),
/// The half of a rename whose partner has not been delivered yet.
///
/// FSEvents reports a rename as two `ItemRenamed` records and usually
/// puts both in one delivery, but "usually" is not "always": a burst
/// long enough splits a pair across two. A half is therefore held until
/// the whole wait is over rather than until the end of its own delivery,
/// because deciding early turns one `renamed` into a removal and a
/// creation on a backend that says it pairs them.
held: ?Half,

/// One `ItemRenamed` record waiting for its partner.
const Half = struct {
    id: WatchId,
    /// Absolute path, owned by the backend.
    path: []u8,
    flags: u32,
};

/// FSEvents' own coalescing window, in seconds. Kept short because
/// lookout does its own coalescing in `Batch`, so that every backend
/// coalesces by one rule rather than by whichever one the kernel has.
const stream_latency: f64 = 0.01;

/// What `lookout.Options.buffer_bytes` may ask for here.
///
/// The default holds a burst of ten thousand paths without losing one:
/// a record is a twenty-byte header and the path, so four megabytes is
/// room for ten thousand paths of nearly four hundred bytes each. It is
/// memory held for the life of the watcher, which is the price of the
/// delivery thread never having to allocate and never having to wait.
const bounds: buffer.Bounds = .{
    .min = 4 * 1024,
    .max = 64 * 1024 * 1024,
    .default = 4 * 1024 * 1024,
};

/// How long a delivery whose rename is missing its partner is waited
/// for before the half is reported on its own, and how many times.
///
/// Paid only while a half is actually held, which is rare: FSEvents
/// puts both halves in one delivery unless a burst was long enough to
/// split them, and its own coalescing window is about ten milliseconds,
/// so the partner is either in the next delivery or nowhere.
const grace_ms = 25;
const grace_rounds = 4;

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
    /// Sized by `lookout.Options.buffer_bytes`, allocated once at `init`
    /// and never moved: the delivery thread writes into it.
    buffer: []u8,
    len: usize,
    /// Set when a delivery did not fit. Cleared by the drain that reports
    /// it.
    overflowed: bool,
    /// How many times the system has called `deliver`, and how many paths
    /// it brought, since the last drain. Counted rather than logged
    /// because the counting happens on a thread lookout does not own and
    /// must not write to a file from. See `trace`.
    deliveries: usize,
    /// Paths `append` had no room for since the last drain.
    dropped: usize,
    /// Set by `wake` from another thread, and cleared by the `wait` that
    /// answers it.
    woken: std.atomic.Value(bool),
    /// Read end, handed out by `fd`. Non-blocking.
    wake_r: posix.fd_t,
    /// Write end, poked once per delivery. Non-blocking, so a full pipe
    /// costs nothing: one byte pending is as good as a thousand.
    wake_w: posix.fd_t,

    /// Record layout: watch id, flags, path length, the system's event
    /// id, path. Read back with unaligned loads, because the path lengths
    /// do not align.
    const header_len = 20;

    fn append(s: *Sink, id: WatchId, flags: u32, event: u64, subject: []const u8) void {
        if (s.len + header_len + subject.len > s.buffer.len) {
            s.overflowed = true;
            s.dropped += 1;
            return;
        }
        std.mem.writeInt(u32, s.buffer[s.len..][0..4], @intFromEnum(id), .little);
        std.mem.writeInt(u32, s.buffer[s.len + 4 ..][0..4], flags, .little);
        std.mem.writeInt(u32, s.buffer[s.len + 8 ..][0..4], @intCast(subject.len), .little);
        std.mem.writeInt(u64, s.buffer[s.len + 12 ..][0..8], event, .little);
        @memcpy(s.buffer[s.len + header_len ..][0..subject.len], subject);
        s.len += header_len + subject.len;
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
    /// `lookout.AddOptions.filter`, copied.
    ///
    /// FSEvents recurses in the kernel and cannot be told to leave a
    /// directory out, so here the filter drops the events rather than
    /// saving the work -- see `lookout.prunesIgnored`.
    filter: Filter,
    /// Whether this stream is still replaying what happened before it
    /// was started, which `lookout.Options.since` asked for. Cleared by
    /// the `HistoryDone` flag.
    ///
    /// It changes what a path that is not there means. In the ordinary
    /// way, a path FSEvents names that is gone and that lookout has
    /// never seen came and went between two polls, and the tree is as
    /// it was, so there is nothing to report. During a replay the same
    /// two facts mean the opposite: the path was there at the position
    /// the caller resumed from and is not there now, which is exactly
    /// the deletion they asked to be told about.
    replaying: bool,
    /// Whether `HistoryDone` has arrived for this stream during the
    /// wait now running. The replay ends at the end of that wait rather
    /// than at the flag: the system delivers the flag as soon as it has
    /// read the log, and the changes made while nothing was watching
    /// arrive just after it, in the same wave.
    caught_up: bool,

    const Scope = enum {
        /// Everything under `root`.
        tree,
        /// `root` and its immediate entries.
        directory,
        /// Only `root` itself. The stream is created on the parent
        /// directory, because FSEvents watches directories.
        file,
    };

    fn wants(st: *const Stream, subject: []const u8) bool {
        const rest = path_cmp.relative(st.root, subject) orelse return false;
        if (rest.len == 0) return true;
        if (st.scope == .file) return false;
        if (st.scope == .tree) return true;
        return std.mem.indexOfAny(u8, rest, path_cmp.separators) == null;
    }
};

/// Creates the delivery queue, the buffer it fills, and the pipe the
/// watcher is woken through.
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
    const bytes = gpa.alloc(u8, buffer.clamp(options.buffer_bytes, bounds)) catch
        return error.SystemResources;
    errdefer gpa.free(bytes);
    sink.* = .{
        .lock = .{},
        .buffer = bytes,
        .len = 0,
        .overflowed = false,
        .deliveries = 0,
        .dropped = 0,
        .woken = .init(false),
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
        .budget = .init(gpa, io, options.max_dir_entries),
        .since = sinceOf(options.since),
        .known = .empty,
        .held = null,
    };
}

/// What to start every stream from. A position from another backend is
/// not this backend's to read, and is the same as no position at all.
fn sinceOf(asked: ?lookout.Position) u64 {
    const p = asked orelse return c.kFSEventStreamEventIdSinceNow;
    if (p.backend != .fsevents) return c.kFSEventStreamEventIdSinceNow;
    return p.value;
}

/// Stops every stream, waits for the delivery thread to be done with
/// them, and closes the pipe.
pub fn deinit(f: *FsEvents) void {
    for (f.streams.values()) |stream| f.destroy(stream);
    f.streams.deinit(f.gpa);
    f.staging.deinit(f.gpa);
    f.budget.deinit();
    for (f.known.keys()) |p| f.gpa.free(p);
    f.known.deinit(f.gpa);
    if (f.held) |half| f.gpa.free(half.path);
    c.dispatch_release(f.queue);
    _ = std.c.close(f.sink.wake_r);
    _ = std.c.close(f.sink.wake_w);
    f.gpa.free(f.sink.buffer);
    f.gpa.destroy(f.sink);
    f.* = undefined;
}

/// The read end of the wake pipe. Readable when a delivery has arrived
/// that `lookout.Watcher.poll` has not drained yet.
pub fn fd(f: *const FsEvents) ?posix.fd_t {
    return f.sink.wake_r;
}

/// The volume's current event id, which `lookout.Options.since` takes
/// back. See `lookout.Watcher.position`.
pub fn position(f: *const FsEvents) ?u64 {
    _ = f;
    return c.FSEventsGetCurrentEventId();
}

/// Pokes the pipe a blocked `wait` is polling. See
/// `lookout.Watcher.wake`.
pub fn wake(f: *FsEvents) void {
    f.sink.woken.store(true, .release);
    f.sink.signal();
}

/// How many FSEvents streams this backend holds: one per watch, because
/// the kernel recurses and a whole tree costs no more than a single path.
/// See `lookout.Watcher.Stats`.
pub fn registrationCount(f: *const FsEvents) usize {
    return f.streams.count();
}

/// Registers `abs_path`, a copy of which the backend keeps.
pub fn add(
    f: *FsEvents,
    id: WatchId,
    abs_path: []const u8,
    options: lookout.AddOptions,
    batch: *Batch,
) lookout.Watcher.AddError!void {
    // One stream covers a whole tree, so there is no per-directory
    // registration here that could fail on its own.
    _ = batch;
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

    // Room for the stream before the stream exists, so that nothing
    // between starting it and recording it can fail. What is left after
    // the start is one error path, and it is the one where the stream was
    // scheduled and never started -- which must be invalidated and
    // released, and must not be stopped.
    try f.streams.ensureUnusedCapacity(f.gpa, 1);

    const stream = try f.gpa.create(Stream);
    errdefer f.gpa.destroy(stream);
    const root = try f.gpa.dupe(u8, abs_path);
    errdefer f.gpa.free(root);
    var filter = try options.filter.dupe(f.gpa);
    errdefer filter.deinit(f.gpa);
    stream.* = .{
        .id = id,
        .sink = f.sink,
        .ref = undefined,
        .root = root,
        .scope = scope,
        .filter = filter,
        .replaying = f.since != c.kFSEventStreamEventIdSinceNow,
        .caught_up = false,
    };

    trace.log("fsevents add watch={d} scope={s} root={s} stream_path={s}", .{
        @intFromEnum(id), @tagName(scope), abs_path, stream_path,
    });
    stream.ref = try createStream(stream, stream_path, f.since);
    // Invalidation is what unschedules a stream, and it requires one that
    // is scheduled, so this may only run after the line below it.
    errdefer {
        c.FSEventStreamInvalidate(stream.ref);
        c.FSEventStreamRelease(stream.ref);
    }
    c.FSEventStreamSetDispatchQueue(stream.ref, f.queue);
    if (c.FSEventStreamStart(stream.ref) == 0) return error.WatchLimitReached;
    trace.log("fsevents started watch={d} since={d} latency={d} streams={d} latest={d} dev={d} now={d}", .{
        @intFromEnum(id),                            f.since,
        stream_latency,                              f.streams.count() + 1,
        c.FSEventStreamGetLatestEventId(stream.ref), c.FSEventStreamGetDeviceBeingWatched(stream.ref),
        c.FSEventsGetCurrentEventId(),
    });

    f.streams.putAssumeCapacity(id, stream);
    if (scope != .file) f.budget.seed(abs_path) catch {};
    f.seedKnown(stream) catch {};
    trace.log("fsevents seeded watch={d} known={d}", .{ @intFromEnum(id), f.known.count() });
}

/// Builds the CoreFoundation array FSEvents wants and creates the stream.
fn createStream(stream: *Stream, subject: []const u8, since: u64) lookout.Watcher.AddError!c.FSEventStreamRef {
    const cf_path = c.CFStringCreateWithBytes(
        null,
        subject.ptr,
        @intCast(subject.len),
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
    return c.FSEventStreamCreate(null, deliver, &context, paths, since, stream_latency, flags) orelse
        error.SystemResources;
}

/// Stops watching `id`.
pub fn remove(f: *FsEvents, id: WatchId) void {
    const entry = f.streams.fetchSwapRemove(id) orelse return;
    f.budget.forget(entry.value.root);
    f.destroy(entry.value);
}

fn destroy(f: *FsEvents, stream: *Stream) void {
    trace.log("fsevents stop watch={d} root={s} streams={d}", .{
        @intFromEnum(stream.id), stream.root, f.streams.count(),
    });
    // Stop, invalidate, release, in that order and with nothing between.
    // `FSEventStreamInvalidate` is what unschedules the stream from the
    // queue, and it requires the stream to still be scheduled: calling
    // `FSEventStreamSetDispatchQueue(ref, null)` first -- which is the
    // other way to unschedule -- makes the invalidation fail its own
    // assertion and do nothing, which leaves the stream registered with
    // the system after it has been released, still holding the pointer
    // to the memory freed below.
    c.FSEventStreamStop(stream.ref);
    c.FSEventStreamInvalidate(stream.ref);
    c.FSEventStreamRelease(stream.ref);
    // Invalidation says no further delivery will be made; it does not say
    // that one already running has returned, and `stream` is what it
    // holds a pointer to. The queue is serial, so an empty block run
    // synchronously on it returns only once everything accepted before it
    // has finished.
    c.dispatch_sync_f(f.queue, null, settled);
    f.gpa.free(stream.root);
    stream.filter.deinit(f.gpa);
    f.gpa.destroy(stream);
}

/// The block `destroy` waits on. It does nothing; arriving is the point.
fn settled(_: ?*anyopaque) callconv(.c) void {}

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
    const stream: *Stream = @ptrCast(@alignCast(info.?));
    const list: [*]const [*:0]const u8 = @ptrCast(@alignCast(paths.?));

    stream.sink.lock.acquire();
    defer stream.sink.lock.release();
    stream.sink.deliveries += 1;
    for (0..count) |i| stream.sink.append(stream.id, flags[i], ids[i], std.mem.span(list[i]));
    stream.sink.signal();
}

/// Waits on the wake pipe until the drain produces something `batch` did
/// not already hold, or `timeout_ms` expires. `null` never gives up.
pub fn wait(f: *FsEvents, batch: *Batch, timeout_ms: ?u32) lookout.Watcher.PollError!void {
    const result = f.collect(batch, timeout_ms);
    // Whatever is still held when the wait is over never found its
    // partner, however many deliveries it waited through.
    try f.resolveHeld(batch);
    // And a replay that caught up during this wait is over, along with
    // the wave of changes that came with it.
    for (f.streams.values()) |stream| {
        if (!stream.caught_up) continue;
        stream.caught_up = false;
        stream.replaying = false;
    }
    return result;
}

fn collect(f: *FsEvents, batch: *Batch, timeout_ms: ?u32) lookout.Watcher.PollError!void {
    const before = batch.revision;
    const deadline: Deadline = .start(f.io, timeout_ms);

    while (true) {
        try f.drain(batch);
        if (f.sink.woken.swap(false, .acquire)) return;
        if (batch.revision != before) {
            // A rename with no partner yet is worth waiting a moment
            // for: the other half is on its way if the burst was simply
            // longer than one delivery, and deciding now would turn one
            // `renamed` into a removal and a creation.
            var round: usize = 0;
            while (f.held != null and round < grace_rounds) : (round += 1) {
                if (!f.readable(grace_ms)) break;
                try f.drain(batch);
            }
            return;
        }
        // Clamped rather than returned on, so that a `timeout_ms` of zero
        // still performs one non-blocking check.
        if (!f.readable(deadline.pollMs())) return;
    }
}

/// Waits for the wake pipe, and empties it. `false` when nothing came.
fn readable(f: *FsEvents, timeout: i32) bool {
    var fds: [1]posix.pollfd = .{.{ .fd = f.sink.wake_r, .events = posix.POLL.IN, .revents = 0 }};
    const ready = posix.poll(&fds, timeout) catch return false;
    if (ready == 0) return false;
    var scratch: [256]u8 = undefined;
    while (std.c.read(f.sink.wake_r, &scratch, scratch.len) > 0) {}
    return true;
}

/// Takes everything the delivery thread has left and turns it into
/// events.
fn drain(f: *FsEvents, batch: *Batch) lookout.Watcher.PollError!void {
    f.staging.clearRetainingCapacity();
    var overflowed = false;
    var deliveries: usize = 0;
    var dropped: usize = 0;
    {
        f.sink.lock.acquire();
        defer f.sink.lock.release();
        overflowed = f.sink.overflowed;
        f.sink.overflowed = false;
        deliveries = f.sink.deliveries;
        dropped = f.sink.dropped;
        f.sink.deliveries = 0;
        f.sink.dropped = 0;
        f.staging.appendSlice(f.gpa, f.sink.buffer[0..f.sink.len]) catch {
            // The buffer stays where it is: a drain that cannot allocate
            // reports the loss and tries again next time rather than
            // throwing the delivery away.
            f.sink.overflowed = overflowed;
            return error.OutOfMemory;
        };
        f.sink.len = 0;
    }
    if (trace.enabled() and (deliveries != 0 or f.staging.items.len != 0)) {
        trace.log("fsevents drain deliveries={d} bytes={d} dropped={d} overflowed={}", .{
            deliveries, f.staging.items.len, dropped, overflowed,
        });
    }
    if (overflowed) {
        for (f.streams.values()) |stream| {
            try batch.push(f.gpa, stream.id, stream.root, .overflow, .directory);
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
        const event = std.mem.readInt(u64, bytes[offset + 12 ..][0..8], .little);
        offset += Sink.header_len;
        if (offset + len > bytes.len) break;
        const subject = bytes[offset..][0..len];
        trace.log("fsevents record watch={d} event={d} flags=0x{x} path={s}", .{
            @intFromEnum(id), event, flags, subject,
        });
        try records.append(f.gpa, .{ .id = id, .flags = flags, .path = subject });
        offset += len;
    }

    // Which records a pairing has already spoken for. FSEvents puts
    // both halves of a rename in one delivery but not always next to
    // each other -- the directory they are in can be named between
    // them -- so a partner is looked for anywhere in the delivery and
    // struck off here.
    const used = try f.gpa.alloc(bool, records.items.len);
    defer f.gpa.free(used);
    @memset(used, false);

    // The half held from the last drain looks for its partner here.
    if (f.held != null) try f.rejoin(batch, records.items, used);

    for (records.items, 0..) |_, i| {
        if (used[i]) continue;
        try f.report(batch, records.items, used, i);
    }
}

/// Joins the half held from the last drain to its partner in this one,
/// or gives up on it.
fn rejoin(f: *FsEvents, batch: *Batch, records: []const Record, used: []bool) lookout.Watcher.PollError!void {
    const half = f.held orelse return;
    const at = f.partnerOf(half.id, half.path, records, used, 0) orelse
        return f.resolveHeld(batch);
    const stream = f.streams.get(half.id) orelse return f.resolveHeld(batch);

    f.held = null;
    used[at] = true;
    defer f.gpa.free(half.path);
    const partner = records[at];
    if (f.exists(partner.path)) {
        try f.joined(batch, half.id, partner.path, half.path, partner.target());
    } else {
        try f.joined(batch, half.id, half.path, partner.path, partner.target());
    }
    try f.recount(batch, partner, stream);
}

/// Where in `records` the other half of a rename of `subject` is, if it
/// is there at all.
///
/// The one that no longer exists is the name it came from: the inode
/// moved, so exactly one of the two paths resolves. When neither test
/// settles it -- the file was renamed and then deleted, or renamed out
/// of the watch -- there is no partner and there is nothing to pair.
fn partnerOf(
    f: *FsEvents,
    id: WatchId,
    subject: []const u8,
    records: []const Record,
    used: []const bool,
    from: usize,
) ?usize {
    const stream = f.streams.get(id) orelse return null;
    const subject_exists = f.exists(subject);
    for (records[from..], from..) |record, at| {
        if (used[at]) continue;
        if (record.id != id) continue;
        if (record.flags & c.kFSEventStreamEventFlagItemRenamed == 0) continue;
        if (path_cmp.eql(record.path, subject)) continue;
        if (!stream.wants(record.path)) continue;
        if (stream.filter.excludes(stream.root, record.path)) continue;
        if (f.exists(record.path) == subject_exists) continue;
        return at;
    }
    return null;
}

/// One delivered change, still pointing into `staging`.
const Record = struct {
    id: WatchId,
    flags: u32,
    path: []const u8,

    fn target(r: Record) Target {
        return if (r.flags & c.kFSEventStreamEventFlagItemIsDir != 0) .directory else .file;
    }
};

/// Reports one record, pairing it with another of the delivery when it
/// is half of a rename.
fn report(
    f: *FsEvents,
    batch: *Batch,
    records: []const Record,
    used: []bool,
    at: usize,
) lookout.Watcher.PollError!void {
    const record = records[at];
    const stream = f.streams.get(record.id) orelse {
        trace.log("fsevents drop no-stream watch={d} path={s}", .{ @intFromEnum(record.id), record.path });
        return;
    };
    if (!stream.wants(record.path)) {
        trace.log("fsevents drop out-of-scope root={s} path={s}", .{ stream.root, record.path });
        return;
    }

    if (record.flags & (c.kFSEventStreamEventFlagMustScanSubDirs |
        c.kFSEventStreamEventFlagUserDropped |
        c.kFSEventStreamEventFlagKernelDropped) != 0)
    {
        trace.log("fsevents push overflow root={s}", .{stream.root});
        try batch.push(f.gpa, record.id, stream.root, .overflow, .directory);
    }
    // The marker that a replay asked for by `lookout.Options.since` has
    // caught up with the present. Nothing happened to a path, so there
    // is nothing to report; it is declared and swallowed rather than
    // left to look like a change to the watch root.
    if (record.flags & c.kFSEventStreamEventFlagHistoryDone != 0) {
        trace.log("fsevents history done root={s}", .{stream.root});
        if (f.streams.get(record.id)) |live| live.caught_up = true;
        return;
    }
    // The watched path itself moved or vanished. FSEvents reports both
    // against the root with one flag and does not say which, so lookout
    // asks the file system: a root that is still there was moved, and one
    // that is not was deleted. FSEvents keeps watching the inode either
    // way; lookout reports it and lets the caller decide.
    if (record.flags & c.kFSEventStreamEventFlagRootChanged != 0) {
        const kind: lookout.Kind = if (f.exists(stream.root)) .renamed else .removed;
        trace.log("fsevents push {s} root={s}", .{ @tagName(kind), stream.root });
        try batch.push(f.gpa, record.id, stream.root, kind, .directory);
        return;
    }

    // The kernel walked the tree whatever the filter says; what the
    // filter can still do is keep the event from the caller.
    if (stream.filter.excludes(stream.root, record.path)) {
        trace.log("fsevents drop filtered path={s}", .{record.path});
        return;
    }

    if (record.flags & c.kFSEventStreamEventFlagItemRenamed != 0) {
        if (f.partnerOf(record.id, record.path, records, used, at + 1)) |partner_at| {
            used[partner_at] = true;
            const partner = records[partner_at];
            trace.log("fsevents push renamed path={s}", .{record.path});
            if (f.exists(partner.path)) {
                try f.joined(batch, record.id, partner.path, record.path, partner.target());
            } else {
                try f.joined(batch, record.id, record.path, partner.path, record.target());
            }
            try f.recount(batch, record, stream);
            try f.recount(batch, partner, stream);
            return;
        }
        // No partner in this delivery. It may be in the next one, so
        // the decision waits: calling it now would turn one `renamed`
        // into a removal and a creation on a backend that pairs them.
        try f.hold(batch, record);
        return;
    }

    try f.reportPlain(batch, record, stream);
}

/// Reports a record that is not half of a rename, by resolving the
/// accumulated flags against the file system.
///
/// The flags are not a sequence of things that happened. FSEvents keeps
/// them per path and does not clear them, so a file created an hour ago
/// and written now still arrives with `ItemCreated` set alongside
/// `ItemModified`. What resolves them is the file: whether it is there,
/// and whether lookout has seen it before.
fn reportPlain(
    f: *FsEvents,
    batch: *Batch,
    record: Record,
    stream: *const Stream,
) lookout.Watcher.PollError!void {
    const there = f.exists(record.path);
    const seen = f.known.contains(record.path);

    if (!there) {
        // Gone. Whatever the flags remember about it, the fact now is
        // that the path is not there. A path lookout never knew about came
        // and went between two polls, and the tree is as it was.
        if (seen or stream.replaying) {
            trace.log("fsevents push removed path={s}", .{record.path});
            try batch.push(f.gpa, record.id, record.path, .removed, record.target());
            f.forget(record.path);
            if (record.target() == .directory) f.forgetSubtree(record.path);
            try f.recount(batch, record, stream);
        } else {
            trace.log("fsevents drop gone-unknown path={s}", .{record.path});
        }
        return;
    }
    if (!seen) {
        trace.log("fsevents push created path={s}", .{record.path});
        try batch.push(f.gpa, record.id, record.path, .created, record.target());
        try f.remember(record.path);
        // A directory can arrive with a tree already inside it -- an
        // archive unpacked, or a rename this backend could not pair --
        // and what is inside it is as new to lookout as the directory
        // is. The backends that recurse themselves walk it here; this
        // one has to as well, or the first write to a file inside would
        // be the first lookout had heard of the path and would be
        // reported as its creation.
        if (record.target() == .directory and stream.scope == .tree) {
            try f.adopt(batch, record.id, record.path, stream);
        }
        try f.recount(batch, record, stream);
        return;
    }
    // Contents and metadata, but not a directory's. A directory's own
    // times move whenever anything inside it moves, so reporting them
    // would make every ancestor of a change produce an event of its own
    // -- which no other backend does and a caller cannot use. It matters
    // more here than anywhere: FSEvents keeps these flags per path and
    // never clears them, so the first delivery naming a directory
    // carries whatever was last done to it, however long ago.
    if (record.target() != .directory) {
        if (record.flags & c.kFSEventStreamEventFlagItemModified != 0) {
            trace.log("fsevents push modified path={s}", .{record.path});
            try batch.push(f.gpa, record.id, record.path, .modified, .file);
        } else if (record.flags & (c.kFSEventStreamEventFlagItemInodeMetaMod |
            c.kFSEventStreamEventFlagItemChangeOwner |
            c.kFSEventStreamEventFlagItemXattrMod |
            c.kFSEventStreamEventFlagItemFinderInfoMod) != 0)
        {
            trace.log("fsevents push attributes path={s}", .{record.path});
            try batch.push(f.gpa, record.id, record.path, .attributes, .file);
        } else {
            trace.log("fsevents drop known-no-change path={s}", .{record.path});
        }
    } else {
        trace.log("fsevents drop dir-metadata path={s}", .{record.path});
    }
    try f.recount(batch, record, stream);
}

/// Reports everything inside a directory that has just appeared, and
/// remembers it.
fn adopt(
    f: *FsEvents,
    batch: *Batch,
    id: WatchId,
    root: []const u8,
    stream: *const Stream,
) lookout.Watcher.PollError!void {
    const Adopting = struct {
        f: *FsEvents,
        batch: *Batch,
        id: WatchId,
        stream: *const Stream,

        fn visit(a: *@This(), entry: walk.Entry) anyerror!walk.Step {
            if (a.stream.filter.prunes(a.stream.root, entry.path)) return .over;
            if (a.f.known.contains(entry.path)) return .into;
            if (!a.stream.filter.excludes(a.stream.root, entry.path)) {
                try a.batch.push(a.f.gpa, a.id, entry.path, .created, .of(entry.kind));
            }
            try a.f.remember(entry.path);
            return .into;
        }
    };
    var adopting: Adopting = .{ .f = f, .batch = batch, .id = id, .stream = stream };
    walk.tree(f.gpa, f.io, root, &adopting, Adopting.visit) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Unexpected,
    };
}

/// Reports one rename and moves everything lookout remembers from the
/// old name to the new one.
///
/// The second half is what a byte-for-byte record of a tree gets wrong
/// after a directory is renamed: every path under the old name is still
/// remembered under it, so the first write inside the new name is a path
/// lookout has never seen and is reported as a creation.
fn joined(
    f: *FsEvents,
    batch: *Batch,
    id: WatchId,
    to: []const u8,
    from: []const u8,
    target: Target,
) lookout.Watcher.PollError!void {
    try batch.pushRename(f.gpa, id, to, from, target);
    try f.rekey(from, to);
    f.budget.forget(from);
}

/// Holds an unpaired rename until the next delivery arrives. Anything
/// already held has waited as long as it is going to.
fn hold(f: *FsEvents, batch: *Batch, record: Record) lookout.Watcher.PollError!void {
    if (f.held != null) try f.resolveHeld(batch);
    const owned = try f.gpa.dupe(u8, record.path);
    f.held = .{ .id = record.id, .path = owned, .flags = record.flags };
    trace.log("fsevents hold renamed path={s}", .{record.path});
}

/// Reports a held half that never found its partner: the path was
/// renamed out of the watch, or renamed and then deleted, and what is
/// left is the removal or the creation the other backends would give.
fn resolveHeld(f: *FsEvents, batch: *Batch) lookout.Watcher.PollError!void {
    const half = f.held orelse return;
    f.held = null;
    defer f.gpa.free(half.path);
    const stream = f.streams.get(half.id) orelse return;
    trace.log("fsevents unpaired renamed path={s}", .{half.path});
    try f.reportPlain(batch, .{ .id = half.id, .flags = half.flags, .path = half.path }, stream);
}

/// Records that a path exists.
fn remember(f: *FsEvents, subject: []const u8) Allocator.Error!void {
    if (f.known.contains(subject)) return;
    const owned = try f.gpa.dupe(u8, subject);
    errdefer f.gpa.free(owned);
    try f.known.put(f.gpa, owned, {});
}

/// Records that a path does not.
fn forget(f: *FsEvents, subject: []const u8) void {
    if (f.known.fetchSwapRemove(subject)) |entry| f.gpa.free(entry.key);
}

/// Forgets everything remembered under a subtree that has gone.
fn forgetSubtree(f: *FsEvents, root: []const u8) void {
    var i: usize = 0;
    while (i < f.known.count()) {
        if (path_cmp.within(root, f.known.keys()[i])) {
            f.gpa.free(f.known.keys()[i]);
            f.known.swapRemoveAt(i);
        } else {
            i += 1;
        }
    }
}

/// Moves everything remembered under `old` to sit under `new`, which is
/// what a directory rename does to a tree.
fn rekey(f: *FsEvents, old: []const u8, new: []const u8) Allocator.Error!void {
    var moved: std.ArrayList([]u8) = .empty;
    defer {
        for (moved.items) |p| f.gpa.free(p);
        moved.deinit(f.gpa);
    }

    var i: usize = 0;
    while (i < f.known.count()) {
        const key = f.known.keys()[i];
        const rest = path_cmp.relative(old, key) orelse {
            i += 1;
            continue;
        };
        // Built before the key it points into is freed.
        const renamed = if (rest.len == 0)
            try f.gpa.dupe(u8, new)
        else
            try std.fs.path.join(f.gpa, &.{ new, rest });
        errdefer f.gpa.free(renamed);
        try moved.append(f.gpa, renamed);
        f.gpa.free(key);
        f.known.swapRemoveAt(i);
    }

    while (moved.items.len != 0) {
        const p = moved.pop().?;
        if (f.known.contains(p)) {
            f.gpa.free(p);
            continue;
        }
        f.known.put(f.gpa, p, {}) catch {
            f.gpa.free(p);
            return error.OutOfMemory;
        };
    }
}

/// Walks a watch once, so that everything already there is known and the
/// first thing to happen to it is not reported as its creation.
///
/// Listing only: no descriptor is kept, which is the difference between
/// this and what the `kqueue` backend has to do.
fn seedKnown(f: *FsEvents, stream: *const Stream) !void {
    // The root itself, before anything below it: FSEvents names the
    // watched path as readily as it names an entry, and a path the
    // backend has never heard of is a path it reports as created. This
    // is the whole of the seeding for a watch on a single file.
    if (f.exists(stream.root)) try f.remember(stream.root);
    if (stream.scope == .file) return;
    trace.log("fsevents seed walk root={s}", .{stream.root});

    const Seeding = struct {
        f: *FsEvents,
        stream: *const Stream,

        fn visit(s: *@This(), entry: walk.Entry) anyerror!walk.Step {
            if (s.stream.filter.prunes(s.stream.root, entry.path)) {
                trace.log("fsevents seed filtered {s}", .{entry.path});
                return .over;
            }
            trace.log("fsevents seed remembered {s}", .{entry.path});
            try s.f.remember(entry.path);
            return if (s.stream.scope == .tree) .into else .over;
        }
    };
    var seeding: Seeding = .{ .f = f, .stream = stream };
    try walk.tree(f.gpa, f.io, stream.root, &seeding, Seeding.visit);
}

fn exists(f: *const FsEvents, subject: []const u8) bool {
    _ = Io.Dir.cwd().statFile(f.io, subject, .{ .follow_symlinks = false }) catch return false;
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
    const move: Budget.Move = if (appeared)
        .appeared
    else if (vanished)
        .vanished
    else
        .unchanged;
    if (try f.budget.note(parent, move)) {
        try batch.push(f.gpa, record.id, stream.root, .overflow, .directory);
    }
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
    /// The replay a past `since_when` asked for has reached the present.
    const kFSEventStreamEventFlagHistoryDone: u32 = 0x00000010;
    const kFSEventStreamEventFlagRootChanged: u32 = 0x00000020;
    const kFSEventStreamEventFlagItemCreated: u32 = 0x00000100;
    const kFSEventStreamEventFlagItemRemoved: u32 = 0x00000200;
    const kFSEventStreamEventFlagItemInodeMetaMod: u32 = 0x00000400;
    const kFSEventStreamEventFlagItemRenamed: u32 = 0x00000800;
    const kFSEventStreamEventFlagItemModified: u32 = 0x00001000;
    const kFSEventStreamEventFlagItemFinderInfoMod: u32 = 0x00002000;
    const kFSEventStreamEventFlagItemChangeOwner: u32 = 0x00004000;
    const kFSEventStreamEventFlagItemXattrMod: u32 = 0x00008000;
    const kFSEventStreamEventFlagItemIsDir: u32 = 0x00020000;

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
    extern "c" fn FSEventStreamGetLatestEventId(stream: FSEventStreamRef) u64;
    extern "c" fn FSEventStreamGetDeviceBeingWatched(stream: FSEventStreamRef) i32;
    extern "c" fn FSEventsGetCurrentEventId() u64;
    extern "c" fn FSEventStreamStop(stream: FSEventStreamRef) void;
    extern "c" fn FSEventStreamInvalidate(stream: FSEventStreamRef) void;
    extern "c" fn FSEventStreamRelease(stream: FSEventStreamRef) void;

    extern "c" fn dispatch_queue_create(label: ?[*:0]const u8, attr: ?*anyopaque) ?dispatch_queue_t;
    extern "c" fn dispatch_release(object: *anyopaque) void;
    extern "c" fn dispatch_sync_f(
        queue: dispatch_queue_t,
        context: ?*anyopaque,
        work: *const fn (?*anyopaque) callconv(.c) void,
    ) void;
};
