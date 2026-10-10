# lookout

lookout watches files and directory trees in Zig. One `Watcher` coalesces changes over
native notification backends or polling, with explicit overflow events and backend
capability queries.

Work in progress toward the public cut. Filesystem policy is measured per root
and directory where supported; sweep parses and composes normalized filters.

## Install

Requires Zig 0.17.0. Fetch with `zig fetch --save
git+https://github.com/pedronaugusto/lookout`, then obtain the `lookout` module through
`b.dependency` and add it to your executable's imports. Forward your target and optimize
settings.

## Usage

[examples/usage.zig](examples/usage.zig) watches an absolute `dir_path`, writes
through an open scratch directory with the supplied `std.Io`, and prints to a
buffered standard output writer, `output`.

<!-- BEGIN GENERATED zig build docs -- usage -->
```zig
const lookout = @import("lookout");

var watcher: lookout.Watcher = try .init(gpa, io, .{});
defer watcher.deinit(io);

const id = try watcher.add(io, dir_path, .{ .recursive = true });
defer watcher.remove(io, id);

try scratch.writeFile(io, .{ .sub_path = "notes.txt", .data = "hello" });

const one_second: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } };
for (try watcher.poll(io, one_second)) |event| {
    try output.print("{s} {s}\n", .{ @tagName(event.kind), event.path });
}
```
<!-- END GENERATED -->

## Design

[docs/design.md](docs/design.md) gives the layers, who owns which state, what
always holds, and the reasons behind the decisions. What follows is what a user
of the API needs to know.

