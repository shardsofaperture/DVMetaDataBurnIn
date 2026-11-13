# encode.zsh

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
        passthrough)
          warn "${format:u} passthrough not supported; using medium-quality transcode."
          resolved_quality_kind="medium"
          resolved_quality_label="medium"
          ;;
        *)
          resolved_quality_kind="medium"
          resolved_quality_label="medium"
          ;;
      esac
      ;;
    *)
      resolved_quality_kind="medium"
      resolved_quality_label="medium"
      ;;
  esac
}

build_codec_args() {
  local format="$1"
  local quality_kind="$2"

  resolve_encode_quality "$format" "$quality_kind"

  local -a args
  local resolved_quality_label="$resolved_quality_label"

  case "$format" in
    mov)
      args=(-c:v copy -c:a copy)
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

# Inspect decoded field order, not just a container tag. FFmpeg showinfo reports
# B/T/P for the decoded frame. DV uses a consistent order within a recording.
interlaced_video_args() {
  local source="$1" report order
  report=$("$ffmpeg_bin" -nostdin -hide_banner -i "$source" -map 0:v:0 \
    -vf showinfo -frames:v 1 -an -f null - 2>&1) || return 1
  order=$(print -r -- "$report" | sed -n 's/.* i:\([BTP]\) .*/\1/p' | head -1)
  reply=()
  case "$order" in
    B) reply=(-flags +ilme+ildct -top 0 -x264-params bff=1) ;;
    T) reply=(-flags +ilme+ildct -top 1 -x264-params tff=1) ;;
    P) ;;
    *) warn "Cannot determine decoded field order: $source"; return 1 ;;
  esac
}
