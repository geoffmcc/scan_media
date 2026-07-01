# Watch Media

Prototype local-pull watcher workflow for updating scan reports without a full media-tree walk every time.

The full scanner remains the source of truth. Run a full scan periodically to catch missed watcher events, deletes, renames, or server downtime.

## Workflow

1. `watch_media.sh` runs on the Jellyfin server.
2. It watches the server media path with `inotifywait`.
3. It appends changed media file paths to a queue on the Jellyfin server.
4. `pull_queue.sh` runs locally from WSL.
5. It drains the remote queue over SSH, maps server paths to local WSL paths, and calls `scan_transcode.sh --file-list`.

This keeps reports on the local workstation while avoiding a full media walk for known changes.

## Setup

Copy the example config and edit it locally:

```bash
cp watch_media/watch_media.conf.example watch_media/watch_media.conf
```

Do not commit `watch_media.conf`; it should contain private server details.

Install server dependency:

```bash
sudo apt install inotify-tools
```

Run the watcher on the Jellyfin server:

```bash
./watch_media/watch_media.sh ./watch_media/watch_media.conf
```

Pull and process queued changes locally from WSL:

```bash
./watch_media/pull_queue.sh ./watch_media/watch_media.conf
```

## Notes

- The watcher is an accelerator, not a replacement for full scans.
- The queue stores paths as seen by the Jellyfin server.
- `pull_queue.sh` translates `REMOTE_MEDIA_ROOT` to `LOCAL_MEDIA_ROOT` before scanning.
- Future webhook integrations can append server-side paths to the same queue file.
