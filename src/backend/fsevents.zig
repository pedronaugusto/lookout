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
//! * FSEvents coalesces on its own, before lookout sees anything. Its
//!   stream uses `lookout.Options.latency_ms` for that window and
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

const lookout = @import("../lookout.zig");
const Batch = @import("../Batch.zig");
const Budget = @import("../Budget.zig");
const Deadline = @import("../Deadline.zig");
const Filter = @import("../Filter.zig");
const buffer = @import("../buffer.zig");
const path_cmp = @import("../path.zig");
const records = @import("fsevents_records.zig");
const trace = @import("../trace.zig");
const walk = @import("../walk.zig");
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
/// How many entries each watched directory holds, against
/// `lookout.Options.max_dir_entries`.
budget: Budget,
/// Where every stream is started from: `since_now`, or the event id a
/// caller kept from an earlier watcher. See `lookout.Options.since`.
since: u64,
/// Greatest FSEvents id this watcher has successfully drained.
last_drained: u64,
/// Every path each watch believes exists, seeded by walking the watch
/// when it is added and kept current from what it reports. Path keys are
/// owned here and compared the way the file system compares them.
///
/// This is the price of FSEvents' flags. They are not a sequence of
/// things that happened: FSEvents keeps them per path and does not clear
/// them, so a file created an hour ago and written now still arrives
/// with `ItemCreated` set beside `ItemModified`, and no reading of the
/// flags alone can tell a creation from a write. What can tell them
/// apart is whether lookout has seen the path before. It costs one string
/// per watched file -- still nothing against `kqueue`'s descriptor per
/// watched file, which is the comparison that matters on this platform.
known: std.ArrayHashMapUnmanaged(KnownKey, void, KnownKeyContext, true),
/// The half of a rename whose partner has not been delivered yet. The
/// path it holds is owned here -- see `records.Half`.
pairing: records.Pairing,
/// FSEvents' coalescing window, in seconds. The stream takes the same
/// window as `lookout.Options.latency_ms`; `NoDefer` still makes its
/// first event immediate.
stream_latency: f64,

const KnownKey = struct {
    id: WatchId,
    path: []const u8,
};

const KnownKeyContext = struct {
    pub fn hash(_: KnownKeyContext, key: KnownKey) u32 {
        const mixed = path_cmp.hash(key.path) ^
            (@as(u64, @intFromEnum(key.id)) *% 0x9e3779b97f4a7c15);
        return @truncate(mixed);
    }

    pub fn eql(_: KnownKeyContext, a: KnownKey, b: KnownKey, _: usize) bool {
        return a.id == b.id and path_cmp.eql(a.path, b.path);
    }
};

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

