#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

QWEN_CONTAINER="dgx-demo-qwen"
NEMOTRON_CONTAINER="dgx-demo-nemotron"

# KV cache is sized explicitly so vLLM skips memory profiling: another demo
# loading a model while we start can then no longer shrink or break our cache.
# gpu-memory-utilization only gates the "enough free memory at start" check.
QWEN_CONTEXT="${QWEN_CONTEXT:-131072}"
QWEN_MAX_SEQS="${QWEN_MAX_SEQS:-2}"
QWEN_KV_CACHE="${QWEN_KV_CACHE:-4G}"
QWEN_START_GATE="${QWEN_START_GATE:-0.30}"
# OpenClaw keeps every screenshot of the running turn, so allow plenty.
QWEN_MAX_IMAGES="${QWEN_MAX_IMAGES:-24}"
QWEN_MAX_IMAGE_PIXELS="${QWEN_MAX_IMAGE_PIXELS:-1638400}"
QWEN_NEED_GIB="${QWEN_NEED_GIB:-45}"

NEMOTRON_CONTEXT="${NEMOTRON_CONTEXT:-65536}"
NEMOTRON_KV_CACHE="${NEMOTRON_KV_CACHE:-6G}"
NEMOTRON_START_GATE="${NEMOTRON_START_GATE:-0.30}"
NEMOTRON_NEED_GIB="${NEMOTRON_NEED_GIB:-40}"

ensure_image() {
  if docker image inspect "$VLLM_IMAGE" >/dev/null 2>&1; then
    return
  fi
  local archive="$DEMO_ROOT/artifacts/containers/dgx-spark-vllm-0.28.0-nvfp4.tar"
  [[ -f "$archive" ]] || die "缺少 vLLM 镜像及离线归档，请先运行 install.sh"
  info "导入离线 vLLM 镜像（约 33 GB，首次需要几分钟）"
  docker load -i "$archive"
}

wait_model_container() {
  local name="$1" url="$2" label="$3" timeout="${4:-1200}" started
  started="$(date +%s)"
  while ! curl -fsS --max-time 3 "$url/models" >/dev/null 2>&1; do
    if ! container_running "$name"; then
      warn "$label 容器已退出"
      docker logs --tail 80 "$name" >&2 || true
      return 1
    fi
    if (( $(date +%s) - started >= timeout )); then
      warn "$label 在 ${timeout}s 内未就绪"
      docker logs --tail 80 "$name" >&2 || true
      return 1
    fi
    sleep 3
  done
}

remove_container() {
  docker rm -f "$1" >/dev/null 2>&1 || true
}

normalize_cache_permissions() {
  docker image inspect "$VLLM_IMAGE" >/dev/null 2>&1 || return 0
  docker run --rm \
    -v "$VLLM_CACHE_ROOT:/cache/vllm" \
    -v "$FLASHINFER_WORKSPACE_BASE:/cache/flashinfer" \
    -v "$TRITON_CACHE_DIR:/cache/triton" \
    --entrypoint bash "$VLLM_IMAGE" -lc \
    'chmod -R a+rX /cache' >/dev/null
}

# Other demos on the same Spark may hold memory for a while (for example an
# Ollama keep-alive). Wait a bounded time instead of stopping anything of theirs.
wait_for_memory() {
  local need="$1" label="$2" waited=0 have
  have="$(available_memory_gib)"
  while (( have < need )); do
    if (( waited == 0 )); then
      warn "$label 需要约 ${need} GiB 可用内存，当前 ${have} GiB；等待其他程序释放（不会停止其他 demo）"
    fi
    if (( waited >= 300 )); then
      warn "等待 5 分钟后可用内存仍只有 ${have} GiB，继续尝试启动"
      return 0
    fi
    sleep 10
    waited=$((waited + 10))
    have="$(available_memory_gib)"
  done
}

# A rare CUDA fault ends the vLLM engine (the server then exits cleanly), so
# Docker brings the model back on its own instead of leaving the workshop down.
common_args=(
  --restart unless-stopped
  --gpus all
  --network host
  --ipc host
  --ulimit memlock=-1
  --ulimit stack=67108864
  -e HF_HUB_OFFLINE=1
  -e TRANSFORMERS_OFFLINE=1
  -e CUTE_DSL_ARCH=sm_121a
  -e MAX_JOBS=8
  -v "$DEMO_ROOT/models:/models:ro"
  -v "$VLLM_CACHE_ROOT:/root/.cache/vllm"
  -v "$FLASHINFER_WORKSPACE_BASE:/root/.cache/flashinfer"
  -v "$TRITON_CACHE_DIR:/root/.triton"
  -v "$DEMO_WORKSPACE:/demo/workspace:ro"
  --entrypoint bash
)

