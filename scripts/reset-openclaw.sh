#!/usr/bin/env bash
# Gives the next workshop participant a fresh OpenClaw: stops the gateway and
# whatever the last session started, wipes sessions, paired devices, memory,
# browser profile and workspace, then renders config + workspace from the
# templates. Models, containers and installed programs are untouched.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

TEMPLATE_DIR="$DEMO_ROOT/openclaw/workspace-template"
CONFIG_TEMPLATE="$DEMO_ROOT/openclaw/config/openclaw.template.json"
CONFIG_TARGET="$OPENCLAW_HOME/.openclaw/openclaw.json"
TOKEN_FILE="$DEMO_ROOT/openclaw/.secrets/gateway-token"

rotate_token=0
[[ "${1:-}" == "--rotate-token" ]] && rotate_token=1

"$HERE/openclaw-ctl.sh" stop >/dev/null 2>&1 || true
kill_participant_processes

[[ "$OPENCLAW_HOME" == "$DEMO_ROOT/"* && "$DEMO_WORKSPACE" == "$DEMO_ROOT/"* ]] ||
  die "路径异常，拒绝清理: $OPENCLAW_HOME / $DEMO_WORKSPACE"
chmod -R u+w "$DEMO_WORKSPACE" 2>/dev/null || true
rm -rf "$OPENCLAW_HOME" "$DEMO_WORKSPACE" \
  "$DEMO_RUNTIME/config" "$DEMO_RUNTIME/data" "$DEMO_RUNTIME/tmp"
find "$DEMO_OUTPUTS" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
rm -rf "$DEMO_ROOT/showcase/sandbox-data"
mkdir -p "$OPENCLAW_HOME/.openclaw" "$DEMO_RUNTIME/config" "$DEMO_RUNTIME/data" "$DEMO_RUNTIME/tmp"

ip="$(lan_ip)"
cp -a "$TEMPLATE_DIR" "$DEMO_WORKSPACE"
mkdir -p "$DEMO_WORKSPACE/demos"
python3 - "$DEMO_WORKSPACE" "${ip:-127.0.0.1}" "$SHOWCASE_PORT" "$DEMO_ROOT" <<'PY'
import pathlib, sys

workspace, lan_ip, showcase_port, demo_root = sys.argv[1:]
for path in pathlib.Path(workspace).rglob("*.md"):
    text = path.read_text(encoding="utf-8")
    text = text.replace("{{LAN_IP}}", lan_ip)
    text = text.replace("{{SHOWCASE_PORT}}", showcase_port)
    text = text.replace("{{DEMO_ROOT}}", demo_root)
    path.write_text(text, encoding="utf-8")
PY

mkdir -p "$(dirname "$TOKEN_FILE")"
if (( rotate_token )) || [[ ! -s "$TOKEN_FILE" ]]; then
  python3 -c 'import secrets; print(secrets.token_urlsafe(32))' > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
fi

python3 - "$CONFIG_TEMPLATE" "$CONFIG_TARGET" "$TOKEN_FILE" "$DEMO_WORKSPACE" \
  "$CHROMIUM_BIN" "$OPENCLAW_PORT" "$QWEN_PORT" "$TTS_PORT" <<'PY'
import json, pathlib, sys
template, target, token_file, workspace, chromium = sys.argv[1:6]
gateway_port, qwen_port, tts_port = map(int, sys.argv[6:9])
raw = pathlib.Path(template).read_text(encoding="utf-8")
raw = raw.replace("__GATEWAY_TOKEN__", pathlib.Path(token_file).read_text().strip())
raw = raw.replace("__WORKSPACE__", workspace)
raw = raw.replace("__CHROMIUM_BIN__", chromium)
raw = raw.replace("__WORKSHOP_PLUGIN__", str(pathlib.Path(workspace).parent / "openclaw/plugins/workshop-agent"))
data = json.loads(raw)
data["gateway"]["port"] = gateway_port
data["models"]["providers"]["qwen-local"]["baseUrl"] = f"http://127.0.0.1:{qwen_port}/v1"
data["tts"]["providers"]["openai"]["baseUrl"] = f"http://127.0.0.1:{tts_port}/v1"
out = pathlib.Path(target)
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
PY

cat > "$DEMO_RUNTIME/ports.env" <<EOF
QWEN_PORT=$QWEN_PORT
NEMOTRON_PORT=$NEMOTRON_PORT
TTS_PORT=$TTS_PORT
OPENCLAW_PORT=$OPENCLAW_PORT
SHOWCASE_PORT=$SHOWCASE_PORT
EOF

"$OPENCLAW_BIN" config validate >/dev/null || die "OpenClaw 配置校验失败: $CONFIG_TARGET"
"$OPENCLAW_BIN" plugins install \
  --link "$DEMO_ROOT/openclaw/plugins/workshop-agent" \
  --force --accept-capabilities >/dev/null ||
  die "Workshop Agent 插件安装失败"
ok "OpenClaw 已重置（会话、设备配对、记忆、浏览器资料、工作区均为全新）"
