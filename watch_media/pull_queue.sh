#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-./watch_media.conf}"
[[ -f "$CONFIG" ]] || { echo "Config not found: $CONFIG" >&2; exit 1; }
# shellcheck source=/dev/null
source "$CONFIG"

REMOTE_SSH="${REMOTE_SSH:?REMOTE_SSH is required}"
REMOTE_QUEUE="${REMOTE_QUEUE:?REMOTE_QUEUE is required}"
REMOTE_MEDIA_ROOT="${REMOTE_MEDIA_ROOT:?REMOTE_MEDIA_ROOT is required}"
LOCAL_MEDIA_ROOT="${LOCAL_MEDIA_ROOT:?LOCAL_MEDIA_ROOT is required}"
SCANNER="${SCANNER:?SCANNER is required}"
REPORT_STEM="${REPORT_STEM:?REPORT_STEM is required}"
FORMAT="${FORMAT:-both}"
JOBS="${JOBS:-4}"

command -v ssh >/dev/null 2>&1 || { echo "ssh not found" >&2; exit 1; }
[[ -x "$SCANNER" || -f "$SCANNER" ]] || { echo "Scanner not found: $SCANNER" >&2; exit 1; }

remote_paths=$(mktemp)
local_paths=$(mktemp)
trap 'rm -f "$remote_paths" "$local_paths"' EXIT

ssh "$REMOTE_SSH" "queue='$REMOTE_QUEUE'; mkdir -p \"\$(dirname \"\$queue\")\"; touch \"\$queue\"; if [ -s \"\$queue\" ]; then tmp=\"\$queue.\$(date +%s).\$\$\"; mv \"\$queue\" \"\$tmp\"; touch \"\$queue\"; cat \"\$tmp\"; rm -f \"\$tmp\"; fi" > "$remote_paths"

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