run_qwen_container() {
  docker run -d --name "$QWEN_CONTAINER" "${common_args[@]}" "$VLLM_IMAGE" -lc \
    "exec vllm serve /models/qwen \
      --served-model-name '$QWEN_MODEL_ID' \
      --host 127.0.0.1 --port '$QWEN_PORT' \
      --tensor-parallel-size 1 \
      --moe-backend flashinfer_b12x \
      --gpu-memory-utilization '$QWEN_START_GATE' \
      --kv-cache-memory-bytes '$QWEN_KV_CACHE' \
      --max-model-len '$QWEN_CONTEXT' \
      --max-num-seqs '$QWEN_MAX_SEQS' \
      --max-num-batched-tokens 8192 \
      --kv-cache-dtype fp8 \
      --attention-backend flashinfer \
      --limit-mm-per-prompt '{\"image\":$QWEN_MAX_IMAGES,\"video\":0}' \
      --mm-processor-kwargs '{\"size\":{\"longest_edge\":$QWEN_MAX_IMAGE_PIXELS,\"shortest_edge\":65536}}' \
      --mm-processor-cache-gb 1 \
      --allowed-local-media-path /demo/workspace \
      --enable-chunked-prefill \
      --enable-prefix-caching \
      --async-scheduling \
      --enable-auto-tool-choice \
      --tool-call-parser qwen3_coder \
      --reasoning-parser qwen3 \
      --trust-remote-code \
      --load-format fastsafetensors" >/dev/null
}

probe_qwen() {
  curl -fsS --max-time 30 "$QWEN_BASE_URL/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"$QWEN_MODEL_ID\",\"messages\":[{\"role\":\"user\",\"content\":\"只回复 OK\"}],\"max_tokens\":8,\"chat_template_kwargs\":{\"enable_thinking\":false}}" |
    grep -q '"choices"'
}

start_qwen() {
  local attempt backend_log
  if container_running "$QWEN_CONTAINER" &&
     curl -fsS --max-time 3 "$QWEN_BASE_URL/models" >/dev/null 2>&1; then
    if probe_qwen; then
      skip "Qwen 已在运行且生成正常: $QWEN_BASE_URL"
      return
    fi
    warn "Qwen API 能列出模型但无法完成最小生成；重启本项目容器清理卡死请求"
    remove_container "$QWEN_CONTAINER"
  fi
  python3 "$HERE/verify-models.py" qwen >/dev/null ||
    die "Qwen 模型不完整，请重新运行 install.sh"
  if container_running "$QWEN_CONTAINER"; then
    info "Qwen 容器正在加载，等待就绪"
  else
    port_is_listening "$QWEN_PORT" &&
      die "端口 $QWEN_PORT 已被其他服务占用；为保护其他 demo，不会自动清理"
    for attempt in 1 2; do
      remove_container "$QWEN_CONTAINER"
      wait_for_memory "$QWEN_NEED_GIB" "Qwen"
      info "启动 Qwen 3.6（视觉+工具调用，上下文 $QWEN_CONTEXT，KV $QWEN_KV_CACHE，首次加载约 3-6 分钟）"
      run_qwen_container
      if wait_model_container "$QWEN_CONTAINER" "$QWEN_BASE_URL" Qwen 1200; then
        break
      fi
      (( attempt == 2 )) && die "Qwen 启动失败，完整日志: docker logs $QWEN_CONTAINER"
      warn "Qwen 首次启动失败，20 秒后重试一次"
      sleep 20
    done
  fi
  wait_model_container "$QWEN_CONTAINER" "$QWEN_BASE_URL" Qwen 1200 ||
    die "Qwen 启动失败，完整日志: docker logs $QWEN_CONTAINER"
  backend_log="$(docker logs "$QWEN_CONTAINER" 2>&1)"
  grep -q "FLASHINFER_B12X.*NvFp4 MoE backend" <<<"$backend_log" ||
    die "Qwen 未实际选中 FLASHINFER_B12X MoE backend"
  probe_qwen || die "Qwen 已启动，但最小生成探针失败"
  ok "Qwen 就绪: $QWEN_BASE_URL"
}

