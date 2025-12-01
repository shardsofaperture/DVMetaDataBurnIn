#!/bin/zsh

set -euo pipefail
setopt NULL_GLOB

# Ensure zsh temp files go somewhere writable
: "${TMPDIR:=/tmp}"
TMPDIR="${TMPDIR%/}"
TMPPREFIX="${TMPDIR}/zsh-"

mkdir -p "$TMPDIR"
export TMPDIR TMPPREFIX

# Defaults
mode="single"          # "single" or "batch"
layout="stacked"       # "stacked" or "single"
format="mov"           # "mov" or "mp4"
fontfile=""
ffmpeg_bin="ffmpeg"
dvrescue_bin="dvrescue"

burn_mode="burnin"             # "burnin" or "passthrough"
missing_meta="error"           # "error" | "skip_burnin_convert" | "skip_file"

# Parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode=*)         mode="${1#*=}"; shift;;
    --layout=*)       layout="${1#*=}"; shift;;
    --format=*)       format="${1#*=}"; shift;;
    --fontfile=*)     fontfile="${1#*=}"; shift;;
    --ffmpeg=*)       ffmpeg_bin="${1#*=}"; shift;;
    --dvrescue=*)     dvrescue_bin="${1#*=}"; shift;;
    --burn-mode=*)    burn_mode="${1#*=}"; shift;;
    --missing-meta=*) missing_meta="${1#*=}"; shift;;
    --)               shift; break;;
    -*)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

