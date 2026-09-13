# lookout

[![CI](https://github.com/pedronaugusto/lookout/actions/workflows/ci.yml/badge.svg)](https://github.com/pedronaugusto/lookout/actions/workflows/ci.yml)

A file-system watcher for Zig: one API over FSEvents and `kqueue` on
Apple platforms, `inotify` on Linux, `ReadDirectoryChangesW` on Windows,
and a polling backend that needs nothing from the kernel and runs
everywhere.

- **Pure Zig, no dependencies.** Nothing to vendor, no C to compile, no
  build script of your own. The system interfaces are reached through
  hand-written `extern` declarations; the only thing linked is
  CoreServices, on Apple targets, where FSEvents lives.
- **One contract, not three.** The backends do not merely share a type
  name: the test suite runs once per backend the host can execute, so the
  polling backend is held to the same assertions as the kernel one on the
  same machine. A behaviour only one backend has is a behaviour you
  cannot rely on, and this is how it is kept out.
- **No threads, no callbacks.** Everything happens on the thread that
  calls `poll`. A program with a wait loop of its own takes
  `Watcher.fd` and waits on the watcher alongside its sockets and pipes.
- **Coalesced by default, and debounced on request.** An editor saving a
  file writes it in several pieces; a build system unpacking an archive
  touches a directory a thousand times. Events on one path inside
  `latency_ms` arrive as one event, so a rebuild is triggered once. Set
  `settle_ms` and a `modified` waits until the file has stopped changing,
  which is the difference between reading a copied file and reading half
  of one.
- **Renames arrive whole where the kernel knows they are renames.**
  `Event.kind == .renamed` carries `Event.from`, so a program that
  follows a file does not have to guess which removal goes with which
  creation. Where the kernel cannot say, the removal and the creation are
  reported as themselves rather than guessed at -- see the table below.

## Usage

The block below is not written here: it is a region of
[`examples/usage.zig`](examples/usage.zig), which `zig build examples`
builds and RUNS, extracted by `ci/readme_usage.sh` and compared by CI. A
snippet in a README is a claim about how a library is used, and this one
is a claim something executes.

<!-- BEGIN GENERATED ci/readme_usage.sh -->
```zig
const lookout = @import("lookout");

// One watcher, one watch. `auto` means kqueue on macOS and the BSDs,
// inotify on Linux, and polling anywhere else.
var watcher: lookout.Watcher = try .init(gpa, io, .{});
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
const lookout_dep = b.dependency("lookout", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("lookout", lookout_dep.module("lookout"));
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
| `Event` | `{ id, path, kind, from }`. `path` is absolute and canonical; `from` is where a paired rename came from. |
| `Kind` | `created`, `modified`, `removed`, `renamed`, `attributes`, `overflow`. |
| `Options` | `backend`, `poll_interval_ms`, `latency_ms`, `settle_ms`, `max_dir_entries`. |
| `AddOptions` | `recursive`. |
| `default_backend` | The backend `.auto` resolves to on this target. |
| `supported(backend)` | Whether this target was built with a backend. |
| `pairsRenames(backend)` | Whether it reports `renamed` with a `from`, or a removal and a creation. |

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

- **The Windows backend has never been run by its author.** It compiles
  for `x86_64-windows-gnu`, `x86_64-windows-msvc` and
  `aarch64-windows-gnu`, and the shared suite runs it on the Windows CI
  runner. That is the whole of the evidence behind it. `Watcher.fd` is
  `null` there, because a completion port is not something another wait
  loop can take.
- **`kqueue` costs a descriptor per file.** It watches descriptors, not
  names, so a watched tree costs one per directory and one per file
  inside a watched directory, against the per-process limit. If the
  process runs out, the files inside a watched directory are still
  reported as appearing, disappearing and being renamed, but not as being
  modified. This is why FSEvents and not `kqueue` is the default on Apple
  platforms; `kqueue` remains the better answer for a handful of paths
  watched without recursion.
- **FSEvents coalesces before lookout sees anything.** It has a latency
  window of its own, and within it several changes to one path arrive as
  one delivery with several flags set. lookout keeps that window as short
  as the API allows and does its own coalescing in one place, so that
  every backend coalesces by the same rule; what it cannot do is
  reconstruct an order FSEvents did not keep.
- **FSEvents delivers on a thread lookout does not own.** The library
  starts none and calls nothing back: the dispatch queue appends to a
  fixed buffer and writes one byte to a pipe, and every event a caller
  sees is produced on the thread that called `poll`. If a burst outruns
  that buffer, the excess becomes `Kind.overflow` rather than a blocked
  system callback.
- **Recursion is not a kernel feature.** Neither `kqueue` nor `inotify`
  recurses. lookout walks the tree at `add` time, registers each
  directory, and registers new directories as they appear. A directory
  created and populated faster than lookout can register it can lose the
  events for files inside; lookout scans each new directory immediately
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
  registered it last. The other backends keep them separate. Watch
  either the tree or the subdirectory, not both.
- **`settle_ms` delays only `modified`.** A creation, a removal and a
  rename are facts about a name rather than about contents, and are
  reported at once whatever it is set to.
- **`renamed` means the watched path itself.** A rename of an entry
  inside a watched directory is `removed` on the old name and `created`
  on the new one, on every backend, because the listing comparison the
  BSD and polling backends make cannot tell a rename from a deletion and
  a creation. `renamed` is reserved for the watched path itself being
  moved, which `kqueue` and `inotify` do report and the polling backend
  reports as `removed`.

## Backends

| Backend | Targets | Default | Mechanism | Recursion costs | Renames |
|---|---|---|---|---|---|
| `fsevents` | macOS, iOS and the rest of Apple's | yes | One FSEvents stream per watch, delivered on a dispatch queue into a pipe the watcher owns. | one stream, and one remembered path per file | paired |
| `kqueue` | Apple platforms, FreeBSD, NetBSD, OpenBSD, DragonFly | on the BSDs | `EVFILT_VNODE` on a descriptor per watched path, plus a listing comparison to name the entry that changed. | one descriptor per directory **and per file** | removal + creation |
| `inotify` | Linux | yes | One kernel watch per directory; the kernel names the entry and gives each rename a cookie. | one kernel watch per directory | paired |
| `windows` | Windows | yes | `ReadDirectoryChangesW` with overlapped reads drained through a completion port. | nothing: recursion is a flag | paired |
| `poll` | everywhere | where there is no kernel backend | Re-stat and re-list on a timer. | one listing per directory per tick | removal + creation |

`Options.backend` selects one explicitly; `supported` says whether this
target has it. Asking for a backend this target was not built with fails
`init` with `error.BackendUnavailable` rather than failing to compile, so
a program can ask and fall back.

### Where the backends disagree, and what the contract does about it

Two differences are real and cannot be papered over, so they are in the
API rather than in the small print.

**Renames.** FSEvents, `inotify` and `ReadDirectoryChangesW` each say
which removal goes with which creation -- by reporting both halves in one
delivery, by a cookie, by an old-name/new-name pair. `kqueue` and polling
learn what changed by comparing directory listings, where a rename and a
delete-plus-create are the same listing. So `pairsRenames(backend)` tells
you which shape to expect, `Event.from` carries the answer where there is
one, and neither backend guesses. `Kind.renamed` with `from == null` is a
third thing: the watched path itself was moved, which has no second half.

**Flags versus facts.** `inotify` reports a sequence of things that
happened. FSEvents reports flags accumulated per path which it never
clears, so a file created an hour ago and written now still arrives with
the created bit set. The FSEvents backend therefore remembers which
paths it believes exist -- seeded by one listing walk per watch, kept
current from what it reports -- and asks that, not the flags, whether
something is a creation. It costs one string per watched file, which is
still nothing beside `kqueue`'s descriptor per watched file.

## What has run where

Test results are a claim like any other, so here is the shape of the
evidence. The suite is executed on Linux, macOS and Windows by CI --
`zig build test` in Debug, ReleaseSafe, ReleaseFast and ReleaseSmall on
each, plus `zig build examples` -- and every target in the cross-compile
matrix is compiled including the test binary, so a backend source cannot
break unnoticed behind an empty archive.

`ci/linux.sh` closes the gap for `inotify`, which now runs rather than
merely compiling. What is left compile-only is Windows: nothing in
`src/backend/windows.zig` has been executed on the machine it was written
on, and the Windows runner in CI is the only place it runs. The polling
backend's Windows path has the same status, and rests on `std.Io.Dir`
behaving there as it does on POSIX -- that a directory opened with
`.iterate` can be listed while entries are being created and removed, and
that `statFile` reports a modification time with enough resolution to see
two writes close together.

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
`LOOKOUT_LINUX_IMAGE` to reuse an image you already have.

## Requirements

Zig 0.16.0. No other dependencies.

## License

MIT. See [LICENSE](LICENSE).
