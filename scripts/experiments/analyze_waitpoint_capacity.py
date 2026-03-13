#!/usr/bin/env python3
"""Formal waitpoint-capacity analysis for reviewer comment S2.3.

Computes |V_W| and proposes stress scenarios where |R| > |V_W|.
"""

import argparse
import json
from pathlib import Path

import yaml


def load_config(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as f:
        return yaml.safe_load(f)


def main():
    parser = argparse.ArgumentParser(description="Analyze hold-and-wait capacity bounds from config")
    parser.add_argument("--config", default="config/config.yaml")
    parser.add_argument("--output", default="artifacts/metrics/waitpoint_capacity.json")
    args = parser.parse_args()

    cfg = load_config(Path(args.config))
    itinerary = cfg.get("itinerary", [])
    waitpoints = [n for n in itinerary if n.get("description") == "waitpoint"]
    checkpoints = [n for n in itinerary if n.get("description") == "checkpoint"]

    w_count = len(waitpoints)
    c_count = len(checkpoints)

    # Reviewer-oriented stress set for |R| > |V_W|
    candidate_robots = sorted({max(1, w_count - 1), w_count, w_count + 1, w_count + 2, w_count + 5})

    scenarios = []
    for r in candidate_robots:
        overflow = max(0, r - w_count)
        scenarios.append({
            "robot_count": r,
            "waitpoint_count": w_count,
            "overflow_robots": overflow,
            "risk_level": "high" if overflow > 0 else "nominal"
        })

    payload = {
        "config_path": str(args.config),
        "waitpoint_count": w_count,
        "checkpoint_count": c_count,
        "formal_bound": "For strict hold-and-wait buffering, safe nominal regime expects |R| <= |V_W|.",
        "scenarios": scenarios,
    }

    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Wrote {out}")


if __name__ == "__main__":
    main()
