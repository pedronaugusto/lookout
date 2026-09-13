//! zwatch — one file-system watching API over `kqueue`, `inotify` and
//! polling.
//!
//! A `Watcher` owns a set of watches. Each watch is a path — a file or a
//! directory — added with `Watcher.add` and dropped with `Watcher.remove`.
//! `Watcher.poll` blocks until something happens and hands back the events
//! that happened, one per path, coalesced.
//!
//! The library starts no threads and calls nothing back. Everything happens
//! on the thread that calls `poll`, and a program with a loop of its own can
//! take `Watcher.fd` and wait on the watcher alongside its other descriptors.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const Batch = @import("Batch.zig");
const Tree = @import("Tree.zig");

/// The mechanism a `Watcher` uses to learn that something changed.
///
/// Which of these can be selected depends on the target: see
/// `native_backend`. `poll` is available everywhere.
pub const Backend = enum {
    /// Pick `native_backend` if this target has one, otherwise `poll`.
    auto,
    /// BSD `kqueue` with the `EVFILT_VNODE` filter. One descriptor is held
    /// open per watched file and per watched directory.
    kqueue,
    /// Linux `inotify`. One kernel watch descriptor is held per watched
    /// file and per watched directory.
    inotify,
    /// Re-stat and re-list watched paths on a timer. Needs no kernel
    /// support and holds no descriptor, at the cost of latency and of
    /// walking every watched directory on every tick.
    poll,
};

/// The backend `Backend.auto` resolves to on this target, or `null` when
/// this target has no kernel notification mechanism zwatch implements and
/// `Backend.poll` is the only choice.
///
/// Selecting a backend other than this one or `.poll` fails
/// `Watcher.init` with `error.BackendUnavailable`; it is not a compile
/// error, so a program may ask for a backend and fall back at run time.
pub const native_backend: ?Backend = switch (builtin.os.tag) {
    .driverkit,
    .ios,
    .maccatalyst,
    .macos,
    .tvos,
    .visionos,
    .watchos,
    .dragonfly,
    .freebsd,
    .netbsd,
    .openbsd,
    => .kqueue,
    .linux => .inotify,
    else => null,
};

/// The compiled-in native backend implementation, or `void` on a target
/// that has none. The switch is comptime, so a target's build contains one
/// native backend and never the others.
const Native = if (native_backend) |backend| switch (backend) {
    .kqueue => @import("backend/kqueue.zig"),
    .inotify => @import("backend/inotify.zig"),
    else => unreachable,
} else void;

const Poll = @import("backend/poll.zig");

/// Identifies one watch within one `Watcher`.
///
/// Values are unique for the lifetime of the `Watcher` that issued them and
/// are never reused, so an event carrying an id of a removed watch cannot
/// be confused with a later watch.
pub const WatchId = enum(u32) { _ };

/// What happened to a path.
///
/// Coalescing within one `Watcher.poll` keeps the most significant kind
/// observed, in this order: `attributes` < `modified` < `created` <
/// `renamed` < `removed` < `overflow`. A path created and then written
/// inside one window reports `created`; a path written and then deleted
/// reports `removed`.
pub const Kind = enum {
    /// The path did not exist at the previous observation and does now.
    created,
    /// The contents of the path changed: a different size, a different
    /// modification time, or a write reported by the kernel.
    modified,
    /// The path no longer exists. A rename of an entry inside a watched
    /// directory is reported as `removed` on the old name and `created` on
    /// the new one, on every backend.
    removed,
    /// The watched path itself was renamed and the watch now follows a
    /// path that no longer has that name. Produced by the `kqueue` and
    /// `inotify` backends; the `poll` backend cannot tell this from
    /// `removed` and reports `removed`.
    renamed,
    /// Metadata other than the contents changed — permissions, ownership,
    /// link count, or the status-change time.
    attributes,
    /// Changes were lost and the caller should rescan the watch itself.
    /// Emitted when the kernel event queue overflowed, or when a watched
    /// directory holds more entries than `Options.max_dir_entries`. The
    /// `path` is the watch root, not an entry inside it.
    overflow,
};

/// One thing that happened to one path during one `Watcher.poll` window.
pub const Event = struct {
    /// The watch this path belongs to, as returned by `Watcher.add`.
    id: WatchId,
    /// Absolute, canonical path of the affected file or directory —
    /// including for an entry inside a watched directory, which is the
    /// watch root joined with the entry name. Owned by the `Watcher` and
    /// valid until the next call to `Watcher.poll` or `Watcher.deinit`.
    path: []const u8,
    /// What happened.
    kind: Kind,
};

