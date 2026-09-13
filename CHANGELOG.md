# Changelog

Each entry says what the old shape could not express, so a port has the
reason and not only the diff. Versions follow
[semantic versioning](https://semver.org); before 1.0 the minor is the
breaking one.

## 0.1.0

First release.

- `Watcher` over three backends behind one API: `kqueue` on macOS and the
  BSDs, `inotify` on Linux, and a polling backend that needs nothing from
  the kernel and is what Windows uses.
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
