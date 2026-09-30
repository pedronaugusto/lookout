#!/usr/bin/env python3
"""Create or remove one strictly-scoped mutable watch root."""

from __future__ import annotations

import os
import argparse
import json
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUILD = Path(os.environ.get("BENCH_BUILD_DIR", str(ROOT / "build")))
WORK = (BUILD / "work").resolve()
INPUTS = BUILD / "inputs"


def checked(path_text: str) -> Path:
    path = Path(path_text).resolve()
    if path == WORK or WORK not in path.parents:
        raise SystemExit(f"refusing path outside build/work: {path}")
    return path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root")
    parser.add_argument("workload", choices=("latency", "burst", "rename", "idle"))
    parser.add_argument("--remove", action="store_true")
    args = parser.parse_args()
    path = checked(args.root)
    if path.exists():
        shutil.rmtree(path)
    if args.remove:
        return
    path.mkdir(parents=True)

    cfg = json.loads((INPUTS / "config.json").read_text(encoding="utf-8"))
    if args.workload == "burst":
        for count in cfg["burst_counts"]:
            (path / f"burst-{count}").mkdir()
    elif args.workload == "rename":
        for line in (INPUTS / "rename.tsv").read_text(encoding="utf-8").splitlines():
            old, _ = line.split("\t")
            (path / old).write_bytes(b"x")


if __name__ == "__main__":
    main()
