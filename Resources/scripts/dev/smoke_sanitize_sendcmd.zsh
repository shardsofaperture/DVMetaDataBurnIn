#!/bin/zsh

set -euo pipefail

script_root="${0:A:h:h}"
lib_root="${script_root}/lib"

if ! source "${lib_root}/timeline.zsh"; then
  echo "[FATAL] Unable to source timeline.zsh" >&2
  exit 1
fi
if ! source "${lib_root}/pathing.zsh"; then
  echo "[FATAL] Unable to source pathing.zsh" >&2
  exit 1
fi

debug_mode=0

tmpdir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/sendcmd-sanitize.XXXXXX")
cmdfile="${tmpdir}/timestamp.cmd"

printf '%s' \
  $'\xEF\xBB\xBF0.000000 drawtext@dvdate reinit text=2024-01-01\r' \
  $'0.000000 drawtext@dvtime reinit text=12\\:34\\:56\r\n' \
  $'\r\n' \
  $'# comment line should be ignored\r\n' \
  $'1.000000 drawtext@dvdate reinit text=2024-01-02   \r' \
  $'1.000000 drawtext@dvtime reinit text=12\\:34\\:57\r\n' \
  $'2.000000 drawtext@dvdate reinit text=2024-01-03\r' \
  $'2.000000 drawtext@dvtime reinit text=12\\:34\\:58\r' \
  > "$cmdfile"

sanitize_sendcmd_file "$cmdfile"

if ! validate_sendcmd_file "$cmdfile"; then
  echo "[ERROR] validate_sendcmd_file failed on sanitized output." >&2
  exit 1
fi

line_count=$(sendcmd_effective_line_count "$cmdfile")
expected_lines=6
if (( line_count != expected_lines )); then
  echo "[ERROR] sanitize_sendcmd_file produced unexpected line count: $line_count (expected $expected_lines)" >&2
  exit 1
fi
if (( line_count <= 1 )); then
  echo "[ERROR] sanitize_sendcmd_file produced too few lines: $line_count" >&2
  exit 1
fi

last_char=$(/usr/bin/tail -c 1 "$cmdfile" || true)
if [[ "$last_char" != $'\n' ]]; then
  echo "[ERROR] sanitize_sendcmd_file output missing trailing newline." >&2
  exit 1
fi

if /usr/bin/grep -q ';' "$cmdfile"; then
  echo "[ERROR] sanitize_sendcmd_file output contains semicolons." >&2
  exit 1
fi

ffmpeg_bin="${FFMPEG_BIN:-ffmpeg}"
if command -v "$ffmpeg_bin" >/dev/null 2>&1; then
  if fontfile=$(find_font); then
    cmdfile_safe=$(printf "%s" "$cmdfile" | /usr/bin/sed -e 's/\\/\\\\/g' -e 's/:/\\\:/g')
    fontfile_safe=$(printf "%s" "$fontfile" | /usr/bin/sed -e 's/\\/\\\\/g' -e 's/:/\\\:/g')
    vf="sendcmd=f='${cmdfile_safe}',drawtext@dvdate=fontfile='${fontfile_safe}':fontsize=12:fontcolor=white:x=0:y=0:text=''"
    if ! "$ffmpeg_bin" -v error -f lavfi -i "color=c=black:s=16x16:d=1" -vf "$vf" -frames:v 1 -f null -; then
      echo "[ERROR] ffmpeg sendcmd smoke run failed." >&2
      exit 1
    fi
  else
    echo "[WARN] Skipping ffmpeg sendcmd smoke run (font not found)." >&2
  fi
else
  echo "[WARN] Skipping ffmpeg sendcmd smoke run (ffmpeg not found)." >&2
fi

echo "[OK] sanitize_sendcmd_file output has $line_count lines, no semicolons, and trailing newline."
