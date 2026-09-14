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

/// Which paths under a watch the caller wants. See `AddOptions.filter`.
pub const Filter = @import("Filter.zig");

/// What a tree looked like, and what has changed in it since. This is
/// what `Kind.overflow` asks a caller to work out, made answerable:
/// seed one where the watch is taken, and diff it when the watcher says
/// its record is incomplete.
pub const Baseline = @import("Baseline.zig");

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

/// What a backend reports when the watched path itself is moved. See
/// `reportsRootMove`.
pub const RootMove = enum {
    /// `Kind.renamed` against the watch root: the backend watches the
    /// object and is told that it moved.
    renamed,
    /// `Kind.removed` against the watch root: the backend watches the
    /// name, and a move and a deletion leave the same absence behind.
    removed,
    /// Nothing at all. The backend holds the object open through a
    /// handle the move does not disturb, and the move itself is a change
    /// in a directory it was not asked to watch, so there is nothing to
    /// deliver and the watch keeps running on the object under its new
    /// name.
    silent,
};

/// How `backend` reports the watched path itself being moved.
///
/// The watched path being *deleted* is `Kind.removed` on every backend.
/// A move is the one that differs, so this is how a program asks which
/// of the three shapes to expect instead of discovering it.
///
/// `kqueue` and `inotify` watch the object and are told that it moved,
/// so both say `renamed`. `poll` compares listings, in which a move and
/// a deletion are the same absence, and FSEvents reports both with one
/// flag against a root that is no longer at its name; both say
/// `removed`. `windows` holds a directory handle that a rename leaves
/// valid, and the rename happens in the parent directory, which the
/// watch was not put on: nothing is delivered, and `silent` says so
/// rather than leaving a caller waiting for an event that is not coming.
pub fn reportsRootMove(backend: Backend) RootMove {
    return switch (backend) {
        .auto => reportsRootMove(default_backend),
        .kqueue, .inotify => .renamed,
        .fsevents, .poll => .removed,
        .windows => .silent,
    };
}

/// Whether `backend` is told that a file open for writing has been
/// closed, and can report `Kind.closed`.
///
/// Only `inotify` is: `IN_CLOSE_WRITE` is the one signal any of these
/// mechanisms gets that a writer has actually finished rather than
/// paused. FSEvents, `kqueue`, `ReadDirectoryChangesW` and a listing
/// comparison all see writes and none of them sees a close.
///
/// This is why `Options.report_closes` is off by default and why this
/// predicate exists beside it: a kind that silently means nothing on
/// four backends out of five is worse than no kind at all. A program
/// that wants the end of a write everywhere uses `Options.settle_ms`,
/// which estimates it from a quiet window and works on all five.
pub fn reportsCloses(backend: Backend) bool {
    return switch (backend) {
        .auto => reportsCloses(default_backend),
        .inotify => true,
        .fsevents, .kqueue, .windows, .poll => false,
    };
}

