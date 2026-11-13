#!/bin/zsh
set -euo pipefail
repo="${0:A:h:h:h:h}"
export FFMPEG_BIN="${FFMPEG_BIN:-$repo/Resources/bin/ffmpeg}"
export DVRESCUE_BIN="${DVRESCUE_BIN:-$repo/Resources/bin/dvrescue}"
for test_script in "${0:A:h}"/smoke_*.zsh; do
  print -r -- "[TEST] ${test_script:t}"
  /bin/zsh "$test_script"
done
# Python is a developer-only test dependency, not used by the app.
"${DVMETA_TEST_PYTHON:-/usr/bin/python3}" -B -m unittest discover -s "${0:A:h}/tests" -v
