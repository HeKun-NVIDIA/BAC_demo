#!/usr/bin/env python3
"""Regenerate the self-extracting root install.sh."""

from __future__ import annotations

import base64
import gzip
import hashlib
import io
import os
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "install.sh"

INCLUDE = [
    ".gitignore",
    "VERSION",
    "README.md",
    "MANUAL_TEST.md",
    "PROMPTS.txt",
    "env.sh",
    "reset.sh",
    "stop.sh",
    "status.sh",
    "uninstall.sh",
    "scripts",
    "artifacts/container",
    "openclaw/bin",
    "openclaw/config",
    "openclaw/plugins",
    "openclaw/tools",
    "openclaw/workspace-template",
    "openclaw/package.json",
    "openclaw/package-lock.json",
    "services/tts",
    "showcase/server.py",
    "openclaw/demo-templates",
    "docs/MODEL_DOWNLOAD_CN.md",
    "docs/THIRD_PARTY.md",
    "docs/bacdemolist.pptx",
    "manifests",
]


def tar_filter(info: tarfile.TarInfo) -> tarfile.TarInfo | None:
    parts = Path(info.name).parts
    if "__pycache__" in parts or info.name.endswith((".pyc", ".partial")):
        return None
    info.uid = 0
    info.gid = 0
    info.uname = "root"
    info.gname = "root"
    info.mtime = 0
    return info


def build_payload() -> bytes:
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w") as archive:
        for relative in INCLUDE:
            source = ROOT / relative
            if not source.exists():
                raise SystemExit(f"missing standalone payload input: {relative}")
            archive.add(source, arcname=relative, recursive=True, filter=tar_filter)
    compressed = io.BytesIO()
    with gzip.GzipFile(fileobj=compressed, mode="wb", mtime=0, compresslevel=9) as gz:
        gz.write(raw.getvalue())
    return compressed.getvalue()


def main() -> None:
    payload = build_payload()
    digest = hashlib.sha256(payload).hexdigest()
    encoded = base64.b64encode(payload).decode("ascii")
    wrapped = "\n".join(encoded[i : i + 76] for i in range(0, len(encoded), 76))
    header = f"""#!/usr/bin/env bash
# DGX Spark x OpenClaw standalone workshop installer.
# This single file contains the small project skeleton. Models, the pinned
# public ARM64 vLLM base image, Node, OpenClaw, Chromium and Python packages are
# downloaded on the first run; subsequent runs reuse them and reset OpenClaw.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PAYLOAD_ID="{digest}"
MARKER="$ROOT/.standalone-payload-id"

if [[ ! -x "$ROOT/scripts/install-main.sh" ]] ||
   [[ ! -s "$MARKER" ]] ||
   [[ "$(cat "$MARKER" 2>/dev/null || true)" != "$PAYLOAD_ID" ]]; then
  echo "[安装] 解压 install.sh 内置项目骨架"
  payload_line="$(awk '/^__DGX_OPENCLAW_PAYLOAD_BELOW__$/ {{ print NR + 1; exit }}' "$0")"
  [[ -n "$payload_line" ]] || {{ echo "install.sh payload marker missing" >&2; exit 1; }}
  tmp="$(mktemp "$ROOT/.install-payload.XXXXXX.tar.gz")"
  trap 'rm -f "$tmp"' EXIT
  tail -n +"$payload_line" "$0" | base64 --decode > "$tmp"
  printf '%s  %s\\n' "$PAYLOAD_ID" "$tmp" | sha256sum -c - >/dev/null
  tar --no-same-owner -xzf "$tmp" -C "$ROOT"
  printf '%s\\n' "$PAYLOAD_ID" > "$MARKER"
  rm -f "$tmp"
  trap - EXIT
fi

exec "$ROOT/scripts/install-main.sh" "$@"
exit 1
__DGX_OPENCLAW_PAYLOAD_BELOW__
"""
    OUTPUT.write_text(header + wrapped + "\n", encoding="utf-8")
    os.chmod(OUTPUT, 0o755)
    print(
        f"wrote {OUTPUT}: {len(payload) / 1e6:.2f} MB compressed, "
        f"{OUTPUT.stat().st_size / 1e6:.2f} MB script, sha256={digest}"
    )


if __name__ == "__main__":
    main()
