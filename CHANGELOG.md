# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Breaking: `Watcher.InitError` includes `OutOfMemory`; FSEvents preserves sink and buffer allocator failures instead of reporting `SystemResources`.

### Added

- `Watcher.refilter(id, filter)` changes a live watch's filter without
  removing its registration or changing its id. Newly admitted directories
  are registered where the backend watches directories individually;
  excluded ones are released, and newly reached directories enter the
  entry budget.

- Export `path.relative` and `path.within` for callers that need the same
  platform case folding and separator handling as lookout's watches.

### Fixed

- FSEvents retains a held rename and its pairing when reporting, replacement or rejoining fails.

- Tree adoption releases frontier and directory paths that failed registration has not taken.

- Windows retains held removals and rename paths until their batch transfer succeeds, so allocation failures leave them retryable.

- Polling releases a staged removal path when its removal list cannot grow, retaining the registration for retry.

- Failed tree registration releases its directory snapshot and any file nodes created before the failure.

- A tree walk releases its root path when allocating the initial frontier fails.

- A failed first budget count publishes no directory or partial listing, so cleanup and retry remain valid.

- Document polling's open directory handles, both backends that recurse in the kernel, and baseline retry and truncation behavior.

- Queued unwatched events, held changes and overflow notices remain pending until their transfer into the batch succeeds.

- FSEvents reports overflow when a path's existence cannot be checked, retaining known paths and refusing ambiguous rename pairs.

- A baseline reports a missing root once, until the root has been seen again.

- Truncated directory scans retain remembered entries and subtrees until a complete listing can establish what changed.

- Polling and kqueue tree scans retain registrations when listing or file metadata access fails instead of reporting removals.

- Document the FSEvents sink and buffer allocated at initialization and their allocator failures.

- Baseline diffs commit listings and returned paths together, so failed traversal or allocation leaves every change available to a retry.

- Baseline scans propagate directory access failures instead of reporting inaccessible paths as removed.

- Windows: a name renamed over from a name the watch does not see --
  outside it, or excluded by its filter -- is `created` there, and
  `renamed` from a name it does see, as on `inotify` and FSEvents. So a
  file saved by writing `settings.new` and renaming it over
  `settings.toml` is `created` for a watch filtered to `settings.toml`.
  `ReadDirectoryChangesW` writes the replaced entry's removal before the
  rename's own records, and the removal outranked the creation in the
  window, so the name was reported `removed` while a file stood there. A
  removal the next records follow with a move onto its name is now not
  reported; one that ends its read is held, for a grace of at most a
  hundred milliseconds, for the next read to say. A delete and a create
  of one name back to back are written the same way as a move onto it
  from another directory, and are reported as that move: `created`.

- Entry counts are read again from disk when changes are lost: the
  `inotify` queue overflowing, a Windows read the kernel could not hold
  (an empty read, `ERROR_NOTIFY_ENUM_DIR`, or one that cannot be
  followed), and FSEvents losing track or a delivery not fitting its
  buffer. The count was kept by adding up the changes reported, so the
  ones lost were in no count, and `Options.max_dir_entries` was off by
  them for as long as the watch lasted -- a folder could go past it with
  no `overflow`. What is read again is what the loss touched: on Windows
  and FSEvents, the folders the watch that lost them was counting, below
  where the loss was said.
- A watch on a file holds no entry budget for its folder, on every
  backend. Windows and FSEvents read the file's folder to see the file,
  and counted the folder through that watch: seeded from disk, then
  moved only when the file itself came or went. That count outlived the
  folder's own watch, and a watch taken on the folder again took it up
  stale, so the folder went past `Options.max_dir_entries` without an
  `overflow`. No backend tells a file watch about its folder's budget
  now, which is what `inotify`, `kqueue` and the `poll` backend already
  did. FSEvents also no longer counts a watched directory's own root
  against the folder above it, which no watch reports.
- A pending watch takes the path it waits for from the `add` on. A
  second `add` of that path was accepted until a `poll` promoted the
  first, and the promotion then registered the path a second time, so
  every change inside it was reported under two ids; two pending watches
  of one path did the same. Both are `PathAlreadyWatched` now, before the
  path appears and after, so the answer no longer depends on whether a
  `poll` came between. A path that, once there, turns out to lead through
  a symbolic link to a path another watch has is not registered again
  either: the pending watch stops waiting and reports `unwatched`.
