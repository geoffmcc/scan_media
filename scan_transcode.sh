#!/usr/bin/env bash
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────
SCAN_DIR=""
FORMAT="both"
OUTPUT_STEM=""
OUTPUT_CSV=""
OUTPUT_HTML=""
ONLY_TRANSCODE=false
CHECK_SUBTITLES=false
VERBOSE=false
JOBS=""
EXTENSIONS="mkv,mp4,avi,mov,ts,m2ts,vob,flv,webm,wmv,rmvb"

SUPPORTED_CONTAINERS="mkv mp4 avi mov ts m2ts vob flv webm wmv rmvb"
SUPPORTED_VIDEO="h264 avc h265 hevc mpeg2 mpeg4 vp8 vp9 mjpeg"
TRANSCODE_AUDIO="dts dts-hd dts-hd_ma dts:x dtsx truehd dolby_truehd"
SUPPORTED_SUBS="subrip srt ass ssa smi sub microdvd text ttxt xml mov_text"

# ── Help ──────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") /path/to/media [options]

Output:
  --format FMT         csv, html, both (default: both)
  --output FILE        Basename stem (e.g. report -> report.csv + report.html)

Filtering:
  --only-transcode     Show only files needing transcode
  --check-subtitles    Check subtitle stream compatibility

Performance:
  --jobs N             Parallel ffprobe workers (default: CPU count)
  --exts "e1,e2,..."   Override default extension list

Troubleshooting:
  --verbose            Print each file as it is processed
  --help               Show this help
EOF
  exit 0
}

# ── Parse arguments ───────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --format)           FORMAT="$2"; shift 2 ;;
    --output)           OUTPUT_STEM="$2"; shift 2 ;;
    --only-transcode)   ONLY_TRANSCODE=true; shift ;;
    --check-subtitles)  CHECK_SUBTITLES=true; shift ;;
    --verbose)          VERBOSE=true; shift ;;
    --jobs)             JOBS="$2"; shift 2 ;;
    --exts)             EXTENSIONS="$2"; shift 2 ;;
    --help)             usage ;;
    -*)                 echo "Unknown option: $1"; usage ;;
    *) [[ -z "$SCAN_DIR" ]] && SCAN_DIR="$1" || { echo "Unexpected: $1"; usage; }; shift ;;
  esac
done

# ── Validation ────────────────────────────────────────────────────────────
[[ -n "$SCAN_DIR" ]] || { echo "Error: scan directory required"; usage; }
[[ -d "$SCAN_DIR" ]] || { echo "Error: '$SCAN_DIR' is not a directory"; exit 1; }
command -v ffprobe &>/dev/null || { echo "Error: ffprobe not found"; exit 1; }
[[ "$FORMAT" =~ ^(csv|html|both)$ ]] || { echo "Error: --format must be csv, html, or both"; exit 1; }

[[ -z "$JOBS" ]] && JOBS=$(nproc 2>/dev/null || echo 4)

# Resolve output paths
if [[ -n "$OUTPUT_STEM" ]]; then
  # Strip .csv or .html extension if user passed one
  stem="${OUTPUT_STEM%.csv}"
  stem="${stem%.html}"
  [[ -z "$OUTPUT_CSV" ]] && OUTPUT_CSV="$stem.csv"
  [[ -z "$OUTPUT_HTML" ]] && OUTPUT_HTML="$stem.html"
else
  [[ -z "$OUTPUT_CSV" ]] && OUTPUT_CSV="$PWD/transcode_report.csv"
  [[ -z "$OUTPUT_HTML" ]] && OUTPUT_HTML="$PWD/transcode_report.html"
fi

# ── Build find patterns ───────────────────────────────────────────────────
IFS=',' read -ra EXT_LIST <<< "$EXTENSIONS"
FIND_ARGS=()
for ext in "${EXT_LIST[@]}"; do
  FIND_ARGS+=(-o -iname "*.$ext")
done

# ── Temp files ────────────────────────────────────────────────────────────
RESULTS=$(mktemp)
SKIPPED=$(mktemp)
trap 'rm -f "$RESULTS" "$SKIPPED"' EXIT

