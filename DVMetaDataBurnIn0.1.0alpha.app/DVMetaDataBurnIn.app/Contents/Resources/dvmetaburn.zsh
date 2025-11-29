#!/bin/zsh

set -euo pipefail
setopt NULL_GLOB

# Ensure zsh temp files go somewhere writable
: "${TMPDIR:=/tmp}"
TMPDIR="${TMPDIR%/}"         # strip trailing slash if any
TMPPREFIX="${TMPDIR}/zsh-"

mkdir -p "$TMPDIR"
# TMPPREFIX is used by zsh for here-doc and other temp files
export TMPDIR TMPPREFIX

# Defaults
mode="single"      # or "batch"
layout="stacked"   # default layout for now
format="mov"       # mov or mp4
fontfile=""          # optional; if empty, we use a hardcoded default for now
ffmpeg_bin="ffmpeg" 
dvrescue_bin="dvrescue"

# Parse flags
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

process_file() {
  local in="$1"

  if [[ ! -f "$in" ]]; then
    echo "Input file not found: $in" >&2
    return 1
  fi

  local base="${in%.*}"
  local out="${base}_dateburn.mov"

  # --- 1) Read rdt from dvrescue ONLY ---

  local raw_rdt_line
  raw_rdt_line=$("$dvrescue_bin" "$in" | grep -m1 'rdt=' || true)
  echo "dvrescue rdt line: $raw_rdt_line"

  local rdt
  rdt=$(echo "$raw_rdt_line" | sed -n 's/.*rdt=\"\([0-9-]* [0-9:]*\)\".*/\1/p')

  if [[ -z "$rdt" ]]; then
    echo "ERROR: Could not extract rdt=\"YYYY-MM-DD HH:MM:SS\" from dvrescue output." >&2
    return 1
  fi

  echo "Using recording datetime: $rdt"

  # --- 2) Parse date + time ---

  # Human-readable date label, e.g. "Nov 12 2025"
  local date_label
  date_label=$(date -j -f "%Y-%m-%d %H:%M:%S" "$rdt" "+%b %d %Y")

  # Time part "HH:MM:SS"
  local hms hh mm ss
  hms="${rdt#* }"
  IFS=':' read -r hh mm ss <<< "$hms"

  # Seconds since midnight (offset for gmtime)
  local offset
  offset=$((10#$hh * 3600 + 10#$mm * 60 + 10#$ss))

  echo "Date label: $date_label"
  echo "Seconds since midnight: $offset"

  # --- 3) Build ffmpeg filter: stacked bottom-right, NO BAR ---

local font

if [[ -n "$fontfile" ]]; then
  font="$fontfile"
else
  # Fallback for now – your current hardcoded path
  font="/Users/zach/Library/Fonts/UAV-OSD-Mono.ttf"
fi

local vf

case "$layout" in
  stacked)

    vf="drawtext=fontfile='${font}':text='${date_label}':fontcolor=white:fontsize=24:x=w-tw-20:y=h-60,\
drawtext=fontfile='${font}':text='%{pts\:gmtime\:${offset}\:%r}':fontcolor=white:fontsize=24:x=w-tw-20:y=h-30"
    ;;

  single)
 
	vf="drawtext=fontfile='${font}':text='${date_label}':fontcolor=white:fontsize=24:x=40:y=h-30,\
drawtext=fontfile='${font}':text='%{pts\:gmtime\:${offset}\:%r}':fontcolor=white:fontsize=24:x=w-tw-40:y=h-30"
    ;;

  *)
    echo "Unknown layout: $layout" >&2
    return 1
    ;;
esac


# --- 4) Encode according to format ---

# Build codec args based on format
local codec_args
local out_ext="$format"

case "$format" in
  mov)
    # DV in a MOV container, audio copied 1:1
    codec_args=(-c:v dvvideo -c:a copy)
    ;;
  mp4)
    # Very safe MP4 path: MPEG-4 video + AAC audio
    # (mpeg4 is always available, unlike libx264 on some builds)
    codec_args=(-c:v mpeg4 -qscale:v 2 -c:a aac -b:a 192k)
    ;;
  *)
    echo "Unknown format: $format" >&2
    return 1
    ;;
esac

# Final ffmpeg call (overwrite if exists, and expose exit code)
"$ffmpeg_bin" -y -i "$in" \
  -vf "$vf" \
  "${codec_args[@]}" \
  "${base}_dateburn.${out_ext}"

local ec=$?
echo "ffmpeg exit code: $ec"
return $ec

}

# --- CLI wrapper ---

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
