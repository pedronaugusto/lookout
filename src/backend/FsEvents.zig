//! The Apple backend: FSEvents.
//!
//! FSEvents and `ReadDirectoryChangesW` recurse in the kernel. A
//! whole tree costs one stream and no descriptors, where `kqueue` costs
//! one descriptor per directory and per file; it names the entry that
//! changed, where `kqueue` says only that a directory moved; it pairs
//! the two halves of a rename; and it is the only one of the five that
//! can say what happened before the watch existed, which is
//! `@import("../options.zig").Options.checkpoint`. That is why it, and not `kqueue`, is
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
//!   How much that buffer holds is `@import("../options.zig").Options.buffer_bytes`.
//! * FSEvents coalesces on its own, before lookout sees anything. Its
//!   stream uses `@import("../options.zig").Options.latency_ms` for that window and
//!   `NoDefer`, so the first event is requested without waiting for the
//!   rest of the window. Passing zero removes lookout's delay, but macOS
//!   still imposed a measured 10.459 ms median (11.714 ms p99) delivery
//!   floor. Several changes to one path can therefore arrive as one event
//!   with several flags set.
//! * It is not a queue of facts but a report of what changed, so it can
//!   say "I lost track, look again": `kFSEventStreamEventFlagMustScanSubDirs`
//!   and the two dropped-event flags all become `lookout.Kind.overflow`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const posix = std.posix;

const lookout = @import("../types.zig");
const Batch = @import("../Batch.zig");
const Volume = @import("fsevents/Volume.zig");
const CheckpointPaths = @import("../Checkpoint/History.zig");
const checkpoint_format = @import("../Checkpoint/format.zig");
const Budget = @import("../Budget.zig");
const Deadline = @import("../Deadline.zig");
const Filter = @import("../Filter.zig");
const buffer = @import("../buffer.zig");
const path_cmp = @import("../path.zig");
const records = @import("fsevents/records.zig");
const trace = @import("../trace.zig");
const walk = @import("../walk.zig");
const Waker = @import("../Waker.zig");
const Checkpoint = @import("../Checkpoint.zig");
const Options = @import("../options.zig").Options;
const contract = @import("../watch_contract.zig");
const AddOptions = @import("../options.zig").AddOptions;
const builtin = @import("builtin");
const Record = records.Record;
const Target = lookout.Target;
const WatchId = lookout.WatchId;
const flag = records.flag;

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
/// The staging delivery's loss flag stays with its bytes until reporting
/// succeeds, including a delivery containing only an overflow notice.
staging_overflowed: bool = false,
/// How many entries each watched directory holds, against
/// `@import("../options.zig").Options.max_dir_entries`.
budget: Budget,
/// Owned restarting state, copied at init. Each stream consumes its matching
/// watch only after registration and restoration succeed.
restarting: ?Checkpoint,
resume_used: []bool,
/// Every path each watch believes exists, seeded by walking the watch
/// when it is added and kept current from what it reports. Path keys are
/// owned here and compared the way the file system compares them.
///
/// This is the price of FSEvents' flags. They are not a sequence of
/// things that happened: FSEvents keeps them per path and does not clear
/// them, so a file created an hour ago and written now still arrives
/// with `ItemCreated` set beside `ItemModified`, and no reading of the
/// flags alone can tell a creation from a write. What can tell them
/// apart is whether lookout has seen the path before. It costs a string
/// and initial metadata per watched file -- still nothing against `kqueue`'s descriptor per
/// watched file, which is the comparison that matters on this platform.
known: std.ArrayHashMapUnmanaged(KnownKey, ?Initial, KnownKeyContext, true),
/// Paths and retained revisions share storage; known keys borrow their nodes.
paths: *CheckpointPaths,
/// The half of a rename whose partner has not been delivered yet. The
/// path it holds is owned here -- see `records.Half`.
pairing: records.Pairing,
/// FSEvents' coalescing window, in seconds. The stream takes the same
/// window as `@import("../options.zig").Options.latency_ms`; `NoDefer` still makes its
/// first event immediate.
stream_latency: f64,

/// Fresh streams replay a conservative device boundary. Remember the initial
/// metadata until the path first changes, so old accumulated flags do not
/// report the state add just seeded. Checkpoint replay bypasses this baseline.
/// The seeding walk reads it with each directory listing; a record compares
/// it with an `lstat`, which reports the same fields for an unchanged entry.
const Initial = walk.Meta;

pub const KnownKey = struct {
    id: WatchId,
    path: []const u8,
    history: ?*CheckpointPaths.Node = null,
};

pub const KnownKeyContext = struct {
    pub fn hash(_: KnownKeyContext, key: KnownKey) u32 {
        const mixed = path_cmp.hash(key.path) ^
            (@as(u64, @intFromEnum(key.id)) *% 0x9e3779b97f4a7c15);
        return @truncate(mixed);
    }

    pub fn eql(_: KnownKeyContext, a: KnownKey, b: KnownKey, _: usize) bool {
        return a.id == b.id and path_cmp.eql(a.path, b.path);
    }
};

/// What `@import("../options.zig").Options.buffer_bytes` may ask for here.
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
    /// Sized by `@import("../options.zig").Options.buffer_bytes`, allocated once at `init`
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

    /// Written here and read back in `drain`, both through
    /// src/backend/fsevents/records.zig, which is where the layout is
    /// written down and where it is fuzzed.
    fn append(s: *Sink, id: WatchId, flags: u32, event: u64, subject: []const u8) void {
        if (s.len + records.encodedLen(subject) > s.buffer.len) {
            s.overflowed = true;
            s.dropped += 1;
            return;
        }
        s.len += records.encode(s.buffer[s.len..], id, flags, event, subject);
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
    ref: c.FsEventStreamRef,
    volume: Volume,
    /// False for host streams covering scopes with more than one device.
    persistent: bool,
    /// The path the caller named, absolute and canonical.
    root: []u8,
    /// Which paths under the stream's own root this watch is about.
    /// FSEvents is always recursive, so a narrower watch is a filter.
    scope: Scope,
    /// `@import("../options.zig").AddOptions.filter`, copied.
    ///
    /// FSEvents recurses in the kernel and cannot be told to leave a
    /// directory out, so here the filter drops the events rather than
    /// saving the work -- see `lookout.prunesIgnored`.
    filter: Filter,
    /// Greatest record id fully reported into Batch for this stream.
    cursor: u64,
    resume_index: ?usize,
    /// Whether this stream was started from a checkpoint rather than from
    /// now, which `@import("../options.zig").Options.checkpoint` asked for. The persisted path baseline closes the resume gap.
    resumed: bool,
    /// When `HistoryDone` arrived, or `null` while the system is still
    /// reading its log. The persisted path baseline closes the resume gap.
    replayed: ?Io.Timestamp,
    /// Set, with release, once the fields the delivery thread reads are
    /// written, and read with acquire by every delivery. FSEvents orders
    /// its start before its first callback, but inside the framework,
    /// where a race detector cannot see it; this says it where it can.
    published: std.atomic.Value(bool) = .init(false),

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

    /// The directories whose entries this stream reports, and so whose
    /// entry budget it keeps; `null` for a watch on a file.
    ///
    /// A watch on a file has its stream on the folder only to see the
    /// file. It is told nothing about the folder's other entries, so it
    /// cannot keep the folder's count, and on no other backend is a file
    /// watch told when its folder is past the budget. Counting the folder
    /// through it moved the count only when the file came or went, and
    /// that count outlived the folder's own watch.
    pub fn reach(st: *const Stream) ?Budget.Reach {
        return switch (st.scope) {
            .tree => .{ .dir = st.root, .recursive = true },
            .directory => .{ .dir = st.root, .recursive = false },
            .file => null,
        };
    }

    fn rootTarget(st: *const Stream) Target {
        return if (st.scope == .file) .file else .directory;
    }

    /// Whether a loss the system reports at `subject` can have taken
    /// events this watch wanted: `subject` is inside the watch, or the
    /// watch is inside `subject`. The second half is what a watch on a
    /// file needs, whose stream is on the parent directory: the loss is
    /// reported at the parent, which `wants` rightly refuses as an
    /// event, and which is nonetheless where this file's events were
    /// lost.
    fn concerns(st: *const Stream, subject: []const u8) bool {
        return st.wants(subject) or path_cmp.within(subject, st.root);
    }
};

/// The flags that say the system lost track: `MustScanSubDirs` is the
/// instruction, and the two dropped flags are the informational ones
/// beside it saying whether the bottleneck was in the kernel or in this
/// process. Each becomes `lookout.Kind.overflow` on its own, because a
/// loss the system does not say how to recover from is still a loss.
const lost_track: u32 = flag.must_scan_sub_dirs | flag.user_dropped | flag.kernel_dropped;

