#!/usr/bin/env bash
# Workshop helper: approves Control UI pairing requests from LAN browsers.
# Only requests that already passed gateway token auth (phase=auth_validated)
# and ask for the operator role are approved, so the token stays the gate.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

LOG="$DEMO_LOGS/openclaw.log"
touch "$LOG"

pending_role() {
  "$OPENCLAW_BIN" devices list --json 2>/dev/null | python3 -c '
import json, sys
wanted = sys.argv[1]
data = json.load(sys.stdin)
for item in data.get("pending", []):
    if item.get("requestId") == wanted:
        roles = item.get("roles") or [item.get("role")]
        print(",".join(r for r in roles if r))
' "$1"
}

declare -A handled=()
tail -n0 -F "$LOG" 2>/dev/null | while IFS= read -r line; do
  [[ "$line" == *"pairing required"*"phase=auth_validated"* ]] || continue
  request_id="$(grep -oE 'requestId: [0-9a-f-]{36}' <<<"$line" | awk '{print $2}')"
  [[ -n "$request_id" && -z "${handled[$request_id]:-}" ]] || continue
  handled[$request_id]=1
  role="$(pending_role "$request_id")"
  if [[ "$role" != "operator" ]]; then
    echo "$(date '+%F %T') skip $request_id role=${role:-unknown}"
    continue
  fi
  if "$OPENCLAW_BIN" devices approve "$request_id" >/dev/null 2>&1; then
    echo "$(date '+%F %T') approved $request_id"
  else
    echo "$(date '+%F %T') approve failed $request_id"
    unset "handled[$request_id]"
  fi
done
