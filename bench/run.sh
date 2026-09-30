#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
build="${BENCH_BUILD_DIR:-$ROOT/build}"
mkdir -p "$build"
build="$(cd "$build" && pwd)"
export BENCH_BUILD_DIR="$build"
results="${BENCH_RESULTS:-$build/results.tsv}"
MODE=${BENCH_MODE:-full}
case "$MODE" in
    full|smoke) ;;
    *) echo "BENCH_MODE must be full or smoke" >&2; exit 2 ;;
esac

mkdir -p "$build/bin" "$build/cargo-home" "$build/cargo-target" \
    "$build/gocache" "$build/gomodcache" "$build/gopath" "$build/zig-cache" \
    "$build/zig-global-cache" "$build/work"
"${PYTHON:-python3}" "$ROOT/src/generate_inputs.py" --mode "$MODE"

env ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$build/zig-global-cache}" \
    "${ZIG:-zig}" build -j1 --build-file "$ROOT/build.zig" -Doptimize=ReleaseFast \
    --prefix "$build/zig-out" --cache-dir "$build/zig-cache" \
    --global-cache-dir "$build/zig-global-cache"

env CARGO_HOME="${CARGO_HOME:-$build/cargo-home}" CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$build/cargo-target}" \
    "${CARGO:-cargo}" build -j1 --manifest-path "$ROOT/src/rust/Cargo.toml" --release --locked

(cd "$ROOT/src/go" && \
    env GOPATH="${GOPATH:-$build/gopath}" GOCACHE="${GOCACHE:-$build/gocache}" GOMODCACHE="${GOMODCACHE:-$build/gomodcache}" \
    "${GO:-go}" build -p=1 -mod=readonly -trimpath -ldflags="-s -w" -o "$build/bin/fsnotify-bench" .)

rm -rf "$build/raw"
mkdir -p "$build/raw"

if [ "$MODE" = smoke ]; then
    SHORT_REPS=1
    LONG_REPS=1
else
    SHORT_REPS=5
    LONG_REPS=3
fi

run_point() {
    side=$1
    program=$2
    workload=$3
    repetitions=$4
    rep=1
    while [ "$rep" -le "$repetitions" ]; do
        if [ "$workload" = tree_setup ]; then
            watch_root="$build/inputs/setup_tree"
        else
            watch_root="$build/work/${side}-${workload}"
            "${PYTHON:-python3}" "$ROOT/src/prepare_run.py" "$watch_root" "$workload"
        fi
        "$program" "$workload" "$build/inputs" "$watch_root" \
            > "$build/raw/${side}-${workload}-${rep}.tsv"
        if [ "$workload" != tree_setup ]; then
            "${PYTHON:-python3}" "$ROOT/src/prepare_run.py" "$watch_root" "$workload" --remove
        fi
        rep=$((rep + 1))
    done
}

run_side() {
    side=$1
    program=$2
    run_point "$side" "$program" latency "$LONG_REPS"
    run_point "$side" "$program" burst "$LONG_REPS"
    run_point "$side" "$program" rename "$SHORT_REPS"
    run_point "$side" "$program" idle "$LONG_REPS"
    run_point "$side" "$program" tree_setup "$SHORT_REPS"
}

run_side lookout "$build/zig-out/bin/lookout-bench"
run_side notify "${CARGO_TARGET_DIR:-$build/cargo-target}/release/notify-raw-bench"
run_side notify_debouncer_full "${CARGO_TARGET_DIR:-$build/cargo-target}/release/notify-debounced-bench"
run_side fsnotify "$build/bin/fsnotify-bench"

SMOKE_FLAG=
if [ "$MODE" = smoke ]; then SMOKE_FLAG=--smoke; fi
"${PYTHON:-python3}" "$ROOT/src/summarize.py" --raw "$build/raw" \
    --output "$results" --inputs "$build/inputs" \
    --parcel-na $SMOKE_FLAG
