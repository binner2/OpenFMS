#!/usr/bin/env python3
"""Prepare normalized manifest for OpenFMS vs OpenRMF comparison (S2.2).

This script does not execute OpenRMF by default; it generates a manifest with aligned
scenario parameters and command templates so both frameworks can be run on the same topology.
"""

import argparse
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description="Prepare cross-framework benchmark manifest")
    parser.add_argument("--robot-counts", default="4,8,16,24")
    parser.add_argument("--duration", type=int, default=180)
    parser.add_argument("--mode", default="random")
    parser.add_argument("--output", default="artifacts/reviewer_runs/framework_manifest.json")
    args = parser.parse_args()

    robot_counts = [int(x.strip()) for x in args.robot_counts.split(",") if x.strip()]

    manifest = []
    for rc in robot_counts:
        seed = rc * 1000 + 1
        manifest.append({
            "robot_count": rc,
            "seed": seed,
            "duration_sec": args.duration,
            "kpi_schema": [
                "task_success_ratio",
                "queue_pressure",
                "detected_collisions",
                "fleet_waiting_time_sec",
                "overall_latency_sec",
                "system_information_age_avg_sec",
                "system_information_age_max_sec",
            ],
            "openfms_cmd": [
                "python3", "fleet_management/FmInterface.py", "run", args.mode,
                "--num-robots", str(rc),
                "--duration", str(args.duration),
                "--seed", str(seed),
            ],
            "openrmf_cmd_template": [
                "<openrmf_runner>",
                "--topology", "config/config.yaml",
                "--robots", str(rc),
                "--duration", str(args.duration),
                "--seed", str(seed),
            ],
        })

    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Wrote {out}")


if __name__ == "__main__":
    main()
