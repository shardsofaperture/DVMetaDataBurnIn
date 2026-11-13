# cleanup.zsh

initialize_run_workspace() {
  local workspace_base
  if [[ -n "${DVMETA_WORKSPACE:-}" ]]; then
    run_scratch_root="$DVMETA_WORKSPACE"
    workspace_token="${DVMETA_WORKSPACE_TOKEN:-}"
  else
    if [[ -n "$scratch_dir" ]]; then
      workspace_base="${scratch_dir%/}/DVMetaDataBurnIn"
    else
      workspace_base="${HOME}/Library/Logs/DVMeta"
    fi
    mkdir -p -- "$workspace_base" || return 1
    run_scratch_root=$(mktemp -d "${workspace_base%/}/run.XXXXXXXX") || return 1
    workspace_token="${run_scratch_root:t}:$$"
    print -rn -- "$workspace_token" > "$run_scratch_root/.dvmeta-owner"
  fi

  [[ -n "$workspace_token" && -d "$run_scratch_root" && ! -L "$run_scratch_root" &&
     "${run_scratch_root:t}" == run.* && -f "$run_scratch_root/.dvmeta-owner" &&
     ! -L "$run_scratch_root/.dvmeta-owner" &&
     "$(<"$run_scratch_root/.dvmeta-owner")" == "$workspace_token" ]] || return 1
  run_scratch_root="${run_scratch_root:A}"
  typeset -gr owned_scratch_root="$run_scratch_root"
  typeset -gr owned_workspace_token="$workspace_token"
  typeset -g run_had_failure=0 active_child_pid=""
  typeset -ga output_stage_dirs=()
  # Keep the original inputs and destination available to the deletion guard.
  typeset -ga protected_run_paths=("$@" "${dest_dir:-}" "${stitch_input_list:-}")
  if [[ -n "${stitch_input_list:-}" && -f "$stitch_input_list" ]]; then
    local protected_input
    while IFS= read -r protected_input || [[ -n "$protected_input" ]]; do
      [[ -n "$protected_input" ]] && protected_run_paths+=("$protected_input")
    done < "$stitch_input_list"
  fi


  artifact_root="$run_scratch_root/artifacts"
  TMPDIR="$run_scratch_root/tmp"
  TMPPREFIX="$TMPDIR/zsh-"
  mkdir -p -- "$artifact_root" "$TMPDIR" || return 1
  export TMPDIR TMPPREFIX
  info "[scratch] Using scratch root: $run_scratch_root"
  append_run_note "Scratch root: $run_scratch_root"
}

workspace_is_owned() {
  local root="${run_scratch_root:-}"
  [[ -n "$root" && "$root" == "${owned_scratch_root:-}" && "$root" != / &&
     ! -L "$root" && "${root:A}" == "$root" && -d "$root" &&
     ! -L "$root/.dvmeta-owner" && -f "$root/.dvmeta-owner" &&
     "$(<"$root/.dvmeta-owner")" == "${owned_workspace_token:-}" ]] || return 1
  local protected resolved
  for protected in "${protected_run_paths[@]}" "${primary_input_path:-}" "${dest_dir:-}"; do
    [[ -n "$protected" ]] || continue
    resolved="${protected:A}"
    if [[ "$resolved" == "$root" || "$resolved" == "$root/"* ]]; then
      warn "[cleanup] Workspace contains an input or destination; preserving it: $root"
      return 1
    fi
  done
}

# Background only the actual child, so a signal can interrupt wait, stop that
# child, and reap it before removing its workspace. Never signal other jobs.
run_owned_command() {
  "$@" &
  active_child_pid=$!
  local rc=0
  wait "$active_child_pid" || rc=$?
  active_child_pid=""
  return "$rc"
}

cancel_run_workspace() {
  local rc="$1"
  if [[ -n "${active_child_pid:-}" ]]; then
    kill -TERM "$active_child_pid" 2>/dev/null || true
    wait "$active_child_pid" 2>/dev/null || true
    active_child_pid=""
  fi
  exit "$rc"
}

