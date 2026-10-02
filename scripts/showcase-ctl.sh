#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

LOG="$DEMO_LOGS/showcase.log"
PID_FILE="$DEMO_RUNTIME/pids/showcase.pid"

stop_apps() {
  local file name
  shopt -s nullglob
  for file in "$DEMO_RUNTIME/pids"/app-*.pid; do
    name="$(basename "$file" .pid)"
    stop_group_pidfile "$name"
  done
  shopt -u nullglob
}

case "${1:-status}" in
  start)
    pid="$(read_pid showcase || true)"
    if pid_is_running "$pid" && port_is_listening "$SHOWCASE_PORT"; then
      ok "演示查看器已运行"
      exit 0
    fi
    port_is_listening "$SHOWCASE_PORT" &&
      die "端口 $SHOWCASE_PORT 已被其他服务占用；不会影响或清理它"
    if [[ "$(video_group_mode)" == "sg" ]]; then
      setsid sg video -c "exec /usr/bin/python3 '$DEMO_ROOT/showcase/server.py'" \
        </dev/null >"$LOG" 2>&1 &
    else
      setsid /usr/bin/python3 "$DEMO_ROOT/showcase/server.py" </dev/null >"$LOG" 2>&1 &
    fi
    echo "$!" > "$PID_FILE"
    wait_http "http://127.0.0.1:$SHOWCASE_PORT/api/health" 20 "演示查看器" || {
      cat "$LOG" >&2
      exit 1
    }
    ok "演示查看器: http://127.0.0.1:$SHOWCASE_PORT/"
    ;;
  stop)
    stop_apps
    stop_group_pidfile showcase
    ok "演示查看器已停止"
    ;;
  restart)
    "$0" stop
    "$0" start
    ;;
  status)
    if curl -fsS --max-time 2 "http://127.0.0.1:$SHOWCASE_PORT/api/health" >/dev/null; then
      ok "演示查看器运行中 (:$SHOWCASE_PORT)"
    else
      warn "演示查看器未运行"
      exit 1
    fi
    ;;
  logs) tail -n "${2:-100}" "$LOG" ;;
  *)
    echo "用法: $0 {start|stop|restart|status|logs [N]}" >&2
    exit 2
    ;;
esac

