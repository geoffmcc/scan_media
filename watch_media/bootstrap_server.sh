#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/geoffmcc/scan_media.git"
RUNTIME_USER="scanmedia"
READONLY_GROUP="scanmedia_ro"
REMOTE_MEDIA_MOUNT="/media/Media"
REMOTE_MEDIA_ROOT="/media/Media/Video"
REMOTE_QUEUE="/var/lib/scan_media/changed-files.queue"
INSTALL_DIR="/opt/scan_media"
CONFIG_DIR="/etc/scan_media"
STATE_DIR="/var/lib/scan_media"
SSH_PUB_KEY=""
YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-url) REPO_URL="$2"; shift 2 ;;
    --runtime-user) RUNTIME_USER="$2"; shift 2 ;;
    --readonly-group) READONLY_GROUP="$2"; shift 2 ;;
    --remote-media-mount) REMOTE_MEDIA_MOUNT="$2"; shift 2 ;;
    --remote-media-root) REMOTE_MEDIA_ROOT="$2"; shift 2 ;;
    --remote-queue) REMOTE_QUEUE="$2"; shift 2 ;;
    --install-dir) INSTALL_DIR="$2"; shift 2 ;;
    --ssh-key) SSH_PUB_KEY="$2"; shift 2 ;;
    --yes) YES=true; shift ;;
    *) echo "Unknown parameter: $1" >&2; exit 1 ;;
  esac
done

