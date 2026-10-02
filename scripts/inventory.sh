#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

echo "Bundle: $DEMO_ROOT"
echo "Architecture: $(uname -m)"
echo "GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null || echo unknown)"
echo "Driver: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null || echo unknown)"
echo "Node: $("$NODE_HOME/bin/node" --version 2>/dev/null || echo missing)"
echo "OpenClaw: $("$OPENCLAW_BIN" --version 2>/dev/null || echo missing)"
echo "vLLM image: $VLLM_IMAGE"
docker image inspect "$VLLM_IMAGE" --format 'Image digest: {{.Id}}' 2>/dev/null || true
echo
du -sh \
  "$QWEN_MODEL_DIR" "$NEMOTRON_MODEL_DIR" \
  "$DEMO_ROOT/artifacts/containers" "$DEMO_ROOT/openclaw" \
  "$DEMO_ROOT/showcase" "$DEMO_ROOT/workspace" 2>/dev/null
echo
df -h "$DEMO_ROOT"

