# lookout

lookout watches files and directory trees in Zig. One `Watcher` coalesces changes over
native notification backends or polling, with explicit overflow events and backend
capability queries.

## Install

Requires Zig 0.16.0. Fetch with `zig fetch --save
git+https://github.com/pedronaugusto/lookout`, then obtain the `lookout` module through
`b.dependency` and add it to your executable's imports. Forward your target and optimize
settings.

## Usage

[examples/usage.zig](examples/usage.zig) watches an absolute `dir_path` and writes
through an open scratch directory with the supplied `std.Io`.

<!-- BEGIN GENERATED ci/readme_usage.sh -->
```zig
const lookout = @import("lookout");

var watcher: lookout.Watcher = try .init(gpa, io, .{});
defer watcher.deinit();

const id = try watcher.add(dir_path, .{ .recursive = true });
defer watcher.remove(id);

try scratch.writeFile(io, .{ .sub_path = "notes.txt", .data = "hello" });

for (try watcher.poll(1_000)) |event| {
    std.debug.print("{s} {s}\n", .{ @tagName(event.kind), event.path });
}
```
<!-- END GENERATED -->

## Design

lookout has no package dependencies. Apple targets link libc and CoreServices for
FSEvents and need a macOS SDK; the build locates the host SDK or uses the supplied
sysroot. A watcher uses the caller's allocator for watches, paths and event storage. A
returned event slice and its paths belong to the watcher until the next poll or
`deinit`. Baselines and checkpoints own separate storage and must be released.

The automatic backend is FSEvents on Apple targets, kqueue on supported BSD targets,
inotify on Linux, ReadDirectoryChangesW on Windows and polling elsewhere. `supported`
lets a caller check availability before choosing a backend. `pairsRenames`,
`reportsRootMove`, `reportsCloses`, `prunesIgnored` and `tracksCheckpoint` describe
differences that affect event handling.

| Backend | Snapshot comparison |
| --- | --- |
| Polling | Entries whose mtime or ctime is not strictly older than their snapshot in a conservative two-second tick are checked by content until they age; hashes cover files up to 1 MiB, and larger or unreadable racy entries report modification. |

`add` accepts file or directory watches, optional recursion and filters. Pending watches
wait at an existing ancestor for a missing path to appear. Filters select paths by
pattern or predicate, and `refilter` changes the selection. Excluded directories are
pruned where the backend supports it; other backends discard their events.

Every change within a watch's scope and filters made after `add` returns is reported, subject to coalescing.

`latency_ms` combines events collected together. `settle_ms` waits for modified file
contents to stop changing. `debounce_ms` holds ordinary changes until the path is quiet
and reports the last kind; it takes precedence over the other windows. Overflow and
unwatched notices bypass these waits. A seeded `Baseline` can diff the current tree
after an overflow. `save(gpa, filename)` atomically replaces a versioned, SHA-256
checksummed file; `Baseline.load(gpa, io, filename, root, options)` restores it on
every backend, and `diff` answers what changed since the last run with one walk.
Keep the file outside the watched tree. Corrupt files return `InvalidBaseline`,
old versions `UnsupportedBaselineVersion`, and mismatched platform, root, scope,
budget or patterns `ForeignBaseline`. Predicate filters return
`UnsupportedBaselineFilter`: executable predicates cannot be stored. Replacement
does not fsync; it promises atomic visibility, not power-loss durability. Neither
in-memory nor persisted baselines recover transient changes absent from both snapshots.
Each change carries its `target`, file or directory, from the listing that saw it, so a
removed directory is known for one without a `stat`.

`poll` accepts a timeout and is a `std.Io` cancellation point. Cancellation preserves
gathered events for a later poll. Native waits observe cancellation when they wake; use
`wake` to end a blocked wait on any backend. `fd` returns a pollable descriptor where
the backend provides one.

FSEvents checkpoints retain per-watch volume and log identity, durable cursors and
pending changes. Resume with matching canonical roots, scopes and filters. A changed
volume or log yields `InvalidCheckpoint`; watches spanning mounted volumes keep live
coverage but cannot produce a checkpoint. Other backends return null.
[examples/since.zig](examples/since.zig) exercises checkpoint tokens and resuming.

## API

| API | Result |
| --- | --- |
| `Baseline.seed`, `diff`, `deinit` | Own, compare and release a tree snapshot. |
| `Baseline.save`, `load` | Atomically persist and restore a checked snapshot for any backend. |

## Scope

- It does not guarantee delivery of every intermediate write or rename.
- It does not turn overflow recovery into a complete history of transient changes.
- It does not follow symbolic links during recursive tree walks: loops and overlapping paths would produce duplicate reports.
- It does not read gitignore syntax: use a predicate with the repository matcher, which owns anchoring, negation and directory rules.
- It does not recover transient history on backends without a persistent log.
- It does not supply an application event loop or rebuild policy.

<!-- performance: quiet pass -->

## Testing

Local build scripts clear `.zig-cache/{o,h,z,tmp}` above the measured cap in `ci/cache.sh`; run `sh ci/cache.sh` before direct Zig builds (only a rebuild is lost).

`zig build test` runs the suite and examples in Debug by default, exercising the
backends available on the host. Tests cover filters, pending paths, renames, overflow,
cancellation, settling, checkpoints and resource cleanup. `zig build examples` runs the
examples separately. CI also runs `ci/check-docs.sh`.

[CI](.github/workflows/ci.yml) runs tests and examples in Debug and ReleaseSafe on
`ubuntu-latest`, `macos-latest` and `windows-latest`, plus ReleaseFast on Ubuntu.
ReleaseSmall compiles the tests and library without running them on Ubuntu. Separate
Ubuntu jobs run ThreadSanitizer in Debug and check formatting and cast reasons.

The default `zig build` compiles the backend-bearing tests and library. CI uses it for
`x86_64-linux-gnu`, `aarch64-linux-gnu`, `x86_64-linux-musl`, `x86_64-windows-gnu`,
`x86_64-windows-msvc`, `aarch64-windows-gnu`, `x86_64-freebsd` and `x86_64-netbsd`.
These jobs do not execute the targets or compile the examples. Apple targets are built
and run by the native macOS jobs.

## Licence

MIT. See [LICENSE](LICENSE).
