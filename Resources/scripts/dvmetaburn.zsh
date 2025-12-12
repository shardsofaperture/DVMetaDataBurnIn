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

log_stage_marker() {
  local stage="$1"
  echo "[STAGE] $stage" >&2
}

########################################################
# Defaults / configuration
########################################################

mode="single"        # "single" or "batch"
layout="stacked"     # "stacked" or "single"
format="mov"         # "mov", "mp4", or "mkv"
mp4_preset="default" # "default", "best-quality", or "audio-only"
burn_mode="burnin"   # "burnin" or "off" or "subtitleTrack"
subtitle_mode="per-clip" # "per-clip" or "continuous"
missing_meta="skip_burnin_convert"  # behavior when metadata is missing
fontfile=""
fontname="UAV-OSD-Mono"
ffmpeg_bin="ffmpeg"
dvrescue_bin="dvrescue"
artifact_root="${HOME}/Library/Logs/DVMeta"
dest_dir=""
# Controls how densely timestamps are emitted into the timeline
burn_granularity="per_second"  # "per_second" or "per_frame"
# Opt-in verbose logging for troubleshooting
debug_mode=0
# Optional stitching
stitch_enabled=0
stitch_input_list=""
stitched_source=""
stitch_inputs_resolved=""

# Optional environment overrides
: "${DVMETABURN_FONTFILE:=}"   # override font path

########################################################
# CLI flag parsing
########################################################

subtitle_mode_arg_set=0
mp4_preset_arg_set=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode=*) mode="${1#*=}"; shift ;;
    --layout=*) layout="${1#*=}"; shift ;;
    --format=*) format="${1#*=}"; shift ;;
    --mp4-preset=*) mp4_preset="${1#*=}"; mp4_preset_arg_set=1; shift ;;
    --preset=*) mp4_preset="${1#*=}"; mp4_preset_arg_set=1; shift ;;
    --burn-mode=*) burn_mode="${1#*=}"; shift ;;
    --subtitle-mode=*) subtitle_mode="${1#*=}"; subtitle_mode_arg_set=1; shift ;;
    --missing-meta=*) missing_meta="${1#*=}"; shift ;;
    --fontfile=*) fontfile="${1#*=}"; shift ;;
    --fontname=*) fontname="${1#*=}"; shift ;;
    --ffmpeg=*) ffmpeg_bin="${1#*=}"; shift ;;
    --dvrescue=*) dvrescue_bin="${1#*=}"; shift ;;
    --dest-dir=*) dest_dir="${1#*=}"; shift ;;
    --stitch) stitch_enabled=1; shift ;;
    --stitch-inputs=*) stitch_input_list="${1#*=}"; shift ;;
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

format="${format//[[:space:]]/}"
format="${format:l}"

mp4_preset="${mp4_preset//[[:space:]]/}"
mp4_preset="${mp4_preset//_/-}"
mp4_preset="${mp4_preset:l}"

burn_mode="${burn_mode//[[:space:]]/}"
burn_mode="${burn_mode//_/-}"
burn_mode="${burn_mode:l}"

case "$burn_mode" in
  burnin|on)
    burn_mode="burnin"
    ;;
  off|none)
    burn_mode="off"
    ;;
  subtitletrack|subtitle-track|subtitle)
    burn_mode="subtitleTrack"
    ;;
  *)
    if [[ "$burn_mode" == "passthrough" || "$burn_mode" == "pass-through" ]]; then
      fatal "Burn mode 'passthrough' is no longer supported; use burnin, off, or subtitleTrack."
    fi
    fatal "Invalid burn mode '$burn_mode'; expected burnin, off, or subtitleTrack."
    ;;
esac

subtitle_mode="${subtitle_mode//[[:space:]]/}"
subtitle_mode="${subtitle_mode//_/-}"
subtitle_mode="${subtitle_mode:l}"

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

case "$format" in
  mov|mp4|mkv)
    ;;
  *)
    fatal "Unsupported format '$format'; expected mov, mp4, or mkv."
    ;;
esac

case "$subtitle_mode" in
  per-clip|"" )
    subtitle_mode="per-clip"
    ;;
  continuous)
    ;;
  *)
    fatal "Invalid subtitle mode '$subtitle_mode'; expected per-clip or continuous."
    ;;
esac

case "$mp4_preset" in
  best-quality)
    ;;
  bestquality)
    mp4_preset="best-quality"
    ;;
  audio-only)
    ;;
  audioonly)
    mp4_preset="audio-only"
    ;;
  default|"")
    mp4_preset="default"
    ;;
  *)
    fatal "Invalid preset '$mp4_preset'; expected best-quality, default, or audio-only."
    ;;
esac

if (( mp4_preset_arg_set == 1 )) && [[ "$format" != "mp4" ]]; then
  fatal "--preset/--mp4-preset requires --format=mp4."
fi

if (( subtitle_mode_arg_set == 1 )) && [[ "$burn_mode" != "subtitleTrack" ]]; then
  fatal "--subtitle-mode requires --burn-mode=subtitleTrack."
fi

if [[ "$burn_mode" == "subtitleTrack" ]] && [[ "$subtitle_mode" != "per-clip" && "$subtitle_mode" != "continuous" ]]; then
  fatal "--burn-mode=subtitleTrack requires a valid --subtitle-mode (per-clip or continuous)."
fi

if [[ "$format" == "mp4" && "$mp4_preset" == "audio-only" && "$burn_mode" == "burnin" ]]; then
  warn "MP4 audio-only preset is not compatible with burn-in; falling back to default video encode"
  mp4_preset="default"
fi

if [[ "$burn_mode" == "subtitleTrack" ]] && [[ "$format" == "mp4" || "$format" == "mov" ]]; then
  echo "[INFO] Subtitle tracks require an MKV container; coercing format '$format' to 'mkv' while preserving the base filename." >&2
  format="mkv"
