# Samsung DLNA Profile

Custom Jellyfin DLNA profile for the Samsung TV used by this scanner project.

## HEVC/H.265

HEVC Direct Play is enabled for `mkv`, `mp4`, and `m4v` because USB playback confirmed the TV can play at least 1080p HEVC files directly.

The HEVC codec profile is intentionally conservative:

- Width <= 1920
- Height <= 1080
- Framerate <= 60
- Bitrate <= 40000000

Only a small number of library files appear to be 4K/2160p, and 4K HEVC over DLNA has not been verified yet. If a 4K HEVC file is tested successfully through DLNA, widen these limits in a separate change.
