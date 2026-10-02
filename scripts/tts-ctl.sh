#!/usr/bin/env bash
# Local Qwen3-TTS speech server (OpenAI-compatible /v1/audio/speech).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

TTS_CONTAINER="dgx-demo-tts"
TTS_VENV="$DEMO_RUNTIME/tts-venv"

start_tts() {
  if container_running "$TTS_CONTAINER" &&
     curl -fsS --max-time 3 "http://127.0.0.1:$TTS_PORT/health" >/dev/null 2>&1; then
    skip "Qwen3-TTS 已在运行: http://127.0.0.1:$TTS_PORT"
    return
  fi
  [[ -x "$TTS_VENV/bin/python" ]] || die "缺少 TTS 运行环境，请重新运行 install.sh"
  [[ -s "$TTS_MODEL_DIR/model.safetensors" ]] || die "缺少 Qwen3-TTS 模型，请重新运行 install.sh"
  docker image inspect "$VLLM_IMAGE" >/dev/null 2>&1 || die "缺少 vLLM 镜像，请重新运行 install.sh"
  if ! container_running "$TTS_CONTAINER"; then
    port_is_listening "$TTS_PORT" &&
      die "端口 $TTS_PORT 已被其他服务占用；为保护其他 demo，不会自动清理"
    docker rm -f "$TTS_CONTAINER" >/dev/null 2>&1 || true
    info "启动 Qwen3-TTS 语音服务（约 1 分钟）"
    docker run -d --name "$TTS_CONTAINER" --restart unless-stopped \
      --gpus all --network host --ipc host \
      --user "$(id -u):$(id -g)" \
      -e HOME=/tmp -e NUMBA_CACHE_DIR=/tmp -e PYTHONUNBUFFERED=1 \
      -e HF_HUB_OFFLINE=1 -e TRANSFORMERS_OFFLINE=1 \
      -e TTS_PORT="$TTS_PORT" -e TTS_MODEL_DIR=/models/qwen3-tts \
      -v "$TTS_MODEL_DIR:/models/qwen3-tts:ro" \
      -v "$TTS_VENV:/demo/runtime/tts-venv:ro" \
      -v "$DEMO_ROOT/services/tts:/demo/services/tts:ro" \
      --entrypoint /demo/runtime/tts-venv/bin/python \
      "$VLLM_IMAGE" /demo/services/tts/tts_server.py >/dev/null
  fi
  local started
  started="$(date +%s)"
  while ! curl -fsS --max-time 3 "http://127.0.0.1:$TTS_PORT/health" >/dev/null 2>&1; do
    if ! container_running "$TTS_CONTAINER"; then
      docker logs --tail 60 "$TTS_CONTAINER" >&2 || true
      die "Qwen3-TTS 容器已退出"
    fi
    if (( $(date +%s) - started > 600 )); then
      docker logs --tail 60 "$TTS_CONTAINER" >&2 || true
      die "Qwen3-TTS 在 600s 内未就绪"
    fi
    sleep 3
  done
  ok "Qwen3-TTS 就绪: http://127.0.0.1:$TTS_PORT/v1/audio/speech"
}

case "${1:-status}" in
  start) start_tts ;;
  stop)
    docker rm -f "$TTS_CONTAINER" >/dev/null 2>&1 || true
    ok "Qwen3-TTS 已停止"
    ;;
  restart)
    "$0" stop
    start_tts
    ;;
  status)
    if curl -fsS --max-time 3 "http://127.0.0.1:$TTS_PORT/health" >/dev/null 2>&1; then
      ok "Qwen3-TTS 运行中 (:$TTS_PORT)"
    else
      warn "Qwen3-TTS 未运行"
      exit 1
    fi
    ;;
  logs) docker logs --tail "${2:-100}" "$TTS_CONTAINER" ;;
  say)
    shift
    text="${*:-你好，我是运行在 DGX Spark 上的本地语音模型。}"
    out="$DEMO_RUNTIME/tmp/tts-test.wav"
    python3 - "$text" "$TTS_PORT" "$out" <<'PY'
import json, sys, urllib.request
text, port, out = sys.argv[1], sys.argv[2], sys.argv[3]
req = urllib.request.Request(
    f"http://127.0.0.1:{port}/v1/audio/speech",
    data=json.dumps({"model": "qwen3-tts", "input": text, "voice": "vivian",
                     "response_format": "wav"}).encode(),
    headers={"Content-Type": "application/json"}, method="POST")
with urllib.request.urlopen(req, timeout=300) as resp:
    open(out, "wb").write(resp.read())
print(out)
PY
    ;;
  *)
    echo "用法: $0 {start|stop|restart|status|logs [N]|say [文本]}" >&2
    exit 2
    ;;
esac
