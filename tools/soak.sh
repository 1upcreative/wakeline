#!/bin/bash
# Soak watchdog. Exits (which wakes the session) on any anomaly, on dismissal, or at the deadline.
LOG="$1/soak.log"; MARK="$1/soak.start"; touch "$MARK"; : > "$LOG"
DEADLINE=$(( $(date +%s) + 10800 ))
idle() { ioreg -c IOHIDSystem 2>/dev/null | awk -F'= ' '/"HIDIdleTime"/{printf "%d", $2/1000000000; exit}'; }
engine() { pgrep -x ScreenSaverEngine >/dev/null; }
hosts() { ps -axo pid=,command= | awk '/legacyScreenSaver\.appex/ && !/awk/ {print $1}'; }
tomb() { case "$1" in *G) awk -v v="${1%G}" 'BEGIN{printf "%d", v*1024}';; *M) echo "${1%M}";; *K) echo 0;; *) echo 0;; esac; }
finish() { echo "$1"; echo "samples: $(grep -c '^s ' "$LOG")"; grep '^s ' "$LOG" | sed -n '1p;$p'; exit 0; }
while ! engine; do
  [ "$(date +%s)" -gt "$DEADLINE" ] && finish "NEVER STARTED: Mac stayed in use for the whole window"
  /bin/sleep 5
done
# Started by the Mac's own idle timer. Display-sleep hold begins only now: taken
# earlier it would stop that timer from firing.
caffeinate -d -w $$ &
START=$(date +%s); BASE=0; LOW=0; N=0; PEAK=0
/bin/sleep 20
while :; do
  ELAPSED=$(( $(date +%s) - START ))
  CR=$(find "$HOME/Library/Logs/DiagnosticReports" -newer "$MARK" -type f 2>/dev/null | grep -iE "legacyScreenSaver|ScreenSaverEngine|Wakeline" | head -1)
  [ -n "$CR" ] && finish "ANOMALY crash report after ${ELAPSED}s: $CR"
  if ! engine; then
    I=$(idle)
    [ "$I" -lt 90 ] && finish "DISMISSED by a person after ${ELAPSED}s, peak ${PEAK}MB, baseline ${BASE}MB"
    /usr/bin/log show --last 3m --style compact --predicate 'process == "loginwindow" AND (eventMessage CONTAINS "screenSaverDied" OR eventMessage CONTAINS "screenSaverStopNow" OR eventMessage CONTAINS "userIsActiveCheck")' 2>/dev/null | tail -8 | cut -c1-160
    finish "ANOMALY engine gone with nobody at the Mac after ${ELAPSED}s (idle ${I}s), peak ${PEAK}MB"
  fi
  BESTC=0; BESTM=0
  for P in $(hosts); do
    L=$(top -l 2 -s 1 -pid "$P" -stats cpu,mem 2>/dev/null | tail -1)
    C=$(echo "$L" | awk '{print $1}'); M=$(tomb "$(echo "$L" | awk '{print $2}')")
    if awk -v a="${C:-0}" -v b="$BESTC" 'BEGIN{exit !(a>b)}'; then BESTC=$C; BESTM=$M; fi
  done
  N=$((N+1)); echo "s $(date +%T) t=${ELAPSED}s cpu=$BESTC mem=${BESTM}MB" >> "$LOG"
  [ "$BESTM" -gt "$PEAK" ] && PEAK=$BESTM
  if awk -v c="$BESTC" 'BEGIN{exit !(c<1)}'; then LOW=$((LOW+1)); else LOW=0; fi
  [ "$LOW" -ge 3 ] && finish "ANOMALY possible lock-up: render host under 1% CPU for 3 samples at ${ELAPSED}s"
  [ "$N" -eq 5 ] && BASE=$BESTM
  if [ "$BASE" -gt 0 ] && [ "$BESTM" -gt $((BASE + 250)) ]; then
    finish "ANOMALY memory grew from ${BASE}MB to ${BESTM}MB by ${ELAPSED}s"
  fi
  [ "$(date +%s)" -gt "$DEADLINE" ] && finish "SOAK COMPLETE ${ELAPSED}s, baseline ${BASE}MB, peak ${PEAK}MB, last ${BESTM}MB"
  /bin/sleep 60
done