# ── Process a single file ─────────────────────────────────────────────────
process_file() {
  local file="$1" relpath="$2"

  local errfile json
  errfile=$(mktemp) || return 0
  json=$(ffprobe -v error -print_format json -show_format -show_streams "$file" 2>"$errfile") || {
    err=$(head -1 "$errfile" 2>/dev/null || echo "unknown error")
    rm -f "$errfile"
    echo "$relpath: $err" >> "$SKIPPED"
    return 0
  }
  rm -f "$errfile"

  local container
  container=$(jq -r '.format.format_name // "unknown"' <<< "$json")

  local video_codecs="" audio_codecs="" sub_codecs=""
  local verdict="Direct Play"
  local reasons=()

  # Container check
  local container_ok=false
  for c in $SUPPORTED_CONTAINERS; do
    if grep -qi "$c" <<< "$container"; then
      container_ok=true
      break
    fi
  done
  if ! $container_ok; then
    reasons+=("Container '$container' not supported")
    verdict="Transcode Needed"
  fi

  local stream_count
  stream_count=$(jq '.streams | length' <<< "$json")

  for ((i=0; i<stream_count; i++)); do
    local codec_type codec_name codec_tag
    codec_type=$(jq -r ".streams[$i].codec_type // \"unknown\"" <<< "$json")
    codec_name=$(jq -r ".streams[$i].codec_name // \"unknown\"" <<< "$json" | tr '[:upper:]' '[:lower:]')
    codec_tag=$(jq -r ".streams[$i].codec_tag_string // \"\"" <<< "$json" | tr '[:upper:]' '[:lower:]')

    case "$codec_type" in
      video)
        local vid_ok=false
        for v in $SUPPORTED_VIDEO; do
          [[ "$codec_name" == "$v" ]] && { vid_ok=true; break; }
        done
        if ! $vid_ok; then
          reasons+=("Video codec '$codec_name' not supported")
          verdict="Transcode Needed"
        fi
        video_codecs="${video_codecs:+$video_codecs,}$codec_name"
        ;;
      audio)
        local aud_bad=false aud_name
        for a in $TRANSCODE_AUDIO; do
          if [[ "$codec_name" == "$a" ]]; then
            aud_bad=true
            break
          fi
          if grep -qiE 'dts(hd|:x|x)' <<< "$codec_tag"; then
            aud_bad=true
            break
          fi
        done
        if $aud_bad; then
          aud_name=$(jq -r ".streams[$i].codec_name // \"$codec_tag\"" <<< "$json")
          reasons+=("Audio codec '$aud_name' not supported")
          verdict="Transcode Needed"
        fi
        audio_codecs="${audio_codecs:+$audio_codecs,}$codec_name"
        ;;
      subtitle)
        if $CHECK_SUBTITLES; then
          local sub_ok=false
          for s in $SUPPORTED_SUBS; do
            [[ "$codec_name" == "$s" ]] && { sub_ok=true; break; }
          done
          if ! $sub_ok; then
            reasons+=("Subtitle codec '$codec_name' not supported")
            verdict="Transcode Needed"
          fi
          sub_codecs="${sub_codecs:+$sub_codecs,}$codec_name"
        fi
        ;;
    esac
  done

  local reason_str
  reason_str=$(IFS='; '; echo "${reasons[*]}")
  echo "$relpath|$container|$video_codecs|$audio_codecs|$sub_codecs|$verdict|$reason_str" >> "$RESULTS"
}

export -f process_file
export RESULTS SUPPORTED_CONTAINERS SUPPORTED_VIDEO TRANSCODE_AUDIO SUPPORTED_SUBS CHECK_SUBTITLES SKIPPED VERBOSE

# ── Scan ──────────────────────────────────────────────────────────────────
echo "Scanning: $SCAN_DIR"
echo "Extensions: $EXTENSIONS"
echo "Parallel jobs: $JOBS"
echo ""

file_count=$(find "$SCAN_DIR" -follow -type f \( "${FIND_ARGS[@]:1}" \) -print 2>/dev/null | wc -l 2>/dev/null || echo 0)
echo "Files found: $file_count"
echo ""