/// Whether `backend` can leave an excluded directory unregistered, or
/// only drop the events coming out of it.
///
/// `AddOptions.filter` means the same thing to a caller on every backend:
/// the excluded paths are not reported. What differs is what it saves.
/// `inotify`, `kqueue` and `poll` recurse in lookout, so an excluded
/// directory is never opened, never registered, and costs neither a
/// kernel watch nor a descriptor nor a listing. FSEvents and
/// `ReadDirectoryChangesW` recurse in the kernel, which was never told
/// about the filter, so the tree is walked whatever the filter says and
/// only the events are dropped.
///
/// A program that filters to save resources rather than noise wants this
/// answer; one that filters to save itself the events does not care.
pub fn prunesIgnored(backend: Backend) bool {
    return switch (backend) {
        .auto => prunesIgnored(default_backend),
        .inotify, .kqueue, .poll => true,
        .fsevents, .windows => false,
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
/// `add` never issues the same value twice for the lifetime of the
/// `Watcher`, so an event carrying the id of a removed watch cannot be
/// confused with a later one.
///
/// One id is registered with a backend twice, and only one: a watch taken
/// with `AddOptions.pending` is registered on an ancestor while it waits
/// and registered again on the path itself when that appears, under the
/// id the caller already holds. A backend that keeps state past a
/// `remove` -- a buffer the kernel may still be writing into, say --
/// therefore cannot key that state on the id alone.
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
    /// the other three report a move differently or not at all, and
    /// `reportsRootMove` says which.
    renamed,
    /// Metadata other than the contents changed — permissions, ownership,
    /// link count, or the status-change time.
    attributes,
    /// A file that was open for writing has been closed: the writing is
    /// over, said by the operating system rather than inferred from a
    /// quiet window. It is the answer `Options.settle_ms` estimates.
    ///
    /// Only `inotify` is told this, so it is off unless
    /// `Options.report_closes` asks for it, and `reportsCloses` says
    /// whether this backend can ever produce one. A program that turns
    /// it on where it is not reported gets no `closed` events and the
    /// writes it would have reported still arrive as `modified`; nothing
    /// is lost, and nothing pretends.
    ///
    /// It outranks `modified` when both land on one path in a window,
    /// because a write that has finished is the more useful statement of
    /// the two. Set `Options.latency_ms` to zero to see each as it
    /// arrives instead.
    closed,
    /// Changes were lost and the caller should rescan the watch itself.
    /// Emitted when the kernel event queue overflowed, or when a watched
    /// directory holds more entries than `Options.max_dir_entries`. The
    /// `path` is the watch root, not an entry inside it.
    ///
    /// What was lost is not knowable from here -- the names are gone --
    /// but it is knowable from the tree. `Baseline`, seeded where the
    /// watch was taken, answers it: its `diff` returns the creations,
    /// changes and removals that the events would have carried.
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
    /// Spelled with the platform's own separator throughout: `/` on
    /// POSIX, `\` on Windows, including the part below the watch root.
    /// A program comparing an event against a path of its own builds it
    /// the same way — `std.fs.path.join` — rather than by pasting `/`
    /// between components.
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
    /// When lookout first saw this path change in this window, read from
    /// the `Io` the watcher was created with on the `awake` clock. It is
    /// comparable with the caller's own `std.Io.Timestamp.now(io, .awake)`
    /// and is not a wall clock.
    ///
    /// Coalescing merges several changes into one event, and this is the
    /// first of them rather than the last: the caller wants to know when
    /// the path started changing, not when lookout stopped collecting.
    time: Io.Timestamp = .zero,
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
    /// How long a path must be quiet before it is reported at all. Zero,
    /// the default, is off.
    ///
    /// This is the third and strongest of the three windows, and it
    /// answers a different question from the other two. `latency_ms`
    /// merges what arrives together and reports the most significant kind
    /// seen; `settle_ms` waits for a file's contents to stop changing.
    /// `debounce_ms` holds *every* kind until the path has been quiet for
    /// the window and then reports it once, carrying the kind seen
    /// **last** rather than the most significant one. A file created and
    /// then deleted inside one window is one `removed`; a file deleted
    /// and then recreated is one `created`, which coalescing cannot say
    /// because `removed` outranks `created`.
    ///
    /// That is what a caller rebuilding from the end state wants, and it
    /// is why it supersedes both of the others: a non-zero `debounce_ms`
    /// takes over from `settle_ms`, and `poll` returns as soon as a
    /// window closes rather than collecting for `latency_ms` more.
    debounce_ms: u32 = 0,
    /// Report `Kind.closed` when a file that was open for writing is
    /// closed. Off by default.
    ///
    /// Only `inotify` is told this, and `reportsCloses` says so; asking
    /// for it on a backend that cannot tell costs nothing and changes
    /// nothing. Where it can, the kernel is asked for `IN_CLOSE_WRITE`
    /// as well, and a path that was written and then closed inside one
    /// coalescing window reports `closed` rather than `modified` --
    /// which is the point, and is also why this is a choice rather than
    /// the default: a program that only wants to know a path changed
    /// should not have to learn a second kind meaning the same thing.
    report_closes: bool = false,
    /// How much change the Windows kernel may hold for one watch between
    /// two reads, in bytes. Ignored by every other backend.
    ///
    /// `ReadDirectoryChangesW` writes its records into a buffer lookout
    /// gives it, one per watch, and that buffer is how much the kernel
    /// can accumulate while no read is outstanding. When it fills, the
    /// change records are discarded and the next read says so, which
    /// lookout reports as `Kind.overflow` against the watch root: the
    /// record is incomplete and the tree should be read again.
    ///
    /// The default, 64 KiB, is what a network share will take; Windows
    /// refuses a larger one there. On a local disk a watch on a busy tree
    /// polled infrequently wants more. Sizes are held between 4 KiB --
    /// enough that one change with the longest possible name always fits
    /// -- and 16 MiB, and rounded down to a multiple of four; zero means
    /// the default. The buffer is non-paged pool for as long as a read is
    /// outstanding, so a large one on many watches is a real cost.
    windows_buffer_bytes: usize = 64 * 1024,
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
    /// What of this path the watch is about. The default excludes
    /// nothing.
    ///
    /// A filter is applied where lookout recurses, so on `inotify`,
    /// `kqueue` and `poll` an excluded directory is never registered and
    /// its tree costs nothing at all. FSEvents and
    /// `ReadDirectoryChangesW` recurse in the kernel, which cannot be
    /// told about a filter, so there the excluded events are dropped and
    /// the kernel does the work regardless -- `prunesIgnored` is how a
    /// program asks which it is getting.
    ///
    /// The patterns are copied by `Watcher.add`; `Filter.context` is
    /// not, and whatever it points at must outlive the watch.
    filter: Filter = .none,
    /// Accept a path that is not there yet, instead of failing the `add`
    /// with `error.FileNotFound`.
    ///
    /// The watch is put on the nearest existing ancestor, narrowed to the
    /// single entry that leads to the path asked for, and steps down as
    /// the path appears. When the path itself appears the watch is
    /// promoted to the real one -- recursion, filter and all -- and the
    /// appearance is reported as `Kind.created` against it. A tool
    /// watching a directory its own first run creates no longer has to
    /// poll for it.
    ///
    /// The id comes back from `add` immediately and is the id every event
    /// carries, before and after the promotion. Nothing that happens to
    /// the ancestor while the watch waits is reported: it is not what the
    /// caller asked about.
    ///
    /// The ancestor is a watch like any other, so it cannot be a path
    /// this same watcher already watches. When it is, the watch stays
    /// parked with nothing registered and is re-examined on every `poll`,
    /// which makes it as prompt as the polls rather than as prompt as the
    /// kernel.
    pending: bool = false,
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
    /// Watches whose path does not exist yet. See `AddOptions.pending`.
    pending: std.ArrayList(*Pending),

    /// A watch waiting for its path to appear.
    ///
    /// Heap-allocated and never moved: the ancestor watch's filter points
    /// at it, and that filter is asked from inside a backend.
    const Pending = struct {
        /// The id `add` returned, which the ancestor watch is registered
        /// under and which the real watch takes over.
        id: WatchId,
        /// The absolute path the caller asked for, canonical as far as it
        /// exists. Owned here, and the two slices below point into it.
        target: []u8,
        /// The ancestor currently watched, or `null` when none could be
        /// registered.
        anchor: ?[]const u8,
        /// The one entry of `anchor` that leads to `target`, which is the
        /// only thing the ancestor watch is about.
        next: []const u8,
        /// `AddOptions.recursive`, applied at the promotion.
        recursive: bool,
        /// `AddOptions.filter`, copied: the patterns it borrowed are long
        /// gone by the time the watch is promoted.
        filter: Filter,

        /// The ancestor watch's filter. Everything but the next step down
        /// is somebody else's business.
        fn onlyNext(context: ?*anyopaque, path: []const u8) bool {
            const p: *const Pending = @ptrCast(@alignCast(context.?));
            return std.mem.eql(u8, path, p.next);
        }
    };

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
            .pending = .empty,
        };
    }

    /// Releases every watch, every descriptor, and the events handed out
    /// by the last `poll`.
    pub fn deinit(w: *Watcher) void {
        switch (w.impl) {
            inline else => |*impl| impl.deinit(),
        }
        for (w.pending.items) |p| w.destroyPending(p);
        w.pending.deinit(w.gpa);
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
        const abs = Io.Dir.cwd().realPathFileAlloc(w.io, path, w.gpa) catch |err| switch (err) {
            error.FileNotFound => if (options.pending)
                return w.addPending(path, options)
            else
                return err,
            else => |e| return e,
        };
        defer w.gpa.free(abs);
        return w.register(abs, options);
    }

    /// Registers an absolute path that exists, and issues its id.
    fn register(w: *Watcher, abs: []const u8, options: AddOptions) AddError!WatchId {
        const id: WatchId = @enumFromInt(w.next_id);
        switch (w.impl) {
            inline else => |*impl| try impl.add(id, abs, options),
        }
        w.next_id += 1;
        return id;
    }

    /// Takes a watch on a path that is not there, parks it on the nearest
    /// existing ancestor, and issues its id. See `AddOptions.pending`.
    fn addPending(w: *Watcher, path: []const u8, options: AddOptions) AddError!WatchId {
        const target = try w.absentPath(path);
        errdefer w.gpa.free(target);
        // It may have appeared while its name was being spelled, in which
        // case there is nothing to wait for.
        if (w.exists(target)) {
            defer w.gpa.free(target);
            return w.register(target, options);
        }

        const p = try w.gpa.create(Pending);
        errdefer w.gpa.destroy(p);
        var filter = try options.filter.dupe(w.gpa);
        errdefer filter.deinit(w.gpa);

        const id: WatchId = @enumFromInt(w.next_id);
        p.* = .{
            .id = id,
            .target = target,
            .anchor = null,
            .next = target,
            .recursive = options.recursive,
            .filter = filter,
        };
        try w.pending.append(w.gpa, p);
        w.next_id += 1;
        w.anchorPending(p);
        return id;
    }

    /// The absolute path of something that is not there: canonical as far
    /// as it exists, and taken as written past that, because a name that
    /// does not exist has no symbolic links to resolve.
    fn absentPath(w: *Watcher, path: []const u8) AddError![]u8 {
        const lexical = lexical: {
            if (std.fs.path.isAbsolute(path)) break :lexical try std.fs.path.resolve(w.gpa, &.{path});
            const here = try Io.Dir.cwd().realPathFileAlloc(w.io, ".", w.gpa);
            defer w.gpa.free(here);
            break :lexical try std.fs.path.resolve(w.gpa, &.{ here, path });
        };
        errdefer w.gpa.free(lexical);

        const present = w.existingPrefix(lexical) orelse return lexical;
        const real = Io.Dir.cwd().realPathFileAlloc(w.io, present, w.gpa) catch return lexical;
        defer w.gpa.free(real);

        var rest = lexical[present.len..];
        while (rest.len != 0 and std.fs.path.isSep(rest[0])) rest = rest[1..];
        const joined = if (rest.len == 0)
            try w.gpa.dupe(u8, real)
        else
            try std.fs.path.join(w.gpa, &.{ real, rest });
        w.gpa.free(lexical);
        return joined;
    }

    /// The longest prefix of `path` that is there, as a slice of it.
    fn existingPrefix(w: *const Watcher, path: []const u8) ?[]const u8 {
        var candidate = path;
        while (true) {
            if (w.exists(candidate)) return candidate;
            candidate = std.fs.path.dirname(candidate) orelse return null;
        }
    }

    fn exists(w: *const Watcher, path: []const u8) bool {
        _ = Io.Dir.cwd().statFile(w.io, path, .{}) catch return false;
        return true;
    }

    /// Puts the watch on the nearest existing ancestor of a path that is
    /// not there yet, narrowed to the one entry that leads to it.
    ///
    /// Failing is not an error: the ancestor may be gone again, or may be
    /// a path this watcher already watches. The watch stays parked and
    /// the next `poll` tries again.
    fn anchorPending(w: *Watcher, p: *Pending) void {
        p.anchor = null;
        const present = w.existingPrefix(p.target) orelse return;
        if (present.len == p.target.len) return;
        p.next = p.target[0..nextStep(p.target, present.len)];
        switch (w.impl) {
            inline else => |*impl| impl.add(p.id, present, .{
                .filter = .{ .allow = Pending.onlyNext, .context = p },
            }) catch return,
        }
        p.anchor = present;
    }

    /// Where the component after the prefix of length `at` ends.
    fn nextStep(target: []const u8, at: usize) usize {
        var i = at;
        while (i < target.len and std.fs.path.isSep(target[i])) i += 1;
        while (i < target.len and !std.fs.path.isSep(target[i])) i += 1;
        return i;
    }

    /// Keeps the watches whose path is not there yet: drops the events of
    /// the ancestor each one is parked on, steps the parked ones down or
    /// up as the tree changes, and promotes any whose path has appeared.
    fn settlePending(w: *Watcher) PollError!void {
        if (w.pending.items.len == 0) return;
        for (w.pending.items) |p| w.batch.discard(w.gpa, p.id);

        var i: usize = 0;
        while (i < w.pending.items.len) {
            const p = w.pending.items[i];
            if (w.exists(p.target)) {
                if (try w.promotePending(p)) {
                    _ = w.pending.orderedRemove(i);
                    continue;
                }
            } else if (w.exists(p.next) or !w.anchorStands(p)) {
                // Something appeared on the way down, or the ancestor the
                // watch was parked on is itself gone. Either way the
                // parking place is no longer the right one.
                switch (w.impl) {
                    inline else => |*impl| impl.remove(p.id),
                }
                w.anchorPending(p);
            }
            i += 1;
        }
    }

    fn anchorStands(w: *const Watcher, p: *const Pending) bool {
        const anchor = p.anchor orelse return false;
        return w.exists(anchor);
    }

    /// Swaps the ancestor watch for the real one and reports the path
    /// appearing. `false` when the path could not be watched after all,
    /// which parks it again.
    fn promotePending(w: *Watcher, p: *Pending) PollError!bool {
        switch (w.impl) {
            inline else => |*impl| impl.remove(p.id),
        }
        switch (w.impl) {
            inline else => |*impl| impl.add(p.id, p.target, .{
                .recursive = p.recursive,
                .filter = p.filter,
            }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                // Gone again between the look and the registration, or
                // not ours to open. Park it and wait.
                else => {
                    w.anchorPending(p);
                    return false;
                },
            },
        }
        try w.batch.push(w.gpa, p.id, p.target, .created);
        w.destroyPending(p);
        return true;
    }

    fn destroyPending(w: *Watcher, p: *Pending) void {
        w.gpa.free(p.target);
        p.filter.deinit(w.gpa);
        w.gpa.destroy(p);
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
        for (w.pending.items, 0..) |p, i| {
            if (p.id != id) continue;
            _ = w.pending.orderedRemove(i);
            w.destroyPending(p);
            break;
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
            try w.settlePending();
            if (w.batch.events.items.len > 0) break;
            if (remainingMs(w.io, started, timeout_ms)) |l| {
                if (l == 0) return &.{};
            }
        }
        // Debouncing has already waited for the path to be quiet, so
        // there is nothing left for a coalescing tail to merge.
        if (timeout_ms == 0 or w.options.latency_ms == 0 or w.options.debounce_ms > 0)
            return w.batch.events.items;

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
            try w.settlePending();
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

    /// What a watcher is currently holding. See `stats`.
    pub const Stats = struct {
        /// Watches `add` has returned an id for and `remove` has not
        /// taken back.
        watches: usize,
        /// Paths the operating system has been told about on this
        /// watcher's behalf: one per kernel watch on `inotify`, one per
        /// open descriptor on `kqueue`, one per stream on `fsevents`, one
        /// per directory handle on `windows`, and one per path scanned on
        /// `poll`.
        ///
        /// This is the number that runs into the limits — the per-user
        /// cap on `inotify` watches, the per-process cap on descriptors —
        /// and the reason a recursive watch on a deep tree is not free on
        /// every backend. See the per-backend table in README.md.
        registrations: usize,
        /// Paths held back by `Options.settle_ms` or
        /// `Options.debounce_ms` and not yet reported.
        held: usize,
        /// Events the last `poll` returned, which the next one drops.
        events: usize,
    };

    /// What this watcher currently holds, for a program that wants to log
    /// it, cap it, or notice it growing.
    ///
    /// Cheap: every field is a count already kept, and nothing here asks
    /// the operating system anything.
    pub fn stats(w: *const Watcher) Stats {
        return .{
            .watches = switch (w.impl) {
                inline else => |*impl| impl.watchCount(),
            },
            .registrations = switch (w.impl) {
                inline else => |*impl| impl.registrationCount(),
            },
            .held = w.batch.held.count(),
            .events = w.batch.events.items.len,
        };
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
    _ = Baseline;
    _ = Batch;
    _ = Filter;
    _ = Tree;
    _ = @import("Snapshot.zig");
    _ = @import("test_suite.zig");
}