exit_run_workspace() {
  local rc="$1" status_label=success
  trap - EXIT
  (( rc != 0 || run_had_failure != 0 )) && status_label=failure
  local stage_dir
  for stage_dir in "${output_stage_dirs[@]}"; do
    [[ -d "$stage_dir" && ! -L "$stage_dir" &&
       -f "$stage_dir/.dvmeta-owner" && ! -L "$stage_dir/.dvmeta-owner" &&
       "$(<"$stage_dir/.dvmeta-owner")" == "${owned_workspace_token:-}" ]] && rm -rf -- "$stage_dir"
  done
  if workspace_is_owned; then
    # Transient subprocess files are never useful diagnostic artifacts.
    rm -rf -- "$run_scratch_root/tmp"
    cleanup_run_scratch_root "$status_label" || true
  fi
}

prepare_subprocess_env() {
  [[ -n "${TMPDIR:-}" ]] && mkdir -p "$TMPDIR" || true
  export TMPDIR TMPPREFIX
}

ensure_cleanup_stage() {
  if (( cleanup_stage_done == 0 )); then
    log_stage_marker "cleanup"
    append_run_note "Cleanup stage executed prior to final mux/manifest"
    cleanup_stage_done=1
  fi
}

cleanup_run_scratch_root() {
  local status_label="$1"

  if [[ -z "$run_scratch_root" ]]; then
    debug_log "[cleanup] No scratch root recorded; skipping cleanup."
    return 0
  fi

  local scratch_root="${run_scratch_root%/}"
  if [[ ! -d "$scratch_root" ]]; then
    debug_log "[cleanup] Scratch root already removed: $scratch_root"
    return 0
  fi

  local should_cleanup=0
  case "$scratch_cleanup_policy" in
    success)
      if [[ "$status_label" == "success" ]]; then
        should_cleanup=1
      fi
      ;;
    failure)
      if [[ "$status_label" != "success" ]]; then
        should_cleanup=1
      fi
      ;;
    never)
      should_cleanup=0
      ;;
  esac

  if (( should_cleanup == 0 )); then
    debug_log "[cleanup] Scratch cleanup policy '${scratch_cleanup_policy}' did not match status '${status_label}'."
    return 0
  fi

  if (( keep_on_failure == 1 )) && [[ "$status_label" != "success" ]]; then
    info "[cleanup] keep-on-failure enabled; preserving scratch root: $scratch_root"
    return 0
  fi

  if ! workspace_is_owned; then
    warn "[cleanup] Refusing to remove unowned scratch root: $scratch_root"
    return 1
  fi
  info "[cleanup] Clearing scratch root (${scratch_cleanup_policy}, status=${status_label}): $scratch_root"
  if ! rm -rf -- "$scratch_root"; then
    warn "[cleanup] Failed to remove scratch root: $scratch_root"
    return 1
  fi

  return 0
}

emit_debug_snapshots() {
  (( debug_mode == 1 )) || return 0

  local timeline_path="$1"
  local cmd_path="$2"

  log_file_excerpt "timeline debug preview" "$timeline_path" 10
  log_file_excerpt "timestamp.cmd preview" "$cmd_path" 10
}

# Encode beside the destination, validate, then publish with link(2)'s exclusive
# creation semantics. /bin/link never follows a destination directory like ln.
# A crash may leave a hidden stage, but never a partial final or overwritten export.
run_output_command() {
  local -a command=("$@")
  local destination="${command[-1]}" stage_dir stage_file rc=0
  if [[ -e "$destination" || -L "$destination" ]]; then
    warn "[publish] Destination exists; choose a new output name: $destination"
    return 1
  fi
  stage_dir=$(mktemp -d "${destination:h}/.dvmeta-output.XXXXXXXX") || return 1
  output_stage_dirs+=("$stage_dir")
  print -rn -- "$owned_workspace_token" > "$stage_dir/.dvmeta-owner" || return 1
  stage_file="$stage_dir/output.${destination:e}"
  command[-1]="$stage_file"
  run_owned_command "${command[@]}" || rc=$?
  if (( rc == 0 )) && [[ -s "$stage_file" ]]; then
    run_owned_command "$ffmpeg_bin" -nostdin -v error -xerror -i "$stage_file" \
      -map '0:v?' -map '0:a?' -f null - || rc=$?
  else
    rc=1
  fi
  if (( rc == 0 )); then
    /bin/link "$stage_file" "$destination" || rc=$?
  fi
  rm -rf -- "$stage_dir"
  (( rc == 0 )) || warn "[publish] Output was not published: $destination"
  return "$rc"
}

# Copy a completed scratch result into a sibling stage before exclusive publish.
# This remains atomic when scratch and destination are on different volumes.
publish_completed_output() {
  local source="$1" destination="$2"
  run_output_command /bin/cp "$source" "$destination"
}