if ! find "$SCAN_DIR" -follow -type f \( "${FIND_ARGS[@]:1}" \) -print0 2>/dev/null | \
  xargs -0 -P "$JOBS" -I {} bash -c '
    rel=$(realpath --relative-to="'"$SCAN_DIR"'" "$1" 2>/dev/null || echo "$1")
    if [[ "'"$VERBOSE"'" == "true" ]]; then
      echo "  Processing: $rel"
    fi
    process_file "$1" "$rel"
  ' _ {} 2>/dev/null; then
  echo "Warning: some files could not be processed — they will appear in Skipped" >&2
fi

total=$(wc -l < "$RESULTS")
transcode=$(grep -c "^.*|Transcode Needed" "$RESULTS" || true)
direct=$((total - transcode))
skipped=$(wc -l < "$SKIPPED" 2>/dev/null || echo 0)

# ── Generate CSV ──────────────────────────────────────────────────────────
generate_csv() {
  {
    echo "path,container,video_codec,audio_codec,subtitle_codec,verdict,reason"
    sort -t'|' -k1 "$RESULTS" | while IFS='|' read -r p c v a s ver reason; do
      printf '"%s","%s","%s","%s","%s","%s","%s"\n' \
        "$p" "$c" "$v" "$a" "$s" "$ver" "$reason"
    done
    if [[ "$skipped" -gt 0 ]]; then
      echo ""
      echo "# Skipped files: $skipped"
      while IFS= read -r f; do
        echo "#   $f"
      done < "$SKIPPED"
    fi
  } > "$OUTPUT_CSV"
  echo "CSV report written to: $OUTPUT_CSV"
}

