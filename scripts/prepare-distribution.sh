#!/usr/bin/env bash
# Remove machine/session identity in place while keeping programs, models and
# caches. The next ./install.sh generates a new token and fresh state.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

"$DEMO_ROOT/stop.sh" || true

rm -rf \
  "$DEMO_ROOT/openclaw/state" \
  "$DEMO_ROOT/openclaw/.secrets" \
  "$DEMO_WORKSPACE" \
  "$DEMO_RUNTIME/config" "$DEMO_RUNTIME/data" "$DEMO_RUNTIME/tmp" "$DEMO_RUNTIME/pids" \
  "$DEMO_ROOT/showcase/sandbox-data" \
  "$DEMO_LOGS"
mkdir -p "$DEMO_ROOT/openclaw/state" "$DEMO_WORKSPACE" "$DEMO_RUNTIME/tmp" "$DEMO_RUNTIME/pids" "$DEMO_LOGS"

ok "目录已脱敏。运行 ./install.sh 会生成新的令牌与全新 OpenClaw 状态。"
