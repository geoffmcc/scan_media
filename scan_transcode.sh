#!/usr/bin/env bash
# scan_transcode.sh ??? Scan media libraries with ffprobe and generate HTML/CSV
#                     reports identifying which files need transcoding for
#                     DLNA/Jellyfin playback on a Samsung NU6900 TV
#
# Planned with help by Geoffrey McClinsey, built by OpenCode
set -euo pipefail

# ?????? Defaults ??????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????
SCAN_DIR=""
FORMAT="both"
OUTPUT_STEM=""
OUTPUT_CSV=""
OUTPUT_HTML=""
FILE_LIST_INPUT=""
CHECK_SUBTITLES=true
VERBOSE=false
JOBS=""
EXTENSIONS="mkv,mp4,avi,mov,ts,m2ts,vob,flv,webm,wmv,rmvb"

SUPPORTED_CONTAINERS="mkv mp4 avi mov ts m2ts vob flv webm wmv rmvb"
SUPPORTED_VIDEO="h264 avc h265 hevc mpeg2 mpeg4 vp8 vp9 mjpeg"
TRANSCODE_AUDIO="dts dts-hd dts-hd_ma dts:x dtsx truehd dolby_truehd"
SUPPORTED_SUBS="subrip srt ass ssa smi sub microdvd text ttxt xml mov_text"

# ?????? Help ??????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????
usage() {
  cat <<EOF
Usage: $(basename "$0") /path/to/media [options]

Output:
  --format FMT         csv, html, both (default: both)
  --output FILE        Basename stem (e.g. report -> report.csv + report.html)
  --file-list FILE     Incremental mode: scan only paths listed in FILE

Filtering:
  --no-check-subtitles Skip subtitle stream compatibility checks

Performance:
  --jobs N             Parallel ffprobe workers (default: CPU count)
  --exts "e1,e2,..."   Override default extension list

Troubleshooting:
  --verbose            Print each file as it is processed
  --help               Show this help
EOF
  exit 0
}

# ?????? Parse arguments ?????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????
while [[ $# -gt 0 ]]; do
  case "$1" in
    --format)           FORMAT="$2"; shift 2 ;;
    --output)           OUTPUT_STEM="$2"; shift 2 ;;
    --file-list)        FILE_LIST_INPUT="$2"; shift 2 ;;
    --check-subtitles)  CHECK_SUBTITLES=true; shift ;;
    --no-check-subtitles) CHECK_SUBTITLES=false; shift ;;
    --verbose)          VERBOSE=true; shift ;;
    --jobs)             JOBS="$2"; shift 2 ;;
    --exts)             EXTENSIONS="$2"; shift 2 ;;
    --help)             usage ;;
    -*)                 echo "Unknown option: $1"; usage ;;
    *) [[ -z "$SCAN_DIR" ]] && SCAN_DIR="$1" || { echo "Unexpected: $1"; usage; }; shift ;;
  esac
done

# ?????? Validation ????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????
[[ -n "$SCAN_DIR" ]] || { echo "Error: scan directory required"; usage; }
[[ -d "$SCAN_DIR" ]] || { echo "Error: '$SCAN_DIR' is not a directory"; exit 1; }
[[ -z "$FILE_LIST_INPUT" || -f "$FILE_LIST_INPUT" ]] || { echo "Error: --file-list '$FILE_LIST_INPUT' does not exist"; exit 1; }
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

# ?????? Build find patterns ?????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????
IFS=',' read -ra EXT_LIST <<< "$EXTENSIONS"
FIND_ARGS=()
for ext in "${EXT_LIST[@]}"; do
  FIND_ARGS+=(-o -iname "*.$ext")
done

