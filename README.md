# lookout

[![CI](https://github.com/pedronaugusto/lookout/actions/workflows/ci.yml/badge.svg)](https://github.com/pedronaugusto/lookout/actions/workflows/ci.yml)

lookout watches a file or a directory tree and says what changed. One
`Watcher` type sits over FSEvents and `kqueue` on Apple platforms,
`inotify` on Linux, `ReadDirectoryChangesW` on Windows, and a polling
backend that needs nothing from the kernel.

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
build links libc and CoreServices, where FSEvents lives, and nothing is
linked anywhere else.

## The API

| Declaration | What it is |
|---|---|
| `Watcher.init(gpa, io, options)` | A watcher holding no watches. `io` is the `std.Io` every file-system operation goes through, captured for the watcher's lifetime. |
| `Watcher.deinit()` | Releases the watches, the descriptors and the last batch of events. |
| `Watcher.add(path, options)` | Watches a file or a directory, optionally recursively. Returns a `WatchId`. A path already watched by this watcher is `error.PathAlreadyWatched`. |
| `Watcher.remove(id)` | Stops a watch and releases its descriptors. |
| `Watcher.poll(timeout_ms)` | Blocks until something happens, and returns the coalesced events. `null` blocks indefinitely; `0` reports what is already queued. |
| `Watcher.fd()` | The descriptor to wait on, or `null` where the backend has none. |
| `Watcher.wake()` | Makes a blocked `poll` come back. The one thing a watcher takes from another thread. |
| `Watcher.backend()` | Which backend this watcher resolved to. |
| `Watcher.stats()` | What the watcher holds: watches, registrations the operating system is keeping, paths held back by a window, events the last `poll` returned. |
| `Watcher.watches(gpa)` | Every watch, with its path, its recursion, and whether it is still waiting for its path to appear. |
| `Watcher.position()` | Where this watcher has got to, for `Options.since` to resume from, or `null` where the backend keeps no log. |
| `Event` | `{ id, path, kind, from, time, target }`. `path` is absolute, canonical, and spelled with the platform's separator; `from` is where a paired rename came from; `time` is when lookout first saw the path change in this window; `target` is whether it is a file or a directory. |
| `Kind` | `created`, `modified`, `removed`, `renamed`, `attributes`, `closed`, `overflow`, `unwatched`. |
| `Target` | `file`, `directory`, or `unknown` where the backend was not told and the path is already gone. |
| `Options` | `backend`, `poll_interval_ms`, `latency_ms`, `settle_ms`, `debounce_ms`, `report_closes`, `buffer_bytes`, `max_dir_entries`, `max_events`, `since`. |
| `AddOptions` | `recursive`, `filter`, `pending`. |
| `Filter` | What a watch is about: `ignore`, patterns to leave out; `only`, patterns to keep and nothing else; `allow`, a predicate of the caller's; `context`, passed back to it. |
| `Baseline` | What a tree looked like. `seed` it where the watch is taken, `diff` it on `Kind.overflow` for the changes the lost events would have carried. |
| `Position` | Where a watcher had got to. `token` writes it as text, `parse` reads it back. |
| `RootMove` | `renamed`, `removed`, or `silent` for nothing at all. |
| `default_backend` | The backend `.auto` resolves to on this target. |
| `folds_case` | Whether paths are compared as this target's file systems compare them, or byte for byte. |
| `supported(backend)` | Whether this target was built with a backend. |
| `pairsRenames(backend)` | Whether it reports `renamed` with a `from`, or a removal and a creation. |
| `reportsRootMove(backend)` | Which of the three shapes a move of the watched path itself arrives as. |
| `prunesIgnored(backend)` | Whether an excluded directory is left unregistered, or only has its events dropped. |
| `reportsCloses(backend)` | Whether the backend is told that a file open for writing has been closed. |
| `tracksPosition(backend)` | Whether it can say where it has got to, so `position` answers and `since` is worth setting. |

The events a `poll` returns, and every path in them, belong to the
watcher and are invalidated by the next `poll`. Copy anything you keep.

## Design

**Everything happens on the thread that calls `poll`.** Nothing runs in
the background and nothing is called back. A program with a wait loop of
its own takes `Watcher.fd()`, which becomes readable when there is
something to report; it is `null` for the polling backend, which has
nothing to wait on, and on Windows, where the watcher waits on an I/O
completion port no other loop can take.

FSEvents delivers on a dispatch queue the system owns; that thread copies
into a fixed buffer and writes one byte to a pipe, and a burst that
outruns the buffer becomes `Kind.overflow`. The allocator holds the watch
tables and the batch of events, so a watcher with no watches holds no
memory.

**Three windows decide when an event is reported.**

| Option | Waits for | Reports |
|---|---|---|
| `latency_ms` | everything that arrives together | the most significant kind of the burst |
| `settle_ms` | a file's contents to stop changing | `modified`, once the writing is over |
| `debounce_ms` | a path to go quiet, whatever happened to it | one event, carrying the kind seen **last** |

`poll` blocks until the first event of a batch arrives and then collects
for `latency_ms` more, 50 ms by default. Everything on one path in that
window becomes one `Event`, carrying the most significant kind:

```
attributes < modified < closed < created < renamed < removed < overflow < unwatched
```

A file created and then written reports `created`; a file written and
then deleted reports `removed`. A path removed and recreated inside one
window also reports `removed` — the one case where the coalesced kind is
not the end state — so treat an event as "look at this path again". Zero
switches coalescing off.

`latency_ms` has a floor on FSEvents that cannot be lowered: the system
coalesces on its own over about ten milliseconds before lookout is told
anything, so a change arrives some eleven milliseconds after it happens
however small this is set. `kqueue` answers in a fifth of a millisecond
and polling in up to one `poll_interval_ms`.

`settle_ms` delays only `modified`, and waits for the file to stop
growing as well as for the window to pass: one `stat` when the window
closes, and a file larger than it was starts the window again. What no
measurement can see is a writer that pauses for longer than the window
and then starts again; `Kind.closed` is the only real answer to that,
and one backend is told it. A creation, a removal and a rename are facts
about a name, and are reported at once whatever this is set to.

`debounce_ms` reports the end state: a file deleted and then recreated is
one `created`, which coalescing cannot say because `removed` outranks
`created`. It supersedes the other two — a non-zero `debounce_ms` takes
over from `settle_ms`, and `poll` returns as soon as a window closes.

**Neither `kqueue` nor `inotify` recurses.** lookout walks the tree at
`add`, registers each directory, and registers new ones as they appear,
reporting whatever is already inside as created — which closes the race
for files that still exist and not for files already gone again. A deep
tree costs one descriptor or one kernel watch per directory, against a
per-process or per-user limit; `Watcher.stats().registrations` is the
number that runs into it. FSEvents and `ReadDirectoryChangesW` recurse
in the kernel, so a tree costs one stream or one handle.

**`AddOptions.filter` says what a watch is about.** `Filter.ignore`
names what to leave out and `Filter.only` names what to keep and nothing
else; `Filter.allow` is the caller's own predicate. All three are asked
about every ancestor, so excluding a directory excludes its subtree.

A pattern is matched against the path relative to the watch root, or
against the absolute path when the pattern is itself absolute: `*` and
`?` match within one path component, `**` crosses a separator, and a
pattern with no separator also matches the final component at any depth.
Between two separators `**` also stands for no directory at all, so
`src/**/*.zig` covers `src/main.zig` as well as `src/deep/main.zig`.

An include list narrows the events without narrowing the walk further
than it has to: a directory is still walked into when a pattern could
match something inside it, or `only = &.{"src/**/*.zig"}` would exclude
`src` and take the files under it with it.

Where lookout does the recursion — `inotify`, `kqueue`, `poll` — an
excluded directory is never opened and never registered, and its tree
costs nothing. Where the kernel recurses it cannot be told about a
filter, so the work happens anyway and only the events are dropped.
`prunesIgnored(backend)` says which of the two you have.

**FSEvents, `inotify` and `ReadDirectoryChangesW` each say which removal
goes with which creation** — both halves in one delivery, a cookie, an
old-name/new-name pair. `kqueue` and polling learn what changed by
comparing directory listings, in which a rename and a delete-plus-create
are the same thing. `pairsRenames(backend)` says which shape to expect,
`Event.from` carries the answer where there is one, and neither backend
guesses.

Both halves of a rename arrive together, but "together" is about the
kernel's queue and not about the buffer lookout reads it into: a burst
long enough puts one pair either side of a read. A half with no partner
is held until the whole wait is over rather than being decided at the
end of its own read, so a rename stays a rename under load.

`Kind.renamed` with `from == null` means the watched path itself moved,
which has no second half. Deleting the watched path is `Kind.removed`
everywhere. Moving it is `renamed` on `kqueue` and `inotify`, which watch
the object and are told; `removed` on FSEvents and polling, which see
only that the name is empty; and nothing on Windows, where the handle
survives the rename and the rename happens in a directory the watch was
not put on. `reportsRootMove` gives all three.

**`Kind.overflow` against a watch root means the record is incomplete
and the tree should be read again.** It comes from the `inotify` queue
overflowing, from FSEvents dropping events, from `ReadDirectoryChangesW`
returning an empty read or `ERROR_NOTIFY_ENUM_DIR`, from a directory
holding more than `Options.max_dir_entries` entries, 4096 by default,
and from a batch reaching `Options.max_events`. It is not an error.

It does not say what was lost, because by then the names are gone. Seed
a `Baseline` where the watch is taken and `diff` it when the overflow
arrives: it re-reads the tree and returns the changes the events would
have carried, on the same ownership terms as the slice `poll` returns.

`Kind.unwatched` is the other half and says more: lookout is no longer
watching that path, and nothing under it will be reported until the
caller asks again. It is what a registration the operating system
refused looks like from the outside — a subdirectory that cannot be
read, one the per-user watch limit had no room for, or on Windows a read
that could not be posted again.

`Options.buffer_bytes` is how much change may accumulate between two
polls on the two backends that are handed a buffer and find the changes
in it. On FSEvents it is the buffer the system's delivery thread copies
into, four megabytes by default, which holds a burst of ten thousand
paths. On Windows it is what `ReadDirectoryChangesW` writes into, one
per watch, 64 KiB by default because that is the largest a network share
takes — a larger one asked for on a share is refused outright rather
than clamped, and lookout comes down to 64 KiB by itself when it is. The
memory is held for the life of the watcher, and on Windows it is
non-paged pool while a read is outstanding, so a large one on many
watches costs something real.

**`settle_ms` decides a write is over when the file has been still for a
window, which is an estimate.** `inotify` is told exactly, through
`IN_CLOSE_WRITE`: `Options.report_closes` asks for it and `Kind.closed`
carries it. `reportsCloses(backend)` says whether the backend can
produce one, and four of the five cannot. It is off by default because
turning it on changes what a write looks like — `closed` outranks
`modified` inside a coalescing window. Asking for it where it is not
reported costs nothing; the writes still arrive as `modified`.

**`add` on a missing path is `error.FileNotFound` unless
`AddOptions.pending` is set.** With it the watch is parked on the
nearest existing ancestor, narrowed to the single entry that leads to
the path asked for, and steps down as the path appears; when the path
appears the watch is promoted to the real one — recursion, filter and
all — and reported as `Kind.created`. The id comes back from `add` at
once and does not change. Nothing that happens to the ancestor meanwhile
is reported.

**Two spellings can name one file.** A volume that folds case answers to
`Notes.txt` and `notes.txt` alike, and one that stores a letter
decomposed answers to an accent written as one code point and as two. A
watcher that compares paths byte for byte on such a volume does not
degrade: it drops every event whose spelling differs from the one the
caller used, and says nothing about why.

So on the targets whose file systems fold — Apple platforms and Windows
— every comparison lookout makes between two paths folds too: the watch
root against the path an event names, a pattern against an entry, one
node against the subtree it is removed with, and the key an event is
coalesced under. Case is folded for the ASCII and Latin-1 letters, and
composition for the Latin-1 letters; a path in another script is
compared as written, which is what a volume storing it verbatim does.
`folds_case` says which of the two this target has, and on Linux and the
BSDs it is false and a comparison is a comparison of bytes.

A case-sensitive volume on a target that folds is compared more loosely
than it stores, so two paths differing only in case are taken for one.
That is the same choice the platform's own tools make.

**A tool that runs, exits and runs again has a gap it cannot see into.**
`Watcher.position` closes it where the operating system keeps a log of
what changed: the position is a short piece of text — `Position.token`
writes it, `Position.parse` reads it back — and `Options.since` takes it
back on the next run. What was created, changed and deleted meanwhile is
reported, resolved against the tree as it is now.

lookout persists nothing. The token is the caller's to write down, and
where it goes is the caller's business.

Only FSEvents can answer, because only it is backed by a log the system
keeps per volume rather than by a queue that starts empty.
`tracksPosition` says so; the others return `null` from `position` and
ignore `since` instead of pretending.
[`examples/since.zig`](examples/since.zig) is the round trip.

**`error.WatchLimitReached` is what `add` returns when the operating
system refuses another watch**: `ENOSPC` from `inotify_add_watch`, the
per-user `max_user_watches` cap; `ENOMEM` from `kevent`; a stream
FSEvents will not start; a handle Windows will not take. A file that
merely sits inside a watched directory is dropped instead, since the
directory still reports it appearing and disappearing; only the path the
caller named is an error.

**What each backend costs.**

| Backend | Mechanism | Recursion costs | Renames | Ignored subtree |
|---|---|---|---|---|
| `fsevents` | One stream per watch, delivered on a dispatch queue into a pipe the watcher owns. | one stream, and one remembered path per file | paired | events dropped; the kernel recurses regardless |
| `kqueue` | `EVFILT_VNODE` on a descriptor per watched path, plus a listing comparison to name the entry that changed. | one descriptor per directory **and per file** | removal + creation | never opened, never registered |
| `inotify` | One kernel watch per directory; the kernel names the entry and gives each rename a cookie. | one kernel watch per directory | paired | never opened, never registered |
| `windows` | `ReadDirectoryChangesW` with overlapped reads drained through a completion port. | nothing: recursion is a flag | paired | events dropped; the kernel recurses regardless |
| `poll` | Re-stat and re-list on a timer. | one listing per directory per tick | removal + creation | never opened, never registered |

`Options.max_dir_entries` is one directory's budget on all five: a
recursive watch over twenty directories of three hundred entries is
twenty directories inside a budget of a thousand.

I made FSEvents the default on Apple platforms rather than `kqueue`,
because it recurses without a descriptor per directory and pairs renames.
`kqueue` is still the better answer for a handful of paths watched
without recursion; a process that runs out of descriptors under it still
sees files inside a watched directory appear, disappear and be renamed,
but not be modified.

`Options.backend` selects one explicitly and `supported` says whether
this target has it. Asking for one this target was not built with fails
`init` with `error.BackendUnavailable` rather than failing to compile.

There is no whole-filesystem backend on Linux. `fanotify` can mark a
whole mount instead of a watch per directory, which is the standard
answer to "one kernel watch per directory does not scale", and it needs
`CAP_SYS_ADMIN` — a privilege a library cannot assume a process has.

**A backend is one file and one struct with nine methods**: `init`,
`deinit`, `fd`, `registrationCount`, `add`, `remove`, `wait`, `wake` and
`position`. `Watcher.Impl` finds it structurally, so adding one is:
write the file, add a tag to `Impl` for the right `os.tag`, add the tag
to `Backend`, and add an arm to each of `pairsRenames`,
`reportsRootMove`, `reportsCloses`, `prunesIgnored` and
`tracksPosition`. The compiler forces the last part, because every one
of those is an exhaustive switch with no `else`, and the suite then runs
whole against the new backend with no edit.

What it will not have to write again: `Deadline` for the wait
arithmetic, `Budget` for the entry count, `walk` for a tree somebody
else made, `path` for every comparison between two paths, and `Tree`
for the bookkeeping a backend that recurses itself needs.

## Scope

- **No symbolic link is followed.** A link inside a watched tree is an
  entry, not a doorway into a directory you did not ask for.
- **No watch follows a file that is replaced rather than written.** The
  write-to-temporary-and-rename an editor does is reported once and then
  goes quiet; watch the containing directory to follow a path.
- **No `Watcher` is thread-safe.** Several may exist in one process, and
  `wake` is the one call another thread may make.
- **No path is watched twice by one watcher.** A second `add` is
  `error.PathAlreadyWatched`, and on Linux two overlapping watches share
  one kernel watch where they meet.
- **Nothing is persisted.** `Options.since` takes a token that is the
  caller's to store.
- **No path is compared more strictly than its file system compares
  it**, so on Apple platforms and Windows a case-sensitive volume is
  compared more loosely than it stores.

## Platforms

| Platform | Backends | Tested |
|---|---|---|
| macOS | `fsevents` (default), `kqueue`, `poll` | macOS CI runner |
| Linux | `inotify` (default), `poll` | Ubuntu CI runner |
| FreeBSD, NetBSD | `kqueue` (default), `poll` | cross-compiled, never run |
| Windows | `windows` (default), `poll` | `windows-latest` CI runner |

CI compiles every commit for `x86_64-linux-gnu`, `aarch64-linux-gnu`,
`x86_64-linux-musl`, `x86_64-windows-gnu`, `x86_64-windows-msvc`,
`aarch64-windows-gnu`, `x86_64-freebsd` and `x86_64-netbsd`, test binary
included, so no backend source can break behind an empty archive. The
other Apple platforms and the other BSDs resolve a backend of their own
and are neither built nor run here.

## Testing

```
zig build test          # the suite, once per backend this host has
sh ci/linux.sh          # the suite on Linux, in Docker, all four modes
```

The suite includes three budgets — how long after a change `poll` comes
back, how much of a burst arrives, and how much memory a watched
directory costs. They are several times the measured numbers, because a
hosted runner is a shared machine; what they catch is a regression of an
order of magnitude rather than of a percentage.

Setting `LOOKOUT_TRACE` in the environment makes the Apple backend and
the suite write what they did to standard error. It is read once per
process.

The suite runs whole against each backend the host can execute, so the
polling backend is held to the same assertions as the kernel ones on the
same machine. `pairsRenames`, `reportsRootMove`, `prunesIgnored` and
`reportsCloses` are asserted per backend, so the tables above cannot go
stale quietly.

[`ci/linux.sh`](ci/linux.sh) is how `inotify` is exercised from a machine
that is not Linux; it is a local script and no CI job calls it, the
Ubuntu runner being what covers `inotify` on every push. It builds a
Debian image with the pinned Zig from
[`ci/linux.Dockerfile`](ci/linux.Dockerfile), mounts the working tree
read-only, and runs `zig build test` inside it in all four optimize modes.
Pass mode names to run fewer, or set `LOOKOUT_LINUX_IMAGE` to reuse an
image you have.

## Requirements

Zig 0.16.0. No other dependencies.

## Licence

MIT. See [LICENSE](LICENSE).
