#!/usr/bin/env python3
"""Parse OpenFMS analytics snapshots and export structured metrics.

This script targets lines produced by `FmScheduleHandler.fm_analytics(..., write_to_file=True)`
inside `logs/result_snapshot_*.txt`.
"""

import argparse
import ast
import json
import re
from pathlib import Path

PATTERNS = {
    "completed_orders": re.compile(r"number of total completed Orders: (\d+)"),
    "cancelled_orders": re.compile(r"number of total cancelled Orders: (\d+)"),
    "charge_orders": re.compile(r"number of charge Orders fullfilled: (\d+)"),
    "active_orders": re.compile(r"number of currently active Orders: (\d+)"),
    "unassigned_orders": re.compile(r"number of currently unassigned Orders: (\d+)"),
    "detected_collisions": re.compile(r"detected target collisions: (\d+)"),
    "active_robots": re.compile(r"number of active robots: (\d+)"),
    "fleet_waiting_time_sec": re.compile(r"total fleet waiting time \[sec\]: ([0-9]+(?:\.[0-9]+)?)"),
    "overall_latency_sec": re.compile(r"overall avg \[sec\]: ([0-9]+(?:\.[0-9]+)?)"),
    "robot_latency_dict": re.compile(r"avg per robot latency \[sec\]: (\{.*\})"),
    "robot_information_age_dict": re.compile(r"avg per robot information age \[sec\]: (\{.*\})"),
    "system_information_age_avg_sec": re.compile(r"system information age avg \[sec\]: ([0-9]+(?:\.[0-9]+)?)"),
    "system_information_age_max_sec": re.compile(r"max \[sec\]: ([0-9]+(?:\.[0-9]+)?)"),
}


def parse_snapshot(path: Path) -> dict:
    text = path.read_text(encoding="utf-8", errors="replace")
    result = {"snapshot_file": str(path)}
    for key, pattern in PATTERNS.items():
        m = pattern.search(text)
        if not m:
            continue
        if key in {"robot_latency_dict", "robot_information_age_dict"}:
            try:
                result[key] = ast.literal_eval(m.group(1))
            except (ValueError, SyntaxError):
                result[key] = {}
        elif key in {"fleet_waiting_time_sec", "overall_latency_sec"}:
            result[key] = float(m.group(1))
        else:
            result[key] = int(m.group(1))

    completed = result.get("completed_orders", 0)
    cancelled = result.get("cancelled_orders", 0)
    denom = completed + cancelled
    result["task_success_ratio"] = (completed / denom) if denom > 0 else None

    active = result.get("active_orders", 0)
    unassigned = result.get("unassigned_orders", 0)
    total_work = active + unassigned
    result["queue_pressure"] = (unassigned / total_work) if total_work > 0 else None

    per_robot = result.get("robot_latency_dict", {}) or {}
    if per_robot:
        vals = list(per_robot.values())
        result["max_robot_latency_sec"] = max(vals)
        result["min_robot_latency_sec"] = min(vals)
    else:
        result["max_robot_latency_sec"] = None
        result["min_robot_latency_sec"] = None

    return result


def find_snapshots(log_dir: Path) -> list[Path]:
    files = sorted(log_dir.glob("result_snapshot_*.txt"), key=lambda p: p.stat().st_mtime)
    return files


def main():
    parser = argparse.ArgumentParser(description="Collect OpenFMS KPI metrics from snapshot logs")
    parser.add_argument("--log-dir", default="logs", help="Directory that contains result_snapshot_*.txt")
    parser.add_argument("--latest-only", action="store_true", help="Parse only the most recent snapshot")
    parser.add_argument("--output", default="artifacts/metrics/kpi_results.jsonl", help="Output JSONL path")
    parser.add_argument("--tag", default="", help="Optional experiment tag to append to each record")
    args = parser.parse_args()

    log_dir = Path(args.log_dir)
    snapshots = find_snapshots(log_dir)
    if args.latest_only and snapshots:
        snapshots = [snapshots[-1]]

    records = []
    for snap in snapshots:
        rec = parse_snapshot(snap)
        if args.tag:
            rec["tag"] = args.tag
        records.append(rec)

    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w", encoding="utf-8") as f:
        for rec in records:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")

    print(f"Parsed {len(records)} snapshot(s) -> {out}")


if __name__ == "__main__":
    main()
