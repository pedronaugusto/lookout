# Lookout benchmarks

Run `./bench/quiet.sh` from the repository on an idle Mac. It builds immutable
library snapshots, then runs the complete FSEvents comparison pass and the
existing speed-check jobs across every supported backend. Harness files and
history live on `bench`; merge current main into this branch before a later
pass. The comparison workloads need macOS/FSEvents.

`./bench/quiet.sh --smoke` runs each job/side once with tiny fixtures. Setup
runs once in each implementation; idle accounting uses one second; backend
speed checks use one round and retain functional assertions while skipping
speed thresholds. Reports retain delivery/rename/setup counts and booleans,
with no timing or CPU-time values. A successful smoke supports no speed claim.

`revisions.json` fixes A at `6af22d4a5bb94956c6fa52fb07f4c40aec4c55db` and B at
`8fac87aa96d5ac91bb8b4f17131d3f71b58b93ca`, the final main. A retains the original
**2026-09-30 00:00:00 +01:00** cutoff. `--before REV --after REV` selects other
immutable snapshots; refresh the pins when main advances.

Jobs are the existing backend checks (blocked-change delivery, rename/delete
delivery, cancellation, wake and stop-by-flag), then single-file latency,
10,000/100,000-file bursts, 1,000 renames, idle and 100-writes/second CPU time and
recursive setup over 50,000 files. The jobs after them time every other public
operation: `backend_setup` (recursive `add`, `refilter` narrowing to half the
directories and back, and `remove` on the FSEvents and poll backends over the
50,000-file tree, plus one polling scan; kqueue's over the 1,000- and 10,000-file
baseline trees, because it checks each added file against every node of the tree
and one add of 50,000 files took three and a half minutes, on both pins), `poll_cpu` (CPU over a two-second
window of a 100 ms poll watcher on that tree), `checkpoint` (checkpoint and token,
parse, and the time a resume takes to report 100 files removed while nothing
watched; `Position` on the before pin; removals it missed are a visible count, as
burst losses are, because lookout drops one fseventsd delivers more than a second
after the replay's sentinel), `filter` (`Filter.excludes` over the tree's 50,100
paths), `path` (`path.relative` and `path.within` over those paths and as many in
a sibling) and `baseline` (`Baseline.seed`, a diff with nothing changed and a diff
after one file in a hundred is changed, removed and created beside, over 1,000,
10,000 and 50,000 files). Pure value queries (`supported`, `pairsRenames`,
`reportsRootMove`, `reportsCloses`, `prunesIgnored`, `tracksCheckpoint`,
`default_backend`, `folds_case`) and counters (`stats`, `watches`, `fd`, `backend`)
are not timed. `Snapshot` is internal: the poll scan and the baseline diffs are
its comparisons. The backend checks run first: the burst
cleanups remove up to 100,000 files, and FSEvents delivers those removals to every
later stream. `--jobs tree_setup,backend-speed-checks` times only the named jobs,
after a smoke. Backend tests emit measurements in full mode and retain
their speed ceilings; every backend is measured before a test fails. A check over
its ceiling is kept as a failed row with its value and budget, the pass runs to the
end, writes its results and exits non-zero. Any other failure stops the pass and
leaves a failed report with the samples collected so far.

The existing same-job tools remain Rust notify 8.2.0, notify-debouncer-full
0.6.0 and Go fsnotify v1.9.0, pinned in their manifests and lockfiles. The debouncer uses a 10 ms window and a 2 ms tick. Event
coalescing and rename pairing differ: delivered counts, files missed, pairing,
unmatched renames and overflow stay visible next to time/CPU data. Writes/renames are checked on disk outside the measured region so a failed
writer cannot look like watcher loss. A burst ends after two quiet seconds once every
file has arrived or an overflow was reported, and waits up to thirty quiet seconds
while files are still missing: with two, FSEvents' lag after a large burst ended
each side on a different subset (about 5% of 10,000), so the sides' last events
were different events. Setup must succeed in smoke. Missing burst/rename observations remain visible rather than
being silently treated as equivalent behavior. Parcel remains unavailable.

The later jobs compare each operation with the tool a reader would otherwise
use, where one has it: notify 8.2.0's FSEvents, poll and kqueue watchers (kqueue
is a build feature that replaces FSEvents, so it builds alone in
`src/rust-kqueue`) and fsnotify (kqueue on macOS) for add and remove; notify's
`PollWatcher` for polling CPU; globset 0.4.20 and doublestar v4.10.2 for the
filter, given lookout's patterns in their spelling; Rust `Path::strip_prefix` and
Go `filepath.Rel` for the path helpers; watchdog 6.0.0's `DirectorySnapshot` and
`DirectorySnapshotDiff` for the baseline. Every side of the filter, path and
baseline jobs must report the same counts, or the pass stops. lookout folds case
and composition on macOS and the Rust and Go path functions compare bytes; the
inputs are lower-case ASCII, so the answers agree and the work differs. No other
tool resumes from a position (notify starts its streams at now; kqueue, polling
and watchdog keep no history; watchman's clocks need its resident daemon) or
changes a watch's filter, and those rows name why in `unavailable`. Installed
toolchains are recorded.

Reports are plain `results.md` and `results.json` under
`bench/results/<UTC-date>/<UTC-start>/`; smoke uses `smoke.md` and `smoke.json`.
They include revision hashes, harness hash, machine/power information, tool
versions, execution order, samples and status. Results and owned scratch/cache
files are ignored. Prepared scratch and compiler caches persist; tool caches remain
under `bench/build/quiet-cache`. Smoke builds both snapshot and backend test artifacts; the full pass reuses them.

Quiet-only planning estimate: **20–45 minutes** after successful smoke preparation. See [QUIET-PREP.md](QUIET-PREP.md) for invocation counts, sizes and assumptions. This is a planning estimate, not a measurement from this preparation. Have at
least 4 GiB free for scratch and caches. `ZIG`, `GO`, `CARGO`, `PYTHON` and standard
tool cache environment variables select installed tools/caches. The specialized
`run.sh` remains; `quiet.sh` is the complete pass entry point.

Standalone `zig build -Doptimize=Debug` compiles the pinned after harness
without running it. Snapshot builds pass `-Dsnapshot=true` to compile the
archived local revision instead; quiet runs retain ReleaseFast.