/// How long after the end of the system's log a resumed stream is still
/// hearing about the gap. See `Stream.catchingUp`.
///
/// Nothing marks the end of a replay, so this is a window and not a
/// signal. Measured on a loaded machine, the last of the tail arrived
/// some two hundred milliseconds after the sentinel; a second is four
/// times that, and being generous costs only this -- a path created and
/// deleted inside the window that lookout never knew about is reported
/// as removed rather than dropped. It is paid once, by a watcher that
/// asked to be told what it missed.
const replay_tail_ms = 1_000;

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

    /// Written here and read back in `drain`, both through
    /// src/backend/fsevents_records.zig, which is where the layout is
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
    /// Whether this stream was started from a position rather than from
    /// now, which `lookout.Options.since` asked for. See `catchingUp`.
    resumed: bool,
    /// When `HistoryDone` arrived, or `null` while the system is still
    /// reading its log. See `catchingUp`.
    replayed: ?Io.Timestamp,

    const Scope = enum {
        /// Everything under `root`.
        tree,
        /// `root` and its immediate entries.
        directory,
        /// Only `root` itself. The stream is created on the parent
        /// directory, because FSEvents watches directories.
        file,
    };

    /// Whether this stream is still catching up on what happened
    /// before it existed, which `lookout.Options.since` asked for.
    ///
    /// It changes what a path that is not there means. In the ordinary
    /// way, a path FSEvents names that is gone and that lookout has
    /// never seen came and went between two polls, and the tree is as
    /// it was, so there is nothing to report. While catching up the
    /// same two facts mean the opposite: the path was there at the
    /// position the caller resumed from and is not there now, which is
    /// exactly the deletion they asked to be told about.
    ///
    /// Two things end it, and neither on its own is the answer.
    /// `HistoryDone` says the system has finished reading its log, not
    /// that the replay is over: a change made while nothing was
    /// watching that had not reached the log when the stream started is
    /// delivered after the sentinel, live and numbered after it. And a
    /// wait that reported nothing is not a wait the system was silent
    /// through -- the sentinel is itself a delivery that reports no
    /// event, and so is a poll that expires before the stream has said
    /// anything at all. Ending on either of those ended the catching up
    /// one delivery before the changes it was there to explain, and a
    /// file deleted in the gap was dropped as one that came and went
    /// between two polls.
    ///
    /// So it ends `replay_tail_ms` after the sentinel, and it is asked
    /// of each record as the record is read rather than being flipped
    /// on a wait boundary.
    fn catchingUp(st: *const Stream, io: Io) bool {
        if (!st.resumed) return false;
        const sentinel = st.replayed orelse return true;
        return sentinel.durationTo(.now(io, .awake)).toMilliseconds() < replay_tail_ms;
    }

    fn wants(st: *const Stream, subject: []const u8) bool {
        const rest = path_cmp.relative(st.root, subject) orelse return false;
        if (rest.len == 0) return true;
        if (st.scope == .file) return false;
        if (st.scope == .tree) return true;
        return std.mem.indexOfAny(u8, rest, path_cmp.separators) == null;
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

    const since = sinceOf(options.since);
    return .{
        .gpa = gpa,
        .io = io,
        .queue = queue,
        .sink = sink,
        .streams = .empty,
        .staging = .empty,
        .budget = .init(gpa, io, options.max_dir_entries),
        .since = since,
        .last_drained = if (since == c.kFSEventStreamEventIdSinceNow)
            c.FSEventsGetCurrentEventId()
        else
            since,
        .known = .empty,
        .pairing = .{},
        .stream_latency = latencySeconds(options.latency_ms),
    };
}

fn latencySeconds(milliseconds: u32) f64 {
    return @as(f64, @floatFromInt(milliseconds)) / std.time.ms_per_s;
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
    for (f.known.keys()) |key| f.gpa.free(key.path);
    f.known.deinit(f.gpa);
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

/// The greatest event id this watcher has drained, which
/// `lookout.Options.since` takes back. See `lookout.Watcher.position`.
pub fn position(f: *const FsEvents) ?u64 {
    return f.last_drained;
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
        .resumed = f.since != c.kFSEventStreamEventIdSinceNow,
        .replayed = null,
    };

    trace.log("fsevents add watch={d} scope={s} root={s} stream_path={s}", .{
        @intFromEnum(id), @tagName(scope), abs_path, stream_path,
    });
    stream.ref = try createStream(stream, stream_path, f.since, f.stream_latency);
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
        f.stream_latency,                            f.streams.count() + 1,
        c.FSEventStreamGetLatestEventId(stream.ref), c.FSEventStreamGetDeviceBeingWatched(stream.ref),
        c.FSEventsGetCurrentEventId(),
    });

    f.streams.putAssumeCapacity(id, stream);
    f.seedKnown(stream) catch {};
    trace.log("fsevents seeded watch={d} known={d}", .{ @intFromEnum(id), f.known.count() });
}

/// Builds the CoreFoundation array FSEvents wants and creates the stream.
fn createStream(
    stream: *Stream,
    subject: []const u8,
    since: u64,
    latency: f64,
) lookout.Watcher.AddError!c.FSEventStreamRef {
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
    // NoDefer makes the first event immediate; this latency controls how
    // long later events may be collected, matching lookout's own tail.
    return c.FSEventStreamCreate(null, deliver, &context, paths, since, latency, flags) orelse
        error.SystemResources;
}

