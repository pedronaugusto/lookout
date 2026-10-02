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
`b9249a0e345acf268ad23c902f9458b446f3cb4a`. A retains the original
**2026-09-30 00:00:00 +01:00** cutoff. `--before REV --after REV` selects other
immutable snapshots; refresh the pins when main advances.

Jobs are single-file latency, 10,000/100,000-file bursts, 1,000 renames, idle and
100-writes/second CPU time, recursive setup over 50,000 files, and existing
backend checks: blocked-change delivery, rename/delete delivery, cancellation,
wake and stop-by-flag. Backend tests emit measurements in full mode and retain
their speed ceilings; failure leaves a failed report with collected samples.

The existing same-job tools remain Rust notify 8.2.0, notify-debouncer-full
0.6.0 and Go fsnotify v1.9.0, pinned in their manifests and lockfiles. The debouncer uses a 10 ms window and a 2 ms tick. Event
coalescing and rename pairing differ: delivered counts, files missed, pairing,
unmatched renames and overflow stay visible next to time/CPU data. Writes/renames are checked on disk outside the measured region so a failed
writer cannot look like watcher loss. Setup must succeed in smoke. Missing burst/rename observations remain visible rather than
being silently treated as equivalent behavior. Parcel remains unavailable;
no new comparison tool is added. Installed toolchains are recorded.

Reports are plain `results.md` and `results.json` under
`bench/results/<UTC-date>/<UTC-start>/`; smoke uses `smoke.md` and `smoke.json`.
They include revision hashes, harness hash, machine/power information, tool
versions, execution order, samples and status. Results and owned scratch/cache
files are ignored. Prepared scratch and compiler caches persist; tool caches remain
under `bench/build/quiet-cache`. Smoke builds both snapshot and backend test artifacts; the full pass reuses them.

Quiet-only planning estimate: **15–25 minutes** after successful smoke preparation. See [QUIET-PREP.md](QUIET-PREP.md) for invocation counts, sizes and assumptions. This is a planning estimate, not a measurement from this preparation. Have at
least 3 GiB free for scratch and caches. `ZIG`, `GO`, `CARGO`, `PYTHON` and standard
tool cache environment variables select installed tools/caches. The specialized
`run.sh` remains; `quiet.sh` is the complete pass entry point.

Standalone `zig build -Doptimize=Debug` compiles the pinned after harness
without running it. Snapshot builds pass `-Dsnapshot=true` to compile the
archived local revision instead; quiet runs retain ReleaseFast.