- A folder several watches reach is counted once against
  `Options.max_dir_entries`. Windows and FSEvents hand every watch its
  own record of each change, and each record was counted, so a folder
  that two watches shared -- overlapping watches, or a pending watch
  parked in a folder another watch holds -- reported `overflow` at a
  fraction of its size. FSEvents also counted what was already in a
  folder once per watch taken on it. One record now counts, and every
  watch the change reached is told when the folder goes past. Removing
  one of the watches, including a pending watch leaving its folder when
  it is promoted, keeps the count the others still use; it was dropped
  and read again from disk, which counted changes still on their way a
  second time.
- A pending watch no longer takes the folder it is parked in. It recorded
  that ancestor as watched, so a later `add` of the same folder failed
  with `PathAlreadyWatched`, and a pending watch added after the folder
  was parked on nothing, found only when a `poll` happened to look. Only
  a watch registered on its own path counts now: the folder's watch and
  the parked one each report what they are about, the parked one still
  promotes when its path appears, and several may wait in one folder.
  Two things this brought out are fixed with it. `inotify` counted a
  folder's entries only through the first watch sharing its kernel
  watch, so when that was a parked one, whose filter leaves every other
  entry out, the folder's watch never reported `overflow`. `kqueue` and
  the `poll` backend dropped every watch's registrations under a path
  that went, so of two watches on it only the one the system reported
  first said `removed`.
- `kqueue`: an entry below a watch that could not be registered is
  dropped with everything under it. The drop compared each path against
  the entry's own, which it had just freed, so what was under it could
  be left registered.

- `wake` read the backend's state while the polling thread was writing
  it: finding which backend to poke loaded the whole backend union, and
  on the `poll` backend the polling thread's own loads of that union read
  the flag `wake` was storing. ThreadSanitizer reported both on Linux, in
  the two suite tests that wake a watcher from another thread. The
  backend now hands `init` a waker -- the pipe, the kernel queue, the
  completion port, the FSEvents sink -- and `wake` pokes that and touches
  nothing else; the `poll` backend's sleep reads the watcher's own flag.
  A `wake` that arrives during the coalescing tail now ends that `poll`
  rather than the next one.

- A rename between a name the filter keeps and one it excludes is
  reported by one rule on every backend that pairs renames: an excluded
  name is treated exactly as a name outside the watch. Only the new name
  kept is `created` there, only the old one kept is `removed` there, both
  kept is `renamed`, neither is nothing. FSEvents dropped the excluded
  half before pairing and then read the kept one on its flags alone, so a
  file saved by renaming an excluded temporary over a watched name was
  reported only when a modified flag happened to be coalesced into the
  record, and a watched file renamed to an excluded name was `modified`.
  `inotify`, for an excluded name its walk still enters, reported
  `renamed` with an excluded `from`, lost the removal when only the old
  name was kept, and reported an excluded name renamed out as `removed`.
  Windows skipped an excluded new name before pairing, so the kept old
  name stayed held for the next rename's new name: lost, or paired with
  the wrong one.
- FSEvents: a rename half with no partner, on a file that was already
  known, is checked for on disk. Renamed out of the watch, it is
  `removed`; it was reported `modified`, or nothing, from flags that
  carry no removal. Still there with nothing else in its flags,
  something was renamed over it from outside the watch, and it is
  `created`, as `inotify` and Windows report the same move; it was
  dropped.

- A pending watch whose path appeared while it moved down to a nearer
  ancestor — `mkdir -p` making both in one breath — was left parked on
  nothing, so a `poll` with no timeout waited until some other change. It
  is promoted at once. Seen once on Linux under load; the window is between
  a look and a registration and no test forces it.
- FSEvents: a file saved by renaming a new file over it and later deleted
  was reported gone only when some other change came along, so a `poll`
  with no timeout could wait for ever. FSEvents keeps a path's flags, so
  the deletion arrives as a rename half with no partner; a half alone is
  now decided once its pairing grace has passed, whatever the timeout.
- FSEvents: the stream a delivery reads is published to the delivery
  thread with a release and read with an acquire. The start ordered them
  already, inside the framework; a race detector now sees it too.

