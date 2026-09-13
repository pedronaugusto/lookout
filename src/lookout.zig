//! lookout — one file-system watching API over `kqueue`, `inotify` and
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
/// Which of these this target was built with is `supported`; which one
/// `auto` picks is `default_backend`. `poll` is built everywhere.
pub const Backend = enum {
    /// Pick `default_backend`.
    auto,
    /// Apple's FSEvents. Recursive in the kernel, so a tree costs no
    /// descriptor per directory, and renames arrive paired.
    fsevents,
    /// BSD `kqueue` with the `EVFILT_VNODE` filter. One descriptor is held
    /// open per watched file and per watched directory.
    kqueue,
    /// Linux `inotify`. One kernel watch descriptor is held per watched
    /// file and per watched directory, and renames arrive paired.
    inotify,
    /// Windows `ReadDirectoryChangesW` with overlapped reads drained
    /// through an I/O completion port. Recursive by flag, and renames
    /// arrive paired.
    windows,
    /// Re-stat and re-list watched paths on a timer. Needs no kernel
    /// support and holds no descriptor, at the cost of latency and of
    /// walking every watched directory on every tick.
    poll,
};

/// Whether this target was built with `backend`.
///
/// Asking `Watcher.init` for one that was not fails with
/// `error.BackendUnavailable` rather than failing to compile, so a
/// program may ask and fall back at run time; this is how it asks first.
pub fn supported(backend: Backend) bool {
    return switch (backend) {
        .auto => true,
        inline else => |tag| @hasField(Watcher.Impl, @tagName(tag)),
    };
}

/// Whether `backend` pairs a rename, reporting one `Kind.renamed` event
/// carrying `Event.from`, or cannot and reports `Kind.removed` on the old
/// path and `Kind.created` on the new one.
///
/// Both shapes describe the same thing happening. A program that only
/// wants to know that a path needs re-reading can ignore the difference;
/// one that follows a file across a rename needs this.
pub fn pairsRenames(backend: Backend) bool {
    return switch (backend) {
        .auto => pairsRenames(default_backend),
        .fsevents, .inotify, .windows => true,
        .kqueue, .poll => false,
    };
}

/// The backend `Backend.auto` resolves to on this target: the kernel one
/// where there is a kernel one, and `poll` where there is not.
///
/// On Apple targets this is `fsevents` rather than `kqueue`, because
/// FSEvents recurses without a descriptor per directory and pairs
/// renames. `kqueue` remains selectable, and is the better answer for a
/// handful of paths watched without recursion.
pub const default_backend: Backend = switch (builtin.os.tag) {
    .driverkit,
    .ios,
    .maccatalyst,
    .macos,
    .tvos,
    .visionos,
    .watchos,
    => .fsevents,
    .dragonfly, .freebsd, .netbsd, .openbsd => .kqueue,
    .linux => .inotify,
    .windows => .windows,
    else => .poll,
};

/// The backend every target has. Named here rather than inside `Impl`
/// because every one of that union's shapes has it.
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
    ///
    /// When the path is a watch's own root, that watch stops there: a
    /// path is watched, not a name, and the name is now empty. The id
    /// stays valid and `Watcher.remove` still releases it.
    removed,
    /// The watched path itself was renamed, so the watch no longer stands
    /// for the name it was added under and stops, exactly as for a
    /// `removed` root. Produced by the `kqueue` and `inotify` backends;
    /// the `poll` backend cannot tell a rename from a deletion and
    /// reports `removed`.
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
    ///
    /// For `Kind.renamed` this is where the path is now.
    path: []const u8,
    /// What happened.
    kind: Kind,
    /// Where a renamed path was before, when the operating system paired
    /// the two halves of the rename. `null` for every other kind, and for
    /// `Kind.renamed` on a backend that cannot pair -- see `pairsRenames`
    /// -- and when the watched path itself was renamed, which has no
    /// second half to pair with.
    ///
    /// Owned by the `Watcher` on the same terms as `path`.
    from: ?[]const u8 = null,
};