make_timestamp_cmd() {
  local in="$1"
  local cmdfile="$2"

  "$dvrescue_bin" "$in" 2>/dev/null | \
  awk '
    /<frame / && /pts="/ && /rdt="/ {
      line = $0

      # Extract pts="..."
      pts = line
      sub(/.*pts="/, "", pts)
      sub(/".*/, "", pts)

      # Extract rdt="YYYY-MM-DD HH:MM:SS"
      rdt = line
      sub(/.*rdt="/, "", rdt)
      sub(/".*/, "", rdt)

      print pts, rdt
    }
  ' | \
  awk '
    function tosec(pts,   parts,h,m,s) {
      split(pts, parts, ":")
      h = parts[1] + 0
      m = parts[2] + 0
      s = parts[3] + 0
      return h*3600 + m*60 + s
    }

    {
      pts  = $1
      date = $2
      time = $3
      dt   = date " " time

      if (dt != prev) {
        sec = tosec(pts)

        # Escape colons in time for drawtext (HH\:MM\:SS)
        t = time
        gsub(":", "\\\\:", t)

        # Two commands, no quotes:
        # 0.000000 drawtext@dvdate reinit text=YYYY-MM-DD;
        # 0.000000 drawtext@dvtime reinit text=HH\:MM\:SS;
        printf("%f drawtext@dvdate reinit text=%s;\n", sec, date)
        printf("%f drawtext@dvtime reinit text=%s;\n", sec, t)

        prev = dt
      }
    }
  ' > "$cmdfile"
}






process_file() {
  local in="$1"

  if [[ ! -f "$in" ]]; then
    echo "Input file not found: $in" >&2
    return 1
  fi

  local base="${in%.*}"
  local out_ext="$format"

  # --- codec args used for both burn-in and passthrough ---
  local -a codec_args
  case "$format" in
    mov)
      # DV in MOV container, audio copied 1:1
      codec_args=(-c:v dvvideo -c:a copy)
      ;;
    mp4)
      # Web-ready H.264 MP4, close to DV (720x480, interlaced, AAC)
      codec_args=(
        -c:v libx264
        -preset slow
        -crf 18
        -pix_fmt yuv420p
        -flags +ildct+ilme
        -c:a aac
        -b:a 192k
      )
      ;;
    *)
      echo "Unknown format: $format" >&2
      return 1
      ;;
  esac

  #####################################
  # 0) PASSTHROUGH MODE (no metadata) #
  #####################################
  if [[ "$burn_mode" == "passthrough" ]]; then
    echo "[INFO] Passthrough only (no burn-in) for: $in"

    local ec
    {
      "$ffmpeg_bin" -hide_banner -loglevel info -y -i "$in" \
        "${codec_args[@]}" \
        "${base}_conv.${out_ext}" 2>&1 \
        | grep -v 'Concealing bitstream errors' || true

      ec=${pipestatus[1]}
    }

    echo "ffmpeg exit code: $ec"
    return $ec
  fi

  ###############################################
  # 1) Try dvrescue JSON, then fall back to text
  ###############################################

  local rdt=""
  local json_base json

  # mktemp template must end with XXXXXX – no suffix after it
  json_base="$(mktemp "${TMPDIR}/dvmeta-XXXXXX")"
  json="${json_base}.json"

  # Try JSON mode first; ignore dvrescue exit code
  "$dvrescue_bin" "$in" -json "$json" >/dev/null 2>&1 || true

  if [[ -s "$json" ]]; then
    rdt=$(
      grep '"rdt"' "$json" | head -n1 | \
        sed -E 's/.*"rdt":"([^"]+)".*/\1/'
    )
  else
    echo "[WARN] dvrescue JSON is empty or missing for $in"
  fi

  rm -f "$json"

  # If JSON didn't give us an rdt, fall back to plain text output
  if [[ -z "$rdt" ]]; then
    echo "[INFO] Falling back to text dvrescue output for rdt."
    local raw_rdt_line
    raw_rdt_line=$("$dvrescue_bin" "$in" | grep -m1 'rdt=' || true)
    echo "dvrescue rdt line: $raw_rdt_line"
    rdt=$(echo "$raw_rdt_line" | sed -n 's/.*rdt=\"\([0-9-]* [0-9:]*\)\".*/\1/p')
  fi

  # Still nothing? Then apply missing_meta behavior.
  if [[ -z "$rdt" ]]; then
    echo "[WARN] No rdt metadata found in this DV file: $in"

    case "$missing_meta" in
      error)
        echo "[ERROR] Stopping because metadata missing."
        return 1
        ;;
      skip_file)
        echo "[INFO] Skipping file due to missing metadata."
        return 0
        ;;
      skip_burnin_convert)
        echo "[INFO] Converting WITHOUT burn-in (no metadata)."

        local ec
        {
          "$ffmpeg_bin" -hide_banner -loglevel info -y -i "$in" \
            "${codec_args[@]}" \
            "${base}_conv.${out_ext}" 2>&1 \
            | grep -v 'Concealing bitstream errors' || true

          ec=${pipestatus[1]}
        }

        echo "ffmpeg exit code: $ec"
        return $ec
        ;;
      *)
        echo "[ERROR] Unknown missing_meta mode: $missing_meta" >&2
        return 1
        ;;
    esac
  fi

  echo "Using recording datetime: $rdt"
  ###############################################################
  # 2 Build per-clip sendcmd file with frame-accurate DV date/time #
  ###############################################################
  local ts_cmd_base ts_cmd_file
  ts_cmd_base="$(mktemp "${TMPDIR}/dvts-XXXXXX")"
  ts_cmd_file="${ts_cmd_base}.cmd"

  make_timestamp_cmd "$in" "$ts_cmd_file"

  if [[ ! -s "$ts_cmd_file" ]]; then
    echo "[WARN] Timestamp command file is empty – treating as missing metadata."

    case "$missing_meta" in
      error)
        echo "[ERROR] Stopping because metadata missing."
        rm -f "$ts_cmd_file"
        return 1
        ;;
      skip_file)
        echo "[INFO] Skipping file due to missing metadata."
        rm -f "$ts_cmd_file"
        return 0
        ;;
      skip_burnin_convert)
        echo "[INFO] Converting WITHOUT burn-in (no metadata)."

        local ec
        {
          "$ffmpeg_bin" -hide_banner -loglevel info -y -i "$in" \
            "${codec_args[@]}" \
            "${base}_conv.${out_ext}" 2>&1 \
            | grep -v 'Concealing bitstream errors' || true

          ec=${pipestatus[1]}
        }

        echo "ffmpeg exit code: $ec"
        rm -f "$ts_cmd_file"
        return $ec
        ;;
    esac
  fi

  
  ###############################################
  # 2) Build date label + offset from midnight  #
  ###############################################
 # ###Commenting out while working on actual RDT ####
 #
 # local date_label
 # date_label=$(date -j -f "%Y-%m-%d %H:%M:%S" "$rdt" "+%b %d %Y")
 #
  #local hms hh mm ss
  #hms="${rdt#* }"
  #IFS=':' read -r hh mm ss <<< "$hms"
 #
 # local offset
 # offset=$((10#$hh * 3600 + 10#$mm * 60 + 10#$ss))
 #
 # echo "Date label: $date_label"
 # echo "Seconds since midnight: $offset"
