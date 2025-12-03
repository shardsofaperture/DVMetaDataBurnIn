#!/bin/zsh

set -euo pipefail
setopt NULL_GLOB

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
burn_mode="burnin"   # "burnin" or "passthrough"
fontfile=""
ffmpeg_bin="ffmpeg"
dvrescue_bin="dvrescue"

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
    --ffmpeg=*)
      ffmpeg_bin="${1#*=}"
      shift
      ;;
    --dvrescue=*)
      dvrescue_bin="${1#*=}"
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

########################################################
# Helper: seconds (float) -> ASS time H:MM:SS.cc
########################################################

seconds_to_ass_time() {
  local sec="$1"
  local -F s h m fsec

  s="$sec"
  if (( s < 0 )); then
    s=0
  fi

  h=$(( int(s/3600.0) ))
  m=$(( int((s - h*3600.0)/60.0) ))
  fsec=$(( s - h*3600.0 - m*60.0 ))

  printf "%d:%02d:%05.2f" "$h" "$m" "$fsec"
}

########################################################
# Helper: build sendcmd file (normalized monotonic timeline)
########################################################

make_timestamp_cmd() {
  local in="$1"
  local cmdfile="$2"

  local json_base json_file
  json_base="$(mktemp "${TMPDIR}/dvts-XXXXXX")"
  json_file="${json_base}.json"

  "$dvrescue_bin" "$in" -json "$json_file" >/dev/null 2>&1 || true

  : > "$cmdfile"

  if [[ ! -s "$json_file" ]]; then
    echo "[WARN] Timestamp JSON missing for $in" >&2
    rm -f "$json_file"
    return 1
  fi

  local -F prev_pts=-1 prev_mono=0 offset=0 last_delta=0
  local prev_dt=""
  local had_lines=0

  while IFS=$'\t' read -r raw_pts raw_rdt; do
    [[ -z "$raw_pts" || -z "$raw_rdt" ]] && continue

    # Convert pts to floating seconds
    local -F pts_sec base_seconds=0
    if [[ "$raw_pts" == *:* ]]; then
      local h m s frac="0"
      h="${raw_pts%%:*}"
      m="${raw_pts#*:}"
      m="${m%%:*}"
      s="${raw_pts##*:}"
      if [[ "$s" == *.* ]]; then
        frac="${s#*.}"
        s="${s%%.*}"
      fi

      base_seconds=$((10#$h * 3600 + 10#$m * 60 + 10#$s))
      pts_sec=$base_seconds

      if [[ -n "$frac" && "$frac" != "0" ]]; then
        local -F frac_val
        frac_val="0.${frac}"
        pts_sec=$((pts_sec + frac_val))
      fi
    else
      pts_sec=$raw_pts
    fi

    # Normalize pts into a monotonic mono timeline
    if (( prev_pts >= 0 )); then
      local -F delta=0
      delta=$((pts_sec - prev_pts))
      if (( delta > 0 )); then
        last_delta=$delta
      fi

      if (( pts_sec < prev_pts )); then
        local -F step
        step=$last_delta
        if (( step <= 0 )); then
          step=0.0333667  # ~1/29.97
        fi
        offset=$((prev_mono + step - pts_sec))
      fi
    fi

    local -F mono
    mono=$((pts_sec + offset))

    # Split RDT into date + time
    local date_part time_part
    if [[ "$raw_rdt" == *" "* ]]; then
      date_part="${raw_rdt%% *}"
      time_part="${raw_rdt#* }"
    else
      continue
    fi

    time_part="${time_part%%.*}"
    local esc_time="${time_part//:/\\:}"
    local dt_key="${date_part} ${time_part}"

    if [[ "$dt_key" != "$prev_dt" ]]; then
      printf "%0.6f drawtext@dvdate reinit text=%s;\n" "$mono" "$date_part" >> "$cmdfile"
      printf "%0.6f drawtext@dvtime reinit text=%s;\n" "$mono" "$esc_time" >> "$cmdfile"
      prev_dt="$dt_key"
      had_lines=1
    fi

    prev_pts=$pts_sec
    prev_mono=$mono
  done < <(
    "$jq_bin" -r '
      def frames:
        if type == "object" then
          (if ((.pts? // .pts_time?) != null and (.rdt? // "") != "") then [.] else [] end)
          + ([to_entries[]? | .value] | map(frames) | add // [])
        elif type == "array" then
          (map(frames) | add // [])
        else [] end;

      frames[] | [.pts_time // .pts, .rdt] | @tsv
    ' "$json_file"
  )

  rm -f "$json_file"

  if (( had_lines == 0 )); then
    echo "[WARN] No per-frame RDT metadata found for $in" >&2
    return 2   # special code: no metadata
  fi

  return 0
}

########################################################
# Helper: build ASS subtitles file from same timeline
########################################################

make_ass_subs() {
  local in="$1"
  local layout="$2"
  local ass_out="$3"

  local json_base json_file
  json_base="$(mktemp "${TMPDIR}/dvts-XXXXXX")"
  json_file="${json_base}.json"

  "$dvrescue_bin" "$in" -json "$json_file" >/dev/null 2>&1 || true

  if [[ ! -s "$json_file" ]]; then
    echo "[WARN] Subtitle JSON missing for $in" >&2
    rm -f "$json_file"
    return 1
  fi

  : > "$ass_out"

  cat >> "$ass_out" << 'EOF'
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
Style: DVOSD,UAV-OSD-Mono,24,&H00FFFFFF,&H00000000,&H00000000,&H64000000,-1,0,0,0,100,100,0,0,1,1,0,2,20,20,20,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
EOF

  local -F prev_pts=-1 prev_mono=-1 offset=0 last_delta=0
  local prev_dt="" prev_date="" prev_time=""
  local had_lines=0

  write_dialog() {
    local start_sec="$1"
    local end_sec="$2"
    local date_part="$3"
    local time_part="$4"
    local layout="$5"

    local start_str end_str
    start_str="$(seconds_to_ass_time "$start_sec")"
    end_str="$(seconds_to_ass_time "$end_sec")"

    local text
    case "$layout" in
      stacked)
        text="${date_part}\\N${time_part}"
        ;;
      single)
        text="${date_part}  ${time_part}"
        ;;
      *)
        text="${date_part}\\N${time_part}"
        ;;
    esac

    printf "Dialogue: 0,%s,%s,DVOSD,,0,0,20,,%s\n" \
      "$start_str" "$end_str" "$text" >> "$ass_out"
  }

  while IFS=$'\t' read -r raw_pts raw_rdt; do
    [[ -z "$raw_pts" || -z "$raw_rdt" ]] && continue

    local -F pts_sec base_seconds=0
    if [[ "$raw_pts" == *:* ]]; then
      local h m s frac="0"
      h="${raw_pts%%:*}"
      m="${raw_pts#*:}"
      m="${m%%:*}"
      s="${raw_pts##*:}"
      if [[ "$s" == *.* ]]; then
        frac="${s#*.}"
        s="${s%%.*}"
      fi

      base_seconds=$((10#$h * 3600 + 10#$m * 60 + 10#$s))
      pts_sec=$base_seconds

      if [[ -n "$frac" && "$frac" != "0" ]]; then
        local -F frac_val
        frac_val="0.${frac}"
        pts_sec=$((pts_sec + frac_val))
      fi
    else
      pts_sec=$raw_pts
    fi

    if (( prev_pts >= 0 )); then
      local -F delta=0
      delta=$((pts_sec - prev_pts))
      if (( delta > 0 )); then
        last_delta=$delta
      fi

      if (( pts_sec < prev_pts )); then
        local -F step
        step=$last_delta
        if (( step <= 0 )); then
          step=0.0333667
        fi
        offset=$((prev_mono + step - pts_sec))
      fi
    fi

    local -F mono
    mono=$((pts_sec + offset))

    local date_part time_part
    if [[ "$raw_rdt" == *" "* ]]; then
      date_part="${raw_rdt%% *}"
      time_part="${raw_rdt#* }"
    else
      continue
    fi

    time_part="${time_part%%.*}"
    local dt_key="${date_part} ${time_part}"

    if [[ "$dt_key" != "$prev_dt" ]]; then
      if (( prev_mono >= 0 )); then
        write_dialog "$prev_mono" "$mono" "$prev_date" "$prev_time" "$layout"
      fi
      prev_dt="$dt_key"
      prev_date="$date_part"
      prev_time="$time_part"
      prev_mono="$mono"
      had_lines=1
    fi

    prev_pts=$pts_sec
  done < <(
    "$jq_bin" -r '
      def frames:
        if type == "object" then
          (if ((.pts? // .pts_time?) != null and (.rdt? // "") != "") then [.] else [] end)
          + ([to_entries[]? | .value] | map(frames) | add // [])
        elif type == "array" then
          (map(frames) | add // [])
        else [] end;

      frames[] | [.pts_time // .pts, .rdt] | @tsv
    ' "$json_file"
  )

  if (( prev_mono >= 0 )); then
    local -F end_sec
    end_sec=$((prev_mono + 1.0))
    write_dialog "$prev_mono" "$end_sec" "$prev_date" "$prev_time" "$layout"
  fi

  rm -f "$json_file"

  if (( had_lines == 0 )); then
    echo "[WARN] No per-frame RDT metadata found for subtitles for $in" >&2
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

  # Passthrough = convert only, no burn-in, no subs
  if [[ "$burn_mode" == "passthrough" ]]; then
    local out_passthrough="${base}_conv.${out_ext}"
    echo "[INFO] Passthrough conversion (no burn-in) to: $out_passthrough"
    "$ffmpeg_bin" -y -i "$in" \
      "${codec_args[@]}" \
      "$out_passthrough"
    return $?
  fi

  # Otherwise: full burn-in + subtitle generation

  local cmdfile
  cmdfile="$(mktemp "${TMPDIR}/dvts-XXXXXX.cmd")"
  if ! make_timestamp_cmd "$in" "$cmdfile"; then
    echo "[ERROR] Failed to build timestamp command file for $in" >&2
    rm -f "$cmdfile"
    return 1
  fi

  # ASS subtitles: non-fatal if missing
  local ass_out="${base}_dvmeta_${layout}.ass"
  if ! make_ass_subs "$in" "$layout" "$ass_out"; then
    echo "[WARN] Failed to build ASS subtitles for $in" >&2
  else
    echo "[INFO] Wrote subtitles: $ass_out"
  fi

  local font
  if ! font="$(find_font)"; then
    echo "[ERROR] Unable to locate a usable font. Provide --fontfile, set DVMETABURN_FONTFILE, or place a supported font in Resources/fonts/." >&2
    rm -f "$cmdfile"
    return 1
  fi

  local vf
  case "$layout" in
    stacked)
      vf="sendcmd=f='${cmdfile}',\
drawtext=fontfile='${font}':text='':fontcolor=white:fontsize=24:x=w-tw-20:y=h-60:@dvdate,\
drawtext=fontfile='${font}':text='':fontcolor=white:fontsize=24:x=w-tw-20:y=h-30:@dvtime"
      ;;
    single)
      vf="sendcmd=f='${cmdfile}',\
drawtext=fontfile='${font}':text='':fontcolor=white:fontsize=24:x=40:y=h-30:@dvdate,\
drawtext=fontfile='${font}':text='':fontcolor=white:fontsize=24:x=w-tw-40:y=h-30:@dvtime"
      ;;
    *)
      echo "Unknown layout: $layout" >&2
      rm -f "$cmdfile"
      return 1
      ;;
  esac

  local out="${base}_dateburn.${out_ext}"

  echo "[INFO] Burning DV metadata into: $out"
  "$ffmpeg_bin" -y -i "$in" \
    -vf "$vf" \
    "${codec_args[@]}" \
    "$out"

  local ec=$?
  rm -f "$cmdfile"
  echo "ffmpeg exit code: $ec"
  return $ec
}

########################################################
# Mode routing
########################################################

if [[ "$mode" == "single" ]]; then
  if [[ $# -ne 1 ]]; then
    echo "Usage: $0 [--mode=single] [--layout=stacked|single] [--format=mov|mp4] [--burn-mode=burnin|passthrough] /path/to/clip.avi" >&2
    exit 1
  fi
  process_file "$1"
  exit $?
fi

if [[ "$mode" == "batch" ]]; then
  if [[ $# -ne 1 ]]; then
    echo "Usage: $0 --mode=batch [--layout=stacked|single] [--format=mov|mp4] [--burn-mode=burnin|passthrough] /path/to/folder" >&2
    exit 1
  fi

  local folder="$1"

  if [[ ! -d "$folder" ]]; then
    echo "ERROR: $folder is not a folder" >&2
    exit 1
  fi

  echo "Batch mode: scanning $folder"
  local f
  for f in "$folder"/*.{avi,AVI,dv,DV}; do
    [[ -f "$f" ]] || continue
    echo "Processing $f"
    process_file "$f"
  done

  exit 0
fi

echo "ERROR: Unknown mode: $mode" >&2
exit 1