/// Creates the delivery queue, the buffer it fills, and the pipe the
/// watcher is woken through.
pub fn init(gpa: Allocator, io: Io, options: Options) contract.InitError!FsEvents {
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
        const flags = std.c.fcntl(end, c.f_getfl, @as(c_int, 0));
        if (flags < 0) return error.Unexpected;
        if (std.c.fcntl(end, c.f_setfl, flags | c.o_nonblock) < 0) return error.Unexpected;
    }

    const sink = try gpa.create(Sink);
    errdefer gpa.destroy(sink);
    const bytes = try gpa.alloc(u8, buffer.clamp(options.buffer_bytes, bounds));
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

    errdefer c.dispatch_release(queue);
    var restarting: ?Checkpoint = if (options.checkpoint) |checkpoint|
        .{ .state = try checkpoint_format.copy(gpa, checkpoint.state.value) }
    else
        null;
    errdefer if (restarting) |*checkpoint| checkpoint.deinit();
    const resume_used = try gpa.alloc(bool, if (restarting) |checkpoint| checkpoint.state.value.watches.len else 0);
    errdefer gpa.free(resume_used);
    @memset(resume_used, false);
    const paths = try CheckpointPaths.init(gpa);
    return .{
        .gpa = gpa,
        .io = io,
        .queue = queue,
        .sink = sink,
        .streams = .empty,
        .staging = .empty,
        .budget = .init(gpa, io, options.max_dir_entries),
        .restarting = restarting,
        .resume_used = resume_used,
        .paths = paths,
        .known = .empty,
        .pairing = .{},
        .stream_latency = latencySeconds(options.latency_ms),
    };
}

fn latencySeconds(milliseconds: u32) f64 {
    return @as(f64, @floatFromInt(milliseconds)) / std.time.ms_per_s;
}

/// Stops every stream, waits for the delivery thread to be done with
/// them, and closes the pipe.
pub fn deinit(f: *FsEvents) void {
    for (f.streams.values()) |stream| f.destroy(stream);
    f.streams.deinit(f.gpa);
    f.staging.deinit(f.gpa);
    if (f.restarting) |*checkpoint| checkpoint.deinit();
    f.gpa.free(f.resume_used);
    f.budget.deinit();
    f.known.deinit(f.gpa);
    f.paths.release();
    if (f.pairing.held) |half| f.gpa.free(half.path);
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

/// Copies only polling-thread state. Callback bytes are still in the log
/// beyond each stream's cursor and need no snapshot copy. A retained failed
/// drain has not committed its cursor and must be retried first.
pub fn capture(f: *const FsEvents, gpa: Allocator, batch: *const Batch, include_ready: bool, roots: []const contract.WatchInfo) Allocator.Error!?Checkpoint {
    if (f.staging.items.len != 0 or f.staging_overflowed) return null;
    var watches: std.ArrayList(checkpoint_format.Watch) = .empty;
    defer watches.deinit(gpa);
    defer for (watches.items) |watch| {
        gpa.free(watch.changes);
        watch.baseline.release();
    };
    for (roots) |root| {
        const stream = f.streams.get(root.id) orelse return null;
        if (!stream.persistent) return null;
        const identity = stream.volume.identity orelse return null;
        const name = try gpa.dupeZ(u8, stream.root);
        defer gpa.free(name);
        const current = Volume.readIdentity(name, stream.volume.device) orelse return null;
        if (!Volume.matches(identity, current)) return null;
        const changes = try batch.capture(gpa, root.id, include_ready);
        errdefer gpa.free(changes);
        var half: ?checkpoint_format.Half = null;
        if (f.pairing.held) |held| {
            if (held.id == root.id) half = .{ .path = held.path, .flags = held.flags, .event = held.event };
        }
        const paths = try f.paths.snapshot(gpa, root.id, root.path);
        errdefer paths.release();
        const cursor = stream.cursor;
        try watches.append(gpa, .{ .root = root.path, .recursive = root.recursive, .cursor = cursor, .identity = identity, .changes = changes, .half = half, .baseline = paths });
    }
    return .{ .state = try checkpoint_format.copy(gpa, .{ .version = 2, .backend = .fsevents, .watches = watches.items }) };
}

fn resumeIndex(f: *const FsEvents, root: []const u8) ?usize {
    const checkpoint = f.restarting orelse return null;
    for (checkpoint.state.value.watches, 0..) |watch, i| {
        if (!f.resume_used[i] and path_cmp.eql(root, watch.root)) return i;
    }
    return null;
}

/// The requested root's checkpoint was refused during a pending watch's
/// promotion. Its owner reports loss and recreates a fresh registration.
pub fn discardCheckpoint(f: *FsEvents, root: []const u8) void {
    if (f.resumeIndex(root)) |index| f.resume_used[index] = true;
}

/// A copy of what the delivery thread has handed over and no drain has
/// taken yet, and whether `buffer_bytes` has already turned some of it
/// away. Nothing is drained: a test that must know what the system has
/// delivered while nobody polls -- which is the whole claim of a buffer
/// the caller sized -- reads it here. The copy is the caller's to free.
pub fn copyHeld(f: *FsEvents, gpa: Allocator) Allocator.Error!Held {
    f.sink.lock.acquire();
    defer f.sink.lock.release();
    return .{
        .bytes = try gpa.dupe(u8, f.sink.buffer[0..f.sink.len]),
        .overflowed = f.sink.overflowed,
    };
}

/// See `copyHeld`. Read `bytes` with `fsevents_records.iterate`.
pub const Held = struct {
    bytes: []u8,
    overflowed: bool,
};

/// How another thread pokes a blocked `wait`: the sink, which is
/// allocated once at `init`, never moves, and is already shared with the
/// delivery thread. See `lookout.Watcher.wake`.
pub fn waker(f: *const FsEvents) Waker {
    return .{ .context = @intFromPtr(f.sink), .call = poke }; // safe: the sink's address, allocated at init and never moved, turned back by poke alone
}

/// Marks the sink woken and pokes the pipe a blocked `wait` is polling.
fn poke(context: usize) void {
    const sink: *Sink = @ptrFromInt(context);
    sink.woken.store(true, .release);
    sink.signal();
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
    options: AddOptions,
    batch: *Batch,
) contract.AddError!void {
    return f.addFor(id, abs_path, abs_path, options, batch);
}

/// The caller's root identifies a resume watch even when its registration
/// is parked on an ancestor while that root is absent.
pub fn addFor(f: *FsEvents, id: WatchId, abs_path: []const u8, requested: []const u8, options: AddOptions, batch: *Batch) contract.AddError!void {
    try f.streams.ensureUnusedCapacity(f.gpa, 1);
    var stream = try f.startStream(id, abs_path, requested, options, false);
    // The table owns the started stream and its initial state. If the
    // baseline cannot be built, remove stops delivery before releasing
    // the stream, its names, and counts no other watch needs.
    f.streams.putAssumeCapacity(id, stream);
    errdefer f.remove(id);
    errdefer batch.discard(f.gpa, id);
    const cross_device = f.seedKnown(stream) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Unexpected,
    };
    if (cross_device) {
        if (stream.resume_index != null) return error.InvalidCheckpoint;
        try batch.deferChange(f.gpa, id, stream.root, .overflow, null, stream.rootTarget());
        try f.useLiveStream(id);
        stream = f.streams.get(id).?;
    }
    if (stream.resume_index) |index| {
        const saved = f.restarting.?.state.value.watches[index];
        // Compare the persisted baseline with the walk just taken. A gone
        // path is a deletion even if the daemon never delivers its record.
        // Remembered live names already cover changes racing the walk.
        var saved_paths = saved.baseline.iterator();
        defer saved_paths.deinit();
        while (saved_paths.next()) |subject| {
            if (!stream.wants(subject) or stream.filter.excludes(stream.root, subject)) continue;
            if (f.known.contains(.{ .id = id, .path = subject })) continue;
            const there = f.exists(subject) orelse {
                try batch.deferChange(f.gpa, id, stream.root, .overflow, null, stream.rootTarget());
                continue;
            };
            if (!there) try batch.deferChange(f.gpa, id, subject, .removed, null, .unknown);
        }
        for (saved.changes) |change| {
            try batch.deferChange(f.gpa, id, change.path, change.kind, change.from, change.target);
        }
        if (saved.half) |half| {
            try f.resolveHeld(batch);
            const owned = try f.gpa.dupe(u8, half.path);
            f.pairing.held = .{ .id = id, .path = owned, .flags = half.flags, .event = half.event };
        }
        f.resume_used[index] = true;
    }
    trace.log("fsevents seeded watch={d} known={d}", .{ @intFromEnum(id), f.known.count() });
}

/// Creates and starts a stream, transferring ownership only on success.
/// Seeding happens after start so changes during the walk stay queued.
fn startStream(f: *FsEvents, id: WatchId, abs_path: []const u8, requested: []const u8, options: AddOptions, force_live: bool) contract.AddError!*Stream {
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

    var volume = try Volume.read(f.gpa, stream_path);
    errdefer volume.deinit(f.gpa);
    const resumed = if (force_live) null else f.resumeIndex(requested);
    if (resumed) |index| {
        if (path_cmp.eql(abs_path, requested) and f.restarting.?.state.value.watches[index].recursive != options.recursive) return error.InvalidCheckpoint;
        const identity = volume.identity orelse return error.InvalidCheckpoint;
        if (!Volume.matches(identity, f.restarting.?.state.value.watches[index].identity)) return error.InvalidCheckpoint;
    }
    const since = if (resumed) |index| f.restarting.?.state.value.watches[index].cursor else if (!force_live and volume.identity != null)
        c.FSEventsGetLastEventIdForDeviceBeforeTime(volume.device, c.CFAbsoluteTimeGetCurrent() + 978307200)
    else
        c.FSEventsGetCurrentEventId();
    // Start at the captured boundary, including fresh subscriptions. SinceNow
    // is resolved later by fseventsd and can skip the caller's first write.
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
        .volume = volume,
        .persistent = !force_live and volume.identity != null,
        .root = root,
        .scope = scope,
        .filter = filter,
        .cursor = since,
        .resume_index = resumed,
        .resumed = resumed != null,
        .replayed = null,
    };
    stream.published.store(true, .release);

    trace.log("fsevents add watch={d} scope={s} root={s} stream_path={s}", .{
        @intFromEnum(id), @tagName(scope), abs_path, stream_path,
    });
    stream.ref = try createStream(stream, if (stream.persistent) volume.relative(stream_path) else stream_path, since, f.stream_latency);
    // Invalidation is what unschedules a stream, and it requires one that
    // is scheduled, so this may only run after the line below it.
    errdefer {
        c.FSEventStreamInvalidate(stream.ref);
        c.FSEventStreamRelease(stream.ref);
    }
    c.FSEventStreamSetDispatchQueue(stream.ref, f.queue);
    if (c.FSEventStreamStart(stream.ref) == 0) return error.WatchLimitReached;
    trace.log("fsevents started watch={d} since={d} latency={d} streams={d} latest={d} dev={d} now={d}", .{
        @intFromEnum(id),                            since,
        f.stream_latency,                            f.streams.count() + 1,
        c.FSEventStreamGetLatestEventId(stream.ref), c.FSEventStreamGetDeviceBeingWatched(stream.ref),
        c.FSEventsGetCurrentEventId(),
    });

    return stream;
}

