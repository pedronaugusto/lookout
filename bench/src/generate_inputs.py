#!/usr/bin/env python3
"""Generate deterministic manifests and the shared setup tree under build/."""

from __future__ import annotations

import os
import argparse
import json
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUILD = Path(os.environ.get("BENCH_BUILD_DIR", str(ROOT / "build")))
INPUTS = BUILD / "inputs"


def write_lines(path: Path, values: list[str]) -> None:
    path.write_text("".join(v + "\n" for v in values), encoding="utf-8")


def write_tree(root: Path, files: int, dirs: int) -> list[str]:
    """`dirs` directories sharing `files` one-byte files; returns every
    entry's path relative to `root`, directories first in each."""
    root.mkdir(parents=True)
    names = []
    per_dir, extra = divmod(files, dirs)
    for d in range(dirs):
        sub = root / f"d{d:04d}"
        sub.mkdir()
        names.append(sub.name)
        for i in range(per_dir + (1 if d < extra else 0)):
            (sub / f"f{i:06d}.txt").write_bytes(b"x")
            names.append(f"{sub.name}/f{i:06d}.txt")
    return names


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("full", "smoke"), default="full")
    args = parser.parse_args()

    if args.mode == "full":
        cfg = {
            "mode": "full",
            "latency_trials": 500,
            "latency_gap_ms": 50,
            "burst_counts": [10_000, 100_000],
            "rename_count": 1_000,
            "idle_seconds": 10,
            "idle_rate": 100,
            "setup_files": 50_000,
            "setup_dirs": 100,
            "baseline_sizes": [
                {"name": "small", "files": 1_000, "dirs": 10},
                {"name": "medium", "files": 10_000, "dirs": 100},
                {"name": "large", "files": 50_000, "dirs": 100},
            ],
            "baseline_change_every": 100,
            "checkpoint_files": 100,
            "poll_window_ms": 2_000,
        }
    else:
        cfg = {
            "mode": "smoke",
            "latency_trials": 1,
            "latency_gap_ms": 10,
            "burst_counts": [1],
            "rename_count": 1,
            "idle_seconds": 1,
            "idle_rate": 1,
            "setup_files": 1,
            "setup_dirs": 1,
            "baseline_sizes": [
                {"name": "small", "files": 3, "dirs": 1},
                {"name": "medium", "files": 6, "dirs": 2},
                {"name": "large", "files": 9, "dirs": 3},
            ],
            "baseline_change_every": 3,
            "checkpoint_files": 3,
            "poll_window_ms": 0,
        }

    marker = INPUTS / "config.json"
    if marker.exists():
        try:
            if json.loads(marker.read_text(encoding="utf-8")) == cfg:
                return
        except (OSError, json.JSONDecodeError):
            pass

    if INPUTS.exists():
        shutil.rmtree(INPUTS)
    INPUTS.mkdir(parents=True)

    write_lines(
        INPUTS / "latency.txt",
        [f"latency-{i:06d}.txt" for i in range(cfg["latency_trials"])],
    )
    for count in cfg["burst_counts"]:
        dirname = f"burst-{count}"
        write_lines(
            INPUTS / f"burst_{count}.txt",
            [f"{dirname}/f{i:06d}.txt" for i in range(count)],
        )
    write_lines(
        INPUTS / "rename.tsv",
        [f"r{i:06d}-old.txt\tr{i:06d}-new.txt" for i in range(cfg["rename_count"])],
    )
    idle_count = cfg["idle_seconds"] * cfg["idle_rate"]
    write_lines(INPUTS / "idle.txt", [f"idle-{i:06d}.txt" for i in range(idle_count)])

    names = write_tree(INPUTS / "setup_tree", cfg["setup_files"], cfg["setup_dirs"])
    # Every entry of the setup tree, for the filter and path workloads.
    write_lines(INPUTS / "paths.txt", names)
    # Pristine trees the baseline workload clones and changes.
    for size in cfg["baseline_sizes"]:
        write_tree(INPUTS / "baseline_trees" / size["name"], size["files"], size["dirs"])

    marker.write_text(json.dumps(cfg, sort_keys=True, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
