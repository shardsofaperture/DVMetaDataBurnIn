# stitch.zsh

build_stitch_input_list() {
  local in="$1"
  local list_file="$2"

  local -a inputs=()
  if [[ -n "$stitch_input_list" ]]; then
    if [[ -f "$stitch_input_list" ]]; then
      mapfile -t inputs < "$stitch_input_list"
    else
      warn "[stitch] stitch input list not found: $stitch_input_list"
    fi
  fi

  if (( ${#inputs[@]} == 0 )); then
    inputs=("$in")
  fi

  if (( ${#inputs[@]} < 2 )); then
    debug_log "[stitch] Not enough inputs to stitch (count=${#inputs[@]})"
    return 1
  fi

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

  reply=("${inputs[@]}")
  return 0
}

stitch_sources() {
  local in="$1"
  local artifact_dir="$2"

  local list_file
  list_file="${artifact_dir%/}/stitch_inputs.txt"

  local -a inputs
  if ! build_stitch_input_list "$in" "$list_file"; then
    reply=("" "")
    return 1
  fi
  inputs=("${reply[@]}")

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
    reply=("$stitched_path" "$list_file")
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
    reply=("$stitched_path" "$list_file")
    return 0
  fi

  warn "[stitch] Failed to stitch batch inputs"
  reply=("" "")
  return 1
}

stitch_batch_folder() {
  local burn_parts_dir="$1"
  local output_dir="$2"
  local stitched_base="$3"
  local part_suffix="$4"
  local output_suffix="$5"
  local out_ext="$6"
  local cleanup_parts="$7"
  local primary_target="$8"
  local conv_suffix="${9:-}"

  local list_file
  list_file="${burn_parts_dir%/}/stitched_inputs.txt"

  local -a inputs=()
  local -a resolved_parts=()
  typeset -A burn_parts=()
  typeset -A conv_parts=()

  local part_path part_name part_id
  for part_path in "${burn_parts_dir%/}"/*"${part_suffix}"; do
    [[ -f "$part_path" ]] || continue
    part_name="${part_path:t}"
    part_id="${part_name%${part_suffix}}"
    burn_parts["$part_id"]="$part_path"
  done

  if [[ -n "$conv_suffix" ]]; then
    for part_path in "${burn_parts_dir%/}"/*"${conv_suffix}"; do
      [[ -f "$part_path" ]] || continue
      part_name="${part_path:t}"
      part_id="${part_name%${conv_suffix}}"
      conv_parts["$part_id"]="$part_path"
    done
  fi

  local -a part_ids
  part_ids=(${(k)burn_parts} ${(k)conv_parts})
  part_ids=(${(onu)part_ids})

  if (( ${#part_ids[@]} == 0 )); then
    echo "[ERROR] No stitchable parts found in: $burn_parts_dir" >&2
    return 1
  fi

  local chosen_path chosen_kind
  for part_id in "${part_ids[@]}"; do
    chosen_path=""
    chosen_kind=""
    if [[ -n "${burn_parts[$part_id]:-}" ]]; then
      chosen_path="${burn_parts[$part_id]}"
      chosen_kind="dateburn"
    elif [[ -n "${conv_parts[$part_id]:-}" ]]; then
      chosen_path="${conv_parts[$part_id]}"
      chosen_kind="conv"
    fi

    if [[ -n "$chosen_path" ]]; then
      inputs+=("$chosen_path")
      resolved_parts+=("${part_id} (${chosen_kind}) -> ${chosen_path}")
    fi
  done

  if (( ${#inputs[@]} == 0 )); then
    echo "[ERROR] No stitchable parts matched after resolution in: $burn_parts_dir" >&2
    return 1
  fi

  : > "$list_file"
  local clip
  for clip in "${inputs[@]}"; do
    printf "file '%s'\n" "$(escape_for_single_quotes "$clip")" >>"$list_file"
  done

  info "[stitch/batch] Resolved parts list (${#inputs[@]})"
  local resolved
  for resolved in "${resolved_parts[@]}"; do
    info "[stitch/batch] ${resolved}"
  done

  local stitched_path
  stitched_path="${output_dir%/}/${stitched_base}${output_suffix}"

  info "[stitch/batch] concat list: $list_file"
  info "[stitch/batch] final output: $stitched_path"
  info "[stitch/batch] Concatenating ${#inputs[@]} clips into $stitched_path (stream copy)"
  prepare_subprocess_env
  local -a stitch_copy_cmd=(
    "$ffmpeg_bin" -y -f concat -safe 0 -i "$list_file" -c copy
    "${sanitized_extra_args[@]}"
    "$stitched_path"
  )
  log_ffmpeg_command "stitch-batch-copy" "${stitch_copy_cmd[@]}"
  if "${stitch_copy_cmd[@]}"; then
    stitch_inputs_resolved="$list_file"
    stitched_source="$stitched_path"
    return 0
  fi

  warn "[stitch/batch] Stream copy concat failed; retrying with re-encode fallback"
  prepare_subprocess_env
  local -a stitch_reencode_cmd
  build_codec_args "$format" "$effective_quality_kind"
  stitch_reencode_cmd=(
    "$ffmpeg_bin" -y -f concat -safe 0 -i "$list_file"
    "${reply[@]}"
    "${sanitized_extra_args[@]}"
    "$stitched_path"
  )
  log_ffmpeg_command "stitch-batch-encode" "${stitch_reencode_cmd[@]}"
  if "${stitch_reencode_cmd[@]}"; then
    stitch_inputs_resolved="$list_file"
    stitched_source="$stitched_path"
    return 0
  fi

  warn "[stitch/batch] Failed to stitch batch inputs"
  return 1
}
