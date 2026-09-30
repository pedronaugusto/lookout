//! lookout — one file-system watching API over FSEvents, `kqueue`,
//! `inotify`, `ReadDirectoryChangesW` and polling.
//!
//! A `Watcher` owns a set of watches. Each watch is a path — a file or a
//! directory — added with `Watcher.add`, changed with `Watcher.refilter`,
//! and dropped with `Watcher.remove`.
//! `Watcher.poll` blocks until something happens and hands back the events
//! that happened, one per path, coalesced.
//!
//! The library starts no threads and calls nothing back. Everything happens
//! on the thread that calls `poll`, and a program with a loop of its own can
//! take `Watcher.fd` and wait on the watcher alongside its other descriptors.
//!
//! `poll` is a `std.Io` cancellation point on every backend, and a
//! cancellation never costs an event: see `Watcher.poll`. What ends a poll
//! that is blocked differs by backend, and `Watcher.wake` is the one way that
//! works on all of them.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const Batch = @import("Batch.zig");
const Deadline = @import("Deadline.zig");
const Tree = @import("Tree.zig");
const Waker = @import("Waker.zig");
const walk = @import("walk.zig");
const path_cmp = @import("path.zig");

/// Paths compared as a watch compares them: the same case folding and
/// separators (`folds_case`).
pub const path = struct {
    /// The part of `p` below `base`, as a slice of `p`: empty when they
    /// name the same place, null when `p` is outside `base`.
    pub const relative = path_cmp.relative;
    /// Whether `p` is `base` or under it.
    pub const within = path_cmp.within;
};

test "public path helpers use watch path comparisons" {
    const testing = std.testing;
    try testing.expectEqualStrings("file", path.relative("/watch", "/watch/file").?);
    try testing.expect(path.within("/watch", "/watch"));
    try testing.expect(!path.within("/watch", "/watcher/file"));
    if (folds_case) try testing.expectEqualStrings("file", path.relative("/WATCH", "/watch/file").?);
}

test "failed overflow reporting leaves the lost watch queued for retry" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    defer gpa.free(root);
    var watcher = try Watcher.init(gpa, testing.io, .{ .backend = .poll });
    defer watcher.deinit();
    const id = try watcher.add(root, .{});
    try watcher.batch.dropped.put(gpa, id, {});
    var failing = testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    {
        watcher.gpa = failing.allocator();
        defer watcher.gpa = gpa;
        try testing.expectError(error.OutOfMemory, watcher.collect());
        try testing.expect(watcher.batch.dropped.contains(id));
    }
    try watcher.collect();
    try testing.expectEqual(@as(usize, 0), watcher.batch.dropped.count());
    try testing.expectEqual(@as(usize, 1), watcher.batch.events.items.len);
    try testing.expectEqual(Kind.overflow, watcher.batch.events.items[0].kind);
}

/// Which paths under a watch the caller wants. See `AddOptions.filter`.
pub const Filter = @import("Filter.zig");

/// Whether lookout applies its portable ASCII/Latin-1 case and composition
/// folding, or compares paths byte for byte. See `path.zig` for the exact
/// supported range and its limitation outside Latin-1.
pub const folds_case = @import("path.zig").folds_case;

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
    /// descriptor per directory, and renames arrive paired. Its system
    /// delivery has a measured roughly ten-millisecond floor even when
    /// `Options.latency_ms` is zero.
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
    /// Re-stat and re-list watched paths on a timer. Needs no notification
    /// queue, but holds a handle per watched directory, at the cost of
    /// latency and of walking every watched directory on every tick.
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
///
/// Where renames are paired, a name the watch's filter excludes is
/// treated exactly as a name outside the watch. Both names kept is
/// `renamed`; only the new one kept is `created` there, as a rename in
/// from outside is; only the old one kept is `removed` there, as a
/// rename out of the watch is; neither is nothing. So a file saved by
/// writing an excluded temporary name and renaming it over a watched one
/// is `created` at the watched name, and an event never names an
/// excluded path, as `Event.path` or as `Event.from`.
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
/// flag that does not say which; both say `removed`. `windows` holds a
/// directory handle that a rename leaves valid, and the rename happens
/// in the parent directory, which the watch was not put on: nothing is
/// delivered, and `silent` says so rather than leaving a caller waiting
/// for an event that is not coming.
///
/// The answer is absolute: a backend gives the shape named here and
/// never one of the other two, so a caller may switch on it without a
/// fallback arm.
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
/// renames. `kqueue` remains explicitly selectable when lower latency on
/// a small tree matters more than either property; it reports a rename as
/// a removal and a creation.
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

/// Where a watcher had got to, so that a later one can carry on from
/// there.
///
/// An owned resume snapshot, including changes poll has not handed out.
pub const Checkpoint = @import("Checkpoint.zig");

