#!/bin/zsh

set -euo pipefail

script_root="${0:A:h:h}"
lib_root="${script_root}/lib"

if ! source "${lib_root}/timeline.zsh"; then
  echo "[FATAL] Unable to source timeline.zsh" >&2
  exit 1
fi

debug_mode=0

tmpdir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/sendcmd-sanitize.XXXXXX")
cmdfile="${tmpdir}/timestamp.cmd"

printf '%s' \
  '0.000000 drawtext@dvdate reinit text=2024-01-01\r' \
  '0.000000 drawtext@dvtime reinit text=12\\:34\\:56\r\n' \
  '\r\n' \
  '1.000000 drawtext@dvdate reinit text=2024-01-02\r' \
  '1.000000 drawtext@dvtime reinit text=12\\:34\\:57\r\n' \
  '2.000000 drawtext@dvdate reinit text=2024-01-03\r' \
  '2.000000 drawtext@dvtime reinit text=12\\:34\\:58\r' \
  > "$cmdfile"

sanitize_sendcmd_file "$cmdfile"

line_count=$(/usr/bin/wc -l < "$cmdfile" | /usr/bin/tr -d '[:space:]')
if (( line_count < 6 )); then
  echo "[ERROR] sanitize_sendcmd_file produced too few lines: $line_count" >&2
  exit 1
fi

last_char=$(/usr/bin/tail -c 1 "$cmdfile" || true)
if [[ "$last_char" != $'\n' ]]; then
  echo "[ERROR] sanitize_sendcmd_file output missing trailing newline." >&2
  exit 1
fi

echo "[OK] sanitize_sendcmd_file output has $line_count lines and trailing newline."
