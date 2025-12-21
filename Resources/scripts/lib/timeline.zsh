# timeline.zsh

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

  log_write "$timeline_out"
  tr '\r' '\n' < "$log_path" | LC_NUMERIC=C awk -v fps="$fps" -v granularity="$granularity" '
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
          time ~ /^[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?$/) {
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
  local fps_in="${3:-29.97}"

  if [[ ! -s "$tsv_path" ]]; then
    echo "[ERROR] build_sendcmd_from_timeline: empty timeline: $tsv_path" >&2
    return 1
  fi

  log_write "$sendcmd_path"
  : > "$sendcmd_path"

  LC_NUMERIC=C awk -F '\t' -v fps="$fps_in" '
    function escape_drawtext_reinit_value(text) {
      gsub(/\\/, "\\\\", text)
      gsub(/"/, "\\\"", text)
      gsub(/\047/, "\\\047", text)
      gsub(/%/, "\\%", text)
      gsub(/:/, "\\\\:", text)
      return text
    }

    # read all rows so we can lookahead to next timestamp
    NF >= 4 {
      n++
      t[n]    = ($2 + 0)
      date[n] = $3
      time[n] = $4
      gsub(/\r/, "", date[n])
      gsub(/\r/, "", time[n])
      sub(/;[0-9][0-9]$/, "", time[n])
    }

    END {
      if (n < 1) exit 2

      frame_step = 0.0333667
      if (fps > 0) frame_step = 1.0 / fps

      for (i=1; i<=n; i++) {
        start = t[i]
        if (i < n) {
          end = t[i+1] - 0.000001
          if (end <= start) end = start + 0.000001
        } else {
          end = start + frame_step
        }

        d = escape_drawtext_reinit_value(date[i])
        tm = escape_drawtext_reinit_value(time[i])

        printf("%.6f drawtext@dvdate reinit text=%s\n", start, d)
        printf("%.6f drawtext@dvtime reinit text=%s\n", start, tm)
      }
    }
  ' "$tsv_path" >> "$sendcmd_path"

  local lines timeline_entries expected_lines
  lines=$(/usr/bin/wc -l < "$sendcmd_path" | /usr/bin/tr -d "[:space:]")
  timeline_entries=$(/usr/bin/wc -l < "$tsv_path" | /usr/bin/tr -d "[:space:]")
  expected_lines=$(( timeline_entries * 2 ))

  if [[ "$lines" -ne "$expected_lines" ]]; then
    echo "[WARN] sendcmd row mismatch: expected $expected_lines lines from $timeline_entries entries, got $lines" >&2
  fi

  debug_log "sendcmd lines for $sendcmd_path: $lines (expected: $expected_lines)"

  return 0
}

