#!/usr/bin/env python3
"""Run reviewer-driven experiment matrix and collect KPIs.

This script executes OpenFMS scenarios with varying robot counts/repeats and stores
structured metadata for reproducibility.
"""

import argparse
import json
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path


def run_cmd(cmd: list[str], cwd: Path, timeout: int) -> tuple[int, str, str, float]:
    start = time.time()
    proc = subprocess.run(cmd, cwd=str(cwd), capture_output=True, text=True, timeout=timeout)
    duration = time.time() - start
    return proc.returncode, proc.stdout, proc.stderr, duration


def main():
    parser = argparse.ArgumentParser(description="Run OpenFMS reviewer experiment matrix")
    parser.add_argument("--robot-counts", default="8,12,16,24,32,40,50",
                        help="Comma-separated robot counts")
    parser.add_argument("--repeats", type=int, default=3, help="Repeat count per robot level")
    parser.add_argument("--duration", type=int, default=180, help="Seconds per run")
    parser.add_argument("--analytics-interval", type=int, default=30)
    parser.add_argument("--task-spacing", type=int, default=3)
    parser.add_argument("--mode", default="random", help="FmInterface mode")
    parser.add_argument("--output-dir", default="artifacts/reviewer_runs")
    parser.add_argument("--timeout", type=int, default=3600)
    parser.add_argument("--skip-exec", action="store_true",
                        help="Only produce plan/metadata; do not execute experiments")
    args = parser.parse_args()

    repo = Path(__file__).resolve().parents[2]
    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    robot_counts = [int(x.strip()) for x in args.robot_counts.split(",") if x.strip()]
    run_manifest = []

    for rc in robot_counts:
        for repeat_idx in range(1, args.repeats + 1):
            seed = rc * 1000 + repeat_idx
            run_id = f"rc{rc}_rep{repeat_idx}"
            cmd = [
                "python3", "fleet_management/FmInterface.py", "run", args.mode,
                "--num-robots", str(rc),
                "--duration", str(args.duration),
                "--analytics-interval", str(args.analytics_interval),
                "--task-spacing", str(args.task_spacing),
                "--seed", str(seed),
            ]

            record = {
                "run_id": run_id,
                "timestamp_utc": datetime.now(timezone.utc).isoformat(),
                "robot_count": rc,
                "repeat": repeat_idx,
                "seed": seed,
                "command": cmd,
            }

            if not args.skip_exec:
                code, stdout, stderr, elapsed = run_cmd(cmd, cwd=repo, timeout=args.timeout)
                record.update({
                    "return_code": code,
                    "elapsed_sec": round(elapsed, 3),
                    "stdout_file": f"{run_id}.stdout.log",
                    "stderr_file": f"{run_id}.stderr.log",
                })
                (out_dir / record["stdout_file"]).write_text(stdout, encoding="utf-8")
                (out_dir / record["stderr_file"]).write_text(stderr, encoding="utf-8")

                # Collect latest KPI snapshot after each run.
                tag = f"{run_id}|mode={args.mode}|duration={args.duration}"
                collect_cmd = [
                    "python3", "scripts/experiments/collect_metrics.py",
                    "--latest-only",
                    "--output", str(out_dir / f"{run_id}.kpi.jsonl"),
                    "--tag", tag,
                ]
                c_code, c_out, c_err, _ = run_cmd(collect_cmd, cwd=repo, timeout=120)
                record["collect_return_code"] = c_code
                record["collect_stdout"] = c_out.strip()
                record["collect_stderr"] = c_err.strip()

            run_manifest.append(record)
            print(f"Prepared run: {run_id}")

    (out_dir / "run_manifest.json").write_text(
        json.dumps(run_manifest, ensure_ascii=False, indent=2),
        encoding="utf-8"
    )
    print(f"Wrote manifest: {out_dir / 'run_manifest.json'}")


if __name__ == "__main__":
    main()
