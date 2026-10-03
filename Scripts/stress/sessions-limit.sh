#!/bin/sh
# Fills the daemon to maximumSessions with `ighostvt-cli new`, checks the
# next open is refused, and prints the daemon's memory at each step.
# Runs where the daemon runs (device over ssh, or the Mac).
#   CLI       ighostvt-cli to use (default: the one on PATH)
#   PROCSTAT  procstat binary (Scripts/stress/procstat.c); memory is skipped without it
#   LIMIT     sessions to reach (default 64)
#   CLEANUP=1 kill the sessions this script opened at the end
CLI=${CLI:-ighostvt-cli}
LIMIT=${LIMIT:-64}
# No awk on a bare bootstrap: split procstat's tab-separated line in sh.
mem() {
  [ -n "$PROCSTAT" ] || return 0
  "$PROCSTAT" ighostvtd | while IFS="$(printf '\t')" read -r pid ppid state foot res cpu name; do
    echo "$1 $name footprint=${foot}KB resident=${res}KB"
  done
}
held() { "$CLI" list | tail -n +2 | wc -l | tr -d ' '; }
opened=""
mem "before($(held) held)"
n=$(held)
while [ "$n" -lt "$LIMIT" ]; do
  id=$("$CLI" new) || { echo "open failed at $n held"; break; }
  opened="$opened $id"
  n=$((n + 1))
  case $n in 16|32|48|64) mem "at $n";; esac
done
if out=$("$CLI" new 2>&1); then
  echo "FAIL: open #$((n + 1)) succeeded ($out)"; opened="$opened $out"
else
  echo "ok: open past the limit refused: $out"
fi
echo "held: $(held)"
mem "full"
if [ "${CLEANUP:-0}" = 1 ]; then
  for id in $opened; do "$CLI" kill "$id" >/dev/null 2>&1; done
  echo "after cleanup: $(held) held"; mem "after cleanup"
fi
echo "opened:$opened"