- A cancellation that arrived while a watcher was re-reading the tree was
  taken for the answer to the question being asked. A directory whose
  listing was cut short was reported `removed` and its subtree stopped
  being watched; a file whose `stat` was cut short was reported `removed`;
  a subdirectory whose open was cut short was reported `unwatched`. And
  since such a cancellation was consumed there, the task was never told
  of it. The re-reading now runs under cancel protection: the kernel
  backends' reading of what the kernel reported, the `poll` backend's
  scans, and the re-examination of parked watches.
- A cancellation during a recursive `add` was taken for a directory that
  could not be read. On `inotify` the directory and everything below it
  were left without a kernel watch, with nothing said; on FSEvents they
  were left out of what the watcher knew, so their next change read as a
  creation; on `kqueue` and the `poll` backend the directory was reported
  `unwatched`. `add` now runs to the end once it has begun.

### Changed

- `LOOKOUT_TRACE` traces the Windows backend too: each record a read
  carries, and what was made of it.
- `poll` is a `std.Io` cancellation point on every backend. It looks for a
  cancellation on entry and each time the backend's wait comes back, and
  returns `error.Canceled` for one requested before it was called or while
  it waited. It used to be one only where a file-system call happened to
  see it, which on a kernel backend blocked in the kernel was the first
  directory re-read after the next change.
- A `poll` that returns an error hands nothing out. What it had gathered
  is returned by the next `poll` rather than dropped with it.
- `add` looks for a cancellation once, on entry, and then registers the
  whole watch. A cancellation requested while it runs is left for the next
  cancellation point.
- `PollError`, `poll`, `wake`, the README and the module documentation now
  state the rule: cancellation is honoured on every backend, a blocked
  wait on the `poll` backend is ended by one, and a blocked wait on a
  kernel backend is ended by `wake`, a change or the timeout, with the
  cancellation reported then. `wake` gives the flag-and-wake recipe that
  stops a polling task on every backend.

## [0.3.0] - 2026-09-20

FSEvents drained without a filesystem query per record and honouring the
latency asked for, and the fixes a second reading found across the four
backends.

### Added

- A `check` build step compiles the complete backend-bearing test artifact for cross-target verification without trying to run it.

### Fixed

- FSEvents now drains ordinary creations and writes without a filesystem query per record, seeds directory budgets during its existing tree walk, and counts accumulated creation flags only when a path actually becomes known.
- FSEvents stream latency now follows `Options.latency_ms`, including a zero-second window when coalescing is disabled; the Apple default remains the rename-pairing backend, with the lower-latency small-tree choice documented explicitly.
- Removing a watch now discards changes still held by settling or debouncing.
- Moving an entry between separate inotify watches is reported to each watch independently.
- Overlapping watches now keep independent registrations, state, and events for shared paths.
- Watching a filesystem root now includes every descendant beneath its trailing separator.
- Saved FSEvents positions now stop at the last event the watcher actually drained.
- Windows now retires a silently renamed root before it can report child paths under the old name.
- FSEvents now reports a path removed and recreated in one delivery as removed.
- Timeouts larger than an operating system wait can represent are now completed in safe chunks.
- Baselines with an `only` filter now traverse excluded ancestors to reach matching descendants.
- Coalescing a rename into a stronger non-rename event now clears the obsolete source path.
- A pending watch promoted onto a file now reports the creation target as a file.
- Removing a directly watched file now reports a file target on every backend.
- Hitting the inotify watch limit below a recursive root now reports the unwatched subtree without rejecting the root.
- Polling now treats only an absent root as removed and returns other root stat errors.
- Retiring a Windows watch no longer allocates while cancellation still references its buffer.
- A pending path that appears during `add` now has one owner on every registration failure path.
- `max_events` now bounds paths held for settling or debouncing as well as ready events.
- A zero polling interval now sleeps for one millisecond between quiet scans instead of spinning.
- Position documentation now describes the host-wide FSEvents sequence used by the backend.
- Path comparison documentation now states that portable case folding is limited to ASCII and Latin-1.
- A watch on a single file now reports `overflow` when FSEvents loses track of the directory the file is in.

## [0.2.0] - 2026-09-19

ASCII and Latin-1 paths compared with filesystem-style folding, a rename that survives
the boundary of a read, and the three questions a watcher could not answer
about itself.

### Breaking