# ?????? Temp files ????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????
RESULTS=$(mktemp)
SKIPPED=$(mktemp)
cache_stem="${OUTPUT_CSV%.csv}"
CACHE="${cache_stem}.cache"
CACHE_HITS=$(mktemp)
FILE_LIST=$(mktemp)
CHANGED_RELS=$(mktemp)
DIFF_RESULT=$(mktemp)
OLD_SNAPSHOT="${cache_stem}.snapshot"
trap 'rm -f "$RESULTS" "$SKIPPED" "${CACHE_HITS:-}" "$FILE_LIST" "$CHANGED_RELS" "$DIFF_RESULT"' EXIT

# Dedup helper for reason strings
_reason_unique() {
  local needle="$1"; shift
  local e
  for e in "$@"; do [[ "$e" == "$needle" ]] && return 1; done
  return 0
}

is_supported_extension() {
  local path_lc="${1,,}"
  local ext
  for ext in "${EXT_LIST[@]}"; do
    ext="${ext,,}"
    [[ "$path_lc" == *."$ext" ]] && return 0
  done
  return 1
}

normalize_input_path() {
  local raw="$1" full rel
  raw="${raw%$'\r'}"
  [[ -z "$raw" || "$raw" == \#* ]] && return 1
  if [[ "$raw" == /* ]]; then
    full="$raw"
  else
    full="$SCAN_DIR/${raw#./}"
  fi
  if [[ -e "$full" ]]; then
    rel=$(realpath --relative-to="$SCAN_DIR" "$full" 2>/dev/null || printf "%s" "${full#"$SCAN_DIR"/}")
  elif [[ "$full" == "$SCAN_DIR"/* ]]; then
    rel="${full#"$SCAN_DIR"/}"
  else
    rel="${raw#./}"
  fi
  [[ "$rel" == ..* || "$rel" == /* ]] && return 1
  is_supported_extension "$rel" || return 1
  printf '%s|%s\n' "$rel" "$full"
}

# ?????? Process a single file ???????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????
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

  local video_codecs="" audio_codecs="" sub_codecs="" unsupported_audio_codecs=""
  local total_audio=0 unsupported_audio=0
  local verdict="No Issues"
  local has_codec_issue=false has_subtitle_issue=false
  local codec_reasons=() subtitle_reasons=()

  # Container check
  local container_ok=false
  for c in $SUPPORTED_CONTAINERS; do
    if grep -qi "$c" <<< "$container"; then
      container_ok=true
      break
    fi
  done
  if ! $container_ok; then
    codec_reasons+=("Container '$container' not supported")
    has_codec_issue=true
  fi

  while IFS='|' read -r codec_type codec_name codec_tag; do
    case "$codec_type" in
      video)
        local vid_ok=false
        for v in $SUPPORTED_VIDEO; do
          [[ "$codec_name" == "$v" ]] && { vid_ok=true; break; }
        done
        if ! $vid_ok; then
          _reason_unique "Video codec '$codec_name' not supported" "${codec_reasons[@]}" && codec_reasons+=("Video codec '$codec_name' not supported")
          has_codec_issue=true
        fi
        [[ ",$video_codecs," != *",$codec_name,"* ]] && video_codecs="${video_codecs:+$video_codecs,}$codec_name"
        ;;
      audio)
        local aud_bad=false
        for a in $TRANSCODE_AUDIO; do
          if [[ "$codec_name" == "$a" ]]; then
            aud_bad=true
            break
          fi
        done
        if ! $aud_bad && [[ $codec_tag =~ dts(hd|:x|x) ]]; then
          aud_bad=true
        fi
        total_audio=$((total_audio + 1))
        if $aud_bad; then
          unsupported_audio=$((unsupported_audio + 1))
          [[ ",$unsupported_audio_codecs," != *",$codec_name,"* ]] && unsupported_audio_codecs="${unsupported_audio_codecs:+$unsupported_audio_codecs,}$codec_name"
        fi
        [[ ",$audio_codecs," != *",$codec_name,"* ]] && audio_codecs="${audio_codecs:+$audio_codecs,}$codec_name"
        ;;
      subtitle)
        if $CHECK_SUBTITLES; then
          local sub_ok=false
          for s in $SUPPORTED_SUBS; do
            [[ "$codec_name" == "$s" ]] && { sub_ok=true; break; }
          done
          if ! $sub_ok; then
            _reason_unique "Subtitle codec '$codec_name' may require burn-in/transcoding" "${subtitle_reasons[@]}" && subtitle_reasons+=("Subtitle codec '$codec_name' may require burn-in/transcoding")
            has_subtitle_issue=true
          fi
          [[ ",$sub_codecs," != *",$codec_name,"* ]] && sub_codecs="${sub_codecs:+$sub_codecs,}$codec_name"
        fi
        ;;
    esac
  done < <(jq -r '.streams[] | select(.disposition.attached_pic != 1) | [.codec_type // "unknown", (.codec_name // .codec_tag_string // "unknown" | ascii_downcase), (.codec_tag_string // "" | ascii_downcase)] | join("|")' <<< "$json")

  if [[ $total_audio -gt 0 && $unsupported_audio -eq $total_audio ]]; then
    codec_reasons+=("All audio tracks may require transcoding: $unsupported_audio_codecs")
    has_codec_issue=true
  fi

  local issue_type="none"
  if $has_codec_issue && $has_subtitle_issue; then
    verdict="Codec + Subtitle Issues"
    issue_type="codec,subtitle"
  elif $has_codec_issue; then
    verdict="Codec Issues"
    issue_type="codec"
  elif $has_subtitle_issue; then
    verdict="Subtitle Issues"
    issue_type="subtitle"
  fi

  local reason_str=""
  local reason_parts=("${codec_reasons[@]}" "${subtitle_reasons[@]}")
  if [[ ${#reason_parts[@]} -gt 0 ]]; then
    reason_str=$(printf '%s; ' "${reason_parts[@]}")
    reason_str="${reason_str%; }"
  fi
  echo "$relpath|$container|$video_codecs|$audio_codecs|$sub_codecs|$verdict|$issue_type|$reason_str" >> "$RESULTS"
}

export -f process_file _reason_unique
export SCAN_DIR RESULTS CACHE_HITS SUPPORTED_CONTAINERS SUPPORTED_VIDEO TRANSCODE_AUDIO SUPPORTED_SUBS CHECK_SUBTITLES SKIPPED VERBOSE

# ?????? Scan ??????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????
echo "Scanning: $SCAN_DIR"
echo "Extensions: $EXTENSIONS"
echo "Parallel jobs: $JOBS"
if [[ -n "$FILE_LIST_INPUT" ]]; then
  echo "Incremental file list: $FILE_LIST_INPUT"
fi
echo ""

INCREMENTAL=false
[[ -n "$FILE_LIST_INPUT" ]] && INCREMENTAL=true

if $INCREMENTAL; then
  while IFS= read -r input_path || [[ -n "$input_path" ]]; do
    normalized=$(normalize_input_path "$input_path" || true)
    [[ -z "$normalized" ]] && continue
    rel="${normalized%%|*}"
    full="${normalized#*|}"
    echo "$rel" >> "$CHANGED_RELS"
    [[ -f "$full" ]] && printf '%s\0' "$full" >> "$FILE_LIST"
  done < "$FILE_LIST_INPUT"
  sort -u "$CHANGED_RELS" -o "$CHANGED_RELS"
else
  # Generate file list once (reused for count and xargs)
  find "$SCAN_DIR" -type f \( "${FIND_ARGS[@]:1}" \) -print0 2>/dev/null > "$FILE_LIST"
fi

# ?????? Pre-populate RESULTS from cache ??????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????
if [[ -f "$CACHE" ]]; then
  # Validate config header — delete cache if flags have changed
  IFS= read -r header_line < "$CACHE"
  if [[ "$header_line" != "# config:schema=2;check_subtitles=$CHECK_SUBTITLES" ]]; then
    rm -f "$CACHE"
  else
    while IFS='|' read -r cached_mtime cached_path cached_rest; do
      if $INCREMENTAL; then
        if ! grep -Fxq "$cached_path" "$CHANGED_RELS" 2>/dev/null; then
          if [[ "$cached_rest" =~ ^SKIPPED\| ]]; then
            err="${cached_rest#SKIPPED|}"
            echo "$cached_path: $err" >> "$SKIPPED"
          else
            echo "$cached_path|$cached_rest" >> "$RESULTS"
          fi
        fi
      else
        full="$SCAN_DIR/$cached_path"
        if [[ -f "$full" ]]; then
          cur_mtime=$(stat -c '%Y' "$full" 2>/dev/null || echo "0")
          if [[ "$cur_mtime" == "$cached_mtime" ]]; then
            if [[ "$cached_rest" =~ ^SKIPPED\| ]]; then
              err="${cached_rest#SKIPPED|}"
              echo "$cached_path: $err" >> "$SKIPPED"
            else
              echo "$cached_path|$cached_rest" >> "$RESULTS"
            fi
            echo "$cached_path" >> "$CACHE_HITS"
          fi
        fi
      fi
    done < <(tail -n +2 "$CACHE")
  fi
fi

if $INCREMENTAL; then
  changed_count=$(wc -l < "$CHANGED_RELS" 2>/dev/null || echo 0)
  to_scan=$(< "$FILE_LIST" tr '\0' '\n' | wc -l 2>/dev/null || echo 0)
  missing_count=$((changed_count - to_scan))
  [[ $missing_count -lt 0 ]] && missing_count=0
  echo "Incremental changes: $changed_count  (existing to scan: $to_scan  removed/missing: $missing_count)"
else
  file_count=$(< "$FILE_LIST" tr '\0' '\n' | wc -l 2>/dev/null || echo 0)
  cached_count=$(wc -l < "$CACHE_HITS" 2>/dev/null || echo 0)
  to_scan=$((file_count - cached_count))
  echo "Files found: $file_count  (cached: $cached_count  to scan: $to_scan)"
fi
echo ""

CACHE_DIRTY=false
if $INCREMENTAL; then
  [[ ${changed_count:-0} -gt 0 ]] && CACHE_DIRTY=true
elif [[ $to_scan -gt 0 ]]; then
  CACHE_DIRTY=true
fi

REUSE_REPORTS=false
if ! $INCREMENTAL && [[ $to_scan -eq 0 ]]; then
  case "$FORMAT" in
    csv)  [[ -f "$OUTPUT_CSV" ]] && REUSE_REPORTS=true ;;
    html) [[ -f "$OUTPUT_HTML" ]] && REUSE_REPORTS=true ;;
    both) [[ -f "$OUTPUT_CSV" && -f "$OUTPUT_HTML" ]] && REUSE_REPORTS=true ;;
  esac
fi

if [[ $to_scan -gt 0 ]]; then
  if ! xargs -0 -P "$JOBS" -I {} bash -c '
    rel=$(realpath --relative-to="$SCAN_DIR" "$1" 2>/dev/null || printf "%s" "$1")
    grep -Fxq "$rel" "$CACHE_HITS" 2>/dev/null && exit 0
    if [ "$VERBOSE" = "true" ]; then
      printf "  Processing: %s\n" "$rel" >&2
    fi
    process_file "$1" "$rel"
  ' _ {} 2>/dev/null < "$FILE_LIST"; then
    echo "Warning: some files could not be processed" >&2
  fi
else
  if $INCREMENTAL; then
    echo "No existing changed media files to scan."
  else
    echo "All files up to date in cache."
  fi
fi

total=$(wc -l < "$RESULTS")
no_issues=$(awk -F'|' '$7 == "none" { count++ } END { print count + 0 }' "$RESULTS")
codec_issues=$(awk -F'|' '$7 ~ /(^|,)codec(,|$)/ { count++ } END { print count + 0 }' "$RESULTS")
subtitle_issues=$(awk -F'|' '$7 ~ /(^|,)subtitle(,|$)/ { count++ } END { print count + 0 }' "$RESULTS")
both_issues=$(awk -F'|' '$7 == "codec,subtitle" { count++ } END { print count + 0 }' "$RESULTS")
skipped=$(wc -l < "$SKIPPED" 2>/dev/null || echo 0)

# ?????? Rebuild cache from RESULTS ?????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????
if $CACHE_DIRTY; then
  {
    echo "# config:schema=2;check_subtitles=$CHECK_SUBTITLES"
    while IFS='|' read -r path rest; do
      full="$SCAN_DIR/$path"
      if [[ -f "$full" ]]; then
        mtime=$(stat -c '%Y' "$full" 2>/dev/null || echo "0")
        echo "$mtime|$path|$rest"
      fi
    done < "$RESULTS"
    while IFS=':' read -r path err_rest; do
      full="$SCAN_DIR/$path"
      if [[ -f "$full" ]]; then
        mtime=$(stat -c '%Y' "$full" 2>/dev/null || echo "0")
        err="${err_rest# }"
        echo "$mtime|$path|SKIPPED|$err"
      fi
    done < "$SKIPPED"
  } > "$CACHE"
fi

# ?????? Diff against previous run ?????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????
if ! $CACHE_DIRTY; then
  {
    echo "=== Changes since last run ==="
    echo "  No changes detected."
  } > "$DIFF_RESULT"
elif [[ -f "$OLD_SNAPSHOT" ]]; then
  {
    echo "=== Changes since last run ==="
    changes=0
    exec 3<"$OLD_SNAPSHOT"
    exec 4< <(awk -F'|' '{print $6 "|" $1}' "$RESULTS" | sort -t'|' -k2)
    read -r old_line <&3 || old_line=""
    read -r new_line <&4 || new_line=""
    while [[ -n "$old_line" || -n "$new_line" ]]; do
      old_path="${old_line#*|}"
      new_path="${new_line#*|}"
      if [[ -z "$new_line" ]]; then
        echo "  GONE: $old_path"
        changes=1
        read -r old_line <&3 || old_line=""
      elif [[ -z "$old_line" ]]; then
        new_verdict="${new_line%%|*}"
        echo "  NEW: $new_verdict - $new_path"
        changes=1
        read -r new_line <&4 || new_line=""
      elif [[ "$old_path" < "$new_path" ]]; then
        echo "  GONE: $old_path"
        changes=1
        read -r old_line <&3 || old_line=""
      elif [[ "$new_path" < "$old_path" ]]; then
        new_verdict="${new_line%%|*}"
        echo "  NEW: $new_verdict - $new_path"
        changes=1
        read -r new_line <&4 || new_line=""
      else
        old_verdict="${old_line%%|*}"
        new_verdict="${new_line%%|*}"
        if [[ "$old_verdict" != "$new_verdict" ]]; then
          if [[ "$new_verdict" == "No Issues" ]]; then
            echo "  FIXED: $new_path"
          else
            echo "  CHANGED: $old_verdict -> $new_verdict - $new_path"
          fi
          changes=1
        fi
        read -r old_line <&3 || old_line=""
        read -r new_line <&4 || new_line=""
      fi
    done
    exec 3<&-
    exec 4<&-
    [[ $changes -eq 0 ]] && echo "  No changes detected."
  } > "$DIFF_RESULT"
fi

# Write new snapshot
if $CACHE_DIRTY; then
  awk -F'|' '{print $6 "|" $1}' "$RESULTS" | sort -t'|' -k2 > "$OLD_SNAPSHOT"
fi

csv_quote() {
  local s="$1"
  s="${s//\"/\"\"}"
  printf '"%s"' "$s"
}

# ?????? Generate CSV ??????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????
generate_csv() {
  if $REUSE_REPORTS; then
    echo "CSV report unchanged: $OUTPUT_CSV"
    return
  fi

  {
    echo "path,container,video_codec,audio_codec,subtitle_codec,verdict,issue_type,reason"
    while IFS='|' read -r p c v a s ver issue_type reason; do
      printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$(csv_quote "$p")" "$(csv_quote "$c")" "$(csv_quote "$v")" \
        "$(csv_quote "$a")" "$(csv_quote "$s")" "$(csv_quote "$ver")" \
        "$(csv_quote "$issue_type")" "$(csv_quote "$reason")"
    done < <(sort -t'|' -k1 "$RESULTS")
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

# ?????? Generate HTML ???????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????
generate_html() {
  if $REUSE_REPORTS; then
    echo "HTML report unchanged: $OUTPUT_HTML"
    return
  fi

  {
    echo '<!DOCTYPE html>'
    echo '<html lang="en">'
    echo '<head><meta charset="UTF-8"><title>Transcode Report</title>'
    echo '<style>'
    echo '  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;'
    echo '         margin: 20px; background: #f5f5f5; color: #333; }'
    echo '  h1 { font-size: 1.4em; margin-bottom: 4px; }'
    echo '  .summary { margin: 12px 0; display: flex; gap: 16px; flex-wrap: wrap; }'
    echo '  .summary span, .filters label { background: #fff; padding: 6px 14px; border-radius: 6px;'
    echo '                  font-size: 0.9em; box-shadow: 0 1px 2px rgba(0,0,0,0.08); }'
    echo '  .summary .num { font-weight: 700; }'
    echo '  .direct { color: #1a7f1a; } .codec { color: #b02; } .subtitle { color: #9a6700; }'
    echo '  label { font-size: 0.9em; cursor: pointer; }'
    echo '  .filters { display:flex; gap:16px; flex-wrap:wrap; margin: 12px 0; }'
    echo '  table { border-collapse: collapse; width: 100%;'
    echo '          background: #fff; box-shadow: 0 1px 3px rgba(0,0,0,0.1);'
    echo '          border-radius: 6px; overflow: hidden; }'
    echo '  th, td { padding: 6px 10px; text-align: left; font-size: 0.85em;'
    echo '           border-bottom: 1px solid #eee; }'
    echo '  th { background: #444; color: #fff; font-weight: 600; }'
    echo '  tr.no-issues { background: #e8f5e9; }'
    echo '  tr.subtitle-issue { background: #fff3cd; }'
    echo '  tr.codec-issue { background: #ffebee; }'
    echo '  tr.codec-issue.subtitle-issue { background: linear-gradient(90deg, #ffebee 0%, #ffebee 50%, #fff3cd 50%, #fff3cd 100%); }'
    echo '  tr.no-issues:hover, tr.subtitle-issue:hover, tr.codec-issue:hover { filter: brightness(0.97); }'
    echo '  .reasons { font-style: italic; color: #888; font-size: 0.85em; }'
    echo '  .reasons-td { padding: 0 10px 6px 10px; }'
    echo '  .hidden { display: none; }'
    echo '</style>'
    echo '</head><body>'

    echo "<h1>Transcode Report</h1>"
    echo "<div class=\"summary\">"
    echo "  <span>Scanned: <span class=\"num\">$total</span></span>"
    echo "  <span>No Issues: <span class=\"num direct\">$no_issues</span></span>"
    echo "  <span>Codec Issues: <span class=\"num codec\">$codec_issues</span></span>"
    echo "  <span>Subtitle Issues: <span class=\"num subtitle\">$subtitle_issues</span></span>"
    echo "  <span>Both: <span class=\"num\">$both_issues</span></span>"
    echo "</div>"
    if [[ "$skipped" -gt 0 ]]; then
      echo "<details style=\"margin: 12px 0;\">"
      echo "  <summary style=\"font-size: 0.9em; cursor: pointer; color: #b02;\">Skipped files ($skipped) ??? could not read</summary>"
      echo "  <ul style=\"color: #b02; font-size: 0.85em;\">"
      while IFS= read -r f; do
        f_esc=$(echo "$f" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
        echo "    <li>$f_esc</li>"
      done < "$SKIPPED"
      echo "  </ul>"
      echo "</details>"
    fi
    echo '<div class="filters">'
    echo '  <label><input type="checkbox" id="showNone" checked onchange="toggleFilter()"> No Issues</label>'
    echo '  <label><input type="checkbox" id="showCodec" checked onchange="toggleFilter()"> Codec Issues</label>'
    echo '  <label><input type="checkbox" id="showSubtitle" checked onchange="toggleFilter()"> Subtitle Issues</label>'
    echo '</div>'
    echo '<table>'
    echo '<colgroup>'
    echo '  <col style="width: 1%"><!-- File: min-width, expand as needed -->'
    echo '  <col style="width: 1%"><!-- Container -->'
    echo '  <col style="width: 1%"><!-- Video -->'
    echo '  <col style="width: 1%"><!-- Audio -->'
    echo '  <col style="width: 1%"><!-- Subtitles -->'
    echo '  <col style="width: 1%"><!-- Verdict -->'
    echo '</colgroup>'
    echo '<thead><tr>'
    echo '  <th>File</th><th>Container</th><th>Video</th><th>Audio</th><th>Subtitles</th><th>Verdict</th>'
    echo '</tr></thead><tbody>'

    sort -t'|' -k1 "$RESULTS" | while IFS='|' read -r p c v a s ver issue_type reason; do
      local row_class
      row_class=""
      [[ "$issue_type" == "none" ]] && row_class="no-issues"
      [[ "$issue_type" == *"codec"* ]] && row_class="${row_class:+$row_class }codec-issue"
      [[ "$issue_type" == *"subtitle"* ]] && row_class="${row_class:+$row_class }subtitle-issue"

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
        echo "  <td colspan=\"6\" class=\"reasons-td\"><span class=\"reasons\">??? $reason_esc</span></td>"
        echo "</tr>"
      fi
    done

    echo '</tbody></table>'
    echo '<script>'
    echo 'function toggleFilter() {'
    echo '  var showNone = document.getElementById("showNone").checked;'
    echo '  var showCodec = document.getElementById("showCodec").checked;'
    echo '  var showSubtitle = document.getElementById("showSubtitle").checked;'
    echo '  var rows = document.querySelectorAll("tbody tr:not(.reasons-row)");'
    echo '  for (var i = 0; i < rows.length; i++) {'
    echo '    var row = rows[i];'
    echo '    var visible = false;'
    echo '    if (row.classList.contains("no-issues") && showNone) visible = true;'
    echo '    if (row.classList.contains("codec-issue") && showCodec) visible = true;'
    echo '    if (row.classList.contains("subtitle-issue") && showSubtitle) visible = true;'
    echo '    row.classList.toggle("hidden", !visible);'
    echo '    var next = row.nextElementSibling;'
    echo '    if (next && next.classList.contains("reasons-row")) next.classList.toggle("hidden", !visible);'
    echo '  }'
    echo '}'
    echo '</script>'
    echo '</body></html>'
  } > "$OUTPUT_HTML"
  echo "HTML report written to: $OUTPUT_HTML"
}

# ?????? Console output ????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????
generate_console() {
  echo "=== Summary ==="
  echo "Total files scanned:   $total"
  echo "No Issues:           $no_issues"
  echo "Codec Issues:        $codec_issues"
  echo "Subtitle Issues:     $subtitle_issues"
  echo "Both Issue Types:    $both_issues"
  echo "Skipped (unreadable): $skipped"

  if [[ -s "$DIFF_RESULT" ]]; then
    echo ""
    cat "$DIFF_RESULT"
  fi

  if [[ "$skipped" -gt 0 ]]; then
    echo ""
    echo "=== Skipped Files ($skipped) ==="
    while IFS= read -r f; do
      echo "  $f"
    done < "$SKIPPED"
  fi
}

# ?????? Dispatch output ?????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????
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
