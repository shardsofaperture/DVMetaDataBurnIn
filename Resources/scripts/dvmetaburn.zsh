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
# Opt-in verbose logging for troubleshooting
debug_mode=0

# Optional environment overrides
: "${DVMETABURN_FONTFILE:=}"   # override font path
: "${DVMETABURN_JQ:=}"         # override jq path (e.g. bundled jq)

########################################################
# CLI flag parsing
########################################################

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode=*)
      mode="${1#*=}"
      shift
      ;;
    --layout=*)
      layout="${1#*=}"
      shift
      ;;
    --format=*)
      format="${1#*=}"
      shift
      ;;
    --burn-mode=*)
      burn_mode="${1#*=}"
      shift
      ;;
    --missing-meta=*)
      missing_meta="${1#*=}"
      shift
      ;;
    --fontfile=*)
      fontfile="${1#*=}"
      shift
      ;;
    --fontname=*)
      fontname="${1#*=}"
      shift
      ;;
    --ffmpeg=*)
      ffmpeg_bin="${1#*=}"
      shift
      ;;
    --dvrescue=*)
      dvrescue_bin="${1#*=}"
      shift
      ;;
    --debug)
      debug_mode=1
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

# Normalize missing metadata handling to allow legacy / camelCase values and
# to ignore stray whitespace from callers.
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
    # Already normalized
    ;;
  *)
    echo "[WARN] Unknown missing-meta value '$missing_meta'; defaulting to 'error'" >&2
    missing_meta="error"
    ;;
esac

