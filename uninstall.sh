#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# Only services and containers carrying this demo's PID files/names are stopped.
"$ROOT/stop.sh" || true

if [[ "${1:-}" == "--remove-image" ]]; then
  docker image rm dgx-spark-vllm:0.28.0-nvfp4 || true
fi

echo "本 demo 已停止。未修改其他 demo、systemd 或全局 npm。"
echo "如需删除全部资产，请手工删除: $ROOT"
