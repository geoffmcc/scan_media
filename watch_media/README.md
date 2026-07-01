# Watch Media

Read-only local-pull watcher workflow for updating scan reports without a full media-tree walk every time.

The full scanner remains the source of truth. Run a full scan periodically to catch missed watcher events, deletes, renames, or server downtime.

## Safety Model

- The watcher observes media paths and writes only to a queue outside the media root.
- The scanner reads media with `ffprobe` and writes reports/cache outside the local media root.
- The server watcher runs as `scanmedia:scanmedia_ro` by default.
- The deploy does not add the watcher user to an existing writable media group.
- The bootstrap never changes media permissions automatically.
- The scanner recurses normal subdirectories but does not follow symlinks by default.

If the watcher user cannot read the media root, bootstrap stops and prints optional read-only ACL commands for manual review. Those commands are not run automatically.

## Files

- `server.env.example` - generic server-side watcher config
- `local.env.example` - generic local puller config
- `watch_media.sh` - server-side inotify watcher
- `pull_queue.sh` - local queue drain and incremental scan runner
- `bootstrap_server.sh` - server bootstrap run by deploy scripts
- `scan-media-watcher.service` - example systemd service

Private config files such as `watch_media/local.env` are ignored by git.

## Server Deploy

From WSL/Linux, run from the repository root:

```bash
./deploy_watch_media.sh --host your-jellyfin-lan-ip
```

The script prompts for an initial SSH user with sudo access. SSH will prompt for that user's password. The bootstrap then creates the low-privilege watcher user and installs the service.

PowerShell is also supported:

```powershell
.\deploy_watch_media.ps1 -HostName your-jellyfin-lan-ip
```

The deploy script uses this repo URL order:

1. explicit `--repo-url` / `-RepoUrl`
2. `git remote get-url origin`
3. the script's built-in upstream fallback

## Local Puller

Copy and edit the local example:

```bash
cp watch_media/local.env.example watch_media/local.env
```

Then run from WSL/Linux:

```bash
./watch_media/pull_queue.sh
```

`pull_queue.sh` drains the remote queue over SSH, maps server paths to local paths, and calls `scan_transcode.sh --file-list`.

## Manual ACL Option

If bootstrap says `scanmedia` cannot read the media root, it will print commands like:

```bash
sudo setfacl -R -m g:scanmedia_ro:rX /media/Media/Video
sudo setfacl -R -d -m g:scanmedia_ro:rX /media/Media/Video
```

These commands grant read/traverse ACL access to `scanmedia_ro`. They modify filesystem permission ACL metadata only. They do not modify media file contents, embedded tags, filenames, or media timestamps. Review before running them.

## Status And Logs

On the server:

```bash
systemctl status scan-media-watcher
journalctl -u scan-media-watcher -n 100 --no-pager
wc -l /var/lib/scan_media/changed-files.queue
```

Stop or disable:

```bash
sudo systemctl stop scan-media-watcher
sudo systemctl disable scan-media-watcher
```

## Inotify Limits

Large libraries may need a higher watch limit. Check:

```bash
sysctl fs.inotify.max_user_watches
```

Example manual increase:

```bash
echo 'fs.inotify.max_user_watches=524288' | sudo tee /etc/sysctl.d/99-scan-media-inotify.conf
sudo sysctl --system
```

## Optional Scheduling

Scheduling is not installed automatically. A local WSL cron entry can run the puller periodically after manual testing:

```cron
*/5 * * * * cd /path/to/scan_media && ./watch_media/pull_queue.sh >> /tmp/scan_media_pull_queue.log 2>&1
```

## SSH Key Removal

To revoke queue-drain SSH access, remove the relevant public key from:

```bash
/home/scanmedia/.ssh/authorized_keys
```

Or remove the watcher user after stopping the service:

```bash
sudo systemctl stop scan-media-watcher
sudo userdel -r scanmedia
```