/// Builds the CoreFoundation array FSEvents wants and creates the stream.
fn createStream(
    stream: *Stream,
    subject: []const u8,
    since: u64,
    latency: f64,
) contract.AddError!c.FsEventStreamRef {
    const cf_path = c.CFStringCreateWithBytes(
        null,
        subject.ptr,
        @intCast(subject.len),
        c.cf_string_encoding_utf8,
        0,
    ) orelse return error.SystemResources;
    defer c.CFRelease(cf_path);

    const values: [1]?*const anyopaque = .{cf_path};
    const paths = c.CFArrayCreate(null, &values, 1, c.cf_type_array_call_backs) orelse
        return error.SystemResources;
    defer c.CFRelease(paths);

    var context: c.FsEventStreamContext = .{ .info = stream };
    // `kFSEventStreamCreateFlagFileEvents` is what makes FSEvents name
    // files rather than only the directories containing them.
    // `NoDefer` makes the first event of a burst arrive at once rather
    // than after the latency window, which is what a caller expects from
    // something that already has its own coalescing. `WatchRoot` is what
    // reports the watched path itself being moved.
    const flags: u32 = c.stream_create_flag_file_events |
        c.stream_create_flag_no_defer |
        c.stream_create_flag_watch_root;
    // NoDefer makes the first event immediate; this latency controls how
    // long later events may be collected, matching lookout's own tail.
    return (if (stream.persistent)
        c.FSEventStreamCreateRelativeToDevice(null, deliver, &context, stream.volume.device, paths, since, latency, flags)
    else
        c.FSEventStreamCreate(null, deliver, &context, paths, since, latency, flags)) orelse error.SystemResources;
}

/// A tree crossing a mount needs the host's live namespace. A host cursor
/// cannot be persisted safely. The caller reports the registration gap as
/// loss in its own delivery phase; checkpoints stay unavailable for this watch.
fn useLiveStream(f: *FsEvents, id: WatchId) contract.AddError!void {
    const old = f.streams.get(id).?;
    if (!old.persistent) return;
    const next = try f.startStream(id, old.root, old.root, .{ .recursive = old.scope == .tree, .filter = old.filter }, true);
    f.streams.getPtr(id).?.* = next;
    f.destroy(old);
}

/// Stops watching `id`.
pub fn remove(f: *FsEvents, id: WatchId) void {
    const entry = f.streams.fetchSwapRemove(id) orelse return;
    f.budget.release(*const FsEvents, stillCounted, entry.value.root, f);
    f.forgetWatch(id);
    f.destroy(entry.value);
    // destroy waits for callbacks already running. Only then can the
    // old stream's records be removed without another callback putting
    // them back under the id a pending promotion will reuse.
    if (f.pairing.held) |half| {
        if (half.id == id) {
            f.gpa.free(half.path);
            f.pairing.held = null;
        }
    }
    f.staging.shrinkRetainingCapacity(withoutStream(f.staging.items, id));
    f.sink.lock.acquire();
    defer f.sink.lock.release();
    f.sink.len = withoutStream(f.sink.buffer[0..f.sink.len], id);
}

/// Compacts whole records written by Sink, without allocating or changing
/// the order of other streams' records. Used under the sink lock as well
/// as on the polling thread's retained delivery.
fn withoutStream(bytes: []u8, id: WatchId) usize {
    var it = records.iterate(bytes);
    var kept: usize = 0;
    while (true) {
        const start = it.offset;
        // unreachable: Sink appends only whole records, under the lock its callers hold
        const record = (it.next() catch unreachable) orelse break;
        if (record.id == id) continue;
        const len = it.offset - start;
        @memmove(bytes[kept..][0..len], bytes[start..it.offset]);
        kept += len;
    }
    return kept;
}

/// Replaces the delivery filter, retaining the stream unless newly reached
/// mounts require the host namespace.
pub fn refilter(f: *FsEvents, id: WatchId, next: lookout.Filter, batch: *Batch) contract.RefilterError!void {
    const stream = f.streams.get(id) orelse return error.UnknownWatch;
    const replacement = try next.dupe(f.gpa);
    var previous = stream.filter;
    stream.filter = replacement;
    errdefer {
        stream.filter.deinit(f.gpa);
        stream.filter = previous;
    }
    const cross_device = f.seedKnown(stream) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Unexpected,
    };
    var i: usize = 0;
    while (i < f.known.count()) {
        const key = f.known.keys()[i];
        if (key.id == id and stream.filter.prunes(stream.root, key.path)) {
            f.paths.remove(key.history.?);
            f.known.swapRemoveAt(i);
        } else i += 1;
    }
    const NewlyReached = struct {
        stream: *const Stream,
        old: Filter,

        const Self = @This();

        fn includes(r: Self, dir: []const u8) bool {
            return r.old.prunes(r.stream.root, dir) and
                !r.stream.filter.prunes(r.stream.root, dir);
        }
    };
    f.budget.reread(NewlyReached, NewlyReached.includes, .{ .stream = stream, .old = previous });
    if (cross_device) {
        try batch.deferChange(f.gpa, id, stream.root, .overflow, null, stream.rootTarget());
        try f.useLiveStream(id);
    }
    previous.deinit(f.gpa);
}

/// Whether a watch still held reports the entries of `dir`, so that its
/// count outlives the watch being removed. See `Budget.release`.
fn stillCounted(f: *const FsEvents, dir: []const u8) bool {
    for (f.streams.values()) |stream| {
        const reach = stream.reach() orelse continue;
        if (reach.covers(dir)) return true;
    }
    return false;
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
    stream.volume.deinit(f.gpa);
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
    ref: c.FsEventStreamRef,
    info: ?*anyopaque,
    count: usize,
    paths: ?*anyopaque,
    flags: [*]const u32,
    ids: [*]const u64,
) callconv(.c) void {
    _ = ref;
    const stream: *Stream = @ptrCast(@alignCast(info.?)); // safe: info is the Stream the stream was created with, alive until it is invalidated
    const list: [*]const [*:0]const u8 = @ptrCast(@alignCast(paths.?)); // safe: without kFSEventStreamCreateFlagUseCFTypes, paths is a C array of C strings, count long
    // the handoff from `add`, made visible (`Stream.published`); a stream
    // is published before it is started, so this never drops a delivery
    if (!stream.published.load(.acquire)) return;

    stream.sink.lock.acquire();
    defer stream.sink.lock.release();
    stream.sink.deliveries += 1;
    for (0..count) |i| {
        const subject = std.mem.span(list[i]);
        if (stream.persistent) {
            // The callback cannot allocate. Reserve and encode the two path
            // pieces directly into the bounded sink under its existing lock.
            const prefix = std.mem.trimEnd(u8, stream.volume.prefix, "/");
            const tail = std.mem.trimStart(u8, subject, "/");
            const length = records.encodedVolumePathLen(prefix, tail);
            if (stream.sink.len + length > stream.sink.buffer.len) {
                stream.sink.overflowed = true;
                stream.sink.dropped += 1;
                continue;
            }
            stream.sink.len += records.encodeVolumePath(stream.sink.buffer[stream.sink.len..], stream.id, flags[i], ids[i], prefix, tail);
        } else stream.sink.append(stream.id, flags[i], ids[i], subject);
    }
    stream.sink.signal();
}

/// Waits on the wake pipe until the drain produces something `batch` did
/// not already hold, or `timeout_ms` expires. `null` never gives up.
pub fn wait(f: *FsEvents, batch: *Batch, timeout_ms: ?u32) contract.PollError!void {
    // A drain takes the delivery thread's records and decides what each
    // one was, asking the file system as it goes, so nothing in here is a
    // place to stop: see `Watcher.poll`. The wait itself is out of
    // `std.Io`'s reach.
    const protection = f.io.swapCancelProtection(.blocked);
    defer _ = f.io.swapCancelProtection(protection);
    try f.collect(batch, timeout_ms);
    // Whatever is still held when the wait is over never found its
    // partner, however many deliveries it waited through.
    try f.resolveHeld(batch);
}