fi

# Track parse stats for manifest writing
typeset -g last_parse_raw_rows=0
typeset -g last_parse_valid_rows=0
typeset -g last_parse_skipped_rows=0
typeset -g last_parse_timeline_entries=0
typeset -g last_parse_frame_source="unknown"
typeset -g last_dvrescue_status=0
typeset -g last_detected_fps=""
typeset -g timestamps_normalized=0
typeset -g primary_input_path=""

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
# LOG helpers
########################################################

# Parse dvrescue log into a timeline debug TSV. This is the only
# metadata source for rolling timestamps.
build_timeline_from_log() {
  local log_path="$1"
  local fps="$2"
  local timeline_out="$3"
  local granularity="$4"

  if [[ ! -s "$log_path" ]]; then
    echo "[ERROR] build_timeline_from_log: missing or empty log: $log_path" >&2
    return 1
  fi

  if [[ -z "$fps" ]]; then
    echo "[ERROR] build_timeline_from_log: fps missing; cannot compute timeline" >&2
    return 1
  fi

  if [[ -z "$granularity" ]]; then
    granularity="per_second"
  fi

  tr '\r' '\n' < "$log_path" | awk -v fps="$fps" -v granularity="$granularity" '
    BEGIN {
      raw_rows = 0;
      valid_rows = 0;
      timeline_entries = 0;
      prev_dt_key = "";
    }

    # Expect lines like:
    #  1 00:02:49;04 2025-11-12 09:17:19
    NF < 4 { next }

    {
      raw_rows++;

      idx  = $1;
      date = $3;
      time = $4;

      if (idx ~ /^[0-9]+$/) {
        frame_index = idx - 1;
        t_sec = frame_index / fps;

        dt_key = date " " time;
        valid_rows++;

        if (granularity == "per_frame") {
          # one entry per frame
          printf("%d\t%.6f\t%s\t%s\t%s\n",
                 frame_index, t_sec, date, time, dt_key);
          timeline_entries++;
        } else {
          # per_second: only when the dt_key changes
          if (dt_key != prev_dt_key) {
            printf("%d\t%.6f\t%s\t%s\t%s\n",
                   frame_index, t_sec, date, time, dt_key);
            timeline_entries++;
            prev_dt_key = dt_key;
          }
        }
      }
    }

    END {
      printf("[INFO] build_timeline_from_log raw_rows=%d valid_rows=%d timeline_entries=%d granularity=%s\n",
             raw_rows, valid_rows, timeline_entries, granularity) > "/dev/stderr";

      if (valid_rows == 0 || timeline_entries == 0) {
        exit 2;
      }
    }
  ' > "$timeline_out"

  return $?
}


