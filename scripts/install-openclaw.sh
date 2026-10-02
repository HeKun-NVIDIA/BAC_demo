#!/usr/bin/env bash
# Installs the bundle-local Node.js and the pinned OpenClaw program.
# Configuration and state are handled by reset-openclaw.sh.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

NODE_VERSION="${NODE_VERSION:-v24.16.0}"
OPENCLAW_VERSION="2026.9.4"
NODE_ARCHIVE="$DEMO_ROOT/artifacts/node/node-${NODE_VERSION}-linux-arm64.tar.xz"
NODE_URL="${NODE_URL:-https://npmmirror.com/mirrors/node/${NODE_VERSION}/node-${NODE_VERSION}-linux-arm64.tar.xz}"

node_ok() {
  [[ -x "$NODE_HOME/bin/node" ]] && [[ "$("$NODE_HOME/bin/node" -v 2>/dev/null)" == "$NODE_VERSION" ]]
}

openclaw_version() {
  "$NODE_HOME/bin/node" -e \
    "console.log(require('$DEMO_ROOT/openclaw/node_modules/openclaw/package.json').version)" \
    2>/dev/null || true
}

if node_ok; then
  skip "Node $NODE_VERSION 已安装"
else
  info "安装 bundle 内 Node $NODE_VERSION"
  mkdir -p "$(dirname "$NODE_ARCHIVE")"
  if [[ ! -f "$NODE_ARCHIVE" ]]; then
    info "从国内 npmmirror 下载 Node"
    curl -fL --retry 5 --retry-all-errors "$NODE_URL" -o "$NODE_ARCHIVE.partial"
    mv "$NODE_ARCHIVE.partial" "$NODE_ARCHIVE"
  fi
  rm -rf "$NODE_HOME"
  mkdir -p "$NODE_HOME"
  tar -xJf "$NODE_ARCHIVE" -C "$NODE_HOME" --strip-components=1
  node_ok || die "Node 安装失败"
  ok "Node $("$NODE_HOME/bin/node" -v)"
fi

if [[ "$(openclaw_version)" == "$OPENCLAW_VERSION" ]]; then
  skip "OpenClaw $OPENCLAW_VERSION 已安装"
else
  info "从 npmmirror 安装 OpenClaw $OPENCLAW_VERSION"
  (
    cd "$DEMO_ROOT/openclaw"
    PATH="$NODE_HOME/bin:$PATH" npm install \
      --registry="$NPM_REGISTRY" --no-audit --no-fund
  )
  [[ "$(openclaw_version)" == "$OPENCLAW_VERSION" ]] ||
    die "OpenClaw 版本不符：期望 $OPENCLAW_VERSION，实际 $(openclaw_version)"
  ok "OpenClaw $OPENCLAW_VERSION"
fi
chmod +x "$OPENCLAW_BIN"
