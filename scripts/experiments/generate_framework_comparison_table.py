#!/usr/bin/env python3
"""Build a markdown comparison table from OpenFMS/OpenRMF KPI JSONL files.

Input JSONL records are expected to include at least:
- robot_count
- task_success_ratio
- queue_pressure
- detected_collisions
- fleet_waiting_time_sec
- overall_latency_sec
- system_information_age_avg_sec
"""

import argparse
import json
from collections import defaultdict
from pathlib import Path


NUM_KEYS = [
    "task_success_ratio",
    "queue_pressure",
    "detected_collisions",
    "fleet_waiting_time_sec",
    "overall_latency_sec",
    "system_information_age_avg_sec",
]


def load_jsonl(path: Path):
    rows = []
    if not path.exists():
        return rows
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        rows.append(json.loads(line))
    return rows


def aggregate_by_robot(rows):
    grouped = defaultdict(list)
    for r in rows:
        rc = r.get("robot_count")
        if rc is None:
            continue
        grouped[int(rc)].append(r)

    out = {}
    for rc, items in grouped.items():
        rec = {}
        for key in NUM_KEYS:
            vals = [x[key] for x in items if isinstance(x.get(key), (int, float))]
            rec[key] = (sum(vals) / len(vals)) if vals else None
        out[rc] = rec
    return out


def fmt(v):
    if v is None:
        return "-"
    return f"{v:.3f}" if isinstance(v, float) else str(v)


def main():
    parser = argparse.ArgumentParser(description="Generate OpenFMS vs OpenRMF markdown comparison table")
    parser.add_argument("--openfms", required=True, help="OpenFMS KPI JSONL path")
    parser.add_argument("--openrmf", required=True, help="OpenRMF KPI JSONL path")
    parser.add_argument("--output", default="artifacts/reviewer_runs/openfms_openrmf_comparison.md")
    args = parser.parse_args()

    fms = aggregate_by_robot(load_jsonl(Path(args.openfms)))
    rmf = aggregate_by_robot(load_jsonl(Path(args.openrmf)))

    robot_counts = sorted(set(fms.keys()) | set(rmf.keys()))

    lines = [
        "# OpenFMS vs OpenRMF (Reviewer Table)",
        "",
        "| robot_count | framework | success_ratio | queue_pressure | collisions | waiting_sec | latency_sec | info_age_avg_sec |",
        "|---:|---|---:|---:|---:|---:|---:|---:|",
    ]

    for rc in robot_counts:
        for fw, data in (("OpenFMS", fms.get(rc, {})), ("OpenRMF", rmf.get(rc, {}))):
            lines.append(
                f"| {rc} | {fw} | {fmt(data.get('task_success_ratio'))} | {fmt(data.get('queue_pressure'))} | "
                f"{fmt(data.get('detected_collisions'))} | {fmt(data.get('fleet_waiting_time_sec'))} | "
                f"{fmt(data.get('overall_latency_sec'))} | {fmt(data.get('system_information_age_avg_sec'))} |"
            )

    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Wrote {out}")


if __name__ == "__main__":
    main()