/// Stops watching `id`.
pub fn remove(f: *FsEvents, id: WatchId) void {
    const entry = f.streams.fetchSwapRemove(id) orelse return;
    f.budget.forget(entry.value.root);
    f.forgetWatch(id);
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
    // A drain takes the delivery thread's records and decides what each
    // one was, asking the file system as it goes, so nothing in here is a
    // place to stop: see `Watcher.poll`. The wait itself is out of
    // `std.Io`'s reach.
    const protection = f.io.swapCancelProtection(.blocked);
    defer _ = f.io.swapCancelProtection(protection);
    const result = f.collect(batch, timeout_ms);
    // Whatever is still held when the wait is over never found its
    // partner, however many deliveries it waited through.
    try f.resolveHeld(batch);
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
            while (f.pairing.held != null and round < grace_rounds) : (round += 1) {
                if (!f.readable(grace_ms)) break;
                try f.drain(batch);
            }
            return;
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

    for (delivered.items, 0..) |_, i| {
        if (used[i]) continue;
        try f.report(batch, delivered.items, used, i);
    }
    for (delivered.items) |record| f.last_drained = @max(f.last_drained, record.event);
}

/// Joins the half held from the last drain to its partner in this one,
/// or gives up on it.
fn rejoin(f: *FsEvents, batch: *Batch, delivered: []const Record, used: []bool) lookout.Watcher.PollError!void {
    const taken = f.pairing.take(delivered, used, Asking{ .f = f }) orelse return;
    defer f.gpa.free(taken.half.path);
    const at = taken.partner orelse return f.reportHalf(batch, taken.half);
    const stream = f.streams.get(taken.half.id) orelse return f.reportHalf(batch, taken.half);

    const partner = delivered[at];
    if (f.exists(partner.path)) {
        try f.joined(batch, taken.half.id, partner.path, taken.half.path, partner.target());
    } else {
        try f.joined(batch, taken.half.id, taken.half.path, partner.path, partner.target());
    }
    try f.recount(batch, partner.path, .unchanged, stream);
}

