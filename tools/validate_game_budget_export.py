#!/usr/bin/env python3
import argparse
import json
from pathlib import Path

from PIL import Image, ImageChops, ImageStat


def _mae(a: Image.Image, b: Image.Image) -> float:
    diff = ImageChops.difference(a.convert("RGBA"), b.convert("RGBA"))
    stat = ImageStat.Stat(diff)
    return sum(stat.mean[:3]) / (3.0 * 255.0)


def _load_manifest(root: Path) -> dict:
    manifest_path = root / "manifest.json"
    if not manifest_path.exists():
        raise FileNotFoundError(f"manifest not found: {manifest_path}")
    return json.loads(manifest_path.read_text(encoding="utf-8"))


def validate(root: Path, raw_motion_threshold: float, frozen_after_threshold: float) -> dict:
    manifest = _load_manifest(root)
    summary = manifest.get("summary", {})
    raw_paths = sorted((root / "raw").glob("frame_*.png"))
    after_paths = sorted((root / "after").glob("frame_*.png"))
    pair_count = max(0, min(len(raw_paths), len(after_paths)) - 1)
    moving_pairs = 0
    frozen_pairs = []
    after_deltas = []
    raw_deltas = []

    for index in range(1, pair_count + 1):
        raw_delta = _mae(Image.open(raw_paths[index - 1]), Image.open(raw_paths[index]))
        after_delta = _mae(Image.open(after_paths[index - 1]), Image.open(after_paths[index]))
        raw_deltas.append(raw_delta)
        after_deltas.append(after_delta)
        if raw_delta >= raw_motion_threshold:
            moving_pairs += 1
            if after_delta < frozen_after_threshold:
                frozen_pairs.append({
                    "frame": index + 1,
                    "raw_delta": raw_delta,
                    "after_delta": after_delta,
                })

    safety_passed = (
        bool(summary.get("after_target_passed", False))
        and int(summary.get("after_over_target_frames", 1)) == 0
        and float(summary.get("max_after_risk", 999.0)) <= float(manifest.get("target", 0.8)) + 0.005
    )
    motion_passed = len(frozen_pairs) == 0
    return {
        "root": str(root),
        "passed": safety_passed and motion_passed,
        "safety_passed": safety_passed,
        "motion_passed": motion_passed,
        "summary": summary,
        "analysis_size": [manifest.get("analysis_width"), manifest.get("analysis_height")],
        "analyzed_frames": manifest.get("analyzed_frames"),
        "pairs": pair_count,
        "moving_pairs": moving_pairs,
        "frozen_pairs": frozen_pairs,
        "mean_raw_delta": sum(raw_deltas) / len(raw_deltas) if raw_deltas else 0.0,
        "mean_after_delta": sum(after_deltas) / len(after_deltas) if after_deltas else 0.0,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("export_root", type=Path)
    parser.add_argument("--raw-motion-threshold", type=float, default=0.02)
    parser.add_argument("--frozen-after-threshold", type=float, default=0.001)
    args = parser.parse_args()
    result = validate(args.export_root, args.raw_motion_threshold, args.frozen_after_threshold)
    print(json.dumps(result, indent=2))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
