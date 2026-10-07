//! Watch contracts shared by batching, storage and platform backends.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
pub const Filter = @import("Filter.zig");

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
        .auto, .poll => true,
        .fsevents => switch (builtin.target.os.tag) {
            .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => true,
            else => false,
        },
        .kqueue => switch (builtin.target.os.tag) {
            .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos, .dragonfly, .freebsd, .netbsd, .openbsd => true,
            else => false,
        },
        .inotify => builtin.target.os.tag == .linux,
        .windows => builtin.target.os.tag == .windows,
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
pub const default_backend: Backend = switch (builtin.target.os.tag) {
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
