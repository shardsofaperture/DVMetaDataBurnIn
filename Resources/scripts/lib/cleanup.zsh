# cleanup.zsh

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
  if [[ -z "$scratch_root" || "$scratch_root" == "/" ]]; then
    warn "[cleanup] Refusing to remove unsafe scratch root: ${run_scratch_root:-<empty>}"
    return 1
  fi

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
