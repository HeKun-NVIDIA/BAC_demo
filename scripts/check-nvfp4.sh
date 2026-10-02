#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

require_command docker

if ! docker image inspect "$VLLM_IMAGE" >/dev/null 2>&1; then
  archive="$DEMO_ROOT/artifacts/containers/dgx-spark-vllm-0.28.0-nvfp4.tar"
  [[ -f "$archive" ]] || die "既没有镜像 $VLLM_IMAGE，也没有离线归档 $archive"
  info "从 bundle 加载 vLLM 镜像"
  docker load -i "$archive"
fi

section "检查 GB10 NVFP4 b12x kernels"
docker run --rm -i --gpus all --entrypoint python3 "$VLLM_IMAGE" - <<'PY'
import torch
from vllm.utils.flashinfer import (
    has_flashinfer_b12x_gemm,
    has_flashinfer_b12x_moe,
)

cap = torch.cuda.get_device_capability()
gemm = has_flashinfer_b12x_gemm()
moe = has_flashinfer_b12x_moe()
print("compute capability:", cap)
print("b12x gemm:", gemm)
print("b12x moe:", moe)
if cap[0] != 12 or not gemm or not moe:
    raise SystemExit(
        "NVFP4 b12x kernel 不可用；继续启动会退化到 Marlin W4A16，已拒绝。"
    )
PY
ok "NVFP4 kernel 检查通过"