start_nemotron() {
  local backend_log moe_backend="${NEMOTRON_MOE_BACKEND:-flashinfer_cutlass}"
  if container_running "$NEMOTRON_CONTAINER" &&
     curl -fsS --max-time 3 "$NEMOTRON_BASE_URL/models" >/dev/null 2>&1; then
    skip "Nemotron 已在运行: $NEMOTRON_BASE_URL"
    return
  fi
  python3 "$HERE/verify-models.py" nemotron >/dev/null ||
    die "Nemotron 模型不完整，请运行 install.sh --with-nemotron"
  port_is_listening "$NEMOTRON_PORT" &&
    die "端口 $NEMOTRON_PORT 已被其他服务占用；为保护其他 demo，不会自动清理"
  remove_container "$NEMOTRON_CONTAINER"
  wait_for_memory "$NEMOTRON_NEED_GIB" "Nemotron"
  info "启动 Nemotron（上下文 $NEMOTRON_CONTEXT，KV $NEMOTRON_KV_CACHE）"
  docker run -d --name "$NEMOTRON_CONTAINER" "${common_args[@]}" "$VLLM_IMAGE" -lc \
    "exec vllm serve /models/nemotron \
      --served-model-name '$NEMOTRON_MODEL_ID' \
      --host 127.0.0.1 --port '$NEMOTRON_PORT' \
      --tensor-parallel-size 1 \
      --moe-backend '$moe_backend' \
      --gpu-memory-utilization '$NEMOTRON_START_GATE' \
      --kv-cache-memory-bytes '$NEMOTRON_KV_CACHE' \
      --max-model-len '$NEMOTRON_CONTEXT' \
      --max-num-seqs 1 \
      --max-num-batched-tokens 8192 \
      --kv-cache-dtype fp8 \
      --video-pruning-rate 0.5 \
      --limit-mm-per-prompt '{\"video\":0,\"image\":1,\"audio\":0}' \
      --allowed-local-media-path /demo/workspace \
      --enable-prefix-caching \
      --reasoning-parser nemotron_v3 \
      --enable-auto-tool-choice \
      --tool-call-parser qwen3_coder \
      --trust-remote-code \
      --load-format fastsafetensors" >/dev/null
  wait_model_container "$NEMOTRON_CONTAINER" "$NEMOTRON_BASE_URL" Nemotron 1200 ||
    die "Nemotron 启动失败，完整日志: docker logs $NEMOTRON_CONTAINER"
  backend_log="$(docker logs "$NEMOTRON_CONTAINER" 2>&1)"
  grep -q "Using 'FLASHINFER_CUTLASS'.*NvFp4 MoE backend" <<<"$backend_log" ||
    die "Nemotron 未实际选中 FLASHINFER_CUTLASS MoE backend"
  ok "Nemotron 就绪: $NEMOTRON_BASE_URL"
}

status_one() {
  local name="$1" label="$2" url="$3"
  if container_running "$name"; then
    if curl -fsS --max-time 3 "$url/models" >/dev/null 2>&1; then
      ok "$label 运行中 ($(json_model_id "$url"))"
    else
      warn "$label 容器运行中，但 API 尚未就绪"
    fi
  else
    warn "$label 未运行"
  fi
}

case "${1:-status}" in
  image)
    if docker image inspect "$VLLM_IMAGE" >/dev/null 2>&1; then
      skip "vLLM 镜像已存在: $VLLM_IMAGE"
    else
      ensure_image
      ok "vLLM 镜像已导入: $VLLM_IMAGE"
    fi
    ;;
  start)
    ensure_image
    case "${2:-qwen}" in
      qwen)
        remove_container "$NEMOTRON_CONTAINER"
        normalize_cache_permissions
        start_qwen
        ;;
      nemotron|vision)
        remove_container "$QWEN_CONTAINER"
        normalize_cache_permissions
        start_nemotron
        ;;
      *) die "未知模型: ${2:-}（可用 qwen|nemotron）" ;;
    esac
    ;;
  stop)
    remove_container "$NEMOTRON_CONTAINER"
    remove_container "$QWEN_CONTAINER"
    normalize_cache_permissions
    ok "模型服务已停止"
    ;;
  restart)
    "$0" stop
    "$0" start "${2:-qwen}"
    ;;
  status)
    status_one "$QWEN_CONTAINER" Qwen "$QWEN_BASE_URL"
    if container_running "$NEMOTRON_CONTAINER"; then
      status_one "$NEMOTRON_CONTAINER" Nemotron "$NEMOTRON_BASE_URL"
    fi
    ;;
  logs)
    case "${2:-qwen}" in
      qwen) docker logs --tail "${3:-100}" "$QWEN_CONTAINER" ;;
      nemotron|vision) docker logs --tail "${3:-100}" "$NEMOTRON_CONTAINER" ;;
      *) die "日志目标必须是 qwen 或 nemotron" ;;
    esac
    ;;
  *)
    echo "用法: $0 {start [qwen|nemotron]|stop|restart [qwen|nemotron]|status|logs [qwen|nemotron] [N]}" >&2
    exit 2
    ;;
esac
