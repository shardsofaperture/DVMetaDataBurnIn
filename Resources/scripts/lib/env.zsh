# env.zsh

export PATH="/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:$PATH}"
export LC_ALL=C
export LC_NUMERIC=C
export LANG=C
# Background children are tracked for cancellation; keep their normal priority.
unsetopt BG_NICE
