#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-./watch_media.conf}"
[[ -f "$CONFIG" ]] || { echo "Config not found: $CONFIG" >&2; exit 1; }
# shellcheck source=/dev/null
source "$CONFIG"

MEDIA_ROOT="${REMOTE_MEDIA_ROOT:?REMOTE_MEDIA_ROOT is required}"
QUEUE_FILE="${REMOTE_QUEUE:?REMOTE_QUEUE is required}"
EXTENSIONS="${EXTENSIONS:-mkv,mp4,avi,mov,ts,m2ts,vob,flv,webm,wmv,rmvb}"

command -v inotifywait >/dev/null 2>&1 || { echo "inotifywait not found. Install inotify-tools." >&2; exit 1; }
[[ -d "$MEDIA_ROOT" ]] || { echo "Media root not found: $MEDIA_ROOT" >&2; exit 1; }

mkdir -p "$(dirname "$QUEUE_FILE")"
touch "$QUEUE_FILE"

is_media_path() {
  local path_lc="${1,,}"
  local ext
  IFS=',' read -ra ext_list <<< "$EXTENSIONS"
  for ext in "${ext_list[@]}"; do
    ext="${ext,,}"
    [[ "$path_lc" == *."$ext" ]] && return 0
  done
  return 1
}

enqueue_path() {
  local path="$1"
  [[ -f "$path" ]] || return 0
  is_media_path "$path" || return 0
  printf '%s\n' "$path" >> "$QUEUE_FILE"
  echo "Queued: $path"
}

echo "Watching: $MEDIA_ROOT"
echo "Queue: $QUEUE_FILE"

inotifywait -m -r \
  -e close_write -e moved_to -e create \
  --format '%w%f' \
  "$MEDIA_ROOT" | while IFS= read -r path; do
    enqueue_path "$path"
  done