# Allow --debug to appear after the -- sentinel and positional arguments.
# Some callers append the toggle after the input path, which would otherwise
# look like an extra positional argument and fail the mode usage checks.
if [[ $# -gt 0 ]]; then
  positional=()
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--debug" ]]; then
      debug_mode=1
    else
      positional+=("$1")
    fi
    shift
  done

  if (( ${#positional[@]} )); then
    set -- "${positional[@]}"
  else
    set --
  fi
fi

########################################################
# Helper: locate jq (bundled or system)
########################################################

find_jq() {
  # 1) Explicit env override
  if [[ -n "$DVMETABURN_JQ" && -x "$DVMETABURN_JQ" ]]; then
    echo "$DVMETABURN_JQ"
    return 0
  fi

  # 2) Bundled jq next: first alongside the script (for .app bundle), then ../bin
  local script_dir jq_candidate
  script_dir="${0:A:h}"

  # Same directory as the script (e.g., Contents/Resources/jq inside the .app)
  jq_candidate="${script_dir}/jq"
  if [[ -x "$jq_candidate" ]]; then
    echo "$jq_candidate"
    return 0
  fi

  # Next to Resources/scripts (development tree path)
  jq_candidate="${script_dir}/../bin/jq"
  if [[ -x "$jq_candidate" ]]; then
    echo "$jq_candidate"
    return 0
  fi

  # 3) Fallback to jq in PATH
  if command -v jq >/dev/null 2>&1; then
    echo "jq"
    return 0
  fi

  echo "[ERROR] jq not found. Set DVMETABURN_JQ, bundle jq in Resources/bin, or install jq in PATH." >&2
  return 1
}

jq_bin="$(find_jq)"

# Lightweight helper for conditional debug output
debug_log() {
  echo "[DEBUG] $*" >&2
}

# Resolve key tool versions once per process for manifest logging.
script_version="$(git -C "${0:A:h}" rev-parse --short HEAD 2>/dev/null || echo "unknown")"
dvrescue_version="$({ "$dvrescue_bin" --version 2>/dev/null || true; } | head -n1 | tr -d '\r')"
ffmpeg_version="$({ "$ffmpeg_bin" -version 2>/dev/null || true; } | head -n1 | tr -d '\r')"
jq_version="$({ "$jq_bin" --version 2>/dev/null || true; } | head -n1 | tr -d '\r')"

typeset -gA TL_STATS
typeset -ga TL_SEG_STARTS TL_SEG_ENDS TL_SEG_DATES TL_SEG_TIMES
typeset -g CURRENT_JSON_FILE CURRENT_DV_LOG CURRENT_FRAME_SOURCE TIMELINE_DEBUG_FILE

prepare_log_root() {
  local primary secondary
  primary="${HOME}/Library/Logs/DVMeta"
  secondary="/tmp/DVMetaLogs"

  if mkdir -p "$primary" 2>/dev/null; then
    echo "$primary"
    return 0
  fi

  mkdir -p "$secondary"
  echo "$secondary"
}

safe_basename() {
  local in="$1"
  local base
  base="${in##*/}"
  base="${base%.*}"
  echo "$base" | tr -c '[:alnum:]_-' '_'
}

make_artifact_dir() {
  local in="$1"
  local root suffix dir
  root="$(prepare_log_root)"
  suffix="$(date -u +%Y%m%d-%H%M%S)"
  dir="${root}/$(safe_basename "$in")_${suffix}"
  if ! mkdir -p "$dir"; then
    echo "[ERROR] Unable to create artifact directory: $dir" >&2
    return 1
  fi
  echo "$dir"
}

# Allocate a temporary file in TMPDIR with a predictable prefix and optional
# extension. Uses mktemp to avoid races and returns the created path on stdout.
make_temp_file() {
  local prefix="${1:-dvmeta}"
  local ext="${2:-}"
  local dir="${TMPDIR:-/tmp}"
  local fallback_dir="/tmp"

  # Prefer absolute paths for core utilities in case PATH is restricted.
  local mktemp_cmd awk_cmd df_cmd stat_cmd mv_cmd sed_cmd cut_cmd
  mktemp_cmd=$(command -v mktemp 2>/dev/null)
  [[ -n "$mktemp_cmd" && -x "$mktemp_cmd" ]] || mktemp_cmd=""
  [[ -z "$mktemp_cmd" && -x /usr/bin/mktemp ]] && mktemp_cmd="/usr/bin/mktemp"

  awk_cmd=$(command -v awk 2>/dev/null)
  [[ -n "$awk_cmd" && -x "$awk_cmd" ]] || awk_cmd=""
  [[ -z "$awk_cmd" && -x /usr/bin/awk ]] && awk_cmd="/usr/bin/awk"

  df_cmd=$(command -v df 2>/dev/null)
  [[ -n "$df_cmd" && -x "$df_cmd" ]] || df_cmd=""
  [[ -z "$df_cmd" && -x /bin/df ]] && df_cmd="/bin/df"

  stat_cmd=$(command -v stat 2>/dev/null)
  [[ -n "$stat_cmd" && -x "$stat_cmd" ]] || stat_cmd=""
  [[ -z "$stat_cmd" && -x /usr/bin/stat ]] && stat_cmd="/usr/bin/stat"

  mv_cmd=$(command -v mv 2>/dev/null)
  [[ -n "$mv_cmd" && -x "$mv_cmd" ]] || mv_cmd=""
  [[ -z "$mv_cmd" && -x /bin/mv ]] && mv_cmd="/bin/mv"
  [[ -z "$mv_cmd" && -x /usr/bin/mv ]] && mv_cmd="/usr/bin/mv"

  sed_cmd=$(command -v sed 2>/dev/null)
  [[ -n "$sed_cmd" && -x "$sed_cmd" ]] || sed_cmd=""
  [[ -z "$sed_cmd" && -x /bin/sed ]] && sed_cmd="/bin/sed"
  [[ -z "$sed_cmd" && -x /usr/bin/sed ]] && sed_cmd="/usr/bin/sed"

  cut_cmd=$(command -v cut 2>/dev/null)
  [[ -n "$cut_cmd" && -x "$cut_cmd" ]] || cut_cmd=""
  [[ -z "$cut_cmd" && -x /bin/cut ]] && cut_cmd="/bin/cut"
  [[ -z "$cut_cmd" && -x /usr/bin/cut ]] && cut_cmd="/usr/bin/cut"

  if [[ -z "$mktemp_cmd" ]]; then
    echo "[ERROR] mktemp not found in PATH or standard locations; cannot allocate temp files." >&2
    return 127
  fi

  if [[ -z "$mv_cmd" ]]; then
    echo "[ERROR] mv not found in PATH or standard locations; cannot finalize temp files." >&2
    return 127
  fi

  # macOS/BSD mktemp requires the XXXXXX pattern at the end of the template,
  # so build the base path without the caller-provided extension and add the
  # extension after the temporary file is created. This keeps GNU mktemp happy
  # as well while avoiding "File exists" errors on macOS when a suffix follows
  # the X characters.
  local template_base="${dir%/}/${prefix}.XXXXXXXX"
  local path mktemp_status mktemp_output fallback_output fallback_status

  mktemp_output="$("$mktemp_cmd" "$template_base" 2>&1)"
  mktemp_status=$?

  if (( mktemp_status != 0 )); then
    local dir_perms dir_free
    if [[ -n "$stat_cmd" ]]; then
      dir_perms=$("$stat_cmd" -f '%Sp' "$dir" 2>/dev/null || "$stat_cmd" -c '%A' "$dir" 2>/dev/null || echo 'unknown')
    else
      dir_perms="unknown"
    fi

    if [[ -n "$df_cmd" && -n "$awk_cmd" ]]; then
      dir_free=$("$df_cmd" -Pk "$dir" 2>/dev/null | "$awk_cmd" 'NR==2{print $4"K"}' || true)
    elif [[ -n "$df_cmd" && -n "$sed_cmd" && -n "$cut_cmd" ]]; then
      dir_free=$("$df_cmd" -Pk "$dir" 2>/dev/null | "$sed_cmd" -n '2p' | "$cut_cmd" -d' ' -f4 2>/dev/null || true)
      [[ -n "$dir_free" ]] && dir_free+="K"
    elif [[ -n "$df_cmd" ]]; then
      dir_free="unknown"
    else
      dir_free="unknown"
    fi

    echo "[ERROR] Unable to create temp file in ${dir}: ${mktemp_output:-unknown error}" >&2
    echo "[ERROR] Temp dir info -> path: ${dir}, perms: ${dir_perms}, free: ${dir_free:-unknown}" >&2

    if [[ "$dir" != "$fallback_dir" ]]; then
      local fallback_template="${fallback_dir%/}/${prefix}.XXXXXXXX"
      fallback_output="$("$mktemp_cmd" "$fallback_template" 2>&1)"
      fallback_status=$?

      if (( fallback_status != 0 )); then
        local fallback_perms fallback_free
        if [[ -n "$stat_cmd" ]]; then
          fallback_perms=$("$stat_cmd" -f '%Sp' "$fallback_dir" 2>/dev/null || "$stat_cmd" -c '%A' "$fallback_dir" 2>/dev/null || echo 'unknown')
        else
          fallback_perms="unknown"
        fi

        if [[ -n "$df_cmd" && -n "$awk_cmd" ]]; then
          fallback_free=$("$df_cmd" -Pk "$fallback_dir" 2>/dev/null | "$awk_cmd" 'NR==2{print $4"K"}' || true)
        elif [[ -n "$df_cmd" && -n "$sed_cmd" && -n "$cut_cmd" ]]; then
          fallback_free=$("$df_cmd" -Pk "$fallback_dir" 2>/dev/null | "$sed_cmd" -n '2p' | "$cut_cmd" -d' ' -f4 2>/dev/null || true)
          [[ -n "$fallback_free" ]] && fallback_free+="K"
        elif [[ -n "$df_cmd" ]]; then
          fallback_free="unknown"
        else
          fallback_free="unknown"
        fi

        echo "[ERROR] Fallback to ${fallback_dir} also failed: ${fallback_output:-unknown error}" >&2
        echo "[ERROR] Temp dir info -> path: ${fallback_dir}, perms: ${fallback_perms}, free: ${fallback_free:-unknown}" >&2
        return $mktemp_status
      fi

      echo "[WARN] Using fallback temp directory ${fallback_dir} after mktemp failure." >&2
      path="$fallback_output"
    else
      return $mktemp_status
    fi
  else
    path="$mktemp_output"
  fi

  # If the caller asked for an extension, rename the mktemp output to add it
  # while keeping the unique random portion provided by mktemp.
  if [[ -n "$ext" ]]; then
    local path_with_ext="${path}${ext}"
    "$mv_cmd" "$path" "$path_with_ext"
    path="$path_with_ext"
  fi

  echo "$path"
}

# Emit a short, prefixed excerpt from a file for troubleshooting
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

# Keep a global friendly font name for ASS style
subtitle_font_name="$fontname"

debug_log "Mode: $mode"
debug_log "Layout: $layout"
debug_log "Format: $format"
debug_log "Burn mode: $burn_mode"
debug_log "Missing meta handling: $missing_meta"
debug_log "Requested font name: ${subtitle_font_name:-<auto>}"
debug_log "ffmpeg path: $ffmpeg_bin"
debug_log "dvrescue path: $dvrescue_bin"
debug_log "jq path: $jq_bin"

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

log_file_info() {
  local label="$1"
  local path="$2"
  if [[ -e "$path" ]]; then
    local size
    size=$(stat -f %z "$path" 2>/dev/null || stat -c %s "$path" 2>/dev/null || echo 0)
    debug_log "$label: ${size} bytes -> $path"
  else
    debug_log "$label: (missing) -> $path"
  fi
}

probe_rdt_paths() {
  local json_file="$1"
  local direct nested
  direct=$({ "$jq_bin" '[.. | objects | select(has("rdt"))] | length' "$json_file" 2>/dev/null || echo 0; } | tr -d '\r')
  nested=$({ "$jq_bin" '[.. | objects | select(.anc?.dvitc?.rdt? != null)] | length' "$json_file" 2>/dev/null || echo 0; } | tr -d '\r')
  debug_log "RDT objects at .rdt: ${direct}"
  debug_log "RDT objects at .anc.dvitc.rdt: ${nested}"
}

run_dvrescue() {
  local in="$1"
  local artifact_dir="$2"

  CURRENT_JSON_FILE="${artifact_dir}/dvrescue.json"
  CURRENT_DV_LOG="${artifact_dir}/dvrescue.log"
  CURRENT_FRAME_SOURCE="json"

  debug_log "Extracting timestamp timeline via dvrescue -> $CURRENT_JSON_FILE (log: $CURRENT_DV_LOG)"
  debug_log "Command: $dvrescue_bin \"$in\" -json $CURRENT_JSON_FILE"

  local dv_status=0
  if ! "$dvrescue_bin" "$in" -json "$CURRENT_JSON_FILE" >"$CURRENT_DV_LOG" 2>&1; then
    dv_status=$?
  fi

  log_file_info "dvrescue JSON" "$CURRENT_JSON_FILE"
  log_file_info "dvrescue log" "$CURRENT_DV_LOG"

  if [[ ! -s "$CURRENT_JSON_FILE" ]]; then
    if [[ -s "$CURRENT_DV_LOG" ]] && grep -q "<dvrescue" "$CURRENT_DV_LOG"; then
      CURRENT_FRAME_SOURCE="xml"
      cp "$CURRENT_DV_LOG" "${artifact_dir}/dvrescue.xml" 2>/dev/null || true
      debug_log "Timestamp JSON missing; using dvrescue XML output"
    else
      echo "[WARN] Timestamp JSON missing for $in (dvrescue exit $dv_status)" >&2
      return 2
    fi
  fi

  debug_log "dvrescue -json exit status: $dv_status"
  if [[ "$CURRENT_FRAME_SOURCE" == "json" ]]; then
    probe_rdt_paths "$CURRENT_JSON_FILE"
  fi

  return 0
}

collect_timeline() {
  local in="$1"
  local artifact_dir="$2"
  local frame_step=0.0333667

  TIMELINE_DEBUG_FILE="${artifact_dir}/timeline.debug.tsv"
  : > "$TIMELINE_DEBUG_FILE"
  echo -e "frame_index\traw_pts\tmono_time\traw_rdt\tdate_part\ttime_part_truncated_to_second\tdt_key\tsegment_change" >> "$TIMELINE_DEBUG_FILE"

  TL_SEG_STARTS=()
  TL_SEG_ENDS=()
  TL_SEG_DATES=()
  TL_SEG_TIMES=()
  TL_STATS=()

  local -i raw_rows=0 valid_rows=0 skipped_rows=0 unique_dt_keys=0 segment_count=0
  local -A dt_seen
  local prev_dt="" prev_date="" prev_time=""
  local -F prev_mono=-1
  local -F frame_idx=0 mono_time=0

  local extractor
  if [[ "$CURRENT_FRAME_SOURCE" == "json" ]]; then
    extractor=("$jq_bin" -r '
      def rows:
        if type == "object" and has("frames") then
          .frames[] | rows
        elif type == "array" then
          (.[] | rows)
        elif type == "object" then
          if (.pts_time? // .pts?) and (.anc.dvitc.rdt? // .rdt?) then . else empty end
        else empty end;
      rows | [.pts_time // .pts, (.anc.dvitc.rdt // .rdt)] | @tsv
    ' "$CURRENT_JSON_FILE")
  else
    extractor=(awk 'BEGIN{FS="\""} /<frame /{pts="";rdt=""; for(i=1;i<NF;i++){if($i~/(^| )pts_time=/||$i~/(^| )pts=/)pts=$(i+1); if($i~/(^| )rdt=/)rdt=$(i+1)} printf "%s\t%s\n", pts, rdt}' "$CURRENT_DV_LOG")
  fi

  while IFS=$'\t' read -r raw_pts raw_rdt; do
    (( raw_rows++ ))
    mono_time=$(( frame_idx * frame_step ))

    if [[ -z "$raw_pts" || -z "$raw_rdt" ]]; then
      (( skipped_rows++ ))
      printf "%d\t%s\t%0.6f\t%s\t\t\t\t0\n" "$frame_idx" "$raw_pts" "$mono_time" "$raw_rdt" >> "$TIMELINE_DEBUG_FILE"
      (( frame_idx++ ))
      continue
    fi

    (( valid_rows++ ))
    local date_part time_part time_trunc dt_key
    date_part="${raw_rdt%% *}"
    time_part="${raw_rdt#* }"
    time_trunc="${time_part%%.*}"
    dt_key="$date_part $time_trunc"

    local segment_change=0
    if [[ "$dt_key" != "$prev_dt" ]]; then
      if [[ -n "$prev_dt" ]]; then
        local -F end_mono
        end_mono=$mono_time
        if (( end_mono <= prev_mono )); then
          end_mono=$(( prev_mono + frame_step ))
        fi
        TL_SEG_STARTS+=("$prev_mono")
        TL_SEG_ENDS+=("$end_mono")
        TL_SEG_DATES+=("$prev_date")
        TL_SEG_TIMES+=("$prev_time")
      fi

      prev_dt="$dt_key"
      prev_date="$date_part"
      prev_time="$time_trunc"
      prev_mono=$mono_time
      segment_change=1
      (( segment_count++ ))
      if [[ -z ${dt_seen[$dt_key]-} ]]; then
        dt_seen[$dt_key]=1
        (( unique_dt_keys++ ))
      fi
    fi

    printf "%d\t%s\t%0.6f\t%s\t%s\t%s\t%s\t%d\n" "$frame_idx" "$raw_pts" "$mono_time" "$raw_rdt" "$date_part" "$time_trunc" "$dt_key" "$segment_change" >> "$TIMELINE_DEBUG_FILE"
    (( frame_idx++ ))
  done < <("${extractor[@]}")

  if [[ -n "$prev_dt" ]]; then
    local -F end_mono
    end_mono=$(( frame_idx * frame_step ))
    if (( end_mono <= prev_mono )); then
      end_mono=$(( prev_mono + frame_step ))
    fi
    TL_SEG_STARTS+=("$prev_mono")
    TL_SEG_ENDS+=("$end_mono")
    TL_SEG_DATES+=("$prev_date")
    TL_SEG_TIMES+=("$prev_time")
  fi

  TL_STATS[raw_rows]=$raw_rows
  TL_STATS[valid_rows]=$valid_rows
  TL_STATS[skipped_rows]=$skipped_rows
  TL_STATS[unique_dt_keys]=$unique_dt_keys
  TL_STATS[segment_count]=$segment_count
  TL_STATS[dialogue_count]=$segment_count
  TL_STATS[frame_source]="${CURRENT_FRAME_SOURCE:-unknown}"

  echo "Frame parse summary [sendcmd]: rows=$raw_rows valid=$valid_rows skipped=$skipped_rows unique_dt=$unique_dt_keys segments=$segment_count source=${CURRENT_FRAME_SOURCE:-unknown}" >&2

  if (( segment_count < 2 )); then
    echo "[WARN] Only $segment_count segments for this clip; overlay would be static. Treating as missing/insufficient metadata." >&2
    return 2
  fi

  return 0
}

write_manifest() {
  local artifact_dir="$1"
  local input_file="$2"
  local manifest_json="${artifact_dir}/run_manifest.json"
  local versions_txt="${artifact_dir}/versions.txt"

  cat > "$manifest_json" <<EOF
{
  "input_file": "${input_file}",
  "input_basename": "$(safe_basename "$input_file")",
  "run_timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "script_version": "${script_version}",
  "dvrescue_version": "${dvrescue_version}",
  "ffmpeg_version": "${ffmpeg_version}",
  "jq_version": "${jq_version}",
  "frame_source": "${TL_STATS[frame_source]:-unknown}",
  "stats": {
    "raw_rows": ${TL_STATS[raw_rows]:-0},
    "valid_rows": ${TL_STATS[valid_rows]:-0},
    "skipped_rows": ${TL_STATS[skipped_rows]:-0},
    "unique_dt_keys": ${TL_STATS[unique_dt_keys]:-0},
    "sendcmd_segment_count": ${TL_STATS[segment_count]:-0},
    "ass_dialogue_count": ${TL_STATS[dialogue_count]:-0}
  },
  "paths": {
    "dvrescue_json": "dvrescue.json",
    "dvrescue_log": "dvrescue.log",
    "timeline_debug": "timeline.debug.tsv",
    "sendcmd_file": "timestamp.cmd",
    "ass_file": "timestamps.ass"
  }
}
EOF

  cat > "$versions_txt" <<EOF
dvmetaburn.zsh version: ${script_version}
${dvrescue_version}
${ffmpeg_version}
${jq_version}
EOF
}

########################################################
# Helper: build sendcmd file from collected timeline
########################################################

make_timestamp_cmd() {
  local cmdfile="$1"
  local artifact_dir="$2"

  : > "$cmdfile"

  local i
  for i in {1..${#TL_SEG_STARTS[@]}}; do
    local idx=$((i-1))
    local start="${TL_SEG_STARTS[$idx]}"
    local date_part="${TL_SEG_DATES[$idx]}"
    local time_part="${TL_SEG_TIMES[$idx]}"
    local esc_date esc_time
    esc_date="${date_part//:/\\:}"
    esc_time="${time_part//:/\\:}"

    printf "%0.6f drawtext@dvdate reinit text='%s';
" "$start" "$esc_date" >> "$cmdfile"
    printf "%0.6f drawtext@dvtime reinit text='%s';
" "$start" "$esc_time" >> "$cmdfile"
  done

  debug_log "Frame parse summary [sendcmd]: rows=${TL_STATS[raw_rows]:-0} valid=${TL_STATS[valid_rows]:-0} skipped=${TL_STATS[skipped_rows]:-0} unique_dt=${TL_STATS[unique_dt_keys]:-0} segments=${TL_STATS[segment_count]:-0} source=${TL_STATS[frame_source]:-unknown}"

  if (( ${TL_STATS[segment_count]:-0} < 2 )); then
    echo "[WARN] Only ${TL_STATS[segment_count]:-0} segments for this clip; overlay would be static. Treating as missing/insufficient metadata." >&2
    return 2
  fi

  return 0
}

########################################################
# Helper: build ASS subtitles file from collected timeline
########################################################

make_ass_subs() {
  local layout="$1"
  local ass_out="$2"
  local artifact_dir="$3"

  : > "$ass_out"

  local subtitle_font_safe
  subtitle_font_safe=${subtitle_font_name//\/\\}
  subtitle_font_safe=${subtitle_font_safe//\$/\\$}
  subtitle_font_safe=${subtitle_font_safe//\`/\\`}

  cat >> "$ass_out" <<EOF
[Script Info]
Title: DV Metadata Burn-In
ScriptType: v4.00+
Collisions: Normal
PlayResX: 720
PlayResY: 480
Timer: 100.0000

[V4+ Styles]
; Style: Name,Fontname,Fontsize,PrimaryColour,SecondaryColour,OutlineColour,BackColour,
;        Bold,Italic,Underline,StrikeOut,ScaleX,ScaleY,Spacing,Angle,BorderStyle,
;        Outline,Shadow,Alignment,MarginL,MarginR,MarginV,Encoding
Style: DVOSD,${subtitle_font_safe},24,&H00FFFFFF,&H00000000,&H00000000,&H00000000,-1,0,0,0,100,100,0,0,0,0,0,2,20,20,20,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
EOF

  local i
  for i in {1..${#TL_SEG_STARTS[@]}}; do
    local idx=$((i-1))
    local start_sec end_sec date_part time_part text line
    start_sec="${TL_SEG_STARTS[$idx]}"
    end_sec="${TL_SEG_ENDS[$idx]}"
    date_part="${TL_SEG_DATES[$idx]}"
    time_part="${TL_SEG_TIMES[$idx]}"

    local start_str end_str
    start_str="$(seconds_to_ass_time "$start_sec")"
    end_str="$(seconds_to_ass_time "$end_sec")"

    case "$layout" in
      stacked)
        text="${date_part}\N${time_part}"
        ;;
      single)
        text="${date_part}  ${time_part}"
        ;;
      *)
        text="${date_part}\N${time_part}"
        ;;
    esac

    printf "Dialogue: 0,%s,%s,DVOSD,,0,0,20,,%s
" "$start_str" "$end_str" "$text" >> "$ass_out"
  done

  debug_log "Frame parse summary [ASS]: rows=${TL_STATS[raw_rows]:-0} valid=${TL_STATS[valid_rows]:-0} skipped=${TL_STATS[skipped_rows]:-0} unique_dt=${TL_STATS[unique_dt_keys]:-0} dialogues=${TL_STATS[dialogue_count]:-0} source=${TL_STATS[frame_source]:-unknown}"

  if (( ${TL_STATS[dialogue_count]:-0} < 2 )); then
    echo "[WARN] Only ${TL_STATS[dialogue_count]:-0} dialogues for this clip; overlay would be static. Treating as missing/insufficient metadata." >&2
    return 2
  fi

  return 0
}

########################################################
# Main per-file processing
########################################################

process_file() {
  local in="$1"

  if [[ ! -f "$in" ]]; then
    echo "Input file not found: $in" >&2
    return 1
  fi

  debug_log "Processing input file: $in"

  local artifact_dir
  if ! artifact_dir="$(make_artifact_dir "$in")"; then
    echo "[ERROR] Unable to create artifact directory for $in" >&2
    return 1
  fi
  debug_log "Artifact directory: $artifact_dir"

  TL_STATS=()
  TL_SEG_STARTS=()
  TL_SEG_ENDS=()
  TL_SEG_DATES=()
  TL_SEG_TIMES=()

  local base="${in%.*}"
  local out_ext="$format"

  local -a codec_args
  case "$format" in
    mov)
      codec_args=(-c:v dvvideo -c:a copy)
      ;;
    mp4)
      codec_args=(-c:v mpeg4 -qscale:v 2 -c:a aac -b:a 192k)
      ;;
    *)
      echo "Unknown format: $format" >&2
      return 1
      ;;
  esac

  local timeline_status=0
  if ! run_dvrescue "$in" "$artifact_dir"; then
    timeline_status=$?
  else
    if ! collect_timeline "$in" "$artifact_dir"; then
      timeline_status=$?
    fi
  fi

  if (( timeline_status != 0 && timeline_status != 2 )); then
    echo "[ERROR] Failed to build timeline for $in (status $timeline_status)" >&2
    write_manifest "$artifact_dir" "$in"
    return 1
  fi

  if [[ ! -f "${artifact_dir}/timeline.debug.tsv" ]]; then
    echo -e "frame_index\traw_pts\tmono_time\traw_rdt\tdate_part\ttime_part_truncated_to_second\tdt_key\tsegment_change" > "${artifact_dir}/timeline.debug.tsv"
  fi

  local font
  if ! font="$(find_font)"; then
    echo "[ERROR] Unable to locate a usable font. Provide --fontfile, set DVMETABURN_FONTFILE, or place a supported font in Resources/fonts/." >&2
    return 1
  fi

  debug_log "Using font file: $font"

  if [[ -z "$subtitle_font_name" ]]; then
    subtitle_font_name="UAV OSD Mono"
  fi
  subtitle_font_name="${subtitle_font_name//,/ }"

  local cmdfile="${artifact_dir}/timestamp.cmd"
  local ass_artifact="${artifact_dir}/timestamps.ass"

  # Generate ASS artifacts regardless of mode for diagnostics
  make_ass_subs "$layout" "$ass_artifact" "$artifact_dir" || true

  if (( timeline_status == 2 )); then
    case "$missing_meta" in
      skip_burnin_convert)
        echo "[WARN] Missing or insufficient timestamp metadata for $in; converting without burn-in or subtitles." >&2
        local out_passthrough="${base}_conv.${out_ext}"
        "$ffmpeg_bin" -y -i "$in" \
          "${codec_args[@]}" \
          "$out_passthrough"
        write_manifest "$artifact_dir" "$in"
        return $?
        ;;
      skip_file)
        echo "[WARN] Missing timestamp metadata for $in; skipping file." >&2
        write_manifest "$artifact_dir" "$in"
        return 0
        ;;
      *)
        ;;
    esac
  fi

  # Handle subtitle-track-only export
  if [[ "$burn_mode" == "subtitleTrack" || "$burn_mode" == "subtitle_track" || "$burn_mode" == "subtitle" ]]; then
    local ass_out="${base}_dvmeta_${layout}.ass"
    local sub_status=0
    if ! make_ass_subs "$layout" "$ass_artifact" "$artifact_dir"; then
      sub_status=$?
      if (( sub_status == 2 )); then
        case "$missing_meta" in
          skip_burnin_convert)
            echo "[WARN] Missing timestamp metadata for $in; converting without subtitle track." >&2
            local out_passthrough="${base}_conv.${out_ext}"
            "$ffmpeg_bin" -y -i "$in" \
              "${codec_args[@]}" \
              "$out_passthrough"
            write_manifest "$artifact_dir" "$in"
            return $?
            ;;
          skip_file)
            echo "[WARN] Missing timestamp metadata for $in; skipping file." >&2
            write_manifest "$artifact_dir" "$in"
            return 0
            ;;
          *)
            ;;
        esac
      fi

      echo "[ERROR] Failed to build subtitles for $in" >&2
      write_manifest "$artifact_dir" "$in"
      return 1
    fi

    cp "$ass_artifact" "$ass_out"

    local out_subbed="${base}_dvsub.${out_ext}"
    local subtitle_codec="mov_text"

    echo "[INFO] Adding DV metadata subtitle track to: $out_subbed"
    debug_log "Merging subtitle track with codec: $subtitle_codec"
    "$ffmpeg_bin" -y -i "$in" -i "$ass_out" \
      -map 0 -map 1 \
      -c:s "$subtitle_codec" \
      "${codec_args[@]}" \
      "$out_subbed"

    write_manifest "$artifact_dir" "$in"
    return $?
  fi

  # Passthrough = convert only, no burn-in, but still keep artifacts
  if [[ "$burn_mode" == "passthrough" ]]; then
    local out_passthrough="${base}_conv.${out_ext}"
    echo "[INFO] Passthrough conversion (no burn-in) to: $out_passthrough"
    debug_log "Running passthrough encode with args: ${codec_args[*]}"
    "$ffmpeg_bin" -y -i "$in" \
      "${codec_args[@]}" \
      "$out_passthrough"
    write_manifest "$artifact_dir" "$in"
    return $?
  fi

  # Otherwise: full burn-in + subtitle generation
  local ts_status=0
  if ! make_timestamp_cmd "$cmdfile" "$artifact_dir"; then
    ts_status=$?

    # Exit code 2 = missing metadata
    if (( ts_status == 2 )); then
      case "$missing_meta" in
        skip_burnin_convert)
          echo "[WARN] Missing timestamp metadata for $in; converting without burn-in." >&2
          local out_passthrough="${base}_conv.${out_ext}"
          "$ffmpeg_bin" -y -i "$in" \
            "${codec_args[@]}" \
            "$out_passthrough"
          write_manifest "$artifact_dir" "$in"
          return $?
          ;;
        skip_file)
          echo "[WARN] Missing timestamp metadata for $in; skipping file." >&2
          write_manifest "$artifact_dir" "$in"
          return 0
          ;;
        *)
          ;;
      esac
    fi

    echo "[ERROR] Failed to build timestamp command file for $in" >&2
    write_manifest "$artifact_dir" "$in"
    return 1
  fi

  local -i cmd_lines=0
  cmd_lines=$( (grep -c 'drawtext@' "$cmdfile" 2>/dev/null) || echo 0 )

  if (( cmd_lines < 4 )); then
    echo "[WARN] Timestamp command file for $in has too few drawtext updates ($cmd_lines); overlay would be static" >&2
    case "$missing_meta" in
      skip_burnin_convert)
        echo "[WARN] Converting without burn-in due to insufficient timestamp metadata." >&2
        local out_passthrough="${base}_conv.${out_ext}"
        "$ffmpeg_bin" -y -i "$in" \
          "${codec_args[@]}" \
          "$out_passthrough"
        write_manifest "$artifact_dir" "$in"
        return $?
        ;;
      skip_file)
        echo "[WARN] Skipping $in due to insufficient timestamp metadata." >&2
        write_manifest "$artifact_dir" "$in"
        return 0
        ;;
      *)
        ;;
    esac

    write_manifest "$artifact_dir" "$in"
    return 1
  fi

  local vf
  case "$layout" in
    stacked)
      vf="sendcmd=f='${cmdfile}',\
 drawtext@dvdate=fontfile='${font}':text='':fontcolor=white:fontsize=24:x=w-tw-20:y=h-60,\
 drawtext@dvtime=fontfile='${font}':text='':fontcolor=white:fontsize=24:x=w-tw-20:y=h-30"
      ;;
    single)
      vf="sendcmd=f='${cmdfile}',\
 drawtext@dvdate=fontfile='${font}':text='':fontcolor=white:fontsize=24:x=40:y=h-30,\
 drawtext@dvtime=fontfile='${font}':text='':fontcolor=white:fontsize=24:x=w-tw-40:y=h-30"
      ;;
    *)
      echo "Unknown layout: $layout" >&2
      write_manifest "$artifact_dir" "$in"
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

  local ec=$?
  write_manifest "$artifact_dir" "$in"
  echo "ffmpeg exit code: $ec"
  return $ec
}

########################################################
# Mode routing
########################################################

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
