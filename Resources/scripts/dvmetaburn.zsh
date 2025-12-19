#!/bin/zsh

set -euo pipefail
setopt ERR_EXIT
# ERR_FAIL is NOT a real zsh option -> remove it
# setopt ERR_FAIL

TRAPZERR() {
  local rc=$?

  # ZSH_COMMAND / ZSH_DEBUG_CMD can be unset; avoid blowing up under -u
  local cmd="${ZSH_DEBUG_CMD-}"
  [[ -z "$cmd" ]] && cmd="${ZSH_COMMAND-}"
  [[ -z "$cmd" ]] && cmd="<unknown command>"

  # funcfiletrace may be unset; guard it
  local where
  if (( ${+funcfiletrace} )); then
    where="${funcfiletrace[1]}"
  else
    where="${(%):-%N}:${LINENO}"
  fi

  print -r -- "[FATAL] (exit=$rc) $cmd | $where" >&2
}

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

die() {
  echo "[ERROR] $1" >&2
  exit "${2:-1}"
}

warn() {
  echo "[WARN] $*" >&2
}

info() {
  echo "[INFO] $*" >&2
}

debug() {
  if (( ${debug_mode:-0} == 1 )); then
    echo "[DEBUG] $*" >&2
  fi
  return 0
}

# Lightweight helper for conditional debug output
debug_log() {
  if (( debug_mode == 1 )); then
    echo "[DEBUG] $*" >&2
  fi
}

json_escape() {
  local raw="$1"
  # Escape backslashes first, then double quotes
  raw="${raw//\\/\\\\}"
  raw="${raw//\"/\\\"}"
  echo "$raw"
}

escape_for_single_quotes() {
  local raw="$1"
  raw="${raw//\'/'"'"'\'}"
  echo "$raw"
}

log_ffmpeg_command() {
  local label="$1"
  shift
  local -a cmd=("$@")
  echo "[ffmpeg/${label}] ${(q)cmd[@]}" >&2
}

log_export() {
  local src="$1"
  local dst="$2"
  echo "[EXPORT] src='${src}' -> dst='${dst}'" >&2
}

probe_media_duration() {
  local path="$1"
  if [[ -z "$path" || ! -f "$path" ]]; then
    return 1
  fi

  local duration_line
  duration_line=$("$ffmpeg_bin" -hide_banner -i "$path" 2>&1 | awk -F',' '/Duration:/ {gsub(/Duration: /,"",$1); print $1; exit}')

  [[ -n "$duration_line" ]] || return 1
  echo "$duration_line"
}

