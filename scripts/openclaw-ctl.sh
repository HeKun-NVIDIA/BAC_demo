#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

LOG="$DEMO_LOGS/openclaw.log"
CONFIG="$OPENCLAW_HOME/.openclaw/openclaw.json"
TOKEN_FILE="$DEMO_ROOT/openclaw/.secrets/gateway-token"

# Refresh the parts of the config that depend on the current network.
configure_access() {
  local mode="$1" ip="" host
  [[ -f "$CONFIG" ]] || die "OpenClaw 尚未初始化，请运行 install.sh"
  host="$(hostname)"
  [[ "$mode" == "lan" ]] && ip="$(lan_ip)"
  python3 - "$CONFIG" "$mode" "$ip" "$host" "$OPENCLAW_PORT" <<'PY'
import json, pathlib, sys
path, mode, ip, host, port = pathlib.Path(sys.argv[1]), *sys.argv[2:]
data = json.loads(path.read_text(encoding="utf-8"))
origins = [f"http://localhost:{port}", f"http://127.0.0.1:{port}"]
browser_hosts = ["127.0.0.1", "localhost"]
if mode == "lan":
    data["gateway"]["bind"] = "lan"
    for name in (ip, host, f"{host}.local"):
        if name:
            origins.append(f"http://{name}:{port}")
    if ip:
        browser_hosts.append(ip)
else:
    data["gateway"]["bind"] = "loopback"
data["gateway"].setdefault("controlUi", {})["allowedOrigins"] = origins
data.setdefault("browser", {}).setdefault("ssrfPolicy", {})["allowedHostnames"] = browser_hosts
path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
}

gateway_running() {
  local pid
  pid="$(read_pid openclaw || true)"
  pid_is_running "$pid" && port_is_listening "$OPENCLAW_PORT"
}

start_watcher() {
  local pid
  pid="$(read_pid pairing-watch || true)"
  pid_is_running "$pid" && return 0
  setsid "$HERE/pairing-watch.sh" </dev/null >>"$DEMO_LOGS/pairing-watch.log" 2>&1 &
  echo "$!" > "$DEMO_RUNTIME/pids/pairing-watch.pid"
}

start_gateway() {
  local mode="${1:-lan}"
  [[ "$mode" == "local" || "$mode" == "lan" ]] || die "访问模式必须是 local 或 lan"
  if gateway_running; then
    skip "OpenClaw 已运行"
    [[ "$mode" == "lan" ]] && start_watcher
    return
  fi
  port_is_listening "$OPENCLAW_PORT" &&
    die "端口 $OPENCLAW_PORT 已被其他服务占用；不会影响或清理它"
  [[ -x "$OPENCLAW_BIN" ]] || die "缺少 $OPENCLAW_BIN，请运行 install.sh"
  configure_access "$mode"
  curl -fsS --max-time 3 "$QWEN_BASE_URL/models" >/dev/null 2>&1 ||
    warn "Qwen API 尚未就绪，Gateway 可启动但暂时不能对话"

  # Tool-launched programs (the camera demo) inherit the gateway's groups.
  local launcher=()
  case "$(video_group_mode)" in
    direct) ;;
    sg) launcher=(sg video -c "exec '$OPENCLAW_BIN' gateway run") ;;
    none) warn "当前用户不在 video 组，摄像头 demo 将无法打开 /dev/video0（执行一次: sudo usermod -aG video $(id -un)）" ;;
  esac
  : > "$LOG"
  if (( ${#launcher[@]} )); then
    setsid "${launcher[@]}" </dev/null >>"$LOG" 2>&1 &
  else
    setsid "$OPENCLAW_BIN" gateway run </dev/null >>"$LOG" 2>&1 &
  fi
  echo "$!" > "$DEMO_RUNTIME/pids/openclaw.pid"
  if ! wait_http "http://127.0.0.1:$OPENCLAW_PORT/" 90 "OpenClaw"; then
    tail -60 "$LOG" >&2 || true
    return 1
  fi
  [[ "$mode" == "lan" ]] && start_watcher
  ok "OpenClaw Gateway 就绪（${mode}）"
}

stop_gateway() {
  stop_group_pidfile pairing-watch
  stop_group_pidfile openclaw
  kill_participant_processes
}

show_urls() {
  local token ip
  [[ -s "$TOKEN_FILE" ]] || die "token 不存在，请运行 install.sh"
  token="$(cat "$TOKEN_FILE")"
  ip="$(lan_ip)"
  printf '  本机浏览器:   http://localhost:%s/#token=%s\n' "$OPENCLAW_PORT" "$token"
  if [[ -n "$ip" ]]; then
    printf '  局域网浏览器: http://%s:%s/#token=%s\n' "$ip" "$OPENCLAW_PORT" "$token"
  fi
}

case "${1:-status}" in
  start) start_gateway "${2:-lan}" ;;
  stop)
    stop_gateway
    ok "OpenClaw 已停止"
    ;;
  restart)
    stop_gateway
    start_gateway "${2:-lan}"
    ;;
  status)
    if gateway_running; then
      ok "OpenClaw 运行中 (PID $(read_pid openclaw), :$OPENCLAW_PORT)"
    else
      warn "OpenClaw 未运行"
      exit 1
    fi
    ;;
  logs) tail -n "${2:-100}" "$LOG" ;;
  urls) show_urls ;;
  *)
    echo "用法: $0 {start [lan|local]|stop|restart [lan|local]|status|logs [N]|urls}" >&2
    exit 2
    ;;
esac
