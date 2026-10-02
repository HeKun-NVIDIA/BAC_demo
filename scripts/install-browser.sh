#!/usr/bin/env bash
# Bundle-local Chromium for the OpenClaw browser tool (no snap, no system install).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

PLAYWRIGHT_CLI="$DEMO_ROOT/openclaw/node_modules/playwright-core/cli.js"

if [[ -x "$CHROMIUM_BIN" ]] && "$CHROMIUM_BIN" --version >/dev/null 2>&1; then
  skip "Chromium 已安装: $("$CHROMIUM_BIN" --version)"
  exit 0
fi

[[ -f "$PLAYWRIGHT_CLI" ]] || die "缺少 playwright-core，请先安装 OpenClaw"
info "从 npmmirror 下载 Chromium（约 200 MB）"
mkdir -p "$PLAYWRIGHT_BROWSERS_PATH"
PLAYWRIGHT_BROWSERS_PATH="$PLAYWRIGHT_BROWSERS_PATH" \
PLAYWRIGHT_DOWNLOAD_HOST="$PLAYWRIGHT_DOWNLOAD_HOST" \
  "$NODE_HOME/bin/node" "$PLAYWRIGHT_CLI" install chromium

[[ -x "$CHROMIUM_BIN" ]] ||
  die "Chromium 安装后未找到 $CHROMIUM_BIN（playwright-core 版本变化时需同步 env.sh）"
ok "Chromium: $("$CHROMIUM_BIN" --version)"
