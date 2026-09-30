# lookout benchmarks

Compares watcher latency, bursts, renames, idle CPU and recursive setup with
Rust notify/notify-debouncer-full and Go fsnotify. Delivery counts, missed
files, rename pairing and overflow remain visible. Parcel is unimplemented
and reported unavailable.

From `bench/`, run `./run.sh` on a quiet machine. `BENCH_MODE=smoke ./run.sh`
uses one event/file and one pass; idle accounting lasts one second. Full
mode uses larger deterministic inputs and three/five passes. The package is
this repository at `..`.

notify 8.2.0/notify-debouncer-full 0.6.0 are exact in `src/rust/Cargo.toml`,
with transitive pins in `Cargo.lock`. fsnotify v1.9.0 is pinned in
`src/go/go.mod`/`go.sum`. Standard libraries use installed tools; Zig's
minimum is in `build.zig.zon`. Record toolchain versions with full results.
`BENCH_BUILD_DIR`/`BENCH_RESULTS` select generated outputs, defaulting to
`build/`; `ZIG`, `GO`, `CARGO`, `PYTHON` select tools. Generated files are ignored.