build_sendcmd_from_timeline() {
  local tsv_path="$1"
  local sendcmd_path="$2"

  if [[ ! -s "$tsv_path" ]]; then
    echo "[ERROR] build_sendcmd_from_timeline: empty timeline: $tsv_path" >&2
    return 1
  fi

  : > "$sendcmd_path"   # truncate

  awk -F '\t' '
    # Expect: frame_index \t t_sec \t date \t time \t dt_key
    NF >= 4 {
      frame_idx = $1
      t_sec     = $2 + 0
      date      = $3
      time      = $4

      # Strip CRs
      gsub(/\r/, "", date)
      gsub(/\r/, "", time)

      # Escape backslashes (paranoia)
      gsub(/\\/, "\\\\", date)
      gsub(/\\/, "\\\\", time)

      # Time has colons → escape for drawtext
      gsub(/:/, "\\\\:", time)

      # Dates are YYYY-MM-DD, no spaces/colons, so they’re fine now.

      # Two commands at same timestamp:
      #   dvdate → date
      #   dvtime → time
      printf("%.6f drawtext@dvdate reinit text=%s;\n", t_sec, date)
      printf("%.6f drawtext@dvtime reinit text=%s;\n", t_sec, time)
    }
  ' "$tsv_path" >> "$sendcmd_path"

  local lines
  lines=$(wc -l < "$sendcmd_path" | tr -d "[:space:]")
  echo "[INFO] sendcmd lines: $lines (from timeline: $tsv_path)" >&2

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
  "input_original": "$primary_input_path",
  "artifact_dir": "$artifact_dir",
  "burn_mode": "$burn_mode",
  "subtitle_mode": "$subtitle_mode",
  "layout": "$layout",
  "format": "$format",
  "mp4_preset": "$mp4_preset",
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
  "stitch": {
    "enabled": $stitch_enabled,
    "inputs_manifest": "$stitch_inputs_resolved",
    "stitched_source": "$stitched_source"
  },
  "parse": {
    "frame_source": "$last_parse_frame_source",
    "raw_rows": $last_parse_raw_rows,
    "valid_rows": $last_parse_valid_rows,
    "skipped_rows": $last_parse_skipped_rows,
    "timeline_entries": $last_parse_timeline_entries,
    "timeline_granularity": "$burn_granularity",
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

normalize_dvrescue_timestamps() {
  local source_log="$1"
  local scratch_output="$2"

  if (( timestamps_normalized == 1 )); then
    debug_log "Timestamp normalization already applied; skipping"
    return 0
  fi

  if [[ -z "$source_log" || ! -s "$source_log" ]]; then
    warn "normalize_dvrescue_timestamps: missing or empty log (${source_log:-unset})"
    return 1
  fi

  info "Normalizing dvrescue timestamps (value-only)…"

  local tmp_output
  if [[ -n "$scratch_output" ]]; then
    tmp_output="$scratch_output"
  else
    tmp_output=$(make_temp_file dvmeta_norm .log) || {
      warn "Failed to allocate temp file for normalization"
      return 1
    }
  fi

  if ! awk '
    NF < 4 { print; next }

    {
      idx=$1; tc=$2; date_val=$3; time_val=$4;

      gsub(/[^0-9-]/, "", date_val);

      split(date_val, dparts, "-");
      if (length(dparts) == 3) {
        date_val=sprintf("%04d-%02d-%02d", dparts[1], dparts[2], dparts[3]);
      }

      gsub(/[^0-9:;]/, "", time_val);
      split(time_val, tparts, /[:;]/);
      if (length(tparts) >= 3) {
        time_val=sprintf("%02d:%02d:%02d", tparts[1], tparts[2], tparts[3]);
        if (length(tparts) >= 4) {
          time_val=sprintf("%s;%02d", time_val, tparts[4]);
        }
      }

      printf("%s %s %s %s", idx, tc, date_val, time_val);
      for (i=5; i<=NF; i++) {
        printf(" %s", $i);
      }
      printf("\n");
    }
  ' "$source_log" > "$tmp_output"; then
    warn "Timestamp normalization failed; preserving original log"
    [[ -n "$scratch_output" ]] || rm -f "$tmp_output"
    return 1
  fi

  /bin/mv "$tmp_output" "$source_log"

  timestamps_normalized=1
  info "Timestamp normalization complete"
  return 0
}

normalize_log_value_only() {
  local source_log="$1"
  local target_log="$2"

  if [[ -z "$source_log" || ! -s "$source_log" ]]; then
    return 1
  fi

  local dest="$target_log"
  if [[ -z "$dest" ]]; then
    dest=$(make_temp_file dvmeta_norm .log) || return 1
  fi

  if ! awk '
    NF < 4 { print; next }

    {
      idx=$1; tc=$2; date_val=$3; time_val=$4;

      gsub(/[^0-9-]/, "", date_val);

      split(date_val, dparts, "-");
      if (length(dparts) == 3) {
        date_val=sprintf("%04d-%02d-%02d", dparts[1], dparts[2], dparts[3]);
      }

      gsub(/[^0-9:;]/, "", time_val);
      split(time_val, tparts, /[:;]/);
      if (length(tparts) >= 3) {
        time_val=sprintf("%02d:%02d:%02d", tparts[1], tparts[2], tparts[3]);
        if (length(tparts) >= 4) {
          time_val=sprintf("%s;%02d", time_val, tparts[4]);
        }
      }

      printf("%s %s %s %s", idx, tc, date_val, time_val);
      for (i=5; i<=NF; i++) {
        printf(" %s", $i);
      }
      printf("\n");
    }
  ' "$source_log" > "$dest"; then
    [[ -z "$target_log" ]] && rm -f "$dest"
    return 1
  fi

  [[ -z "$target_log" ]] && /bin/mv "$dest" "$source_log"
  return 0
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
if [[ "$format" == "mp4" ]]; then
  debug_log "MP4 preset: $mp4_preset"
fi
debug_log "Burn mode: $burn_mode"
if [[ "$burn_mode" == "subtitleTrack" ]]; then
  debug_log "Subtitle mode: $subtitle_mode"
fi
debug_log "Stitch enabled: $stitch_enabled"
if [[ -n "$stitch_input_list" ]]; then
  debug_log "Stitch input list: $stitch_input_list"
fi
debug_log "Missing meta handling: $missing_meta"
debug_log "Requested font name: ${subtitle_font_name:-<auto>}"
debug_log "ffmpeg path: $ffmpeg_bin"
debug_log "dvrescue path: $dvrescue_bin"
if [[ -n "$dest_dir" ]]; then
  debug_log "Destination override: $dest_dir"
else
  debug_log "Destination override: <source folder>"
fi

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

build_stitch_input_list() {
  local primary="$1"
  local -n _out_inputs="$2"

  typeset -a inputs
  inputs=("$primary")

  if [[ -n "$stitch_input_list" ]]; then
    if [[ ! -f "$stitch_input_list" ]]; then
      warn "Stitch input list not found: $stitch_input_list"
    else
      while IFS= read -r line; do
        line="${line%%#*}"
        line="${line#${line%%[![:space:]]*}}"
        line="${line%${line##*[![:space:]]}}"
        [[ -z "$line" ]] && continue
        inputs+=("$line")
      done <"$stitch_input_list"
    fi
  fi

  typeset -A seen
  typeset -a deduped
  local clip
  for clip in "${inputs[@]}"; do
    [[ -z "$clip" ]] && continue
    if [[ -z "${seen[$clip]:-}" ]]; then
      if [[ -f "$clip" ]]; then
        deduped+=("$clip")
        seen[$clip]=1
      else
        warn "Stitch input missing: $clip"
      fi
    fi
  done

  _out_inputs=(${deduped[@]})
}

stitch_sources() {
  local primary="$1"
  local artifact_dir="$2"
  local -n _out_source="$3"
  local -n _out_manifest="$4"

  typeset -a input_paths
  build_stitch_input_list "$primary" input_paths

  if (( ${#input_paths[@]} <= 1 )); then
    info "[stitch] Single clip only; skipping stitch step."
    _out_source="$primary"
    _out_manifest=""
    return 0
  fi

  typeset -a stitch_rows
  local clip tmp_log tmp_xml norm_log start_ts
  for clip in "${input_paths[@]}"; do
    tmp_log=$(make_temp_file dvmeta_stitch .log) || return 1
    tmp_xml=$(make_temp_file dvmeta_stitch .xml) || return 1

    "$dvrescue_bin" "$clip" --xml-output "$tmp_xml" >"$tmp_log" 2>&1 || true

    norm_log=$(make_temp_file dvmeta_stitch_norm .log) || return 1
    if ! normalize_log_value_only "$tmp_log" "$norm_log"; then
      warn "[stitch] Failed to normalize timestamps for $clip"
      continue
    fi

    start_ts=$(awk 'NF>=4 {printf "%s %s", $3, $4; exit}' "$norm_log")
    [[ -z "$start_ts" ]] && start_ts="9999-99-99 99:99:99"

    stitch_rows+=("$start_ts|$clip")
  done

  if (( ${#stitch_rows[@]} <= 1 )); then
    info "[stitch] Not enough valid clips after normalization; skipping stitch."
    _out_source="$primary"
    _out_manifest=""
    return 0
  fi

  local concat_manifest
  concat_manifest="${artifact_dir%/}/stitch_inputs.txt"
  : > "$concat_manifest"

  local sorted
  sorted=$(printf "%s\n" "${stitch_rows[@]}" | LC_ALL=C sort)

  typeset -a ordered_inputs
  local line ts clip_path
  while IFS='|' read -r ts clip_path; do
    [[ -z "$clip_path" ]] && continue
    ordered_inputs+=("$clip_path")
    printf "file '%s'\n" "$clip_path" >> "$concat_manifest"
  done <<<"$sorted"

  if (( ${#ordered_inputs[@]} <= 1 )); then
    info "[stitch] Not enough ordered clips to stitch; continuing with original."
    _out_source="$primary"
    _out_manifest=""
    return 0
  fi

  stitch_inputs_resolved="$concat_manifest"

  log_stage_marker "stitch"
  local stitched_path
  stitched_path="${artifact_dir%/}/stitched_source.mkv"

  info "[stitch] Concatenating ${#ordered_inputs[@]} clips into $stitched_path"
  if ! "$ffmpeg_bin" -y -f concat -safe 0 -i "$concat_manifest" -c copy "$stitched_path"; then
    warn "[stitch] ffmpeg concat failed; using primary source"
    _out_source="$primary"
    _out_manifest=""
    return 0
  fi

  stitched_source="$stitched_path"
  _out_source="$stitched_path"
  _out_manifest="$concat_manifest"
  return 0
}

validate_and_plan_file() {
  local in="$1"
  local -n _out_output_dir="$2"
  local -n _out_base="$3"
  local -n _out_base_name="$4"
  local -n _out_ext="$5"

  if [[ ! -f "$in" ]]; then
    echo "[ERROR] Input file not found: $in" >&2
    return 1
  fi

  _out_ext="$format"
  _out_base_name="${in:t:r}"
  if [[ -n "$dest_dir" ]]; then
    _out_output_dir="${dest_dir%/}"
  else
    _out_output_dir="${in:h}"
  fi

  _out_base="${_out_output_dir}/${_out_base_name}"
  return 0
}

create_artifact_scaffold() {
  local in="$1"
  local output_dir="$2"
  local base_name="$3"
  local out_ext="$4"
  local -n _artifact_dir="$5"
  local -n _dvrescue_xml="$6"
  local -n _dvrescue_log="$7"
  local -n _cmdfile="$8"
  local -n _timeline_debug="$9"
  local -n _ass_artifact="${10}"
  local -n _run_manifest="${11}"
  local -n _versions_file="${12}"

  if [[ -n "$dest_dir" && ! -d "$output_dir" ]]; then
    if ! mkdir -p "$output_dir"; then
      echo "[ERROR] Unable to create destination folder: $output_dir" >&2
      return 1
    fi
  fi

  if ! _artifact_dir="$(prepare_artifact_dir "$in")"; then
    return 1
  fi

  _dvrescue_xml="${_artifact_dir}/dvrescue.xml"
  _dvrescue_log="${_artifact_dir}/dvrescue.log"
  _cmdfile="${_artifact_dir}/timestamp.cmd"
  _timeline_debug="${_artifact_dir}/timeline.debug.tsv"
  _ass_artifact="${_artifact_dir}/timestamps.ass"
  _run_manifest="${_artifact_dir}/run_manifest.json"
  _versions_file="${_artifact_dir}/versions.txt"

  rm -f "$_dvrescue_xml"
  debug_log "Cleared prior dvrescue XML target: $_dvrescue_xml"
  : > "$_dvrescue_log"
  : > "$_cmdfile"
  : > "$_timeline_debug"
  : > "$_ass_artifact"
  printf '{"status":"pending","input":"%s"}\n' "$in" > "$_run_manifest"
  : > "$_versions_file"

  log_artifact_path_and_size "dvrescue XML" "$_dvrescue_xml"
  log_artifact_path_and_size "dvrescue log" "$_dvrescue_log"
  echo "[INFO] sendcmd path: $_cmdfile" >&2
  echo "[INFO] ASS output path: $_ass_artifact" >&2
  echo "[INFO] timeline debug path: $_timeline_debug" >&2

  return 0
}

########################################################
# Build sendcmd file from dvrescue log timeline
########################################################

make_timestamp_cmd() {
  local in="$1"
  local cmdfile="$2"
  local _xml_unused="$3"
  local dv_log="$4"
  local timeline_debug="$5"
  local fps="$6"

  : > "$cmdfile"

  if [[ -z "$fps" ]]; then
    echo "[ERROR] FPS value missing for $in" >&2
    return 1
  fi

  local build_output build_status
  build_output=$({ build_timeline_from_log "$dv_log" "$fps" "$timeline_debug" "$burn_granularity"; } 2>&1)
  build_status=$?
  printf "%s\n" "$build_output" >&2

  local stats_line
  stats_line=$(printf "%s\n" "$build_output" | awk '/build_timeline_from_log raw_rows=/ {print; exit}')

  local raw_rows=0 valid_rows=0 timeline_entries=0
  if [[ -n "$stats_line" ]]; then
    raw_rows=$(printf "%s\n" "$stats_line" | awk '{for(i=1;i<=NF;i++){if($i~ /^raw_rows=/){split($i,a,"="); print a[2]; break}}}')
    valid_rows=$(printf "%s\n" "$stats_line" | awk '{for(i=1;i<=NF;i++){if($i~ /^valid_rows=/){split($i,a,"="); print a[2]; break}}}')
    timeline_entries=$(printf "%s\n" "$stats_line" | awk '{for(i=1;i<=NF;i++){if($i~ /^timeline_entries=/){split($i,a,"="); print a[2]; break}}}')
  fi

  last_parse_frame_source="log"
  last_parse_raw_rows=${raw_rows:-0}
  last_parse_valid_rows=${valid_rows:-0}
  last_parse_skipped_rows=$(( last_parse_raw_rows - last_parse_valid_rows ))
  (( last_parse_skipped_rows < 0 )) && last_parse_skipped_rows=0
  last_parse_timeline_entries=${timeline_entries:-0}

  local timeline_fail=0
  if (( build_status != 0 )); then
    timeline_fail=1
  elif ! build_sendcmd_from_timeline "$timeline_debug" "$cmdfile"; then
    timeline_fail=1
  fi

  if (( timeline_fail != 0 )); then
    echo "[ERROR] Failed to build sendcmd timeline from dvrescue.log" >&2
    return 2
  fi

  debug_log "sendcmd lines for $in: $(wc -l < "$cmdfile" | tr -d '[:space:]')"
  return 0
}
########################################################
# Build ASS subtitles from log timeline
########################################################

make_ass_subs() {
  local in="$1"
  local layout="$2"
  local ass_out="$3"
  local _xml_unused="$4"
  local dv_log="$5"
  local timeline_debug="$6"
  local fps="$7"

  if [[ -z "$fps" ]]; then
    echo "[ERROR] FPS value missing for subtitle generation" >&2
    return 1
  fi

  : > "$ass_out"

  local build_output build_status
  build_output=$({ build_timeline_from_log "$dv_log" "$fps" "$timeline_debug" "$burn_granularity"; } 2>&1)
  build_status=$?
  printf "%s\n" "$build_output" >&2

  local stats_line
  stats_line=$(printf "%s\n" "$build_output" | awk '/build_timeline_from_log raw_rows=/ {print; exit}')

  local raw_rows=0 valid_rows=0 timeline_entries=0
  if [[ -n "$stats_line" ]]; then
    raw_rows=$(printf "%s\n" "$stats_line" | awk '{for(i=1;i<=NF;i++){if($i~ /^raw_rows=/){split($i,a,"="); print a[2]; break}}}')
    valid_rows=$(printf "%s\n" "$stats_line" | awk '{for(i=1;i<=NF;i++){if($i~ /^valid_rows=/){split($i,a,"="); print a[2]; break}}}')
    timeline_entries=$(printf "%s\n" "$stats_line" | awk '{for(i=1;i<=NF;i++){if($i~ /^timeline_entries=/){split($i,a,"="); print a[2]; break}}}')
  fi

  last_parse_frame_source="log"
  last_parse_raw_rows=${raw_rows:-0}
  last_parse_valid_rows=${valid_rows:-0}
  last_parse_skipped_rows=$(( last_parse_raw_rows - last_parse_valid_rows ))
  (( last_parse_skipped_rows < 0 )) && last_parse_skipped_rows=0
  last_parse_timeline_entries=${timeline_entries:-0}

  if (( build_status != 0 )); then
    echo "[ERROR] No RDT rows parsed from dvrescue.log; skipping subtitle burn-in per --missing-meta=${missing_meta}" >&2
    return 2
  fi

  local subtitle_font_safe
  subtitle_font_safe=${subtitle_font_name//\\/\\\\}
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
; bottom-left (date)
Style: DVLeft,${subtitle_font_safe},24,&H00FFFFFF,&H00000000,&H00000000,&H00000000,-1,0,0,0,100,100,0,0,1,0,0,1,20,0,40,1
; bottom-right (time or stacked block)
Style: DVRight,${subtitle_font_safe},24,&H00FFFFFF,&H00000000,&H00000000,&H00000000,-1,0,0,0,100,100,0,0,1,0,0,3,0,20,40,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
EOF


   local frame_step
  frame_step=$(awk -v fps="$fps" 'BEGIN{if (fps<=0) {exit 1} printf "%.6f", 1/fps}') || {
    echo "[ERROR] Unable to compute frame step for subtitles" >&2
    return 1
  }

  local -i raw_lines=0 dialogue_count=0 skipped_lines=0
  local prev_start_sec="" prev_date="" prev_time="" prev_dt=""

  while IFS=$'\t' read -r frame_idx t_sec date_part time_part dt_key; do
    (( raw_lines++ ))

    if [[ -z "$t_sec" || -z "$date_part" || -z "$time_part" ]]; then
      (( skipped_lines++ ))
      continue
    fi

    local dt_key_fallback="${date_part} ${time_part}"
    [[ -z "$dt_key" ]] && dt_key="$dt_key_fallback"

    if [[ -n "$prev_dt" ]]; then
      local start_str end_str
      start_str=$(seconds_to_ass_time "$prev_start_sec")
      end_str=$(seconds_to_ass_time "$t_sec")

      case "$layout" in
        stacked)
          # One stacked block, bottom-right
          printf "Dialogue: 0,%s,%s,DVRight,,0,0,40,,%s\\N%s\n" \
            "$start_str" "$end_str" "$prev_date" "$prev_time" >> "$ass_out"
          (( dialogue_count++ ))
          ;;
        single)
          # Date bottom-left, time bottom-right on same baseline
          printf "Dialogue: 0,%s,%s,DVLeft,,20,0,40,,%s\n" \
            "$start_str" "$end_str" "$prev_date" >> "$ass_out"
          printf "Dialogue: 0,%s,%s,DVRight,,0,20,40,,%s\n" \
            "$start_str" "$end_str" "$prev_time" >> "$ass_out"
          (( dialogue_count+=2 ))
          ;;
        *)
          printf "Dialogue: 0,%s,%s,DVRight,,0,0,40,,%s\\N%s\n" \
            "$start_str" "$end_str" "$prev_date" "$prev_time" >> "$ass_out"
          (( dialogue_count++ ))
          ;;
      esac
    fi

    prev_start_sec="$t_sec"
    prev_date="$date_part"
    prev_time="$time_part"
    prev_dt="$dt_key"
  done < "$timeline_debug"

  # Close the last subtitle segment
  if [[ -n "$prev_dt" && -n "$prev_start_sec" ]]; then
    local start_str end_str end_sec
    start_str=$(seconds_to_ass_time "$prev_start_sec")
    end_sec=$(awk -v start="$prev_start_sec" -v step="$frame_step" 'BEGIN{printf "%.6f", start+step}')
    end_str=$(seconds_to_ass_time "$end_sec")

    case "$layout" in
      stacked)
        printf "Dialogue: 0,%s,%s,DVRight,,0,0,40,,%s\\N%s\n" \
          "$start_str" "$end_str" "$prev_date" "$prev_time" >> "$ass_out"
        (( dialogue_count++ ))
        ;;
      single)
        printf "Dialogue: 0,%s,%s,DVLeft,,20,0,40,,%s\n" \
          "$start_str" "$end_str" "$prev_date" >> "$ass_out"
        printf "Dialogue: 0,%s,%s,DVRight,,0,20,40,,%s\n" \
          "$start_str" "$end_str" "$prev_time" >> "$ass_out"
        (( dialogue_count+=2 ))
        ;;
      *)
        printf "Dialogue: 0,%s,%s,DVRight,,0,0,40,,%s\\N%s\n" \
          "$start_str" "$end_str" "$prev_date" "$prev_time" >> "$ass_out"
        (( dialogue_count++ ))
        ;;
    esac
  fi

  if [[ ${timeline_entries:-0} -gt 0 ]]; then
    last_parse_timeline_entries=${timeline_entries}
  else
    last_parse_timeline_entries=$dialogue_count
  fi

  local skipped_rows=$last_parse_skipped_rows
  local summary_line
  summary_line="[INFO] Subtitle parse summary (source=log): rows=$raw_rows, valid=$valid_rows, skipped=$skipped_rows, timeline_entries=$dialogue_count"
  echo "$summary_line" >&2
  debug_log "$summary_line"

  if (( dialogue_count < 1 )); then
    echo "[WARN] No valid subtitle timestamps found in dvrescue log" >&2
    return 2
  fi

  return 0
}
offline_smoke_test() {
  local _xml_unused="${1:-/tmp/dvrescue.xml}"
  local log="${2:-/tmp/dvrescue.log}"
  local fps="${3:-29.97}"
  local cmdfile="${4:-/tmp/timestamp.cmd}"
  local timeline="${5:-/tmp/timeline.debug.tsv}"

  if ! make_timestamp_cmd "offline_sample" "$cmdfile" "$log" "$log" "$timeline" "$fps"; then
    echo "[ERROR] offline_smoke_test failed to build timestamp command file" >&2
    return 1
  fi

  echo "[INFO] offline_smoke_test artifacts: timeline=$timeline sendcmd=$cmdfile (source=log fps=$fps)" >&2
}

########################################################
# Main per-file processing
########################################################

process_file_core() {
  local in="$1"
  local base="$2"
  local out_ext="$3"
  local artifact_dir="$4"
  local dvrescue_xml="$5"
  local dvrescue_log="$6"
  local cmdfile="$7"
  local timeline_debug="$8"
  local ass_artifact="$9"
  local run_manifest="${10}"
  local versions_file="${11}"

  local burn_output="" subtitle_output="" passthrough_output=""
  local exit_status=0 manifest_status="pending"

  local source_video="$in"
  local stitch_manifest=""

  stitch_inputs_resolved=""
  stitched_source=""

  last_parse_raw_rows=0
  last_parse_valid_rows=0
  last_parse_skipped_rows=0
  last_parse_timeline_entries=0
  last_parse_frame_source="unknown"
  last_dvrescue_status=0
  timestamps_normalized=0

  local -a codec_args
  case "$format" in
    mov)
      codec_args=(-c:v dvvideo -c:a copy)
      ;;
    mp4)
      case "$mp4_preset" in
        best-quality)
          codec_args=(-c:v mpeg4 -qscale:v 1 -c:a aac -b:a 256k)
          ;;
        audio-only)
          codec_args=(-vn -c:a aac -b:a 192k)
          ;;
        *)
          codec_args=(-c:v mpeg4 -qscale:v 2 -c:a aac -b:a 192k)
          ;;
      esac
      ;;
    mkv)
      codec_args=(-c:v mpeg4 -qscale:v 2 -c:a aac -b:a 192k)
      ;;
    *)
      warn "Unknown format: $format"
      manifest_status="error"
      finish_run 1 "$manifest_status" "$source_video" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_artifact" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
      return 1
      ;;
  esac

  local fps
  if (( stitch_enabled == 1 )); then
    if ! stitch_sources "$in" "$artifact_dir" source_video stitch_manifest; then
      warn "[stitch] Stitching failed; continuing with original clip"
      source_video="$in"
      stitch_inputs_resolved=""
      stitched_source=""
    elif [[ "$source_video" != "$in" ]]; then
      info "[stitch] Using stitched source for downstream processing: $source_video"
    else
      info "[stitch] Stitch step skipped; using primary clip."
    fi
  fi

  if ! fps="$(detect_fps "$source_video")"; then
    finish_run 1 "error" "$source_video" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_artifact" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
    return 1
  fi
  last_detected_fps="$fps"
  debug_log "Detected FPS: $fps"

  local dv_status=0
  debug_log "Extracting dvrescue XML -> $dvrescue_xml (log: $dvrescue_log)"
  "$dvrescue_bin" "$source_video" --xml-output "$dvrescue_xml" >"$dvrescue_log" 2>&1
  dv_status=$?
  last_dvrescue_status=$dv_status
  log_artifact_path_and_size "dvrescue XML" "$dvrescue_xml"
  log_artifact_path_and_size "dvrescue log" "$dvrescue_log"

  log_stage_marker "timeline"

  if [[ "$burn_mode" != "off" ]]; then
    normalize_dvrescue_timestamps "$dvrescue_log" "${artifact_dir}/dvrescue.normalized.log" || \
      warn "Proceeding with unnormalized timestamps due to prior error"
  fi

  # Transcode-only mode: no metadata
  if [[ "$burn_mode" == "off" ]]; then
    local out_passthrough="${base}_conv.${out_ext}"
    echo "[INFO] Transcode-only conversion (no burn-in) to: $out_passthrough"
    debug_log "Running transcode-only encode with args: ${codec_args[*]}"
    log_stage_marker "encode"
    "$ffmpeg_bin" -y -i "$source_video" \
      "${codec_args[@]}" \
      "$out_passthrough"
    exit_status=$?
    manifest_status=$([[ $exit_status -eq 0 ]] && echo "success" || echo "error")
    passthrough_output="$out_passthrough"
    finish_run "$exit_status" "$manifest_status" "$source_video" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_artifact" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
    return $exit_status
  fi

  local font
  if ! font="$(find_font)"; then
    echo "[ERROR] Unable to locate a usable font. Provide --fontfile, set DVMETABURN_FONTFILE, or place a supported font in Resources/fonts/." >&2
    manifest_status="error"
    finish_run 1 "$manifest_status" "$source_video" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_artifact" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
    return 1
  fi

  debug_log "Using font file: $font"

  if [[ -z "$subtitle_font_name" ]]; then
    subtitle_font_name="UAV OSD Mono"
  fi
  subtitle_font_name="${subtitle_font_name//,/ }"

  # Subtitle track mode: generate ASS from timeline and mux into container
  if [[ "$burn_mode" == "subtitleTrack" ]]; then
    if [[ "$out_ext" != "mkv" ]]; then
      echo "[ERROR] Subtitle track muxing is only supported for MKV output (got '$out_ext')." >&2
      manifest_status="error"
      finish_run 1 "$manifest_status" "$source_video" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_artifact" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
      return 1
    fi

    local sub_status=0

    # Build ASS subtitles from the dvrescue timeline
    if ! make_ass_subs "$source_video" "$layout" "$ass_artifact" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$fps"; then
      sub_status=$?
    fi

    # Handle missing / bad metadata according to --missing-meta
    if (( sub_status != 0 )); then
      echo "[WARN] Failed to build subtitles; honoring --missing-meta=$missing_meta (status=$sub_status)" >&2
      case "$missing_meta" in
        skip_burnin_convert)
          echo "[WARN] Missing timestamp metadata for $source_video; converting without subtitle track." >&2
          local out_passthrough="${base}_conv.${out_ext}"
          log_stage_marker "encode"
          "$ffmpeg_bin" -y -i "$source_video" \
            "${codec_args[@]}" \
            "$out_passthrough"
          exit_status=$?
          manifest_status=$([[ $exit_status -eq 0 ]] && echo "success" || echo "error")
          passthrough_output="$out_passthrough"
          finish_run "$exit_status" "$manifest_status" "$source_video" "$artifact_dir" \
            "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_artifact" \
            "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
          return $exit_status
          ;;
        skip_file)
          echo "[WARN] Missing timestamp metadata for $source_video; skipping file." >&2
          manifest_status="skipped"
          finish_run 0 "$manifest_status" "$source_video" "$artifact_dir" \
            "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_artifact" \
            "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
          return 0
          ;;
        error|*)
          echo "[ERROR] Missing timestamp metadata and --missing-meta=error; aborting subtitle mode." >&2
          manifest_status="error"
          finish_run 1 "$manifest_status" "$source_video" "$artifact_dir" \
            "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_artifact" \
            "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
          return 1
          ;;
      esac
    fi

    log_stage_marker "encode"

    # We have a valid ASS file – mux it as MKV with true ASS subtitles
    local out_subbed="${base}_dvsub.mkv"
    local -a sub_video_args=(
      -c:v mpeg4 -qscale:v 2
      -c:a aac -b:a 192k
    )
    local subtitle_codec="ass"

    echo "[INFO] Muxing subtitle track into: $out_subbed" >&2
    "$ffmpeg_bin" -y -i "$source_video" -i "$ass_artifact" \
      -map 0:v:0 -map 0:a? -map 1:s:0 \
      "${sub_video_args[@]}" \
      -c:s "$subtitle_codec" \
      "$out_subbed"

    exit_status=$?
    manifest_status=$([[ $exit_status -eq 0 ]] && echo "success" || echo "error")
    subtitle_output="$out_subbed"
    finish_run "$exit_status" "$manifest_status" "$source_video" "$artifact_dir" \
      "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_artifact" \
      "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
    return $exit_status
  fi

  local timeline_fail=0
  if ! make_timestamp_cmd "$source_video" "$cmdfile" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$fps"; then
    timeline_fail=1
  fi

  if (( timeline_fail != 0 )); then
    echo "[WARN] Failed to build timestamp timeline from log; honoring --missing-meta=$missing_meta" >&2
    case "$missing_meta" in
      error)
        finish_run 1 "error" "$source_video" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_artifact" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
        return 1
        ;;
      skip_burnin_convert)
        echo "[WARN] Converting without burn-in due to missing timestamp metadata." >&2
        local out_passthrough="${base}_conv.${out_ext}"
        log_stage_marker "encode"
        "$ffmpeg_bin" -y -i "$source_video" \
          "${codec_args[@]}" \
          "$out_passthrough"
        exit_status=$?
        manifest_status=$([[ $exit_status -eq 0 ]] && echo "success" || echo "error")
        passthrough_output="$out_passthrough"
        finish_run "$exit_status" "$manifest_status" "$source_video" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_artifact" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
        return $exit_status
        ;;
      skip_file)
        echo "[WARN] Skipping $source_video due to missing timestamp metadata." >&2
        manifest_status="skipped"
        finish_run 0 "$manifest_status" "$source_video" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_artifact" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
        return 0
        ;;
    esac
  fi

  log_stage_marker "encode"

  local vf
  case "$layout" in
    stacked)
      vf="sendcmd=f='${cmdfile}',\\
