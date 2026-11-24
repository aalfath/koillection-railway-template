#!/bin/bash
# Mirrors /uploads to the Railway Bucket file by file (never a whole-tree "sync",
# so an older container can't delete files a newer one wrote).
# Events from inotifywait are batched until 2 s pass with no new event, then the
# changed files are copied and deleted files removed. A full copy (no deletes)
# also runs every 10 minutes as a safety net. Exits 1 if the watcher stops.
set -uo pipefail
log() { echo "[uploads-sync] $*"; }
B=/tmp/uploads-sync.batch UP=/tmp/uploads-sync.up DEL=/tmp/uploads-sync.del
: > "$B"

flush() {
  [ -s "$B" ] || return 0
  : > "$UP"; : > "$DEL"
  cut -d'|' -f2- "$B" | sort -u | while IFS= read -r path; do
    rel="${path#/uploads/}"
    [ -n "$rel" ] && [ "$rel" != "$path" ] || continue
    case "$rel" in .railway-jwt/*) continue;; esac
    if [ -d "$path" ]; then
      # new folder: files written before its watch existed are caught here
      (cd /uploads && find "$rel" -type f) >> "$UP"
    elif [ -f "$path" ]; then echo "$rel" >> "$UP"
    elif [ ! -e "$path" ]; then echo "$rel" >> "$DEL"; fi
  done
  sort -u -o "$UP" "$UP"
  local rc=0
  if [ -s "$UP" ]; then
    rclone copy /uploads "$RCLONE_REMOTE/uploads" --files-from-raw "$UP" --no-traverse -q || rc=1
  fi
  if [ -s "$DEL" ]; then
    rclone delete "$RCLONE_REMOTE/uploads" --files-from-raw "$DEL" --no-traverse -q || rc=1
  fi
  if [ "$rc" -ne 0 ]; then
    log "bucket write failed; will retry with the next change or the 10-minute copy"
    return 0
  fi
  log "saved $(wc -l < "$UP") file(s), removed $(wc -l < "$DEL") file(s)"
  : > "$B"
}

full_copy() {
  rclone copy /uploads "$RCLONE_REMOTE/uploads" --exclude '.railway-jwt/**' -q || log "periodic copy failed"
}

trap 'flush; exit 0' TERM INT
last_full=$SECONDS
while :; do
  r=0
  IFS= read -r -t 2 line || r=$?
  if [ "$r" -eq 0 ]; then
    printf '%s\n' "$line" >> "$B"
    # keep collecting while events keep coming, but flush at least every 30 s
    [ "$(wc -l < "$B")" -lt 5000 ] && [ $(( SECONDS - ${batch_start:=$SECONDS} )) -lt 30 ] && continue
  elif [ "$r" -le 128 ]; then
    log "inotifywait stopped"; flush; exit 1
  fi
  flush; unset batch_start
  if [ $(( SECONDS - last_full )) -ge 600 ]; then full_copy; last_full=$SECONDS; fi
done < <(inotifywait -m -r -q -e close_write,moved_to,delete,moved_from,create --format '%e|%w%f' /uploads)
