#!/usr/bin/env bash
# Fast switch to the next participant when everything is already installed
# and running: only OpenClaw is reset and restarted.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
S="$ROOT/scripts"
# shellcheck source=scripts/lib.sh
source "$S/lib.sh"

access=lan
reset_args=()
for arg in "$@"; do
  case "$arg" in
    --local) access=local ;;
    --rotate-token) reset_args+=(--rotate-token) ;;
    *) die "未知参数: $arg（可用 --local / --rotate-token）" ;;
  esac
done

"$S/model-ctl.sh" start qwen
"$S/tts-ctl.sh" start
"$S/reset-openclaw.sh" "${reset_args[@]}"
"$S/showcase-ctl.sh" restart
"$S/openclaw-ctl.sh" start "$access"
echo
echo "打开 OpenClaw（复制整行到浏览器地址栏）："
"$S/openclaw-ctl.sh" urls
echo "提示词：$ROOT/PROMPTS.txt"