- **`Options.windows_buffer_bytes` is `Options.buffer_bytes`**, and it sizes
  both backends that are handed a buffer and find the changes in it.

- **`Kind` has another member, `unwatched`, and `Event` another field,
  `target`.** An exhaustive switch over either has to grow an arm.

- **`Filter` has another field, `only`, and a second question, `prunes`.**

- **`Options.max_events` puts a ceiling on a batch** where there was none.

### Added

- **`Kind.unwatched`** says that lookout is no longer watching a path, and
  that nothing under it will be reported. A subdirectory the operating system
  refused — unreadable, or past the per-user watch limit — was swallowed at
  five places, and the only sign of it was a part of the tree that never
  reported anything. It outranks `overflow`: one says look again, the other
  says looking again is the only way you will ever hear about this path.

- **`Watcher.position` and `Options.since`** are how a tool that runs, exits
  and runs again is told what it missed. The position is a short piece of text
  — `Position.token` writes it, `Position.parse` reads it back — and lookout
  persists nothing: the token is the caller's to keep. Only FSEvents can
  answer, because only it is backed by a persistent per-host log
  rather than by a queue that starts empty, and `tracksPosition` says so
  instead of pretending. A resumed watch reports what was created, changed
  and deleted while nothing was watching, resolved against the tree as it is
  now.

- **`Event.target`** says whether the path was a file or a directory. After a
  removal the path cannot be stat-ed to find out, so a caller keeping a model
  of a tree had no way to know what had just left it.

- **`Filter.only`** says what a watch *is* about, which no combination of
  exclusions could express, and `**` crosses a separator, so `src/**/*.zig` is
  a thing that can be written. An include list has to answer two questions
  rather than one — may this path be reported, and may lookout look inside
  this directory — because a list naming files at any depth still has to let
  the walk reach them.

- **`Watcher.wake`** makes a blocked `poll` come back from another thread. A
  program that wanted its thread back had to have left itself a timeout to
  discover that through, and `poll(null)` could not be interrupted at all.

- **`Watcher.watches`** enumerates what the watcher holds — the path, the
  recursion, and whether it is still parked on an ancestor waiting for its
  path to appear. `Watcher.stats` counted them and could not name them, so
  intent could not be diffed against reality.

- **The decoders are fuzzed.** The run of `struct inotify_event` one read
  brings back, the `FILE_NOTIFY_INFORMATION` chain a completed
  `ReadDirectoryChangesW` leaves, and the flags-and-paths buffer the
  FSEvents delivery thread fills are parsers over bytes lookout did not
  write; the matching that decides which two records of a delivery are
  the two halves of one rename is a parser over the records. They are out
  of the backends now, in files that compile on every target rather than
  only on the one whose kernel writes those bytes, each with a
  `std.testing.fuzz` target holding it to one contract: any input yields
  records or a named error, never a crash and never a read past the end
  of the input; every name lies inside the input it was decoded from; and
  the work and the memory are bounded by the input's length. The two over
  the FSEvents records hold one more, being the two that pair: the
  matching is symmetric, so if this record is that one's other half, that
  one is this one's. `zig build test --fuzz` runs them.

- **`Options.max_events`** is a ceiling on one batch. A process writing faster
  than the caller polls made the library grow without bound; past the ceiling
  the names stop being kept and `Kind.overflow` says so against the roots that
  lost them, which is the answer the caller already handles.

### Changed

- **`Options.buffer_bytes` defaults to four megabytes on the Apple backend**,
  where it sizes the buffer the delivery thread copies into and was fixed at
  64 KiB. At about a hundred and ten bytes a record that was room for some six
  hundred paths: ten thousand files created in one directory arrived as four
  hundred and sixty-five creations and one `overflow`, which is true and
  useless to a caller who wanted the names. Four megabytes holds that burst.
  The same option sizes the Windows read buffer, which had its own name before
  and the same job.

- **What a watcher costs is held to a budget.** How long after a change `poll`
  comes back, how much of a burst arrives, and how much memory a watched
  directory costs were each measured once; a measurement nothing checks is one
  that goes quietly wrong.

### Fixed

