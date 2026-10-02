#!/usr/bin/env python3
"""Fail if the portable tree contains links or runtime paths outside itself."""

from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
problems: list[str] = []

for path in ROOT.rglob("*"):
    if any(part in {"node_modules", "corpus", "jupyter-env"} for part in path.parts):
        continue
    if path.is_symlink():
        target = path.resolve()
        # Python venv launchers intentionally point at the target Spark's
        # system Python. The application venv runs on the host; the TTS venv is
        # mounted into the fixed path /demo/runtime/tts-venv in the container.
        expected_system_python = (
            path.name.startswith("python")
            and "bin" in path.parts
            and any(
                venv in path.parts
                for venv in ("pyenv", "tts-venv")
            )
            and str(target).startswith("/usr/bin/python3")
        )
        if expected_system_python:
            continue
        if target != ROOT and ROOT not in target.parents:
            problems.append(f"external symlink: {path} -> {target}")

config = ROOT / "openclaw/state/.openclaw/openclaw.json"
if config.is_file():
    data = json.loads(config.read_text(encoding="utf-8"))
    workspace = Path(data["agents"]["defaults"]["workspace"]).resolve()
    if workspace != (ROOT / "workspace").resolve():
        problems.append(f"OpenClaw workspace outside bundle: {workspace}")
    expected = {"qwen-local": "http://127.0.0.1:18000/v1"}
    for provider, url in expected.items():
        actual = data["models"]["providers"][provider]["baseUrl"]
        if actual != url:
            problems.append(f"{provider} endpoint: {actual} != {url}")

for source in (ROOT / "scripts", ROOT / "openclaw/config", ROOT / "workspace"):
    for path in source.rglob("*"):
        if not path.is_file() or path.suffix not in {".sh", ".py", ".json", ".md"}:
            continue
        if path.resolve() == Path(__file__).resolve():
            continue
        text = path.read_text(encoding="utf-8", errors="ignore")
        for forbidden in (
            "/home/nvidia/build_a_claw_workshop",
            "/home/nvidia/qwen-openclaw-hermes-demo",
            "/home/nvidia/.openclaw",
        ):
            if forbidden in text:
                problems.append(f"external path in {path}: {forbidden}")

if problems:
    for problem in problems:
        print(f"[FAIL] {problem}")
    raise SystemExit(1)

print(f"[OK] portable isolation boundary: {ROOT}")

