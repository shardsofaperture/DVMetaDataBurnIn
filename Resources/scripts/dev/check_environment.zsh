#!/bin/zsh
set -uo pipefail
repo="${0:A:h:h:h:h}"
print -r -- "Project: $repo/DVMetaDataBurnIn.xcodeproj"
print -r -- "Git: $(git --version)"
git -C "$repo" status --short --branch
print -r -- "Developer directory: $(xcode-select -p)"
if ! /bin/zsh "${0:A:h}/xcodebuild.zsh" -version; then
  print -r -- 'Full Xcode is required for app builds. With Xcode installed, set DEVELOPER_DIR to its Contents/Developer directory for this task.' >&2
fi
for tool in ffmpeg dvrescue; do
  print -r -- "Bundled $tool:"
  file "$repo/Resources/bin/$tool"
  if [[ "$tool" == dvrescue ]]; then
    "$repo/Resources/bin/$tool" --version
  else
    "$repo/Resources/bin/$tool" -version 2>&1 | head -n 1
  fi
done
print -r -- 'Developer test interpreter:'
/usr/bin/python3 --version
