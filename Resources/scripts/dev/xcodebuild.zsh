#!/bin/zsh
# Select Xcode only for this command; never change xcode-select system-wide.
set -euo pipefail
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  selected_developer_dir=$(/usr/bin/xcode-select -p 2>/dev/null || true)
  owner_xcode_dir='/Volumes/1 TB Storage/xcode-15.4/Xcode.app/Contents/Developer'
  if [[ ! -x "$selected_developer_dir/usr/bin/xcodebuild" && -x "$owner_xcode_dir/usr/bin/xcodebuild" ]]; then
    export DEVELOPER_DIR="$owner_xcode_dir"
  fi
fi
print -r -- "[Xcode] ${DEVELOPER_DIR:-${selected_developer_dir:-system selection}}" >&2
exec /usr/bin/xcodebuild "$@"
