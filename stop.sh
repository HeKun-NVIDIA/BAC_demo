#!/usr/bin/env bash
# Stops everything this workshop started. Other demos are never touched.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
S="$ROOT/scripts"

"$S/openclaw-ctl.sh" stop || true
"$S/showcase-ctl.sh" stop || true
"$S/tts-ctl.sh" stop || true
"$S/model-ctl.sh" stop || true
