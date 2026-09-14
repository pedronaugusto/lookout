# lookout

[![CI](https://github.com/pedronaugusto/lookout/actions/workflows/ci.yml/badge.svg)](https://github.com/pedronaugusto/lookout/actions/workflows/ci.yml)

A file-system watcher for Zig. One `Watcher` type over FSEvents and
`kqueue` on Apple platforms, `inotify` on Linux, `ReadDirectoryChangesW`
on Windows, and a polling backend that needs nothing from the kernel.

## Usage

The block below is a region of [`examples/usage.zig`](examples/usage.zig),
which `zig build examples` builds and runs; CI compares the two.

<!-- BEGIN GENERATED ci/readme_usage.sh -->
```zig
const lookout = @import("lookout");

// One watcher, one watch. `auto` means FSEvents on Apple platforms,
// kqueue on the BSDs, inotify on Linux, ReadDirectoryChangesW on
// Windows, and polling anywhere else.
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

## Install

```
zig fetch --save git+https://github.com/pedronaugusto/lookout
```

```zig
const lookout_dep = b.dependency("lookout", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("lookout", lookout_dep.module("lookout"));
```

There are no dependencies and no C to compile. The system interfaces are
reached through hand-written `extern` declarations; on Apple targets the
build links CoreServices, where FSEvents lives, and nothing else is
linked anywhere.

## The API

| Declaration | What it is |
|---|---|
| `Watcher.init(gpa, io, options)` | A watcher holding no watches. `io` is the `std.Io` every file-system operation goes through, captured for the watcher's lifetime. |
| `Watcher.deinit()` | Releases the watches, the descriptors and the last batch of events. |
| `Watcher.add(path, options)` | Watches a file or a directory, optionally recursively. Returns a `WatchId`. A path already watched by this watcher is `error.PathAlreadyWatched`. |
| `Watcher.remove(id)` | Stops a watch and releases its descriptors. |
| `Watcher.poll(timeout_ms)` | Blocks until something happens, and returns the coalesced events. `null` blocks indefinitely; `0` reports what is already queued. |
| `Watcher.fd()` | The descriptor to wait on, or `null` where the backend has none. |
| `Watcher.backend()` | Which backend this watcher resolved to. |
| `Watcher.stats()` | What the watcher holds: watches, registrations the operating system is keeping, paths held back by a window, events the last `poll` returned. |
| `Event` | `{ id, path, kind, from, time }`. `path` is absolute, canonical, and spelled with the platform's separator; `from` is where a paired rename came from; `time` is when lookout first saw the path change in this window. |
| `Kind` | `created`, `modified`, `removed`, `renamed`, `attributes`, `closed`, `overflow`. |
| `Options` | `backend`, `poll_interval_ms`, `latency_ms`, `settle_ms`, `debounce_ms`, `report_closes`, `max_dir_entries`. |
| `AddOptions` | `recursive`, `filter`, `pending`. |
| `Filter` | What a watch is not about: `ignore`, a list of path prefixes and simple globs; `allow`, a predicate of the caller's; `context`, passed back to it. |
| `Baseline` | What a tree looked like. `seed` it where the watch is taken, `diff` it on `Kind.overflow` for the changes the lost events would have carried. |
| `RootMove` | `renamed`, `removed`, or `silent` for nothing at all. |
| `default_backend` | The backend `.auto` resolves to on this target. |
| `supported(backend)` | Whether this target was built with a backend. |
| `pairsRenames(backend)` | Whether it reports `renamed` with a `from`, or a removal and a creation. |
| `reportsRootMove(backend)` | Which of the three shapes a move of the watched path itself arrives as. |
| `prunesIgnored(backend)` | Whether an excluded directory is left unregistered, or only has its events dropped. |
| `reportsCloses(backend)` | Whether the backend is told that a file open for writing has been closed. |

The events a `poll` returns, and every path in them, belong to the
watcher and are invalidated by the next `poll`. Copy anything you keep.

## Design

### Where the work happens

Everything happens on the thread that calls `poll`. Nothing runs in the
background and nothing is called back. A program with a wait loop of its
own takes `Watcher.fd()`, which becomes readable when there is something
to report; it is `null` for the polling backend, which has nothing to
wait on, and on Windows, where the watcher waits on an I/O completion
port no other loop can take.

FSEvents delivers on a dispatch queue the system owns. That thread copies
into a fixed buffer and writes one byte to a pipe, and nothing else; a
burst that outruns the buffer becomes `Kind.overflow`.

The allocator holds the watch tables and the batch of events, so a
watcher with no watches holds no memory. The slice `poll` returns is the
watcher's, and so is every path in it; the next `poll` frees them.

### Three windows

| Option | Waits for | Reports |
|---|---|---|
| `latency_ms` | everything that arrives together | the most significant kind of the burst |
| `settle_ms` | a file's contents to stop changing | `modified`, once the writing is over |
| `debounce_ms` | a path to go quiet, whatever happened to it | one event, carrying the kind seen **last** |

`poll` blocks until the first event of a batch arrives and then collects
for `latency_ms` more, 50 ms by default. Everything on one path inside
that window becomes one `Event`, carrying the most significant kind:

```
attributes  <  modified  <  closed  <  created  <  renamed  <  removed  <  overflow
```

A file created and then written reports `created`; a file written and
then deleted reports `removed`. A path removed and recreated inside one
window also reports `removed` — the one case where the coalesced kind is
not the end state — so treat an event as "look at this path again". Zero
switches coalescing off.

`settle_ms` delays only `modified`. A creation, a removal and a rename
are facts about a name, and are reported at once whatever it is set to.

`debounce_ms` reports the end state: a file deleted and then recreated is
one `created`, which coalescing cannot say because `removed` outranks
`created`. It supersedes the other two — a non-zero `debounce_ms` takes
over from `settle_ms`, and `poll` returns as soon as a window closes.

### Recursion

Neither `kqueue` nor `inotify` recurses. lookout walks the tree at `add`,
registers each directory, and registers new ones as they appear,
reporting whatever is already inside as created — which closes the race
for files that still exist and not for files already gone again. A deep
tree costs one descriptor or one kernel watch per directory, against a
per-process or per-user limit; `Watcher.stats().registrations` is the
number that runs into it. FSEvents and `ReadDirectoryChangesW` recurse in
the kernel, so a tree costs one stream or one handle.

### Filtering

`AddOptions.filter` says what a watch is not about. `Filter.ignore` is a
list of path prefixes and simple globs: `*` and `?` match within one path
component, a pattern holding no separator matches the final component at
any depth, and an absolute pattern matches the absolute path.
`Filter.allow` is the caller's own predicate. Both are asked about every
ancestor of a path, so excluding a directory excludes its subtree.

Where lookout does the recursion — `inotify`, `kqueue`, `poll` — an
excluded directory is never opened and never registered, and its tree
costs nothing. Where the kernel recurses it cannot be told about a
filter, so the work happens anyway and only the events are dropped.
`prunesIgnored(backend)` says which of the two you have.

### Renames

FSEvents, `inotify` and `ReadDirectoryChangesW` each say which removal
goes with which creation — both halves in one delivery, a cookie, an
old-name/new-name pair. `kqueue` and polling learn what changed by
comparing directory listings, in which a rename and a delete-plus-create
are the same thing. `pairsRenames(backend)` says which shape to expect,
`Event.from` carries the answer where there is one, and neither backend
guesses.

`Kind.renamed` with `from == null` means the watched path itself was
moved, which has no second half. Deleting the watched path is
`Kind.removed` everywhere. Moving it is `renamed` on `kqueue` and
`inotify`, which watch the object and are told; `removed` on FSEvents and
polling, which see only that the name is empty; and nothing at all on
Windows, where the handle survives the rename and the rename happens in a
directory the watch was not put on. `reportsRootMove` gives all three.

### Losing events

`Kind.overflow` against a watch root means the record is incomplete and
the tree should be read again. It comes from the `inotify` queue
overflowing, from FSEvents dropping events, from `ReadDirectoryChangesW`
returning an empty read or `ERROR_NOTIFY_ENUM_DIR`, and from a directory
holding more than `Options.max_dir_entries` entries, 4096 by default. It
is not an error.

It does not say what was lost, because by then the names are gone. Seed
a `Baseline` where the watch is taken and `diff` it when the overflow
arrives: it re-reads the tree and returns the changes the events would
have carried, on the same ownership terms as the slice `poll` returns.

### Finished writes

`settle_ms` decides a write is over when the file has been still for a
window, which is an estimate. `inotify` is told exactly, through
`IN_CLOSE_WRITE`: `Options.report_closes` asks for it and `Kind.closed`
carries it. `reportsCloses(backend)` says whether the backend can produce
one, and four of the five cannot. It is off by default because turning it
on changes what a write looks like — `closed` outranks `modified` inside
a coalescing window. Asking for it where it is not reported costs
nothing; the writes still arrive as `modified`.

### Watching a path that is not there

`add` on a missing path is `error.FileNotFound` unless
`AddOptions.pending` is set. With it the watch is parked on the nearest
existing ancestor, narrowed to the single entry that leads to the path
asked for, and steps down as the path appears; when the path appears the
watch is promoted to the real one — recursion, filter and all — and
reported as `Kind.created`. The id comes back from `add` at once and does
not change. Nothing that happens to the ancestor meanwhile is reported.

### One error for the watch limit

`error.WatchLimitReached` is what `add` returns when the operating system
refuses another watch: `ENOSPC` from `inotify_add_watch`, the per-user
`max_user_watches` cap; `ENOMEM` from `kevent`; a stream FSEvents will
not start; a handle Windows will not take. A file that merely sits inside
a watched directory is dropped instead, since the directory still reports
it appearing and disappearing; only the path the caller named is an
error.

### What each backend costs

| Backend | Mechanism | Recursion costs | Renames | Ignored subtree |
|---|---|---|---|---|
| `fsevents` | One stream per watch, delivered on a dispatch queue into a pipe the watcher owns. | one stream, and one remembered path per file | paired | events dropped; the kernel recurses regardless |
| `kqueue` | `EVFILT_VNODE` on a descriptor per watched path, plus a listing comparison to name the entry that changed. | one descriptor per directory **and per file** | removal + creation | never opened, never registered |
| `inotify` | One kernel watch per directory; the kernel names the entry and gives each rename a cookie. | one kernel watch per directory | paired | never opened, never registered |
| `windows` | `ReadDirectoryChangesW` with overlapped reads drained through a completion port. | nothing: recursion is a flag | paired | events dropped; the kernel recurses regardless |
| `poll` | Re-stat and re-list on a timer. | one listing per directory per tick | removal + creation | never opened, never registered |

I made FSEvents the default on Apple platforms rather than `kqueue`,
because it recurses without a descriptor per directory and pairs renames.
`kqueue` is still the better answer for a handful of paths watched
without recursion; a process that runs out of descriptors under it still
sees files inside a watched directory appear, disappear and be renamed,
but not be modified.

`Options.backend` selects one explicitly and `supported` says whether
this target has it. Asking for one this target was not built with fails
`init` with `error.BackendUnavailable` rather than failing to compile.

## Scope

What lookout does not do:

- Symbolic links are not followed. A link inside a watched tree is an
  entry, not a doorway into a directory you did not ask for.
- A watched file that is replaced rather than written — the
  write-to-temporary-and-rename an editor does — is reported once and
  then goes quiet. Watch the containing directory to follow a path.
- A `Watcher` is not thread-safe. Several may exist in one process.
- One watcher watches a path once; a second `add` of it is
  `error.PathAlreadyWatched`. On Linux two watches that overlap share one
  kernel watch where they meet, and its events go to whichever came last.
- Nothing is persisted. There is no answer to what changed while the
  process was not running.

## Platforms

| Platform | Backends | Tested |
|---|---|---|
| macOS, and the other Apple platforms | `fsevents` (default), `kqueue`, `poll` | macOS CI runner |
| Linux | `inotify` (default), `poll` | Ubuntu CI runner, and `ci/linux.sh` in Docker |
| FreeBSD, NetBSD, OpenBSD, DragonFly | `kqueue` (default), `poll` | cross-compiled only |
| Windows | `windows` (default), `poll` | compiles for Windows; the CI run is pending |

Pending: the Windows read buffer is fixed at 64 KB and is not
configurable. That waits on a green Windows CI run.

CI compiles every commit for `x86_64-linux-gnu`, `aarch64-linux-gnu`,
`x86_64-linux-musl`, `x86_64-windows-gnu`, `x86_64-windows-msvc`,
`aarch64-windows-gnu`, `x86_64-freebsd` and `x86_64-netbsd`, test binary
included, so no backend source can break behind an empty archive.

## Testing

```
zig build test          # the suite, once per backend this host has
sh ci/linux.sh          # the suite on Linux, in Docker, all four modes
```

Setting `LOOKOUT_TRACE` in the environment makes the Apple backend and
the suite write what they did to standard error, which is how an event
that did not arrive is chased down. It is read once per process.

The suite runs whole against each backend the host can execute, so the
polling backend is held to the same assertions as the kernel ones on the
same machine. `pairsRenames`, `reportsRootMove`, `prunesIgnored` and
`reportsCloses` are asserted per backend, so the tables above cannot go
stale quietly.

`ci/linux.sh` exists because `inotify` cannot run on macOS or Windows. It
builds a Debian image with the pinned Zig from
[`ci/linux.Dockerfile`](ci/linux.Dockerfile), mounts the working tree
read-only, and runs `zig build test` inside it in all four optimize modes.
Pass mode names to run fewer, or set `LOOKOUT_LINUX_IMAGE` to reuse an
image you have.

## Requirements

Zig 0.16.0. No other dependencies.

## License

MIT. See [LICENSE](LICENSE).