log() { echo "[bootstrap] $*"; }
die() { echo "[bootstrap] ERROR: $*" >&2; exit 1; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run with sudo/root privileges"

case "$RUNTIME_USER" in (*[!A-Za-z0-9_-]*|"") die "Unsafe runtime user: $RUNTIME_USER" ;; esac
case "$READONLY_GROUP" in (*[!A-Za-z0-9_-]*|"") die "Unsafe group name: $READONLY_GROUP" ;; esac
case "$REPO_URL" in http://*|https://*|git@*) ;; *) die "Unsupported repo URL: $REPO_URL" ;; esac

canonical_path() { realpath -m "$1"; }
is_under_path() {
  local child parent
  child="$(canonical_path "$1")"
  parent="$(canonical_path "$2")"
  [[ "$child" == "$parent" || "$child" == "$parent"/* ]]
}
require_absolute_path() {
  local name="$1" value="$2"
  [[ "$value" == /* ]] || die "$name must be absolute: $value"
}

require_absolute_path REMOTE_MEDIA_MOUNT "$REMOTE_MEDIA_MOUNT"
require_absolute_path REMOTE_MEDIA_ROOT "$REMOTE_MEDIA_ROOT"
require_absolute_path REMOTE_QUEUE "$REMOTE_QUEUE"
require_absolute_path INSTALL_DIR "$INSTALL_DIR"
require_absolute_path CONFIG_DIR "$CONFIG_DIR"
require_absolute_path STATE_DIR "$STATE_DIR"

[[ -d "$REMOTE_MEDIA_MOUNT" ]] || die "Media mount path does not exist: $REMOTE_MEDIA_MOUNT"
[[ -d "$REMOTE_MEDIA_ROOT" ]] || die "Media root path does not exist: $REMOTE_MEDIA_ROOT"
if command -v mountpoint >/dev/null 2>&1; then
  mountpoint -q "$REMOTE_MEDIA_MOUNT" || die "Expected media mount is not mounted: $REMOTE_MEDIA_MOUNT"
fi
is_under_path "$REMOTE_MEDIA_ROOT" "$REMOTE_MEDIA_MOUNT" || die "REMOTE_MEDIA_ROOT must be under REMOTE_MEDIA_MOUNT"
is_under_path "$REMOTE_QUEUE" "$REMOTE_MEDIA_ROOT" && die "REMOTE_QUEUE must not be inside media root"
is_under_path "$INSTALL_DIR" "$REMOTE_MEDIA_ROOT" && die "INSTALL_DIR must not be inside media root"
is_under_path "$CONFIG_DIR" "$REMOTE_MEDIA_ROOT" && die "CONFIG_DIR must not be inside media root"
is_under_path "$STATE_DIR" "$REMOTE_MEDIA_ROOT" && die "STATE_DIR must not be inside media root"

if [[ "$YES" != true ]]; then
  echo "This will install scan_media watcher outside the media root."
  echo "  repo:        $REPO_URL"
  echo "  install:     $INSTALL_DIR"
  echo "  config:      $CONFIG_DIR/server.env"
  echo "  queue:       $REMOTE_QUEUE"
  echo "  media root:  $REMOTE_MEDIA_ROOT"
  echo "  user/group:  $RUNTIME_USER:$READONLY_GROUP"
  read -r -p "Continue? [y/N] " answer
  [[ "$answer" == "y" || "$answer" == "Y" ]] || die "Aborted"
fi

if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  case "${ID:-}" in ubuntu|debian) ;; *) die "Unsupported OS: ${ID:-unknown}. Ubuntu/Debian required." ;; esac
else
  die "Cannot detect OS"
fi

log "Installing required packages"
apt-get update -qq
apt-get install -y -qq git inotify-tools util-linux acl ca-certificates >/dev/null

log "Creating group/user"
getent group "$READONLY_GROUP" >/dev/null || groupadd --system "$READONLY_GROUP"
if id "$RUNTIME_USER" >/dev/null 2>&1; then
  usermod -aG "$READONLY_GROUP" "$RUNTIME_USER"
else
  useradd --system --create-home --shell /bin/bash --gid "$READONLY_GROUP" "$RUNTIME_USER"
fi
passwd -l "$RUNTIME_USER" >/dev/null 2>&1 || true

USER_HOME="$(eval echo "~$RUNTIME_USER")"
mkdir -p "$USER_HOME/.ssh"
touch "$USER_HOME/.ssh/authorized_keys"
chmod 700 "$USER_HOME/.ssh"
chmod 600 "$USER_HOME/.ssh/authorized_keys"
chown -R "$RUNTIME_USER:$READONLY_GROUP" "$USER_HOME/.ssh"

if [[ -n "$SSH_PUB_KEY" ]]; then
  log "Installing SSH public key for $RUNTIME_USER"
  grep -Fxq "$SSH_PUB_KEY" "$USER_HOME/.ssh/authorized_keys" || echo "$SSH_PUB_KEY" >> "$USER_HOME/.ssh/authorized_keys"
  sort -u "$USER_HOME/.ssh/authorized_keys" -o "$USER_HOME/.ssh/authorized_keys"
  chmod 600 "$USER_HOME/.ssh/authorized_keys"
  chown "$RUNTIME_USER:$READONLY_GROUP" "$USER_HOME/.ssh/authorized_keys"
fi

log "Checking read-only media access"
if ! sudo -u "$RUNTIME_USER" test -r "$REMOTE_MEDIA_ROOT" || ! sudo -u "$RUNTIME_USER" test -x "$REMOTE_MEDIA_ROOT"; then
  cat >&2 <<EOF
[bootstrap] ERROR: $RUNTIME_USER cannot read/traverse $REMOTE_MEDIA_ROOT.

No media permissions were changed. If you choose to grant read-only ACL access,
review and run these commands manually, then rerun deploy:

sudo groupadd --system $READONLY_GROUP 2>/dev/null || true
sudo setfacl -R -m g:$READONLY_GROUP:rX $REMOTE_MEDIA_ROOT
sudo setfacl -R -d -m g:$READONLY_GROUP:rX $REMOTE_MEDIA_ROOT

These ACL commands modify filesystem permission ACL metadata only. They do not
modify media file contents, embedded tags, filenames, or media timestamps.
EOF
  exit 1
fi
if sudo -u "$RUNTIME_USER" test -w "$REMOTE_MEDIA_ROOT"; then
  die "$RUNTIME_USER can write to $REMOTE_MEDIA_ROOT; refusing unsafe setup"
fi

log "Creating state/config directories"
mkdir -p "$STATE_DIR" "$CONFIG_DIR" "$(dirname "$INSTALL_DIR")"
touch "$REMOTE_QUEUE"
chown -R "$RUNTIME_USER:$READONLY_GROUP" "$STATE_DIR"
chmod 750 "$STATE_DIR"
chmod 640 "$REMOTE_QUEUE"

log "Cloning/updating repository"
if [[ -d "$INSTALL_DIR/.git" ]]; then
  git -C "$INSTALL_DIR" pull --ff-only
else
  rm -rf "$INSTALL_DIR"
  git clone "$REPO_URL" "$INSTALL_DIR"
fi
chown -R root:root "$INSTALL_DIR"
find "$INSTALL_DIR" -type d -exec chmod 755 {} +
find "$INSTALL_DIR" -type f -exec chmod 644 {} +
chmod 755 "$INSTALL_DIR/scan_transcode.sh" "$INSTALL_DIR/watch_media/watch_media.sh" "$INSTALL_DIR/watch_media/pull_queue.sh" 2>/dev/null || true

log "Writing server config"
cat > "$CONFIG_DIR/server.env" <<EOF
REMOTE_MEDIA_MOUNT="$REMOTE_MEDIA_MOUNT"
REMOTE_MEDIA_ROOT="$REMOTE_MEDIA_ROOT"
REMOTE_QUEUE="$REMOTE_QUEUE"
EXTENSIONS="mkv,mp4,avi,mov,ts,m2ts,vob,flv,webm,wmv,rmvb"
EOF
chown root:"$READONLY_GROUP" "$CONFIG_DIR/server.env"
chmod 640 "$CONFIG_DIR/server.env"

log "Installing systemd service"
cat > /etc/systemd/system/scan-media-watcher.service <<EOF
[Unit]
Description=scan_media read-only media watcher
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$RUNTIME_USER
Group=$READONLY_GROUP
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/watch_media/watch_media.sh $CONFIG_DIR/server.env
Restart=on-failure
RestartSec=30
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=$REMOTE_MEDIA_ROOT
ReadWritePaths=$STATE_DIR
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
SystemCallArchitectures=native

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable scan-media-watcher >/dev/null
systemctl restart scan-media-watcher

if sysctl fs.inotify.max_user_watches >/dev/null 2>&1; then
  watches="$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo 0)"
  if [[ "$watches" =~ ^[0-9]+$ && "$watches" -lt 65536 ]]; then
    echo "[bootstrap] WARNING: fs.inotify.max_user_watches is low ($watches). Large libraries may need a higher limit."
  fi
fi

sleep 2
systemctl is-active --quiet scan-media-watcher || {
  systemctl status --no-pager scan-media-watcher >&2 || true
  die "scan-media-watcher did not start"
}

log "Installed and started scan-media-watcher"
