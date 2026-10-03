#!/bin/sh
# Opens and closes sessions in a tight loop through the CLI, then reports
# what is left: sessions, zombie processes, and the daemon's memory.
#   CLI       ighostvt-cli to use (default: the one on PATH)
#   PROCSTAT  procstat binary (Scripts/stress/procstat.c), for zombies and memory
#   ROUNDS    open/close pairs (default 100)
#   PARALLEL  sessions opened before they are all closed (default 1)
CLI=${CLI:-ighostvt-cli}
ROUNDS=${ROUNDS:-100}
PARALLEL=${PARALLEL:-1}
held() { "$CLI" list | tail -n +2 | wc -l | tr -d ' '; }
report() {
  echo "$1: $(held) held"
  [ -n "$PROCSTAT" ] || return 0
  "$PROCSTAT" ighostvtd | while IFS="$(printf '\t')" read -r pid ppid state foot res cpu name; do
    echo "  $name footprint=${foot}KB resident=${res}KB"
  done
  echo "  zombies: $("$PROCSTAT" -z | wc -l | tr -d ' ')"
}
report before
i=0
failures=0
while [ "$i" -lt "$ROUNDS" ]; do
  ids=""
  j=0
  while [ "$j" -lt "$PARALLEL" ]; do
    id=$("$CLI" new) && ids="$ids $id" || failures=$((failures + 1))
    j=$((j + 1))
  done
  for id in $ids; do "$CLI" kill "$id" >/dev/null || failures=$((failures + 1)); done
  i=$((i + 1))
done
echo "failures: $failures"
sleep 2
report after