drawtext@dvdate=fontfile='${font}':text='':fontcolor=white:fontsize=24:box=0:x=w-tw-20:y=h-60,\\
drawtext@dvtime=fontfile='${font}':text='':fontcolor=white:fontsize=24:box=0:x=w-tw-20:y=h-30"
      ;;
    single)
      vf="sendcmd=f='${cmdfile}',\\
drawtext@dvdate=fontfile='${font}':text='':fontcolor=white:fontsize=24:box=0:x=20:y=h-40,\\
drawtext@dvtime=fontfile='${font}':text='':fontcolor=white:fontsize=24:box=0:x=w-tw-20:y=h-40"
      ;;
    *)
      echo "Unknown layout: $layout" >&2
      finish_run 1 "error" "$source_video" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_artifact" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
      return 1
      ;;
  esac

  local out="${base}_dateburn.${out_ext}"

  echo "[INFO] Burning DV metadata into: $out"
  debug_log "ffmpeg burn-in args: ${codec_args[*]}"
  "$ffmpeg_bin" -y -i "$source_video" \
    -vf "$vf" \
    "${codec_args[@]}" \
    "$out"

  exit_status=$?
  manifest_status=$([[ $exit_status -eq 0 ]] && echo "success" || echo "error")
  burn_output="$out"
  echo "ffmpeg exit code: $exit_status"
  finish_run "$exit_status" "$manifest_status" "$source_video" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_artifact" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
  return $exit_status
}

