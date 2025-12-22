# logging.zsh

TRAPZERR() {
  local rc=$?

  # funcfiletrace may be unset; guard it
  local where
  if (( ${+funcfiletrace} )); then
    where="${funcfiletrace[1]}"
  else
    where="${(%):-%N}:${LINENO}"
  fi

  local stage="${last_stage_marker-}"
  local cmd="${last_stage_cmd-}"
  print -r -- "[FATAL] (exit=$rc) stage=${stage} cmd=${cmd} | $where" >&2
}

fatal() {
  echo "[ERROR] $*" >&2
  exit 1
}

die() {
  echo "[ERROR] $1" >&2
  exit "${2:-1}"
}

warn() {
  echo "[WARN] $*" >&2
}

info() {
  echo "[INFO] $*" >&2
}

debug() {
  if (( ${debug_mode:-0} == 1 )); then
    echo "[DEBUG] $*" >&2
  fi
  return 0
}

# Lightweight helper for conditional debug output
debug_log() {
  if (( debug_mode == 1 )); then
    echo "[DEBUG] $*" >&2
  fi
}

json_escape() {
  local raw="$1"
  # Escape backslashes first, then double quotes
  raw="${raw//\\/\\\\}"
  raw="${raw//\"/\\\"}"
  echo "$raw"
}

escape_for_single_quotes() {
  local raw="$1"
  raw=${raw//\'/$'\'\\\'\''}
  print -r -- "$raw"
}

log_ffmpeg_command() {
  local label="$1"
  shift
  local -a cmd=("$@")
  echo "[ffmpeg/${label}] ${(q)cmd[@]}" >&2
}

log_export() {
  local src="$1"
  local dst="$2"
  echo "[EXPORT] src='${src}' -> dst='${dst}'" >&2
}

log_write() {
  local path="$1"
  echo "[WRITE] -> $path" >&2
}

log_move() {
  local src="$1"
  local dst="$2"
  echo "[MOVE] $src -> $dst" >&2
}

append_run_note() {
  local msg="$*"
  run_notes+=("$msg")
  if (( ${debug_mode:-0} == 1 )); then
    echo "[DEBUG] [note] $msg" >&2
  fi
  return 0
}

log_stage_marker() {
  local stage="$1"
  last_stage_marker="$stage"
  echo "[STAGE] $stage" >&2
}

run_stage() {
  local stage="$1"
  shift

  last_stage_cmd="$*"
  log_stage_marker "$stage"

  set +e
  "$@"
  local rc=$?
  set -e

  if (( rc != 0 )); then
    echo "[ERROR] ${stage} failed (exit ${rc})" >&2
  fi

  return $rc
}

log_file_excerpt() {
  local label="$1"
  local path="$2"
  local lines="${3:-10}"

  if [[ ! -s "$path" ]]; then
    debug_log "$label: no content at $path"
    return 0
  fi

  debug_log "$label (first ${lines} lines):"
  local head_cmd="/usr/bin/head"
  [[ -x "$head_cmd" ]] || head_cmd="/bin/head"
  "$head_cmd" -n "$lines" "$path" | while IFS= read -r line; do
    debug_log "$line"
  done

  local awk_cmd="/usr/bin/awk"
  [[ -x "$awk_cmd" ]] || awk_cmd="/bin/awk"

  if command -v "$awk_cmd" >/dev/null 2>&1 && command -v "$head_cmd" >/dev/null 2>&1; then
    debug_log "$label first-field preview:"
    "$awk_cmd" '{print $1}' "$path" | "$head_cmd" -n 5 | while IFS= read -r field; do
      debug_log "$label $field"
    done
  fi
}

log_sendcmd_debug_snapshot() {
  local cmd_path="$1"

  if [[ ! -s "$cmd_path" ]]; then
    debug_log "sendcmd snapshot: $cmd_path is empty"
    return 0
  fi

  local head_cmd="/usr/bin/head"
  local tail_cmd="/usr/bin/tail"
  [[ -x "$head_cmd" ]] || head_cmd="/bin/head"
  [[ -x "$tail_cmd" ]] || tail_cmd="/bin/tail"

  debug_log "sendcmd snapshot: $cmd_path (first 10 lines)"
  "$head_cmd" -n 10 "$cmd_path" | while IFS= read -r line; do
    debug_log "sendcmd $line"
  done

  debug_log "sendcmd snapshot: $cmd_path (last 10 lines)"
  "$tail_cmd" -n 10 "$cmd_path" | while IFS= read -r line; do
    debug_log "sendcmd $line"
  done

  if [[ -n "${sendcmd_exec_path:-}" && -s "$sendcmd_exec_path" ]]; then
    debug_log "sendcmd.exec snapshot: $sendcmd_exec_path (first 10 lines)"
    "$head_cmd" -n 10 "$sendcmd_exec_path" | while IFS= read -r line; do
      debug_log "sendcmd.exec $line"
    done
  fi
}
