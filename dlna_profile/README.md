# Samsung DLNA Profile

Custom Jellyfin DLNA profile for the Samsung TV used by this scanner project.

## HEVC/H.265

HEVC Direct Play is enabled for `mkv`, `mp4`, and `m4v` because USB playback confirmed the TV can play HEVC files directly, including a 4K HEVC sample.

The HEVC codec profile is intentionally conservative for DLNA:

- Width <= 3840
- Height <= 2160
- Framerate <= 30
- Bitrate <= 40000000

This allows typical 4K movie/TV HEVC files without opening the profile to unverified 4K60 or very high bitrate content. If 4K60 HEVC is tested successfully through DLNA, widen these limits in a separate change.
