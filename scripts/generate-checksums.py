#!/usr/bin/env python3
"""Generate portable SHA256 manifests and verify Hub LFS digests when available."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "manifests" / "assets.sha256"


def digest(path: Path) -> str:
    sha = hashlib.sha256()
    with path.open("rb") as handle:
        while block := handle.read(16 * 1024 * 1024):
            sha.update(block)
    return sha.hexdigest()


records: list[tuple[str, Path]] = []
expected: dict[Path, str] = {}

for model_name in ("qwen", "nemotron"):
    folder = ROOT / "models" / model_name
    metadata_path = folder / ".snapshot-api.json"
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    for item in metadata.get("siblings", []):
        path = folder / item["rfilename"]
        lfs = item.get("lfs") or {}
        oid = lfs.get("oid", "")
        if oid.startswith("sha256:"):
            expected[path] = oid.removeprefix("sha256:")
        if path.is_file():
            records.append((str(path.relative_to(ROOT)), path))

for path in (
    ROOT / "artifacts/containers/dgx-spark-vllm-0.28.0-nvfp4.tar",
    ROOT / "artifacts/node/node-v24.16.0-linux-arm64.tar.xz",
    ROOT / "openclaw/package-lock.json",
    ROOT / "showcase/vendor/three.module.js",
):
    if path.is_file():
        records.append((str(path.relative_to(ROOT)), path))

lines: list[str] = []
for relative, path in sorted(records):
    actual = digest(path)
    wanted = expected.get(path)
    if wanted and actual != wanted:
        raise SystemExit(f"SHA256 mismatch: {relative}: {actual} != {wanted}")
    print(f"[OK] {relative}")
    lines.append(f"{actual}  {relative}")

OUTPUT.parent.mkdir(parents=True, exist_ok=True)
OUTPUT.write_text("\n".join(lines) + "\n", encoding="utf-8")
print(f"wrote {OUTPUT}")

