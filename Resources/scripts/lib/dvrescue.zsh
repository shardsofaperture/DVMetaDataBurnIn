# dvrescue.zsh

detect_fps() {
  local src="$1"

  if [[ ! -f "$src" ]]; then
    echo "[ERROR] File not found: $src" >&2
    return 1
  fi

  local probe_output fps
  probe_output=$("$ffmpeg_bin" -hide_banner -i "$src" 2>&1)
  fps=$(printf "%s\n" "$probe_output" | awk -F', ' '/Video:/ {for (i=1;i<=NF;i++) if ($i ~ /fps$/) {sub(/ fps/,"",$i); print $i; exit}}')

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
      warn "Unable to allocate scratch log for normalization"
      return 1
    }
  fi

  normalize_log_value_only "$source_log" "$tmp_output"
  local rc=$?

  if (( rc != 0 )); then
    warn "normalize_log_value_only failed with status $rc"
    return $rc
  fi

  if [[ -s "$tmp_output" ]]; then
    cp -f "$tmp_output" "$source_log"
    timestamps_normalized=1
    debug_log "Normalized timestamps written back to $source_log"
    log_artifact_path_and_size "dvrescue normalized" "$source_log"
  else
    warn "normalize_dvrescue_timestamps produced empty output; leaving original log"
    return 1
  fi

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

  log_write "$dest"
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

  if [[ -z "$target_log" ]]; then
    log_move "$dest" "$source_log"
    /bin/mv "$dest" "$source_log"
  fi
  return 0
}

generate_selftest_dvrescue_log() {
  local out_log="$1"
  local start_date="${2:-2024-01-01}"
  local start_time="${3:-00:00:00}"
  local entries="${4:-5}"

  log_write "$out_log"
  : > "$out_log"

  local i
  local -i seconds=0
  for (( i=1; i<=entries; i++ )); do
    printf "%d 00:00:00 %s %s\n" "$i" "$start_date" "$(printf '00:00:%02d' $seconds)" >> "$out_log"
    (( seconds++ ))
  done
}

run_dvrescue_capture() {
  local source_video="$1"
  local xml_out="$2"
  local log_out="$3"

  if (( ${selftest_mode:-0} == 1 )); then
    generate_selftest_dvrescue_log "$log_out" "2024-01-01" "00:00:00" 5
    : > "$xml_out"
    last_dvrescue_status=0
    log_artifact_path_and_size "dvrescue XML" "$xml_out"
    log_artifact_path_and_size "dvrescue log" "$log_out"
    return 0
  fi

  local dv_status=0
  debug_log "Extracting dvrescue XML -> $xml_out (log: $log_out)"
  prepare_subprocess_env
  log_write "$xml_out"
  log_write "$log_out"
  "$dvrescue_bin" "$source_video" --xml-output "$xml_out" >"$log_out" 2>&1
  dv_status=$?
  last_dvrescue_status=$dv_status
  log_artifact_path_and_size "dvrescue XML" "$xml_out"
  log_artifact_path_and_size "dvrescue log" "$log_out"
  return $dv_status
}
