#!/usr/bin/env bash
# Quick end-to-end checks of every service a participant will touch.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

failures=0
check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$label"; else warn "$label 失败"; failures=$((failures + 1)); fi
}

qwen_chat() {
  curl -fsS --max-time 60 "$QWEN_BASE_URL/chat/completions" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$QWEN_MODEL_ID\",\"messages\":[{\"role\":\"user\",\"content\":\"只回复 OK\"}],\"max_tokens\":8,\"chat_template_kwargs\":{\"enable_thinking\":false}}" |
    grep -q '"choices"'
}
qwen_vision() {
  "$DEMO_PYENV/bin/python" - "$DEMO_WORKSPACE/samples/street-park.png" "$QWEN_BASE_URL" "$QWEN_MODEL_ID" <<'PY'
import base64, io, json, sys, urllib.request
from PIL import Image

image = Image.open(sys.argv[1]).convert("RGB")
image.thumbnail((640, 640))
buffer = io.BytesIO()
image.save(buffer, "JPEG", quality=80)
payload = {
    "model": sys.argv[3],
    "messages": [{"role": "user", "content": [
        {"type": "image_url", "image_url": {
            "url": "data:image/jpeg;base64," + base64.b64encode(buffer.getvalue()).decode()
        }},
        {"type": "text", "text": "只回答图中有几个人。"},
    ]}],
    "max_tokens": 32,
    "chat_template_kwargs": {"enable_thinking": False},
}
request = urllib.request.Request(
    sys.argv[2] + "/chat/completions",
    data=json.dumps(payload).encode(),
    headers={"Content-Type": "application/json"},
)
with urllib.request.urlopen(request, timeout=120) as response:
    result = json.load(response)
assert result.get("choices")
PY
}
tts_speech() {
  curl -fsS --max-time 120 "http://127.0.0.1:$SHOWCASE_PORT/api/tts/v1/audio/speech" \
    -H 'Content-Type: application/json' -d '{"input":"你好","voice":"vivian"}' -o "$DEMO_RUNTIME/tmp/selftest.wav" &&
    [[ "$(head -c 4 "$DEMO_RUNTIME/tmp/selftest.wav")" == "RIFF" ]]
}
workshop_agent() {
  "$OPENCLAW_BIN" plugins list --json | python3 -c '
import json, sys
plugin = next(p for p in json.load(sys.stdin)["plugins"] if p["id"] == "workshop-agent")
assert plugin["status"] == "loaded"
assert plugin.get("trust", {}).get("reason") == "origin-path"
'
}
browser_nvidia() {
  "$OPENCLAW_BIN" browser open "https://developer.nvidia.com/cuda/toolkit" --json |
    grep -q '"url": "https://developer.nvidia.com/'
}

check "Qwen 对话" qwen_chat
check "Qwen 看图" qwen_vision
check "网页调用大模型代理 /api/llm" curl -fsS --max-time 10 "http://127.0.0.1:$SHOWCASE_PORT/api/llm/v1/models"
check "网页调用语音代理 /api/tts（合成一句）" tts_speech
check "Three.js 本地资源" curl -fsS --max-time 5 "http://127.0.0.1:$SHOWCASE_PORT/vendor/three/build/three.module.js"
check "Phaser 本地资源" curl -fsS --max-time 5 -o /dev/null "http://127.0.0.1:$SHOWCASE_PORT/vendor/phaser/dist/phaser.min.js"
check "OpenClaw 页面检查器" test -f "$DEMO_ROOT/openclaw/tools/page-check.mjs"
check "演示检查工具" test -x "$DEMO_ROOT/scripts/workshop-check-page"
check "演示工程" bash -c 'for n in pong platformer kart3d spark3d breathe voice; do test -s "$0/openclaw/demo-templates/$n/index.html" || exit 1; done; test -s "$0/openclaw/demo-templates/camera/camera_server.py" && test -x "$0/scripts/new-project"' "$DEMO_ROOT"
check "体验者服务托管器" curl -fsS --max-time 5 "http://127.0.0.1:$SHOWCASE_PORT/api/services/selftest"
check "OpenClaw Gateway" curl -fsS --max-time 5 "http://127.0.0.1:$OPENCLAW_PORT/"
check "Chromium" "$CHROMIUM_BIN" --version
check "Workshop 输出保护插件" workshop_agent
check "OpenClaw 真实浏览器访问 NVIDIA" browser_nvidia
check "Python 应用环境（OpenCV/Flask）" "$DEMO_PYENV/bin/python" -c 'import cv2, flask'
check "OpenClaw 配置" "$OPENCLAW_BIN" config validate
check "目录隔离边界" python3 "$HERE/isolation-check.py"

if [[ ! -e /dev/video0 ]]; then
  warn "未检测到 USB 摄像头 /dev/video0（Demo 5 需要摄像头）"
elif [[ "$(video_group_mode)" == "none" ]]; then
  warn "摄像头已接入，但当前用户不在 video 组；Demo 5 前请执行一次: sudo usermod -aG video $(id -un)，然后重新运行 ./install.sh"
else
  ok "USB 摄像头 /dev/video0 可用（$(video_group_mode)）"
fi

if curl -fsS --max-time 15 \
  "https://docs.nvidia.com/cuda/cuda-toolkit-release-notes/index.html" \
  >/dev/null 2>&1; then
  ok "NVIDIA CUDA Release Notes 可访问（Demo 7）"
else
  warn "NVIDIA CUDA Release Notes 当前不可访问；其余 demo 不受影响，Demo 7 需要联网"
fi

(( failures == 0 )) || die "$failures 项自检失败，请查看上方提示"
