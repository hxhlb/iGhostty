#!/bin/sh
# Starts (or stops) an output flood in existing sessions by typing a command
# into each: `start <sid>...` runs a flood program, `stop <sid>...` sends ^C.
#   CLI    ighostvt-cli to use (default: the one on PATH)
#   FLOOD  the command typed (default alternates `yes` and
#          `base64 /dev/urandom`); OSC 2 title churn: FLOOD=osc
CLI=${CLI:-ighostvt-cli}
action=$1; shift
i=0
for sid in "$@"; do
  case $action in
  start)
    case ${FLOOD:-mixed} in
      mixed) [ $((i % 2)) = 0 ] && cmd='yes' || cmd='base64 /dev/urandom' ;;
      osc) cmd='i=0; while :; do i=$((i+1)); printf "\033]2;title %d\007\033]7;file://localhost/tmp/%d\007" $i $i; done' ;;
      *) cmd=$FLOOD ;;
    esac
    "$CLI" send "$sid" text "$cmd" key Enter ;;
  stop) "$CLI" send "$sid" key C-c ;;
  esac
  i=$((i + 1))
done
