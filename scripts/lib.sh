#!/usr/bin/env bash
set -o pipefail

SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../env.sh
source "$SCRIPT_LIB_DIR/../env.sh"

if [[ -t 1 ]]; then
  C_BLUE=$'\033[36m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_BOLD=""; C_RESET=""
fi

section() { printf '\n%s== %s ==%s\n' "$C_BOLD" "$*" "$C_RESET"; }
info()    { printf '%s[信息]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()      { printf '%s[正常]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
skip()    { printf '%s[跳过]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()    { printf '%s[警告]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()     { printf '%s[错误]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

lan_ip() {
  ip -4 route get 1.1.1.1 2>/dev/null |
    awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}'
}

# Reads the kernel socket table directly so no extra tool is required.
port_is_listening() {
  local hex
  printf -v hex ':%04X' "$1"
  awk -v p="$hex" '
    FNR > 1 && $4 == "0A" && substr($2, length($2) - 4) == p { found = 1 }
    END { exit !found }
  ' /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

wait_http() {
  local url="$1" timeout="${2:-180}" label="${3:-服务}"
  local started now
  started="$(date +%s)"
  while ! curl -fsS --max-time 3 "$url" >/dev/null 2>&1; do
    now="$(date +%s)"
    if (( now - started >= timeout )); then
      warn "$label 在 ${timeout}s 内未就绪: $url"
      return 1
    fi
    sleep 2
  done
}

read_pid() {
  local name="$1" file
  file="$DEMO_RUNTIME/pids/$name.pid"
  [[ -s "$file" ]] && cat "$file"
}

pid_is_running() {
  local pid="${1:-}"
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null
}

pid_is_owned() {
  local pid="$1" executable=""
  if { tr '\0' ' ' < "/proc/$pid/cmdline"; } 2>/dev/null | grep -Fq "$DEMO_ROOT"; then
    return 0
  fi
  executable="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
  [[ "$executable" == "$DEMO_ROOT/"* ]]
}

stop_pidfile() {
  local name="$1" pid file
  file="$DEMO_RUNTIME/pids/$name.pid"
  pid="$(read_pid "$name" || true)"
  if pid_is_running "$pid"; then
    if ! pid_is_owned "$pid"; then
      warn "PID $pid 不属于本 demo，拒绝停止"
      rm -f "$file"
      return 0
    fi
    kill "$pid" 2>/dev/null || true
    for _ in {1..10}; do
      pid_is_running "$pid" || break
      sleep 1
    done
    pid_is_running "$pid" && kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$file"
}

# For services started with setsid: stop the whole process group, because
# wrappers such as `sg` fork the real program as a child.
stop_group_pidfile() {
  local name="$1" pid file
  file="$DEMO_RUNTIME/pids/$name.pid"
  pid="$(read_pid "$name" || true)"
  if pid_is_running "$pid"; then
    if ! pid_is_owned "$pid"; then
      warn "PID $pid 不属于本 demo，拒绝停止"
      rm -f "$file"
      return 0
    fi
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    for _ in {1..15}; do
      kill -0 -- "-$pid" 2>/dev/null || break
      sleep 1
    done
    kill -KILL -- "-$pid" 2>/dev/null || true
  fi
  rm -f "$file"
}

_ancestor_pids() {
  local pid=$$
  while [[ "$pid" =~ ^[0-9]+$ ]] && (( pid > 1 )); do
    printf '%s\n' "$pid"
    pid="$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null || true)"
  done
}

# Processes a participant's OpenClaw session left behind: anything spawned by
# this bundle's exec tool (OpenClaw marks those with OPENCLAW_SHELL=exec) and
# the managed Chromium that lives under this bundle's OpenClaw state.
kill_participant_processes() {
  local dir pid ancestors targets=() env
  ancestors=" $(_ancestor_pids | tr '\n' ' ') "
  for dir in /proc/[0-9]*; do
    pid="${dir#/proc/}"
    [[ -O "$dir" ]] || continue
    [[ "$ancestors" == *" $pid "* ]] && continue
    if { tr '\0' ' ' < "$dir/cmdline"; } 2>/dev/null | grep -Fq "$OPENCLAW_HOME/"; then
      targets+=("$pid")
      continue
    fi
    env="$({ tr '\0' '\n' < "$dir/environ"; } 2>/dev/null || true)"
    if grep -qx 'OPENCLAW_SHELL=exec' <<<"$env" && grep -qxF "DEMO_ROOT=$DEMO_ROOT" <<<"$env"; then
      targets+=("$pid")
    fi
  done
  (( ${#targets[@]} )) || return 0
  info "结束上一位体验者留下的 ${#targets[@]} 个进程"
  kill -TERM "${targets[@]}" 2>/dev/null || true
  sleep 2
  for pid in "${targets[@]}"; do
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
  done
}

json_model_id() {
  local url="$1"
  curl -fsS --max-time 5 "$url/models" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])'
}

# direct: this shell already has the video group; sg: the account was added
# to the group after login, so `sg video` can pick it up; none: not a member.
video_group_mode() {
  local user
  user="$(id -un)"
  if id -nG | tr ' ' '\n' | grep -qx video; then
    echo direct
  elif getent group video | cut -d: -f4 | tr ',' '\n' | grep -qx "$user"; then
    echo sg
  else
    echo none
  fi
}

container_running() {
  docker ps --filter "name=^${1}$" --format '{{.Names}}' | grep -qx "$1"
}

# GiB of memory the kernel can hand out right now (unified CPU/GPU memory).
available_memory_gib() {
  awk '/^MemAvailable:/ {printf "%d", $2 / 1024 / 1024}' /proc/meminfo
}