/// How a `Watcher` behaves, fixed for its lifetime.
pub const Options = struct {
    /// Which mechanism to use. See `Backend` and `native_backend`.
    backend: Backend = .auto,
    /// How long the `poll` backend waits between scans. Ignored by every
    /// other backend.
    poll_interval_ms: u32 = 500,
    /// How long `Watcher.poll` keeps collecting after the first event of a
    /// batch arrives. Everything that lands on one path inside that window
    /// becomes a single `Event`, so a program is not woken once per write
    /// of a file being saved. Zero disables the wait and reports whatever
    /// is already queued.
    latency_ms: u32 = 50,
    /// The largest number of entries zwatch tracks in one watched
    /// directory. A directory with more entries than this is tracked up to
    /// the limit and reports `Kind.overflow` on every scan, because
    /// changes beyond the limit cannot be seen. Used by the `kqueue` and
    /// `poll` backends, which learn what changed by comparing directory
    /// listings; `inotify` is told the name by the kernel and ignores it.
    max_dir_entries: usize = 4096,
};

/// How one watch behaves, fixed for its lifetime.
pub const AddOptions = struct {
    /// Also watch every directory below this one, and every directory
    /// created below it afterwards.
    ///
    /// Recursion is not a kernel feature on either `kqueue` or `inotify`:
    /// zwatch walks the tree at `add` time and registers each directory
    /// individually, then registers newly created directories as it sees
    /// them. Three consequences are worth knowing:
    ///
    /// * A deep tree costs one descriptor (`kqueue`) or one kernel watch
    ///   (`inotify`) per directory, against a per-process limit.
    /// * A directory created and populated faster than zwatch can register
    ///   it can lose the events for the files inside. zwatch scans each
    ///   directory immediately after registering it and reports whatever
    ///   it finds as `created`, which closes the race for files that still
    ///   exist, not for files already gone again.
    /// * Symbolic links are not followed, so a link into a watched tree
    ///   does not silently widen it.
    recursive: bool = false,
};