/// How a `Watcher` behaves, fixed for its lifetime.
pub const Options = struct {
    /// Which mechanism to use. See `Backend`, `default_backend` and
    /// `supported`.
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
    /// How long a file must stop changing before its `Kind.modified` is
    /// reported. Zero, the default, reports it as soon as it is seen.
    ///
    /// `latency_ms` merges the writes that arrive together; this waits
    /// for the writing to be over. A build system copying a large file
    /// produces `modified` the moment it starts, which is the wrong
    /// moment to read it; with `settle_ms` the event arrives once the
    /// file has been still for that long.
    ///
    /// It delays only `modified`. A creation, a removal and a rename are
    /// facts about a name rather than about contents, and are reported at
    /// once whatever this is set to.
    settle_ms: u32 = 0,
    /// The largest number of entries lookout will account for in one
    /// watched directory. A directory holding more reports
    /// `Kind.overflow` against its watch root, which means: this one is
    /// past the budget you set, rescan it yourself.
    ///
    /// The backends reach that answer differently and it is deliberate
    /// that they all reach it. `kqueue` and `poll` name an entry by
    /// comparing directory listings, so past the limit they genuinely
    /// cannot see a change. `inotify` is told every name by the kernel
    /// and keeps reporting them, and counts entries only so that the
    /// signal a caller handles is the same one on every platform.
    max_dir_entries: usize = 4096,
};

