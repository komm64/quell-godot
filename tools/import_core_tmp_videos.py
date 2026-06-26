from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
from pathlib import Path


VIDEO_EXTENSIONS = {".mp4", ".mov", ".mkv", ".webm", ".avi"}
DEFAULT_CORE_TMP = Path(r"C:\Users\komm64\Projects\quell-core\.tmp")
DEFAULT_OUTPUT_ROOT = DEFAULT_CORE_TMP / "quell-godot-sample-frames"


def _ffmpeg_exe() -> str:
    try:
        import imageio_ffmpeg
    except ImportError as exc:
        raise SystemExit("imageio_ffmpeg is required to import .tmp videos") from exc
    return imageio_ffmpeg.get_ffmpeg_exe()


def _slug(value: str) -> str:
    normalized = re.sub(r"[^A-Za-z0-9]+", "-", value).strip("-").lower()
    return normalized[:72] or "video"


def _video_duration(path: Path) -> float:
    try:
        import imageio_ffmpeg

        _frames, seconds = imageio_ffmpeg.count_frames_and_secs(str(path))
        return float(seconds)
    except Exception:
        return 0.0


def _load_manifest(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}


def _is_current(video: Path, out_dir: Path, fps: float, max_width: int, quality: int) -> bool:
    manifest = _load_manifest(out_dir / "manifest.json")
    if not manifest:
        return False
    if Path(str(manifest.get("source_video", ""))) != video:
        return False
    if int(manifest.get("source_size", -1)) != video.stat().st_size:
        return False
    if int(manifest.get("source_mtime_ns", -1)) != video.stat().st_mtime_ns:
        return False
    if float(manifest.get("fps", -1.0)) != float(fps):
        return False
    if int(manifest.get("max_width", -1)) != int(max_width):
        return False
    if int(manifest.get("quality", -1)) != int(quality):
        return False
    return bool(list(out_dir.glob("frame_*.jpg")))


def _import_video(video: Path, output_root: Path, fps: float, max_width: int, quality: int, force: bool) -> Path:
    slug = _slug(video.stem)
    out_dir = output_root / slug
    if not force and _is_current(video, out_dir, fps, max_width, quality):
        return out_dir

    if out_dir.exists():
        shutil.rmtree(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    ffmpeg = _ffmpeg_exe()
    output_pattern = out_dir / "frame_%06d.jpg"
    vf = f"fps={fps:g},scale=min({max_width}\\,iw):-2"
    subprocess.run(
        [
            ffmpeg,
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(video),
            "-vf",
            vf,
            "-q:v",
            str(quality),
            str(output_pattern),
        ],
        check=True,
    )

    frame_count = len(list(out_dir.glob("frame_*.jpg")))
    duration = _video_duration(video)
    manifest = {
        "schema": "quell-godot-tmp-video-frames-v1",
        "id": f"tmp_video_{slug}",
        "name": video.stem,
        "source_video": str(video),
        "source_size": video.stat().st_size,
        "source_mtime_ns": video.stat().st_mtime_ns,
        "frame_dir": str(out_dir),
        "frame_prefix": "frame_",
        "frame_extension": ".jpg",
        "frame_count": frame_count,
        "fps": fps,
        "duration_seconds": duration if duration > 0.0 else (frame_count / max(fps, 1.0)),
        "max_width": max_width,
        "quality": quality,
        "estimated_risk": 1.35,
    }
    (out_dir / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    return out_dir


def _videos(core_tmp: Path, explicit_video: str) -> list[Path]:
    if explicit_video:
        return [Path(explicit_video).resolve()]
    return sorted(
        path
        for path in core_tmp.iterdir()
        if path.is_file() and path.suffix.lower() in VIDEO_EXTENSIONS
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Import quell-core/.tmp videos as sample frame sequences.")
    parser.add_argument("--core-tmp", default=str(DEFAULT_CORE_TMP))
    parser.add_argument("--output-root", default=str(DEFAULT_OUTPUT_ROOT))
    parser.add_argument("--video", default="")
    parser.add_argument("--fps", type=float, default=12.0)
    parser.add_argument("--max-width", type=int, default=640)
    parser.add_argument("--quality", type=int, default=5)
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    core_tmp = Path(args.core_tmp).resolve()
    output_root = Path(args.output_root).resolve()
    output_root.mkdir(parents=True, exist_ok=True)
    imported: list[str] = []
    for video in _videos(core_tmp, args.video):
        if not video.exists():
            raise FileNotFoundError(video)
        out_dir = _import_video(video, output_root, args.fps, args.max_width, args.quality, args.force)
        imported.append(str(out_dir))
    print(json.dumps({"imported": imported}, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