/// Whether the backend has a persistent log that checkpoints can resume.
/// Other backends return null from Watcher.checkpoint and ignore the option.
pub fn tracksCheckpoint(backend: Backend) bool {
    return switch (backend) {
        .auto => tracksCheckpoint(default_backend),
        .fsevents => true,
        .kqueue, .inotify, .windows, .poll => false,
    };
}

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
/// observed, in this order: `attributes` < `modified` < `closed` <
/// `created` < `renamed` < `removed` < `overflow` < `unwatched`. A path
/// created and then written inside one window reports `created`; a path
/// written and then deleted reports `removed`.
/// With `Options.debounce_ms`, ordinary changes report the kind seen last.
/// `overflow` and `unwatched` bypass holding in every mode and keep the
/// precedence above: neither can be replaced by an ordinary change, and
/// `unwatched` wins when both loss notices name the same watch and path.
/// A loss notice clears any held change on that path; later changes in
/// the same batch cannot start another hold there.
pub const Kind = enum {
    /// The path did not exist at the previous observation and does now.
    created,
    /// The contents of the path changed: a different size, a different
    /// modification time, or a write reported by the kernel.
    modified,
    /// The path no longer exists. A rename of an entry inside a watched
    /// directory is reported this way only where the operating system
    /// cannot pair the two halves; where it can, one `renamed` carrying
    /// `Event.from` is reported instead, and `pairsRenames` says which
    /// of the two this backend does.
    ///
    /// When the path is a watch's own root, that watch stops there: a
    /// path is watched, not a name, and the name is now empty. The id
    /// stays valid and `Watcher.remove` still releases it.
    removed,
    /// A path was renamed. `Event.path` is where it is now and
    /// `Event.from` is where it was, on the backends `pairsRenames` is
    /// true for.
    ///
    /// Against a watch's own root it means something else and carries no
    /// `from`: the watched path itself was moved, so the watch no longer
    /// stands for the name it was added under and stops, exactly as for
    /// a `removed` root. Which backends say that, and what the others
    /// say instead, is `reportsRootMove`.
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
    /// lookout is no longer watching this path, and nothing that happens
    /// to it or below it will be reported. The watch itself is still
    /// alive and its other paths still report; this one is a hole in it.
    ///
    /// It is what a registration the operating system refused looks like
    /// from the outside: a subdirectory of a recursive watch that could
    /// not be opened or that the per-user watch limit had no room for,
    /// or on Windows a read that could not be posted again. Each of
    /// those used to be swallowed, which left a subtree silently quiet
    /// with no error and no event -- the worst thing a watcher can be.
    ///
    /// Like `overflow` it is not an error, and it outranks it: an
    /// `overflow` says look again, and this says looking again is the
    /// only way you will ever hear about this path. A caller that wants
    /// the path back adds a watch on it.
    unwatched,
};

/// What an event's path is, where the backend knows.
pub const Target = enum {
    /// A regular file, a symbolic link, or anything else that is not a
    /// directory.
    file,
    /// A directory.
    directory,
    /// The backend was not told and the path can no longer be asked:
    /// it is gone by the time the event is read. `Kind.removed` of an
    /// entry inside a watched directory on `windows` is the one that
    /// lands here; a watched path itself is remembered from when the
    /// watch was added.
    unknown,

    /// What a listing or a `stat` found, as a target.
    pub fn of(kind: Io.File.Kind) Target {
        return if (kind == .directory) .directory else .file;
    }
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
    /// Always a path the watch is about. A rename from a name outside the
    /// watch, or from one its filter excludes, is `Kind.created` at the
    /// new name and carries no `from`; see `pairsRenames`.
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
    /// Whether the path is a file or a directory.
    ///
    /// After a `Kind.removed` the path cannot be stat-ed to find out, so
    /// a caller keeping a model of the tree needs to be told. Every
    /// backend is told by the operating system, except that
    /// `ReadDirectoryChangesW` says nothing about an entry that is
    /// already gone; that one is `unknown`. A watched path itself is
    /// always known, on every backend, from when the watch was added.
    target: Target = .unknown,
};