sanitize_extra_ffmpeg_args() {
  sanitized_extra_args=()
  local -a raw=("$@")
  local skip_next_input=0
  local skipped_option=""
  local token ext
  for token in "${raw[@]}"; do
    if (( skip_next_input == 1 )); then
      warn "[extra-args] Dropping value following ${skipped_option:-managed option}: $token"
      skip_next_input=0
      skipped_option=""
      continue
    fi

    case "$token" in
      (-i|-filter_complex|-vf|-af|-map)
        warn "[extra-args] Ignoring '$token' to protect managed inputs."
        skip_next_input=1
        skipped_option="$token"
        continue
        ;;
      (-y|-n)
        warn "[extra-args] Ignoring '$token' to protect managed outputs."
        continue
        ;;
    esac

    if [[ "$token" == */* || "$token" == *.* ]]; then
      ext="${token##*.}"
      ext="${ext:l}"
      case "$ext" in
        mov|mp4|mkv|avi|flv|wmv|mpg|mpeg|m4v|ts|webm|mxf|mp3|wav)
          warn "[extra-args] Ignoring possible output override: $token"
          continue
          ;;
      esac
    fi

    sanitized_extra_args+=("$token")
  done

  if (( ${#sanitized_extra_args[@]} > 0 )); then
    echo "[extra-args] Sanitized args: ${(q)sanitized_extra_args[@]}" >&2
  else
    debug "[extra-args] No sanitized extra args present"
  fi
}


typeset -ga run_notes=()
typeset -ga initial_run_notes=()
typeset -ga sanitized_extra_args=()
typeset -g last_stage_marker=""
extra_args_raw=""

append_run_note() {
  local msg="$*"
  run_notes+=("$msg")
  if (( ${debug_mode:-0} == 1 )); then
    echo "[DEBUG] [note] $msg" >&2
  fi
  return 0
}


log_stage_marker() {
  local stage="$1"
  last_stage_marker="$stage"
  echo "[STAGE] $stage" >&2
}

run_stage() {
  local stage="$1"
  shift

  log_stage_marker "$stage"

  set +e
  "$@"
  local rc=$?
  set -e

  if (( rc != 0 )); then
    echo "[ERROR] ${stage} failed (exit ${rc})" >&2
  fi

  return $rc
}

audio_extension_for_format() {
  local fmt="${1:l}"
  case "$fmt" in
    mov|mp4)
      echo "m4a"
      ;;
    mkv)
      echo "mka"
      ;;
    *)
      echo "m4a"
      ;;
  esac
}

container_flag_for_format() {
  local fmt="${1:l}"
  reply=()

  case "$fmt" in
    mkv)
      reply=(-f matroska)
      ;;
    *)
      reply=()
      ;;
  esac
}

resolve_audio_bitrate() {
  local quality_kind="$1"

  case "$quality_kind" in
    low)
      resolved_audio_bitrate=128
      ;;
    medium|"")
      resolved_audio_bitrate=192
      ;;
    high)
      resolved_audio_bitrate=256
      ;;
    *)
      resolved_audio_bitrate=192
      ;;
  esac
}

quality_to_video_args() {
  local quality_kind="$1"
  reply=()

  case "$quality_kind" in
    high)
      reply=(-c:v libx264 -crf 18 -preset slow)
      ;;
    low)
      reply=(-c:v libx264 -crf 28 -preset veryfast)
      ;;
    *)
      reply=(-c:v libx264 -crf 22 -preset medium)
      ;;
  esac
}

normalize_deinterlace_mode() {
  local raw="${1:-}"
  raw="${raw//[[:space:]]/}"
  raw="${raw//_/-}"
  raw="${raw:l}"

  case "$raw" in
    ""|off|none|false|0)
      echo "off"
      ;;
    30|30p|p30)
      echo "30p"
      ;;
    60|60p|p60)
      echo "60p"
      ;;
    *)
      fatal "Invalid deinterlace mode '$raw'; expected off, 30p, or 60p."
      ;;
  esac
}

deinterlace_vf_for_mode() {
  local mode="$1"
  case "$mode" in
    30p)
      echo "yadif=mode=0"
      ;;
    60p)
      echo "yadif=mode=1"
      ;;
    *)
      echo ""
      ;;
  esac
}

deinterlace_output_fps_args_for_mode() {
  local mode="$1"
  reply=()
  case "$mode" in
    60p)
      reply=(-r 60000/1001)
      ;;
  esac
}

########################################################
# Defaults / configuration
########################################################

mode="single"        # "single" or "batch"
layout="stacked"     # "stacked" or "single"
format="mov"         # "mov", "mp4", or "mkv"
encode_quality="medium" # low, medium, high (passthrough for mov)
output_mode="video"   # "video" or "audio"
burn_mode="burnin"   # "burnin" or "off" or "subtitleTrack"
subtitle_mode="per-clip" # "per-clip" or "continuous"
deinterlace_mode="off" # "off" or "30p" or "60p"
missing_meta="skip_burnin_convert"  # behavior when metadata is missing
fontfile=""
fontname="UAV-OSD-Mono"
ffmpeg_bin="ffmpeg"
dvrescue_bin="dvrescue"
artifact_root="${HOME}/Library/Logs/DVMeta"
dest_dir=""
output_base=""
# Controls how densely timestamps are emitted into the timeline
burn_granularity="per_second"  # "per_second" or "per_frame"
# Opt-in verbose logging for troubleshooting
debug_mode=0
# Optional stitching
stitch_enabled=0
stitch_batch=0
stitch_input_list=""
stitched_source=""
stitch_inputs_resolved=""
suppress_finish_run=0
last_burn_output_path=""
last_subtitle_output_path=""
last_passthrough_output_path=""
scratch_dir="${DVMETA_SCRATCH_DIR:-}"
run_scratch_root=""

# Optional environment overrides
: "${DVMETABURN_FONTFILE:=}"   # override font path

########################################################
# CLI flag parsing
########################################################

subtitle_mode_arg_set=0
encode_quality_arg_set=0
deprecated_encode_quality_used=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode=*) mode="${1#*=}"; shift ;;
    --layout=*) layout="${1#*=}"; shift ;;
    --format=*) format="${1#*=}"; shift ;;
    --encode-quality=*) encode_quality="${1#*=}"; encode_quality_arg_set=1; deprecated_encode_quality_used=1; shift ;;
    --quality=*) encode_quality="${1#*=}"; encode_quality_arg_set=1; shift ;;
    --output-mode=*) output_mode="${1#*=}"; shift ;;
    --burn-mode=*) burn_mode="${1#*=}"; shift ;;
    --subtitle-mode=*) subtitle_mode="${1#*=}"; subtitle_mode_arg_set=1; shift ;;
    --deinterlace=*) deinterlace_mode="${1#*=}"; shift ;;
    --missing-meta=*) missing_meta="${1#*=}"; shift ;;
    --fontfile=*) fontfile="${1#*=}"; shift ;;
    --fontname=*) fontname="${1#*=}"; shift ;;
    --ffmpeg=*) ffmpeg_bin="${1#*=}"; shift ;;
    --dvrescue=*) dvrescue_bin="${1#*=}"; shift ;;
    --dest-dir=*) dest_dir="${1#*=}"; shift ;;
    --output-base=*) output_base="${1#*=}"; shift ;;
    --scratch-dir=*) scratch_dir="${1#*=}"; shift ;;
    --stitch) stitch_enabled=1; shift ;;
        --stitch-mode=*)
      case "${1#*=}" in
        stitch|on|enable)
          stitch_enabled=1
          ;;
        off|none|disable)
          stitch_enabled=0
          ;;
        *)
          fatal "Invalid --stitch-mode value: ${1#*=}"
          ;;
      esac
      shift
      ;;

    --stitch-inputs=*) stitch_input_list="${1#*=}"; shift ;;
    --stitch-batch=*) stitch_batch="${1#*=}"; shift ;;
    --stitch-batch) stitch_batch=1; shift ;;
    --debug) debug_mode=1; shift ;;
    --extra-ffmpeg-flags=*) extra_args_raw="${1#*=}"; shift ;;
    --extra-args=*) extra_args_raw="${1#*=}"; shift ;;
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

output_base="${output_base%/}"

encode_quality="${encode_quality//[[:space:]]/}"
encode_quality="${encode_quality//_/-}"
encode_quality="${encode_quality:l}"
if [[ -z "$encode_quality" ]]; then
  encode_quality="medium"
fi

output_mode="${output_mode//[[:space:]]/}"
output_mode="${output_mode:l}"
case "$output_mode" in
  audio|audioonly)
    output_mode="audio"
    ;;
  video|"")
    output_mode="video"
    ;;
  *)
    fatal "Invalid output mode '$output_mode'; expected video or audio."
    ;;
esac

stitch_batch="${stitch_batch//[[:space:]]/}"
stitch_batch="${stitch_batch//_/-}"
stitch_batch="${stitch_batch:l}"
case "$stitch_batch" in
  1|true|yes|on)
    stitch_batch=1
    ;;
  0|false|no|off|"")
    stitch_batch=0
    ;;
  *)
    stitch_batch=0
    ;;
esac

if [[ "$mode" == "batch" && $stitch_enabled -eq 1 && $stitch_batch -eq 0 ]]; then
  stitch_batch=1
  debug_log "[stitch] mode=batch and stitch enabled -> forcing stitch_batch=1"
fi

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

if [[ "$output_mode" == "audio" ]]; then
  burn_mode="off"
  subtitle_mode=""
  deinterlace_mode="off"
fi

deinterlace_mode="$(normalize_deinterlace_mode "$deinterlace_mode")"

if [[ -n "$extra_args_raw" ]]; then
  info "[extra-args] raw: ${(q)extra_args_raw}"
  typeset -a parsed_extra_args
  parsed_extra_args=(${(z)extra_args_raw})
  sanitize_extra_ffmpeg_args "${parsed_extra_args[@]}"
else
  sanitized_extra_args=()
fi

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

case "$encode_quality" in
  low|medium|high)
    ;;
  passthrough|pass-through)
    encode_quality="passthrough"
    ;;
  "")
    encode_quality="medium"
    ;;
  *)
    warn "Unknown quality '$encode_quality'; defaulting to medium."
    encode_quality="medium"
    ;;
esac

if (( deprecated_encode_quality_used == 1 )); then
  warn "[config] --encode-quality is deprecated; use --quality=low|medium|high"
fi

requested_format="$format"
requested_encode_quality="$encode_quality"

# Track effective values after validation/coercion
effective_format="$format"
effective_quality_kind="$encode_quality"

if (( subtitle_mode_arg_set == 1 )) && [[ "$burn_mode" != "subtitleTrack" ]]; then
  fatal "--subtitle-mode requires --burn-mode=subtitleTrack."
fi

if [[ "$burn_mode" == "subtitleTrack" ]] && [[ "$subtitle_mode" != "per-clip" && "$subtitle_mode" != "continuous" ]]; then
  fatal "--burn-mode=subtitleTrack requires a valid --subtitle-mode (per-clip or continuous)."
fi

if [[ "$burn_mode" == "subtitleTrack" ]] && [[ "$format" == "mp4" || "$format" == "mov" ]]; then
  echo "[INFO] Subtitle tracks require an MKV container; coercing format '$format' to 'mkv' while preserving the base filename." >&2
  append_run_note "Subtitle track mode coerced container from $format to mkv while keeping base filename"
  format_coerced=1
  format_coercion_reason="subtitleTrack requires mkv container"
  format="mkv"
  effective_format="$format"
fi

if [[ "$effective_format" == "mov" ]]; then
  effective_quality_kind="passthrough"
fi

if [[ "$effective_format" != "mov" && "$effective_quality_kind" == "passthrough" ]]; then
  warn "${effective_format:u} passthrough not supported; coercing encode quality to medium."
  append_run_note "${effective_format:u} passthrough request coerced to medium-quality transcode"
  effective_quality_kind="medium"
fi

effective_encode_quality="$effective_quality_kind"
quality_log_suffix=""
if (( encode_quality_arg_set == 0 )); then
  quality_log_suffix=" (default)"
fi

if [[ "$effective_format" == "mov" && "$deinterlace_mode" != "off" ]]; then
  info "[INFO] Deinterlace ignored for MOV (DV passthrough)"
  append_run_note "Deinterlace ignored for MOV (DV passthrough)"
  deinterlace_mode="off"
fi

append_run_note "Output mode: $output_mode"
if [[ "$effective_format" == "mov" ]]; then
  append_run_note "Effective burn mode: $burn_mode (subtitle mode: $subtitle_mode), container: $effective_format, deinterlace: $deinterlace_mode"
  info "[config] output_mode=$output_mode, burn_mode=$burn_mode, subtitle_mode=$subtitle_mode, deinterlace=$deinterlace_mode, container=$effective_format (requested: $requested_format)"
else
  append_run_note "Effective burn mode: $burn_mode (subtitle mode: $subtitle_mode), container: $effective_format, quality: $effective_encode_quality, deinterlace: $deinterlace_mode"
  info "[config] output_mode=$output_mode, burn_mode=$burn_mode, subtitle_mode=$subtitle_mode, deinterlace=$deinterlace_mode, container=$effective_format (requested: $requested_format), quality=$effective_encode_quality${quality_log_suffix} (requested: $requested_encode_quality)"
fi
initial_run_notes=("${run_notes[@]}")

# Scratch directory setup (optional)
if [[ -z "$scratch_dir" && -n "${DVMETA_SCRATCH_DIR:-}" ]]; then
  scratch_dir="$DVMETA_SCRATCH_DIR"
fi

if [[ -n "$scratch_dir" ]]; then
  scratch_dir="${scratch_dir%/}"

  if ! mkdir -p "$scratch_dir"; then
    fatal "Unable to create scratch directory: $scratch_dir"
  fi

  if [[ ! -w "$scratch_dir" ]]; then
    fatal "Scratch directory is not writable: $scratch_dir"
  fi

  run_scratch_root="${scratch_dir}/DVMetaDataBurnIn/$(date '+%Y%m%d_%H%M%S')_${RANDOM}${RANDOM}"
  scratch_tmp="${run_scratch_root%/}/tmp"

  if ! mkdir -p "$scratch_tmp"; then
    fatal "Unable to create scratch temp directory: $scratch_tmp"
  fi

  artifact_root="${run_scratch_root%/}/artifacts"
  if ! mkdir -p "$artifact_root"; then
    fatal "Unable to create artifact root: $artifact_root"
  fi

  TMPDIR="$scratch_tmp"
  TMPPREFIX="${TMPDIR}/zsh-"
  export TMPDIR TMPPREFIX

  info "[scratch] Using scratch root: $run_scratch_root"
  append_run_note "Scratch root: $run_scratch_root"
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
typeset -g requested_format
typeset -g requested_encode_quality
typeset -g effective_format
typeset -g effective_encode_quality
typeset -g effective_quality_kind
typeset -g resolved_audio_bitrate
typeset -g resolved_quality_kind
typeset -g resolved_quality_label
typeset -g resolved_video_codec
typeset -g resolved_audio_codec
typeset -g format_coerced=0
typeset -g format_coercion_reason=""
typeset -g cleanup_stage_done=0

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

########################################################
# Helper: detect FPS using ffmpeg probe output
########################################################

detect_fps() {
  local src="$1"
  local fps

  last_detected_fps=""

  local probe_output
  prepare_subprocess_env
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

      if (idx ~ /^[0-9]+$/ &&
          date ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/ &&
          time ~ /^[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?$/) {
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
    function escape_single_quotes(text, repl) {
      repl = sprintf("%c\\%c%c", 39, 39, 39)
      gsub(/\047/, repl, text)
      return text
    }
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

      # Escape single quotes for drawtext
      date = escape_single_quotes(date)
      time = escape_single_quotes(time)

      # Time has colons → escape for drawtext
      gsub(/:/, "\\\\:", time)

      # Dates are YYYY-MM-DD, no spaces/colons, so they’re fine now.

      # Two commands at same timestamp:
      #   dvdate → date
      #   dvtime → time
      printf("%.6f drawtext@dvdate reinit text='\''%s'\''\n", t_sec, date)
      printf("%.6f drawtext@dvtime reinit text='\''%s'\''\n", t_sec, time)
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
      (( ++count ))
    done <"$path"

    if (( $("$wc_cmd" -l <"$path") > max_lines )); then
      debug_log "  ... (truncated after $max_lines lines)"
    fi
  else
    debug_log "$label missing or empty (path: $path)"
  fi
}

prepare_subprocess_env() {
  [[ -n "${TMPDIR:-}" ]] && mkdir -p "$TMPDIR" || true
  export TMPDIR TMPPREFIX
}

ensure_cleanup_stage() {
  if (( cleanup_stage_done == 0 )); then
    log_stage_marker "cleanup"
    append_run_note "Cleanup stage executed prior to final mux/manifest"
    cleanup_stage_done=1
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

  local notes_json=""
  if (( ${#run_notes[@]} > 0 )); then
    local idx=1 total=${#run_notes[@]} note escaped
    for note in "${run_notes[@]}"; do
      escaped=$(json_escape "$note")
      notes_json+="    \"${escaped}\""
      (( idx < total )) && notes_json+="," 
      notes_json+=$'\n'
      (( ++idx ))
    done
  fi

  notes_json="${notes_json%$'\n'}"

  cat > "$manifest_path" <<EOF
{
  "status": "$status_label",
  "input": "$input_path",
  "input_original": "$primary_input_path",
  "artifact_dir": "$artifact_dir",
  "output_mode": "$output_mode",
  "burn_mode": "$burn_mode",
  "subtitle_mode": "$subtitle_mode",
  "layout": "$layout",
  "format": "$effective_format",
  "encode_quality": "$effective_encode_quality",
  "cleanup_stage_completed": $([[ $cleanup_stage_done -eq 1 ]] && echo true || echo false),
  "decisions": {
    "requested_format": "$requested_format",
    "requested_output_mode": "$output_mode",
    "effective_format": "$effective_format",
    "format_coerced": $([[ $format_coerced -eq 1 ]] && echo true || echo false),
    "coercion_reason": "$format_coercion_reason",
    "requested_encode_quality": "$requested_encode_quality",
    "effective_encode_quality": "$effective_encode_quality",
    "burn_mode": "$burn_mode",
    "subtitle_mode": "$subtitle_mode"
  },
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
  },
  "run_notes": [
${notes_json}
  ]
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

  ensure_cleanup_stage

  if (( suppress_finish_run == 1 )); then
    debug_log "finish_run suppressed (exit=$exit_code, status=$status_label)"
    return "$exit_code"
  fi

  write_versions_file "$versions_file"
  write_run_manifest "$manifest_path" "$status_label" "$input_path" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_path" "$cmd_path" "$ass_path" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file"

  if [[ "$status_label" == "success" ]]; then
    emit_debug_snapshots "$timeline_path" "$cmd_path"
  fi

  local final_output
  final_output="${burn_output:-${subtitle_output:-${passthrough_output:-}}}"
  if [[ -n "$final_output" ]]; then
    info "[output] Final output path: $final_output"
    debug_log "Final output path: $final_output"
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
debug_log "Encode quality (requested/effective): $requested_encode_quality/$effective_encode_quality"
debug_log "Burn mode: $burn_mode"
if [[ "$burn_mode" == "subtitleTrack" ]]; then
  debug_log "Subtitle mode: $subtitle_mode"
fi
debug_log "Stitch enabled: $stitch_enabled"
debug_log "Stitch batch enabled: $stitch_batch"
if [[ -n "$stitch_input_list" ]]; then
  debug_log "Stitch input list: $stitch_input_list"
fi
debug_log "Missing meta handling: $missing_meta"
debug_log "Requested font name: ${subtitle_font_name:-<auto>}"
debug_log "ffmpeg path: $ffmpeg_bin"
debug_log "dvrescue path: $dvrescue_bin"
dest_dir="${dest_dir%/}"
if [[ -n "$dest_dir" ]]; then
  debug_log "Requested destination override: $dest_dir"
else
  debug_log "Requested destination override: (default: input folder)"
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

  reply=("${deduped[@]}")
  return 0
}

stitch_sources() {
  local primary="$1"
  local artifact_dir="$2"

  typeset -a input_paths
  if ! build_stitch_input_list "$primary"; then
    reply=("$primary" "")
    return 0
  fi
  input_paths=("${reply[@]}")

  if (( ${#input_paths[@]} <= 1 )); then
    reply=("$primary" "")
    return 0
  fi

  typeset -a stitch_rows
  local clip tmp_log tmp_xml norm_log start_ts

  log_stage_marker "normalize"
  local norm_success=0
  for clip in "${input_paths[@]}"; do
    tmp_log=$(make_temp_file dvmeta_stitch .log) || return 1
    tmp_xml=$(make_temp_file dvmeta_stitch .xml) || return 1

    prepare_subprocess_env
    "$dvrescue_bin" "$clip" --xml-output "$tmp_xml" >"$tmp_log" 2>&1 || true

    norm_log=$(make_temp_file dvmeta_stitch_norm .log) || return 1
    if ! normalize_log_value_only "$tmp_log" "$norm_log"; then
      warn "[stitch] Failed to normalize timestamps for $clip"
      continue
    fi

    norm_success=1

    start_ts=$(awk 'NF>=4 {printf "%s %s", $3, $4; exit}' "$norm_log")
    [[ -z "$start_ts" ]] && start_ts="9999-99-99 99:99:99"

    stitch_rows+=("$start_ts|$clip")
  done

  if (( ${#stitch_rows[@]} <= 1 )); then
    info "[stitch] Not enough valid clips after normalization; skipping stitch."
    append_run_note "Stitch step skipped: insufficient valid clips after normalization"
    reply=("$primary" "")
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
    printf "file '%s'\n" "$(escape_for_single_quotes "$clip_path")" >> "$concat_manifest"
  done <<<"$sorted"

  if (( ${#ordered_inputs[@]} <= 1 )); then
    info "[stitch] Not enough ordered clips to stitch; continuing with original."
    append_run_note "Stitch step skipped: ordering produced a single clip"
    reply=("$primary" "")
    return 0
  fi

  stitch_inputs_resolved="$concat_manifest"

  log_stage_marker "stitch"
  local stitched_path
  stitched_path="${artifact_dir%/}/stitched_source.mkv"

  info "[stitch] Concatenating ${#ordered_inputs[@]} clips into $stitched_path"
  prepare_subprocess_env
  if ! "$ffmpeg_bin" -y -f concat -safe 0 -i "$concat_manifest" -c copy "$stitched_path"; then
    warn "[stitch] ffmpeg concat failed; using primary source"
    append_run_note "Stitch step failed during concat; reverted to primary source"
    reply=("$primary" "")
    return 0
  fi

  stitched_source="$stitched_path"
  reply=("$stitched_path" "$concat_manifest")
  return 0
}

stitch_batch_folder() {
  local artifact_dir="$1"
  shift

  local -a inputs=("$@")

  local target_ext stitched_suffix part_suffix
  if [[ "$output_mode" == "audio" ]]; then
    target_ext="$(audio_extension_for_format "$format")"
    stitched_suffix="_stitched_audio.${target_ext}"
    part_suffix="_audio.${target_ext}"
  else
    target_ext="$format"
    stitched_suffix="_stitched_dateburn.${target_ext}"
    part_suffix="_dateburn.${format}"
  fi

  if (( ${#inputs[@]} == 0 )); then
    warn "[stitch] No inputs provided for batch stitching"
    reply=("")
    return 1
  fi

  local list_file
  list_file="${artifact_dir%/}/list.txt"

  : > "$list_file"

  local clip
  for clip in "${inputs[@]}"; do
    printf "file '%s'\n" "$(escape_for_single_quotes "$clip")" >>"$list_file"
  done

  if [[ "$output_mode" == "audio" ]]; then
    local part_duration
    for clip in "${inputs[@]}"; do
      if part_duration=$(probe_media_duration "$clip"); then
        info "[stitch] part ${clip:t}: $part_duration"
        append_run_note "Stitch part ${clip:t} duration: $part_duration"
      fi
    done
  fi

  log_stage_marker "stitch"

  local stitched_path
  stitched_path="${artifact_dir%/}/stitched.${target_ext}"

  info "[stitch] Concatenating ${#inputs[@]} clips into $stitched_path (stream copy)"
  prepare_subprocess_env
  local -a stitch_copy_cmd=(
    "$ffmpeg_bin" -y -f concat -safe 0 -i "$list_file" -c copy
    "${sanitized_extra_args[@]}"
    "$stitched_path"
  )
  log_ffmpeg_command "stitch-copy" "${stitch_copy_cmd[@]}"
  if "${stitch_copy_cmd[@]}"; then
    stitched_source="$stitched_path"
    stitch_inputs_resolved="$list_file"
    if final_duration=$(probe_media_duration "$stitched_path"); then
      info "[stitch] stitched duration: $final_duration"
    fi
    reply=("$stitched_path")
    return 0
  fi

  warn "[stitch] Stream copy concat failed; retrying with re-encode fallback"
  prepare_subprocess_env
  local -a stitch_reencode_cmd
  build_codec_args "$format" "$effective_quality_kind"
  stitch_reencode_cmd=(
    "$ffmpeg_bin" -y -f concat -safe 0 -i "$list_file"
    "${reply[@]}"
    "${sanitized_extra_args[@]}"
    "$stitched_path"
  )
  log_ffmpeg_command "stitch-encode" "${stitch_reencode_cmd[@]}"
  if "${stitch_reencode_cmd[@]}"; then
    stitched_source="$stitched_path"
    stitch_inputs_resolved="$list_file"
    if final_duration=$(probe_media_duration "$stitched_path"); then
      info "[stitch] stitched duration: $final_duration"
    fi
    reply=("$stitched_path")
    return 0
  fi

  warn "[stitch] Failed to stitch batch inputs"
  reply=("")
  return 1
}

validate_and_plan_file() {
  local in="$1"
  local base_override="${2:-}"
  local output_dir_override="${3:-}"

  if [[ ! -f "$in" ]]; then
    echo "[ERROR] Input file not found: $in" >&2
    return 1
  fi

  local output_dir base base_name out_ext

  if [[ "$output_mode" == "audio" ]]; then
    out_ext="$(audio_extension_for_format "$format")"
  else
    out_ext="$format"
  fi
  if [[ -n "$base_override" ]]; then
    base_name="$base_override"
  else
    base_name="${in:t:r}"
  fi

  if [[ -n "$output_dir_override" ]]; then
    output_dir="${output_dir_override%/}"
  elif [[ -n "$dest_dir" ]]; then
    output_dir="${dest_dir%/}"
  else
    output_dir="${in:h}"
  fi

  base="${output_dir}/${base_name}"

  reply=("$output_dir" "$base" "$base_name" "$out_ext")
  return 0
}


create_artifact_scaffold() {
  local in="$1"
  local output_dir="$2"
  local base_name="$3"
  local out_ext="$4"
  local artifact_dir_override="${5:-}"
  local artifact_dir dvrescue_xml dvrescue_log cmdfile timeline_debug ass_artifact run_manifest versions_file

  if [[ -n "$dest_dir" && ! -d "$output_dir" ]]; then
    if ! mkdir -p "$output_dir"; then
      echo "[ERROR] Unable to create destination folder: $output_dir" >&2
      return 1
    fi
  fi

  if [[ -n "$artifact_dir_override" ]]; then
    artifact_dir="$artifact_dir_override"
    if [[ ! -d "$artifact_dir" ]] && ! mkdir -p "$artifact_dir"; then
      echo "[ERROR] Unable to create artifact directory override: $artifact_dir" >&2
      return 1
    fi
    echo "[INFO] Artifact directory (override): $artifact_dir" >&2
    debug_log "Artifacts will be stored in override dir $artifact_dir"
  else
    if ! artifact_dir="$(prepare_artifact_dir "$in")"; then
      return 1
    fi
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
  printf '{"status":"pending","input":"%s"}\n' "$in" > "$run_manifest"
  : > "$versions_file"

  log_artifact_path_and_size "dvrescue XML" "$dvrescue_xml"
  log_artifact_path_and_size "dvrescue log" "$dvrescue_log"
  echo "[INFO] sendcmd path: $cmdfile" >&2
  echo "[INFO] ASS output path: $ass_artifact" >&2
  echo "[INFO] timeline debug path: $timeline_debug" >&2

  reply=("$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$cmdfile" "$timeline_debug" "$ass_artifact" "$run_manifest" "$versions_file")

  return 0
}

build_burnin_filtergraph() {
  local layout="$1"
  local cmdfile="$2"
  local font="$3"

  local cmd_escaped font_escaped
  cmd_escaped=$(escape_for_single_quotes "$cmdfile")
  font_escaped=$(escape_for_single_quotes "$font")

  case "$layout" in
    stacked)
      echo "sendcmd=f='${cmd_escaped}',drawtext@dvdate=fontfile='${font_escaped}':text='':fontcolor=white:fontsize=24:box=0:x=w-tw-20:y=h-60,drawtext@dvtime=fontfile='${font_escaped}':text='':fontcolor=white:fontsize=24:box=0:x=w-tw-20:y=h-30"
      ;;
    single)
      echo "sendcmd=f='${cmd_escaped}',drawtext@dvdate=fontfile='${font_escaped}':text='':fontcolor=white:fontsize=24:box=0:x=20:y=h-40,drawtext@dvtime=fontfile='${font_escaped}':text='':fontcolor=white:fontsize=24:box=0:x=w-tw-20:y=h-40"
      ;;
    *)
      return 1
      ;;
  esac

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
  else
    if [[ ! -s "$cmdfile" ]]; then
      echo "[ERROR] sendcmd output is empty for $in" >&2
      timeline_fail=1
    elif ! grep -q "drawtext@dvdate" "$cmdfile"; then
      echo "[ERROR] sendcmd output missing dvdate commands for $in" >&2
      timeline_fail=1
    elif ! grep -q "drawtext@dvtime" "$cmdfile"; then
      echo "[ERROR] sendcmd output missing dvtime commands for $in" >&2
      timeline_fail=1
    elif grep -q ';[[:space:]]*$' "$cmdfile"; then
      echo "[ERROR] sendcmd output contains trailing semicolons for $in" >&2
      timeline_fail=1
    fi
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
    (( ++raw_lines ))

    if [[ -z "$t_sec" || -z "$date_part" || -z "$time_part" ]]; then
      (( ++skipped_lines ))
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
          (( ++dialogue_count ))
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
        (( ++dialogue_count ))
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

resolve_encode_quality() {
  local format="$1"
  local quality_kind="$2"

  resolved_quality_kind="${quality_kind:-medium}"
  resolved_quality_label="$resolved_quality_kind"
  resolved_audio_bitrate=""

  if [[ "$output_mode" == "audio" ]]; then
    resolve_audio_bitrate "$resolved_quality_kind"
    resolved_quality_label="$resolved_quality_kind"
    return
  fi

  case "$format" in
    mov)
      resolved_quality_kind="passthrough"
      resolved_quality_label="passthrough"
      ;;
    mp4|mkv)
      case "$resolved_quality_kind" in
        low|medium|high)
          ;;
        *)
          resolved_quality_kind="medium"
          resolved_quality_label="medium"
          ;;
      esac
      ;;
  esac
}

build_codec_args() {
  local format="$1"
  local quality="$2"
  local -a args
  local quality_kind="$quality"

  resolved_video_codec=""
  resolved_audio_codec=""

  resolve_encode_quality "$format" "$quality_kind"

  if [[ "$output_mode" == "audio" ]]; then
    local bitrate
    bitrate=${resolved_audio_bitrate:-192}
    args=(-vn -c:a aac -b:a "${bitrate}k")
    resolved_video_codec="(none)"
    resolved_audio_codec="aac"
    info "[codec] Resolved audio bitrate: ${bitrate}k (quality=${resolved_quality_label}) | container=${format} | codecs: v=${resolved_video_codec} a=${resolved_audio_codec} | codec args: ${args[*]}"
    reply=("${args[@]}")
    return
  fi

  case "$format" in
    mov)
      args=(-c:v dvvideo -c:a pcm_s16le)
      resolved_video_codec="dvvideo"
      resolved_audio_codec="pcm_s16le"
      ;;
    *)
      quality_to_video_args "$resolved_quality_kind"
      args=("${reply[@]}" -c:a aac -b:a 192k)
      resolved_video_codec="libx264 (${resolved_quality_kind})"
      resolved_audio_codec="aac"
      ;;
  esac

  info "[codec] Resolved encode quality: $resolved_quality_label | container=${format} | codecs: v=${resolved_video_codec} a=${resolved_audio_codec} | codec args: ${args[*]}"
  reply=("${args[@]}")
}

log_container_resolution() {
  local subtitle_label

  case "$burn_mode" in
    subtitleTrack)
      subtitle_label="embedded subtitle track"
      ;;
    burnin)
      subtitle_label="burn-in filtergraph"
      ;;
    *)
      subtitle_label="disabled"
      ;;
  esac

  info "[mux] Container: ${effective_format} | Video: ${resolved_video_codec:-unknown} | Audio: ${resolved_audio_codec:-unknown} | Subtitles: ${subtitle_label}"
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

  last_burn_output_path=""
  last_subtitle_output_path=""
  last_passthrough_output_path=""

  local source_video="$in"
  local stitch_manifest=""
  local ass_target="$ass_artifact"

  stitch_inputs_resolved=""
  stitched_source=""

  last_parse_raw_rows=0
  last_parse_valid_rows=0
  last_parse_skipped_rows=0
  last_parse_timeline_entries=0
  last_parse_frame_source="unknown"
  last_dvrescue_status=0
  timestamps_normalized=0
  cleanup_stage_done=0
  run_notes=("${initial_run_notes[@]}")

  local -a codec_args
  build_codec_args "$format" "$effective_quality_kind"
  codec_args=("${reply[@]}")

  container_flag_for_format "$format"
  local -a container_args
  container_args=("${reply[@]}")

  log_container_resolution

  if (( ${#codec_args[@]} == 0 )); then
    warn "Unknown format for codec args: $format"
    manifest_status="error"
    finish_run 1 "$manifest_status" "$source_video" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_target" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
    return 1
  fi
  
 # --- Stitching (optional) ---
  if (( stitch_enabled == 1 )) && [[ "$mode" != "batch" ]]; then
    if ! stitch_sources "$in" "$artifact_dir"; then
      warn "[stitch] Stitching failed; continuing with original clip"
      source_video="$in"
      stitch_inputs_resolved=""
      stitched_source=""
      stitch_manifest=""
    else
      source_video="$reply[1]"
      stitch_manifest="$reply[2]"
    fi

    if [[ -z "$source_video" || "$source_video" == "$in" ]]; then
      info "[stitch] No stitched output produced (single clip or no valid list); using primary source"
      source_video="$in"
      stitch_manifest=""
      stitch_inputs_resolved=""
      stitched_source=""
      append_run_note "Stitch enabled but produced no stitched output; proceeded with primary source"
    else
      info "[stitch] Using stitched source for downstream processing: $source_video"
    fi
  fi

  if [[ "$output_mode" == "audio" ]]; then
    ensure_cleanup_stage
    local audio_ext out_audio
    audio_ext="$(audio_extension_for_format "$format")"
    out_audio="${base}_audio.${audio_ext}"

    local -a audio_cmd=(
      "$ffmpeg_bin" -y -i "$source_video"
      "${codec_args[@]}"
      "${container_args[@]}"
      "${sanitized_extra_args[@]}"
      "$out_audio"
    )

    log_export "$source_video" "$out_audio"
    prepare_subprocess_env
    log_ffmpeg_command "audio-only" "${audio_cmd[@]}"
    if ! run_stage "audio-extract" "${audio_cmd[@]}"; then
      exit_status=$?
      manifest_status="error"
      passthrough_output="$out_audio"
      last_passthrough_output_path="$passthrough_output"
      last_burn_output_path="$out_audio"
      finish_run "$exit_status" "$manifest_status" "$source_video" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debu
g" "$cmdfile" "$ass_target" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
      die "ffmpeg encode failed for: $source_video"
    fi

    exit_status=$?
    manifest_status=$([[ $exit_status -eq 0 ]] && echo "success" || echo "error")
    passthrough_output="$out_audio"
    last_passthrough_output_path="$passthrough_output"
    last_burn_output_path="$out_audio"
    finish_run "$exit_status" "$manifest_status" "$source_video" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_target" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
    return $exit_status
  fi

  local fps

  if ! fps="$(detect_fps "$source_video")"; then
    finish_run 1 "error" "$source_video" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_target" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
    return 1
  fi
  last_detected_fps="$fps"
  debug_log "Detected FPS: $fps"

  local dv_status=0
  debug_log "Extracting dvrescue XML -> $dvrescue_xml (log: $dvrescue_log)"
  prepare_subprocess_env
  "$dvrescue_bin" "$source_video" --xml-output "$dvrescue_xml" >"$dvrescue_log" 2>&1
  dv_status=$?
  last_dvrescue_status=$dv_status
  log_artifact_path_and_size "dvrescue XML" "$dvrescue_xml"
  log_artifact_path_and_size "dvrescue log" "$dvrescue_log"

  local deinterlace_vf=""
  local -a deinterlace_fps_args=()
  if [[ "$out_ext" == "mp4" || "$out_ext" == "mkv" ]]; then
    if [[ "$deinterlace_mode" != "off" ]]; then
      deinterlace_vf="$(deinterlace_vf_for_mode "$deinterlace_mode")"
      deinterlace_output_fps_args_for_mode "$deinterlace_mode"
      deinterlace_fps_args=("${reply[@]}")
    fi
  fi

  if [[ "$burn_mode" != "off" ]]; then
    normalize_dvrescue_timestamps "$dvrescue_log" "${artifact_dir}/dvrescue.normalized.log" || \
      warn "Proceeding with unnormalized timestamps due to prior error"
  fi

  # Transcode-only mode: no metadata
  if [[ "$burn_mode" == "off" ]]; then
    local out_passthrough="${base}_conv.${out_ext}"
    echo "[INFO] Transcode-only conversion (no burn-in) to: $out_passthrough"
    debug_log "Running transcode-only encode with args: ${codec_args[*]}"
    ensure_cleanup_stage
    local -a transcode_cmd=("$ffmpeg_bin" -y -i "$source_video")
    if [[ -n "$deinterlace_vf" ]]; then
      transcode_cmd+=(-vf "$deinterlace_vf")
    fi
    transcode_cmd+=(
      "${codec_args[@]}"
      "${deinterlace_fps_args[@]}"
      "${container_args[@]}"
      "${sanitized_extra_args[@]}"
      "$out_passthrough"
    )
    log_export "$source_video" "$out_passthrough"
    prepare_subprocess_env
    log_ffmpeg_command "transcode-only" "${transcode_cmd[@]}"
    if ! run_stage "encode" "${transcode_cmd[@]}"; then
      exit_status=$?
      manifest_status="error"
      passthrough_output="$out_passthrough"
      last_passthrough_output_path="$passthrough_output"
      finish_run "$exit_status" "$manifest_status" "$source_video" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_target" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
      die "ffmpeg encode failed for: $source_video"
    fi

    exit_status=$?
    manifest_status=$([[ $exit_status -eq 0 ]] && echo "success" || echo "error")
    passthrough_output="$out_passthrough"
    last_passthrough_output_path="$passthrough_output"
    finish_run "$exit_status" "$manifest_status" "$source_video" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_target" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
    return $exit_status
  fi

  local font
  if ! font="$(find_font)"; then
    echo "[ERROR] Unable to locate a usable font. Provide --fontfile, set DVMETABURN_FONTFILE, or place a supported font in Resources/fonts/." >&2
    manifest_status="error"
    finish_run 1 "$manifest_status" "$source_video" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_target" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
    return 1
  fi

 debug_log "Using font file: $font"

# Default if UI didn't pass a name
if [[ -z "$subtitle_font_name" ]]; then
  subtitle_font_name="UAV OSD Mono"
fi

# Normalize to ASS/libass font family matching
subtitle_font_name="${subtitle_font_name//-/ }"   # UAV-OSD-Mono -> UAV OSD Mono
subtitle_font_name="${subtitle_font_name//,/ }"   # commas to spaces (defensive)

debug_log "ASS font family resolved to: '$subtitle_font_name'"

  # Subtitle track mode: generate ASS from timeline and mux into container
  if [[ "$burn_mode" == "subtitleTrack" ]]; then
    if [[ "$out_ext" != "mkv" ]]; then
      echo "[ERROR] Subtitle track muxing is only supported for MKV output (got '$out_ext')." >&2
      manifest_status="error"
      finish_run 1 "$manifest_status" "$source_video" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_target" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
      return 1
    fi

    local sub_status=0

    local per_clip_ass_path="$ass_target"
    local subtitle_ass_path="$ass_target"
    if (( stitch_enabled == 1 )); then
    
      if [[ "$subtitle_mode" == "continuous" ]]; then
        subtitle_ass_path="${artifact_dir%/}/timestamps.stitched.ass"
        ass_target="$subtitle_ass_path"
        info "[subtitle] Continuous mode enabled; regenerating ASS from stitched normalized timeline: $subtitle_ass_path"
      else
        info "[subtitle] Per-clip subtitle mode selected; retaining ASS at $subtitle_ass_path"
      fi
    fi

    # Build ASS subtitles from the dvrescue timeline
    if ! make_ass_subs "$source_video" "$layout" "$ass_target" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$fps"; then
      sub_status=$?
    fi

    if (( stitch_enabled == 1 )) && [[ "$subtitle_mode" == "continuous" && "$ass_target" != "$per_clip_ass_path" ]]; then
      if [[ -e "$per_clip_ass_path" ]]; then
        info "[subtitle] Removing per-clip ASS artifact after stitched regeneration: $per_clip_ass_path"
        rm -f "$per_clip_ass_path"
        append_run_note "Removed per-clip ASS artifact after continuous-mode regeneration"
      else
        debug_log "Per-clip ASS artifact already absent: $per_clip_ass_path"
      fi
    fi

    # Handle missing / bad metadata according to --missing-meta
    if (( sub_status != 0 )); then
      echo "[WARN] Failed to build subtitles; honoring --missing-meta=$missing_meta (status=$sub_status)" >&2
      case "$missing_meta" in
        skip_burnin_convert)
          echo "[WARN] Missing timestamp metadata for $source_video; converting without subtitle track." >&2
          local out_passthrough="${base}_conv.${out_ext}"
          echo "[INFO] Missing metadata fallback: writing transcode-only output to $out_passthrough (stitch-batch will use *_conv.* parts)." >&2
          ensure_cleanup_stage
          local -a subtitle_fallback_cmd=("$ffmpeg_bin" -y -i "$source_video")
          if [[ -n "$deinterlace_vf" ]]; then
            subtitle_fallback_cmd+=(-vf "$deinterlace_vf")
          fi
          subtitle_fallback_cmd+=(
            "${codec_args[@]}"
            "${deinterlace_fps_args[@]}"
            "${container_args[@]}"
            "${sanitized_extra_args[@]}"
            "$out_passthrough"
          )
          log_export "$source_video" "$out_passthrough"
          prepare_subprocess_env
          log_ffmpeg_command "subtitle-fallback" "${subtitle_fallback_cmd[@]}"
          if ! run_stage "encode" "${subtitle_fallback_cmd[@]}"; then
            exit_status=$?
            manifest_status="error"
            passthrough_output="$out_passthrough"
            last_passthrough_output_path="$passthrough_output"
            finish_run "$exit_status" "$manifest_status" "$source_video" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_target" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
            die "ffmpeg encode failed for: $source_video"
          fi

          exit_status=$?
          manifest_status=$([[ $exit_status -eq 0 ]] && echo "success" || echo "error")
          passthrough_output="$out_passthrough"
          last_passthrough_output_path="$passthrough_output"
          finish_run "$exit_status" "$manifest_status" "$source_video" "$artifact_dir" \
            "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_target" \
            "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
          return $exit_status
          ;;
        skip_file)
          echo "[WARN] Missing timestamp metadata for $source_video; skipping file." >&2
          manifest_status="skipped"
          finish_run 0 "$manifest_status" "$source_video" "$artifact_dir" \
            "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_target" \
            "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
          return 0
          ;;
        error|*)
          echo "[ERROR] Missing timestamp metadata and --missing-meta=error; aborting subtitle mode." >&2
          manifest_status="error"
          finish_run 1 "$manifest_status" "$source_video" "$artifact_dir" \
            "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_target" \
            "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
          return 1
          ;;
      esac
    fi

    ensure_cleanup_stage

    # We have a valid ASS file – mux it as MKV with true ASS subtitles
    local out_subbed="${base}_dvsub.mkv"
    local -a sub_video_args=("${codec_args[@]}")
    local subtitle_codec="ass"

    echo "[INFO] Muxing subtitle track into: $out_subbed" >&2
    local font_attach="$font"
    local font_filename="${font_attach:t}"

   local -a mux_cmd=(
  "$ffmpeg_bin" -y
  -i "$source_video"
  -f ass -i "$ass_target"

  -attach "$font_attach"
  -metadata:s:t:0 mimetype=application/x-truetype-font
  -metadata:s:t:0 filename="$font_filename"

  -map 0:v:0 -map "0:a?" -map 1:0
)
    if [[ -n "$deinterlace_vf" ]]; then
      mux_cmd+=(-vf "$deinterlace_vf")
    fi
    mux_cmd+=(
      "${sub_video_args[@]}"
      "${deinterlace_fps_args[@]}"
      -c:s "$subtitle_codec"
      -disposition:s:0 default
      "${container_args[@]}"
      "${sanitized_extra_args[@]}"
      "$out_subbed"
    )

    log_export "$source_video" "$out_subbed"
    prepare_subprocess_env
    log_ffmpeg_command "subtitle-mux" "${mux_cmd[@]}"
    if ! run_stage "encode" "${mux_cmd[@]}"; then
      exit_status=$?
      manifest_status="error"
      finish_run "$exit_status" "$manifest_status" "$source_video" "$artifact_dir" \
        "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_target" \
        "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
      die "ffmpeg encode failed for: $source_video"
    fi

    exit_status=$?
    manifest_status=$([[ $exit_status -eq 0 ]] && echo "success" || echo "error")
    subtitle_output="$out_subbed"
    last_subtitle_output_path="$subtitle_output"
    finish_run "$exit_status" "$manifest_status" "$source_video" "$artifact_dir" \
      "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_target" \
      "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
    return $exit_status
  fi

  local timeline_fail=0
  if ! run_stage "timeline" make_timestamp_cmd "$source_video" "$cmdfile" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$fps"; then
    timeline_fail=1
  fi

  if (( timeline_fail != 0 )); then
    echo "[WARN] Failed to build timestamp timeline from log; honoring --missing-meta=$missing_meta" >&2
    case "$missing_meta" in
      error)
        finish_run 1 "error" "$source_video" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_target" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
        die "timeline generation failed for: $source_video (see artifacts: $artifact_dir)"
        ;;
      skip_burnin_convert)
        echo "[WARN] Converting without burn-in due to missing timestamp metadata." >&2
        local out_passthrough="${base}_conv.${out_ext}"
        echo "[INFO] Missing metadata fallback: writing transcode-only output to $out_passthrough (stitch-batch will use *_conv.* parts)." >&2
        ensure_cleanup_stage
        local -a timeline_fallback_cmd=("$ffmpeg_bin" -y -i "$source_video")
        if [[ -n "$deinterlace_vf" ]]; then
          timeline_fallback_cmd+=(-vf "$deinterlace_vf")
        fi
        timeline_fallback_cmd+=(
          "${codec_args[@]}"
          "${deinterlace_fps_args[@]}"
          "${container_args[@]}"
          "${sanitized_extra_args[@]}"
          "$out_passthrough"
        )
        log_export "$source_video" "$out_passthrough"
        prepare_subprocess_env
        log_ffmpeg_command "timeline-fallback" "${timeline_fallback_cmd[@]}"
        if ! run_stage "encode" "${timeline_fallback_cmd[@]}"; then
          exit_status=$?
          manifest_status="error"
          passthrough_output="$out_passthrough"
          last_passthrough_output_path="$passthrough_output"
          finish_run "$exit_status" "$manifest_status" "$source_video" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_target" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
          die "ffmpeg encode failed for: $source_video"
        fi
        exit_status=$?
        manifest_status=$([[ $exit_status -eq 0 ]] && echo "success" || echo "error")
        passthrough_output="$out_passthrough"
        last_passthrough_output_path="$passthrough_output"
        finish_run "$exit_status" "$manifest_status" "$source_video" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_target" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
        return $exit_status
        ;;
      skip_file)
        echo "[WARN] Skipping $source_video due to missing timestamp metadata." >&2
        manifest_status="skipped"
        finish_run 0 "$manifest_status" "$source_video" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_target" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
        return 0
        ;;
    esac
  fi

  ensure_cleanup_stage

  local vf
  if ! vf=$(build_burnin_filtergraph "$layout" "$cmdfile" "$font"); then
    echo "Unknown layout: $layout" >&2
    finish_run 1 "error" "$source_video" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_target" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
    return 1
  fi

  if [[ "$format" == "mkv" && "$burn_mode" == "burnin" ]]; then
    if [[ "$vf" == *"sendcmd"* && "$vf" == *"drawtext"* ]]; then
      info "[burn] MKV burn-in filtergraph contains sendcmd and drawtext"
    else
      warn "[burn] MKV burn-in filtergraph missing sendcmd/drawtext markers"
    fi
  fi


  local out="${base}_dateburn.${out_ext}"
  local burn_vf="$vf"
  if [[ -n "$deinterlace_vf" ]]; then
    burn_vf="${deinterlace_vf},${vf}"
  fi

  echo "[INFO] Burning DV metadata into: $out"
  debug_log "ffmpeg burn-in filtergraph: $burn_vf"
  debug_log "ffmpeg burn-in args: ${codec_args[*]}"
  local -a burn_cmd=(
    "$ffmpeg_bin" -y -i "$source_video"
    -vf "$burn_vf"
    "${codec_args[@]}"
    "${deinterlace_fps_args[@]}"
    "${container_args[@]}"
    "${sanitized_extra_args[@]}"
    "$out"
  )
  log_export "$source_video" "$out"
  prepare_subprocess_env
  log_ffmpeg_command "burn-in" "${burn_cmd[@]}"
  if ! run_stage "encode" "${burn_cmd[@]}"; then
    exit_status=$?
    manifest_status="error"
    burn_output="$out"
    last_burn_output_path="$burn_output"
    finish_run "$exit_status" "$manifest_status" "$source_video" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_target" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
    die "ffmpeg encode failed for: $source_video"
  fi

  exit_status=$?
  manifest_status=$([[ $exit_status -eq 0 ]] && echo "success" || echo "error")
  burn_output="$out"
  last_burn_output_path="$burn_output"
  echo "ffmpeg exit code: $exit_status"
  finish_run "$exit_status" "$manifest_status" "$source_video" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_target" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
  return $exit_status
}

process_file_controller() {
  local in="$1"
  local base_override="${2:-}"
  local output_dir_override="${3:-}"
  local artifact_dir_override="${4:-}"
  debug_log "process_file_controller() received: '$in'"

  primary_input_path="$in"

  local expected_base_name
  expected_base_name="${base_override:-${in:t:r}}"

  log_stage_marker "validation"
  local output_dir base base_name out_ext
  if ! validate_and_plan_file "$in" "$base_override" "$output_dir_override"; then
    return 1
  fi
  output_dir="$reply[1]"
  base="$reply[2]"
  base_name="$reply[3]"
  out_ext="$reply[4]"

  local requested_destination resolved_destination
  if [[ -n "$dest_dir" ]]; then
    requested_destination="$dest_dir"
  else
    requested_destination="<input folder>"
  fi
  resolved_destination="$output_dir"

  info "[pathing] Requested destination: $requested_destination"
  info "[pathing] Resolved destination: $resolved_destination"
  debug_log "[pathing] Scratch root: ${run_scratch_root:-<default>}"

  if [[ "$base_name" != "$expected_base_name" ]]; then
    fatal "Base filename changed unexpectedly (expected '$expected_base_name', got '$base_name')"
  fi

  log_stage_marker "artifact_stubs"
  local artifact_dir dvrescue_xml dvrescue_log cmdfile timeline_debug ass_artifact run_manifest versions_file
  if ! create_artifact_scaffold "$in" "$output_dir" "$base_name" "$out_ext" "$artifact_dir_override"; then
    return 1
  fi
  artifact_dir="$reply[1]"
  dvrescue_xml="$reply[2]"
  dvrescue_log="$reply[3]"
  cmdfile="$reply[4]"
  timeline_debug="$reply[5]"
  ass_artifact="$reply[6]"
  run_manifest="$reply[7]"
  versions_file="$reply[8]"

  if [[ "${artifact_dir:t}" != ${expected_base_name}_* ]]; then
    fatal "Artifact directory base changed unexpectedly (expected prefix '${expected_base_name}_', got '${artifact_dir:t}')"
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
  stitch_batch=0
  if [[ $# -ne 1 ]]; then
    echo "Usage: $0 [--mode=single] [--layout=stacked|single] [--format=mov|mp4|mkv] [--quality=low|medium|high] [--burn-mode=burnin|off|subtitleTrack] [--subtitle-mode=per-clip|continuous] [--deinterlace=off|30p|60p (default: off)] [--scratch-dir=/path (or DVMETA_SCRATCH_DIR)] [--output-base=name] [--stitch [--stitch-inputs=/path/to/list.txt]] /path/to/clip.avi" >&2
    exit 1
  fi
  debug_log "Running in single-file mode with target: $1"
  single_base_override=""
  if [[ -n "$output_base" ]]; then
    single_base_override="$output_base"
  fi

  process_file_controller "$1" "$single_base_override"
  exit $?
fi

if [[ "$mode" == "batch" ]]; then
  if [[ $# -ne 1 ]]; then
    echo "Usage: $0 --mode=batch [--layout=stacked|single] [--format=mov|mp4|mkv] [--quality=low|medium|high] [--burn-mode=burnin|off|subtitleTrack] [--subtitle-mode=per-clip|continuous] [--deinterlace=off|30p|60p (default: off)] [--scratch-dir=/path (or DVMETA_SCRATCH_DIR)] [--output-base=name] [--stitch [--stitch-inputs=/path/to/list.txt]] /path/to/folder" >&2
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

  batch_output_root="$folder_abs"
  if [[ -n "$dest_dir" ]]; then
    batch_output_root="${dest_dir%/}"
  fi

  echo "Batch mode: scanning $folder_abs"
  debug_log "Scanning batch folder with zsh globs (**/*.(avi|AVI|dv|DV))"

  # Use zsh’s recursive globbing; only existing regular files (.N)
  setopt localoptions null_glob extended_glob

  local -a batch_files
  batch_files=("$folder_abs"/**/*.(avi|AVI|dv|DV)(N))
  batch_files=( ${(on)batch_files} )

  if (( ${#batch_files[@]} == 0 )); then
    echo "[WARN] No DV files found in: $folder_abs"
    exit 0
  fi

  if (( stitch_batch == 1 )); then
    primary_input_path="$folder_abs"
    base_name=""
    output_dir_override=""
    ts=""
    artifact_dir_override=""
    burned_parts_dir=""
    list_file=""
    stitched_output=""
    if [[ -n "$output_base" ]]; then
      base_name="$output_base"
    else
      base_name="${folder_abs:t}"
    fi

    local target_ext stitched_suffix part_suffix conv_suffix
    if [[ "$burn_mode" == "subtitleTrack" ]]; then
      target_ext="mkv"
      stitched_suffix="_dvsub_stitched.mkv"
      part_suffix="_dvsub.mkv"
    elif [[ "$output_mode" == "audio" ]]; then
      target_ext="$(audio_extension_for_format "$format")"
      stitched_suffix="_stitched_audio.${target_ext}"
      part_suffix="_audio.${target_ext}"
    else
      target_ext="$format"
      stitched_suffix="_stitched_dateburn.${target_ext}"
      part_suffix="_dateburn.${format}"
      conv_suffix="_conv.${format}"
    fi

    output_dir_override="$batch_output_root"

    ts="$(date '+%Y%m%d_%H%M%S')"
    artifact_dir_override="${artifact_root%/}/${base_name}_stitched_${ts}"
    burned_parts_dir="${artifact_dir_override%/}/burned_parts"

    if ! mkdir -p "$burned_parts_dir"; then
      echo "[ERROR] Unable to create artifact directory for stitching: $artifact_dir_override" >&2
      exit 1
    fi

    suppress_finish_run=1
    typeset -a stitch_inputs=()
    typeset -a part_ids=()
    local idx=1
    local abs part_base part_artifact_dir
    local had_part_failure=0

    for abs in "${batch_files[@]}"; do
      part_base=$(printf "%04d" "$idx")
      part_artifact_dir="${burned_parts_dir%/}/${part_base}_artifacts"
      debug_log "[stitch/batch] Burning part $part_base from $abs (artifacts -> $part_artifact_dir)"

      last_stage_marker=""
      if ! process_file_controller "$abs" "$part_base" "$burned_parts_dir" "$part_artifact_dir"; then
        had_part_failure=1
        local stage_suffix=""
        if [[ -n "$last_stage_marker" ]]; then
          stage_suffix=" (stage: $last_stage_marker)"
        fi
        echo "[ERROR] [stitch/batch] Failed part $part_base: $abs${stage_suffix}" >&2
        break
      fi

      part_ids+=("$part_base")
      (( ++idx ))
    done
    suppress_finish_run=0

    if (( had_part_failure == 1 )); then
      echo "[STITCH] ABORT: at least one part failed; not attempting concat" >&2
      exit 1
    fi

    if [[ ! -d "$burned_parts_dir" ]]; then
      echo "[ERROR] No stitchable parts were produced; aborting stitch." >&2
      exit 1
    fi

    list_file="${burned_parts_dir%/}/list.txt"
    : > "$list_file"
    local stitched_inputs=0
    local burned_count=0
    local conv_count=0
    local missing_count=0

    local part_id burned_path conv_path
    for part_id in "$part_ids[@]"; do
      burned_path="${burned_parts_dir%/}/${part_id}${part_suffix}"
      conv_path=""
      if [[ -n "$conv_suffix" ]]; then
        conv_path="${burned_parts_dir%/}/${part_id}${conv_suffix}"
      fi

      if [[ -f "$burned_path" ]]; then
        info "[stitch] part ${part_id} -> dateburn"
        stitch_inputs+=("$burned_path")
        (( ++burned_count ))
      elif [[ -n "$conv_suffix" && -f "$conv_path" ]]; then
        info "[stitch] part ${part_id} -> conv (fallback)"
        stitch_inputs+=("$conv_path")
        (( ++conv_count ))
      else
        warn "[stitch] part ${part_id} missing (no dateburn/conv output)"
        (( ++missing_count ))
        continue
      fi

      printf "file '%s'\n" "$(escape_for_single_quotes "${stitch_inputs[-1]}")" >> "$list_file"
      (( ++stitched_inputs ))
    done

    if (( stitched_inputs == 0 )); then
      echo "[ERROR] No stitchable parts were produced; aborting stitch. (burned=${burned_count} conv=${conv_count} missing=${missing_count})" >&2
      exit 1
    fi

    if [[ "$output_mode" == "audio" ]]; then
      local part_duration
      for abs in "${stitch_inputs[@]}"; do
        if part_duration=$(probe_media_duration "$abs"); then
          info "[stitch/batch] part ${abs:t}: $part_duration"
          append_run_note "Stitch part ${abs:t} duration: $part_duration"
        fi
      done
    fi

    stitched_output="${output_dir_override%/}/${base_name}${stitched_suffix}"

    container_flag_for_format "$format"
    local -a stitch_container_args
    stitch_container_args=("${reply[@]}")

    info "[stitch/batch] Concatenating ${stitched_inputs} stitchable parts into $stitched_output (stream copy)"
    log_export "$list_file" "$stitched_output"
    prepare_subprocess_env
    local -a stitch_copy_cmd=(
      "$ffmpeg_bin" -y -f concat -safe 0 -i "$list_file" -c copy
      "${sanitized_extra_args[@]}"
      "$stitched_output"
    )
    log_ffmpeg_command "stitch-copy" "${stitch_copy_cmd[@]}"
    if ! "${stitch_copy_cmd[@]}"; then
      warn "[stitch/batch] Stream copy concat failed; retrying with re-encode fallback"

      if [[ "$output_mode" == "audio" ]]; then
        local -a stitch_codec_args
        build_codec_args "$format" "$effective_quality_kind"
        stitch_codec_args=("${reply[@]}")
        log_export "$list_file" "$stitched_output"
        prepare_subprocess_env
        local -a stitch_encode_cmd=(
          "$ffmpeg_bin" -y -f concat -safe 0 -i "$list_file"
          "${stitch_codec_args[@]}"
          "${stitch_container_args[@]}"
          "${sanitized_extra_args[@]}"
          "$stitched_output"
        )
        log_ffmpeg_command "stitch-audio" "${stitch_encode_cmd[@]}"
        "${stitch_encode_cmd[@]}" || true
      else
        case "$format" in
          mov|mp4|mkv)
            local -a stitch_codec_args
            build_codec_args "$format" "$effective_quality_kind"
            stitch_codec_args=("${reply[@]}")
            log_export "$list_file" "$stitched_output"
            prepare_subprocess_env
            local -a stitch_encode_cmd=(
              "$ffmpeg_bin" -y -f concat -safe 0 -i "$list_file"
              "${stitch_codec_args[@]}"
              "${stitch_container_args[@]}"
              "${sanitized_extra_args[@]}"
              "$stitched_output"
            )
            log_ffmpeg_command "stitch-encode" "${stitch_encode_cmd[@]}"
            "${stitch_encode_cmd[@]}" || true
            ;;
          *)
            log_export "$list_file" "$stitched_output"
            prepare_subprocess_env
            local -a stitch_default_cmd=(
              "$ffmpeg_bin" -y -f concat -safe 0 -i "$list_file"
              -c:v libx264 -crf 20 -preset medium -c:a aac -b:a 192k
              "${stitch_container_args[@]}"
              "${sanitized_extra_args[@]}"
              "$stitched_output"
            )
            log_ffmpeg_command "stitch-default" "${stitch_default_cmd[@]}"
            "${stitch_default_cmd[@]}" || true
            ;;
        esac
      fi
    fi

    if [[ ! -f "$stitched_output" ]]; then
      echo "[ERROR] Failed to produce stitched output." >&2
      exit 1
    fi

    if final_duration=$(probe_media_duration "$stitched_output"); then
      info "[stitch/batch] stitched duration: $final_duration"
      append_run_note "Stitched duration: $final_duration"
    fi

    primary_input_path="$folder_abs"
    cleanup_stage_done=1
    run_notes=("${initial_run_notes[@]}")
    write_versions_file "${artifact_dir_override%/}/versions.txt"
    write_run_manifest "${artifact_dir_override%/}/run_manifest.json" "success" "$folder_abs" "$artifact_dir_override" "" "" "$list_file" "" "" "$stitched_output" "" "" "${artifact_dir_override%/}/versions.txt"

    echo "[INFO] Final stitched output: $stitched_output"
    exit 0
  fi

  batch_output_override=""
  batch_base_prefix=""

  if [[ -n "$output_base" ]]; then
    batch_output_override="${batch_output_root%/}/${output_base}"
    if mkdir -p "$batch_output_override" 2>/dev/null; then
      debug_log "[batch] Writing outputs under: $batch_output_override"
    else
      warn "[batch] Unable to create output_base folder: $batch_output_override; prefixing outputs instead"
      batch_output_override=""
      batch_base_prefix="$output_base"
    fi
  fi

  for abs in "${batch_files[@]}"; do
    debug_log "Batch candidate path: '$abs'"
    echo "Processing $abs"

    file_base_override=""
    file_output_dir_override=""

    if [[ -n "$batch_output_override" ]]; then
      file_output_dir_override="$batch_output_override"
    fi

    if [[ -n "$batch_base_prefix" ]]; then
      file_base_override="${batch_base_prefix}_${abs:t:r}"
    fi

    if ! process_file_controller "$abs" "$file_base_override" "$file_output_dir_override"; then
      echo "[ERROR] Failed while processing: $abs" >&2
      # continue to next file instead of bailing
      continue
    fi
  done

  exit 0
fi






echo "ERROR: Unknown mode: $mode" >&2
exit 1