process_file_controller() {
  local in="$1"
  debug_log "process_file_controller() received: '$in'"

  primary_input_path="$in"

  log_stage_marker "validation"
  local output_dir base base_name out_ext
  if ! validate_and_plan_file "$in" output_dir base base_name out_ext; then
    return 1
  fi

  log_stage_marker "artifact_stubs"
  local artifact_dir dvrescue_xml dvrescue_log cmdfile timeline_debug ass_artifact run_manifest versions_file
  if ! create_artifact_scaffold "$in" "$output_dir" "$base_name" "$out_ext" artifact_dir dvrescue_xml dvrescue_log cmdfile timeline_debug ass_artifact run_manifest versions_file; then
    return 1
  fi

  log_stage_marker "dvrescue"
  process_file_core "$in" "$base" "$out_ext" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$cmdfile" "$timeline_debug" "$ass_artifact" "$run_manifest" "$versions_file"
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
    echo "Usage: $0 [--mode=single] [--layout=stacked|single] [--format=mov|mp4|mkv] [--preset=default|best-quality|audio-only] [--burn-mode=burnin|off|subtitleTrack] [--subtitle-mode=per-clip|continuous] [--stitch [--stitch-inputs=/path/to/list.txt]] /path/to/clip.avi" >&2
    exit 1
  fi
  debug_log "Running in single-file mode with target: $1"
  process_file_controller "$1"
  exit $?
fi

if [[ "$mode" == "batch" ]]; then
  if [[ $# -ne 1 ]]; then
    echo "Usage: $0 --mode=batch [--layout=stacked|single] [--format=mov|mp4|mkv] [--preset=default|best-quality|audio-only] [--burn-mode=burnin|off|subtitleTrack] [--subtitle-mode=per-clip|continuous] [--stitch [--stitch-inputs=/path/to/list.txt]] /path/to/folder" >&2
    exit 1
  fi

  folder="$1"

  if [[ ! -d "$folder" ]]; then
    echo "ERROR: $folder is not a folder" >&2
    exit 1
  fi

  # Canonical absolute path
  folder_abs="$(cd "$folder" && pwd)"
  if [[ -z "$folder_abs" ]]; then
    echo "ERROR: Failed to resolve folder path: $folder" >&2
    exit 1
  fi

  echo "Batch mode: scanning $folder_abs"
  debug_log "Scanning batch folder with zsh globs (**/*.(avi|AVI|dv|DV))"

  # Use zsh’s recursive globbing; only existing regular files (.N)
  setopt localoptions null_glob extended_glob

  typeset -a files
  files=("$folder_abs"/**/*.(avi|AVI|dv|DV)(.N))

  if (( ${#files[@]} == 0 )); then
    echo "[WARN] No DV files found in: $folder_abs"
    exit 0
  fi

  for abs in "${files[@]}"; do
    debug_log "Batch candidate path: '$abs'"
    echo "Processing $abs"

    if ! process_file_controller "$abs"; then
      echo "[ERROR] Failed while processing: $abs" >&2
      # continue to next file instead of bailing
      continue
    fi
  done

  exit 0
fi






echo "ERROR: Unknown mode: $mode" >&2
exit 1
