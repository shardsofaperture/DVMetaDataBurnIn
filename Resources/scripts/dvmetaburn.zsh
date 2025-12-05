#!/bin/zsh

set -euo pipefail
setopt NULL_GLOB

# Ensure baseline coreutils are available even when PATH is sanitized by the
# app bundle environment.
PATH="/bin:/usr/bin:/usr/local/bin:${PATH:-}"
export PATH

# Ensure zsh temp files go somewhere writable
: "${TMPDIR:=/tmp}"
TMPDIR="${TMPDIR%/}"
TMPPREFIX="${TMPDIR}/zsh-"

mkdir -p "$TMPDIR"
export TMPDIR TMPPREFIX

fatal() {
  echo "[ERROR] $*" >&2
  exit 1
}

warn() {
  echo "[WARN] $*" >&2
}

info() {
  echo "[INFO] $*" >&2
}

debug() {
  (( debug_mode == 1 )) && echo "[DEBUG] $*" >&2
}

########################################################
# Defaults / configuration
########################################################

mode="single"        # "single" or "batch"
layout="stacked"     # "stacked" or "single"
format="mov"         # "mov" or "mp4"
burn_mode="burnin"   # "burnin" or "passthrough" or "subtitleTrack"
missing_meta="skip_burnin_convert"  # behavior when metadata is missing
fontfile=""
fontname="UAV-OSD-Mono"
ffmpeg_bin="ffmpeg"
dvrescue_bin="dvrescue"
artifact_root="${HOME}/Library/Logs/DVMeta"
# Opt-in verbose logging for troubleshooting
debug_mode=0

# Shared header for frame timeline artifacts
typeset -gr timeline_header=$'frame_index\tt_sec\tdate_part\ttime_part\tdt_key\tsegment_change'

# Optional environment overrides
: "${DVMETABURN_FONTFILE:=}"   # override font path

########################################################
# CLI flag parsing
########################################################

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode=*) mode="${1#*=}"; shift ;;
    --layout=*) layout="${1#*=}"; shift ;;
    --format=*) format="${1#*=}"; shift ;;
    --burn-mode=*) burn_mode="${1#*=}"; shift ;;
    --missing-meta=*) missing_meta="${1#*=}"; shift ;;
    --fontfile=*) fontfile="${1#*=}"; shift ;;
    --fontname=*) fontname="${1#*=}"; shift ;;
    --ffmpeg=*) ffmpeg_bin="${1#*=}"; shift ;;
    --dvrescue=*) dvrescue_bin="${1#*=}"; shift ;;
    --debug) debug_mode=1; shift ;;
    --) shift; break ;;
    -*) fatal "Unknown option: $1" ;;
    *) break ;;
  esac
done

# Normalize missing metadata handling
missing_meta="${missing_meta//[[:space:]]/}"
missing_meta="${missing_meta//-/_}"
missing_meta="${missing_meta:l}"

case "$missing_meta" in
  skipburninconvert)
    missing_meta="skip_burnin_convert"
    ;;
  skipfile)
    missing_meta="skip_file"
    ;;
  error)
    missing_meta="error"
    ;;
  skip_burnin_convert | skip_file)
    ;;
  *)
    echo "[WARN] Unknown missing-meta value '$missing_meta'; defaulting to 'error'" >&2
    missing_meta="error"
    ;;
esac

# Track parse stats for manifest writing
typeset -g last_parse_raw_rows=0
typeset -g last_parse_valid_rows=0
typeset -g last_parse_skipped_rows=0
typeset -g last_parse_timeline_entries=0
typeset -g last_parse_frame_source="unknown"
typeset -g last_dvrescue_status=0
typeset -g last_detected_fps=""

prepare_artifact_dir() {
  local input_path="$1"
  local base_name ts dir_name

  base_name="${input_path##*/}"
  base_name="${base_name%.*}"
  ts="$(date '+%Y%m%d_%H%M%S')"
  dir_name="${artifact_root%/}/${base_name}_${ts}"

  if ! mkdir -p "$dir_name"; then
    echo "[ERROR] Unable to create artifact directory: $dir_name" >&2
    return 1
  fi

  echo "[INFO] Artifact directory: $dir_name" >&2
  debug_log "Artifacts will be stored in $dir_name"
  echo "$dir_name"
}

stat_size_bytes() {
  local path="$1"
  stat -f %z "$path" 2>/dev/null || stat -c %s "$path" 2>/dev/null || echo "unknown"
}

log_artifact_path_and_size() {
  local label="$1"
  local path="$2"

  if [[ -e "$path" ]]; then
    echo "[INFO] ${label}: ${path} (size: $(stat_size_bytes "$path") bytes)" >&2
  else
    echo "[INFO] ${label}: ${path} (missing)" >&2
  fi
}

# Lightweight helper for conditional debug output
debug_log() {
  if (( debug_mode == 1 )); then
    echo "[DEBUG] $*" >&2
  fi
}

########################################################
# Helper: detect FPS using ffmpeg probe output
########################################################

