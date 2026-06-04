# scan_transcode.sh — How It Works

Scans a media library directory, inspects every video file with `ffprobe`, and reports which files will require transcoding when played on a Samsung NU6900 TV (and likely other Samsung models or TV brands) via Jellyfin/DLNA. Outputs a console summary plus CSV and/or HTML reports.

## Usage

```bash
./scan_transcode.sh /path/to/media [options]
```

### Options

| Option | Description |
|---|---|
| `--format FMT` | Output format: `csv`, `html`, `both` (default: `both`) |
| `--output FILE` | Basename stem (e.g. `--output report` → `report.csv` + `report.html`) |
| `--only-transcode` | Show only files needing transcode in the console table. Does not affect the HTML checkbox or CSV — full data is always written to both reports. |
| `--check-subtitles` | Check subtitle stream compatibility |
| `--jobs N` | Parallel ffprobe workers (default: CPU count) |
| `--exts "e1,e2,..."` | Override default extension list |
| `--verbose` | Print each file as it is processed |
| `--help` | Show help text |

### Examples

```bash
# Full scan — console + CSV + HTML
./scan_transcode.sh /mnt/media

# HTML report only, custom filename stem
./scan_transcode.sh /mnt/media --format html --output ~/media_report

# CSV only, transcode-only filter, subtitle check
./scan_transcode.sh /mnt/media --format csv --only-transcode --check-subtitles
```

## Architecture

### 1. Argument Parsing

Positional argument is the scan directory. All `--options` are parsed with a `while` loop. `--output` strips `.csv`/`.html` extensions if provided, using the clean stem for both output files.

The directory is validated to exist, and `ffprobe` is checked to be on `PATH`.

### 2. File Discovery

Uses `find` with `-follow` (follow symlinks) to recursively locate all files matching the supported extensions (default: mkv, mp4, avi, mov, ts, m2ts, vob, flv, webm, wmv, rmvb). The extension list is user-overridable via `--exts`. A file count is printed before processing begins so you can confirm discovery worked.

### 3. Parallel Processing

`find` pipes null-terminated file paths to `xargs -0 -P`, which spawns up to N parallel workers. Each worker runs the `process_file` function on one file. This is the key performance feature — a large library is scanned in minutes rather than hours.

A live progress counter is displayed on the terminal during processing, showing `Processed: N / M`.

### 3.5 Incremental Cache

Results are cached in a `.cache` file alongside the CSV report. Each entry stores the file's modification time (mtime) alongside its scan verdict. On subsequent runs:

- Files whose mtime hasn't changed are pulled from the cache and skipped by workers
- Files that previously errored (unreadable) are also cached so they aren't retried
- When all files are up to date, the script exits immediately with no report regeneration
- The cache includes a config header; if `--check-subtitles` is toggled, the cache is invalidated and a full re-scan runs
- Delete the `.cache` file to force a full re-scan

### 4. Stream Inspection (`process_file`)

For each file, `ffprobe` is called once with JSON output containing format info and all stream metadata. `jq` extracts and iterates over every stream:

- **Container**: compared against the supported container list
- **Video streams**: codec name checked against H.264, HEVC, MPEG-2, MPEG-4, VP8, VP9, MJPEG
- **Audio streams**: codec name and tag string checked against the transcode blocklist: DTS, DTS-HD MA, DTS:X, Dolby TrueHD
- **Subtitle streams** (only if `--check-subtitles`): codec name checked against SRT, `mov_text`, ASS, SSA, SMI, SUB, MicroDVD, TTXT, XML — anything else (PGS, VobSub) is flagged

### 5. Verdict Logic

- **Direct Play** — no issues found across all checked streams
- **Subtitle Issue** (only when `--check-subtitles`) — all flagged issues are subtitle-only, no codec problems
- **Transcode Needed** — at least one codec stream flagged. The specific reason is recorded (e.g., "Audio codec 'dts' not supported")

### 6. Output

**Console** (always unless `--format html`): formatted table with file path, container, video codec, audio codec, subtitle codec, and verdict. Transcode reasons are indented under each file. `--only-transcode` filters to just problematic files. Unreadable files are listed in a separate Skipped Files section at the bottom.

**CSV** (if format includes `csv`): machine-readable with columns `path,container,video_codec,audio_codec,subtitle_codec,verdict,reason`. If files were skipped, a `# Skipped files: N` comment block is appended at the end.

**HTML** (if format includes `html`): self-contained single file with:

- Summary banner with total / direct play / transcode / skipped counts
- Collapsible Skipped Files section (orange) listing unreadable files
- Color-coded table rows (green = Direct Play, amber = Subtitle Issue, red = Transcode Needed)
- Three independent JS-powered checkboxes to hide/show each verdict category
- Reasons displayed as italic text below each file row
- No external dependencies — CSS and JS are inline

### 7. Output Dispatch

A `case` statement on `$FORMAT` calls the appropriate generation functions:

- `generate_csv` — writes sorted CSV with header
- `generate_html` — writes single-file HTML with inline styles and JS
- `generate_console` — writes formatted table to stdout

## Dependencies

- `ffprobe` (from FFmpeg)
- `jq`
- Standard POSIX tools: `find`, `xargs`, `grep`, `sort`, `realpath`, `sed`

## Design Notes

- All temp files (RESULTS, SKIPPED, CACHE_HITS, FILE_LIST, PROGRESS_FILE, PROGRESS_DONE) are cleaned up on exit via `trap`
- The `process_file` function is `export -f` so `xargs` can invoke it in child shells
- `jq` is used over `grep`/`awk` for reliable JSON parsing with proper escaping
- Results are written to a temp file, sorted, and then emitted — no interleaving from parallel workers
- `--verbose` prints each file's relative path as `xargs` dispatches it, useful for debugging slow or skipped scans
- Unreadable files (corrupt, permission-denied, etc.) are tracked in a separate temp file and reported in a Skipped Files section rather than aborting the entire scan. Each entry includes the `ffprobe` error message (e.g., `Invalid data found when processing input`) to help diagnose the issue.
 - `--output` intelligently strips `.csv`/`.html` extensions so old habits don't cause doubled extensions

Planned with help by Geoffrey McClinsey, built by OpenCode
