# Changelog

Each entry says what the old shape could not express, so a port has the
reason and not only the diff. Versions follow
[semantic versioning](https://semver.org); before 1.0 the minor is the
breaking one.

## Unreleased

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