fn collect(f: *FsEvents, batch: *Batch, timeout_ms: ?u32) contract.PollError!void {
    const before = batch.revision;
    const deadline: Deadline = .start(f.io, timeout_ms);

    while (true) {
        try f.drain(batch);
        if (f.sink.woken.swap(false, .acquire)) return;
        if (batch.revision != before or f.pairing.held != null) {
            // A rename with no partner yet is worth waiting a moment
            // for: the other half is on its way if the burst was simply
            // longer than one delivery, and deciding now would turn one
            // `renamed` into a removal and a creation.
            var round: usize = 0;
            while (f.pairing.held != null and round < grace_rounds) : (round += 1) {
                if (!f.readable(grace_ms)) break;
                try f.drain(batch);
            }
            // A half alone, its partner not come within the grace, is
            // decided now rather than when the next delivery happens to
            // arrive, which a wait with no deadline could make never: a
            // file saved by a rename and then deleted carries the rename
            // in its flags.
            try f.resolveHeld(batch);
            if (batch.revision != before) return;
        }
        // Clamped rather than returned on, so that a `timeout_ms` of zero
        // still performs one non-blocking check.
        if (!f.readable(deadline.pollMs())) {
            if (!deadline.expired()) continue;
            return;
        }
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
fn drain(f: *FsEvents, batch: *Batch) contract.PollError!void {
    // A failed drain keeps its bytes. Replaying can repeat bookkeeping,
    // which Watcher.poll covers with its conservative recovery notice.
    errdefer f.budget.reread(void, everyDirectory, {});
    var overflowed = f.staging_overflowed;
    var deliveries: usize = 0;
    var dropped: usize = 0;
    if (f.staging.items.len == 0 and !f.staging_overflowed) {
        f.sink.lock.acquire();
        defer f.sink.lock.release();
        overflowed = f.sink.overflowed;
        deliveries = f.sink.deliveries;
        dropped = f.sink.dropped;
        f.staging.appendSlice(f.gpa, f.sink.buffer[0..f.sink.len]) catch {
            // Nothing has left the sink, including its loss notice.
            return error.OutOfMemory;
        };
        f.sink.len = 0;
        f.sink.overflowed = false;
        f.sink.deliveries = 0;
        f.sink.dropped = 0;
        f.staging_overflowed = overflowed;
    }
    if (trace.enabled() and (deliveries != 0 or f.staging.items.len != 0)) {
        trace.log("fsevents drain deliveries={d} bytes={d} dropped={d} overflowed={}", .{
            deliveries, f.staging.items.len, dropped, overflowed,
        });
    }
    if (overflowed) {
        for (f.streams.values()) |stream| {
            // A delivery that did not fit may have carried the sentinel,
            // and a stream waiting for one that was dropped would catch
            // up for ever.
            if (stream.replayed == null) stream.replayed = .now(f.io, .awake);
            try batch.push(f.gpa, stream.id, stream.root, .overflow, stream.rootTarget());
        }
    }

    var delivered: std.ArrayList(Record) = .empty;
    defer delivered.deinit(f.gpa);
    var it = records.iterate(f.staging.items);
    while (true) {
        // The delivery thread writes a whole record under the lock and
        // the drain copies under the same lock, so a tail this cannot
        // decode is not one either of them wrote. What has been decoded
        // is reported; the rest says nothing that can be acted on.
        const record = it.next() catch |err| switch (err) {
            error.TruncatedRecord => break,
        } orelse break;
        trace.log("fsevents record watch={d} event={d} flags=0x{x} path={s}", .{
            @intFromEnum(record.id), record.event, record.flags, record.path,
        });
        try delivered.append(f.gpa, record);
    }

    // Which records a pairing has already spoken for. FSEvents puts
    // both halves of a rename in one delivery but not always next to
    // each other -- the directory they are in can be named between
    // them -- so a partner is looked for anywhere in the delivery and
    // struck off here.
    const used = try f.gpa.alloc(bool, delivered.items.len);
    defer f.gpa.free(used);
    @memset(used, false);

    // The half held from the last drain looks for its partner here.
    try f.rejoin(batch, delivered.items, used);

    // Where the system said it lost track, and of which watch. The paths
    // are slices of `staging`, which lives until the next drain.
    var losses: std.ArrayList(Loss) = .empty;
    defer losses.deinit(f.gpa);

    for (delivered.items, 0..) |_, i| {
        if (used[i]) continue;
        try f.report(batch, delivered.items, used, i, &losses);
    }
    for (delivered.items) |record| {
        if (f.streams.get(record.id)) |stream| stream.cursor = @max(stream.cursor, record.event);
    }

    // What was lost is in no count, so the counts it touched are read
    // again from disk -- see `Budget.reread`. Once the delivery is done
    // and not where the loss was said: the records after that are
    // changes made since, and a re-read made before them would take them
    // in and then count them again from their records.
    if (overflowed) {
        // A delivery that did not fit was every watch's.
        f.budget.reread(void, everyDirectory, {});
    } else if (losses.items.len != 0) {
        f.budget.reread(Losses, Losses.stale, .{ .f = f, .items = losses.items });
    }
    // Mount records belong to the old stream, as do loss pointers above.
    // Replace it only after the delivery and budget rereads finish.
    for (delivered.items) |record| {
        if (record.flags & flag.mount == 0) continue;
        const stream = f.streams.get(record.id) orelse continue;
        if (stream.scope != .tree or !stream.concerns(record.path)) continue;
        if (!stream.persistent) continue;
        try batch.push(f.gpa, record.id, stream.root, .overflow, stream.rootTarget());
        f.useLiveStream(record.id) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Unexpected,
        };
    }
    f.staging.clearRetainingCapacity();
    f.staging_overflowed = false;
}

/// One place the system said it lost track, for one watch.
const Loss = struct {
    stream: *const Stream,
    /// The directory to read again, with everything below it.
    at: []const u8,
};

/// The counts a drain's losses leave wrong: in a directory at or below
/// where the loss was said, and resting on the reads of the watch that
/// lost them. See `Budget.restsOn`.
const Losses = struct {
    f: *const FsEvents,
    items: []const Loss,

    fn stale(losses: Losses, dir: []const u8) bool {
        for (losses.items) |loss| {
            if (!path_cmp.within(loss.at, dir)) continue;
            if (Budget.restsOn(losses.f.streams.values(), loss.stream, dir)) return true;
        }
        return false;
    }
};

fn everyDirectory(_: void, _: []const u8) bool {
    return true;
}

/// Joins the half held from the last drain to its partner in this one,
/// or gives up on it.
fn rejoin(f: *FsEvents, batch: *Batch, delivered: []const Record, used: []bool) contract.PollError!void {
    const taken = f.pairing.take(delivered, used, Asking{ .f = f }) orelse return;
    errdefer {
        f.pairing.held = taken.half;
        if (taken.partner) |at| used[at] = false;
    }
    try f.reportTaken(batch, delivered, taken);
    f.gpa.free(taken.half.path);
}

/// The pairing owns the half until reporting it and its partner succeeds.
fn reportTaken(f: *FsEvents, batch: *Batch, delivered: []const Record, taken: records.Pairing.Taken) contract.PollError!void {
    const at = taken.partner orelse return f.reportHalf(batch, taken.half);
    const stream = f.streams.get(taken.half.id) orelse return f.reportHalf(batch, taken.half);

    const partner = delivered[at];
    const there = f.exists(partner.path) orelse return f.incomplete(batch, stream);
    if (there) {
        try f.joined(batch, stream, partner.path, taken.half.path, partner.target());
    } else {
        try f.joined(batch, stream, taken.half.path, partner.path, partner.target());
    }
    try f.recount(batch, partner.path, .unchanged, stream);
}

/// What the matching in src/backend/fsevents/records.zig asks the
/// watcher about a path: whether it is inside that watch's scope, and
/// whether the file system has it now.
///
/// Scope and not the filter: a rename between a name the filter keeps
/// and one it excludes is still one rename, and which half the caller
/// hears about is decided on the pair -- see `joined`. Refusing the
/// excluded half here left the kept one to be read on its flags alone,
/// and a file saved by renaming an excluded temporary over a watched
/// name carries nothing in them that says it changed.
pub const Asking = struct {
    f: *FsEvents,

    pub fn wanted(a: Asking, id: WatchId, subject: []const u8) bool {
        const stream = a.f.streams.get(id) orelse return false;
        return stream.wants(subject);
    }

    pub fn exists(a: Asking, subject: []const u8) ?bool {
        return a.f.exists(subject);
    }
};

/// Reports one record, pairing it with another of the delivery when it
/// is half of a rename.
fn report(
    f: *FsEvents,
    batch: *Batch,
    delivered: []const Record,
    used: []bool,
    at: usize,
    losses: *std.ArrayList(Loss),
) contract.PollError!void {
    const record = delivered[at];
    const stream = f.streams.get(record.id) orelse {
        trace.log("fsevents drop no-stream watch={d} path={s}", .{ @intFromEnum(record.id), record.path });
        return;
    };
    // Before the scope check, not after it: the path a loss is reported
    // at is the directory to rescan, which the system coalesces upwards,
    // and for a watch on a file that is the parent directory -- a path
    // the watch does not want an event for and cannot afford to ignore
    // a loss at.
    if (record.flags & lost_track != 0 and stream.concerns(record.path)) {
        trace.log("fsevents push overflow root={s} at={s}", .{ stream.root, record.path });
        try batch.push(f.gpa, record.id, stream.root, .overflow, stream.rootTarget());
        try losses.append(f.gpa, .{ .stream = stream, .at = record.path });
    }
    // The marker that the system has finished reading its log back to
    // the captured registration boundary or an explicit checkpoint. Nothing
    // happened to a path, so there is nothing to report; it is swallowed
    // rather than left to look like a change to the watch root. The persisted path baseline, rather than this marker or its
    // arrival time, establishes which missing paths must be reported.
    if (record.flags & flag.history_done != 0) {
        if (stream.replayed == null) stream.replayed = .now(f.io, .awake);
        trace.log("fsevents history done root={s}", .{stream.root});
        return;
    }
    if (!stream.wants(record.path)) {
        trace.log("fsevents drop out-of-scope root={s} path={s}", .{ stream.root, record.path });
        return;
    }
    // The watched path itself moved or vanished. FSEvents reports both
    // against the root with one flag and does not say which, and
    // `lookout.reportsRootMove` is what a caller switches on: it answers
    // `removed` for this backend, and it answers absolutely, so the
    // shape cannot depend on what the file system happens to hold when
    // the delivery is read. Asking whether the root was there made a
    // root deleted and recreated inside one window a `renamed` -- the
    // one shape this backend says it never gives. It is the rule
    // coalescing already has for every other path: removed and
    // recreated inside one window is `removed`, which means look at this
    // path again.
    if (record.flags & flag.root_changed != 0) {
        trace.log("fsevents push removed root={s}", .{stream.root});
        try batch.push(f.gpa, record.id, stream.root, .removed, stream.rootTarget());
        return;
    }

    if (f.unchangedInitial(record) orelse return f.incomplete(batch, stream)) return;

    // A rename is paired before the filter is asked, because the filter
    // is about the two names and the pair is one change: see `joined`.
    if (record.renamed()) {
        if (records.partnerOf(record, delivered, used, at + 1, Asking{ .f = f })) |partner_at| {
            used[partner_at] = true;
            const partner = delivered[partner_at];
            const there = f.exists(partner.path) orelse return f.incomplete(batch, stream);
            if (there) {
                try f.joined(batch, stream, partner.path, record.path, partner.target());
            } else {
                try f.joined(batch, stream, record.path, partner.path, record.target());
            }
            try f.recount(batch, record.path, .unchanged, stream);
            try f.recount(batch, partner.path, .unchanged, stream);
            return;
        }
        // No partner in this delivery. On a name the filter excludes,
        // the half says nothing the caller asked about: were its partner
        // in the next delivery, that half would be read alone as the
        // rename in or out it would have been paired into. It is not
        // held, where it would push out a half that is worth waiting on.
        if (stream.filter.excludes(stream.root, record.path)) {
            trace.log("fsevents drop filtered unpaired path={s}", .{record.path});
            return;
        }
        // It may be in the next one, so the decision waits: calling it
        // now would turn one `renamed` into a removal and a creation on
        // a backend that pairs them.
        try f.hold(batch, record);
        return;
    }

    // The kernel walked the tree whatever the filter says; what the
    // filter can still do is keep the event from the caller.
    if (stream.filter.excludes(stream.root, record.path)) {
        trace.log("fsevents drop filtered path={s}", .{record.path});
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
) contract.PollError!void {
    const seen = f.known.contains(.{ .id = record.id, .path = record.path });
    // A known path with no removal or rename flag, and a newly-created
    // path with neither, are present as far as this record can say. A
    // later removal races any `stat` made here in exactly the same way
    // and will carry its own record. Save the filesystem query for the
    // ambiguous cases: accumulated removal flags and an unknown path
    // whose flags do not say it was created.
    const there = if (needsExistenceCheck(record.flags, seen))
        f.exists(record.path) orelse return f.incomplete(batch, stream)
    else
        true;

    if (!there) {
        // Gone. Whatever the flags remember about it, the fact now is
        // that the path is not there. A path lookout never knew about came
        // and went between two polls, and the tree is as it was.
        if (seen) {
            trace.log("fsevents push removed path={s}", .{record.path});
            try batch.push(f.gpa, record.id, record.path, .removed, record.target());
            f.forget(record.id, record.path);
            if (record.target() == .directory) f.forgetSubtree(record.id, record.path);
            try f.recount(batch, record.path, .vanished, stream);
        } else {
            trace.log("fsevents drop gone-unknown path={s}", .{record.path});
        }
        return;
    }
    if (!seen) {
        trace.log("fsevents push created path={s}", .{record.path});
        try batch.push(f.gpa, record.id, record.path, .created, record.target());
        try f.remember(record.id, record.path);
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
        try f.recount(batch, record.path, .appeared, stream);
        return;
    }
    // Both flags on a path that still exists and was already known mean
    // that the old entry left and another now occupies its name. Removal
    // wins inside a coalescing window so the caller knows to read it anew.
    // A removal alone on a name that is there again means the same: the
    // system recorded the removal before the name was taken again, and
    // the creation, in a later delivery, says nothing a known path does
    // not already say -- a symbolic link replaced in two steps carries
    // no content or metadata flag, and was otherwise not reported at all.
    if (wasReplaced(record.flags) or record.flags & flag.item_removed != 0) {
        trace.log("fsevents push replaced-as-removed path={s}", .{record.path});
        try batch.push(f.gpa, record.id, record.path, .removed, record.target());
        if (record.target() == .directory) try f.refreshKnown(record.id, record.path, stream);
        try f.recount(batch, record.path, .unchanged, stream);
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
        if (record.flags & flag.item_modified != 0) {
            trace.log("fsevents push modified path={s}", .{record.path});
            try batch.push(f.gpa, record.id, record.path, .modified, .file);
        } else if (record.flags & (flag.item_inode_meta_mod |
            flag.item_change_owner |
            flag.item_xattr_mod |
            flag.item_finder_info_mod) != 0)
        {
            trace.log("fsevents push attributes path={s}", .{record.path});
            try batch.push(f.gpa, record.id, record.path, .attributes, .file);
        } else if (record.renamed() and
            record.flags & (flag.item_created | flag.item_removed) == 0)
        {
            // A rename half alone, on a name that was there and still
            // is, and nothing else said about it: something was renamed
            // over the file from a name this watch does not see -- outside
            // it, or excluded by its filter. The file is a new one, and
            // `inotify` and Windows say `created` for the same move.
            trace.log("fsevents push created renamed-over path={s}", .{record.path});
            try batch.push(f.gpa, record.id, record.path, .created, .file);
        } else {
            trace.log("fsevents drop known-no-change path={s}", .{record.path});
        }
    } else {
        trace.log("fsevents drop dir-metadata path={s}", .{record.path});
    }
}

fn needsExistenceCheck(flags: u32, seen: bool) bool {
    // A rename half says the name was left or arrived at and not which,
    // and one that reaches here had no partner to say it: renamed out
    // of the watch leaves the flags of the file that was there, with no
    // removal among them.
    if (flags & (flag.item_removed | flag.item_renamed) != 0) return true;
    return !seen and flags & flag.item_created == 0;
}

fn wasReplaced(flags: u32) bool {
    return flags & (flag.item_removed | flag.item_created) ==
        (flag.item_removed | flag.item_created);
}

/// Reports everything inside a directory that has just appeared, and
/// remembers it.
fn adopt(
    f: *FsEvents,
    batch: *Batch,
    id: WatchId,
    root: []const u8,
    stream: *const Stream,
) contract.PollError!void {
    try f.budget.begin(root);
    defer f.budget.end();
    const Adopting = struct {
        f: *FsEvents,
        batch: *Batch,
        id: WatchId,
        stream: *const Stream,

        const Self = @This();

        fn visit(a: *Self, entry: walk.Entry) anyerror!walk.Step {
            try a.f.budget.found(entry.dir, entry.name);
            if (entry.kind == .directory) try a.f.budget.begin(entry.path);
            if (a.stream.filter.prunes(a.stream.root, entry.path)) return .over;
            if (a.f.known.contains(.{ .id = a.id, .path = entry.path })) return .into;
            if (!a.stream.filter.excludes(a.stream.root, entry.path)) {
                try a.batch.push(a.f.gpa, a.id, entry.path, .created, .of(entry.kind));
            }
            try a.f.remember(a.id, entry.path);
            return .into;
        }
    };
    var adopting: Adopting = .{ .f = f, .batch = batch, .id = id, .stream = stream };
    walk.tree(*Adopting, Adopting.visit, f.gpa, f.io, root, &adopting) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Unexpected,
    };
}

/// Reports one rename, whose two names are both in the watch's scope,
/// and keeps what lookout remembers in step with it.
///
/// The filter is applied to the pair, and a name it excludes is treated
/// exactly as a name outside the watch: both names kept is `renamed`;
/// only the new one kept is `created` there, as a rename in from outside
/// would be; only the old one kept is `removed` there, as a rename out
/// would be; neither is nothing.
///
/// For a rename that stays a rename, everything remembered under the
/// old name is moved to the new one, which is what a byte-for-byte
/// record of a tree gets wrong after a directory is renamed: every path
/// under the old name is still remembered under it, so the first write
/// inside the new name is a path lookout has never seen and is reported
/// as a creation.
fn joined(
    f: *FsEvents,
    batch: *Batch,
    stream: *const Stream,
    to: []const u8,
    from: []const u8,
    target: Target,
) contract.PollError!void {
    const id = stream.id;
    const keeps_to = !stream.filter.excludes(stream.root, to);
    const keeps_from = !stream.filter.excludes(stream.root, from);
    f.budget.forget(from);
    if (keeps_to and keeps_from) {
        trace.log("fsevents push renamed path={s} from={s}", .{ to, from });
        try batch.pushRename(f.gpa, id, to, from, target);
        try f.rekey(id, from, to);
        return;
    }
    // Whatever was remembered under the old name was remembered under a
    // name the caller never heard about, or is about to hear is gone.
    f.forget(id, from);
    if (target == .directory) f.forgetSubtree(id, from);
    if (keeps_to) {
        trace.log("fsevents push created renamed-in path={s} from={s}", .{ to, from });
        try batch.push(f.gpa, id, to, .created, target);
        try f.remember(id, to);
        // As for any directory that arrives with a tree in it: what is
        // inside is as new to the caller as the directory is.
        if (target == .directory and stream.scope == .tree) try f.adopt(batch, id, to, stream);
    } else if (keeps_from) {
        trace.log("fsevents push removed renamed-out path={s} to={s}", .{ from, to });
        try batch.push(f.gpa, id, from, .removed, target);
    } else {
        trace.log("fsevents drop filtered renamed path={s} from={s}", .{ to, from });
    }
}

/// Holds an unpaired rename until the next delivery arrives. Anything
/// already held has waited as long as it is going to.
fn hold(f: *FsEvents, batch: *Batch, record: Record) contract.PollError!void {
    // Copied first: the buffer the record points into is emptied before
    // the next delivery is read, and a dupe that fails must leave what
    // is already held where it was.
    const owned = try f.gpa.dupe(u8, record.path);
    errdefer f.gpa.free(owned);
    try f.resolveHeld(batch);
    trace.log("fsevents hold renamed path={s}", .{record.path});
    f.pairing.held = .{
        .id = record.id,
        .path = owned,
        .flags = record.flags,
        .event = record.event,
    };
}

/// Gives up on a half that never found its partner, at the end of the
/// whole wait rather than at the end of one delivery.
fn resolveHeld(f: *FsEvents, batch: *Batch) contract.PollError!void {
    const half = f.pairing.held orelse return;
    try f.reportHalf(batch, half);
    f.pairing.held = null;
    f.gpa.free(half.path);
}

/// Reports a half that never found its partner: the path was renamed
/// out of the watch, or renamed and then deleted, and what is left is
/// the removal or the creation the other backends would give. A half on
/// a name the filter excludes is never held -- see `report`.
fn reportHalf(f: *FsEvents, batch: *Batch, half: records.Half) contract.PollError!void {
    const stream = f.streams.get(half.id) orelse return;
    trace.log("fsevents unpaired renamed path={s}", .{half.path});
    try f.reportPlain(batch, half.record(), stream);
}

/// Records that a path exists.
fn remember(f: *FsEvents, id: WatchId, subject: []const u8) Allocator.Error!void {
    _ = try f.rememberNew(id, subject);
}

/// Records a path not yet known and returns its slot, in one lookup:
/// seeding does this once per entry of the tree. Null if already known.
fn rememberNew(f: *FsEvents, id: WatchId, subject: []const u8) Allocator.Error!?*?Initial {
    const entry = try f.known.getOrPut(f.gpa, .{ .id = id, .path = subject });
    if (entry.found_existing) return null;
    // The new entry is the last one, still keyed by the borrowed name.
    const node = f.paths.prepare(id, subject) catch |err| {
        _ = f.known.pop();
        return err;
    };
    f.paths.publish(node);
    entry.key_ptr.path = node.path;
    entry.key_ptr.history = node;
    entry.value_ptr.* = null;
    return entry.value_ptr;
}

/// Seeding on an ordinary add is a baseline, not a change to report.
/// `listed` is the metadata the walk read with the name, if it could.
fn rememberInitial(f: *FsEvents, stream: *const Stream, subject: []const u8, listed: ?Initial) !void {
    if (stream.resumed) return f.remember(stream.id, subject);
    const initial = try f.rememberNew(stream.id, subject) orelse return;
    if (listed) |meta| {
        initial.* = meta;
        return;
    }
    const stat = Io.Dir.cwd().statFile(f.io, subject, .{ .follow_symlinks = false }) catch |err| {
        // Gone already, or not remembered at all: drop the entry just made.
        f.paths.remove(f.known.pop().?.key.history.?);
        switch (err) {
            error.FileNotFound, error.NotDir => return,
            else => return err,
        }
    };
    initial.* = .of(stat);
}

/// Old replay flags on an unchanged seeded path say nothing new. A missing
/// path or changed inode, contents or metadata still goes through reporting.
fn unchangedInitial(f: *FsEvents, record: Record) ?bool {
    const entry = f.known.getPtr(.{ .id = record.id, .path = record.path }) orelse return false;
    const initial = entry.* orelse return false;
    const stat = Io.Dir.cwd().statFile(f.io, record.path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            entry.* = null;
            return false;
        },
        else => return null,
    };
    if (std.meta.eql(initial, Initial.of(stat))) return true;
    entry.* = null;
    return false;
}

