#!/usr/bin/env bash
# Source this file before using the demo manually. Every writable path is
# redirected below DEMO_ROOT so the bundle can be copied or removed as one unit.

_DEMO_ENV_SOURCE="${BASH_SOURCE[0]:-$0}"
export DEMO_ROOT="$(cd "$(dirname "$_DEMO_ENV_SOURCE")" && pwd)"
unset _DEMO_ENV_SOURCE

export DEMO_RUNTIME="$DEMO_ROOT/runtime"
export DEMO_LOGS="$DEMO_ROOT/logs"
export DEMO_WORKSPACE="$DEMO_ROOT/workspace"
export DEMO_OUTPUTS="$DEMO_ROOT/showcase/outputs"
export OPENCLAW_HOME="$DEMO_ROOT/openclaw/state"

# Preserve the login home for diagnostics, then contain normal ~/ paths.
export DEMO_HOST_HOME="${DEMO_HOST_HOME:-$HOME}"
export HOME="$DEMO_WORKSPACE"
export XDG_CACHE_HOME="$DEMO_RUNTIME/cache/xdg"
export XDG_CONFIG_HOME="$DEMO_RUNTIME/config"
export XDG_DATA_HOME="$DEMO_RUNTIME/data"
export TMPDIR="$DEMO_RUNTIME/tmp"
export NPM_CONFIG_CACHE="$DEMO_RUNTIME/cache/npm"
export PIP_CACHE_DIR="$DEMO_RUNTIME/cache/pip"

# Domestic mirrors are only used by installers when something is missing.
export NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmmirror.com}"
export PIP_INDEX_URL="${PIP_INDEX_URL:-https://mirrors.aliyun.com/pypi/simple}"
export PLAYWRIGHT_DOWNLOAD_HOST="${PLAYWRIGHT_DOWNLOAD_HOST:-https://registry.npmmirror.com/-/binary/playwright}"

# Hugging Face and inference caches are bundle-local and offline at runtime.
export HF_HOME="$DEMO_ROOT/models/hf-cache"
export HF_HUB_CACHE="$HF_HOME/hub"
export HUGGINGFACE_HUB_CACHE="$HF_HUB_CACHE"
export TRANSFORMERS_CACHE="$HF_HOME/transformers"
export HF_HUB_OFFLINE="${HF_HUB_OFFLINE:-1}"
export TRANSFORMERS_OFFLINE="${TRANSFORMERS_OFFLINE:-1}"
export VLLM_CACHE_ROOT="$DEMO_RUNTIME/cache/vllm"
export FLASHINFER_WORKSPACE_BASE="$DEMO_RUNTIME/cache/flashinfer"
export TRITON_CACHE_DIR="$DEMO_RUNTIME/cache/triton"

export QWEN_MODEL_DIR="$DEMO_ROOT/models/qwen"
export NEMOTRON_MODEL_DIR="$DEMO_ROOT/models/nemotron"
export TTS_MODEL_DIR="$DEMO_ROOT/models/qwen3-tts"
export QWEN_MODEL_ID="nvidia/Qwen3.6-35B-A3B-NVFP4"
export NEMOTRON_MODEL_ID="nvidia/Nemotron-3-Nano-Omni-30B-A3B-Reasoning-NVFP4"
export TTS_MODEL_ID="qwen3-tts"

# OpenClaw strips the gateway environment from agent commands, so the ports
# chosen at reset time are persisted and reused by every later shell.
if [[ "${DGX_DEMO_ALLOW_PORT_OVERRIDE:-0}" != "1" && -f "$DEMO_ROOT/runtime/ports.env" ]]; then
  # shellcheck source=/dev/null
  source "$DEMO_ROOT/runtime/ports.env"
  export DGX_DEMO_ALLOW_PORT_OVERRIDE=1
fi
if [[ "${DGX_DEMO_ALLOW_PORT_OVERRIDE:-0}" == "1" ]]; then
  export QWEN_PORT="${QWEN_PORT:-18000}"
  export NEMOTRON_PORT="${NEMOTRON_PORT:-18001}"
  export TTS_PORT="${TTS_PORT:-18002}"
  export OPENCLAW_PORT="${OPENCLAW_PORT:-13001}"
  export SHOWCASE_PORT="${SHOWCASE_PORT:-18088}"
else
  # Force isolated defaults even if the parent shell sourced another demo.
  export QWEN_PORT=18000
  export NEMOTRON_PORT=18001
  export TTS_PORT=18002
  export OPENCLAW_PORT=13001
  export SHOWCASE_PORT=18088
fi
# Ports OpenClaw may use for servers it writes during the workshop.
export APP_PORT_FIRST=18090
export APP_PORT_LAST=18099

export QWEN_BASE_URL="http://127.0.0.1:${QWEN_PORT}/v1"
export NEMOTRON_BASE_URL="http://127.0.0.1:${NEMOTRON_PORT}/v1"
export TTS_BASE_URL="http://127.0.0.1:${TTS_PORT}/v1"
export OPENCLAW_BIN="$DEMO_ROOT/openclaw/bin/openclaw"
export VLLM_IMAGE="${VLLM_IMAGE:-dgx-spark-vllm:0.28.0-nvfp4}"

export NODE_HOME="$DEMO_RUNTIME/node"
export DEMO_PYENV="$DEMO_RUNTIME/pyenv"
export PLAYWRIGHT_BROWSERS_PATH="$DEMO_RUNTIME/ms-playwright"
export CHROMIUM_BIN="$PLAYWRIGHT_BROWSERS_PATH/chromium-1234/chrome-linux/chrome"
export PATH="$DEMO_PYENV/bin:$DEMO_ROOT/openclaw/bin:$NODE_HOME/bin:$DEMO_ROOT/scripts:$PATH"

mkdir -p \
  "$DEMO_LOGS" "$DEMO_OUTPUTS" "$DEMO_WORKSPACE" \
  "$OPENCLAW_HOME" "$TMPDIR" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" \
  "$XDG_DATA_HOME" "$NPM_CONFIG_CACHE" "$PIP_CACHE_DIR" "$HF_HUB_CACHE" \
  "$VLLM_CACHE_ROOT" "$FLASHINFER_WORKSPACE_BASE" "$TRITON_CACHE_DIR" \
  "$DEMO_RUNTIME/pids" "$DEMO_RUNTIME/containers"
