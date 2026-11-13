#!/bin/zsh

set -euo pipefail
setopt ERR_EXIT

script_root="$(cd -- "$(dirname -- "$0")" && pwd)"
lib_dir="${script_root%/}/lib"

fatal() {
  print -r -- "[FATAL] $*" >&2
  exit 1
}

export PATH="/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:$PATH}"

if [[ -f "${lib_dir}/env.zsh" ]]; then
  /bin/zsh -n "${lib_dir}/env.zsh" || fatal "Parse check failed: ${lib_dir}/env.zsh"
  if ! source "${lib_dir}/env.zsh"; then
    fatal "Failed to source ${lib_dir}/env.zsh"
  fi
else
  export LC_ALL=C LC_NUMERIC=C LANG=C
  print -r -- "[WARN] Missing ${lib_dir}/env.zsh; using inline env defaults." >&2
fi

required_libs=(
  logging.zsh
  pathing.zsh
  artifacts.zsh
  dvrescue.zsh
  timeline.zsh
  filtergraph.zsh
  encode.zsh
  stitch.zsh
  cleanup.zsh
  pipeline.zsh
)

for lib_file in "${required_libs[@]}"; do
  [[ -f "${lib_dir}/${lib_file}" ]] || fatal "Missing required lib: ${lib_dir}/${lib_file}"
done

for lib_file in "${required_libs[@]}"; do
  /bin/zsh -n "${lib_dir}/${lib_file}" || fatal "Parse check failed: ${lib_dir}/${lib_file}"
done

RUN_ID="${DVMETA_RUN_ID:-${RUN_ID:-}}"
echo "[RUN] id=${RUN_ID:-} argv=$*"

typeset -g last_stage_marker=""
typeset -g last_stage_cmd=""

setopt NULL_GLOB

echo "[INFO] locale: LC_ALL=${LC_ALL:-unset} LC_NUMERIC=${LC_NUMERIC:-unset} LANG=${LANG:-unset}" >&2
if command -v locale >/dev/null 2>&1; then
  echo "[INFO] locale output (head -n 20):" >&2
  locale 2>/dev/null | /usr/bin/head -n 20 | while IFS= read -r line; do
    echo "[INFO] locale: $line" >&2
  done
fi

# Ensure zsh temp files go somewhere writable
: "${TMPDIR:=/tmp}"
TMPDIR="${TMPDIR%/}"
TMPPREFIX="${TMPDIR}/zsh-"

mkdir -p "$TMPDIR"
export TMPDIR TMPPREFIX

for lib in logging pathing artifacts dvrescue timeline filtergraph encode stitch cleanup pipeline; do
  if ! source "${lib_dir}/${lib}.zsh"; then
    fatal "Failed to source ${lib_dir}/${lib}.zsh"
  fi
done


typeset -ga run_notes=()
typeset -ga initial_run_notes=()
typeset -ga sanitized_extra_args=()
typeset -g last_stage_marker=""
typeset -g last_stage_cmd=""
extra_args_raw=""
typeset -A job_spec=()
typeset -ga job_spec_extra_args=()
typeset -ga job_spec_initial_run_notes=()
selftest_requested=0


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
scratch_cleanup_policy="${DVMETA_SCRATCH_CLEANUP:-never}"
keep_on_failure="${DVMETA_KEEP_ON_FAILURE:-0}"

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
    --scratch-cleanup=*) scratch_cleanup_policy="${1#*=}"; shift ;;
    --cleanup=*) scratch_cleanup_policy="${1#*=}"; shift ;;
    --keep-on-failure=*) keep_on_failure="${1#*=}"; shift ;;
    --keep-on-failure) keep_on_failure=1; shift ;;
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
    --selftest) selftest_requested=1; shift ;;
    --) shift; break ;;
    -*) fatal "Unknown option: $1" ;;
    *) break ;;
  esac
done

if (( debug_mode == 1 )); then
  debug_log "Effective PATH: $PATH"
fi

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

scratch_cleanup_policy="${scratch_cleanup_policy//[[:space:]]/}"
scratch_cleanup_policy="${scratch_cleanup_policy//_/-}"
scratch_cleanup_policy="${scratch_cleanup_policy:l}"
case "$scratch_cleanup_policy" in
  success|on-success|clear-on-success)
    scratch_cleanup_policy="success"
    ;;
  failure|on-failure|clear-on-failure)
    scratch_cleanup_policy="failure"
    ;;
  never|off|none|"")
    scratch_cleanup_policy="never"
    ;;
  *)
    warn "Unknown scratch cleanup policy '$scratch_cleanup_policy'; defaulting to never."
    scratch_cleanup_policy="never"
    ;;