#
  ###############################################
  # 3) Build ffmpeg drawtext filter             #
  ###############################################

  local font
  if [[ -n "$fontfile" ]]; then
    font="$fontfile"
  else
    font="/Users/zach/Library/Fonts/UAV-OSD-Mono.ttf"
  fi

  local vf
  case "$layout" in
    stacked)
      # Bottom-right, date over time (DV-style)
      vf="sendcmd=f='${ts_cmd_file}',"\
"drawtext@dvdate=fontfile='${font}':"\
"text='0000-00-00':"\
"fontcolor=white:fontsize=24:"\
"x=w-tw-20:y=h-60,"\
"drawtext@dvtime=fontfile='${font}':"\
"text='000000':"\
"fontcolor=white:fontsize=24:"\
"x=w-tw-20:y=h-30"
      ;;
    single)
      # Bottom bar: date left, time right
      vf="sendcmd=f='${ts_cmd_file}',"\
"drawtext@dvdate=fontfile='${font}':"\
"text='0000-00-00':"\
"fontcolor=white:fontsize=24:"\
"x=40:y=h-30,"\
"drawtext@dvtime=fontfile='${font}':"\
"text='000000':"\
"fontcolor=white:fontsize=24:"\
"x=w-tw-20:y=h-30"
      ;;
    *)
      echo "Unknown layout: $layout" >&2
      rm -f "$ts_cmd_file"
      return 1
      ;;
  esac






  ###############################################
  # 4) Final ffmpeg call with burn-in           #
  ###############################################

  # FIX 2: actually use -vf "$vf" and name output _dateburn
 local ec
  {
    "$ffmpeg_bin" -hide_banner -loglevel info -y -i "$in" \
      -vf "$vf" \
      "${codec_args[@]}" \
      "${base}_dateburn.${out_ext}" 2>&1 \
      | grep -v 'Concealing bitstream errors' || true

    ec=${pipestatus[1]}
  }

  echo "ffmpeg exit code: $ec"
  return $ec
}

# --- Mode routing ---

if [[ "$mode" == "single" ]]; then
  if [[ $# -ne 1 ]]; then
    echo "Usage: $0 [--mode=single] /path/to/clip.avi" >&2
    exit 1
  fi
  process_file "$1"
  exit $?
fi

if [[ "$mode" == "batch" ]]; then
  if [[ $# -ne 1 ]]; then
    echo "Usage: $0 --mode=batch /path/to/folder" >&2
    exit 1
  fi

  folder="$1"

  if [[ ! -d "$folder" ]]; then
    echo "ERROR: $folder is not a folder" >&2
    exit 1
  fi

  echo "Batch mode: scanning $folder"
  for f in "$folder"/*.{avi,AVI,dv,DV}; do
    [[ -f "$f" ]] || continue
    echo "Processing $f"
    process_file "$f"
  done

  exit 0
fi

echo "ERROR: Unknown mode: $mode" >&2
exit 1
