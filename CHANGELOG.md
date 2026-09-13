# Changelog

Each entry says what the old shape could not express, so a port has the
reason and not only the diff. Versions follow
[semantic versioning](https://semver.org); before 1.0 the minor is the
breaking one.

## 0.1.0

First release.

- `Watcher` over four backends behind one API: FSEvents and `kqueue` on
  Apple platforms, `inotify` on Linux, and a polling backend that needs
  nothing from the kernel and runs everywhere. `Options.backend` picks
  one; `supported` says which this target has.
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