/// How a `Watcher` behaves, fixed for its lifetime.
pub const Options = struct {
    /// Which mechanism to use. See `Backend`, `default_backend` and
    /// `supported`.
    backend: Backend = .auto,
    /// How long the `poll` backend waits between scans. Ignored by every
    /// other backend. Zero is clamped to one millisecond so a quiet
    /// indefinite poll still blocks instead of scanning in a busy loop.
    poll_interval_ms: u32 = 500,
    /// How long `Watcher.poll` keeps collecting after the first event of a
    /// batch arrives. Everything that lands on one path inside that window
    /// becomes a single `Event`, so a program is not woken once per write
    /// of a file being saved. Zero disables the wait and reports whatever
    /// is already queued. FSEvents uses the same window for its stream and
    /// requests delivery of the first event without waiting for the rest
    /// of the window. Zero asks the system for no additional delay; on
    /// macOS the measured system-delivery floor is still roughly ten
    /// milliseconds.
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
    /// How long an ordinary change must be quiet before it is reported. Zero,
    /// the default, is off.
    ///
    /// This is the third and strongest of the three windows, and it
    /// answers a different question from the other two. `latency_ms`
    /// merges what arrives together and reports the most significant kind
    /// seen; `settle_ms` waits for a file's contents to stop changing.
    /// `debounce_ms` holds every ordinary kind until the path has been quiet for
    /// the window and then reports it once, carrying the kind seen
    /// **last** rather than the most significant one. A file created and
    /// then deleted inside one window is one `removed`; a file deleted
    /// and then recreated is one `created`, which coalescing cannot say
    /// because `removed` outranks `created`.
    /// `overflow` and `unwatched` are immediate and retain their precedence
    /// over ordinary changes; see `Kind`.
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
    /// How much change may accumulate between two polls, in bytes, on
    /// the backends that are handed a buffer and find the changes in it.
    /// Zero, the default, is each backend's own.
    ///
    /// On `windows` this is the buffer `ReadDirectoryChangesW` writes
    /// its records into, one per watch. Its default is 64 KiB, which is
    /// what a network share will take -- Windows refuses a larger one
    /// there, and lookout falls back to it by itself if a larger one is
    /// refused. Sizes are held between 4 KiB and 16 MiB.
    ///
    /// On `fsevents` this is the buffer the system's delivery thread
    /// copies into, one per watcher, which is what lets that thread do a
    /// bounded `memcpy` and nothing else. Its default is 4 MiB, enough
    /// to hold a burst of ten thousand paths without losing one. Sizes
    /// are held between 4 KiB and 64 MiB.
    ///
    /// When the buffer does fill, the changes that did not fit are lost
    /// and `Kind.overflow` says so against the watch root. A watch on a
    /// busy tree that is polled infrequently wants more; the memory is
    /// held for the life of the watcher, and on Windows it is non-paged
    /// pool for as long as a read is outstanding, so a large one on many
    /// watches is a real cost.
    ///
    /// The other three backends are told what changed by the kernel or
    /// find it by listing, and ignore this.
    buffer_bytes: usize = 0,
    /// Resume from an earlier Watcher.checkpoint. Borrowed only by init,
    /// which copies what it keeps. Recreate the same watched paths, scopes
    /// and filters. Watches are matched by their canonical requested roots.
    /// Pending changes are restored and new log records are resolved against
    /// the current tree. Backends without a persistent log ignore this.
    checkpoint: ?Checkpoint = null,
    /// The most events one `poll` will hold, past which it stops
    /// collecting names and says `Kind.overflow` against the watch roots
    /// that lost them. Zero means no ceiling at all.
    ///
    /// A watcher holds one event and one path per changed path until the
    /// next `poll`, so a process writing a million files faster than the
    /// caller polls made the library grow without bound. The default is
    /// high enough that no ordinary burst reaches it and low enough to
    /// be a ceiling.
    max_events: usize = 100_000,
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
    ///
    /// It is the budget of a directory a watch reports the entries of:
    /// a watched directory, and every directory below it for a recursive
    /// watch. A watch on a file has none. It is about one entry, and no
    /// backend tells it when the folder the file is in is past the
    /// budget -- Windows and FSEvents read that folder to see the file,
    /// but are told nothing about its other entries through that watch.
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
    /// An excluded path is treated exactly as a path outside the watch,
    /// including as one half of a rename: see `pairsRenames`.
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
    /// appearance is reported as `Kind.created` against it, with whatever
    /// the directory already holds by then that the watch would report.
    /// A tool
    /// watching a directory its own first run creates no longer has to
    /// poll for it.
    ///
    /// The id comes back from `add` immediately and is the id every event
    /// carries, before and after the promotion. Nothing that happens to
    /// the ancestor while the watch waits is reported: it is not what the
    /// caller asked about.
    ///
    /// The ancestor is not taken by the wait. A watch of that same folder
    /// added before or after is a watch of its own and succeeds, rather
    /// than failing with `error.PathAlreadyWatched`; each reports what it
    /// is about, and the parked watch still promotes when its path
    /// appears. Several pending watches may wait in one folder.
    ///
    /// The path it waits for is taken, though, from the `add` on: a
    /// second `add` of that path, pending or not, is
    /// `error.PathAlreadyWatched`, before the path appears and after,
    /// exactly as for a watch taken on a path that was there. So the
    /// answer does not depend on whether a `poll` has promoted it yet.
    /// A path that turns out to be one another watch already has -- a
    /// symbolic link on the way to it that leads there -- is not
    /// watched twice either: the watch is not promoted, and says
    /// `Kind.unwatched` against its path.
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
    /// Every watch `add` has issued an id for, in the order it issued
    /// them. Kept here rather than in the backends because all five had
    /// the same table and the same linear scan over it, and because a
    /// watch's root is what `Kind.overflow` is reported against.
    table: std.AutoArrayHashMapUnmanaged(WatchId, Held),
    /// Watches whose path does not exist yet. See `AddOptions.pending`.
    pending: std.ArrayList(*Pending),
    /// Set by `wake` and cleared by the `poll` that answers it. One of
    /// the two fields of a `Watcher` another thread may touch.
    woken: std.atomic.Value(bool),
    /// How `wake` reaches the backend's wait, taken from it at `init` and
    /// only read after: the other field another thread may touch. `wake`
    /// never touches `impl`, which is the polling thread's to write.
    waker: Waker,
    /// Whether the events in `batch` were handed to the caller by the last
    /// `poll`, and so are the caller's until the next one begins. A `poll`
    /// that returned an error handed nothing out, and what it had gathered
    /// is still the next one's to return.
    handed_out: bool,

    /// What the watcher remembers about one watch.
    const Held = struct {
        /// The path the caller asked for, absolute and canonical as far
        /// as it exists. Owned here.
        path: []u8,
        /// The path the backend currently holds a registration on: the
        /// same path, or an ancestor while a pending watch waits, or
        /// `null` when nothing could be registered at all. Owned here.
        ///
        /// Where it is registered has no say in what it claims. `path` is
        /// the watch's whether it is registered there, on an ancestor, or
        /// nowhere yet, and an ancestor is never taken by a wait in it --
        /// see `claimed`.
        registered: ?[]u8,
        /// The type of the caller's root, retained for root-level events
        /// after the path can no longer be stat-ed.
        target: Target,
        /// `AddOptions.recursive`.
        recursive: bool,
        /// An allocation failure may have interrupted this watch's delivery.
        /// Set without allocation and cleared only after its notice is handed out.
        incomplete: bool = false,
    };

    /// One watch, as `watches` reports it.
    pub const WatchInfo = struct {
        /// The id `add` returned.
        id: WatchId,
        /// The path the caller asked for. Owned by the watcher and valid
        /// until the next `add`, `remove` or `deinit`.
        path: []const u8,
        /// `AddOptions.recursive`.
        recursive: bool,
        /// Whether the path is still not there, so the watch is parked
        /// on an ancestor. See `AddOptions.pending`.
        waiting: bool,
    };

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
        fn onlyNext(context: ?*anyopaque, subject: []const u8) bool {
            const p: *const Pending = @ptrCast(@alignCast(context.?)); // safe: the filter's context is the Pending it was made with
            return path_cmp.eql(subject, p.next);
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

    /// Errors `init` can return when creating the backend's resources.
    /// FSEvents also allocates its delivery sink and `Options.buffer_bytes`
    /// buffer here, even with no watches. Allocator failures are
    /// `OutOfMemory`. Other backends allocate as watches are added.
    pub const InitError = error{
        /// `Options.backend` names a backend this target was not built
        /// with. See `supported`.
        BackendUnavailable,
        /// The system-wide descriptor table is full.
        SystemFdQuotaExceeded,
        /// This process may not open another descriptor.
        ProcessFdQuotaExceeded,
        /// The system could not create the notification queue.
        SystemResources,
        /// The allocator could not create the FSEvents delivery sink or buffer.
        OutOfMemory,
    } || UnexpectedError;

    /// Errors `add` can return, on top of the file-system errors of
    /// resolving and opening the path.
    pub const AddError = error{
        /// The kernel refused another watch: the per-process or
        /// system-wide limit on watches or descriptors is reached.
        WatchLimitReached,
        /// This watcher already watches that path. See `add`.
        PathAlreadyWatched,
    } || Tree.AddError || UnexpectedError;

    /// Errors changing a live watch's filter.
    pub const RefilterError = AddError || error{UnknownWatch};

    /// Errors `poll` can return, on top of the file-system errors of
    /// re-reading watched directories.
    ///
    /// One set for every backend, and true for every one of them.
    /// `error.Canceled` is in it because `poll` is a cancellation point on
    /// all five: see `poll` for where. The backend is chosen when the
    /// watcher is made, not when the program is compiled, so a set per
    /// backend would be a set per value of `Options.backend` — and every
    /// backend re-reads directories through `std.Io`, whose file-system
    /// errors carry `error.Canceled` anyway.
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
        var kept_options = options;
        kept_options.checkpoint = null; // Only the resuming backend owns the copy.
        return .{
            .gpa = gpa,
            .io = io,
            .options = kept_options,
            .batch = .init(io, options),
            .next_id = 0,
            .impl = impl,
            .table = .empty,
            .pending = .empty,
            .woken = .init(false),
            .waker = switch (impl) {
                inline else => |*backend_impl| backend_impl.waker(),
            },
            .handed_out = false,
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
        for (w.table.values()) |*held| w.release(held);
        w.table.deinit(w.gpa);
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
    ///
    /// A cancellation already requested is `error.Canceled`, and nothing is
    /// added. One requested while the `add` runs is left for the next
    /// cancellation point: a recursive watch is registered directory by
    /// directory, and one stopped half way would be neither a watch nor a
    /// failure to take one.
    pub fn add(w: *Watcher, requested: []const u8, options: AddOptions) AddError!WatchId {
        try w.io.checkCancel();
        const protection = w.io.swapCancelProtection(.blocked);
        defer _ = w.io.swapCancelProtection(protection);

        // The backend copies what it keeps, so this resolution is scratch
        // and a failed `add` leaves nothing behind.
        const abs = Io.Dir.cwd().realPathFileAlloc(w.io, requested, w.gpa) catch |err| switch (err) {
            error.FileNotFound => if (options.pending)
                return w.addPending(requested, options)
            else
                return err,
            else => |e| return e,
        };
        defer w.gpa.free(abs);
        return w.register(abs, options);
    }

    /// Registers an absolute path that exists, and issues its id.
    fn register(w: *Watcher, abs: []const u8, options: AddOptions) AddError!WatchId {
        if (w.claimed(abs)) return error.PathAlreadyWatched;
        const stat = try Io.Dir.cwd().statFile(w.io, abs, .{ .follow_symlinks = false });
        const id: WatchId = @enumFromInt(w.next_id);
        const owned = try w.gpa.dupe(u8, abs);
        errdefer w.gpa.free(owned);
        const mirror = try w.gpa.dupe(u8, abs);
        errdefer w.gpa.free(mirror);
        try w.table.ensureUnusedCapacity(w.gpa, 1);
        try w.addBackend(id, abs, abs, options);
        w.table.putAssumeCapacity(id, .{
            .path = owned,
            .registered = mirror,
            .target = .of(stat.kind),
            .recursive = options.recursive,
        });
        w.next_id += 1;
        return id;
    }

    /// Backend registrations may live on an ancestor; resume identity is
    /// always the caller's root, owned by Watcher.
    fn addBackend(w: *Watcher, id: WatchId, physical: []const u8, requested: []const u8, options: AddOptions) AddError!void {
        if (comptime @hasField(Impl, "fsevents")) {
            if (w.impl == .fsevents) return w.impl.fsevents.addFor(id, physical, requested, options, &w.batch);
        }
        switch (w.impl) {
            inline else => |*impl| try impl.add(id, physical, options, &w.batch),
        }
    }

    /// Whether some watch already watches `abs` itself, or waits for it.
    ///
    /// Every watch claims the path it was asked for, and nothing else. A
    /// pending watch claims the path it waits for from the moment it is
    /// added, so that a second watch of that path is refused whether or
    /// not a `poll` has promoted the first yet; allowing it until then
    /// left two registrations on one path once the promotion came.
    ///
    /// The ancestor a pending watch is parked on is not claimed. It holds
    /// a registration there, but that ancestor is not what anybody asked
    /// to watch: a caller who then asks for it gets a watch of their own,
    /// and a second pending watch may park on it as well. The backends
    /// keep such watches apart -- `inotify` by giving one kernel watch
    /// several owners, the others by registering each one separately.
    fn claimed(w: *const Watcher, abs: []const u8) bool {
        return w.claimedBesides(abs, null);
    }

    /// `claimed`, leaving out the watch `own`.
    fn claimedBesides(w: *const Watcher, abs: []const u8, own: ?WatchId) bool {
        for (w.table.keys(), w.table.values()) |id, held| {
            if (own == id) continue;
            if (path_cmp.eql(held.path, abs)) return true;
        }
        return false;
    }

    fn release(w: *Watcher, held: *Held) void {
        w.gpa.free(held.path);
        if (held.registered) |registered| w.gpa.free(registered);
        held.* = undefined;
    }

    /// The root `Kind.overflow` is reported against for a watch.
    fn rootOf(w: *const Watcher, id: WatchId) ?[]const u8 {
        return (w.table.get(id) orelse return null).path;
    }

    fn rootTarget(w: *const Watcher, id: WatchId) Target {
        return (w.table.get(id) orelse return .unknown).target;
    }

    /// Takes a watch on a path that is not there, parks it on the nearest
    /// existing ancestor, and issues its id. See `AddOptions.pending`.
    fn addPending(w: *Watcher, requested: []const u8, options: AddOptions) AddError!WatchId {
        const target = try w.absentPath(requested);
        var owns_target = true;
        defer if (owns_target) w.gpa.free(target);
        // It may have appeared while its name was being spelled, in which
        // case there is nothing to wait for.
        if (w.exists(target)) {
            return w.register(target, options);
        }

        if (w.claimed(target)) return error.PathAlreadyWatched;
        const p = try w.gpa.create(Pending);
        errdefer w.gpa.destroy(p);
        var filter = try options.filter.dupe(w.gpa);
        errdefer filter.deinit(w.gpa);

        const id: WatchId = @enumFromInt(w.next_id);
        const owned = try w.gpa.dupe(u8, target);
        errdefer w.gpa.free(owned);
        try w.table.put(w.gpa, id, .{
            .path = owned,
            .registered = null,
            .target = .unknown,
            .recursive = options.recursive,
        });
        errdefer _ = w.table.swapRemove(id);
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
        owns_target = false;
        return id;
    }

    /// The absolute path of something that is not there: canonical as far
    /// as it exists, and taken as written past that, because a name that
    /// does not exist has no symbolic links to resolve.
    fn absentPath(w: *Watcher, requested: []const u8) AddError![]u8 {
        const lexical = lexical: {
            if (std.fs.path.isAbsolute(requested)) break :lexical try std.fs.path.resolve(w.gpa, &.{requested});
            const here = try Io.Dir.cwd().realPathFileAlloc(w.io, ".", w.gpa);
            defer w.gpa.free(here);
            break :lexical try std.fs.path.resolve(w.gpa, &.{ here, requested });
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
    fn existingPrefix(w: *const Watcher, requested: []const u8) ?[]const u8 {
        var candidate = requested;
        while (true) {
            if (w.exists(candidate)) return candidate;
            candidate = std.fs.path.dirname(candidate) orelse return null;
        }
    }

    fn exists(w: *const Watcher, requested: []const u8) bool {
        _ = Io.Dir.cwd().statFile(w.io, requested, .{}) catch return false;
        return true;
    }

    /// Puts the watch on the nearest existing ancestor of a path that is
    /// not there yet, narrowed to the one entry that leads to it.
    ///
    /// Failing is not an error: the ancestor may be gone again. The watch
    /// stays parked and the next `poll` tries again.
    ///
    /// The ancestor may be a path this watcher already watches, or one
    /// another pending watch is parked on. The registration is this
    /// watch's own either way, under its own id and its own filter, so
    /// neither watch hears the other's events or loses its own.
    fn anchorPending(w: *Watcher, p: *Pending) void {
        p.anchor = null;
        w.unregister(p.id);
        const present = w.existingPrefix(p.target) orelse return;
        if (present.len == p.target.len) return;
        p.next = p.target[0..nextStep(p.target, present.len)];
        const mirror = w.gpa.dupe(u8, present) catch return;
        w.addBackend(p.id, present, p.target, .{
            .filter = .{ .allow = Pending.onlyNext, .context = p },
        }) catch {
            w.gpa.free(mirror);
            return;
        };
        if (w.table.getPtr(p.id)) |held| held.registered = mirror else w.gpa.free(mirror);
        p.anchor = present;
    }

    /// Forgets what the backend was registered on for `id`, without
    /// touching the backend itself.
    fn unregister(w: *Watcher, id: WatchId) void {
        const held = w.table.getPtr(id) orelse return;
        if (held.registered) |registered| w.gpa.free(registered);
        held.registered = null;
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
                // What appeared between the look and the new registration
                // has no event of its own — `mkdir -p` makes the next step
                // and the path in one breath — so this one is looked at
                // again now: promoted if the path is there, moved again if
                // another step is. A wait with no deadline would otherwise
                // hold it parked on nothing until some other change.
                if (w.exists(p.target)) {
                    if (try w.promotePending(p)) {
                        _ = w.pending.orderedRemove(i);
                        continue;
                    }
                } else if (p.anchor != null and w.exists(p.next)) continue;
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
    ///
    /// A path that is, once it is there, one another watch already has
    /// -- reached through a symbolic link that appeared on the way -- is
    /// not registered a second time: the watch stops waiting and says
    /// `Kind.unwatched`, as an `add` of that path would have been
    /// refused. `true` then too, because it is no longer waiting.
    fn promotePending(w: *Watcher, p: *Pending) PollError!bool {
        switch (w.impl) {
            inline else => |*impl| impl.remove(p.id),
        }
        w.unregister(p.id);
        if (try w.takenElsewhere(p)) {
            try w.batch.pushDetail(w.gpa, p.id, p.target, .unwatched, null, .unknown);
            w.destroyPending(p);
            return true;
        }
        const target = target: {
            const stat = Io.Dir.cwd().statFile(w.io, p.target, .{ .follow_symlinks = false }) catch
                break :target Target.unknown;
            break :target Target.of(stat.kind);
        };
        {
            // This scope owns the mirror only until the backend and table
            // take the registration. Reporting below may still fail, but
            // then unregister or deinit owns its eventual release.
            const mirror = try w.gpa.dupe(u8, p.target);
            errdefer w.gpa.free(mirror);
            w.addBackend(p.id, p.target, p.target, .{
                .recursive = p.recursive,
                .filter = p.filter,
            }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    w.gpa.free(mirror);
                    w.anchorPending(p);
                    return false;
                },
            };
            if (w.table.getPtr(p.id)) |held| {
                held.registered = mirror;
                held.target = target;
            } else w.gpa.free(mirror);
        }
        try w.batch.pushDetail(w.gpa, p.id, p.target, .created, null, target);
        if (target == .directory) try w.reportMade(p);
        w.destroyPending(p);
        return true;
    }

    /// Reports as created what a promoted directory already holds: what
    /// was made in it between its appearing and the watch taken on it,
    /// which no watch was there to see -- `mkdir -p` and a write into the
    /// new folder are one breath. Only what the watch would report: its
    /// filter, and below the first level only when it recurses. The batch
    /// keeps one event per path, so a backend that reports the same entry
    /// itself reports it once.
    fn reportMade(w: *Watcher, p: *const Pending) PollError!void {
        const Made = struct {
            w: *Watcher,
            p: *const Pending,

            fn visit(m: @This(), entry: walk.Entry) anyerror!walk.Step {
                if (m.p.filter.prunes(m.p.target, entry.path)) return .over;
                if (!m.p.filter.excludes(m.p.target, entry.path)) {
                    try m.w.batch.pushDetail(m.w.gpa, m.p.id, entry.path, .created, null, Target.of(entry.kind));
                }
                return if (entry.kind == .directory and m.p.recursive) .into else .over;
            }
        };
        walk.tree(w.gpa, w.io, p.target, Made{ .w = w, .p = p }, Made.visit) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // gone again, or not ours to read: the watch says the rest
            else => {},
        };
    }

    /// Whether the path a pending watch waited for, now that it is there,
    /// resolves to a path another watch has.
    fn takenElsewhere(w: *Watcher, p: *const Pending) Allocator.Error!bool {
        const real = Io.Dir.cwd().realPathFileAlloc(w.io, p.target, w.gpa) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // Gone again, or not ours to resolve: the registration that
            // follows finds out which.
            else => return false,
        };
        defer w.gpa.free(real);
        return w.claimedBesides(real, p.id);
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
        if (w.table.fetchSwapRemove(id)) |entry| {
            var held = entry.value;
            w.release(&held);
        }
        for (w.pending.items, 0..) |p, i| {
            if (p.id != id) continue;
            _ = w.pending.orderedRemove(i);
            w.destroyPending(p);
            break;
        }
        w.batch.discardFuture(w.gpa, id);
    }

    /// Replaces the filter of a live watch without changing its id, root or
    /// recursion. Patterns are copied; the predicate context remains the
    /// caller's and must outlive this filter. An unknown id is an error.
    ///
    /// On return, every collected event not yet returned by `poll`,
    /// including an event held for debouncing or settling, is reconciled
    /// with the new filter: an excluded path is dropped, and a rename
    /// from an excluded path into an included one becomes a creation.
    /// Events already returned by `poll` stay valid and are not replayed.
    /// Queued backend records are tested against the new filter when read;
    /// changes completed after return use it too, subject to the backend's
    /// usual event-loss limits.
    /// There is no snapshot boundary for a write overlapping this call:
    /// a short-lived file in a newly admitted directory may be gone
    /// before that directory is registered, as during recursive `add`.
    /// Existing newly admitted directories are registered before return
    /// where the backend registers directories individually. A pending
    /// watch keeps the replacement filter for its eventual promotion.
    pub fn refilter(w: *Watcher, id: WatchId, filter: Filter) RefilterError!void {
        if (!w.table.contains(id)) return error.UnknownWatch;
        try w.io.checkCancel();
        const protection = w.io.swapCancelProtection(.blocked);
        defer _ = w.io.swapCancelProtection(protection);
        for (w.pending.items) |p| {
            if (p.id != id) continue;
            const replacement = try filter.dupe(w.gpa);
            p.filter.deinit(w.gpa);
            p.filter = replacement;
            return;
        }
        switch (w.impl) {
            inline else => |*impl| try impl.refilter(id, filter, &w.batch),
        }
        w.batch.refilter(w.gpa, id, w.table.get(id).?.path, filter, w.handed_out);
    }

    /// Waits for something to happen and returns what did.
    ///
    /// Blocks until at least one event arrives or `timeout_ms`
    /// milliseconds pass; `null` blocks indefinitely, and `0` performs a
    /// single non-blocking check and returns. Once the first event of a
    /// batch arrives, collection continues for `Options.latency_ms` more
    /// so that a burst on one path becomes one event; a `timeout_ms` of
    /// `0` skips that wait.
    /// `overflow` and `unwatched` bypass settling and debouncing and remain
    /// in the batch until handed out, even if later ordinary changes name
    /// the same path. See `Kind` for precedence.
    ///
    /// The returned slice, and every path in it, is owned by the watcher
    /// and is invalidated by the next call to `poll` or by `deinit`. An
    /// empty slice means the timeout expired with nothing to report.
    ///
    /// **Allocation failure.** An `OutOfMemory` hands nothing out. Retry
    /// `poll`: backends keep unread deliveries where possible, and the
    /// retry reports `overflow` against every still-live watch root before
    /// it can return successfully, even after a wake. Rescan those roots.
    /// Recovery notices survive further allocation failures and bypass
    /// settling and debouncing. Events already gathered remain available.
    ///
    /// **Cancellation.** `poll` is a `std.Io` cancellation point on every
    /// backend: a cancellation requested before it is called, or while it
    /// waits, is `error.Canceled`. It is looked for on entry and each time
    /// the backend's wait comes back, and nowhere else — never half way
    /// through reading what the kernel reported, which runs under
    /// `std.Io`'s cancel protection. So a cancellation costs no event: a
    /// `poll` that returns an error has handed nothing out, and whatever it
    /// had gathered is returned by the next one.
    ///
    /// What ends a poll that is *blocked* is the part that differs. The
    /// `poll` backend waits in an `Io` sleep, and a cancellation ends that
    /// sleep. The kernel backends wait in the kernel — `kevent`, `poll(2)`
    /// on an inotify descriptor or on the FSEvents pipe, an I/O completion
    /// port — where `std.Io` has no way to reach, so the wait ends when
    /// something happens, when the timeout runs out, or when `wake` is
    /// called, and the cancellation is reported then. `wake` is the one way
    /// to end a blocked poll that works on every backend; see it for how to
    /// stop a task that is polling.
    pub fn poll(w: *Watcher, timeout_ms: ?u32) PollError![]const Event {
        // What the last `poll` handed out is the caller's until now. What a
        // `poll` that failed gathered was never handed out, and is this
        // one's to return.
        if (w.handed_out) w.batch.reset(w.gpa);
        w.handed_out = false;
        try w.io.checkCancel();
        const events = w.gather(timeout_ms) catch |err| {
            if (err == error.OutOfMemory) {
                // A shared delivery can touch several roots, and a failed
                // operation may already have changed backend bookkeeping.
                // Conservatively include every live watch; no allocation
                // or backend-owned path is needed to remember the loss.
                for (w.table.values()) |*held| held.incomplete = true;
            }
            return err;
        };
        for (w.table.values()) |*held| held.incomplete = false;
        w.handed_out = true;
        return events;
    }

    /// `poll`, less the bookkeeping of what has been handed out.
    fn gather(w: *Watcher, timeout_ms: ?u32) PollError![]const Event {
        // Report before a wake or an indefinite wait can return or block.
        try w.recover();
        _ = try w.gatherWindow(timeout_ms);
        // Pending-watch reconciliation can discard ancestor events. The
        // recovery obligation is the caller's root, and ends only when
        // poll actually hands the notice out, never during reconciliation.
        try w.recover();
        return w.batch.events.items;
    }

    fn recover(w: *Watcher) Allocator.Error!void {
        for (w.table.keys(), w.table.values()) |id, held| {
            if (!held.incomplete) continue;
            try w.batch.push(w.gpa, id, held.path, .overflow, held.target);
        }
    }

    fn gatherWindow(w: *Watcher, timeout_ms: ?u32) PollError![]const Event {
        // Before anything blocks: a watch that came back half
        // registered says so at once rather than when the tree next
        // happens to change.
        try w.batch.flush(w.gpa);
        const deadline: Deadline = .start(w.io, timeout_ms);
        if (w.woken.swap(false, .acquire)) return w.batch.events.items;

        while (w.batch.events.items.len == 0) {
            // A path that is settling has a deadline of its own, so the
            // wait is the shorter of the caller's timeout and the next
            // one due; otherwise a `poll(null)` would sleep through a
            // deadline the watcher set itself.
            const left = deadline.remainingMs();
            const wait_ms: ?u32 = if (w.batch.nextDueMs()) |due|
                if (left) |l| @min(l, due) else due
            else
                left;

            try w.wait(wait_ms);
            try w.collect();
            if (w.woken.swap(false, .acquire)) return w.batch.events.items;
            if (w.batch.events.items.len == 0 and deadline.expired()) return &.{};
        }
        // Debouncing has already waited for the path to be quiet, so
        // there is nothing left for a coalescing tail to merge.
        if (timeout_ms == 0 or w.options.latency_ms == 0 or w.options.debounce_ms > 0)
            return w.batch.events.items;

        // The coalescing tail: keep reading for `latency_ms` past the first
        // event so that an editor writing a file in four chunks is one
        // `modified` and not four.
        const tail: Deadline = .start(w.io, w.options.latency_ms);
        while (true) {
            const left = tail.remainingMs() orelse 0;
            if (left == 0) break;
            try w.wait(left);
            try w.collect();
            // A wake that arrives now is answered by this poll, which
            // returns what it has rather than waiting out the tail.
            if (w.woken.swap(false, .acquire)) break;
        }
        return w.batch.events.items;
    }

    /// One wait of the backend's, and the cancellation point after it.
    ///
    /// Each backend decides what of its wait can be interrupted: the kernel
    /// backends read what the kernel handed them under cancel protection,
    /// because an event read and not yet recorded would be lost, and the
    /// `poll` backend protects its scans and leaves its sleep open. Here is
    /// where a cancellation that arrived during any of it is reported,
    /// with everything the wait read already in the batch.
    fn wait(w: *Watcher, wait_ms: ?u32) PollError!void {
        switch (w.impl) {
            // Nothing to interrupt, only a sleep to cut short: it reads
            // the flag `wake` sets between the slices it sleeps in.
            .poll => |*impl| try impl.wait(&w.batch, wait_ms, &w.woken),
            inline else => |*impl| try impl.wait(&w.batch, wait_ms),
        }
        try w.io.checkCancel();
    }

    /// What every round of `poll` does with what a backend has just
    /// pushed: promote what has gone quiet, keep the parked watches
    /// current, and turn a batch that hit its ceiling into the overflow
    /// that says so.
    fn collect(w: *Watcher) PollError!void {
        // Parked watches are re-examined and promoted here, a registration
        // at a time: nothing in it is a place to stop.
        const protection = w.io.swapCancelProtection(.blocked);
        defer _ = w.io.swapCancelProtection(protection);
        try w.batch.flush(w.gpa);
        try w.batch.promote(w.gpa);
        try w.settlePending();
        while (w.batch.dropped.count() != 0) {
            const id = w.batch.dropped.keys()[0];
            // The batch knows it had to stop holding names; only the
            // watcher knows which root to say so against.
            const root = w.rootOf(id) orelse {
                w.batch.dropped.swapRemoveAt(0);
                continue;
            };
            try w.batch.push(w.gpa, id, root, .overflow, w.rootTarget(id));
            w.batch.dropped.swapRemoveAt(0);
        }
    }

    /// Makes a `poll` blocked on this watcher come back, from another
    /// thread.
    ///
    /// This is the one thing a `Watcher` will take from a thread that is
    /// not its own. Everything else about a watcher belongs to one
    /// thread; this is how that thread is let go of, so that a program
    /// shutting down, or one that has decided it wants to watch
    /// something else, does not have to have left itself a timeout to
    /// discover it through.
    ///
    /// The `poll` returns whatever it had, which is usually nothing. It
    /// is not a cancellation: the watcher is still good and the next
    /// `poll` carries on. Calling it while nothing is polling makes the
    /// next `poll` return at once, and calling it many times is the same
    /// as calling it once.
    ///
    /// On the `poll` backend the return takes up to
    /// `Options.poll_interval_ms`, or a tenth of a second, whichever is
    /// less: there is nothing to interrupt, only a sleep to cut short.
    ///
    /// This, and not cancellation, is what lets go of a poll blocked on a
    /// kernel backend: see `poll`. A task that polls in a loop is stopped
    /// the same way on every backend, with a flag it reads between polls:
    ///
    /// ```
    /// // The task.
    /// while (!stopping.load(.acquire)) {
    ///     for (try watcher.poll(null)) |event| handle(event);
    /// }
    /// // Stopping it, from another thread.
    /// stopping.store(true, .release);
    /// watcher.wake();
    /// future.await(io); // or `cancel`: the task is already on its way out
    /// ```
    ///
    /// The flag is what makes it certain. A `wake` alone can be answered by
    /// the poll that is running when it arrives, and a cancellation
    /// requested after that is not seen by the next poll until something
    /// ends its wait; a wake that lands between two polls is kept for the
    /// next one, so the flag is always read.
    pub fn wake(w: *Watcher) void {
        w.woken.store(true, .release);
        w.waker.wake();
    }

    /// Copies the boundary of what poll has handed out. The snapshot owns
    /// each watch's log cursor and every drained change still waiting for
    /// debounce or settling, so resuming restores those changes without
    /// replaying the delivery represented by this checkpoint.
    ///
    /// Call Checkpoint.deinit to free it. null means the backend has no
    /// persistent log, or a failed delivery must first be retried by poll.
    /// Persist the token after processing the returned events. A crash
    /// before persistence replays work since the previously saved snapshot;
    /// processing and persistence need a caller transaction for exactly once.
    pub fn checkpoint(w: *const Watcher, gpa: Allocator) Allocator.Error!?Checkpoint {
        if (w.batch.dropped.count() != 0) return null;
        for (w.table.values()) |held| if (held.incomplete) return null;
        if (comptime @hasField(Impl, "fsevents")) {
            if (w.impl == .fsevents) {
                const roots = try w.watches(gpa);
                defer gpa.free(roots);
                return w.impl.fsevents.capture(gpa, &w.batch, !w.handed_out, roots);
            }
        }
        return null;
    }

    /// Every watch this watcher holds, in the order they were added.
    ///
    /// The slice is allocated with `gpa` and is the caller's to free;
    /// the paths inside it belong to the watcher and are valid until the
    /// next `add`, `remove` or `deinit`. A program that keeps its own
    /// idea of what it asked to watch can check it against this.
    pub fn watches(w: *const Watcher, gpa: Allocator) Allocator.Error![]WatchInfo {
        const list = try gpa.alloc(WatchInfo, w.table.count());
        for (w.table.keys(), w.table.values(), list) |id, held, *slot| {
            slot.* = .{
                .id = id,
                .path = held.path,
                .recursive = held.recursive,
                .waiting = w.waiting(id),
            };
        }
        return list;
    }

    fn waiting(w: *const Watcher, id: WatchId) bool {
        for (w.pending.items) |p| if (p.id == id) return true;
        return false;
    }

    /// What a watcher is currently holding. See `stats`.
    pub const Stats = struct {
        /// Watches `add` has returned an id for and `remove` has not
        /// taken back.
        watches: usize,
        /// Paths the operating system has been told about on this
        /// watcher's behalf: one per kernel watch on `inotify`, one per
        /// open descriptor on `kqueue`, one per stream on `fsevents`, one
        /// per directory handle on `windows`, and one per path scanned
        /// on `poll`.
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
            .watches = w.table.count(),
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
    _ = Poll;
    _ = Tree;
    _ = Waker;
    _ = @import("Snapshot.zig");
    _ = @import("Budget.zig");
    _ = @import("Deadline.zig");
    _ = @import("buffer.zig");
    _ = @import("path.zig");
    _ = @import("walk.zig");
    // Held-event transfers use no Windows calls and are tested on every host.
    _ = @import("backend/windows.zig");
    _ = @import("trace.zig");
    _ = @import("test_suite.zig");
    _ = @import("test_bench.zig");
    _ = @import("test_gaps.zig");
    _ = @import("test_fuzz.zig");
    // The backends this target was built with, each of which carries
    // tests of its own. They are found when the backend is analysed,
    // which the suite causes and a filtered run does not, so they are
    // named here for `zig test --test-filter` to find them.
    inline for (@typeInfo(Watcher.Impl).@"union".fields) |field| _ = field.type;
}

test "the Apple default preserves paired renames" {
    switch (builtin.os.tag) {
        .driverkit,
        .ios,
        .maccatalyst,
        .macos,
        .tvos,
        .visionos,
        .watchos,
        => {
            try std.testing.expectEqual(Backend.fsevents, default_backend);
            try std.testing.expect(pairsRenames(.auto));
        },
        else => return error.SkipZigTest,
    }
}

test "a failed pending promotion keeps each registered path owned" {
    const testing = std.testing;
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        defer testing.allocator.free(root);
        const target = try std.fs.path.join(testing.allocator, &.{ root, "later" });
        defer testing.allocator.free(target);
        // Keep freed storage mapped so a duplicate release can be counted
        // without dereferencing freed memory or crashing the test runner.
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var failing = testing.FailingAllocator.init(arena.allocator(), .{});
        var failed = false;
        {
            var watcher = try Watcher.init(failing.allocator(), testing.io, .{ .backend = .poll });
            defer watcher.deinit();
            _ = try watcher.add(target, .{ .pending = true, .recursive = true });
            try tmp.dir.createDirPath(testing.io, "later/child");
            try tmp.dir.writeFile(testing.io, .{ .sub_path = "later/child/file", .data = "x" });
            failing.fail_index = failing.alloc_index + fail_index;
            const answer = watcher.promotePending(watcher.pending.items[0]);
            failing.fail_index = std.math.maxInt(usize);
            if (answer) |promoted| {
                try testing.expect(promoted);
                // promotePending destroys the object; its caller removes
                // the list entry only after that successful return.
                _ = watcher.pending.orderedRemove(0);
            } else |err| {
                try testing.expectEqual(error.OutOfMemory, err);
                failed = true;
            }
        }
        try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        if (!failed) break;
    }
    try testing.expect(fail_index > 0);
}
