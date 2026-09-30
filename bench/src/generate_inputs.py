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

    setup = INPUTS / "setup_tree"
    setup.mkdir()
    per_dir = cfg["setup_files"] // cfg["setup_dirs"]
    extra = cfg["setup_files"] % cfg["setup_dirs"]
    for d in range(cfg["setup_dirs"]):
        sub = setup / f"d{d:04d}"
        sub.mkdir()
        count = per_dir + (1 if d < extra else 0)
        for i in range(count):
            (sub / f"f{i:06d}.txt").write_bytes(b"x")

    marker.write_text(json.dumps(cfg, sort_keys=True, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