/// Records that a path does not.
fn forget(f: *FsEvents, id: WatchId, subject: []const u8) void {
    if (f.known.fetchSwapRemove(.{ .id = id, .path = subject })) |entry| {
        f.paths.remove(entry.key.history.?);
    }
}

/// Forgets everything remembered under a subtree that has gone.
fn forgetSubtree(f: *FsEvents, id: WatchId, root: []const u8) void {
    var i: usize = 0;
    while (i < f.known.count()) {
        const key = f.known.keys()[i];
        if (key.id == id and path_cmp.within(root, key.path)) {
            f.paths.remove(key.history.?);
            f.known.swapRemoveAt(i);
        } else {
            i += 1;
        }
    }
}

fn forgetWatch(f: *FsEvents, id: WatchId) void {
    var i: usize = 0;
    while (i < f.known.count()) {
        if (f.known.keys()[i].id != id) {
            i += 1;
            continue;
        }
        f.paths.remove(f.known.keys()[i].history.?);
        f.known.swapRemoveAt(i);
    }
}

fn refreshKnown(
    f: *FsEvents,
    id: WatchId,
    root: []const u8,
    stream: *const Stream,
) contract.PollError!void {
    f.forgetSubtree(id, root);
    try f.remember(id, root);

    const Refreshing = struct {
        f: *FsEvents,
        id: WatchId,
        stream: *const Stream,

        const Self = @This();

        fn visit(r: *Self, entry: walk.Entry) anyerror!walk.Step {
            if (r.stream.filter.prunes(r.stream.root, entry.path)) return .over;
            try r.f.remember(r.id, entry.path);
            return .into;
        }
    };
    var refreshing: Refreshing = .{ .f = f, .id = id, .stream = stream };
    walk.tree(*Refreshing, Refreshing.visit, f.gpa, f.io, root, &refreshing) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Unexpected,
    };
}