- **A record the operating system did not write no longer reads past the
  end of the buffer it came in.** All three backends that are handed
  bytes trusted the lengths in the records' own headers: an `inotify`
  event whose name ran past the read, a `FILE_NOTIFY_INFORMATION` whose
  `FileNameLength` ran past what the read transferred, and a chain whose
  `NextEntryOffset` pointed back into the record it followed were each an
  out-of-bounds read away. The Windows name was also loaded as `u16`
  where it lay, which a `NextEntryOffset` that is not even makes a
  misaligned load; it is copied and realigned now. A chain that cannot be
  followed is `Kind.overflow`, which is lookout saying it could not
  account for a read and is what the caller already handles.

- **`reportsRootMove` is absolute on the Apple backend.** It answers
  `removed` there, and a caller switches on it; the backend chose between
  `removed` and `renamed` by asking whether the watched path was there
  when the delivery was read. A root deleted and recreated inside one
  window is there, so it arrived as `renamed` — the one shape the
  predicate says this backend never gives, and the shape a caller
  therefore does not handle. FSEvents says the path to the root changed
  and does not say how, so there was nothing behind the question but a
  race. It is the rule coalescing already has for every other path: a
  path removed and recreated inside one window is `removed`, which means
  look at this path again.

- **ASCII and Latin-1 paths use filesystem-style folding.** lookout compared
  paths byte for byte, which on a volume that folds case is not a degradation
  but a silent total failure: a caller whose spelling differed from the one on
  disk had every event dropped, and nothing said why. An ignore pattern had it
  from the other side — `*.TMP` excluded nothing on a disk holding
  `notes.tmp`. Case and Latin-1 composition are now folded on the targets
  whose file systems fold them, and every comparison between two paths goes
  through one place: the watch root against the path an event names, a pattern
  against an entry, one node against the subtree it is removed with, and the
  key an event is coalesced under. Linux and the BSDs still compare bytes.

- **On Windows a buffer the caller sized for a local disk is no longer a watch
  that dies on a network share.** `ReadDirectoryChangesW` refuses a buffer over
  64 KiB on a remote directory rather than clamping it, and the failure was an
  unmapped error at the point where the watch was re-armed: the watch stopped
  reporting, with no error and no event. lookout comes down to the size a share
  takes by itself.

- **A rename is no longer split into a removal and a creation by the boundary
  of a read.** Both halves arrive together, but "together" is about the
  kernel's queue and not about the buffer lookout reads it into, and all three
  backends that pair renames decided at the end of each read. A half is now
  held until the whole wait is over. On the Apple backend the partner is also
  looked for anywhere in the delivery rather than only next door, because the
  directory the two names are in can be reported between them.

- **A write inside a renamed directory is a write.** The Apple backend tells a
  creation from a write by remembering every path it has seen, and renaming a
  directory left every path under the old name: the first write inside the new
  one looked new. Renaming re-keys the subtree, and a directory that arrives
  already holding a tree — an archive unpacked, or a rename that could not be
  paired — is walked and reported, which is what the backends that recurse
  themselves already did.

- **`max_dir_entries` is one directory's budget on every backend.** It is
  documented as the entries of one watched directory, and the Windows backend
  counted every creation anywhere under a recursive root against one number,
  so twenty directories of three hundred entries overflowed a budget none of
  them reached.

- **`settle_ms` measures the file as well as timing it.** The quiet window on
  its own is a guess about a writer nobody can see, and a kernel that coalesces
  several writes into one notification could leave the window closing over a
  file that was still growing — the exact failure the option exists to prevent.
  One `stat` at the moment the window closes; a file larger than it was starts
  the window again. A writer that stops for longer than the window and then
  starts again is still indistinguishable from one that has finished, and
  `Kind.closed` is the only real answer to that.

- **Six things the documents said that the code did not do.** `Kind.removed`
  said every backend reports a rename as a removal and a creation, which
  `pairsRenames` contradicts; `Kind.renamed` was described as two backends'
  when three produce it for entries; `Stats.registrations` said one per path
  scanned on `poll` when it is one per directory; the module header named three
  backends of five; and the polling backend called itself the one for Windows,
  which has had a backend of its own since 0.1.0. Where a statement can be
  asserted rather than written down, it now is: the suite holds
  `tracksPosition` and the entry budget the same way it already held
  `pairsRenames` and `reportsRootMove`.

## [0.1.1] - 2026-09-14

### Breaking

