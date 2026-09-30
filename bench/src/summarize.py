#!/usr/bin/env python3
"""Validate, aggregate, print and persist benchmark output."""

from __future__ import annotations

import argparse
import json
import statistics
from collections import defaultdict
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--raw", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--inputs", required=True)
    parser.add_argument("--smoke", action="store_true")
    parser.add_argument("--parcel-na", action="store_true")
    args = parser.parse_args()

    groups: dict[tuple[str, str, str, str], list[float]] = defaultdict(list)
    raw = Path(args.raw)
    for path in sorted(raw.glob("*.tsv")):
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            fields = line.split("\t")
            if len(fields) != 5:
                raise SystemExit(f"{path}:{number}: expected five tab-separated fields")
            side, workload, metric, value, unit = fields
            try:
                groups[(side, workload, metric, unit)].append(float(value))
            except ValueError:
                if value != "n/a":
                    raise SystemExit(f"{path}:{number}: non-numeric value {value!r}")
                groups[(side, workload, metric, unit)] = []

    cfg = json.loads((Path(args.inputs) / "config.json").read_text(encoding="utf-8"))
    if args.parcel_na:
        expected: list[tuple[str, list[tuple[str, str]]]] = [
            ("latency", [("latency_median", "us"), ("latency_p99", "us")]),
            ("rename", [("paired", "renames"), ("split", "renames"), ("unmatched", "renames")]),
            ("idle", [("idle_cpu", "us"), ("active_100ps_cpu", "us")]),
            ("tree_setup", [("setup_time", "us"), ("setup_success", "bool")]),
        ]
        for count in cfg["burst_counts"]:
            expected.append((f"burst_{count}", [
                ("events_delivered", "events"), ("files_missed", "files"),
                ("overflow_reported", "bool"), ("time_to_last_event", "us"),
            ]))
        for workload, metrics in expected:
            for metric, unit in metrics:
                groups[("parcel", workload, metric, unit)] = []

    rows: list[tuple[str, str, str, str, str]] = []
    for key in sorted(groups):
        side, workload, metric, unit = key
        values = groups[key]
        if not values:
            value = "n/a"
        elif workload == "tree_setup" and metric == "setup_time" and len(values) > 1:
            value = f"{min(values):.3f}"
        else:
            value = f"{statistics.median(values):.3f}"
        rows.append((side, workload, metric, value, unit))

    output = Path(args.output)
    with output.open("w", encoding="utf-8") as f:
        for row in rows:
            f.write("\t".join(row) + "\n")

    if args.smoke:
        print("SMOKE ONLY — machine loaded; reduced workload sizes")
    widths = [max(len(r[i]) for r in rows + [("side", "workload", "metric", "value", "unit")]) for i in range(5)]
    header = ("side", "workload", "metric", "value", "unit")
    print("  ".join(header[i].ljust(widths[i]) for i in range(5)))
    print("  ".join("-" * widths[i] for i in range(5)))
    for row in rows:
        print("  ".join(row[i].ljust(widths[i]) for i in range(5)))


if __name__ == "__main__":
    main()