/// Moves everything remembered under `old` to sit under `new`, which is
/// what a directory rename does to a tree.
fn rekey(f: *FsEvents, id: WatchId, old: []const u8, new: []const u8) Allocator.Error!void {
    const Move = struct { before: []const u8, after: *CheckpointPaths.Node };
    var moved: std.ArrayList(Move) = .empty;
    var committed = false;
    defer {
        if (!committed) for (moved.items) |move| f.paths.discard(move.after);
        moved.deinit(f.gpa);
    }

    // Keep the remembered names available until every replacement path
    // and the map capacity have been allocated. Publishing cannot fail.
    for (f.known.keys()) |key| {
        if (key.id != id) continue;
        const rest = path_cmp.relative(old, key.path) orelse continue;
        const renamed = if (rest.len == 0)
            try f.gpa.dupe(u8, new)
        else
            try std.fs.path.join(f.gpa, &.{ new, rest });
        errdefer f.gpa.free(renamed);
        const node = try f.paths.prepareOwned(id, renamed);
        errdefer f.paths.gpa.destroy(node);
        try moved.append(f.gpa, .{ .before = key.path, .after = node });
    }
    try f.known.ensureUnusedCapacity(f.gpa, moved.items.len);
    for (moved.items) |move| {
        const removed = f.known.fetchSwapRemove(.{ .id = id, .path = move.before }).?;
        f.paths.remove(removed.key.history.?);
        const key: KnownKey = .{ .id = id, .path = move.after.path, .history = move.after };
        if (f.known.contains(key)) {
            f.paths.discard(move.after);
        } else {
            f.paths.publish(move.after);
            f.known.putAssumeCapacity(key, null);
        }
    }
    committed = true;
}

/// Walks a watch once, so that everything already there is known and the
/// first thing to happen to it is not reported as its creation.
///
/// Names and initial metadata only: no descriptor is kept, which is the
/// difference between this and what the `kqueue` backend has to do.
fn seedKnown(f: *FsEvents, stream: *const Stream) !bool {
    // The root itself, before anything below it: FSEvents names the
    // watched path as readily as it names an entry, and a path the
    // backend has never heard of is a path it reports as created. This
    // is the whole of the seeding for a watch on a single file.
    try f.rememberInitial(stream, stream.root, null);
    if (stream.scope == .file) return false;
    try f.budget.begin(stream.root);
    defer f.budget.end();
    trace.log("fsevents seed walk root={s}", .{stream.root});

    const Seeding = struct {
        f: *FsEvents,
        stream: *const Stream,
        cross_device: bool = false,

        const Self = @This();

        fn visit(s: *Self, entry: walk.Entry) anyerror!walk.Step {
            try s.f.budget.found(entry.dir, entry.name);
            if (entry.kind == .directory) try s.f.budget.begin(entry.path);
            if (s.stream.filter.prunes(s.stream.root, entry.path)) {
                trace.log("fsevents seed filtered {s}", .{entry.path});
                return .over;
            }
            if (entry.kind == .directory and s.stream.scope == .tree) {
                const name = try s.f.gpa.dupeZ(u8, entry.path);
                defer s.f.gpa.free(name);
                const device = Volume.deviceOf(name) orelse {
                    s.cross_device = true;
                    return .over;
                };
                if (device != s.stream.volume.device) s.cross_device = true;
            }
            trace.log("fsevents seed remembered {s}", .{entry.path});
            try s.f.rememberInitial(s.stream, entry.path, entry.meta);
            return if (s.stream.scope == .tree) .into else .over;
        }
    };
    var seeding: Seeding = .{ .f = f, .stream = stream };
    try walk.treeWithMeta(*Seeding, Seeding.visit, f.gpa, f.io, stream.root, &seeding);
    return seeding.cross_device;
}