/// A set of watches and the events they have produced.
///
/// Not thread-safe: one `Watcher` belongs to one thread. Several may exist
/// in one process.
pub const Watcher = struct {
    gpa: Allocator,
    io: Io,
    options: Options,
    batch: Batch,
    next_id: u32,
    impl: Impl,

    /// The backend, chosen at `init` from what this target was built
    /// with. A target with no native backend has no prong for one, which
    /// is what keeps Windows from carrying a dead `kqueue` branch.
    const Impl = if (Native == void) union(enum) {
        poll: Poll,
    } else union(enum) {
        native: Native,
        poll: Poll,
    };

    /// Errors `init` can return.
    pub const InitError = error{
        /// `Options.backend` names a backend this target was not built
        /// with. See `native_backend`.
        BackendUnavailable,
        /// The process or the system is out of file descriptors.
        SystemFdQuotaExceeded,
        ProcessFdQuotaExceeded,
        /// The kernel could not allocate for the notification queue.
        SystemResources,
    } || Allocator.Error || UnexpectedError;

    /// Errors `add` can return, on top of the file-system errors of
    /// resolving and opening the path.
    pub const AddError = error{
        /// The kernel refused another watch: the per-process or
        /// system-wide limit on watches or descriptors is reached.
        WatchLimitReached,
    } || Tree.AddError || UnexpectedError;

    /// Errors `poll` can return, on top of the file-system errors of
    /// re-reading watched directories.
    pub const PollError = Tree.ScanError || Io.Cancelable || UnexpectedError;

    /// A system call failed with a code zwatch does not model. This is
    /// the escape hatch every backend shares, so that an error set is a
    /// promise about the whole API rather than about one platform.
    pub const UnexpectedError = error{Unexpected};

    /// Creates a watcher that holds no watches.
    ///
    /// `gpa` is used for the watch tables and for the event buffer handed
    /// out by `poll`; `io` is the I/O implementation every file-system
    /// operation goes through, and is captured for the lifetime of the
    /// watcher. Call `deinit` to release both the allocations and the
    /// descriptors.
    pub fn init(gpa: Allocator, io: Io, options: Options) InitError!Watcher {
        const resolved: Backend = switch (options.backend) {
            .auto => native_backend orelse .poll,
            else => |b| b,
        };
        const impl: Impl = impl: {
            if (resolved == .poll) break :impl .{ .poll = Poll.init(gpa, io, options) };
            if (Native == void) return error.BackendUnavailable;
            if (resolved != native_backend.?) return error.BackendUnavailable;
            break :impl .{ .native = try Native.init(gpa, io, options) };
        };
        return .{
            .gpa = gpa,
            .io = io,
            .options = options,
            .batch = .empty,
            .next_id = 0,
            .impl = impl,
        };
    }

    /// Releases every watch, every descriptor, and the events handed out
    /// by the last `poll`.
    pub fn deinit(w: *Watcher) void {
        switch (w.impl) {
            inline else => |*impl| impl.deinit(),
        }
        w.batch.deinit(w.gpa);
        w.* = undefined;
    }

    /// Starts watching `path`, which may be a file or a directory and may
    /// be relative to the current directory.
    ///
    /// The path is resolved to a canonical absolute path once, here; the
    /// watch follows that path and the events it produces are spelled
    /// against it. Adding the same path twice produces two independent
    /// watches and two events per change.
    ///
    /// The returned id is valid until `remove` is called with it or the
    /// watcher is deinitialized.
    pub fn add(w: *Watcher, path: []const u8, options: AddOptions) AddError!WatchId {
        // The backend copies what it keeps, so this resolution is scratch
        // and a failed `add` leaves nothing behind.
        const abs = try Io.Dir.cwd().realPathFileAlloc(w.io, path, w.gpa);
        defer w.gpa.free(abs);

        const id: WatchId = @enumFromInt(w.next_id);
        switch (w.impl) {
            inline else => |*impl| try impl.add(id, abs, options),
        }
        w.next_id += 1;
        return id;
    }

    /// Stops watching `id`, releasing its descriptors. Events already
    /// collected for it by the last `poll` stay valid until the next one;
    /// no further events are produced for it.
    ///
    /// Removing an id that is not currently watched — one already
    /// removed — does nothing.
    pub fn remove(w: *Watcher, id: WatchId) void {
        switch (w.impl) {
            inline else => |*impl| impl.remove(id),
        }
    }

    /// Waits for something to happen and returns what did.
    ///
    /// Blocks until at least one event arrives or `timeout_ms`
    /// milliseconds pass; `null` blocks indefinitely, and `0` reports
    /// whatever is already queued without waiting. Once the first event of
    /// a batch arrives, collection continues for `Options.latency_ms`
    /// more so that a burst on one path becomes one event; a `timeout_ms`
    /// of `0` skips that wait.
    ///
    /// The returned slice, and every path in it, is owned by the watcher
    /// and is invalidated by the next call to `poll` or by `deinit`. An
    /// empty slice means the timeout expired with nothing to report.
    pub fn poll(w: *Watcher, timeout_ms: ?u32) PollError![]const Event {
        w.batch.reset(w.gpa);

        switch (w.impl) {
            inline else => |*impl| try impl.wait(&w.batch, timeout_ms),
        }
        if (w.batch.events.items.len == 0) return &.{};
        if (timeout_ms == 0 or w.options.latency_ms == 0) return w.batch.events.items;

        // The coalescing tail: keep reading for `latency_ms` past the first
        // event so that an editor writing a file in four chunks is one
        // `modified` and not four.
        const started: Io.Timestamp = .now(w.io, .awake);
        const window = Io.Duration.fromMilliseconds(w.options.latency_ms);
        while (true) {
            const elapsed = started.durationTo(Io.Timestamp.now(w.io, .awake));
            const remaining = window.nanoseconds - elapsed.nanoseconds;
            if (remaining <= 0) break;
            const remaining_ms: u32 = @intCast(@divTrunc(remaining, std.time.ns_per_ms) + 1);
            switch (w.impl) {
                inline else => |*impl| try impl.wait(&w.batch, remaining_ms),
            }
        }
        return w.batch.events.items;
    }

    /// The descriptor the watcher waits on, for a program that runs a
    /// wait loop of its own: it becomes readable when there is something
    /// for `poll` to report.
    ///
    /// `null` for the `poll` backend, which has no descriptor — such a
    /// watcher can only be driven by calling `poll`.
    ///
    /// The descriptor belongs to the watcher. Reading from it, closing it,
    /// or registering it for anything other than readability is illegal
    /// behavior; use it to decide when to call `poll`, and nothing else.
    pub fn fd(w: *const Watcher) ?std.posix.fd_t {
        if (Native == void) return null;
        return switch (w.impl) {
            .poll => null,
            .native => |*impl| impl.fd(),
        };
    }

    /// The backend this watcher actually uses, with `Backend.auto`
    /// resolved.
    pub fn backend(w: *const Watcher) Backend {
        if (Native == void) return .poll;
        return switch (w.impl) {
            .poll => .poll,
            .native => native_backend.?,
        };
    }
};

test {
    _ = Batch;
    _ = Tree;
    _ = @import("Snapshot.zig");
    _ = @import("test_suite.zig");
}