/// What the matching in src/backend/fsevents_records.zig asks the
/// watcher about a path: whether an event for it would be reported
/// against that watch at all, and whether the file system has it now.
const Asking = struct {
    f: *FsEvents,

    pub fn wanted(a: Asking, id: WatchId, subject: []const u8) bool {
        const stream = a.f.streams.get(id) orelse return false;
        if (!stream.wants(subject)) return false;
        return !stream.filter.excludes(stream.root, subject);
    }

    pub fn exists(a: Asking, subject: []const u8) bool {
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
) lookout.Watcher.PollError!void {
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
    }
    if (!stream.wants(record.path)) {
        trace.log("fsevents drop out-of-scope root={s} path={s}", .{ stream.root, record.path });
        return;
    }
    // The marker that the system has finished reading its log back to
    // the position `lookout.Options.since` named. Nothing happened to a
    // path, so there is nothing to report; it is declared and swallowed
    // rather than left to look like a change to the watch root. What it
    // is kept for is `Stream.catchingUp`, which measures the tail that
    // still follows it from here.
    if (record.flags & flag.history_done != 0) {
        if (stream.replayed == null) stream.replayed = .now(f.io, .awake);
        trace.log("fsevents history done root={s}", .{stream.root});
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

    // The kernel walked the tree whatever the filter says; what the
    // filter can still do is keep the event from the caller.
    if (stream.filter.excludes(stream.root, record.path)) {
        trace.log("fsevents drop filtered path={s}", .{record.path});
        return;
    }

    if (record.renamed()) {
        if (records.partnerOf(record, delivered, used, at + 1, Asking{ .f = f })) |partner_at| {
            used[partner_at] = true;
            const partner = delivered[partner_at];
            trace.log("fsevents push renamed path={s}", .{record.path});
            if (f.exists(partner.path)) {
                try f.joined(batch, record.id, partner.path, record.path, partner.target());
            } else {
                try f.joined(batch, record.id, record.path, partner.path, record.target());
            }
            try f.recount(batch, record.path, .unchanged, stream);
            try f.recount(batch, partner.path, .unchanged, stream);
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
    const seen = f.known.contains(.{ .id = record.id, .path = record.path });
    // A known path with no removal flag, and a newly-created path with
    // no removal flag, are present as far as this record can say. A
    // later removal races any `stat` made here in exactly the same way
    // and will carry its own record. Save the filesystem query for the
    // ambiguous cases: accumulated removal flags and an unknown path
    // whose flags do not say it was created.
    const there = if (needsExistenceCheck(record.flags, seen))
        f.exists(record.path)
    else
        true;

    if (!there) {
        // Gone. Whatever the flags remember about it, the fact now is
        // that the path is not there. A path lookout never knew about came
        // and went between two polls, and the tree is as it was.
        if (seen or stream.catchingUp(f.io)) {
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
    if (wasReplaced(record.flags)) {
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
        } else {
            trace.log("fsevents drop known-no-change path={s}", .{record.path});
        }
    } else {
        trace.log("fsevents drop dir-metadata path={s}", .{record.path});
    }
}

fn needsExistenceCheck(flags: u32, seen: bool) bool {
    return flags & flag.item_removed != 0 or (!seen and flags & flag.item_created == 0);
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
) lookout.Watcher.PollError!void {
    try f.budget.begin(root);
    const Adopting = struct {
        f: *FsEvents,
        batch: *Batch,
        id: WatchId,
        stream: *const Stream,

        fn visit(a: *@This(), entry: walk.Entry) anyerror!walk.Step {
            a.f.budget.found(entry.dir);
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
    try f.rekey(id, from, to);
    f.budget.forget(from);
}

/// Holds an unpaired rename until the next delivery arrives. Anything
/// already held has waited as long as it is going to.
fn hold(f: *FsEvents, batch: *Batch, record: Record) lookout.Watcher.PollError!void {
    // Copied first: the buffer the record points into is emptied before
    // the next delivery is read, and a dupe that fails must leave what
    // is already held where it was.
    const owned = try f.gpa.dupe(u8, record.path);
    trace.log("fsevents hold renamed path={s}", .{record.path});
    const stale = f.pairing.carry(.{
        .id = record.id,
        .path = owned,
        .flags = record.flags,
        .event = record.event,
    }) orelse return;
    defer f.gpa.free(stale.path);
    try f.reportHalf(batch, stale);
}

/// Gives up on a half that never found its partner, at the end of the
/// whole wait rather than at the end of one delivery.
fn resolveHeld(f: *FsEvents, batch: *Batch) lookout.Watcher.PollError!void {
    const half = f.pairing.held orelse return;
    f.pairing.held = null;
    defer f.gpa.free(half.path);
    try f.reportHalf(batch, half);
}

/// Reports a half that never found its partner: the path was renamed
/// out of the watch, or renamed and then deleted, and what is left is
/// the removal or the creation the other backends would give.
fn reportHalf(f: *FsEvents, batch: *Batch, half: records.Half) lookout.Watcher.PollError!void {
    const stream = f.streams.get(half.id) orelse return;
    trace.log("fsevents unpaired renamed path={s}", .{half.path});
    try f.reportPlain(batch, half.record(), stream);
}

/// Records that a path exists.
fn remember(f: *FsEvents, id: WatchId, subject: []const u8) Allocator.Error!void {
    const key: KnownKey = .{ .id = id, .path = subject };
    if (f.known.contains(key)) return;
    const owned = try f.gpa.dupe(u8, subject);
    errdefer f.gpa.free(owned);
    try f.known.put(f.gpa, .{ .id = id, .path = owned }, {});
}

/// Records that a path does not.
fn forget(f: *FsEvents, id: WatchId, subject: []const u8) void {
    if (f.known.fetchSwapRemove(.{ .id = id, .path = subject })) |entry| {
        f.gpa.free(entry.key.path);
    }
}

/// Forgets everything remembered under a subtree that has gone.
fn forgetSubtree(f: *FsEvents, id: WatchId, root: []const u8) void {
    var i: usize = 0;
    while (i < f.known.count()) {
        const key = f.known.keys()[i];
        if (key.id == id and path_cmp.within(root, key.path)) {
            f.gpa.free(key.path);
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
        f.gpa.free(f.known.keys()[i].path);
        f.known.swapRemoveAt(i);
    }
}

fn refreshKnown(
    f: *FsEvents,
    id: WatchId,
    root: []const u8,
    stream: *const Stream,
) lookout.Watcher.PollError!void {
    f.forgetSubtree(id, root);
    try f.remember(id, root);

    const Refreshing = struct {
        f: *FsEvents,
        id: WatchId,
        stream: *const Stream,

        fn visit(r: *@This(), entry: walk.Entry) anyerror!walk.Step {
            if (r.stream.filter.prunes(r.stream.root, entry.path)) return .over;
            try r.f.remember(r.id, entry.path);
            return .into;
        }
    };
    var refreshing: Refreshing = .{ .f = f, .id = id, .stream = stream };
    walk.tree(f.gpa, f.io, root, &refreshing, Refreshing.visit) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Unexpected,
    };
}

/// Moves everything remembered under `old` to sit under `new`, which is
/// what a directory rename does to a tree.
fn rekey(f: *FsEvents, id: WatchId, old: []const u8, new: []const u8) Allocator.Error!void {
    var moved: std.ArrayList([]u8) = .empty;
    defer {
        for (moved.items) |p| f.gpa.free(p);
        moved.deinit(f.gpa);
    }

    var i: usize = 0;
    while (i < f.known.count()) {
        const key = f.known.keys()[i];
        if (key.id != id) {
            i += 1;
            continue;
        }
        const rest = path_cmp.relative(old, key.path) orelse {
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
        f.gpa.free(key.path);
        f.known.swapRemoveAt(i);
    }

    while (moved.items.len != 0) {
        const p = moved.pop().?;
        if (f.known.contains(.{ .id = id, .path = p })) {
            f.gpa.free(p);
            continue;
        }
        f.known.put(f.gpa, .{ .id = id, .path = p }, {}) catch {
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
    if (f.exists(stream.root)) try f.remember(stream.id, stream.root);
    if (stream.scope == .file) return;
    try f.budget.begin(stream.root);
    trace.log("fsevents seed walk root={s}", .{stream.root});

    const Seeding = struct {
        f: *FsEvents,
        stream: *const Stream,

        fn visit(s: *@This(), entry: walk.Entry) anyerror!walk.Step {
            s.f.budget.found(entry.dir);
            if (entry.kind == .directory) try s.f.budget.begin(entry.path);
            if (s.stream.filter.prunes(s.stream.root, entry.path)) {
                trace.log("fsevents seed filtered {s}", .{entry.path});
                return .over;
            }
            trace.log("fsevents seed remembered {s}", .{entry.path});
            try s.f.remember(s.stream.id, entry.path);
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
fn recount(
    f: *FsEvents,
    batch: *Batch,
    subject: []const u8,
    move: Budget.Move,
    stream: *const Stream,
) lookout.Watcher.PollError!void {
    const parent = std.fs.path.dirname(subject) orelse return;
    if (try f.budget.note(parent, move)) {
        try batch.push(f.gpa, stream.id, stream.root, .overflow, stream.rootTarget());
    }
}

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
}

test "stream latency follows the watcher latency" {
    try std.testing.expectEqual(@as(f64, 0.0), latencySeconds(0));
    try std.testing.expectEqual(@as(f64, 0.05), latencySeconds(50));
    try std.testing.expectEqual(@as(f64, 1.5), latencySeconds(1_500));
}

/// One record of a delivery made by hand.
const Synthetic = struct { path: []const u8, flags: u32 };

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
        paths[filled] = try gpa.dupeZ(u8, item.path);
        flags[filled] = item.flags;
        ids[filled] = c.FSEventsGetCurrentEventId();
        filled += 1;
    }
    deliver(stream.ref, stream, filled, @ptrCast(&paths), &flags, &ids);
}

/// Polls until one `overflow` arrives, checks it against the watch it is
/// for, and then that no second one follows it.
fn expectOneOverflow(watcher: *lookout.Watcher, id: WatchId, root: []const u8, target: Target) !void {
    var overflows: usize = 0;
    var waited: u32 = 0;
    while (waited < 10_000 and overflows == 0) : (waited += 200) {
        for (try watcher.poll(200)) |event| {
            if (event.kind != .overflow) continue;
            try std.testing.expectEqual(id, event.id);
            try std.testing.expectEqualStrings(root, event.path);
            try std.testing.expectEqual(target, event.target);
            overflows += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), overflows);
    while (true) {
        const events = try watcher.poll(200);
        if (events.len == 0) return;
        for (events) |event| try std.testing.expect(event.kind != .overflow);
    }
}

test "the flags that say the system lost track are one overflow, and the watch goes on" {
    // FSEvents.h on `kFSEventStreamEventFlagMustScanSubDirs`: "Your
    // application must rescan not just the directory given in the event,
    // but all its children, recursively. This can happen if there was a
    // problem whereby events were coalesced hierarchically", with
    // `UserDropped` and `KernelDropped` set beside it to say where. A
    // hundred thousand creations against the smallest buffer this
    // backend takes did not make the kernel set any of the three -- the
    // callback is a bounded copy, so this process is never the
    // bottleneck -- so the delivery is made by hand, through the
    // callback the system calls and the buffer it writes.
    const testing = std.testing;
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    try tmp.dir.createDirPath(io, "sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one" });
    const sub = try std.fs.path.join(gpa, &.{ root, "sub" });
    defer gpa.free(sub);
    const file = try std.fs.path.join(gpa, &.{ root, "a.txt" });
    defer gpa.free(file);

    // The caller's half of the contract: seeded where the watch is taken.
    var baseline: lookout.Baseline = try .seed(gpa, io, root, .{ .recursive = true });
    defer baseline.deinit(gpa);

    var watcher: lookout.Watcher = try .init(gpa, io, .{ .backend = .fsevents });
    defer watcher.deinit();
    const tree = try watcher.add(root, .{ .recursive = true });
    const single = try watcher.add(file, .{});
    while ((try watcher.poll(200)).len != 0) {}
    const f = &watcher.impl.fsevents;

    // What the lost events would have carried.
    try tmp.dir.writeFile(io, .{ .sub_path = "missed.txt", .data = "x" });

    // One delivery, the three flags across it, at the root and below it:
    // one overflow, against the root.
    try synthesize(gpa, f.streams.get(tree).?, &.{
        .{ .path = root, .flags = flag.must_scan_sub_dirs | flag.kernel_dropped },
        .{ .path = sub, .flags = flag.must_scan_sub_dirs | flag.user_dropped },
        .{ .path = root, .flags = flag.must_scan_sub_dirs },
    });
    try expectOneOverflow(&watcher, tree, root, .directory);

    // The tree read again, which is what the event asks for.
    var recovered = false;
    for (try baseline.diff(gpa)) |change| {
        if (change.kind == .created and std.mem.endsWith(u8, change.path, "missed.txt")) recovered = true;
    }
    try testing.expect(recovered);

    // A watch on a file has its stream on the parent directory, and the
    // loss is reported there: a path the watch wants no event for, and
    // the one place its events could have been lost.
    try synthesize(gpa, f.streams.get(single).?, &.{
        .{ .path = root, .flags = flag.must_scan_sub_dirs | flag.kernel_dropped },
    });
    try expectOneOverflow(&watcher, single, file, .file);

    // A loss coalesced above the root took the root's events with it.
    try synthesize(gpa, f.streams.get(tree).?, &.{
        .{ .path = std.fs.path.dirname(root).?, .flags = flag.user_dropped },
    });
    try expectOneOverflow(&watcher, tree, root, .directory);

    // And both watches are still watching.
    try tmp.dir.writeFile(io, .{ .sub_path = "after.txt", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one and two" });
    const after = try std.fs.path.join(gpa, &.{ root, "after.txt" });
    defer gpa.free(after);
    var saw_after = false;
    var saw_file = false;
    var waited: u32 = 0;
    while (waited < 10_000 and !(saw_after and saw_file)) : (waited += 200) {
        for (try watcher.poll(200)) |event| {
            if (event.id == tree and event.kind == .created and std.mem.eql(u8, event.path, after)) saw_after = true;
            if (event.id == single and event.kind == .modified and std.mem.eql(u8, event.path, file)) saw_file = true;
        }
    }
    try testing.expect(saw_after);
    try testing.expect(saw_file);
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

    /// The replay a past `since_when` asked for has reached the present.
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
