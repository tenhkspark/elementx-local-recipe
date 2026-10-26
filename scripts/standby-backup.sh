#!/usr/bin/env bash
# standby-backup.sh — daily backup of the Matrix DB to a standby machine.
#
# Primary: HOT backup via an APFS snapshot — the homeserver never stops
# (macOS only; the running RocksDB files are copied from a point-in-time
# snapshot, which is safe to rsync).
# Fallback: COLD copy — docker stop -> rsync -> docker start (a ~30s outage;
# a trap guarantees the container comes back up).
#
# Run from launchd/systemd daily. On Linux, use the cold-copy path or
# `rocksdb checkpoint` instead of APFS snapshots.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
DB_DIR="$HERE/db"
DST="${STANDBY_DST:?set STANDBY_DST, e.g. user@standby-host:/home/user/matrix-standby/}"
LOG="${LOG:-$HERE/standby-backup.log}"
MNT="/tmp/.matrix-snapshot"

say()  { echo "$(date '+%F %H:%M:%S') $*" >> "$LOG"; }
fail() { say "FAIL: $*"; }

hot_backup() {
  local out snap_date snap_name
  out=$(tmutil localsnapshot /System/Volumes/Data 2>&1) || { say "snapshot unavailable: $out"; return 1; }
  snap_date=$(printf %s "$out" | grep -oE "[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}" | tail -1)
  [ -n "$snap_date" ] || { say "snapshot unavailable: $out"; return 1; }
  snap_name="com.apple.TimeMachine.$snap_date.local"
  say "snapshot: $snap_name"
  mkdir -p "$MNT"
  mount_apfs -s "$snap_name" /System/Volumes/Data "$MNT" >> "$LOG" 2>&1 || { say "mount_apfs failed"; tmutil deletelocalsnapshots "$snap_date" >/dev/null 2>&1; return 1; }
  rsync -a --delete "$MNT$DB_DIR/" "$DST" >> "$LOG" 2>&1 \
    || { umount "$MNT" >/dev/null 2>&1; say "rsync from snapshot failed"; return 1; }
  umount "$MNT" >/dev/null 2>&1
  tmutil deletelocalsnapshots "$snap_date" >/dev/null 2>&1
  return 0
}

cold_backup() {
  local STOPPED=0
  restore() { [ "$STOPPED" = 1 ] && docker start "$CONTAINER" >> "$LOG" 2>&1; }
  trap restore EXIT
  CONTAINER="${CONTAINER:-matrix-server}"
  say "cold copy mode"
  docker stop "$CONTAINER" >> "$LOG" 2>&1 && STOPPED=1 || { fail "docker stop"; return 1; }
  rsync -a --delete "$DB_DIR/" "$DST" >> "$LOG" 2>&1 || { fail "rsync"; return 1; }
  restore; STOPPED=0; trap - EXIT
  sleep 3
  return 0
}

post_check() {
  curl -sf -m8 http://127.0.0.1:8008/_matrix/client/versions >/dev/null || { fail "matrix-server not answering"; return 1; }
  return 0
}

say "start"
if hot_backup && post_check; then
  say "ok: standby synced from snapshot, matrix-server untouched"
  exit 0
fi
say "hot mode unavailable — falling back to cold copy"
cold_backup || exit 1
post_check || exit 1
say "ok: standby synced (cold copy), matrix-server back up"
