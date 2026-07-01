#!/usr/bin/env bash
set -euo pipefail

HOST=""
INITIAL_USER=""
REPO_URL=""
RUNTIME_USER="scanmedia"
READONLY_GROUP="scanmedia_ro"
REMOTE_MEDIA_MOUNT="/media/Media"
REMOTE_MEDIA_ROOT="/media/Media/Video"
REMOTE_QUEUE="/var/lib/scan_media/changed-files.queue"
SSH_KEY="${SCAN_MEDIA_SSH_KEY:-$HOME/.ssh/scan_media_watcher}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --initial-user) INITIAL_USER="$2"; shift 2 ;;
    --repo-url) REPO_URL="$2"; shift 2 ;;
    --runtime-user) RUNTIME_USER="$2"; shift 2 ;;
    --readonly-group) READONLY_GROUP="$2"; shift 2 ;;
    --remote-media-mount) REMOTE_MEDIA_MOUNT="$2"; shift 2 ;;
    --remote-media-root) REMOTE_MEDIA_ROOT="$2"; shift 2 ;;
    --remote-queue) REMOTE_QUEUE="$2"; shift 2 ;;
    --ssh-key) SSH_KEY="$2"; shift 2 ;;
    *) echo "Unknown parameter: $1" >&2; exit 1 ;;
  esac
done

die() { echo "Error: $*" >&2; exit 1; }
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP="$PROJECT_DIR/watch_media/bootstrap_server.sh"

[[ -n "$HOST" ]] || read -r -p "Jellyfin server LAN IP/host: " HOST
[[ -n "$HOST" ]] || die "Host is required"
[[ -n "$INITIAL_USER" ]] || read -r -p "Initial SSH user with sudo on $HOST: " INITIAL_USER
[[ -n "$INITIAL_USER" ]] || die "Initial user is required"
[[ -f "$BOOTSTRAP" ]] || die "Bootstrap not found: $BOOTSTRAP"

if [[ -z "$REPO_URL" ]]; then
  REPO_URL="$(git -C "$PROJECT_DIR" remote get-url origin 2>/dev/null || true)"
fi
[[ -n "$REPO_URL" ]] || REPO_URL="https://github.com/geoffmcc/scan_media.git"

case "$HOST" in (*[!A-Za-z0-9._:-]*|"") die "Unsafe host: $HOST" ;; esac
case "$INITIAL_USER" in (*[!A-Za-z0-9._-]*|"") die "Unsafe initial user: $INITIAL_USER" ;; esac

if [[ ! -f "$SSH_KEY" || ! -f "$SSH_KEY.pub" ]]; then
  echo "Generating SSH key: $SSH_KEY"
  mkdir -p "$(dirname "$SSH_KEY")"
  ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -q
fi
chmod 600 "$SSH_KEY"
PUB_KEY="$(< "$SSH_KEY.pub")"

CONTROL_PATH="/tmp/scan-media-ssh-%r@%h:%p"
echo "Opening SSH connection to $INITIAL_USER@$HOST. Enter password if prompted."
ssh -M -o ControlPath="$CONTROL_PATH" -o ControlPersist=60 -o StrictHostKeyChecking=accept-new -fN "$INITIAL_USER@$HOST"
trap 'ssh -o ControlPath="$CONTROL_PATH" -O exit "$INITIAL_USER@$HOST" >/dev/null 2>&1 || true' EXIT

scp -o ControlPath="$CONTROL_PATH" "$BOOTSTRAP" "$INITIAL_USER@$HOST:/tmp/scan_media_bootstrap_server.sh" >/dev/null

REMOTE_CMD=(sudo bash /tmp/scan_media_bootstrap_server.sh --yes
  --repo-url "$REPO_URL"
  --runtime-user "$RUNTIME_USER"
  --readonly-group "$READONLY_GROUP"
  --remote-media-mount "$REMOTE_MEDIA_MOUNT"
  --remote-media-root "$REMOTE_MEDIA_ROOT"
  --remote-queue "$REMOTE_QUEUE"
  --ssh-key "$PUB_KEY")

printf -v REMOTE_CMD_STR '%q ' "${REMOTE_CMD[@]}"
ssh -t -o ControlPath="$CONTROL_PATH" "$INITIAL_USER@$HOST" "$REMOTE_CMD_STR"

ssh -o ControlPath="$CONTROL_PATH" -O exit "$INITIAL_USER@$HOST" >/dev/null 2>&1 || true
trap - EXIT

echo "Verifying key-based SSH as $RUNTIME_USER@$HOST"
ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$RUNTIME_USER@$HOST" "echo OK"
echo "Verifying watcher service"
ssh -i "$SSH_KEY" -o BatchMode=yes "$RUNTIME_USER@$HOST" "systemctl is-active scan-media-watcher && systemctl status --no-pager scan-media-watcher | sed -n '1,12p'"
