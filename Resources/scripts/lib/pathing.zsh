# pathing.zsh

# Escape the option-value grammar, then the enclosing filtergraph grammar.
# Process arguments are passed directly; there is no shell-quoting layer.
escape_filter_value() {
  local value="$1" escaped="" char
  local -i i
  for (( i=1; i<=${#value}; i++ )); do
    char="${value[i]}"
    [[ "$char" == [\\\':] ]] && escaped+='\'
    escaped+="$char"
  done
  value="$escaped"
  escaped=""
  for (( i=1; i<=${#value}; i++ )); do
    char="${value[i]}"
    [[ "$char" == [\\\'\,\[\]\;] ]] && escaped+='\'
    escaped+="$char"
  done
  print -r -- "$escaped"
}

probe_media_duration() {
  local file_path="$1"
  if [[ -z "$file_path" || ! -f "$file_path" ]]; then
    return 1
  fi

  local duration_line
  duration_line=$("$ffmpeg_bin" -hide_banner -i "$file_path" 2>&1 || true)
  duration_line=$(printf "%s\n" "$duration_line" | awk -F',' '/Duration:/ {gsub(/Duration: /,"",$1); print $1; exit}')

  [[ -n "$duration_line" ]] || return 1
  echo "$duration_line"
}

make_temp_file() {
  local prefix="$1"
  local suffix="$2"

  local tmpdir="${TMPDIR:-/tmp}"
  local template="${tmpdir%/}/${prefix}.XXXXXX${suffix}"

  local tmpfile
  if ! tmpfile=$(mktemp "$template" 2>/dev/null); then
    echo "[ERROR] Unable to create temp file with template: $template" >&2
    return 1
  fi

  print -r -- "$tmpfile"
}

validate_and_plan_file() {
  local in="$1"
  local base_override="${2:-}"
  local output_dir_override="${3:-}"

  if [[ ! -f "$in" ]]; then
    echo "[ERROR] Input file not found: $in" >&2
    return 1
  fi

  local output_dir base base_name out_ext

  if [[ "$output_mode" == "audio" ]]; then
    out_ext="$(audio_extension_for_format "$format")"
  else
    out_ext="$format"
  fi
  if [[ -n "$base_override" ]]; then
    base_name="$base_override"
  else
    base_name="${in:t:r}"
  fi

  if [[ -n "$output_dir_override" ]]; then
    output_dir="${output_dir_override%/}"
  elif [[ -n "$dest_dir" ]]; then
    output_dir="${dest_dir%/}"
  else
    output_dir="${in:h}"
  fi

  base="${output_dir}/${base_name}"

  reply=("$output_dir" "$base" "$base_name" "$out_ext")
  return 0
}

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
  local script_dir="${script_root%/}"
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
      print -r -- "$candidate"
      return 0
    fi
  done

  return 1
}
