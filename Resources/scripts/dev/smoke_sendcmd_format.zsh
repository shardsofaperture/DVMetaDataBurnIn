#!/bin/zsh

set -euo pipefail

script_root="${0:A:h:h}"
lib_root="${script_root}/lib"

if ! source "${lib_root}/env.zsh"; then
  echo "[FATAL] Unable to source env.zsh" >&2
  exit 1
fi
if ! source "${lib_root}/logging.zsh"; then
  echo "[FATAL] Unable to source logging.zsh" >&2
  exit 1
fi
if ! source "${lib_root}/pathing.zsh"; then
  echo "[FATAL] Unable to source pathing.zsh" >&2
  exit 1
fi
if ! source "${lib_root}/filtergraph.zsh"; then
  echo "[FATAL] Unable to source filtergraph.zsh" >&2
  exit 1
fi

ffmpeg_bin="${FFMPEG_BIN:-ffmpeg}"

fontfile=""
if ! fontfile=$(find_font); then
  echo "[ERROR] Unable to locate a font for sendcmd smoke test." >&2
  exit 1
fi

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/sendcmd-smoke.XXXXXX")
cmdfile="${tmpdir}/timestamp.cmd"

cat > "$cmdfile" <<'EOF_CMD'
0.000 drawtext@dvdate reinit text=2003-09-20
0.000 drawtext@dvtime reinit text=12\:34\:56
EOF_CMD

vf=$(build_burnin_filtergraph "single" "$cmdfile" "$fontfile" "off")

cmdfile_exec="${cmdfile}.exec"
if [[ ! -f "$cmdfile_exec" ]]; then
  echo "[ERROR] sendcmd exec file not created: $cmdfile_exec" >&2
  exit 1
fi

line_count=$(/usr/bin/wc -l < "$cmdfile_exec" | /usr/bin/tr -d "[:space:]")
if (( line_count <= 1 )); then
  echo "[ERROR] sendcmd exec file should contain multiple lines: $cmdfile_exec (lines=$line_count)" >&2
  exit 1
fi

last_char=$(/usr/bin/tail -c 1 "$cmdfile_exec" 2>/dev/null || /bin/tail -c 1 "$cmdfile_exec" 2>/dev/null || true)
if [[ "$last_char" != $'\n' ]]; then
  echo "[ERROR] sendcmd exec file missing trailing newline: $cmdfile_exec" >&2
  exit 1
fi

if /usr/bin/grep -qvE '^[[:space:]]*$|^[[:space:]]*#|;[[:space:]]*$' "$cmdfile_exec"; then
  echo "[ERROR] sendcmd exec file has a line without trailing semicolon: $cmdfile_exec" >&2
  exit 1
fi

typeset -a sendcmd_smoke_cmd=(
  "$ffmpeg_bin" -v error
  -f lavfi -i "color=c=black:s=16x16:d=1"
  -vf "$vf"
  -frames:v 1
  -f null -
)

log_ffmpeg_command "sendcmd-smoke" "${sendcmd_smoke_cmd[@]}"
run_sendcmd_smoke_check "sendcmd-smoke" "${sendcmd_smoke_cmd[@]}"
