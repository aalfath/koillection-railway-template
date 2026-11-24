#!/bin/bash
# Mirrors /uploads to the Railway Bucket file by file (never a whole-tree "sync",
# so an older container can't delete files a newer one wrote).
# Changes are batched every 2 s; a full copy (no deletes) runs every 10 minutes.
set -uo pipefail
Q=/tmp/uploads-sync.queue
: > "$Q"
log() { echo "[uploads-sync] $*"; }

inotifywait -m -r -q -e close_write,moved_to,delete,moved_from,create --format '%e|%w%f' /uploads >> "$Q" &
watcher=$!

flush() {
  [ -s "$Q" ] || return 0
  local batch=/tmp/uploads-sync.batch up=/tmp/uploads-sync.up del=/tmp/uploads-sync.del
  mv "$Q" "$batch"; : > "$Q"
  : > "$up"; : > "$del"
  cut -d'|' -f2- "$batch" | sort -u | while IFS= read -r path; do
    rel="${path#/uploads/}"
    [ -n "$rel" ] && [ "$rel" != "$path" ] || continue
    case "$rel" in .railway-jwt/*) continue;; esac
    if [ -d "$path" ]; then
      # new folder: files written before its watch existed are caught here
      (cd /uploads && find "$rel" -type f) >> "$up"
    elif [ -f "$path" ]; then echo "$rel" >> "$up"
    elif [ ! -e "$path" ]; then echo "$rel" >> "$del"; fi
  done
  local rc=0
  if [ -s "$up" ]; then
    sort -u -o "$up" "$up"
    rclone copy /uploads "$RCLONE_REMOTE/uploads" --files-from-raw "$up" --no-traverse -q || rc=1
  fi
  if [ -s "$del" ]; then
    rclone delete "$RCLONE_REMOTE/uploads" --files-from-raw "$del" --no-traverse -q || rc=1
  fi
  if [ "$rc" -ne 0 ]; then
    log "bucket write failed; will retry"
    cat "$batch" >> "$Q"
  else
    log "saved $(wc -l < "$up") file(s), removed $(wc -l < "$del") file(s)"
  fi
  rm "$batch" 2>/dev/null
  return 0
}

stop() { kill "$watcher" 2>/dev/null; sleep 0.5; flush; exit 0; }
trap stop TERM INT

n=0
while :; do
  kill -0 "$watcher" 2>/dev/null || { log "inotifywait stopped"; flush; exit 1; }
  sleep 2 & wait $!
  flush
  n=$(( n + 1 ))
  if [ "$n" -ge 300 ]; then
    n=0
    rclone copy /uploads "$RCLONE_REMOTE/uploads" --exclude '.railway-jwt/**' -q || log "periodic copy failed"
  fi
done
