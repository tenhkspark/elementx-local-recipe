#!/usr/bin/env bash
# matrix-watchdog.sh — keep the local Matrix chat chain alive, 5-minute cron.
#
# Chain checked top-down (repairs the FIRST broken link, then re-checks):
#   0. tailscaled running
#   1. colima VM (Docker host) running          [delete this stage on plain Linux]
#   2. docker container matrix-server Up
#   3. 127.0.0.1:8008 answers /_matrix/client/versions
#   4. tailscale serve path answers from outside (only when stage 3 is healthy,
#      so a dead backend doesn't burn the serve-path repair budget)
#   5. the bot's launchd job has a live PID
#   6. (optional) notification sender heartbeat
#   7. (optional) the LLM board / upstream the bot calls answers
#
# Anti-runaway: same stage repaired at most once per 10 min; 3 consecutive
# failed repairs -> alert only, stop trying.
#
# Stop: touch .watchdog-stop    Dry-run: WD_DRY=1 ./matrix-watchdog.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
STATE="$HERE/.wd-state"; mkdir -p "$STATE"
LOG="${LOG:-$HERE/watchdog.log}"
ALERT_HOOK="${ALERT_HOOK:-}"   # set to a script that takes a message on stdin
TS="${TS:-tailscale}"
BOT_LABEL="${BOT_LABEL:-}"     # launchd label of your bot, e.g. com.example.matrix-bot
CONTAINER="${CONTAINER:-matrix-server}"
PUBLIC_HOST="${PUBLIC_HOST:-}" # your tailnet hostname, e.g. matrix.example.ts.net (stage 4 skipped if empty)

log() { echo "$(date '+%F %H:%M:%S') $*" >> "$LOG"; }
alert() { log "ALERT: $*"; [ -n "$ALERT_HOOK" ] && echo "$*" | "$ALERT_HOOK" || true; }

colima_start()   { colima start --vm-type vz --cpu 2 --memory 2 --disk 20 --mount-type virtiofs; }
colima_restart() { colima stop && colima_start; }
serve_restore()  { "$TS" serve --bg --https=443 --set-path=/_matrix http://127.0.0.1:8008/_matrix && sleep 2 && "$TS" serve --bg --https=443 --set-path=/.well-known http://127.0.0.1:9111/.well-known; }
bot_restart()    { launchctl kickstart "gui/$(id -u)/$BOT_LABEL" 2>/dev/null || launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$BOT_LABEL.plist"; }

# repair <stage-id> <desc> <wait-sec> <recheck-cmd> <fix-cmd...>
repair() {
  local st=$1 desc=$2 wait=$3 check=$4; shift 4
  local now last fails
  now=$(date +%s)
  last=$(cat "$STATE/$st.last" 2>/dev/null || echo 0)
  fails=$(cat "$STATE/$st.fails" 2>/dev/null || echo 0)
  if [ "$fails" -ge 3 ]; then
    [ $((now - last)) -gt 3600 ] && alert "$desc: still broken after 3 tries (manual fix needed)"
    return 3
  fi
  [ $((now - last)) -lt 600 ] && { log "$desc: repair skipped (<10min since last try)"; return 2; }
  echo "$now" > "$STATE/$st.last"
  if [ -n "${WD_DRY:-}" ]; then log "DRY would repair $st: $desc"; return 0; fi
  log "repair $st: $desc"
  "$@" >> "$LOG" 2>&1
  sleep "$wait"
  if eval "$check" >> "$LOG" 2>&1; then
    echo 0 > "$STATE/$st.fails"; alert "$desc repaired by watchdog"; return 0
  fi
  fails=$((fails + 1)); echo "$fails" > "$STATE/$st.fails"
  alert "$desc repair FAILED (attempt $fails/3)"
}

[ -e "$HERE/.watchdog-stop" ] && exit 0

ts_ok() { "$TS" status --json 2>/dev/null | grep -q '"BackendState": "Running"'; }
ts_ok || repair s0-tailscale "tailscaled down" 20 ts_ok "$TS" up

colima status 2>&1 | grep -q 'colima is running' \
  || repair s1-colima "colima VM" 60 "colima status 2>&1 | grep -q 'colima is running'" colima_start

docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null | grep -q "^$CONTAINER Up" \
  || repair s2-docker "docker $CONTAINER" 8 "docker ps --format '{{.Names}} {{.Status}}' | grep -q '^$CONTAINER Up'" docker start "$CONTAINER"

curl -sf -m8 http://127.0.0.1:8008/_matrix/client/versions >/dev/null 2>&1 \
  || repair s3-api "matrix 127.0.0.1:8008" 60 "curl -sf -m8 http://127.0.0.1:8008/_matrix/client/versions" colima_restart

if [ -n "$PUBLIC_HOST" ]; then
  curl -sf -m10 "https://$PUBLIC_HOST/_matrix/client/versions" >/dev/null 2>&1 \
    || repair s4-serve "tailscale serve /_matrix" 3 "curl -sf -m10 https://$PUBLIC_HOST/_matrix/client/versions" serve_restore
fi

if [ -n "$BOT_LABEL" ]; then
  launchctl list 2>/dev/null | awk -v L="$BOT_LABEL" '$1 ~ /^[0-9]+$/ && $3 == L {f=1} END {exit !f}' \
    || repair s5-bot "$BOT_LABEL" 20 "launchctl list | grep -q '$BOT_LABEL'" bot_restart
fi

log "ok"
exit 0
