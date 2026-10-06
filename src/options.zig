//! Watch configuration above checkpoint storage and event contracts.
const Filter = @import("Filter.zig");
const Checkpoint = @import("Checkpoint.zig");
const types = @import("types.zig");
const Backend = types.Backend;

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
    /// add returns InvalidCheckpoint if the volume or its log has changed,
    /// or if the watch's ignore or include patterns differ from the ones
    /// the checkpoint was taken with; a predicate filter cannot be
    /// recorded, and keeping it the same is the caller's.
    /// Each persistent stream follows one device. Scopes crossing mounted
    /// volumes keep live coverage but cannot produce checkpoints; watch
    /// those volumes separately to retain resumable history.
    /// Pending changes are restored as the watch would report them live --
    /// what is outside it or excluded by its filter is dropped -- and new
    /// log records are resolved against the current tree, a path the
    /// checkpoint's baseline did not hold being `created`. Backends without
    /// a persistent log ignore this.
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
    ///   does not silently widen it, unless `follow_symlinks` asks for it.
    recursive: bool = false,
    /// Follow symbolic links to directories inside a recursive watch.
    /// Off by default, and ignored without `recursive` or on a watch of a
    /// file.
    ///
    /// A followed link is watched as if the directory it leads to were
    /// there, and what happens below it is reported under the link's
    /// path, never the target's, with the watch's own id and filter.
    /// Links are followed wherever they lead, outside the watched root as
    /// well: that is what turning this on asks for, and why it is off.
    ///
    /// A link is not followed into a directory the watch already reaches:
    /// the root or anything below it, a directory another followed link
    /// reached first, or one that holds either -- a link back to an
    /// ancestor is the usual case. This is decided by what the directory
    /// is, its device and inode or its volume and file id on Windows,
    /// never by how its path is spelled, so a cycle is never walked and
    /// one watch never reports a directory under two names. Such a link
    /// is an entry, as every link is without this option; when the link
    /// that reached its directory first goes, it is followed instead.
    ///
    /// A link is looked at again whenever its own path changes. One that
    /// leads elsewhere is reported on its path, and what the old
    /// directory held stops being watched while the new one is walked;
    /// neither is reported entry by entry. A link that leads nowhere is an
    /// entry until it changes. A directory a followed link leads to that is
    /// removed is `Kind.removed` on the link's path, and the link is an
    /// entry from then on.
    ///
    /// Each followed link is a registration of its own on the directory
    /// it leads to -- one more descriptor, kernel watch, stream or handle
    /// -- and `add` walks the tree once more to find the links. A watch
    /// follows at most `max_followed_links`; a link past that is
    /// `Kind.unwatched` and is not followed. A watch that follows a link
    /// produces no checkpoint: see `Watcher.checkpoint`. Where a
    /// directory's identity cannot be read, no link is followed.
    follow_symlinks: bool = false,
    /// The most links one watch follows with `follow_symlinks`, those
    /// found inside followed directories included. It bounds the depth of
    /// a chain of links as well as their number.
    max_followed_links: usize = 64,
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
    ///
    /// The ancestor a watch parks on has to be one the backend can
    /// register. One it refuses -- a folder that cannot be listed, a full
    /// watch table -- fails the `add` with that error, as a watch taken
    /// on a path that was there would. Refused later, when the watch
    /// steps down to a folder that has appeared, the watch stops waiting
    /// and says `Kind.unwatched` against its path.
    pending: bool = false,
};