/// Unknown is distinct from absent: it cannot decide a rename or removal.
fn exists(f: *const FsEvents, subject: []const u8) ?bool {
    _ = Io.Dir.cwd().statFile(f.io, subject, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => return null,
    };
    return true;
}

fn incomplete(f: *FsEvents, batch: *Batch, stream: *const Stream) Allocator.Error!void {
    try batch.push(f.gpa, stream.id, stream.root, .overflow, stream.rootTarget());
}

test "FSEvents refuses a watch whose initial names could not be remembered" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "sub/deep");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "sub/deep/kept", .data = "x" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    defer gpa.free(root);
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        var f = try FsEvents.init(gpa, testing.io, .{});
        defer f.deinit();
        f.gpa = failing.allocator();
        f.budget.gpa = failing.allocator();
        var batch = Batch.init(testing.io, .{});
        defer batch.deinit(gpa);
        if (f.add(@enumFromInt(0), root, .{ .recursive = true }, &batch)) |_| {
            if (failing.has_induced_failure) std.debug.print("add succeeded after allocation {d} failed, with {d} remembered names\n", .{ fail_index, f.known.count() });
            try testing.expectEqual(false, failing.has_induced_failure);
            try testing.expectEqual(@as(usize, 4), f.known.count());
            break;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(@as(usize, 0), f.streams.count());
            try testing.expectEqual(@as(usize, 0), f.known.count());
            try testing.expectEqual(@as(usize, 0), f.budget.counts.count());
        }
    }
}

test "seeding remembers each entry with the metadata an lstat reads" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "sub/deep");
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/deep/kept", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "top", .data = "contents" });
    try tmp.dir.symLink(io, "top", "sub/link", .{});
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    var f = try FsEvents.init(gpa, io, .{});
    defer f.deinit();
    var batch = Batch.init(io, .{});
    defer batch.deinit(gpa);
    try f.add(@enumFromInt(0), root, .{ .recursive = true }, &batch);
    // A replayed record is compared with a later lstat: the seeded value
    // must be exactly what that lstat reads for an unchanged entry.
    try testing.expectEqual(@as(usize, 6), f.known.count());
    for (f.known.keys(), f.known.values()) |key, initial| {
        const stat = try Io.Dir.cwd().statFile(io, key.path, .{ .follow_symlinks = false });
        try testing.expectEqual(Initial.of(stat), initial.?);
    }
}

test "removing an FSEvents stream releases its unreported delivery state" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    defer gpa.free(root);
    var f = try FsEvents.init(gpa, testing.io, .{});
    defer f.deinit();
    var batch = Batch.init(testing.io, .{});
    defer batch.deinit(gpa);
    const gone: WatchId = @enumFromInt(0);
    const kept: WatchId = @enumFromInt(1);
    try f.add(gone, root, .{}, &batch);
    try f.add(kept, root, .{}, &batch);
    // This test owns the two records below. Stop and join native replay
    // callbacks before constructing that exact delivery.
    c.FSEventStreamStop(f.streams.get(gone).?.ref);
    c.FSEventStreamStop(f.streams.get(kept).?.ref);
    c.dispatch_sync_f(f.queue, null, settled);
    f.sink.lock.acquire();
    f.sink.len = 0;
    f.sink.overflowed = false;
    f.sink.lock.release();
    // A stopped pending registration can be replaced under the same id.
    // Its buffered records and rename half belong to the old stream.
    f.sink.lock.acquire();
    f.sink.append(gone, flag.item_created, 1, root);
    f.sink.append(kept, flag.item_modified, 2, root);
    f.sink.lock.release();
    try f.staging.resize(gpa, 2 * records.encodedLen(root));
    const first = records.encode(f.staging.items, gone, flag.item_created, 3, root);
    _ = records.encode(f.staging.items[first..], kept, flag.item_modified, 4, root);
    f.pairing.held = .{ .id = gone, .path = try gpa.dupe(u8, root), .flags = flag.item_renamed, .event = 5 };
    f.remove(gone);
    try testing.expectEqual(@as(?records.Half, null), f.pairing.held);
    const held = try f.copyHeld(gpa);
    defer gpa.free(held.bytes);
    for ([_][]const u8{ held.bytes, f.staging.items }) |bytes| {
        var it = records.iterate(bytes);
        const record = (try it.next()).?;
        try testing.expectEqual(kept, record.id);
        try testing.expectEqual(@as(?Record, null), try it.next());
    }
    try f.add(gone, root, .{}, &batch);
    try f.drain(&batch);
    for (batch.events.items) |event| try testing.expect(event.id != gone);
}

/// Keeps the entry budget of the directory a change happened in, and
/// reports `lookout.Kind.overflow` when it is past.
///
/// Every stream the change is in hands over its own record of it -- two
/// watches over one folder, or a pending watch parked in a folder another
/// watch holds -- and counting each record reached the budget at a
/// fraction of the folder's size. One record counts, chosen by
/// `Budget.counter`, and when that takes the directory past the budget
/// every watch the change reached is told.
fn recount(
    f: *FsEvents,
    batch: *Batch,
    subject: []const u8,
    move: Budget.Move,
    stream: *const Stream,
) contract.PollError!void {
    const change: Change = .{
        .dir = std.fs.path.dirname(subject) orelse return,
        .subject = subject,
    };
    const counting = Budget.counter(*Stream, Change, Change.reaches, f.streams.values(), change) orelse return;
    if (counting != stream) return;
    if (!try f.budget.note(change.dir, std.fs.path.basename(subject), move)) return;
    for (f.streams.values()) |other| {
        if (!change.reaches(other)) continue;
        try batch.push(f.gpa, other.id, other.root, .overflow, other.rootTarget());
    }
}

/// One change to an entry, as every stream it is in hands over its own
/// record of it.
const Change = struct {
    /// The directory the entry is in.
    dir: []const u8,
    subject: []const u8,

    /// Whether `stream` reports this change as one of the entries of a
    /// directory it reports: the directory is in its reach, the entry in
    /// its scope, and its filter keeps it. A watch's own root is not an
    /// entry of anything it reports, and neither is a watched file. See
    /// `Stream.reach`.
    fn reaches(change: Change, stream: *Stream) bool {
        const reach = stream.reach() orelse return false;
        return reach.covers(change.dir) and
            stream.wants(change.subject) and
            !stream.filter.excludes(stream.root, change.subject);
    }
};

test "accumulated removal and creation flags identify a replacement" {
    try std.testing.expect(wasReplaced(flag.item_removed | flag.item_created));
    try std.testing.expect(wasReplaced(
        flag.item_removed | flag.item_created | flag.item_modified,
    ));
    try std.testing.expect(!wasReplaced(flag.item_removed));
    try std.testing.expect(!wasReplaced(flag.item_created | flag.item_modified));
}

test "only ambiguous plain records query the filesystem" {
    try std.testing.expect(!needsExistenceCheck(flag.item_created, false));
    try std.testing.expect(!needsExistenceCheck(flag.item_created | flag.item_modified, true));
    try std.testing.expect(!needsExistenceCheck(flag.item_modified, true));
    try std.testing.expect(needsExistenceCheck(flag.item_modified, false));
    try std.testing.expect(needsExistenceCheck(flag.item_removed, true));
    try std.testing.expect(needsExistenceCheck(flag.item_removed | flag.item_created, true));
    try std.testing.expect(needsExistenceCheck(flag.item_renamed, true));
    try std.testing.expect(needsExistenceCheck(flag.item_renamed | flag.item_created | flag.item_modified, true));
}

test "stream latency follows the watcher latency" {
    try std.testing.expectEqual(@as(f64, 0.0), latencySeconds(0));
    try std.testing.expectEqual(@as(f64, 0.05), latencySeconds(50));
    try std.testing.expectEqual(@as(f64, 1.5), latencySeconds(1_500));
}

/// One record of a delivery made by hand.
const Synthetic = struct { path: []const u8, flags: u32, event: ?u64 = null };

/// Makes the delivery the system would make for `items`, through the
/// callback it would call and into the buffer that callback writes.
/// Nothing between the system's queue and `drain` is bypassed.
fn synthesize(gpa: Allocator, stream: *Stream, items: []const Synthetic) !void {
    var paths: [4][*:0]const u8 = undefined;
    var flags: [4]u32 = undefined;
    var ids: [4]u64 = undefined;
    var filled: usize = 0;
    defer for (paths[0..filled]) |path| gpa.free(std.mem.span(path));
    for (items) |item| {
        paths[filled] = try gpa.dupeZ(u8, if (stream.persistent) stream.volume.relative(item.path) else item.path);
        flags[filled] = item.flags;
        ids[filled] = item.event orelse c.FSEventsGetCurrentEventId();
        filled += 1;
    }
    deliver(stream.ref, stream, filled, @ptrCast(&paths), &flags, &ids); // safe: the same C array of C strings FSEvents hands deliver
}