/// How one watch behaves, fixed for its lifetime.
pub const AddOptions = struct {
    /// Also watch every directory below this one, and every directory
    /// created below it afterwards.
    ///
    /// Recursion is not a kernel feature on either `kqueue` or `inotify`:
    /// lookout walks the tree at `add` time and registers each directory
    /// individually, then registers newly created directories as it sees
    /// them. Three consequences are worth knowing:
    ///
    /// * A deep tree costs one descriptor (`kqueue`) or one kernel watch
    ///   (`inotify`) per directory, against a per-process limit.
    /// * A directory created and populated faster than lookout can register
    ///   it can lose the events for the files inside. lookout scans each
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

    /// Every backend this target was built with, and the one the watcher
    /// chose. Written out per target rather than generated, because the
    /// set really is different per target and a reader should be able to
    /// see which. The tag names match `Backend`'s, which is what lets
    /// `init`, `supported` and `backend` be one line each.
    const Impl = switch (builtin.os.tag) {
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => union(enum) {
            fsevents: @import("backend/fsevents.zig"),
            kqueue: @import("backend/kqueue.zig"),
            poll: Poll,
        },
        .dragonfly, .freebsd, .netbsd, .openbsd => union(enum) {
            kqueue: @import("backend/kqueue.zig"),
            poll: Poll,
        },
        .linux => union(enum) {
            inotify: @import("backend/inotify.zig"),
            poll: Poll,
        },
        .windows => union(enum) {
            windows: @import("backend/windows.zig"),
            poll: Poll,
        },
        else => union(enum) {
            poll: Poll,
        },
    };

    /// Errors `init` can return. No allocation happens here -- a watcher
    /// that holds no watches holds no memory -- so this is only what
    /// creating the kernel queue can fail with.
    pub const InitError = error{
        /// `Options.backend` names a backend this target was not built
        /// with. See `supported`.
        BackendUnavailable,
        /// The system-wide descriptor table is full.
        SystemFdQuotaExceeded,
        /// This process may not open another descriptor.
        ProcessFdQuotaExceeded,
        /// The kernel could not allocate for the notification queue.
        SystemResources,
    } || UnexpectedError;

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

    /// A system call failed with a code lookout does not model. This is
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
            .auto => default_backend,
            else => |b| b,
        };
        const impl: Impl = switch (resolved) {
            .auto => unreachable,
            inline else => |tag| impl: {
                const name = @tagName(tag);
                if (!@hasField(Impl, name)) return error.BackendUnavailable;
                break :impl @unionInit(Impl, name, try @FieldType(Impl, name).init(gpa, io, options));
            },
        };
        return .{
            .gpa = gpa,
            .io = io,
            .options = options,
            .batch = .init(io, options),
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
    /// against it.
    ///
    /// One watcher watches a path once: a second `add` of a path already
    /// watched fails with `error.PathAlreadyWatched`, on every backend.
    /// The rule exists because `inotify` returns the same kernel watch
    /// descriptor for the same inode, so a second registration would
    /// quietly take the first one's events over; refusing it is the same
    /// answer everywhere instead of a difference to discover.
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
    /// milliseconds pass; `null` blocks indefinitely, and `0` performs a
    /// single non-blocking check and returns. Once the first event of a
    /// batch arrives, collection continues for `Options.latency_ms` more
    /// so that a burst on one path becomes one event; a `timeout_ms` of
    /// `0` skips that wait.
    ///
    /// The returned slice, and every path in it, is owned by the watcher
    /// and is invalidated by the next call to `poll` or by `deinit`. An
    /// empty slice means the timeout expired with nothing to report.
    pub fn poll(w: *Watcher, timeout_ms: ?u32) PollError![]const Event {
        w.batch.reset(w.gpa);
        const started: Io.Timestamp = .now(w.io, .awake);

        while (true) {
            // A path that is settling has a deadline of its own, so the
            // wait is the shorter of the caller's timeout and the next
            // one due; otherwise a `poll(null)` would sleep through a
            // deadline the watcher set itself.
            const left = remainingMs(w.io, started, timeout_ms);
            const wait_ms: ?u32 = if (w.batch.nextDueMs()) |due|
                if (left) |l| @min(l, due) else due
            else
                left;

            switch (w.impl) {
                inline else => |*impl| try impl.wait(&w.batch, wait_ms),
            }
            try w.batch.promote(w.gpa);
            if (w.batch.events.items.len > 0) break;
            if (remainingMs(w.io, started, timeout_ms)) |l| {
                if (l == 0) return &.{};
            }
        }
        if (timeout_ms == 0 or w.options.latency_ms == 0) return w.batch.events.items;

        // The coalescing tail: keep reading for `latency_ms` past the first
        // event so that an editor writing a file in four chunks is one
        // `modified` and not four.
        const tail: Io.Timestamp = .now(w.io, .awake);
        while (true) {
            const left = remainingMs(w.io, tail, w.options.latency_ms) orelse 0;
            if (left == 0) break;
            switch (w.impl) {
                inline else => |*impl| try impl.wait(&w.batch, left),
            }
            try w.batch.promote(w.gpa);
        }
        return w.batch.events.items;
    }

    /// Milliseconds left of `timeout_ms` since `started`, or `null` when
    /// there is no timeout at all. Zero means it has expired.
    fn remainingMs(io: Io, started: Io.Timestamp, timeout_ms: ?u32) ?u32 {
        const total = timeout_ms orelse return null;
        const elapsed = started.durationTo(Io.Timestamp.now(io, .awake)).toMilliseconds();
        return @intCast(@max(0, @as(i64, total) - elapsed));
    }

    /// The descriptor the watcher waits on, for a program that runs a
    /// wait loop of its own: it becomes readable when there is something
    /// for `poll` to report.
    ///
    /// `null` where the backend has no descriptor to give: the `poll`
    /// backend, which has nothing to wait on, and the Windows backend,
    /// which waits on an I/O completion port rather than on a handle
    /// anything else can wait for. Such a watcher is driven by calling
    /// `poll`.
    ///
    /// The descriptor belongs to the watcher. Reading from it, closing it,
    /// or registering it for anything other than readability is illegal
    /// behavior; use it to decide when to call `poll`, and nothing else.
    pub fn fd(w: *const Watcher) ?std.posix.fd_t {
        return switch (w.impl) {
            inline else => |*impl| impl.fd(),
        };
    }

    /// The backend this watcher actually uses, with `Backend.auto`
    /// resolved.
    pub fn backend(w: *const Watcher) Backend {
        return switch (w.impl) {
            inline else => |_, tag| @field(Backend, @tagName(tag)),
        };
    }
};

test {
    _ = Batch;
    _ = Tree;
    _ = @import("Snapshot.zig");
    _ = @import("test_suite.zig");
}
