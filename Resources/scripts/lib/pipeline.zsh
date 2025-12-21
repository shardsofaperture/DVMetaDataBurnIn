# pipeline.zsh

apply_job_spec() {
  local spec_name="$1"
  typeset -n spec="$spec_name"

  mode="$spec[mode]"
  layout="$spec[layout]"
  format="$spec[format]"
  encode_quality="$spec[encode_quality]"
  output_mode="$spec[output_mode]"
  burn_mode="$spec[burn_mode]"
  subtitle_mode="$spec[subtitle_mode]"
  deinterlace_mode="$spec[deinterlace_mode]"
  missing_meta="$spec[missing_meta]"
  fontfile="$spec[fontfile]"
  fontname="$spec[fontname]"
  ffmpeg_bin="$spec[ffmpeg_bin]"
  dvrescue_bin="$spec[dvrescue_bin]"
  dest_dir="$spec[dest_dir]"
  output_base="$spec[output_base]"
  scratch_dir="$spec[scratch_dir]"
  scratch_cleanup_policy="$spec[scratch_cleanup_policy]"
  keep_on_failure="$spec[keep_on_failure]"
  stitch_enabled="$spec[stitch_enabled]"
  stitch_batch="$spec[stitch_batch]"
  stitch_input_list="$spec[stitch_input_list]"
  debug_mode="$spec[debug_mode]"
  burn_granularity="$spec[burn_granularity]"

  requested_format="$spec[requested_format]"
  requested_encode_quality="$spec[requested_encode_quality]"
  effective_format="$spec[effective_format]"
  effective_encode_quality="$spec[effective_encode_quality]"
  effective_quality_kind="$spec[effective_quality_kind]"
  format_coerced="$spec[format_coerced]"
  format_coercion_reason="$spec[format_coercion_reason]"

  run_scratch_root="$spec[run_scratch_root]"
  artifact_root="$spec[artifact_root]"

  sanitized_extra_args=()
  if (( ${#job_spec_extra_args[@]} > 0 )); then
    sanitized_extra_args=("${job_spec_extra_args[@]}")
  fi

  initial_run_notes=("${job_spec_initial_run_notes[@]}")
}

process_one_file() {
  local spec_name="$1"
  local input_path="$2"
  local base_override="${3:-}"
  local output_dir_override="${4:-}"
  local artifact_dir_override="${5:-}"

  apply_job_spec "$spec_name"
  process_file_controller "$input_path" "$base_override" "$output_dir_override" "$artifact_dir_override"
}

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
  sendcmd_exec_path=""
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

    log_write "$out_audio"
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
      finish_run "$exit_status" "$manifest_status" "$source_video" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_target" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
      die "ffmpeg encode failed for: $source_video"
    fi

    exit_status=0
    manifest_status="success"
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
  if ! run_dvrescue_capture "$source_video" "$dvrescue_xml" "$dvrescue_log"; then
    dv_status=$?
  fi
  last_dvrescue_status=$dv_status

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
    local final_out="${base}_conv.${out_ext}"
    local work_out=""
    if [[ -n "$deinterlace_vf" ]]; then
      work_out="${run_scratch_root%/}/artifacts/$(basename "$final_out").work.${out_ext}"
    fi
    echo "[PATH] FINAL_OUT=$final_out"
    echo "[PATH] WORK_OUT=$work_out"
    echo "[INFO] Transcode-only conversion (no burn-in) to: $final_out"
    debug_log "Running transcode-only encode with args: ${codec_args[*]}"
    ensure_cleanup_stage
    echo "[WRITE] -> $final_out"
    if [[ -n "$work_out" ]]; then
      echo "[WRITE] -> $work_out"
    fi
    local transcode_target="$final_out"
    if [[ -n "$work_out" ]]; then
      transcode_target="$work_out"
    fi
    local -a transcode_cmd=("$ffmpeg_bin" -y -i "$source_video")
    if [[ -n "$deinterlace_vf" ]]; then
      transcode_cmd+=(-vf "$deinterlace_vf")
    fi
    transcode_cmd+=(
      "${codec_args[@]}"
      "${deinterlace_fps_args[@]}"
      "${container_args[@]}"
      "${sanitized_extra_args[@]}"
      "$transcode_target"
    )
    log_export "$source_video" "$transcode_target"
    prepare_subprocess_env
    log_ffmpeg_command "transcode-only" "${transcode_cmd[@]}"
    if ! run_stage "encode" "${transcode_cmd[@]}"; then
      exit_status=$?
      manifest_status="error"
      passthrough_output="$final_out"
      last_passthrough_output_path="$passthrough_output"
      finish_run "$exit_status" "$manifest_status" "$source_video" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_target" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
      die "ffmpeg encode failed for: $source_video"
    fi

    if [[ -n "$work_out" ]]; then
      log_move "$work_out" "$final_out"
      if ! mv -f "$work_out" "$final_out"; then
        exit_status=$?
        manifest_status="error"
        passthrough_output="$final_out"
        last_passthrough_output_path="$passthrough_output"
        finish_run "$exit_status" "$manifest_status" "$source_video" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_target" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
        die "Failed to move scratch output into place: $work_out -> $final_out"
      fi
    fi

    exit_status=0
    manifest_status="success"
    passthrough_output="$final_out"
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
          local final_out="${base}_conv.${out_ext}"
          local work_out=""
          if [[ -n "$deinterlace_vf" ]]; then
            work_out="${run_scratch_root%/}/artifacts/$(basename "$final_out").work.${out_ext}"
          fi
          echo "[PATH] FINAL_OUT=$final_out"
          echo "[PATH] WORK_OUT=$work_out"
          echo "[INFO] Missing metadata fallback: writing transcode-only output to $final_out (stitch-batch will use *_conv.* parts)." >&2
          ensure_cleanup_stage
          echo "[WRITE] -> $final_out"
          if [[ -n "$work_out" ]]; then
            echo "[WRITE] -> $work_out"
          fi
          local subtitle_fallback_target="$final_out"
          if [[ -n "$work_out" ]]; then
            subtitle_fallback_target="$work_out"
          fi
          local -a subtitle_fallback_cmd=("$ffmpeg_bin" -y -i "$source_video")
          if [[ -n "$deinterlace_vf" ]]; then
            subtitle_fallback_cmd+=(-vf "$deinterlace_vf")
          fi
          subtitle_fallback_cmd+=(
            "${codec_args[@]}"
            "${deinterlace_fps_args[@]}"
            "${container_args[@]}"
            "${sanitized_extra_args[@]}"
            "$subtitle_fallback_target"
          )
          log_export "$source_video" "$subtitle_fallback_target"
          prepare_subprocess_env
          log_ffmpeg_command "subtitle-fallback" "${subtitle_fallback_cmd[@]}"
          if ! run_stage "encode" "${subtitle_fallback_cmd[@]}"; then
            exit_status=$?
            manifest_status="error"
            passthrough_output="$final_out"
            last_passthrough_output_path="$passthrough_output"
            finish_run "$exit_status" "$manifest_status" "$source_video" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_target" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
            die "ffmpeg encode failed for: $source_video"
          fi

          if [[ -n "$work_out" ]]; then
            log_move "$work_out" "$final_out"
            if ! mv -f "$work_out" "$final_out"; then
              exit_status=$?
              manifest_status="error"
              passthrough_output="$final_out"
              last_passthrough_output_path="$passthrough_output"
              finish_run "$exit_status" "$manifest_status" "$source_video" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_target" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
              die "Failed to move scratch output into place: $work_out -> $final_out"
            fi
          fi

          exit_status=0
          manifest_status="success"
          passthrough_output="$final_out"
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
    local final_out="${base}_dvsub.mkv"
    local work_out=""
    if [[ -n "$deinterlace_vf" ]]; then
      work_out="${run_scratch_root%/}/artifacts/$(basename "$final_out").work.${out_ext}"
    fi
    echo "[PATH] FINAL_OUT=$final_out"
    echo "[PATH] WORK_OUT=$work_out"
    local mux_target="$final_out"
    if [[ -n "$work_out" ]]; then
      mux_target="$work_out"
    fi
    local -a sub_video_args=("${codec_args[@]}")
    local subtitle_codec="ass"

    echo "[INFO] Muxing subtitle track into: $final_out" >&2
    echo "[WRITE] -> $final_out"
    if [[ -n "$work_out" ]]; then
      echo "[WRITE] -> $work_out"
    fi
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
      "$mux_target"
    )

    log_export "$source_video" "$mux_target"
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

    if [[ -n "$work_out" ]]; then
      log_move "$work_out" "$final_out"
      if ! mv -f "$work_out" "$final_out"; then
        exit_status=$?
        manifest_status="error"
        finish_run "$exit_status" "$manifest_status" "$source_video" "$artifact_dir" \
          "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_target" \
          "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
        die "Failed to move scratch output into place: $work_out -> $final_out"
      fi
    fi

    exit_status=0
    manifest_status="success"
    subtitle_output="$final_out"
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
        local final_out="${base}_conv.${out_ext}"
        local work_out=""
        if [[ -n "$deinterlace_vf" ]]; then
          work_out="${run_scratch_root%/}/artifacts/$(basename "$final_out").work.${out_ext}"
        fi
        echo "[PATH] FINAL_OUT=$final_out"
        echo "[PATH] WORK_OUT=$work_out"
        echo "[INFO] Missing metadata fallback: writing transcode-only output to $final_out (stitch-batch will use *_conv.* parts)." >&2
        ensure_cleanup_stage
        echo "[WRITE] -> $final_out"
        if [[ -n "$work_out" ]]; then
          echo "[WRITE] -> $work_out"
        fi
        local timeline_fallback_target="$final_out"
        if [[ -n "$work_out" ]]; then
          timeline_fallback_target="$work_out"
        fi
        local -a timeline_fallback_cmd=("$ffmpeg_bin" -y -i "$source_video")
        if [[ -n "$deinterlace_vf" ]]; then
          timeline_fallback_cmd+=(-vf "$deinterlace_vf")
        fi
        timeline_fallback_cmd+=(
          "${codec_args[@]}"
          "${deinterlace_fps_args[@]}"
          "${container_args[@]}"
          "${sanitized_extra_args[@]}"
          "$timeline_fallback_target"
        )
        log_export "$source_video" "$timeline_fallback_target"
        prepare_subprocess_env
        log_ffmpeg_command "timeline-fallback" "${timeline_fallback_cmd[@]}"
        if ! run_stage "encode" "${timeline_fallback_cmd[@]}"; then
          exit_status=$?
          manifest_status="error"
          passthrough_output="$final_out"
          last_passthrough_output_path="$passthrough_output"
          finish_run "$exit_status" "$manifest_status" "$source_video" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_target" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
          die "ffmpeg encode failed for: $source_video"
        fi
        if [[ -n "$work_out" ]]; then
          log_move "$work_out" "$final_out"
          if ! mv -f "$work_out" "$final_out"; then
            exit_status=$?
            manifest_status="error"
            passthrough_output="$final_out"
            last_passthrough_output_path="$passthrough_output"
            finish_run "$exit_status" "$manifest_status" "$source_video" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_target" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
            die "Failed to move scratch output into place: $work_out -> $final_out"
          fi
        fi
        exit_status=0
        manifest_status="success"
        passthrough_output="$final_out"
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

  if ! validate_sendcmd_file "$cmdfile"; then
    echo "[ERROR] sendcmd validation failed before ffmpeg run" >&2
    finish_run 1 "error" "$source_video" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_target" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
    die "sendcmd validation failed for: $source_video"
  fi

  local vf
  if ! vf=$(build_burnin_filtergraph "$layout" "$cmdfile" "$font" "$deinterlace_mode"); then
    echo "Unknown layout: $layout" >&2
    finish_run 1 "error" "$source_video" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_target" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
    return 1
  fi

  if [[ ! -s "$cmdfile" ]]; then
    warn "[burn] timestamp.cmd is empty -> overlay will be blank"
  fi
  if [[ "$vf" != *"sendcmd="* || "$vf" != *"drawtext@dvdate"* || "$vf" != *"drawtext@dvtime"* ]]; then
    warn "[burn] vf missing expected sendcmd/drawtext pieces"
    warn "[burn] vf='$vf'"
  fi

  local -a sendcmd_smoke_cmd=(
    "$ffmpeg_bin" -v error
    -f lavfi -i "color=c=black:s=16x16:d=1"
    -vf "$vf"
    -frames:v 1
    -f null -
  )
  log_ffmpeg_command "sendcmd-smoke" "${sendcmd_smoke_cmd[@]}"
  if ! run_sendcmd_smoke_check "sendcmd-smoke" "${sendcmd_smoke_cmd[@]}"; then
    exit_status=$?
    manifest_status="error"
    finish_run "$exit_status" "$manifest_status" "$source_video" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_target" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
    die "sendcmd smoke test failed for: $source_video"
  fi

  if [[ "$format" == "mkv" && "$burn_mode" == "burnin" ]]; then
    if [[ "$vf" == *"sendcmd"* && "$vf" == *"drawtext"* ]]; then
      info "[burn] MKV burn-in filtergraph contains sendcmd and drawtext"
    else
      warn "[burn] MKV burn-in filtergraph missing sendcmd/drawtext markers"
    fi
  fi


  local final_out="${base}_dateburn.${out_ext}"
  local work_out=""
  if [[ -n "$deinterlace_vf" ]]; then
    work_out="${run_scratch_root%/}/artifacts/$(basename "$final_out").work.${out_ext}"
  fi
  echo "[PATH] FINAL_OUT=$final_out"
  echo "[PATH] WORK_OUT=$work_out"
  echo "[INFO] Burning DV metadata into: $final_out"
  echo "[WRITE] -> $final_out"
  if [[ -n "$work_out" ]]; then
    echo "[WRITE] -> $work_out"
  fi
  debug_log "ffmpeg burn-in filtergraph: $vf"
  debug_log "ffmpeg burn-in args: ${codec_args[*]}"
  local burn_target="$final_out"
  if [[ -n "$work_out" ]]; then
    burn_target="$work_out"
  fi
  local -a burn_cmd=(
    "$ffmpeg_bin" -y -i "$source_video"
    -vf "$vf"
    "${codec_args[@]}"
    "${deinterlace_fps_args[@]}"
    "${container_args[@]}"
    "${sanitized_extra_args[@]}"
    "$burn_target"
  )
  log_export "$source_video" "$burn_target"
  prepare_subprocess_env
  log_ffmpeg_command "burn-in" "${burn_cmd[@]}"
  if ! run_stage "encode" "${burn_cmd[@]}"; then
    exit_status=$?
    manifest_status="error"
    burn_output="$final_out"
    last_burn_output_path="$burn_output"
    finish_run "$exit_status" "$manifest_status" "$source_video" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_target" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
    die "ffmpeg encode failed for: $source_video"
  fi

  if [[ -n "$work_out" ]]; then
    log_move "$work_out" "$final_out"
    if ! mv -f "$work_out" "$final_out"; then
      exit_status=$?
      manifest_status="error"
      burn_output="$final_out"
      last_burn_output_path="$burn_output"
      finish_run "$exit_status" "$manifest_status" "$source_video" "$artifact_dir" "$dvrescue_xml" "$dvrescue_log" "$timeline_debug" "$cmdfile" "$ass_target" "$burn_output" "$subtitle_output" "$passthrough_output" "$versions_file" "$run_manifest"
      die "Failed to move scratch output into place: $work_out -> $final_out"
    fi
  fi

  exit_status=0
  manifest_status="success"
  burn_output="$final_out"
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

run_selftest() {
  local tmp_root
  tmp_root=$(mktemp -d "${TMPDIR%/}/dvmetaburn_selftest.XXXXXX") || {
    echo "[ERROR] Unable to create selftest temp dir" >&2
    return 1
  }

  local input_path
  input_path="${tmp_root}/selftest_input.mp4"

  info "[selftest] Generating lavfi input at $input_path"
  local -a gen_cmd=(
    "$ffmpeg_bin" -y
    -f lavfi -i "testsrc=size=640x480:rate=30000/1001"
    -f lavfi -i "sine=frequency=1000:sample_rate=48000"
    -t 1
    -pix_fmt yuv420p
    -c:v libx264 -preset ultrafast -crf 28
    -c:a aac -b:a 96k
    "$input_path"
  )
  log_ffmpeg_command "selftest-generate" "${gen_cmd[@]}"
  if ! "${gen_cmd[@]}"; then
    echo "[ERROR] Selftest failed to generate lavfi input" >&2
    return 1
  fi

  local selftest_dir
  selftest_dir="${tmp_root}/outputs"
  mkdir -p "$selftest_dir"

  local previous_output_mode="$output_mode"
  local previous_burn_mode="$burn_mode"
  local previous_format="$format"
  local previous_deinterlace="$deinterlace_mode"
  local previous_dest_dir="$dest_dir"
  local original_format="${job_spec[format]}"
  local original_encode_quality="${job_spec[encode_quality]}"
  local original_output_mode="${job_spec[output_mode]}"
  local original_burn_mode="${job_spec[burn_mode]}"
  local original_subtitle_mode="${job_spec[subtitle_mode]}"
  local original_deinterlace_mode="${job_spec[deinterlace_mode]}"
  local original_requested_format="${job_spec[requested_format]}"
  local original_effective_format="${job_spec[effective_format]}"
  local original_effective_quality_kind="${job_spec[effective_quality_kind]}"
  local original_effective_encode_quality="${job_spec[effective_encode_quality]}"

  selftest_mode=1
  dest_dir="$selftest_dir"
  job_spec[dest_dir]="$selftest_dir"

  info "[selftest] Running burn-in MP4 test"
  job_spec[format]="mp4"
  job_spec[requested_format]="mp4"
  job_spec[effective_format]="mp4"
  job_spec[encode_quality]="medium"
  job_spec[effective_quality_kind]="medium"
  job_spec[effective_encode_quality]="medium"
  job_spec[burn_mode]="burnin"
  job_spec[subtitle_mode]="$original_subtitle_mode"
  job_spec[deinterlace_mode]="off"
  process_one_file "job_spec" "$input_path" "selftest_burnin"

  info "[selftest] Running subtitle track MKV test"
  job_spec[format]="mkv"
  job_spec[requested_format]="mkv"
  job_spec[effective_format]="mkv"
  job_spec[encode_quality]="medium"
  job_spec[effective_quality_kind]="medium"
  job_spec[effective_encode_quality]="medium"
  job_spec[burn_mode]="subtitleTrack"
  job_spec[subtitle_mode]="per-clip"
  job_spec[deinterlace_mode]="off"
  process_one_file "job_spec" "$input_path" "selftest_subs"

  info "[selftest] Running transcode-only test"
  job_spec[format]="mp4"
  job_spec[requested_format]="mp4"
  job_spec[effective_format]="mp4"
  job_spec[encode_quality]="medium"
  job_spec[effective_quality_kind]="medium"
  job_spec[effective_encode_quality]="medium"
  job_spec[burn_mode]="off"
  job_spec[subtitle_mode]="$original_subtitle_mode"
  job_spec[deinterlace_mode]="off"
  process_one_file "job_spec" "$input_path" "selftest_transcode"

  info "[selftest] Running deinterlace toggle test"
  job_spec[format]="mp4"
  job_spec[requested_format]="mp4"
  job_spec[effective_format]="mp4"
  job_spec[encode_quality]="medium"
  job_spec[effective_quality_kind]="medium"
  job_spec[effective_encode_quality]="medium"
  job_spec[burn_mode]="burnin"
  job_spec[subtitle_mode]="$original_subtitle_mode"
  job_spec[deinterlace_mode]="60p"
  process_one_file "job_spec" "$input_path" "selftest_deinterlace"

  selftest_mode=0
  dest_dir="$previous_dest_dir"
  output_mode="$previous_output_mode"
  burn_mode="$previous_burn_mode"
  format="$previous_format"
  deinterlace_mode="$previous_deinterlace"
  job_spec[dest_dir]="$previous_dest_dir"
  job_spec[format]="$original_format"
  job_spec[encode_quality]="$original_encode_quality"
  job_spec[output_mode]="$original_output_mode"
  job_spec[burn_mode]="$original_burn_mode"
  job_spec[subtitle_mode]="$original_subtitle_mode"
  job_spec[deinterlace_mode]="$original_deinterlace_mode"
  job_spec[requested_format]="$original_requested_format"
  job_spec[effective_format]="$original_effective_format"
  job_spec[effective_quality_kind]="$original_effective_quality_kind"
  job_spec[effective_encode_quality]="$original_effective_encode_quality"

  info "[selftest] Completed outputs in $selftest_dir"
  return 0
}