sanitize_sendcmd_file() {
  local path="$1"

  if [[ ! -f "$path" ]]; then
    echo "[ERROR] sanitize_sendcmd_file: missing file $path" >&2
    return 1
  fi

  local tmp="${path}.tmp"
  LC_ALL=C /usr/bin/awk '
    function rtrim(s) { sub(/[ \t]+$/, "", s); return s }
    {
      line = $0
      gsub(/\r/, "", line)
      line = rtrim(line)
      if (line != "" && line !~ /;$/) {
        line = line ";"
      }
      print line
    }
  ' "$path" > "$tmp"

  if (( ${debug_mode:-0} == 1 )); then
    local bad_lines_path="${path}.bad_semicolons"
    : > "$bad_lines_path"

    local bad_count
    bad_count=$(LC_ALL=C /usr/bin/awk -v bad_out="$bad_lines_path" '
      {
        semicolons = gsub(/;/, "&")
        if (semicolons > 1) {
          bad++
          if (bad <= 5) {
            print $0 >> bad_out
          }
        }
      }
      END { print bad + 0 }
    ' "$tmp")

    if (( bad_count > 0 )); then
      echo "[ERROR] sanitize_sendcmd_file: lines with multiple command terminators: $bad_count" >&2
      while IFS= read -r line; do
        echo "[ERROR] sanitize_sendcmd_file: $line" >&2
      done < "$bad_lines_path"
      /bin/rm -f "$bad_lines_path"
      /bin/rm -f "$tmp"
      return 1
    fi
    /bin/rm -f "$bad_lines_path"
  fi

  if [[ -s "$tmp" ]]; then
    /bin/mv -f "$tmp" "$path"
  else
    /bin/rm -f "$tmp"
  fi

  return 0
}

validate_sendcmd_file() {
  local path="$1"
  if [[ ! -s "$path" ]]; then
    echo "[ERROR] timestamp.cmd is missing or empty: $path" >&2
    return 1
  fi

  local lines
  lines=$(/usr/bin/wc -l < "$path" | /usr/bin/tr -d "[:space:]")
  if (( lines < 1 )); then
    echo "[ERROR] timestamp.cmd has no lines: $path" >&2
    return 1
  fi

  local bad_lines_path="${path:h}/sendcmd.bad_lines.txt"
  log_write "$bad_lines_path"
  : > "$bad_lines_path"

  local bad_count
  bad_count=$(LC_ALL=C /usr/bin/awk -v bad_out="$bad_lines_path" '
    {
      if ($1 !~ /^[0-9]+([.][0-9]+)?$/ || NF < 3) {
        bad++
        if (bad <= 5) {
          print $0 >> bad_out
        }
      }
    }
    END { print bad + 0 }
  ' "$path")

  if (( bad_count > 0 )); then
    echo "[ERROR] timestamp.cmd contains ${bad_count} malformed lines (see $bad_lines_path)" >&2
    return 1
  fi

  debug_log "timestamp.cmd validation succeeded ($lines lines)"
  return 0
}

make_timestamp_cmd() {
  local in="$1"
  local cmdfile="$2"
  local dvrescue_xml="$3"
  local dvrescue_log="$4"
  local timeline_debug="$5"
  local fps="$6"

  if [[ -z "$fps" ]]; then
    echo "[ERROR] FPS missing for make_timestamp_cmd" >&2
    return 1
  fi

  local build_output build_status
  build_output=$({ build_timeline_from_log "$dvrescue_log" "$fps" "$timeline_debug" "$burn_granularity"; } 2>&1)
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
    echo "[ERROR] No RDT rows parsed from dvrescue.log; skipping burn-in per --missing-meta=${missing_meta}" >&2
    return 1
  fi

  if ! build_sendcmd_from_timeline "$timeline_debug" "$cmdfile" "$fps"; then
    echo "[ERROR] Unable to build sendcmd file: $cmdfile" >&2
    return 1
  fi

  if ! sanitize_sendcmd_file "$cmdfile"; then
    echo "[ERROR] Unable to sanitize sendcmd file: $cmdfile" >&2
    return 1
  fi

  log_sendcmd_debug_snapshot "$cmdfile"

  local cmd_lines timeline_lines
  cmd_lines=$(/usr/bin/wc -l < "$cmdfile" | /usr/bin/tr -d '[:space:]')
  timeline_lines=$(/usr/bin/wc -l < "$timeline_debug" | /usr/bin/tr -d '[:space:]')

  if (( cmd_lines != (timeline_lines * 2) )); then
    warn "Unexpected sendcmd line count: expected $(( timeline_lines * 2 )), got $cmd_lines"
  fi

  debug_log "sendcmd lines for $in: $cmd_lines (timeline rows: $timeline_lines)"

  return 0
}

seconds_to_ass_time() {
  local sec="$1"
  if [[ -z "$sec" ]]; then
    echo "0:00:00.00"
    return
  fi

  LC_NUMERIC=C awk -v s="$sec" 'BEGIN {
    if (s < 0) s = 0;
    h = int(s / 3600);
    m = int((s - h*3600) / 60);
    sec = s - h*3600 - m*60;
    printf("%d:%02d:%05.2f", h, m, sec);
  }'
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

  log_write "$ass_out"
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

  cat >> "$ass_out" <<EOF_ASS
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
EOF_ASS


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
