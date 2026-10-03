#!/usr/bin/env python3
"""watchdog's DirectorySnapshot and DirectorySnapshotDiff: the baseline
workload, with lookout's tree sizes, changes and restores."""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

from watchdog.utils.dirsnapshot import DirectorySnapshot, DirectorySnapshotDiff

SMOKE = os.environ.get("BENCH_SMOKE") == "1"


def clock() -> int:
    return 0 if SMOKE else time.perf_counter_ns()


def micros(started: int) -> int:
    return 1 if SMOKE else (time.perf_counter_ns() - started) // 1000


def median_of(once) -> int:
    """Runs `once` until 200 ms of it have been measured (once in smoke) and
    returns the median sample in microseconds."""
    samples: list[int] = []
    while not samples or (not SMOKE and sum(samples) < 200_000):
        samples.append(once())
    samples.sort()
    return samples[(len(samples) - 1) // 2]


def mutate(root: Path, size: dict, every: int, undo: bool) -> None:
    """lookout_bench.zig's mutateTree: per directory, every `every`th file
    rewritten with a different size, the next one removed, and a new name
    created beside the one after."""
    per_dir, extra = divmod(size["files"], size["dirs"])
    for d in range(size["dirs"]):
        for i in range(per_dir + (1 if d < extra else 0)):
            step = i % every
            if step == 0:
                (root / f"d{d:04d}/f{i:06d}.txt").write_bytes(b"x" if undo else b"yy")
            elif step == 1:
                path = root / f"d{d:04d}/f{i:06d}.txt"
                path.write_bytes(b"x") if undo else path.unlink()
            elif step == 2:
                path = root / f"d{d:04d}/n{i:06d}.txt"
                path.unlink() if undo else path.write_bytes(b"x")


def counts(diff: DirectorySnapshotDiff) -> dict[str, int]:
    name = lambda path: os.path.basename(path)[0]
    created = sum(name(p) == "n" for p in diff.files_created)
    modified = sum(name(p) == "f" for p in diff.files_modified)
    removed = sum(name(p) == "f" for p in diff.files_deleted)
    total = sum(len(getattr(diff, kind)) for kind in (
        "files_created", "files_deleted", "files_modified", "files_moved",
        "dirs_created", "dirs_deleted", "dirs_modified", "dirs_moved"))
    return {"created": created, "modified": modified, "removed": removed,
            "other_changes": total - created - modified - removed}


def metric(workload: str, name: str, value: int, unit: str) -> None:
    print(f"watchdog\t{workload}\t{name}\t{value}\t{unit}")


def main() -> None:
    workload, inputs, root = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3])
    if workload != "baseline":
        raise SystemExit(f"unknown workload {workload}")
    cfg = json.loads((inputs / "config.json").read_text(encoding="utf-8"))
    every = cfg["baseline_change_every"]
    for size in cfg["baseline_sizes"]:
        tree = root / size["name"]
        path = str(tree)

        def seed() -> int:
            started = clock()
            DirectorySnapshot(path, recursive=True)
            return micros(started)

        seed_us = median_of(seed)
        held = {"ref": DirectorySnapshot(path, recursive=True)}

        def unchanged() -> int:
            started = clock()
            now = DirectorySnapshot(path, recursive=True)
            diff = DirectorySnapshotDiff(held["ref"], now)
            us = micros(started)
            if any(counts(diff).values()):
                raise SystemExit("unchanged tree differed")
            held["ref"] = now
            return us

        unchanged_us = median_of(unchanged)
        found: dict[str, int] = {}

        def changed() -> int:
            mutate(tree, size, every, False)
            started = clock()
            now = DirectorySnapshot(path, recursive=True)
            diff = DirectorySnapshotDiff(held["ref"], now)
            us = micros(started)
            found.update(counts(diff))
            mutate(tree, size, every, True)
            held["ref"] = DirectorySnapshot(path, recursive=True)
            return us

        changed_us = median_of(changed)
        name = f"baseline_{size['name']}"
        metric(name, "seed_time", seed_us, "us")
        metric(name, "diff_unchanged_time", unchanged_us, "us")
        metric(name, "diff_changed_time", changed_us, "us")
        for key in ("created", "modified", "removed", "other_changes"):
            metric(name, key, found[key], "records")


if __name__ == "__main__":
    main()
