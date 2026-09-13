# zwatch

[![CI](https://github.com/pedronaugusto/zwatch/actions/workflows/ci.yml/badge.svg)](https://github.com/pedronaugusto/zwatch/actions/workflows/ci.yml)

A file-system watcher for Zig: one API over `kqueue` on macOS and the
BSDs, `inotify` on Linux, and a polling backend that needs nothing from
the kernel and runs everywhere else.

- **Pure Zig, no dependencies.** Nothing to vendor, nothing to link, no
  `libc` requirement beyond what your target already has. Add the import
  and build.
- **One contract, not three.** The backends do not merely share a type
  name: the test suite runs once per backend the host can execute, so the
  polling backend is held to the same assertions as the kernel one on the
  same machine. A behaviour only one backend has is a behaviour you
  cannot rely on, and this is how it is kept out.
- **No threads, no callbacks.** Everything happens on the thread that
  calls `poll`. A program with a wait loop of its own takes
  `Watcher.fd` and waits on the watcher alongside its sockets and pipes.
- **Coalesced by default.** An editor saving a file writes it in several
  pieces; a build system unpacking an archive touches a directory a
  thousand times. Events on one path inside a short window arrive as one
  event, so a rebuild is triggered once.

## Usage

The block below is not written here: it is a region of
[`examples/usage.zig`](examples/usage.zig), which `zig build examples`
builds and RUNS, extracted by `ci/readme_usage.sh` and compared by CI. A
snippet in a README is a claim about how a library is used, and this one
is a claim something executes.

<!-- BEGIN GENERATED ci/readme_usage.sh -->
```zig
const zwatch = @import("zwatch");

// One watcher, one watch. `auto` means kqueue on macOS and the BSDs,
// inotify on Linux, and polling anywhere else.
var watcher: zwatch.Watcher = try .init(gpa, io, .{});
defer watcher.deinit();

const id = try watcher.add(dir_path, .{ .recursive = true });
defer watcher.remove(id);

// Something changes the tree. In a real program this is someone else:
// an editor saving, a build writing, a package manager unpacking.
try scratch.writeFile(io, .{ .sub_path = "notes.txt", .data = "hello" });

// `poll` blocks until something happens or the timeout expires, and
// returns one event per path, coalesced. The slice and every path in
// it belong to the watcher until the next call.
for (try watcher.poll(1_000)) |event| {
    std.debug.print("{s} {s}\n", .{ @tagName(event.kind), event.path });
}
```
<!-- END GENERATED -->

Add it as a dependency and link the module:

```zig
const zwatch_dep = b.dependency("zwatch", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zwatch", zwatch_dep.module("zwatch"));
```

## The API

| Declaration | What it is |
|---|---|
| `Watcher.init(gpa, io, options)` | A watcher holding no watches. `io` is the `std.Io` every file-system operation goes through, captured for the watcher's lifetime. |
| `Watcher.deinit()` | Releases the watches, the descriptors and the last batch of events. |
| `Watcher.add(path, options)` | Watches a file or a directory, optionally recursively. Returns a `WatchId`. A path already watched by this watcher is `error.PathAlreadyWatched`. |
| `Watcher.remove(id)` | Stops a watch and releases its descriptors. |
| `Watcher.poll(timeout_ms)` | Blocks until something happens, and returns the coalesced events. `null` blocks indefinitely; `0` reports what is already queued. |
| `Watcher.fd()` | The descriptor to wait on, or `null` for the polling backend. |
| `Watcher.backend()` | Which backend this watcher resolved to. |
| `Event` | `{ id, path, kind }`. `path` is absolute and canonical. |
| `Kind` | `created`, `modified`, `removed`, `renamed`, `attributes`, `overflow`. |
| `Options` | `backend`, `poll_interval_ms`, `latency_ms`, `max_dir_entries`. |
| `AddOptions` | `recursive`. |
| `native_backend` | The backend `.auto` resolves to here, or `null` where polling is the only choice. |

The events a `poll` returns, and every path in them, belong to the
watcher and are invalidated by the next `poll`. Copy anything you intend
to keep.

## Coalescing

`poll` blocks until the first event of a batch arrives and then keeps
collecting for `latency_ms` more — 50 ms by default. Everything that
lands on one path inside that window becomes one `Event`, carrying the
most significant kind observed:

```
attributes  <  modified  <  created  <  renamed  <  removed  <  overflow
```

So a file created and then written reports `created`; a file written and
then deleted reports `removed`. A path removed and recreated inside one
window reports `removed`, which is the one case where the coalesced kind
is not the end state — a caller that tracks state should treat any event
as "look at this path again" rather than as a replay of what happened.

Set `latency_ms` to zero to switch coalescing off and get whatever the
kernel had queued.

## What it does not do

The point of this section is that the list is short and explicit, rather
than something you discover.

- **No native Windows backend.** Windows gets the polling backend in this
  release. `ReadDirectoryChangesW` is the right answer there and it is
  not written yet, so on Windows a change is seen up to
  `poll_interval_ms` after it happens and a file created and deleted
  between two scans is never seen at all. A watched directory is also
  held open for the life of the watch, which on Windows can stop another
  process from deleting or renaming it.
- **No FSEvents on macOS.** `kqueue` watches descriptors, so a watched
  tree costs one descriptor per directory and one per file inside a
  watched directory, against the per-process limit. If the process runs
  out of descriptors, the files inside a watched directory are still
  reported as appearing, disappearing and being renamed, but not as
  being modified. FSEvents has no such cost and would suit a very large
  tree better.
- **Recursion is not a kernel feature.** Neither `kqueue` nor `inotify`
  recurses. zwatch walks the tree at `add` time, registers each
  directory, and registers new directories as they appear. A directory
  created and populated faster than zwatch can register it can lose the
  events for files inside; zwatch scans each new directory immediately
  and reports what it finds as `created`, which closes the race for
  files that still exist and not for files already gone again.
- **Symbolic links are not followed.** A link inside a watched tree is an
  entry, not a doorway, so a watch cannot silently widen into a
  directory you did not ask for.
- **A watched file that is replaced is not followed.** The
  write-to-temporary-and-rename that editors do replaces the inode; a
  watch on the file reports `renamed` or `removed` and then goes quiet,
  because the descriptor still refers to the old file. Watch the
  containing directory to follow a path rather than a file.
- **Large directories are capped.** A directory holding more than
  `max_dir_entries` entries, 4096 by default, reports `Kind.overflow`
  against the watch root, meaning "rescan this yourself". `kqueue` and
  `poll` name entries by comparing listings and past the limit genuinely
  cannot see a change; `inotify` is told every name by the kernel and
  keeps reporting them, and counts entries only so that the signal is
  the same on every platform. Raise the budget if you meant to watch a
  directory that size.
- **`overflow` is not an error.** It is also what the kernel event queue
  overflowing looks like on Linux. Either way the answer is the same:
  the watcher's record is incomplete and the caller should re-read the
  tree.
- **One watcher, one thread.** A `Watcher` is not thread-safe. Several
  may exist in one process.
- **One watcher watches a path once.** A second `add` of a path already
  watched fails with `error.PathAlreadyWatched`. Two watchers may watch
  the same path; one watcher may not watch it twice, because `inotify`
  hands back the same kernel watch descriptor for the same inode and the
  second registration would quietly take the first one's events over.
- **Overlapping watches are not fully independent on Linux.** Watching a
  tree recursively and also watching a directory inside it means two
  watches meeting at one inode, which `inotify` represents once; the
  events for the shared directory arrive under whichever watch
  registered it last. The BSD and polling backends keep them separate.
  Watch either the tree or the subdirectory, not both.
- **`renamed` means the watched path itself.** A rename of an entry
  inside a watched directory is `removed` on the old name and `created`
  on the new one, on every backend, because the listing comparison the
  BSD and polling backends make cannot tell a rename from a deletion and
  a creation. `renamed` is reserved for the watched path itself being
  moved, which `kqueue` and `inotify` do report and the polling backend
  reports as `removed`.

## Backends

| Backend | Targets | Mechanism |
|---|---|---|
| `kqueue` | macOS, iOS, FreeBSD, NetBSD, OpenBSD, DragonFly | `EVFILT_VNODE` on a descriptor per watched path, plus a directory-listing comparison to name the entry that changed. |
| `inotify` | Linux | One kernel watch per directory; the kernel names the entry. |
| `poll` | everywhere, including Windows | Re-stat and re-list on a timer. |

`Options.backend` selects one explicitly. Asking for a backend this
target was not built with fails `init` with `error.BackendUnavailable`
rather than failing to compile, so a program can ask and fall back.

## What has run where

Test results are a claim like any other, so here is the shape of the
evidence. The suite is executed on Linux, macOS and Windows by CI --
`zig build test` in Debug, ReleaseSafe, ReleaseFast and ReleaseSmall on
each, plus `zig build examples` -- and every target in the cross-compile
matrix is compiled including the test binary, so a backend source cannot
break unnoticed behind an empty archive.

What that leaves unverified between CI runs: the `inotify` and Windows
paths have no local execution behind them, only compilation. Two
Windows-specific behaviours in particular rest on `std.Io.Dir` and are
asserted by the suite rather than by reading Win32: that a directory
opened with `.iterate` can be listed while entries are being created and
removed, and that `statFile` reports a modification time with enough
resolution to see two writes close together. Both hold on the POSIX
targets this was developed on.

## Testing

```
zig build test          # the suite, on this host, once per backend it has
ci/linux.sh             # the suite on Linux, in Docker, all four modes
```

`ci/linux.sh` exists because the `inotify` backend cannot run on macOS or
Windows, and a backend that only compiles is a backend nobody has run. It
builds a Debian image with the pinned Zig from
[`ci/linux.Dockerfile`](ci/linux.Dockerfile) — no network beyond that,
nothing installed on the host — mounts the working tree read-only, and
runs `zig build test` inside it in Debug, ReleaseSafe, ReleaseFast and
ReleaseSmall. Pass mode names to run fewer, or set
`ZWATCH_LINUX_IMAGE` to reuse an image you already have.

## Requirements

Zig 0.16.0. No other dependencies.

## License

MIT. See [LICENSE](LICENSE).
