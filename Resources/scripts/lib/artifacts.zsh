# artifacts.zsh

prepare_artifact_dir() {
  local input_path="$1"
  local base_name ts artifact_dir

  base_name="${input_path:t:r}"
  ts=$(date '+%Y%m%d_%H%M%S')

  if [[ -z "$artifact_root" ]]; then
    artifact_dir="${HOME}/Library/Logs/DVMeta/${base_name}_${ts}"
  else
    artifact_dir="${artifact_root%/}/${base_name}_${ts}"
  fi

  if ! mkdir -p "$artifact_dir"; then
    echo "[ERROR] Unable to create artifact directory: $artifact_dir" >&2
    return 1
  fi

  echo "$artifact_dir"
  return 0
}

stat_size_bytes() {
  local path="$1"
  if [[ ! -e "$path" ]]; then
    echo "0"
    return 0
  fi

  if stat -f '%z' "$path" >/dev/null 2>&1; then
    stat -f '%z' "$path"
    return 0
  fi

  if stat -c '%s' "$path" >/dev/null 2>&1; then
    stat -c '%s' "$path"
    return 0
  fi

  echo "0"
}

log_artifact_path_and_size() {
  local label="$1"
  local path="$2"
  local size

  size=$(stat_size_bytes "$path")
  echo "[INFO] ${label}: $path (${size} bytes)" >&2
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
  log_write "$dvrescue_log"
  : > "$dvrescue_log"
  log_write "$cmdfile"
  : > "$cmdfile"
  log_write "$timeline_debug"
  : > "$timeline_debug"
  log_write "$ass_artifact"
  : > "$ass_artifact"
  log_write "$run_manifest"
  printf '{"status":"pending","input":"%s"}\n' "$in" > "$run_manifest"
  log_write "$versions_file"
  : > "$versions_file"

  log_artifact_path_and_size "dvrescue XML" "$dvrescue_xml"
  log_artifact_path_and_size "dvrescue log" "$dvrescue_log"
  echo "[INFO] sendcmd path: $cmdfile" >&2
  echo "[INFO] ASS output path: $ass_artifact" >&2
  echo "[INFO] timeline debug path: $timeline_debug" >&2

  reply=("$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$cmdfile" "$timeline_debug" "$ass_artifact" "$run_manifest" "$versions_file")
  return 0
}

write_versions_file() {
  local path="$1"

  log_write "$path"
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

  log_write "$manifest_path"
  cat > "$manifest_path" <<EOF_MANIFEST
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
EOF_MANIFEST

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

  cleanup_run_scratch_root "$status_label" || warn "[cleanup] Scratch cleanup failed (non-fatal)"

  return "$exit_code"
}
