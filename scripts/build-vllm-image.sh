#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

# Pinned public ARM64 manifest from the multi-arch vLLM nightly recommended by
# the NVIDIA model card. Use a mainland mirror first; the digest is identical
# to Docker Hub, which remains an automatic fallback.
BASE_DIGEST="sha256:6a8b606d0df31c73054d0b83b5f70637203f7676b27a1d02da0dfc6ba5d51368"
DOMESTIC_BASE="docker.1ms.run/vllm/vllm-openai:nightly@$BASE_DIGEST"
DIRECT_BASE="vllm/vllm-openai:nightly@$BASE_DIGEST"
BASE_IMAGE="${BASE_IMAGE:-$DOMESTIC_BASE}"
ARCHIVE="$DEMO_ROOT/artifacts/containers/dgx-spark-vllm-0.28.0-nvfp4.tar"
EXPORT=1
[[ "${1:-}" == "--no-export" ]] && EXPORT=0

require_command docker
mkdir -p "$(dirname "$ARCHIVE")"

section "构建固定 vLLM 0.28.0 镜像"
info "基础镜像: $BASE_IMAGE"
info "Python 包主源: 阿里云 PyPI 镜像"
build_image() {
  docker build \
    --build-arg "BASE_IMAGE=$1" \
    --build-arg "PIP_INDEX_URL=${PIP_INDEX_URL:-https://mirrors.aliyun.com/pypi/simple}" \
    --build-arg "PIP_EXTRA_INDEX_URL=${PIP_EXTRA_INDEX_URL:-https://pypi.org/simple}" \
    -t "$VLLM_IMAGE" \
    "$DEMO_ROOT/artifacts/container"
}
if ! build_image "$BASE_IMAGE"; then
  [[ "$BASE_IMAGE" == "$DOMESTIC_BASE" ]] ||
    die "自定义基础镜像构建失败: $BASE_IMAGE"
  warn "国内 Docker 代理不可用，改用相同 digest 的 Docker Hub 原地址"
  build_image "$DIRECT_BASE"
fi

docker run --rm -i --entrypoint python3 "$VLLM_IMAGE" - <<'PY'
from importlib.metadata import version
print("vllm", version("vllm"))
print("flashinfer-python", version("flashinfer-python"))
print("nvidia-cutlass-dsl", version("nvidia-cutlass-dsl"))
PY

if (( EXPORT )); then
  section "导出离线 OCI 镜像"
  tmp="$ARCHIVE.partial"
  rm -f "$tmp"
  docker save "$VLLM_IMAGE" -o "$tmp"
  mv "$tmp" "$ARCHIVE"
  chmod 644 "$ARCHIVE"
  (
    cd "$(dirname "$ARCHIVE")"
    sha256sum "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256"
  )
  ok "镜像已导出: $ARCHIVE"
else
  warn "按 --no-export 跳过 docker save"
fi