- **`reportsRootMove` answers with `RootMove` rather than with a boolean**,
  because there are three shapes and not two: `renamed` on `kqueue` and
  `inotify`, `removed` on FSEvents and polling, and `silent` on Windows, where
  the directory handle survives the rename and the rename itself happens in a
  directory the watch was never put on. The boolean said Windows reported
  `removed`, which it does not; a caller waiting for that event waited forever.

### Added

- **`Event.time`** says when lookout first saw the path change in this window,
  on the same clock a caller reads with `std.Io.Timestamp.now(io, .awake)`. An
  event that says only what happened leaves a caller unable to order two
  batches or to tell a change from a backlog.

- **`Options.debounce_ms`** is the third window, and it answers the question
  the other two cannot. `latency_ms` merges what arrives together and reports
  the most significant kind; `settle_ms` waits for a file's contents to stop
  changing. `debounce_ms` holds every kind until the path is quiet and then
  reports it once, carrying the kind seen **last** — so a path deleted and
  recreated inside one window is one `created`, which coalescing cannot say
  because `removed` outranks it.

- **`Watcher.stats()`** reports what a watcher holds: watches, registrations
  the operating system is keeping on its behalf, paths held back by a window,
  and the size of the last batch. The registration count is the one that runs
  into `max_user_watches` and the per-process descriptor limit, and there was
  no way to see it.

- **`Options.windows_buffer_bytes`** sets how much change the Windows kernel
  may hold for one watch between two reads. It was fixed at 64 KiB, which is
  the largest a network share takes and not always the right answer on a local
  disk: a busy tree polled infrequently overflowed and the caller had no way to
  buy headroom. Sizes are held between 4 KiB and 16 MiB and rounded down to a
  multiple of four.

- **`Kind.closed`** says that a file open for writing has been closed: the
  writing is over, from the operating system rather than inferred from a quiet
  window, which is what `Options.settle_ms` can only estimate. Only `inotify`
  is told this, through `IN_CLOSE_WRITE`, so `Options.report_closes` has to ask
  for it and `reportsCloses` says whether this backend will ever produce one —
  a kind that silently means nothing on four backends out of five is worse than
  no kind at all.

- **`Baseline`** answers what `Kind.overflow` could not. The watcher can say
  that its record of a tree is incomplete and not what was lost, because the
  names are gone by the time it knows. A baseline seeded where the watch is
  taken remembers the tree; `diff` re-reads it and returns the creations,
  modifications, attribute changes and removals that the lost events would have
  carried, spelled the way events are and on the same ownership terms as
  `Watcher.poll`. It is the listing comparison the `kqueue` and polling
  backends already made, kept for the caller instead of for the watcher.

- **`AddOptions.pending`** takes a watch on a path that does not exist yet
  instead of failing the `add` with `error.FileNotFound`. The watch is parked
  on the nearest existing ancestor, narrowed to the single entry that leads to
  the path asked for, steps down as the path appears, and is promoted to the
  real watch — recursion, filter and all — with the appearance reported as
  `Kind.created` against it. A tool watching a directory its own first run
  creates had to poll for it.

- **`AddOptions.filter`** says what a watch is not about: `Filter.ignore`, a
  list of path prefixes and simple globs, and `Filter.allow`, a predicate of
  the caller's, both asked about every ancestor of a path so that excluding a
  directory excludes its whole tree. It is applied where lookout does the
  recursion, so on `inotify`, `kqueue` and `poll` an excluded directory is
  never opened and never registered; FSEvents and `ReadDirectoryChangesW`
  recurse in the kernel, which cannot be told about a filter, so there the
  events are dropped and the work happens anyway. `prunesIgnored` is how a
  program asks which of the two it has. Before this, a recursive watch over a
  tree with a large build directory in it paid for every file in it.

- **`LOOKOUT_TRACE`** in the environment makes the Apple backend write what it
  did to standard error: every delivery the system made, every path in it with
  its event id and flags, and every decision that turned one into an event or
  dropped it, alongside each stream being created, started and stopped. It is
  read once per process and is compiled out where libc is not linked. An event
  that did not arrive was not investigable from outside the library.

- **`error.WatchLimitReached` is written down.** Every backend returns it when
  the operating system refuses another watch, and the README had never
  mentioned it.

### Fixed

