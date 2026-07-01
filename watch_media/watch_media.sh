#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${1:-/etc/scan_media/server.env}"
[[ -f "$CONFIG" ]] || { echo "Config not found: $CONFIG" >&2; exit 1; }
# shellcheck source=/dev/null
source "$CONFIG"

MEDIA_ROOT="${REMOTE_MEDIA_ROOT:?REMOTE_MEDIA_ROOT is required}"
MEDIA_MOUNT="${REMOTE_MEDIA_MOUNT:-}"
QUEUE_FILE="${REMOTE_QUEUE:?REMOTE_QUEUE is required}"
EXTENSIONS="${EXTENSIONS:-mkv,mp4,avi,mov,ts,m2ts,vob,flv,webm,wmv,rmvb}"

die() { echo "Error: $*" >&2; exit 1; }

canonical_path() {
  realpath -m "$1" 2>/dev/null || python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$1"
}

is_under_path() {
  local child parent
  child="$(canonical_path "$1")"
  parent="$(canonical_path "$2")"
  [[ "$child" == "$parent" || "$child" == "$parent"/* ]]
}

require_absolute_path() {
  local name="$1" value="$2"
  [[ "$value" == /* ]] || die "$name must be an absolute path: $value"
}

require_absolute_path REMOTE_MEDIA_ROOT "$MEDIA_ROOT"
require_absolute_path REMOTE_QUEUE "$QUEUE_FILE"
[[ -z "$MEDIA_MOUNT" ]] || require_absolute_path REMOTE_MEDIA_MOUNT "$MEDIA_MOUNT"

command -v inotifywait >/dev/null 2>&1 || die "inotifywait not found. Install inotify-tools."
[[ -d "$MEDIA_ROOT" ]] || die "Media root not found: $MEDIA_ROOT"

if [[ -n "$MEDIA_MOUNT" ]]; then
  [[ -d "$MEDIA_MOUNT" ]] || die "Media mount not found: $MEDIA_MOUNT"
  if command -v mountpoint >/dev/null 2>&1; then
    mountpoint -q "$MEDIA_MOUNT" || die "Expected media mount is not mounted: $MEDIA_MOUNT"
  fi
  is_under_path "$MEDIA_ROOT" "$MEDIA_MOUNT" || die "REMOTE_MEDIA_ROOT must be under REMOTE_MEDIA_MOUNT"
fi

is_under_path "$QUEUE_FILE" "$MEDIA_ROOT" && die "REMOTE_QUEUE must not be inside REMOTE_MEDIA_ROOT"

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
  is_under_path "$path" "$MEDIA_ROOT" || return 0
  printf '%s\n' "$path" >> "$QUEUE_FILE"
  echo "Queued: $path"
}

echo "Watching: $MEDIA_ROOT"
echo "Queue: $QUEUE_FILE"
[[ -n "$MEDIA_MOUNT" ]] && echo "Mount: $MEDIA_MOUNT"

inotifywait -m -r \
  -e close_write -e moved_to -e create \
  --format '%w%f' \
  "$MEDIA_ROOT" | while IFS= read -r path; do
    enqueue_path "$path"
  done
