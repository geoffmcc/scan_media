#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${1:-$SCRIPT_DIR/local.env}"
[[ -f "$CONFIG" ]] || { echo "Config not found: $CONFIG" >&2; exit 1; }
# shellcheck source=/dev/null
source "$CONFIG"

REMOTE_SSH="${REMOTE_SSH:?REMOTE_SSH is required}"
REMOTE_QUEUE="${REMOTE_QUEUE:?REMOTE_QUEUE is required}"
REMOTE_MEDIA_ROOT="${REMOTE_MEDIA_ROOT:?REMOTE_MEDIA_ROOT is required}"
LOCAL_MEDIA_ROOT="${LOCAL_MEDIA_ROOT:?LOCAL_MEDIA_ROOT is required}"
LOCAL_MEDIA_MOUNT="${LOCAL_MEDIA_MOUNT:-}"
SCANNER="${SCANNER:?SCANNER is required}"
REPORT_STEM="${REPORT_STEM:?REPORT_STEM is required}"
FORMAT="${FORMAT:-both}"
JOBS="${JOBS:-4}"
PULL_LOCK="${PULL_LOCK:-/tmp/scan_media_pull_queue.lock}"

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

require_safe_remote_path() {
  local name="$1" value="$2"
  require_absolute_path "$name" "$value"
  [[ "$value" =~ ^/[A-Za-z0-9._/@%+=:,~-]+$ ]] || die "$name contains unsupported characters: $value"
}

require_absolute_path LOCAL_MEDIA_ROOT "$LOCAL_MEDIA_ROOT"
require_absolute_path SCANNER "$SCANNER"
require_absolute_path REPORT_STEM "$REPORT_STEM"
[[ -z "$LOCAL_MEDIA_MOUNT" ]] || require_absolute_path LOCAL_MEDIA_MOUNT "$LOCAL_MEDIA_MOUNT"
require_safe_remote_path REMOTE_MEDIA_ROOT "$REMOTE_MEDIA_ROOT"
require_safe_remote_path REMOTE_QUEUE "$REMOTE_QUEUE"

command -v ssh >/dev/null 2>&1 || die "ssh not found"
command -v flock >/dev/null 2>&1 || die "flock not found"
[[ -x "$SCANNER" || -f "$SCANNER" ]] || die "Scanner not found: $SCANNER"
[[ -d "$LOCAL_MEDIA_ROOT" ]] || die "Local media root not found: $LOCAL_MEDIA_ROOT"

if [[ -n "$LOCAL_MEDIA_MOUNT" ]]; then
  [[ -d "$LOCAL_MEDIA_MOUNT" ]] || die "Local media mount not found: $LOCAL_MEDIA_MOUNT"
  if command -v mountpoint >/dev/null 2>&1 && mountpoint -q "$LOCAL_MEDIA_MOUNT"; then
    :
  else
    [[ -r "$LOCAL_MEDIA_ROOT" ]] || die "Local media root is not readable: $LOCAL_MEDIA_ROOT"
  fi
  is_under_path "$LOCAL_MEDIA_ROOT" "$LOCAL_MEDIA_MOUNT" || die "LOCAL_MEDIA_ROOT must be under LOCAL_MEDIA_MOUNT"
fi

is_under_path "$REPORT_STEM" "$LOCAL_MEDIA_ROOT" && die "REPORT_STEM must not be inside LOCAL_MEDIA_ROOT"

remote_paths=$(mktemp)
local_paths=$(mktemp)
trap 'rm -f "$remote_paths" "$local_paths"' EXIT

(
  flock -n 9 || die "Another pull_queue.sh run is already active"

  ssh "$REMOTE_SSH" 'bash -s' -- "$REMOTE_QUEUE" <<'REMOTE_DRAIN' > "$remote_paths"
set -euo pipefail
queue="$1"
case "$queue" in
  /*) ;;
  *) echo "Remote queue must be absolute" >&2; exit 2 ;;
esac
case "$queue" in
  *[!A-Za-z0-9._/@%+=:,~-]*) echo "Remote queue contains unsupported characters" >&2; exit 2 ;;
esac
lock="${queue}.lock"
mkdir -p "$(dirname "$queue")"
touch "$queue"
if command -v flock >/dev/null 2>&1; then
  exec 9>"$lock"
  flock 9
  if [ -s "$queue" ]; then
    tmp="${queue}.$(date +%s).$$"
    mv "$queue" "$tmp"
    touch "$queue"
    cat "$tmp"
    rm -f "$tmp"
  fi
else
  lockdir="${lock}.d"
  while ! mkdir "$lockdir" 2>/dev/null; do sleep 1; done
  trap 'rmdir "$lockdir"' EXIT
  if [ -s "$queue" ]; then
    tmp="${queue}.$(date +%s).$$"
    mv "$queue" "$tmp"
    touch "$queue"
    cat "$tmp"
    rm -f "$tmp"
  fi
fi
REMOTE_DRAIN

  if [[ ! -s "$remote_paths" ]]; then
    echo "No queued media changes."
    exit 0
  fi

  while IFS= read -r remote_path || [[ -n "$remote_path" ]]; do
    remote_path="${remote_path%$'\r'}"
    [[ -z "$remote_path" ]] && continue
    case "$remote_path" in
      "$REMOTE_MEDIA_ROOT"/*)
        rel="${remote_path#"$REMOTE_MEDIA_ROOT"/}"
        case "$rel" in
          ""|/*|../*|*/../*) echo "Skipping unsafe relative path: $remote_path" >&2; continue ;;
        esac
        printf '%s/%s\n' "${LOCAL_MEDIA_ROOT%/}" "$rel"
        ;;
      *)
        echo "Skipping path outside remote media root: $remote_path" >&2
        ;;
    esac
  done < "$remote_paths" | sort -u > "$local_paths"

  if [[ ! -s "$local_paths" ]]; then
    echo "No queued media changes matched the configured media root."
    exit 0
  fi

  echo "Queued media changes: $(wc -l < "$local_paths")"
  bash "$SCANNER" "$LOCAL_MEDIA_ROOT" \
    --format "$FORMAT" \
    --output "$REPORT_STEM" \
    --file-list "$local_paths" \
    --jobs "$JOBS"
) 9>"$PULL_LOCK"