- **An FSEvents watch no longer goes silent for the life of the program.** The
  backend unscheduled a stream from its dispatch queue before invalidating it,
  and `FSEventStreamInvalidate` requires the stream to still be scheduled: it
  failed its own assertion and did nothing, so every stream was released while
  the system still had it registered. The registrations accumulated, and
  roughly one stream in twenty-five after that was accepted and then never
  delivered anything. The same registration kept a pointer to memory the
  watcher had freed, which is the crash that came with it under a program that
  takes and drops watches quickly.

- **The watched path's own disappearance is reported by every backend.**
  Deleting it is `Kind.removed` everywhere; moving it is `Kind.renamed` where
  the backend watches the object rather than the name. Three backends were
  wrong before: FSEvents reported a deletion as a move, the polling backend saw
  neither because it lists a directory through a handle that outlives the name,
  and the Windows backend dropped the failed read that says the directory is
  gone.

- **`ERROR_NOTIFY_ENUM_DIR`**, the kernel's other spelling of a
  `ReadDirectoryChangesW` buffer overflow, is `Kind.overflow` like the
  zero-length read that says the same thing. It was previously taken for a
  watch going away, which lost the watch as well as the events.

- **A backend waits until the batch has *changed* rather than until it has
  *grown*.** Under `debounce_ms` a push produces no event for a while, and a
  backend watching the event count would have slept through its own deadline —
  with no timeout at all, forever.

- **A directory that appears under a recursive watch with files already inside
  it reports them.** The `kqueue` and polling backends registered such a
  directory by listing it and keeping that listing as the baseline, so
  everything already in it was taken for something that had always been there —
  and the directories among them were never registered, which left a whole
  unpacked tree unwatched below the first level. `inotify` already did this;
  now all three do.

- **A fresh FSEvents watch no longer reports the directory it was just put on
  as `Kind.created`.** The backend resolves a flag against the file system by
  asking whether it has seen the path before, and the walk that seeds that
  answer covered every path under the root and not the root itself. A
  directory's own `modified` and `attributes` flags are dropped too: a
  directory's times move whenever anything inside it moves, no other backend
  reports that, and FSEvents keeps these flags per path and never clears them.

- **`Event.path` is spelled with the platform's own separator** all the way
  down: `/` on POSIX, `\` on Windows, including the part below the watch root.
  The backends already did this; nothing said so, and a caller comparing an
  event against a path it pasted together with `/` matched nothing on Windows.

## [0.1.0] - 2026-09-13

First release.

### Added

- **`Watcher` over five backends behind one API**: FSEvents and `kqueue` on
  Apple platforms, `inotify` on Linux, `ReadDirectoryChangesW` on Windows, and
  a polling backend that needs nothing from the kernel and runs everywhere.
  `Options.backend` picks one; `supported` says which this target has.

- **Renames arrive whole where the kernel knows they are renames.**
  `Event.from` carries where a path came from, and `pairsRenames` says which
  backends can tell. Where they cannot — `kqueue` and polling compare directory
  listings, in which a rename and a delete-plus-create are the same thing — the
  removal and the creation are reported as themselves rather than guessed at.

- **`Options.settle_ms`** waits for a file to stop changing before reporting it
  as modified, which is the difference between reading a copied file and
  reading half of one. `latency_ms` merges the writes that arrive together;
  this waits for the writing to be over.

- **Events are coalesced per path within the `latency_ms` window**, so a file
  written in four chunks is one `modified` rather than four.

- **`Watcher.fd`** exposes the kernel descriptor, so a program with a wait loop
  of its own can wait on the watcher alongside its other descriptors. The
  library starts no threads and calls nothing back.

- **Recursive watches** are implemented by walking and registering each
  directory, and by registering directories created afterwards as they appear.

- **The suite runs once per backend the host can execute**, so the polling
  backend is held to the same contract as the kernel ones instead of to a
  weaker one of its own. `ci/linux.sh` runs it on Linux in Docker, so the
  `inotify` backend is executed rather than merely compiled from a machine that
  is not Linux.

[0.2.0]: https://github.com/pedronaugusto/lookout/releases/tag/v0.2.0
[0.1.1]: https://github.com/pedronaugusto/lookout/releases/tag/v0.1.1
[0.1.0]: https://github.com/pedronaugusto/lookout/releases/tag/v0.1.0