# ── Generate HTML ─────────────────────────────────────────────────────────
generate_html() {
  {
    echo '<!DOCTYPE html>'
    echo '<html lang="en">'
    echo '<head><meta charset="UTF-8"><title>Transcode Report</title>'
    echo '<style>'
    echo '  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;'
    echo '         margin: 20px; background: #f5f5f5; color: #333; }'
    echo '  h1 { font-size: 1.4em; margin-bottom: 4px; }'
    echo '  .summary { margin: 12px 0; display: flex; gap: 16px; }'
    echo '  .summary span { background: #fff; padding: 6px 14px; border-radius: 6px;'
    echo '                  font-size: 0.9em; box-shadow: 0 1px 2px rgba(0,0,0,0.08); }'
    echo '  .summary .num { font-weight: 700; }'
    echo '  .direct { color: #1a7f1a; } .transcode { color: #b02; }'
    echo '  label { font-size: 0.9em; cursor: pointer; }'
    echo '  table { border-collapse: collapse; width: 100%;'
    echo '          background: #fff; box-shadow: 0 1px 3px rgba(0,0,0,0.1);'
    echo '          border-radius: 6px; overflow: hidden; }'
    echo '  th, td { padding: 6px 10px; text-align: left; font-size: 0.85em;'
    echo '           border-bottom: 1px solid #eee; }'
    echo '  th { background: #444; color: #fff; font-weight: 600; }'
    echo '  tr.direct-play { background: #e8f5e9; }'
    echo '  tr.transcode { background: #ffebee; }'
    echo '  tr.direct-play:hover, tr.transcode:hover { filter: brightness(0.97); }'
    echo '  .reasons { font-style: italic; color: #888; font-size: 0.85em; }'
    echo '  .reasons-td { padding: 0 10px 6px 10px; }'
    echo '  .hidden { display: none; }'
    echo '</style>'
    echo '</head><body>'

    echo "<h1>Transcode Report</h1>"
    echo "<div class=\"summary\">"
    echo "  <span>Scanned: <span class=\"num\">$total</span></span>"
    echo "  <span>Direct Play: <span class=\"num direct\">$direct</span></span>"
    echo "  <span>Transcode Needed: <span class=\"num transcode\">$transcode</span></span>"
    echo "</div>"
    if [[ "$skipped" -gt 0 ]]; then
      echo "<details style=\"margin: 12px 0;\">"
      echo "  <summary style=\"font-size: 0.9em; cursor: pointer; color: #b02;\">Skipped files ($skipped) — could not read</summary>"
      echo "  <ul style=\"color: #b02; font-size: 0.85em;\">"
      while IFS= read -r f; do
        f_esc=$(echo "$f" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
        echo "    <li>$f_esc</li>"
      done < "$SKIPPED"
      echo "  </ul>"
      echo "</details>"
    fi
    echo '<div><label><input type="checkbox" id="filterToggle" onchange="toggleFilter()"> Show only Transcode Needed</label></div>'
    echo '<table><thead><tr>'
    echo '  <th>File</th><th>Container</th><th>Video</th><th>Audio</th><th>Subtitles</th><th>Verdict</th>'
    echo '</tr></thead><tbody>'

    sort -t'|' -k1 "$RESULTS" | while IFS='|' read -r p c v a s ver reason; do
      local row_class
      if [[ "$ver" == "Direct Play" ]]; then
        row_class="direct-play"
      else
        row_class="transcode"
      fi

      # Escape HTML entities
      p_esc=$(echo "$p" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
      c_esc=$(echo "$c" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
      v_esc=$(echo "$v" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
      a_esc=$(echo "$a" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
      s_esc=$(echo "$s" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
      ver_esc=$(echo "$ver" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')

      echo "<tr class=\"$row_class\">"
      echo "  <td>$p_esc</td><td>$c_esc</td><td>$v_esc</td><td>$a_esc</td><td>$s_esc</td><td>$ver_esc</td>"
      echo "</tr>"

      if [[ -n "$reason" ]]; then
        reason_esc=$(echo "$reason" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
        echo "<tr class=\"$row_class reasons-row\">"
        echo "  <td colspan=\"6\" class=\"reasons-td\"><span class=\"reasons\">↳ $reason_esc</span></td>"
        echo "</tr>"
      fi
    done

    echo '</tbody></table>'
    echo '<script>'
    echo 'function toggleFilter() {'
    echo '  var checked = document.getElementById("filterToggle").checked;'
    echo '  var rows = document.querySelectorAll("tr.direct-play");'
    echo '  for (var i = 0; i < rows.length; i++) {'
    echo '    rows[i].classList.toggle("hidden", checked);'
    echo '    var next = rows[i].nextElementSibling;'
    echo '    if (next && next.classList.contains("reasons-row")) {'
    echo '      next.classList.toggle("hidden", checked);'
    echo '    }'
    echo '  }'
    echo '}'
    echo '</script>'
    echo '</body></html>'
  } > "$OUTPUT_HTML"
  echo "HTML report written to: $OUTPUT_HTML"
}

# ── Console output ────────────────────────────────────────────────────────
generate_console() {
  printf "%-80s %-10s %-12s %-18s %-12s %s\n" \
    "File" "Container" "Video" "Audio" "Subtitles" "Verdict"
  printf "%*s\n" 150 "" | tr ' ' '─'

  local display_filter=""
  $ONLY_TRANSCODE && display_filter="Transcode Needed"

  while IFS='|' read -r p c v a s ver reason; do
    [[ -n "$display_filter" && "$ver" != "$display_filter" ]] && continue

    local display_path="$p"
    [[ ${#display_path} -gt 77 ]] && display_path="…${display_path: -76}"

    printf "%-80s %-10s %-12s %-18s %-12s %s\n" \
      "$display_path" "$c" "$v" "$a" "$s" "$ver"

    if [[ -n "$reason" ]]; then
      while IFS=';' read -ra R; do
        for r in "${R[@]}"; do
          r="${r#"${r%%[! ]*}"}"
          [[ -n "$r" ]] && printf "  └─ %s\n" "$r"
        done
      done <<< "$reason"
    fi
  done < "$RESULTS"

  echo ""
  echo "=== Summary ==="
  echo "Total files scanned:   $total"
  echo "Direct Play:          $direct"
  echo "Transcode Needed:     $transcode"
  echo "Skipped (unreadable): $skipped"

  if [[ "$skipped" -gt 0 ]]; then
    echo ""
    echo "=== Skipped Files ($skipped) ==="
    while IFS= read -r f; do
      echo "  $f"
    done < "$SKIPPED"
  fi
}

# ── Dispatch output ───────────────────────────────────────────────────────
case "$FORMAT" in
  csv)
    generate_csv
    generate_console
    ;;
  html)
    generate_html
    ;;
  both)
    generate_csv
    generate_html
    generate_console
    ;;
esac
