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

By default A is the last first-parent main commit before **2026-09-30 00:00:00
+0100**, and B is current local main. The explicit time and offset enforce the
midnight boundary (Git's date-only `--before=2026-09-30` can inherit the current
time of day). `--before REV --after REV` selects other immutable snapshots.
Each job runs A, B, then its existing same-job tools, repeating that order.
Full mode retains three passes for latency/burst/idle and five for rename/setup;
`BENCH_RUNS` overrides these. Each watcher invocation warms itself up with an
observed event. Inputs are shared, mutable watch roots are separate and reset
for every invocation. All samples remain visible; summaries use medians.
Lookout's workload APIs required no adaptation. The final API's changed stream
start/cursor behavior is exercised by those same calls.

Jobs are single-file latency, 10,000/100,000-file bursts, 1,000 renames, idle and
100-writes/second CPU time, recursive setup over 50,000 files, and existing
backend checks: blocked-change delivery, rename/delete delivery, cancellation,
wake and stop-by-flag. Backend tests emit measurements in full mode and retain
their speed ceilings; failure leaves a failed report with collected samples.

The existing same-job tools remain Rust notify 8.2.0, notify-debouncer-full
0.6.0 and Go fsnotify v1.9.0, pinned in their manifests and lockfiles. The debouncer uses a 10 ms window and a 2 ms tick. Event
coalescing and rename pairing differ: delivered counts, files missed, pairing,
unmatched renames and overflow stay visible next to time/CPU data. Setup must
succeed in smoke. Missing burst/rename observations remain visible rather than
being silently treated as equivalent behavior. Parcel remains unavailable;
no new comparison tool is added. Installed toolchains are recorded.

Reports are plain `results.md` and `results.json` under
`bench/results/<UTC-date>/<UTC-start>/`; smoke uses `smoke.md` and `smoke.json`.
They include revision hashes, harness hash, machine/power information, tool
versions, execution order, samples and status. Results and owned scratch/cache
files are ignored. Scratch is removed on success or failure; tool caches remain
under `bench/build/quiet-cache`. Each pass builds fresh binaries, including both
backend test artifacts, without requiring speed build steps in either snapshot.

Allow roughly **15–25 minutes** for the default full pass on an Apple Silicon
Mac with cached dependencies, plus first-time downloads/builds. The 500-event
latency jobs include fixed 50 ms gaps and watcher delivery/coalescing waits.
This is a planning estimate, not a measurement from this preparation. Have at
least 3 GiB free for scratch and caches. `ZIG`, `GO`, `CARGO`, `PYTHON` and standard
tool cache environment variables select installed tools/caches. The specialized
`run.sh` remains; `quiet.sh` is the complete pass entry point.