detect_fps() {
  local src="$1"
  local fps

  last_detected_fps=""

  local probe_output
  probe_output="$("$ffmpeg_bin" -hide_banner -i "$src" 2>&1)"

  fps="$(printf "%s\n" "$probe_output" | awk '/Video:/ && /fps/ { for (i=1;i<=NF;i++) if ($i ~ /fps/) {print $(i-1); exit}}')"

  if [[ "$fps" == */* ]]; then
    fps=$(awk -v v="$fps" 'BEGIN{split(v,a,"/"); if (a[2]==0) {exit 1} printf "%.6f", a[1]/a[2]}') || fps=""
  fi

  if [[ -z "$fps" ]]; then
    echo "[ERROR] Unable to detect FPS for $src" >&2
    if (( debug_mode == 1 )); then
      printf "%s\n" "$probe_output" | awk '/Video:/' | while IFS= read -r line; do
        debug_log "ffmpeg probe Video line: $line"
      done
    fi
    return 1
  fi

  last_detected_fps="$fps"
  echo "$fps"
}


########################################################
# XML / LOG helpers
########################################################

extract_rdt_from_xml() {
  local xml_path="$1"

  if [[ -z "$xml_path" || ! -s "$xml_path" ]]; then
    echo "[ERROR] XML payload missing or empty: $xml_path" >&2
    return 1
  fi

  perl -0777 -ne '
    my $idx = 0;
    while (/<frame\b([^>]*?)(?:\/>|>(.*?)<\/frame>)/sg) {
      my ($attrs, $body) = ($1, $2 // q{});

      my ($date, $time);

      if ($attrs =~ /\brdt=\"([^\"]+)\"/) {
        my $rdt = $1;
        ($date, $time) = split(/\s+/, $rdt, 2);
      } elsif ($body =~ /<recordingDateTime[^>]*>.*?<date>([^<]*)<\/date>.*?<time>([^<]*)<\/time>/s) {
        ($date, $time) = ($1, $2);
      } elsif ($body =~ /<recordingDateTime[^>]*>.*?<time>([^<]*)<\/time>.*?<date>([^<]*)<\/date>/s) {
        ($time, $date) = ($1, $2);
      }

      next unless defined $date && defined $time;

      $date =~ s/^\s+|\s+$//g;
      $time =~ s/^\s+|\s+$//g;

      next if $date eq q{} || $time eq q{};

      my $frame = $idx;
      if ($attrs =~ /\bn=\"([0-9]+)\"/) {
        $frame = $1;
      }

      printf "%d %s %s\n", $frame, $date, $time;
      $idx++;
    }
  ' "$xml_path"
}

# PRIMARY SOURCE: parse dvrescue log into frame / date / time TSV.
build_rdt_from_log() {
  local log="$1"

  if [[ -z "$log" || ! -s "$log" ]]; then
    echo "[ERROR] dvrescue log missing or empty: $log" >&2
    return 1
  fi

  awk '
    BEGIN { rows = 0 }

    {
      # Strip ALL leading whitespace
      sub(/^[[:space:]]+/, "", $0)

      # Expected layout (very loose):
      #   $1 = frame index
      #   $2 = SMPTE timecode (ignored)
      #   $3 = YYYY-MM-DD
      #   $4 = HH:MM:SS
      if (NF >= 4 && $1 ~ /^[0-9]+$/) {
        printf "%s\t%s\t%s\n", $1, $3, $4
        rows++
      }
    }

    END {
      if (rows == 0) exit 1
    }
  ' "$log"
}

# Try XML then log, but prefer LOG when it has usable rows.
build_rdt_tmp() {
  local xml_path="$1"
  local log_path="$2"
  local tmp_var="$3"
  local source_var="$4"

  local frame_source="unknown"
  local -i final_rows=0
  local -i xml_rows=0 log_rows=0
  local -i log_min_rows=10
  local prefer_log=0

  local xml_tmp="" log_tmp="" tmp_path=""

  if (( last_dvrescue_status == 0 )) && [[ -n "$log_path" && -s "$log_path" ]]; then
    prefer_log=1
  fi

  if [[ -n "$xml_path" && -s "$xml_path" ]]; then
    xml_tmp=$(make_temp_file dvmeta_rdt_xml ".tsv") || return 1
    if ! extract_rdt_from_xml "$xml_path" > "$xml_tmp"; then
      debug_log "extract_rdt_from_xml failed for $xml_path; continuing to log evaluation"
      : > "$xml_tmp"
    fi
    xml_rows=$(wc -l < "$xml_tmp" | tr -d " ")
  else
    debug_log "XML path missing or empty; skipping XML parse (xml_path=$xml_path)"
  fi

  if [[ -n "$log_path" && -s "$log_path" ]]; then
    log_tmp=$(make_temp_file dvmeta_rdt_log ".tsv") || return 1
    if ! build_rdt_from_log "$log_path" > "$log_tmp"; then
      debug_log "build_rdt_from_log failed for $log_path"
      : > "$log_tmp"
    fi
    log_rows=$(wc -l < "$log_tmp" | tr -d ' ')
  else
    debug_log "dvrescue log missing or empty; skipping log parse (log_path=$log_path)"
  fi

  if (( prefer_log == 1 && log_rows >= log_min_rows )); then
    frame_source="log"
    final_rows=$log_rows
    tmp_path="$log_tmp"
  elif (( log_rows > 0 )); then
    frame_source="log"
    final_rows=$log_rows
    tmp_path="$log_tmp"
  elif (( xml_rows > 0 )); then
    frame_source="xml"
    final_rows=$xml_rows
    tmp_path="$xml_tmp"
  else
    tmp_path=$(make_temp_file dvmeta_rdt ".tsv") || return 1
    : > "$tmp_path"
  fi

  echo "[INFO] build_rdt_tmp xml_path=$xml_path log_path=$log_path xml_rows=$xml_rows log_rows=$log_rows source=$frame_source final_rows=$final_rows" >&2
  debug_log "build_rdt_tmp (detailed) xml_rows=$xml_rows log_rows=$log_rows final_rows=$final_rows source=$frame_source"

  if (( final_rows == 0 )); then
    echo "[WARN] Unable to derive RDT timeline from XML or dvrescue log" >&2
    return 2
  fi

  printf -v "$tmp_var" '%s' "$tmp_path"
  printf -v "$source_var" '%s' "$frame_source"
  return 0
}

# Optional: first available RDT (not currently used by burn-in)
extract_first_rdt() {
  local xml_path="$1"
  local log_path="$2"
  local dt_var="$3"
  local source_var="$4"

  local dt="" source="unknown"

  if [[ -n "$xml_path" && -s "$xml_path" ]]; then
    dt=$(perl -ne 'if (/rdt=\"([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2})\"/) { print $1; exit }' "$xml_path")
    if [[ -z "$dt" ]]; then
      dt=$(perl -0777 -ne 'if (/<recordingDateTime[^>]*>.*?<date>([^<]+)<\/date>.*?<time>([^<]+)<\/time>/s) {print "$1 $2"; exit}' "$xml_path")
    fi
    [[ -n "$dt" ]] && source="xml"
  fi

  if [[ -z "$dt" && -n "$log_path" && -s "$log_path" ]]; then
    dt=$(grep -m1 -E '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' "$log_path" | \
         awk '{for (i=1;i<NF;i++) if ($i ~ /^[0-9]{4}-/ && $(i+1) ~ /^[0-9]{2}:/) {print $i " " $(i+1); exit}}')
    [[ -n "$dt" ]] && source="log"
  fi

  if [[ -z "$dt" ]]; then
    return 1
  fi

  printf -v "$dt_var" '%s' "$dt"
  printf -v "$source_var" '%s' "$source"
  return 0
}

# Allocate a temporary file in TMPDIR
make_temp_file() {
  local prefix="${1:-dvmeta}"
  local ext="${2:-}"
  local path tmpdir mktemp_cmd

  tmpdir="${TMPDIR:-/tmp}"
  tmpdir="${tmpdir%/}"

  if mktemp_cmd="$(command -v mktemp 2>/dev/null)" && [[ -n "$mktemp_cmd" ]]; then
    :
  else
    mktemp_cmd=""
  fi

  [[ -z "$mktemp_cmd" && -x /usr/bin/mktemp ]] && mktemp_cmd="/usr/bin/mktemp"

  if [[ -n "$mktemp_cmd" ]]; then
    debug_log "make_temp_file using mktemp: $mktemp_cmd"
    path=$("$mktemp_cmd" "${tmpdir}/${prefix}.XXXXXX") || return 127
  else
    debug_log "make_temp_file using manual fallback in ${tmpdir}"
    local i candidate
    for i in {1..10}; do
      candidate="${tmpdir}/${prefix}.$(date +%s).${RANDOM}${RANDOM}"
      if (set -o noclobber; : >"$candidate") 2>/dev/null; then
        path="$candidate"
        break
      fi
    done

    [[ -n "${path:-}" ]] || return 127
  fi

  if [[ -n "$ext" ]]; then
    local new_path="${path}${ext}"
    /bin/mv "$path" "$new_path"
    path="$new_path"
  fi

  echo "$path"
}

log_file_excerpt() {
  (( debug_mode == 1 )) || return 0

  local label="$1"
  local path="$2"
  local -i max_lines=${3:-20}

  local wc_cmd
  wc_cmd=$(command -v wc 2>/dev/null)
  [[ -n "$wc_cmd" && -x "$wc_cmd" ]] || wc_cmd=""
  [[ -z "$wc_cmd" && -x /bin/wc ]] && wc_cmd="/bin/wc"
  [[ -z "$wc_cmd" && -x /usr/bin/wc ]] && wc_cmd="/usr/bin/wc"

  if [[ -z "$wc_cmd" ]]; then
    debug_log "$label missing or empty (path: $path)"
    return 0
  fi

  if [[ -s "$path" ]]; then
    debug_log "$label (path: $path, size: $("$wc_cmd" -c <"$path") bytes):"
    local -i count=0
    while IFS= read -r line && (( count < max_lines )); do
      debug_log "  $line"
      (( count++ ))
    done <"$path"

    if (( $("$wc_cmd" -l <"$path") > max_lines )); then
      debug_log "  ... (truncated after $max_lines lines)"
    fi
  else
    debug_log "$label missing or empty (path: $path)"
  fi
}

emit_debug_snapshots() {
  (( debug_mode == 1 )) || return 0

  local timeline_path="$1"
  local cmd_path="$2"

  log_file_excerpt "timeline debug preview" "$timeline_path" 10
  log_file_excerpt "timestamp.cmd preview" "$cmd_path" 10
}

write_versions_file() {
  local path="$1"

  {
    if command -v "$ffmpeg_bin" >/dev/null 2>&1; then
      "$ffmpeg_bin" -version 2>/dev/null | head -n 1
    else
      echo "ffmpeg: unavailable"
    fi

    if command -v "$dvrescue_bin" >/dev/null 2>&1; then
      "$dvrescue_bin" --version 2>/dev/null | head -n 1
    else
      echo "dvrescue: unavailable"
    fi

    echo "fps: ${last_detected_fps:-}"
    echo "dvrescue_status: $last_dvrescue_status"
    echo "frame_source: $last_parse_frame_source"
    echo "parse_stats: raw=${last_parse_raw_rows}, valid=${last_parse_valid_rows}, skipped=${last_parse_skipped_rows}, timeline=${last_parse_timeline_entries}"
  } > "$path" 2>/dev/null || true

  echo "[INFO] Versions file recorded at: $path" >&2
}

write_run_manifest() {
  local manifest_path="$1"
  local status_label="$2"
  local input_path="$3"
  local artifact_dir="$4"
  local xml_path="$5"
  local log_path="$6"
  local timeline_path="$7"
  local sendcmd_path="$8"
  local ass_path="$9"
  local burn_output="${10}"
  local subtitle_output="${11}"
  local passthrough_output="${12}"
  local versions_path="${13}"

  cat > "$manifest_path" <<EOF
{
  "status": "$status_label",
  "input": "$input_path",
  "artifact_dir": "$artifact_dir",
  "burn_mode": "$burn_mode",
  "layout": "$layout",
  "format": "$format",
  "artifacts": {
    "dvrescue_xml": "$xml_path",
    "dvrescue_log": "$log_path",
    "timeline_debug": "$timeline_path",
    "sendcmd_file": "$sendcmd_path",
    "ass_file": "$ass_path",
    "versions_file": "$versions_path",
    "run_manifest": "$manifest_path"
  },
  "outputs": {
    "burnin": "$burn_output",
    "subtitle": "$subtitle_output",
    "passthrough": "$passthrough_output"
  },
  "parse": {
    "frame_source": "$last_parse_frame_source",
    "raw_rows": $last_parse_raw_rows,
    "valid_rows": $last_parse_valid_rows,
    "skipped_rows": $last_parse_skipped_rows,
    "timeline_entries": $last_parse_timeline_entries,
    "dvrescue_status": $last_dvrescue_status,
    "fps": "${last_detected_fps}"
  }
}
EOF

  echo "[INFO] Run manifest recorded at: $manifest_path" >&2
}

finish_run() {
  local exit_code="$1"
  local status_label="$2"
  local input_path="$3"
  local artifact_dir="$4"
  local dvrescue_xml="$5"
  local dvrescue_log="$6"
  local timeline_path="$7"
  local cmd_path="$8"
  local ass_path="$9"
  local burn_output="${10}"
  local subtitle_output="${11}"
  local passthrough_output="${12}"
  local versions_file="${13}"
  local manifest_path="${14}"

  write_versions_file "$versions_file"
  write_run_manifest "$manifest_path" "$status_label" "$input_path" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_path" "$cmd_path" "$ass_path" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file"

  if [[ "$status_label" == "success" ]]; then
    emit_debug_snapshots "$timeline_path" "$cmd_path"
  fi

  return "$exit_code"
}

########################################################
# Helper: locate a font file
########################################################

find_font() {
  local -a candidates

  # 1) Explicit CLI flag wins
  if [[ -n "$fontfile" ]]; then
    candidates+=("$fontfile")
  fi

  # 2) Environment override
  if [[ -n "$DVMETABURN_FONTFILE" ]]; then
    candidates+=("$DVMETABURN_FONTFILE")
  fi

  # 3) Bundled fonts next
  local script_dir="${0:A:h}"
  local -a font_names=(
    "UAV-OSD-Mono.ttf"
    "UAV-OSD-Sans-Mono.ttf"
    "VCR_OSD_MONO_1.001.ttf"
  )

  local resource_fonts_dirs=(
    "${script_dir}/fonts"
    "${script_dir}/../fonts"
  )

  local d fname
  for d in "${resource_fonts_dirs[@]}"; do
    for fname in "${font_names[@]}"; do
      candidates+=("${d%/}/${fname}")
    done
  done

  # 4) Common system font locations
  local -a system_dirs=(
    "/System/Library/Fonts"
    "/Library/Fonts"
    "${HOME}/Library/Fonts"
    "/usr/share/fonts"
    "/usr/local/share/fonts"
  )

  local dir
  for dir in "${system_dirs[@]}"; do
    for fname in "${font_names[@]}"; do
      candidates+=("${dir%/}/${fname}")
    done
  done

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done

  return 1
}

subtitle_font_name="$fontname"

debug_log "Mode: $mode"
debug_log "Layout: $layout"
debug_log "Format: $format"
debug_log "Burn mode: $burn_mode"
debug_log "Missing meta handling: $missing_meta"
debug_log "Requested font name: ${subtitle_font_name:-<auto>}"
debug_log "ffmpeg path: $ffmpeg_bin"
debug_log "dvrescue path: $dvrescue_bin"

########################################################
# Helper: seconds (float) -> ASS time H:MM:SS.cc
########################################################

seconds_to_ass_time() {
  local sec="$1"
  local -F s fsec
  local -i h m

  s="$sec"
  if (( s < 0 )); then
    s=0
  fi

  (( h = s / 3600 ))
  (( m = (s - h*3600) / 60 ))
  (( fsec = s - h*3600 - m*60 ))

  printf "%d:%02d:%05.2f" "$h" "$m" "$fsec"
}

########################################################
# Segment generator — shared by sendcmd + ASS
########################################################

generate_segments_from_tsv() {
  local rdt_tsv="$1"
  local fps="$2"

  local prev_dt="" prev_date="" prev_time=""
  local prev_start=""
  local frame_step
  frame_step=$(awk -v fps="$fps" 'BEGIN{printf "%.6f", 1/fps}')
  local -i segment_rows=0 raw_rows=0

  while read -r frame_idx date_part time_part || [[ -n "${frame_idx:-}" ]]; do
    (( raw_rows++ ))
    local dt_key="${date_part} ${time_part}"
    local start_sec
    start_sec=$(awk -v f="$frame_idx" -v fps="$fps" 'BEGIN{if (f < 1) {f = 1} printf "%.6f", (f-1)/fps}')

    if [[ -z "$prev_dt" ]]; then
      prev_dt="$dt_key"
      prev_date="$date_part"
      prev_time="$time_part"
      prev_start="$start_sec"
      continue
    fi

    if [[ "$dt_key" != "$prev_dt" ]]; then
      printf "%s\t%s\t%s\t%s\n" "$prev_start" "$start_sec" "$prev_date" "$prev_time"
      (( segment_rows++ ))
      prev_dt="$dt_key"
      prev_date="$date_part"
      prev_time="$time_part"
      prev_start="$start_sec"
    fi
  done < "$rdt_tsv"

  if [[ -n "$prev_dt" && -n "$prev_start" ]]; then
    local end_sec
    end_sec=$(awk -v start="$prev_start" -v step="$frame_step" 'BEGIN{printf "%.6f", start+step}')
    printf "%s\t%s\t%s\t%s\n" "$prev_start" "$end_sec" "$prev_date" "$prev_time"
    (( segment_rows++ ))
  fi

  debug_log "generate_segments_from_tsv rows_in=$raw_rows rows_out=$segment_rows source_tsv=$rdt_tsv fps=$fps"
}

########################################################
# Build sendcmd file from RDT
########################################################

make_timestamp_cmd() {
  local in="$1"
  local cmdfile="$2"
  local xml_file="$3"
  local dv_log="$4"
  local timeline_debug="$5"
  local fps="$6"

  : > "$cmdfile"

  if [[ -z "$fps" ]]; then
    echo "[ERROR] FPS value missing for $in" >&2
    return 1
  fi

  local rdt_tmp rdt_source
  if ! build_rdt_tmp "$xml_file" "$dv_log" rdt_tmp rdt_source; then
    echo "[WARN] Unable to extract per-frame RDT data (source: $rdt_source)" >&2
    last_parse_frame_source="${rdt_source:-unknown}"
    last_parse_raw_rows=0
    last_parse_valid_rows=0
    last_parse_skipped_rows=0
    last_parse_timeline_entries=0
    return 2
  fi

  : > "$timeline_debug"
  echo "$timeline_header" >> "$timeline_debug"

  local segments_tmp
  segments_tmp=$(make_temp_file dvmeta_segments ".tsv") || return 1
  generate_segments_from_tsv "$rdt_tmp" "$fps" > "$segments_tmp"

  local -i raw_rows=0 valid_rows=0 skipped_rows=0
  local -i unique_dt_keys=0 segment_count=0 segment_lines=0
  local prev_dt=""
  typeset -A dt_keys_seen=()

  while IFS=$'\t' read -r start_sec end_sec date_part time_part || [[ -n "${start_sec:-}" ]]; do
    (( raw_rows++ ))
    local dt_key="${date_part} ${time_part}"

    if [[ "$dt_key" != "$prev_dt" ]]; then
      (( segment_count++ ))
      if [[ -z "${dt_keys_seen[$dt_key]:-}" ]]; then
        dt_keys_seen[$dt_key]=1
        (( unique_dt_keys++ ))
      fi
      prev_dt="$dt_key"
    fi

    (( valid_rows++ ))

    # Escape colons for drawtext
    local text="${dt_key//:/\\:}"
    printf "%0.6f drawtext@dvmeta reinit text='%s';\n" "$start_sec" "$text" >> "$cmdfile"
    printf "0\t%0.6f\t%s\t%s\t%s\t1\n" \
      "$start_sec" "$date_part" "$time_part" "$dt_key" >> "$timeline_debug"
    (( segment_lines++ ))
  done < "$segments_tmp"

  last_parse_frame_source="$rdt_source"
  last_parse_raw_rows=$raw_rows
  last_parse_valid_rows=$valid_rows
  last_parse_skipped_rows=$skipped_rows
  last_parse_timeline_entries=$segment_lines

  local summary_line
  summary_line="[INFO] Frame parse summary (source=$rdt_source): rows=$raw_rows, valid=$valid_rows, skipped=$skipped_rows, unique_dt_keys=$unique_dt_keys, segment_count=$segment_count"
  echo "$summary_line" >&2
  debug_log "$summary_line"

  if (( segment_lines < 1 )); then
    echo "[WARN] Empty sendcmd generated for $in (lines=$segment_lines)" >&2
    return 1
  fi

  debug_log "sendcmd lines for $in: $segment_lines"
  return 0
}

########################################################
# Build ASS subtitles from same timeline
########################################################

make_ass_subs() {
  local in="$1"
  local layout="$2"
  local ass_out="$3"
  local xml_file="$4"
  local dv_log="$5"
  local timeline_debug="$6"
  local fps="$7"

  if [[ -z "$fps" ]]; then
    echo "[ERROR] FPS value missing for subtitle generation" >&2
    return 1
  fi

  : > "$ass_out"
  : > "$timeline_debug"
  echo "$timeline_header" >> "$timeline_debug"

  local rdt_tmp rdt_source
  if ! build_rdt_tmp "$xml_file" "$dv_log" rdt_tmp rdt_source; then
    echo "[WARN] Unable to extract per-frame RDT data (source: $rdt_source)" >&2
    return 2
  fi

  local segments_tmp
  segments_tmp=$(make_temp_file dvmeta_segments ".tsv") || return 1
  generate_segments_from_tsv "$rdt_tmp" "$fps" > "$segments_tmp"

  local subtitle_font_safe
  subtitle_font_safe=${subtitle_font_name//\/\\}
  subtitle_font_safe=${subtitle_font_safe//\$/\\$}

  cat >> "$ass_out" <<EOF
[Script Info]
Title: DV Metadata Burn-In
ScriptType: v4.00+
Collisions: Normal
PlayResX: 720
PlayResY: 480
Timer: 100.0000

[V4+ Styles]
Style: DVOSD,${subtitle_font_safe},24,&H00FFFFFF,&H00000000,&H00000000,&H00000000,-1,0,0,0,100,100,0,0,0,0,0,2,20,20,20,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
EOF

  local -i raw_rows=0 valid_rows=0 skipped_rows=0
  local -i unique_dt_keys=0 segment_count=0 dialogue_count=0
  local prev_dt=""
  typeset -A dt_keys_seen=()

  while IFS=$'\t' read -r start_sec end_sec date_part time_part || [[ -n "${start_sec:-}" ]]; do
    (( raw_rows++ ))

    if [[ -z "$date_part" || -z "$time_part" ]]; then
      (( skipped_rows++ ))
      continue
    fi

    local dt_key="${date_part} ${time_part}"

    if [[ "$dt_key" != "$prev_dt" ]]; then
      (( segment_count++ ))
      if [[ -z "${dt_keys_seen[$dt_key]:-}" ]]; then
        dt_keys_seen[$dt_key]=1
        (( unique_dt_keys++ ))
      fi
      prev_dt="$dt_key"
    fi

    (( valid_rows++ ))

    local start_str end_str text
    start_str="$(seconds_to_ass_time "$start_sec")"
    end_str="$(seconds_to_ass_time "$end_sec")"

    case "$layout" in
      stacked) text="${date_part}\\N${time_part}" ;;
      single)  text="${date_part}  ${time_part}" ;;
      *)       text="${date_part}\\N${time_part}" ;;
    esac

    printf "Dialogue: 0,%s,%s,DVOSD,,0,0,20,,%s\n" \
      "$start_str" "$end_str" "$text" >> "$ass_out"
    ((dialogue_count++))

    printf "0\t%0.6f\t%s\t%s\t%s\t1\n" \
      "$start_sec" "$date_part" "$time_part" "$dt_key" >> "$timeline_debug"
  done < "$segments_tmp"

  last_parse_frame_source="$rdt_source"
  last_parse_raw_rows=$raw_rows
  last_parse_valid_rows=$valid_rows
  last_parse_skipped_rows=$skipped_rows
  last_parse_timeline_entries=$dialogue_count

  local summary_line
  summary_line="[INFO] Subtitle parse summary (source=$rdt_source): rows=$raw_rows, valid=$valid_rows, skipped=$skipped_rows, unique_dt_keys=$unique_dt_keys, segment_count=$segment_count, dialogue_count=$dialogue_count"
  echo "$summary_line" >&2
  debug_log "$summary_line"

  if (( dialogue_count < 1 )); then
    echo "[WARN] No valid subtitle timestamps found in RDT data" >&2
    return 2
  fi

  return 0
}

offline_smoke_test() {
  local xml="${1:-/tmp/dvrescue.xml}"
  local log="${2:-/tmp/dvrescue.log}"
  local fps="${3:-29.97}"
  local cmdfile="${4:-/tmp/timestamp.cmd}"
  local timeline="${5:-/tmp/timeline.debug.tsv}"
  local rdt_tmp rdt_source

  if ! build_rdt_tmp "$xml" "$log" rdt_tmp rdt_source; then
    echo "[ERROR] offline_smoke_test could not parse RDT data (xml=$xml log=$log)" >&2
    return 1
  fi

  if ! make_timestamp_cmd "offline_sample" "$cmdfile" "$xml" "$log" "$timeline" "$fps"; then
    echo "[ERROR] offline_smoke_test failed to build timestamp command file" >&2
    return 1
  fi

  echo "[INFO] offline_smoke_test artifacts: timeline=$timeline sendcmd=$cmdfile (source=$rdt_source fps=$fps)" >&2
}

########################################################
# Main per-file processing
########################################################

process_file() {
  local in="$1"

  if [[ ! -f "$in" ]]; then
    echo "[ERROR] Input file not found: $in" >&2
    return 1
  fi

  debug_log "Processing input file: $in"

  local base="${in%.*}"
  local out_ext="$format"
  local artifact_dir dvrescue_xml dvrescue_log cmdfile timeline_debug ass_artifact run_manifest versions_file
  local burn_output="" subtitle_output="" passthrough_output=""
  local exit_status=0 manifest_status="pending"

  last_parse_raw_rows=0
  last_parse_valid_rows=0
  last_parse_skipped_rows=0
  last_parse_timeline_entries=0
  last_parse_frame_source="unknown"
  last_dvrescue_status=0

  if ! artifact_dir="$(prepare_artifact_dir "$in")"; then
    return 1
  fi

  dvrescue_xml="${artifact_dir}/dvrescue.xml"
  dvrescue_log="${artifact_dir}/dvrescue.log"
  cmdfile="${artifact_dir}/timestamp.cmd"
  timeline_debug="${artifact_dir}/timeline.debug.tsv"
  ass_artifact="${artifact_dir}/timestamps.ass"
  run_manifest="${artifact_dir}/run_manifest.json"
  versions_file="${artifact_dir}/versions.txt"

  rm -f "$dvrescue_xml"
  debug_log "Cleared prior dvrescue XML target: $dvrescue_xml"
  : > "$dvrescue_log"
  : > "$cmdfile"
  : > "$timeline_debug"
  : > "$ass_artifact"

  log_artifact_path_and_size "dvrescue XML" "$dvrescue_xml"
  log_artifact_path_and_size "dvrescue log" "$dvrescue_log"
  echo "[INFO] sendcmd path: $cmdfile" >&2
  echo "[INFO] ASS output path: $ass_artifact" >&2
  echo "[INFO] timeline debug path: $timeline_debug" >&2

  local -a codec_args
  case "$format" in
    mov)
      codec_args=(-c:v dvvideo -c:a copy)
      ;;
    mp4)
      codec_args=(-c:v mpeg4 -qscale:v 2 -c:a aac -b:a 192k)
      ;;
    *)
      warn "Unknown format: $format"
      manifest_status="error"
      finish_run 1 "$manifest_status" "$in" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_artifact" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
      return 1
      ;;
  esac

  local fps
  if ! fps="$(detect_fps "$in")"; then
    finish_run 1 "error" "$in" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_artifact" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
    return 1
  fi
  last_detected_fps="$fps"
  debug_log "Detected FPS: $fps"

  local dv_status=0
  debug_log "Extracting dvrescue XML -> $dvrescue_xml (log: $dvrescue_log)"
  "$dvrescue_bin" "$in" --xml-output "$dvrescue_xml" >"$dvrescue_log" 2>&1
  dv_status=$?
  last_dvrescue_status=$dv_status
  log_artifact_path_and_size "dvrescue XML" "$dvrescue_xml"
  log_artifact_path_and_size "dvrescue log" "$dvrescue_log"

  # Passthrough mode: no metadata
  if [[ "$burn_mode" == "passthrough" ]]; then
    local out_passthrough="${base}_conv.${out_ext}"
    echo "[INFO] Passthrough conversion (no burn-in) to: $out_passthrough"
    debug_log "Running passthrough encode with args: ${codec_args[*]}"
    "$ffmpeg_bin" -y -i "$in" \
      "${codec_args[@]}" \
      "$out_passthrough"
    exit_status=$?
    manifest_status=$([[ $exit_status -eq 0 ]] && echo "success" || echo "error")
    passthrough_output="$out_passthrough"
    write_versions_file "$versions_file"
    write_run_manifest "$run_manifest" "$manifest_status" "$in" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_artifact" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file"
    if [[ "$manifest_status" == "success" ]]; then
      emit_debug_snapshots "$timeline_debug" "$cmdfile"
    fi
    return $exit_status
  fi

  local font
  if ! font="$(find_font)"; then
    echo "[ERROR] Unable to locate a usable font. Provide --fontfile, set DVMETABURN_FONTFILE, or place a supported font in Resources/fonts/." >&2
    manifest_status="error"
    write_versions_file "$versions_file"
    write_run_manifest "$run_manifest" "$manifest_status" "$in" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_artifact" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file"
    return 1
  fi

  debug_log "Using font file: $font"

  if [[ -z "$subtitle_font_name" ]]; then
    subtitle_font_name="UAV OSD Mono"
  fi
  subtitle_font_name="${subtitle_font_name//,/ }"

  # Subtitle track mode
  if [[ "$burn_mode" == "subtitleTrack" || "$burn_mode" == "subtitle_track" || "$burn_mode" == "subtitle" ]]; then
    local sub_status=0
    if ! make_ass_subs "$in" "$layout" "$ass_artifact" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$fps"; then
      sub_status=$?
      if (( sub_status == 2 )); then
        case "$missing_meta" in
          skip_burnin_convert)
            echo "[WARN] Missing timestamp metadata for $in; converting without subtitle track." >&2
            local out_passthrough="${base}_conv.${out_ext}"
            "$ffmpeg_bin" -y -i "$in" \
              "${codec_args[@]}" \
              "$out_passthrough"
            exit_status=$?
            manifest_status=$([[ $exit_status -eq 0 ]] && echo "success" || echo "error")
            passthrough_output="$out_passthrough"
            write_versions_file "$versions_file"
            write_run_manifest "$run_manifest" "$manifest_status" "$in" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_artifact" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file"
            if [[ "$manifest_status" == "success" ]]; then
              emit_debug_snapshots "$timeline_debug" "$cmdfile"
            fi
            return $exit_status
            ;;
          skip_file)
            echo "[WARN] Missing timestamp metadata for $in; skipping file." >&2
            manifest_status="skipped"
            write_versions_file "$versions_file"
            write_run_manifest "$run_manifest" "$manifest_status" "$in" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_artifact" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file"
            return 0
            ;;
          *)
            ;;
        esac
      fi

      echo "[ERROR] Failed to build subtitles for $in" >&2
      write_versions_file "$versions_file"
      write_run_manifest "$run_manifest" "error" "$in" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_artifact" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file"
      return 1
    fi

    local out_subbed="${base}_dvsub.${out_ext}"
    local subtitle_codec="mov_text"

    echo "[INFO] Adding DV metadata subtitle track to: $out_subbed"
    debug_log "Merging subtitle track with codec: $subtitle_codec"
    "$ffmpeg_bin" -y -i "$in" -i "$ass_artifact" \
      -c:v copy -c:a copy -c:s "$subtitle_codec" -map 0 -map 1 \
      -metadata:s:s:0 language=eng \
      "$out_subbed"

    exit_status=$?
    manifest_status=$([[ $exit_status -eq 0 ]] && echo "success" || echo "error")
    subtitle_output="$out_subbed"
    write_versions_file "$versions_file"
    write_run_manifest "$run_manifest" "$manifest_status" "$in" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_artifact" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file"
    if [[ "$manifest_status" == "success" ]]; then
      emit_debug_snapshots "$timeline_debug" "$cmdfile"
    fi
    return $exit_status
  fi

  # Burn-in mode
  if ! make_timestamp_cmd "$in" "$cmdfile" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$fps"; then
    case "$missing_meta" in
      error)
        echo "[ERROR] Failed to build timestamp command file for $in" >&2
        write_versions_file "$versions_file"
        write_run_manifest "$run_manifest" "error" "$in" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_artifact" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file"
        return 1
        ;;
      skip_burnin_convert)
        warn "No usable RDT; converting without burn-in for $in"
        burn_mode="passthrough"
        ;;
      skip_file)
        warn "No usable RDT; skipping file $in"
        write_versions_file "$versions_file"
        write_run_manifest "$run_manifest" "skipped" "$in" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_artifact" "$burn_output" "$subtitle_output" "" "$versions_file"
        return 0
        ;;
    esac
  fi

  local -i cmd_lines=0
  cmd_lines=$( (grep -c 'drawtext@dvmeta' "$cmdfile" 2>/dev/null) || echo 0 )

  if (( cmd_lines < 2 )); then
    echo "[WARN] Timestamp command file for $in has too few drawtext updates ($cmd_lines); overlay would be static" >&2
    case "$missing_meta" in
      skip_burnin_convert)
        echo "[WARN] Converting without burn-in due to insufficient timestamp metadata." >&2
        local out_passthrough="${base}_conv.${out_ext}"
        "$ffmpeg_bin" -y -i "$in" \
          "${codec_args[@]}" \
          "$out_passthrough"
        exit_status=$?
        manifest_status=$([[ $exit_status -eq 0 ]] && echo "success" || echo "error")
        passthrough_output="$out_passthrough"
        write_versions_file "$versions_file"
        write_run_manifest "$run_manifest" "$manifest_status" "$in" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_artifact" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file"
        return $exit_status
        ;;
      skip_file)
        echo "[WARN] Skipping $in due to insufficient timestamp metadata." >&2
        manifest_status="skipped"
        write_versions_file "$versions_file"
        write_run_manifest "$run_manifest" "$manifest_status" "$in" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_artifact" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file"
        return 0
        ;;
      *)
        ;;
    esac

    write_versions_file "$versions_file"
    write_run_manifest "$run_manifest" "error" "$in" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_artifact" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file"
    return 1
  fi

  local vf
  case "$layout" in
    stacked)
      vf="sendcmd=f='${cmdfile}',\
drawtext@dvmeta=fontfile='${font}':text='':fontcolor=white:fontsize=24:x=w-tw-20:y=h-45"
      ;;
    single)
      vf="sendcmd=f='${cmdfile}',\
drawtext@dvmeta=fontfile='${font}':text='':fontcolor=white:fontsize=24:x=w-tw-40:y=h-30"
      ;;
    *)
      echo "Unknown layout: $layout" >&2
      write_versions_file "$versions_file"
      write_run_manifest "$run_manifest" "error" "$in" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_artifact" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file"
      return 1
      ;;
  esac

  local out="${base}_dateburn.${out_ext}"

  echo "[INFO] Burning DV metadata into: $out"
  debug_log "ffmpeg burn-in args: ${codec_args[*]}"
  "$ffmpeg_bin" -y -i "$in" \
    -vf "$vf" \
    "${codec_args[@]}" \
    "$out"

  exit_status=$?
  manifest_status=$([[ $exit_status -eq 0 ]] && echo "success" || echo "error")
  burn_output="$out"
  echo "ffmpeg exit code: $exit_status"
  write_versions_file "$versions_file"
  write_run_manifest "$run_manifest" "$manifest_status" "$in" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_artifact" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file"
  if [[ "$manifest_status" == "success" ]]; then
    emit_debug_snapshots "$timeline_debug" "$cmdfile"
  fi
  return $exit_status
}

########################################################
# Mode routing
########################################################

if [[ "${RUN_OFFLINE_TEST:-0}" == "1" ]]; then
  offline_smoke_test
  exit $?
fi

if [[ "$mode" == "single" ]]; then
  if [[ $# -ne 1 ]]; then
    echo "Usage: $0 [--mode=single] [--layout=stacked|single] [--format=mov|mp4] [--burn-mode=burnin|passthrough|subtitleTrack] /path/to/clip.avi" >&2
    exit 1
  fi
  debug_log "Running in single-file mode with target: $1"
  process_file "$1"
  exit $?
fi

if [[ "$mode" == "batch" ]]; then
  if [[ $# -ne 1 ]]; then
    echo "Usage: $0 --mode=batch [--layout=stacked|single] [--format=mov|mp4] [--burn-mode=burnin|passthrough|subtitleTrack] /path/to/folder" >&2
    exit 1
  fi

  folder="$1"

  if [[ ! -d "$folder" ]]; then
    echo "ERROR: $folder is not a folder" >&2
    exit 1
  fi

  echo "Batch mode: scanning $folder"
  debug_log "Scanning batch folder for AVI/DV files"
  for f in "$folder"/*.{avi,AVI,dv,DV}; do
    [[ -f "$f" ]] || continue
    echo "Processing $f"
    process_file "$f"
  done

  exit 0
fi

echo "ERROR: Unknown mode: $mode" >&2
exit 1
