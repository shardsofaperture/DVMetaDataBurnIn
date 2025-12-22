# filtergraph.zsh

run_sendcmd_smoke_check() {
  local stage="$1"
  shift

  local output rc
  set +e
  output=$(run_stage "$stage" "$@" 2>&1)
  rc=$?
  set -e

  if [[ -n "$output" ]]; then
    printf "%s\n" "$output" >&2
  fi

  if [[ "$output" == *"Key '\"text' not found."* ]]; then
    echo "[ERROR] sendcmd smoke test output indicates quoted drawtext text key; timestamp.cmd should use unquoted text= values." >&2
    return 1
  fi

  return $rc
}

build_burnin_filtergraph() {
  local layout="$1"
  local cmdfile="$2"
  local font="$3"
  local deinterlace_mode="$4"

  local vf sendcmd drawtext_date drawtext_time drawtext_time_stacked drawtext_date_stacked
  
  local sendcmd_exec="${cmdfile}.exec"
  sendcmd_exec_path="$sendcmd_exec"
  log_write "$sendcmd_exec"
  cp -f "$cmdfile" "$sendcmd_exec"
  if typeset -f sanitize_sendcmd_file >/dev/null 2>&1; then
    if ! sanitize_sendcmd_file "$sendcmd_exec"; then
      echo "[ERROR] Unable to sanitize sendcmd exec file: $sendcmd_exec" >&2
      return 1
    fi
  fi
  debug_log "sendcmd exec path: $sendcmd_exec_path"

  local cmdfile_safe
  cmdfile_safe=$(printf "%s" "$sendcmd_exec" | sed -e 's/\\/\\\\/g' -e 's/:/\\\:/g')

  local fontfile
  fontfile=$(printf "%s" "$font" | sed -e 's/\\/\\\\/g' -e 's/:/\\\:/g')

  sendcmd="sendcmd=f='${cmdfile_safe}'"

  local shadow="shadowcolor=black:shadowx=1:shadowy=1"

  drawtext_date="drawtext@dvdate=fontfile='${fontfile}':fontsize=24:fontcolor=white:x=20:y=h-th-20:${shadow}:text=''"
  drawtext_time="drawtext@dvtime=fontfile='${fontfile}':fontsize=24:fontcolor=white:x=w-tw-20:y=h-th-20:${shadow}:text=''"
  drawtext_time_stacked="drawtext@dvtime=fontfile='${fontfile}':fontsize=24:fontcolor=white:x=w-tw-20:y=h-th-30:${shadow}:text=''"
  drawtext_date_stacked="drawtext@dvdate=fontfile='${fontfile}':fontsize=24:fontcolor=white:x=w-tw-20:y=h-th-60:${shadow}:text=''"

  case "$layout" in
    stacked)
      vf="${sendcmd},${drawtext_date_stacked},${drawtext_time_stacked}"
      ;;
    single)
      vf="${sendcmd},${drawtext_date},${drawtext_time}"
      ;;
    *)
      return 1
      ;;
  esac

  if [[ "$deinterlace_mode" != "off" ]]; then
    local deinterlace_vf
    deinterlace_vf=$(deinterlace_vf_for_mode "$deinterlace_mode")
    if [[ -n "$deinterlace_vf" ]]; then
      vf="${vf},${deinterlace_vf}"
    fi
  fi

  printf "%s" "$vf"
  return 0
}