esac

keep_on_failure="${keep_on_failure//[[:space:]]/}"
keep_on_failure="${keep_on_failure:l}"
case "$keep_on_failure" in
  1|true|yes|on)
    keep_on_failure=1
    ;;
  0|false|no|off|"")
    keep_on_failure=0
    ;;
  *)
    warn "Unknown keep-on-failure value '$keep_on_failure'; defaulting to off."
    keep_on_failure=0
    ;;
esac

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

# All invocations use an exclusively created workspace. Swift can supply its
# already-owned workspace so copied scripts and processing artifacts share it.
trap 'exit_run_workspace $?' EXIT
trap 'cancel_run_workspace 143' TERM
trap 'cancel_run_workspace 130' INT
trap 'cancel_run_workspace 129' HUP
initialize_run_workspace "$@" || fatal "Unable to initialize run workspace"
initial_run_notes=("${run_notes[@]}")

# Track parse stats for manifest writing
typeset -g last_parse_raw_rows=0
typeset -g last_parse_valid_rows=0
typeset -g last_parse_skipped_rows=0
typeset -g last_parse_timeline_entries=0
typeset -g last_parse_frame_source="unknown"
typeset -g last_dvrescue_status=0
typeset -g last_detected_fps=""
typeset -g timestamps_normalized=0
typeset -g sendcmd_exec_path=""
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

job_spec=(
  mode "$mode"
  layout "$layout"
  format "$format"
  encode_quality "$encode_quality"
  output_mode "$output_mode"
  burn_mode "$burn_mode"
  subtitle_mode "$subtitle_mode"
  deinterlace_mode "$deinterlace_mode"
  missing_meta "$missing_meta"
  fontfile "$fontfile"
  fontname "$fontname"
  ffmpeg_bin "$ffmpeg_bin"
  dvrescue_bin "$dvrescue_bin"
  dest_dir "$dest_dir"
  output_base "$output_base"
  scratch_dir "$scratch_dir"
  scratch_cleanup_policy "$scratch_cleanup_policy"
  keep_on_failure "$keep_on_failure"
  stitch_enabled "$stitch_enabled"
  stitch_batch "$stitch_batch"
  stitch_input_list "$stitch_input_list"
  debug_mode "$debug_mode"
  burn_granularity "$burn_granularity"
  requested_format "$requested_format"
  requested_encode_quality "$requested_encode_quality"
  effective_format "$effective_format"
  effective_encode_quality "$effective_encode_quality"
  effective_quality_kind "$effective_quality_kind"
  format_coerced "$format_coerced"
  format_coercion_reason "$format_coercion_reason"
  run_scratch_root "$run_scratch_root"
  artifact_root "$artifact_root"
)

job_spec_extra_args=("${sanitized_extra_args[@]}")
job_spec_initial_run_notes=("${initial_run_notes[@]}")

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
job_spec[dest_dir]="$dest_dir"


########################################################
# Mode routing
########################################################

if [[ "${RUN_OFFLINE_TEST:-0}" == "1" ]]; then
  offline_smoke_test
  exit $?
fi

if (( selftest_requested == 1 )); then
  run_selftest
  exit $?
fi