/// Polls until one `overflow` arrives, checks it against the watch it is
/// for, and then that no second one follows it.
/// The CoreFoundation, CoreServices and libdispatch surface lookout uses.
///
/// Hand-written rather than `@cImport`ed: this is nine functions and a
/// handful of constants against a stable system ABI, and declaring them
/// here keeps the package free of a C compilation step.
const c = struct {
    // Apple's names, in Zig's casing: `CFStringRef` is `CfStringRef` and
    // `kFSEventStreamCreateFlagNoDefer` is `stream_create_flag_no_defer`.
    // Functions keep their symbol names.
    const CfAllocatorRef = ?*anyopaque;
    const CfStringRef = *anyopaque;
    const CfArrayRef = *anyopaque;
    const FsEventStreamRef = *anyopaque;
    const dispatch_queue_t = *anyopaque;

    const cf_string_encoding_utf8: u32 = 0x0800_0100;

    const stream_create_flag_no_defer: u32 = 0x00000002;
    const stream_create_flag_watch_root: u32 = 0x00000004;
    const stream_create_flag_file_events: u32 = 0x00000010;

    /// Darwin's `fcntl` commands and flag, for the delivery pipe.
    const f_getfl: c_int = 3;
    const f_setfl: c_int = 4;
    const o_nonblock: c_int = 0x0004;

    const FsEventStreamContext = extern struct {
        version: c_long = 0,
        info: ?*anyopaque = null,
        retain: ?*const anyopaque = null,
        release: ?*const anyopaque = null,
        copyDescription: ?*const anyopaque = null,
    };

    const FsEventStreamCallback = *const fn (
        stream: FsEventStreamRef,
        info: ?*anyopaque,
        num_events: usize,
        event_paths: ?*anyopaque,
        event_flags: [*]const u32,
        event_ids: [*]const u64,
    ) callconv(.c) void;

    const cf_type_array_call_backs = @extern(*const anyopaque, .{ .name = "kCFTypeArrayCallBacks" });

    extern "c" fn CFStringCreateWithBytes(
        alloc: CfAllocatorRef,
        bytes: [*]const u8,
        num_bytes: c_long,
        encoding: u32,
        is_external_representation: u8,
    ) ?CfStringRef;
    extern "c" fn CFArrayCreate(
        allocator: CfAllocatorRef,
        values: [*]const ?*const anyopaque,
        num_values: c_long,
        call_backs: ?*const anyopaque,
    ) ?CfArrayRef;
    extern "c" fn CFRelease(cf: *anyopaque) void;

    extern "c" fn FSEventStreamCreate(
        allocator: CfAllocatorRef,
        callback: FsEventStreamCallback,
        context: ?*FsEventStreamContext,
        paths_to_watch: CfArrayRef,
        since_when: u64,
        latency: f64,
        flags: u32,
    ) ?FsEventStreamRef;
    extern "c" fn FSEventStreamSetDispatchQueue(stream: FsEventStreamRef, q: ?dispatch_queue_t) void;
    extern "c" fn FSEventStreamStart(stream: FsEventStreamRef) u8;
    extern "c" fn FSEventStreamGetLatestEventId(stream: FsEventStreamRef) u64;
    pub extern "c" fn FSEventStreamGetDeviceBeingWatched(stream: FsEventStreamRef) i32;
    extern "c" fn FSEventsGetCurrentEventId() u64;
    extern "c" fn FSEventsGetLastEventIdForDeviceBeforeTime(device: i32, time: f64) u64;
    extern "c" fn CFAbsoluteTimeGetCurrent() f64;
    extern "c" fn FSEventStreamCreateRelativeToDevice(allocator: CfAllocatorRef, callback: FsEventStreamCallback, context: ?*FsEventStreamContext, device: i32, paths: CfArrayRef, since: u64, latency: f64, flags: u32) ?FsEventStreamRef;
    pub extern "c" fn FSEventStreamStop(stream: FsEventStreamRef) void;
    extern "c" fn FSEventStreamInvalidate(stream: FsEventStreamRef) void;
    extern "c" fn FSEventStreamRelease(stream: FsEventStreamRef) void;

    extern "c" fn dispatch_queue_create(label: ?[*:0]const u8, attr: ?*anyopaque) ?dispatch_queue_t;
    extern "c" fn dispatch_release(object: *anyopaque) void;
    pub extern "c" fn dispatch_sync_f(
        queue: dispatch_queue_t,
        context: ?*anyopaque,
        work: *const fn (?*anyopaque) callconv(.c) void,
    ) void;
};

test "a failed FSEvents rekey keeps every remembered name" {
    const testing = std.testing;
    const id: WatchId = @enumFromInt(0);
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        var backend = try FsEvents.init(testing.allocator, testing.io, .{});
        defer backend.deinit();
        try backend.remember(id, "/old");
        try backend.remember(id, "/old/child");
        backend.gpa = failing.allocator();
        backend.paths.gpa = failing.allocator();
        defer backend.gpa = testing.allocator;
        defer backend.paths.gpa = testing.allocator;
        if (backend.rekey(id, "/old", "/new")) |_| {
            try testing.expect(backend.known.contains(.{ .id = id, .path = "/new" }));
            try testing.expect(backend.known.contains(.{ .id = id, .path = "/new/child" }));
            break;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(@as(usize, 2), backend.known.count());
            try testing.expect(backend.known.contains(.{ .id = id, .path = "/old" }));
            try testing.expect(backend.known.contains(.{ .id = id, .path = "/old/child" }));
            try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        }
    }
}

test "allocation failure during delivery retains FSEvents bytes and position" {
    const testing = std.testing;
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        defer testing.allocator.free(root);
        const first = try std.fs.path.join(testing.allocator, &.{ root, "first" });
        defer testing.allocator.free(first);
        const last = try std.fs.path.join(testing.allocator, &.{ root, "last" });
        defer testing.allocator.free(last);
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        var f = try FsEvents.init(failing.allocator(), testing.io, .{ .latency_ms = 0 });
        defer f.deinit();
        var batch = Batch.init(testing.io, .{});
        defer batch.deinit(failing.allocator());
        const id: WatchId = @enumFromInt(0);
        try f.add(id, root, .{}, &batch);
        // No disk changes after registration: only this synthetic delivery.
        try synthesize(testing.allocator, f.streams.get(id).?, &.{
            .{ .path = first, .flags = flag.item_created },
            .{ .path = last, .flags = flag.item_created },
        });
        const before = f.streams.get(id).?.cursor;
        failing.fail_index = failing.alloc_index + fail_index;
        const answer = f.drain(&batch);
        failing.fail_index = std.math.maxInt(usize);
        if (answer) |_| break else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(before, f.streams.get(id).?.cursor);
        }
        try f.drain(&batch);
        var saw_first = false;
        var saw_last = false;
        for (batch.events.items) |event| {
            if (std.mem.eql(u8, event.path, first)) saw_first = true;
            if (std.mem.eql(u8, event.path, last)) saw_last = true;
        }
        try testing.expect(saw_first and saw_last);
    }
    try testing.expect(fail_index > 0);
}

test "a file stream accepts the replay sentinel outside its event scope" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "file", .data = "one" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, "file", gpa);
    defer gpa.free(root);
    const parent = std.fs.path.dirname(root).?;
    var backend = try FsEvents.init(gpa, testing.io, .{});
    defer backend.deinit();
    var batch = Batch.init(testing.io, .{});
    defer batch.deinit(gpa);
    const id: WatchId = @enumFromInt(0);
    try backend.add(id, root, .{}, &batch);
    const stream = backend.streams.get(id).?;
    stream.resumed = true;
    try synthesize(gpa, stream, &.{.{ .path = parent, .flags = flag.history_done }});
    try backend.drain(&batch);
    if (stream.replayed == null) std.debug.print("file replay sentinel discarded root={s} parent={s} scope={s}\n", .{ root, parent, @tagName(stream.scope) });
    try testing.expect(stream.replayed != null);
    try testing.expectEqual(@as(usize, 0), batch.events.items.len);
}

// Integration fixtures use the adapter’s own callback and native declarations.
pub const test_access = if (builtin.is_test) struct {
    pub const Asking = AskingFixture;
    pub const append = Sink.append;
    pub const signal = Sink.signal;
    pub const acquire = SpinLock.acquire;
    pub const c = cAccess;
    pub const drain = drainFixture;
    pub const hold = holdFixture;
    pub const readable = readableFixture;
    pub const rejoin = rejoinFixture;
    pub const release = SpinLock.release;
    pub const reportPlain = reportPlainFixture;
    pub const resolveHeld = resolveHeldFixture;
    pub const settled = settledFixture;
    pub const synthesize = synthesizeFixture;
} else struct {};
const synthesizeFixture = synthesize;

const AskingFixture = Asking;

const settledFixture = settled;

const cAccess = c;

const readableFixture = readable;

const drainFixture = drain;

const rejoinFixture = rejoin;

const reportPlainFixture = reportPlain;

const holdFixture = hold;

const resolveHeldFixture = resolveHeld;
