# Changelog

Each entry says what the old shape could not express, so a port has the
reason and not only the diff. Versions follow
[semantic versioning](https://semver.org); before 1.0 the minor is the
breaking one.

## Unreleased

## 0.2.0

Breaking, and each of them is a shape that was wrong rather than a
preference:

- `Options.windows_buffer_bytes` is `Options.buffer_bytes`, and it sizes
  both backends that are handed a buffer and find the changes in it.
- `Kind` has another member, `unwatched`, and `Event` another field,
  `target`. An exhaustive switch over either has to grow an arm.
- `Filter` has another field, `only`, and a second question, `prunes`.
- `Options.max_events` puts a ceiling on a batch where there was none.

The changes themselves:

- A path is compared the way the file system compares it. lookout
  compared paths byte for byte, which on a volume that folds case is not
  a degradation but a silent total failure: a caller whose spelling
  differed from the one on disk had every event dropped, and nothing
  said why. An ignore pattern had it from the other side -- `*.TMP`
  excluded nothing on a disk holding `notes.tmp`. Case and Latin-1
  composition are now folded on the targets whose file systems fold
  them, and every comparison between two paths goes through one place:
  the watch root against the path an event names, a pattern against an
  entry, one node against the subtree it is removed with, and the key an
  event is coalesced under. Linux and the BSDs still compare bytes.
- `Options.buffer_bytes` sizes the buffer the Apple backend's delivery
  thread copies into, which was fixed at 64 KiB. At about a hundred and
  ten bytes a record that is room for some six hundred paths: ten
  thousand files created in one directory arrived as four hundred and
  sixty-five creations and one `overflow`, which is the truth honestly
  reported and useless to a caller who wanted the names. The default is
  four megabytes, which holds that burst. The same option sizes the
  Windows read buffer, which had its own name before and the same job.
- On Windows a buffer the caller sized for a local disk is no longer a
  watch that dies on a network share. `ReadDirectoryChangesW` refuses a
  buffer over 64 KiB on a remote directory rather than clamping it, and
  the failure was an unmapped error at the point where the watch was
  re-armed: the watch stopped reporting, with no error and no event.
  lookout comes down to the size a share takes by itself.
- `Kind.unwatched` says that lookout is no longer watching a path, and
  that nothing under it will be reported. A subdirectory the operating
  system refused -- unreadable, or past the per-user watch limit -- was
  swallowed at five places, and the only sign of it was a part of the
  tree that never reported anything. It outranks `overflow`: one says
  look again, the other says looking again is the only way you will ever
  hear about this path.
- A rename is no longer split into a removal and a creation by the
  boundary of a read. Both halves arrive together, but "together" is
  about the kernel's queue and not about the buffer lookout reads it
  into, and all three backends that pair renames decided at the end of
  each read. A half is now held until the whole wait is over. On the
  Apple backend the partner is also looked for anywhere in the delivery
  rather than only next door, because the directory the two names are in
  can be reported between them.
- A write inside a renamed directory is a write. The Apple backend tells
  a creation from a write by remembering every path it has seen, and
  renaming a directory left every path under the old name: the first
  write inside the new one looked new. Renaming re-keys the subtree, and
  a directory that arrives already holding a tree -- an archive
  unpacked, or a rename that could not be paired -- is walked and
  reported, which is what the backends that recurse themselves already
  did.
- `max_dir_entries` is one directory's budget on every backend. It is
  documented as the entries of one watched directory, and the Windows
  backend counted every creation anywhere under a recursive root against
  one number, so twenty directories of three hundred entries overflowed
  a budget none of them reached.
- `Watcher.position` and `Options.since` are how a tool that runs, exits
  and runs again is told what it missed. The position is a short piece
  of text -- `Position.token` writes it, `Position.parse` reads it back
  -- and lookout persists nothing: the token is the caller's to keep.
  Only FSEvents can answer, because only it is backed by a log the
  system keeps per volume rather than by a queue that starts empty, and
  `tracksPosition` says so rather than pretending. A resumed watch
  reports what was created, changed and deleted while nothing was
  watching, resolved against the tree as it is now.
- `Event.target` says whether the path was a file or a directory. After
  a removal the path cannot be stat-ed to find out, so a caller keeping
  a model of a tree had no way to know what had just left it.
- `Filter.only` says what a watch *is* about, which no combination of
  exclusions could express, and `**` crosses a separator, so
  `src/**/*.zig` is a thing that can be written. An include list has to
  answer two questions rather than one -- may this path be reported, and
  may lookout look inside this directory -- because a list naming files
  at any depth still has to let the walk reach them.
- `Watcher.wake` makes a blocked `poll` come back from another thread. A
  program that wanted its thread back had to have left itself a timeout
  to discover that through, and `poll(null)` could not be interrupted at
  all.
- `Watcher.watches` enumerates what the watcher holds -- the path, the
  recursion, and whether it is still parked on an ancestor waiting for
  its path to appear. `Watcher.stats` counted them and could not name
  them, so intent could not be diffed against reality.
- `Options.max_events` is a ceiling on one batch. A process writing
  faster than the caller polls made the library grow without bound;
  past the ceiling the names stop being kept and `Kind.overflow` says so
  against the roots that lost them, which is the answer the caller
  already handles.
- `settle_ms` measures the file as well as timing it. The quiet window
  on its own is a guess about a writer nobody can see, and a kernel that
  coalesces several writes into one notification could leave the window
  closing over a file that was still growing -- the exact failure the
  option exists to prevent. One `stat` at the moment the window closes;
  a file larger than it was starts the window again. A writer that stops
  for longer than the window and then starts again is still
  indistinguishable from one that has finished, and `Kind.closed` is the
  only real answer to that.
- The documentation says what the code does. `Kind.removed` claimed that
  every backend reports a rename as a removal and a creation, which
  `pairsRenames` contradicts; `Kind.renamed` was described as two
  backends' when three produce it for entries; `Stats.registrations` said
  one per path scanned on `poll` when it is one per directory; the module
  header named three backends of five; and the polling backend called
  itself the one for Windows, which has had a backend of its own since
  0.1.0. Where a claim can be asserted rather than written down, it now
  is: the suite holds `tracksPosition` and the entry budget the same way
  it already held `pairsRenames` and `reportsRootMove`.
- What a watcher costs is held to a budget. How long after a change
  `poll` comes back, how much of a burst arrives, and how much memory a
  watched directory costs were each measured once; a measurement nothing
  checks is one that goes quietly wrong.

## 0.1.1

- `Event.time` says when lookout first saw the path change in this
  window, on the same clock a caller reads with
  `std.Io.Timestamp.now(io, .awake)`. An event that says only what
  happened leaves a caller unable to order two batches or to tell a
  change from a backlog.
- `Options.debounce_ms` is the third window, and it answers the question
  the other two cannot. `latency_ms` merges what arrives together and
  reports the most significant kind; `settle_ms` waits for a file's
  contents to stop changing. `debounce_ms` holds every kind until the
  path is quiet and then reports it once, carrying the kind seen
  **last** -- so a path deleted and recreated inside one window is one
  `created`, which coalescing cannot say because `removed` outranks it.
  A caller rebuilding from the end state wants the end state.
- The watched path's own disappearance is reported by every backend.
  Deleting it is `Kind.removed` everywhere; moving it is `Kind.renamed`
  where the backend watches the object rather than the name, and
  `reportsRootMove` is how a program asks which to expect instead of
  discovering it. Three backends were wrong before: FSEvents reported a
  deletion as a move, the polling backend saw neither because it lists a
  directory through a handle that outlives the name, and the Windows
  backend dropped the failed read that says the directory is gone.
- `ERROR_NOTIFY_ENUM_DIR`, the kernel's other spelling of a
  `ReadDirectoryChangesW` buffer overflow, is `Kind.overflow` like the
  zero-length read that says the same thing. It was previously taken for
  a watch going away, which lost the watch as well as the events.
- `Watcher.stats()` reports what a watcher holds: watches,
  registrations the operating system is keeping on its behalf, paths
  held back by a window, and the size of the last batch. The
  registration count is the one that runs into `max_user_watches` and
  the per-process descriptor limit, and there was no way to see it.
- A backend now waits until the batch has *changed* rather than until it
  has *grown*. Under `debounce_ms` a push produces no event for a while,
  and a backend watching the event count would have slept through its
  own deadline -- with no timeout at all, forever.
- `reportsRootMove` answers with `RootMove` rather than with a boolean,
  because there are three shapes and not two: `renamed` on `kqueue` and
  `inotify`, `removed` on FSEvents and polling, and `silent` on Windows,
  where the directory handle survives the rename and the rename itself
  happens in a directory the watch was never put on. The boolean said
  Windows reported `removed`, which it does not; a caller waiting for
  that event waited forever.
- `Options.windows_buffer_bytes` sets how much change the Windows kernel
  may hold for one watch between two reads. It was fixed at 64 KiB, which
  is the largest a network share takes and not always the right answer on
  a local disk: a busy tree polled infrequently overflowed and the caller
  had no way to buy headroom. Sizes are held between 4 KiB and 16 MiB and
  rounded down to a multiple of four; when the buffer does fill, the
  overflow is reported as before.
- An FSEvents watch no longer goes silent for the life of the program.
  The backend unscheduled a stream from its dispatch queue before
  invalidating it, and `FSEventStreamInvalidate` requires the stream to
  still be scheduled: it failed its own assertion and did nothing, so
  every stream was released while the system still had it registered.
  The registrations accumulated, and roughly one stream in twenty-five
  after that was accepted and then never delivered anything -- a watch
  that reported nothing, ever, with no error to say so. The same
  registration kept a pointer to memory the watcher had freed, which is
  the crash that came with it under a program that takes and drops
  watches quickly.
- Setting `LOOKOUT_TRACE` in the environment makes the Apple backend
  write what it did to standard error: every delivery the system made,
  every path in it with its event id and flags, and every decision that
  turned one into an event or dropped it, alongside each stream being
  created, started and stopped. It is read once per process and is
  compiled out where libc is not linked. An event that does not arrive
  was previously not investigable from outside the library.
- `Kind.closed` says that a file open for writing has been closed: the
  writing is over, from the operating system rather than inferred from a
  quiet window, which is what `Options.settle_ms` can only estimate. Only
  `inotify` is told this, through `IN_CLOSE_WRITE`, so `Options.report_closes`
  has to ask for it and `reportsCloses` says whether this backend will
  ever produce one -- a kind that silently means nothing on four backends
  out of five is worse than no kind at all. With it on, a path written and
  then closed inside one coalescing window reports `closed` rather than
  `modified`, which is why it is a choice and not the default.
- `Baseline` answers what `Kind.overflow` could not. The watcher can say
  that its record of a tree is incomplete and not what was lost, because
  the names are gone by the time it knows. A baseline seeded where the
  watch is taken remembers the tree; `diff` re-reads it and returns the
  creations, modifications, attribute changes and removals that the lost
  events would have carried, spelled the way events are and on the same
  ownership terms as `Watcher.poll`. It takes the same `recursive`,
  `max_dir_entries` and `filter` a watch does, so the two can be made to
  cover the same tree. It is the listing comparison the `kqueue` and
  polling backends already made, kept for the caller instead of for the
  watcher; nothing exposed it before.
- `AddOptions.pending` takes a watch on a path that does not exist yet
  instead of failing the `add` with `error.FileNotFound`. The watch is
  parked on the nearest existing ancestor, narrowed to the single entry
  that leads to the path asked for, steps down as the path appears, and
  is promoted to the real watch -- recursion, filter and all -- with the
  appearance reported as `Kind.created` against it. Nothing that happens
  to the ancestor while it waits is reported. A tool watching a directory
  its own first run creates had to poll for it.
- A directory that appears under a recursive watch with files already
  inside it reports them. The `kqueue` and polling backends registered
  such a directory by listing it and keeping that listing as the
  baseline, so everything already in it was taken for something that had
  always been there -- and the directories among them were never
  registered, which left a whole unpacked tree unwatched below the first
  level. `inotify` already did this; now all three do.
- A fresh FSEvents watch no longer reports the directory it was just
  put on as `Kind.created`. The backend resolves a flag against the file
  system by asking whether it has seen the path before, and the walk that
  seeds that answer covered every path under the root and not the root
  itself, so the first delivery naming the watched directory called it
  new. A directory's own `modified` and `attributes` flags are dropped
  too: a directory's times move whenever anything inside it moves, no
  other backend reports that, and FSEvents keeps these flags per path and
  never clears them -- so the first delivery for a directory carried
  whatever was last done to it, however long before the watch.
- `AddOptions.filter` says what a watch is not about: `Filter.ignore`, a
  list of path prefixes and simple globs, and `Filter.allow`, a predicate
  of the caller's, both asked about every ancestor of a path so that
  excluding a directory excludes its whole tree. It is applied where
  lookout does the recursion, so on `inotify`, `kqueue` and `poll` an
  excluded directory is never opened and never registered and costs
  neither a kernel watch nor a descriptor; FSEvents and
  `ReadDirectoryChangesW` recurse in the kernel, which cannot be told
  about a filter, so there the events are dropped and the work happens
  anyway. `prunesIgnored` is how a program asks which of the two it has.
  Before this, a recursive watch over a tree with a large build
  directory in it paid for every file in that directory and the caller
  could only throw the events away afterwards.
- `Event.path` is spelled with the platform's own separator all the way
  down: `/` on POSIX, `\` on Windows, including the part below the watch
  root. The backends already did this; nothing said so, and a caller
  comparing an event against a path it pasted together with `/` matched
  nothing on Windows.
- "What it does not do" names three gaps that were there all along and
  were left to be found: there is no filtering, so a recursive watch
  over a tree with a large build directory in it costs a kernel watch
  or a descriptor for every file in that directory; a path must exist
  before `add` will watch it; and `overflow` comes with no rescan
  helper. It also states `error.WatchLimitReached`, which every backend
  returns when the operating system refuses another watch and which the
  README had never mentioned.

## 0.1.0

First release.

- `Watcher` over five backends behind one API: FSEvents and `kqueue` on
  Apple platforms, `inotify` on Linux, `ReadDirectoryChangesW` on
  Windows, and a polling backend that needs nothing from the kernel and
  runs everywhere. `Options.backend` picks one; `supported` says which
  this target has.
- Renames arrive whole where the kernel knows they are renames:
  `Event.from` carries where a path came from, and `pairsRenames` says
  which backends can tell. Where they cannot -- `kqueue` and polling
  compare directory listings, in which a rename and a delete-plus-create
  are the same thing -- the removal and the creation are reported as
  themselves rather than guessed at.
- `Options.settle_ms` waits for a file to stop changing before reporting
  it as modified, which is the difference between reading a copied file
  and reading half of one. `latency_ms` merges the writes that arrive
  together; this waits for the writing to be over.
- Events are coalesced per path within a window, so a file written in
  four chunks is one `modified` rather than four.
- `Watcher.fd` exposes the kernel descriptor, so a program with a wait
  loop of its own can wait on the watcher alongside its other
  descriptors. The library starts no threads and calls nothing back.
- Recursive watches are implemented by walking and registering each
  directory, and by registering directories created afterwards as they
  appear.
- The test suite runs once per backend the host can execute, so the
  polling backend is held to the same contract as the kernel ones instead
  of to a weaker one of its own. `ci/linux.sh` runs it on Linux in
  Docker, so the `inotify` backend is executed rather than merely
  compiled from a machine that is not Linux.
