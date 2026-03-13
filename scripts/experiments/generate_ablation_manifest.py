#!/usr/bin/env python3
"""Generate a compact, reviewer-focused ablation/sensitivity manifest.

Targets M1.2 with a bounded 5-7 experiment set instead of very large grids.
"""

import argparse
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description="Generate minimal ablation manifest for reviewer response")
    parser.add_argument("--output", default="artifacts/reviewer_runs/ablation_manifest.json")
    parser.add_argument("--robot-count", type=int, default=20)
    parser.add_argument("--duration", type=int, default=240)
    args = parser.parse_args()

    # Intentionally compact set: baseline + targeted ablations/sensitivity points.
    manifest = [
        {
            "id": "A0_baseline",
            "description": "Current scheduler + reservation enabled",
            "params": {
                "robot_count": args.robot_count,
                "duration_sec": args.duration,
                "scheduler_mode": "fuzzy",
                "reservation_mode": "enabled",
                "alpha_beta_profile": "default",
                "lambda_profile": "default",
            },
        },
        {
            "id": "A1_fifo_no_fuzzy",
            "description": "Disable fuzzy scheduling, fallback to FIFO",
            "params": {
                "robot_count": args.robot_count,
                "duration_sec": args.duration,
                "scheduler_mode": "fifo",
                "reservation_mode": "enabled",
                "alpha_beta_profile": "n/a",
                "lambda_profile": "default",
            },
        },
        {
            "id": "A2_no_reservation",
            "description": "Disable node reservation to quantify conflict escalation",
            "params": {
                "robot_count": args.robot_count,
                "duration_sec": args.duration,
                "scheduler_mode": "fuzzy",
                "reservation_mode": "disabled",
                "alpha_beta_profile": "default",
                "lambda_profile": "default",
            },
        },
        {
            "id": "S1_alpha_beta_low",
            "description": "Sensitivity: lower alpha/beta emphasis",
            "params": {
                "robot_count": args.robot_count,
                "duration_sec": args.duration,
                "scheduler_mode": "fuzzy",
                "reservation_mode": "enabled",
                "alpha_beta_profile": "low",
                "lambda_profile": "default",
            },
        },
        {
            "id": "S2_alpha_beta_high",
            "description": "Sensitivity: higher alpha/beta emphasis",
            "params": {
                "robot_count": args.robot_count,
                "duration_sec": args.duration,
                "scheduler_mode": "fuzzy",
                "reservation_mode": "enabled",
                "alpha_beta_profile": "high",
                "lambda_profile": "default",
            },
        },
        {
            "id": "S3_lambda_conservative",
            "description": "Sensitivity: conservative conflict penalties (lambda)",
            "params": {
                "robot_count": args.robot_count,
                "duration_sec": args.duration,
                "scheduler_mode": "fuzzy",
                "reservation_mode": "enabled",
                "alpha_beta_profile": "default",
                "lambda_profile": "conservative",
            },
        },
        {
            "id": "S4_lambda_aggressive",
            "description": "Sensitivity: aggressive conflict penalties (lambda)",
            "params": {
                "robot_count": args.robot_count,
                "duration_sec": args.duration,
                "scheduler_mode": "fuzzy",
                "reservation_mode": "enabled",
                "alpha_beta_profile": "default",
                "lambda_profile": "aggressive",
            },
        },
    ]

    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Wrote {out}")


if __name__ == "__main__":
    main()
