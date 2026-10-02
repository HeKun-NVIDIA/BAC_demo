#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
S="$ROOT/scripts"

"$S/model-ctl.sh" status
"$S/tts-ctl.sh" status
"$S/showcase-ctl.sh" status
"$S/openclaw-ctl.sh" status && "$S/openclaw-ctl.sh" urls