if [[ "$mode" == "single" ]]; then
  stitch_batch=0
  job_spec[stitch_batch]=0
  if [[ $# -ne 1 ]]; then
    echo "Usage: $0 [--mode=single] [--layout=stacked|single] [--format=mov|mp4|mkv] [--quality=low|medium|high] [--burn-mode=burnin|off|subtitleTrack] [--subtitle-mode=per-clip|continuous] [--deinterlace=off|30p|60p (default: off)] [--scratch-dir=/path (or DVMETA_SCRATCH_DIR)] [--scratch-cleanup=success|failure|never] [--keep-on-failure] [--output-base=name] [--stitch [--stitch-inputs=/path/to/list.txt]] /path/to/clip.avi" >&2
    exit 1
  fi
  debug_log "Running in single-file mode with target: $1"
  single_base_override=""
  if [[ -n "$output_base" ]]; then
    single_base_override="$output_base"
  fi

  process_one_file "job_spec" "$1" "$single_base_override"
  exit $?
fi

if [[ "$mode" == "batch" ]]; then
  if [[ $# -ne 1 ]]; then
    echo "Usage: $0 --mode=batch [--layout=stacked|single] [--format=mov|mp4|mkv] [--quality=low|medium|high] [--burn-mode=burnin|off|subtitleTrack] [--subtitle-mode=per-clip|continuous] [--deinterlace=off|30p|60p (default: off)] [--scratch-dir=/path (or DVMETA_SCRATCH_DIR)] [--scratch-cleanup=success|failure|never] [--keep-on-failure] [--output-base=name] [--stitch [--stitch-inputs=/path/to/list.txt]] /path/to/folder" >&2
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

  mkdir -p -- "$batch_output_root" || fatal "Unable to create batch destination: $batch_output_root"

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

    local target_ext stitched_suffix part_suffix conv_suffix conv_stitched_suffix burn_stitched_suffix
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
      burn_stitched_suffix="_stitched_dateburn.${target_ext}"
      conv_stitched_suffix="_stitched_conv.${target_ext}"
      part_suffix="_dateburn.${format}"
      conv_suffix="_conv.${format}"
    fi

    output_dir_override="$batch_output_root"

    ts="$(date '+%Y%m%d_%H%M%S')"
    artifact_dir_override="${artifact_root%/}/${base_name}_stitched_${ts}"
    burned_parts_dir="${run_scratch_root%/}/artifacts/${base_name}_stitched_${ts}/burned_parts"

    if ! mkdir -p "$burned_parts_dir"; then
      echo "[ERROR] Unable to create artifact directory for stitching: $artifact_dir_override" >&2
      exit 1
    fi

    suppress_finish_run=1
    typeset -a burnin_outputs=()
    typeset -a convert_outputs=()
    typeset -a part_ids=()
    local idx=1
    local abs part_base part_artifact_dir
    local had_part_failure=0

    for abs in "${batch_files[@]}"; do
      part_base=$(printf "%04d" "$idx")
      part_artifact_dir="${burned_parts_dir%/}/${part_base}_artifacts"
      debug_log "[stitch/batch] Burning part $part_base from $abs (artifacts -> $part_artifact_dir)"

      last_stage_marker=""
      if ! process_one_file "job_spec" "$abs" "$part_base" "$burned_parts_dir" "$part_artifact_dir"; then
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
    log_write "$list_file"
    : > "$list_file"
    local burned_count=0
    local conv_count=0
    local missing_count=0
    local -a stitch_inputs=()
    local -a resolved_parts=()

    local part_id burned_path conv_path chosen_path chosen_kind
    for part_id in "$part_ids[@]"; do
      burned_path="${burned_parts_dir%/}/${part_id}${part_suffix}"
      conv_path=""
      if [[ -n "$conv_suffix" ]]; then
        conv_path="${burned_parts_dir%/}/${part_id}${conv_suffix}"
      fi

      if [[ -f "$burned_path" ]]; then
        info "[stitch] part ${part_id} -> dateburn"
        burnin_outputs+=("$burned_path")
        chosen_path="$burned_path"
        chosen_kind="dateburn"
        (( ++burned_count ))
      elif [[ -n "$conv_suffix" && -f "$conv_path" ]]; then
        info "[stitch] part ${part_id} -> conv (no burn-in)"
        convert_outputs+=("$conv_path")
        chosen_path="$conv_path"
        chosen_kind="conv"
        (( ++conv_count ))
      else
        warn "[stitch] part ${part_id} missing (no dateburn/conv output)"
        (( ++missing_count ))
        continue
      fi

      stitch_inputs+=("$chosen_path")
      resolved_parts+=("${part_id} (${chosen_kind}) -> ${chosen_path}")
    done

    if (( ${#stitch_inputs[@]} == 0 )); then
      info "[stitch] No stitchable outputs found (burned=${burned_count} conv=${conv_count} missing=${missing_count}); leaving outputs in place."
      exit 0
    fi

    if (( ${#stitch_inputs[@]} == 1 )); then
      local single_output="${stitch_inputs[1]}"
      local single_suffix="$part_suffix"
      if [[ -n "$conv_suffix" && "$single_output" == *"${conv_suffix}" ]]; then
        single_suffix="$conv_suffix"
      fi
      local final_single_out="${output_dir_override%/}/${base_name}${single_suffix}"
      info "[stitch/batch] Single output; moving into place: $final_single_out"
      log_move "$single_output" "$final_single_out"
      if ! mv -f "$single_output" "$final_single_out"; then
        echo "[ERROR] Failed to move single burn-in output into place: $single_output -> $final_single_out" >&2
        exit 1
      fi
      if final_duration=$(probe_media_duration "$final_single_out"); then
        info "[stitch/batch] stitched duration: $final_duration"
        append_run_note "Stitched duration: $final_duration"
      fi
      exit 0
    fi

    for abs in "${stitch_inputs[@]}"; do
      printf "file '%s'\n" "$(escape_for_single_quotes "$abs")" >> "$list_file"
    done

    info "[stitch/batch] Resolved parts list (${#stitch_inputs[@]})"
    for abs in "${resolved_parts[@]}"; do
      info "[stitch/batch] ${abs}"
    done

    if [[ "$output_mode" == "audio" ]]; then
      local part_duration
      for abs in "${stitch_inputs[@]}"; do
        if part_duration=$(probe_media_duration "$abs"); then
          info "[stitch/batch] part ${abs:t}: $part_duration"
          append_run_note "Stitch part ${abs:t} duration: $part_duration"
        fi
      done
    fi

    if [[ "$burn_mode" != "subtitleTrack" && "$output_mode" != "audio" ]]; then
      if (( burned_count == 0 && conv_count > 0 )); then
        stitched_suffix="$conv_stitched_suffix"
      else
        stitched_suffix="$burn_stitched_suffix"
      fi
    fi
    local final_stitch_out="${output_dir_override%/}/${base_name}${stitched_suffix}"
    stitched_output="${artifact_dir_override%/}/stitched.final.${target_ext}"

    container_flag_for_format "$format"
    local -a stitch_container_args
    stitch_container_args=("${reply[@]}")

    info "[stitch/batch] concat list: $list_file"
    info "[stitch/batch] final output: $final_stitch_out"
    info "[stitch/batch] Concatenating ${#stitch_inputs[@]} stitchable parts into $stitched_output (stream copy)"
    log_export "$list_file" "$stitched_output"
    prepare_subprocess_env
    local -a stitch_copy_cmd=(
      "$ffmpeg_bin" -y -f concat -safe 0 -i "$list_file" -c copy
      "${sanitized_extra_args[@]}"
      "$stitched_output"
    )
    log_ffmpeg_command "stitch-copy" "${stitch_copy_cmd[@]}"
    stitch_ok=1
    if ! run_owned_command "${stitch_copy_cmd[@]}"; then
      stitch_ok=0
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
        if run_owned_command "${stitch_encode_cmd[@]}"; then stitch_ok=1; fi
      else
        case "$format" in
          mov|mp4|mkv)
            local -a stitch_codec_args
            build_codec_args "$format" "$effective_quality_kind"
            stitch_codec_args=("${reply[@]}")
            if [[ "$format" != mov && "$deinterlace_mode" == off ]]; then
              interlaced_video_args "$stitch_inputs[1]" || exit 1
              stitch_codec_args+=("${reply[@]}")
            fi
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
            if run_owned_command "${stitch_encode_cmd[@]}"; then stitch_ok=1; fi
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
            if run_owned_command "${stitch_default_cmd[@]}"; then stitch_ok=1; fi
            ;;
        esac
      fi
    fi

    if (( stitch_ok == 0 )) || [[ ! -s "$stitched_output" ]]; then
      echo "[ERROR] Failed to produce stitched output." >&2
      exit 1
    fi

    log_move "$stitched_output" "$final_stitch_out"
    if ! publish_completed_output "$stitched_output" "$final_stitch_out"; then
      echo "[ERROR] Failed to move stitched output into place: $stitched_output -> $final_stitch_out" >&2
      exit 1
    fi

    if final_duration=$(probe_media_duration "$final_stitch_out"); then
      info "[stitch/batch] stitched duration: $final_duration"
      append_run_note "Stitched duration: $final_duration"
    fi

    primary_input_path="$folder_abs"
    cleanup_stage_done=1
    run_notes=("${initial_run_notes[@]}")
    write_versions_file "${artifact_dir_override%/}/versions.txt"
    write_run_manifest "${artifact_dir_override%/}/run_manifest.json" "success" "$folder_abs" "$artifact_dir_override" "" "" "$list_file" "" "" "$final_stitch_out" "" "" "${artifact_dir_override%/}/versions.txt"

    echo "[INFO] Final stitched output: $final_stitch_out"

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

  batch_failed=0
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

    if ! process_one_file "job_spec" "$abs" "$file_base_override" "$file_output_dir_override"; then
      echo "[ERROR] Failed while processing: $abs" >&2
      batch_failed=1
      run_had_failure=1
      continue
    fi
  done

  exit "$batch_failed"
fi

echo "ERROR: Unknown mode: $mode" >&2
exit 1
