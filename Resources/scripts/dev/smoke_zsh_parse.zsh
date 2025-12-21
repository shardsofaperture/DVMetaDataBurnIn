#!/bin/zsh

set -euo pipefail

script_root="${0:A:h:h}"
entrypoint="${script_root}/dvmetaburn.zsh"
lib_root="${script_root}/lib"

zsh -n "$entrypoint"

for lib in "${lib_root}"/*.zsh; do
  zsh -n "$lib"
done
