#!/usr/bin/env bash
# Isolated Python environment for Qwen3-TTS. It runs inside the vLLM image
# (torch + CUDA for GB10) and is always mounted at /demo/runtime/tts-venv, so
# the directory stays valid when the bundle is copied to another Spark.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

TTS_VENV="$DEMO_RUNTIME/tts-venv"
IMPORT_CHECK='import qwen_tts, transformers, librosa, soundfile, platformdirs; assert transformers.__version__ == "4.57.3"'

docker image inspect "$VLLM_IMAGE" >/dev/null 2>&1 || die "缺少 vLLM 镜像，请先导入"

venv_ok() {
  [[ -x "$TTS_VENV/bin/python" ]] || return 1
  docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
    -v "$TTS_VENV:/demo/runtime/tts-venv:ro" \
    --entrypoint /demo/runtime/tts-venv/bin/python "$VLLM_IMAGE" \
    -c "$IMPORT_CHECK" >/dev/null 2>&1
}

if venv_ok; then
  skip "Qwen3-TTS 运行环境已就绪"
  exit 0
fi

info "创建 Qwen3-TTS 运行环境（阿里云 PyPI 镜像）"
if [[ -e "$TTS_VENV" ]]; then
  # Earlier root-run attempts may have left root-owned files behind.
  docker run --rm -v "$DEMO_RUNTIME:/demo/runtime" --entrypoint rm "$VLLM_IMAGE" \
    -rf /demo/runtime/tts-venv
fi
mkdir -p "$TTS_VENV"
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -e PIP_INDEX_URL="$PIP_INDEX_URL" \
  -v "$TTS_VENV:/demo/runtime/tts-venv" \
  --entrypoint bash "$VLLM_IMAGE" -lc '
set -e
python3 -m venv --without-pip --system-site-packages /demo/runtime/tts-venv
PY=/demo/runtime/tts-venv/bin/python
OPTS="--disable-pip-version-check --no-cache-dir --index-url $PIP_INDEX_URL"
$PY -m pip install $OPTS --no-deps qwen-tts==0.1.1
$PY -m pip install $OPTS "transformers==4.57.3" "accelerate==1.12.0" librosa soundfile sox onnxruntime platformdirs
'
venv_ok || die "Qwen3-TTS 运行环境校验失败"
ok "Qwen3-TTS 运行环境就绪"