The watcher module uses Zig's standard library and three packages of the same family,
[aegis](https://github.com/pedronaugusto/aegis) for typed ids, byte counts, limits and
the lock beside the data the system's delivery thread shares,
[airlock](https://github.com/pedronaugusto/airlock) for the baseline file and
[sweep](https://github.com/pedronaugusto/sweep) for filter patterns. A watcher keeps
the allocator it is made with for watches, paths and event storage, and keeps no
`std.Io`: `add`, `remove`, `refilter`, `poll` and `deinit` each take the `io` they go
through. A returned event slice and its paths belong to the watcher until the next poll or
`deinit`. Baselines keep their allocator the same way and take `io` per call;
baselines and checkpoints retain their storage and must be released. A checkpoint
can outlive its watcher; the watcher allocator must remain valid until every shared
checkpoint is released.

`add` accepts file or directory watches, optional recursion and filters. Pending watches
wait at an existing ancestor for a missing path to appear. Filters select paths by
pattern or predicate, and `refilter` changes the selection. Patterns are git's, as
in a `.gitignore` line: `*`, `?` and brackets within a component, `**` as a whole
component across components, `\` escapes (a separator on Windows), and a pattern
with no separator matching a name at any depth. A pattern git refuses is
`InvalidPattern`. Each path is matched against all of a watch's patterns in one
pass over it, compared as the file system compares names. Excluded directories are
pruned where the backend supports it; other backends discard their events.

Every change within a watch's scope and filters made after `add` returns is reported, subject to coalescing.

Recursive watches do not follow symbolic links unless `follow_symlinks` is set. With it,
a link to a directory is watched as if the directory were there, wherever it leads,
including outside the root, and changes below it are reported under the link's path
with the watch's id and filter. A link into a directory the watch already reaches, or
into one holding such a directory, is not followed; this is decided by device and inode,
or volume and file id on Windows, not by path. Each followed link is a registration of its
own, and `add` walks the tree once more to find the links. A link changed to lead
elsewhere is reported on its own path and the watch moves to the new directory; a
dangling link is an entry until it changes. A watch follows at most `max_followed_links`
links and reports a link past that as `unwatched`. Such a watch produces no checkpoint.

`Watcher.Options` holds the watcher's settings and `Watcher.AddOptions` a watch's.
Their spans are `std.Io.Duration`s, kept to the millisecond and rounded up.
`latency` combines events collected together. `settle` waits for modified file
contents to stop changing. `debounce` holds ordinary changes until the path is quiet
and reports the last kind; it takes precedence over the other windows. Overflow and
unwatched notices bypass these waits. A seeded `Baseline` can diff the current tree
after an overflow. A baseline does not follow symbolic links, so for a watch with
`follow_symlinks` it answers for the tree itself and not for what lies below its links.
`save(io, filename, .{})` atomically replaces a versioned, SHA-256 checksummed file;
`Baseline.load(gpa, io, filename, root, options)` restores it on every backend, and
`diff(io)` answers what changed since the last run with one walk.
Keep the file outside the watched tree. Corrupt files return `InvalidBaseline`,
old versions `UnsupportedBaselineVersion`, and mismatched platform, root, scope,
budget or patterns `ForeignBaseline`. Predicate filters return
`UnsupportedBaselineFilter`: executable predicates cannot be stored. `save` writes
through [airlock](https://github.com/pedronaugusto/airlock): a temporary file next to
the destination, renamed over it, so readers see the old file or the new one. It does
not sync by default. `save(io, filename, .{ .durable = true })` also makes the new file
survive a power cut on every platform: the temporary file is synced before the rename
and the directory after it, one barrier and one flush on macOS and two flushes on Linux
and Windows. A failed sync before the rename leaves the old file; a failed directory
sync after it is `PublishedNotDurable`, with the new file in place; a filesystem that
refuses the syncs is `LevelUnavailable`. A crash during a save can leave a temporary
file named after `Baseline.temp_prefix`, which `airlock.pruneTemps` removes. Neither in-memory nor persisted baselines
recover transient changes absent from both snapshots.
Each change carries its `target`, file or directory, from the listing that saw it, so a
removed directory is known for one without a `stat`.

`poll` takes a `std.Io.Timeout` and is a `std.Io` cancellation point. Cancellation preserves
gathered events for a later poll. Every backend waits through reactor, so a cancellation
ends a blocked `poll` on every backend but Windows, where the completion port is waited on
by a call nothing can interrupt and the cancellation lands when it comes back. Under a
reactor runtime the wait holds no thread; under any other `std.Io` the calling thread
waits and looks for a cancellation every few milliseconds. `wake` ends a blocked wait from
another thread on every backend. `fd` returns a pollable descriptor where the backend
provides one.

FSEvents checkpoints retain per-watch volume and log identity, durable cursors and
pending changes and the path baseline the watch knew. Capture retains a shared
path revision without walking or copying the tree; token writing flattens it
to a self-contained baseline. Paths removed since a retained revision are reclaimed
when that revision is released. On resume a path in that
baseline that is gone is reported as a deletion once, independent of event ids
and replay arrival time. The replay has no time window or id-space barrier;
Version-1/2 checkpoint tokens are refused. Resume with matching canonical roots, scopes and filters: a
token records its ignore and include patterns and is refused under others, while a predicate
filter cannot be recorded and is the caller's to keep the same. Saved changes a resumed watch
would not report live are dropped. A changed
volume or log yields `InvalidCheckpoint`; watches spanning mounted volumes keep live
coverage but cannot produce a checkpoint. Other backends return null.
[examples/since.zig](examples/since.zig) exercises checkpoint tokens and resuming.

Filesystem name capabilities and caller policy are separate: `Watcher.capabilities(id)`
reports `names` (nullable facts) and `policy` (effective matching policy).
`directoryCapabilities(io, id, directory)` probes a canonical directory below a watch.
Unknown capability selects exact spelling and sensitive matching; `AddOptions.identity`
can override the policy without changing the reported facts. Darwin measures volume
case sensitivity, Windows measures directory case flags, and Linux measures supported
filesystem/directory flags. Normalization remains unknown where no supported query
establishes it; lookout makes no platform guess about Unicode equivalence.

`Filter.case` and `Filter.normalization` are independent matching preferences.
Set normalization to `.nfc` for canonical equivalence: `[é]` matches `é` and `e` plus
combining acute, and never plain `e`; `?` consumes one composed scalar. Sweep owns
composition, classes, ranges, escapes and folding; lookout passes original glob text.
A class member that remains several scalars under NFC is `InvalidPattern`.
Kernel event names and canonical roots are retained unchanged; `WatchInfo.requested`
retains the original caller root independently. Public `path` helpers take canonical
kernel paths and compare exact bytes. Baseline format 2 and checkpoint format 3
retain matching preferences and refuse older formats.

## API

| API | Result |
| --- | --- |
| `Baseline.seed`, `diff`, `deinit` | Own, compare and release a tree snapshot. |
| `Baseline.save`, `load` | Atomically persist, durably on request, and restore a checked snapshot for any backend. |
| `Watcher.checkpoint`, `Checkpoint.token`, `parse`, `deinit` | Own, persist and resume FSEvents log cursors and known path baselines. |
| `Watcher.capabilities(id)` | The backend and filesystem fact for one watch; null for an unknown id. |

## Scope

- It does not guarantee delivery of every intermediate write or rename.
- It does not turn overflow recovery into a complete history of transient changes.
- It does not follow symbolic links during recursive tree walks unless `follow_symlinks` asks for it, and never into a directory the watch already reaches: loops and overlapping paths would produce duplicate reports.
- It does not read ignore files: a pattern is one line of gitignore syntax, and negation (`!`), directory-only rules (a trailing `/`), files and their precedence are a predicate's, backed by the repository's own matcher.
- It does not recover transient history on backends without a persistent log.
- It does not supply an application event loop or rebuild policy.

<!-- performance: quiet pass -->

## Platforms

The automatic backend is FSEvents on Apple targets, kqueue on supported BSD targets,
inotify on Linux, ReadDirectoryChangesW on Windows and polling elsewhere.
For each `.auto` watch, network and FUSE filesystems select polling instead; local
watches in the same watcher retain their native backend. Explicit backend choices
are kept. `Watcher.capabilities(id)` reports the selected backend and filesystem
fact (`local`, `network`, `fuse`, or `unknown`), measured with statfs/statvfs on POSIX
and drive type plus the remote-device flag on Windows. Failed or unavailable type
queries report `unknown` and keep the default backend. Pending watches recheck when
they move to another ancestor or their root. `backend()` reports the watcher's
primary backend; use the per-watch result for backend capability queries. A watcher
with polling registrations returns null from `fd` and `checkpoint`; drive it with
`poll` and persist a Baseline for those roots. Detection describes the root mount,
so watch nested mounted volumes separately. `supported`
lets a caller check availability before choosing a backend. `pairsRenames`,
`reportsRootMove`, `reportsCloses`, `prunesIgnored` and `tracksCheckpoint` describe
differences that affect event handling.

| Backend | Snapshot comparison |
| --- | --- |
| Polling | Entries whose mtime or ctime is not strictly older than their snapshot in a conservative two-second tick are checked by content until they age; hashes cover files up to 1 MiB, and larger or unreadable racy entries report modification. |

Apple targets link libc and CoreServices for FSEvents and need a macOS SDK. A
native macOS build finds the host's SDK by itself. A named Apple target links
against the SDK given with `-Dmacos-sdk=$(xcrun --show-sdk-path)` or, without one,
a pinned SDK package; `-Dbundled-macos-sdk=true` selects the pinned SDK for a
native build too.

## Built with

- [Zig](https://ziglang.org) 0.17.0 and its standard library. On Apple targets the
  module links libc and CoreServices; nothing else is linked anywhere.
- [aegis](https://github.com/pedronaugusto/aegis) supplies the watch and revision
  ids, the byte count of `Options.buffer_bytes`, the limits and the guarded state
  shared with the system's delivery thread.
- [airlock](https://github.com/pedronaugusto/airlock) writes the baseline file
  atomically and, on request, durably.
- [reactor](https://github.com/pedronaugusto/reactor) waits for a backend's
  descriptor and for `wake`, over any `std.Io`, and on Windows runs the wait on
  the completion port off the runtime's workers.
- [sweep](https://github.com/pedronaugusto/sweep) compiles and matches filter
  patterns.
- [preflight](https://github.com/pedronaugusto/preflight) runs the source checks,
  the tests and CI.
- [shakedown](https://github.com/pedronaugusto/shakedown) is the clock, fault
  injection and counting allocator the tests run on, and under airlock's test
  seam, `airlock.testing`, which counts and fails a durable save's syncs;
  fetched only for the tests.
- A pinned macOS SDK package, fetched only to link a named Apple target without
  an SDK of its own.

## Testing

`zig build test` runs the suite and examples in Debug by default, exercising the
backends available on the host. Tests cover filters, pending paths, renames,
overflow, cancellation, settling, checkpoints and resource cleanup. `zig build
examples` runs the examples separately. `zig build bench` holds lookout's own speed
claims to their ceilings in ReleaseFast; run it on a quiet machine. `zig build test`
runs each once with `--smoke`, judging nothing. CI also runs
`zig build lint`, which includes `zig build check-consumer`: a project that depends
on lookout by path, built with only aegis, airlock, reactor and sweep fetched.

[CI](.github/workflows/ci.yml) has three tiers. The fast tier runs the source
checks and the Linux Debug suite with the examples and each benchmark once, and
compiles the tests for macOS, Windows and every configured target without running
them. The merge tier adds the Debug suite on `macos-latest` and `windows-latest`.
The release tier runs the tests and examples in Debug and ReleaseSafe on all three
hosts, plus ReleaseFast on Ubuntu; it compiles ReleaseSmall without running it, and
runs ThreadSanitizer in Debug on Ubuntu.

The default `zig build` compiles the backend-bearing tests and library. CI uses it for
`x86_64-linux-gnu`, `aarch64-linux-gnu`, `x86_64-linux-musl`, `x86_64-windows-gnu`,
`x86_64-windows-msvc`, `aarch64-windows-gnu`, `x86_64-freebsd` and `x86_64-netbsd`.
These jobs do not execute the targets or compile the examples. Apple targets are built
and run by the native macOS jobs.

## Licence

MIT. See [LICENSE](LICENSE).
