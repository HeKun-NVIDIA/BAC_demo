#!/usr/bin/env python3
"""Validate that local model snapshots contain every expected file."""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

ROOT = Path(os.environ.get("DEMO_ROOT", Path(__file__).resolve().parents[1]))
MODELS = {
    "qwen": (ROOT / "models" / "qwen", ["config.json", "model.safetensors.index.json"]),
    "nemotron": (ROOT / "models" / "nemotron", ["config.json", "model.safetensors.index.json"]),
    "qwen3-tts": (
        ROOT / "models" / "qwen3-tts",
        ["config.json", "model.safetensors", "speech_tokenizer/model.safetensors"],
    ),
}


def verify(name: str, folder: Path, required: list[str]) -> int:
    problems: list[str] = []
    for relative in required:
        path = folder / relative
        if not path.is_file() or path.stat().st_size == 0:
            problems.append(f"missing {relative}")

    index_path = folder / "model.safetensors.index.json"
    weight_files: set[str] = set()
    if index_path.is_file():
        index = json.loads(index_path.read_text(encoding="utf-8"))
        weight_files = set(index.get("weight_map", {}).values())
        for relative in sorted(weight_files):
            path = folder / relative
            if not path.is_file() or path.stat().st_size == 0:
                problems.append(f"missing/empty {relative}")

    expected_path = folder / ".expected-files.tsv"
    if expected_path.is_file():
        for line in expected_path.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            relative, expected = line.rsplit("\t", 1)
            path = folder / relative
            if not path.is_file():
                problems.append(f"missing {relative}")
            elif int(expected) and path.stat().st_size != int(expected):
                problems.append(f"size {relative}: {path.stat().st_size} != {expected}")

    if problems:
        print(f"[FAIL] {name}")
        for problem in sorted(set(problems)):
            print(f"  - {problem}")
        return 1

    total = sum(path.stat().st_size for path in folder.rglob("*") if path.is_file())
    print(f"[OK] {name}: {total / 1e9:.2f} GB")
    return 0


def main() -> int:
    selected = sys.argv[1:] or ["qwen", "qwen3-tts"]
    unknown = [name for name in selected if name not in MODELS]
    if unknown:
        print(f"unknown model key(s): {', '.join(unknown)}", file=sys.stderr)
        return 2
    failures = sum(verify(name, *MODELS[name]) for name in selected)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
