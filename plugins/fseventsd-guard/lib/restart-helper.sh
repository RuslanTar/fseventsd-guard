#!/bin/sh
# fseventsd-guard privileged restart helper (SOURCE).
#
# `fseventsd-guard install` renders this file (the settings block below) and installs
# the copy root-owned at /usr/local/libexec/fseventsd-guard-restart, mode 0755. A
# sudoers drop-in lets one user run exactly that path, with no arguments, without a
# password. The repo copy is never run as root: the checkout is writable by the user
# and by agents, so a root job executing it would hand root to anything that can
# edit the repo.
#
# It trusts nothing from its caller: it takes no arguments, reads no environment
# (it resets PATH and IFS) and uses fixed paths. Before it sends SIGTERM it checks
# for itself that:
#   - the target is the one real fseventsd: root-owned, the system binary path,
#     a child of launchd (ppid 1);
#   - its footprint is at or above the floor (a healthy daemon is left alone);
#   - no restart happened within the minimum interval (root-owned state file);
#   - no other restart is in progress.
# A trial window (install --trial-hours N) swaps in looser floor/interval values
# until TRIAL_UNTIL passes; it closes by itself. A TRIAL_UNTIL more than 24 h ahead
# is ignored.
# Every refusal and every restart is logged to $EVIDENCE_DIR/helper.log; before a
# restart it writes a small evidence record next to it. launchd respawns fseventsd
# at once after SIGTERM (`launchctl kickstart -k` is refused by SIP).
#
# Exit codes: 0 restarted (a new fseventsd pid appeared)
#   64 arguments given        65 footprint below the floor   66 rate limited
#   69 no genuine fseventsd   70 cannot measure              71 kill failed
#   72 no respawn seen        75 another restart running     77 not root

# @@SETTINGS-BEGIN@@ (install rewrites these lines; do not edit the installed copy)
EVIDENCE_DIR=/Library/Logs/fseventsd-guard
HISTORY_DIR=/System/Volumes/Data/.fseventsd
MIN_MB=150
MIN_INTERVAL_S=1800
TRIAL_UNTIL=0
TRIAL_MIN_MB=0
TRIAL_MIN_INTERVAL_S=120
TOOLS=
# @@SETTINGS-END@@

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
IFS='
'
umask 022
ARGC=$#

FSEVENTSD=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/FSEvents.framework/Versions/A/Support/fseventsd
RESPAWN_WAIT_S=15
KEEP_RECORDS=20

# TOOLS is empty in every real install: install sets it only under a fake --prefix
# for the test suite, and doctor fails a real install whose TOOLS is not empty.
if [ -n "$TOOLS" ]; then
  PGREP=$TOOLS/pgrep; PS=$TOOLS/ps; TOP=$TOOLS/top; KILL=$TOOLS/kill
  ID=$TOOLS/id; FOOTPRINT=$TOOLS/footprint; SLEEP=$TOOLS/sleep
else
  PGREP=/usr/bin/pgrep; PS=/bin/ps; TOP=/usr/bin/top; KILL=/bin/kill
  ID=/usr/bin/id; FOOTPRINT=/usr/bin/footprint; SLEEP=/bin/sleep
fi

LOG=$EVIDENCE_DIR/helper.log
LOCK=$EVIDENCE_DIR/.lock
STAMP=$EVIDENCE_DIR/last-restart

now() { date -u +%s; }
log() {
  mkdir -p "$EVIDENCE_DIR" 2>/dev/null
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG" 2>/dev/null
}
refuse() {
  code=$1; shift
  log "REFUSED code=$code $*"
  printf 'fseventsd-guard-restart: refused (%s): %s\n' "$code" "$*" >&2
  exit "$code"
}
is_uint() { case ${1:-x} in *[!0-9]*) return 1 ;; esac; return 0; }

# top's MEM column is the physical footprint, e.g. 5456K-, 612M, 17G, 1.5G.
footprint_mb() {
  "$TOP" -l 1 -pid "$1" -stats mem 2>/dev/null | tail -n 1 | awk '
    { v = $1; sub(/[+-]$/, "", v); u = substr(v, length(v), 1); n = substr(v, 1, length(v) - 1)
      if (n !~ /^[0-9]+(\.[0-9]+)?$/) exit 1
      if (u == "B") mb = n / 1048576; else if (u == "K") mb = n / 1024
      else if (u == "M") mb = n; else if (u == "G") mb = n * 1024; else if (u == "T") mb = n * 1048576
      else exit 1
      printf "%d\n", mb }'
}

# Prints the pid of the one genuine fseventsd. Returns 1 none, 2 several, 3 not genuine.
# Only root-owned processes count: a user process named fseventsd must not be able
# to block the restart.
genuine_pid() {
  pids=$("$PGREP" -x -u 0 fseventsd 2>/dev/null)
  [ -n "$pids" ] || return 1
  [ "$(printf '%s\n' "$pids" | wc -l | tr -d ' ')" = 1 ] || return 2
  is_uint "$pids" || return 1
  info=$("$PS" -o uid= -o comm= -p "$pids" 2>/dev/null) || return 1
  uid=$(printf '%s\n' "$info" | awk '{print $1}')
  comm=$(printf '%s\n' "$info" | sed 's/^[[:space:]]*[0-9][0-9]*[[:space:]]*//')
  ppid=$("$PS" -o ppid= -p "$pids" 2>/dev/null | tr -d ' ')
  [ "$uid" = 0 ] || return 3
  [ "$comm" = "$FSEVENTSD" ] || return 3
  [ "$ppid" = 1 ] || return 3
  printf '%s\n' "$pids"
}

[ "$ARGC" -eq 0 ] || refuse 64 "arguments are not accepted ($ARGC given)"
[ "$("$ID" -u 2>/dev/null)" = 0 ] || refuse 77 "must run as root (use: sudo -n /usr/local/libexec/fseventsd-guard-restart)"

mkdir -p "$EVIDENCE_DIR" || refuse 70 "cannot create $EVIDENCE_DIR"
chmod 0755 "$EVIDENCE_DIR" 2>/dev/null

NOW=$(now)
MODE=normal
# install caps a window at 24 h, so one that ends further ahead was not set by it
# (or the clock went back): it is ignored, never stretched.
TRIAL_MAX_S=86400
if is_uint "$TRIAL_UNTIL" && [ "$NOW" -lt "$TRIAL_UNTIL" ]; then
  if [ $((TRIAL_UNTIL - NOW)) -le "$TRIAL_MAX_S" ]; then
    MODE=trial; MIN_MB=$TRIAL_MIN_MB; MIN_INTERVAL_S=$TRIAL_MIN_INTERVAL_S
  else
    log "NOTE trial window until $TRIAL_UNTIL is more than $TRIAL_MAX_S s ahead; ignored"
  fi
fi
is_uint "$MIN_MB" || MIN_MB=150
is_uint "$MIN_INTERVAL_S" || MIN_INTERVAL_S=1800
# The lowest values install renders; a lower one is raised to them, so an edited
# settings block cannot open the rule up.
if [ "$MODE" = trial ]; then
  [ "$MIN_INTERVAL_S" -ge 120 ] || MIN_INTERVAL_S=120
else
  [ "$MIN_MB" -ge 150 ] || MIN_MB=150
  [ "$MIN_INTERVAL_S" -ge 1800 ] || MIN_INTERVAL_S=1800
fi

# One restart at a time. A lock older than 5 minutes is left over from a crash.
if ! mkdir "$LOCK" 2>/dev/null; then
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +5 2>/dev/null)" ]; then
    rmdir "$LOCK" 2>/dev/null; mkdir "$LOCK" 2>/dev/null || refuse 75 "another restart is in progress"
    log "NOTE removed a stale lock"
  else
    refuse 75 "another restart is in progress"
  fi
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

PID=$(genuine_pid); rc=$?
case $rc in
  0) ;;
  2) refuse 69 "more than one root-owned process is named fseventsd" ;;
  3) refuse 69 "the process named fseventsd is not launchd's root-owned $FSEVENTSD" ;;
  *) refuse 69 "no fseventsd process found" ;;
esac

MB=$(footprint_mb "$PID") || MB=
[ -n "$MB" ] || refuse 70 "cannot read the footprint of pid $PID"
[ "$MB" -ge "$MIN_MB" ] || refuse 65 "fseventsd pid $PID is healthy: footprint $MB MB is below the $MIN_MB MB floor ($MODE)"

if [ -f "$STAMP" ]; then
  LAST=$(head -n 1 "$STAMP" 2>/dev/null)
  is_uint "$LAST" || LAST=0
  AGE=$((NOW - LAST))
  # A stamp in the future means the clock moved back; do not let it block forever.
  if [ "$AGE" -ge 0 ] && [ "$AGE" -lt "$MIN_INTERVAL_S" ]; then
    refuse 66 "last restart was $AGE s ago; the minimum interval is $MIN_INTERVAL_S s ($MODE)"
  fi
fi

# Evidence: small on purpose. The history directory can be gigabytes; count it only.
TS=$(date -u +%Y%m%dT%H%M%SZ)
REC=$EVIDENCE_DIR/restart-$TS.txt
{
  echo "fseventsd-guard restart evidence $TS"
  echo "pid=$PID footprint_mb=$MB floor_mb=$MIN_MB min_interval_s=$MIN_INTERVAL_S mode=$MODE"
  echo "--- ps"
  "$PS" -o pid,ppid,uid,etime,time,rss,vsz,comm -p "$PID" 2>&1
  echo "--- top"
  "$TOP" -l 1 -pid "$PID" -stats pid,mem,cpu,time,th,state 2>&1 | tail -n 2
  echo "--- history dir $HISTORY_DIR"
  if [ -d "$HISTORY_DIR" ]; then
    echo "files=$(find "$HISTORY_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')"
    echo "size_kb=$(du -sk "$HISTORY_DIR" 2>/dev/null | awk '{print $1}')"
  else
    echo "missing"
  fi
  echo "--- footprint (10 s limit)"
} > "$REC" 2>&1
# footprint can be slow on a huge process; give it 10 s and move on.
"$FOOTPRINT" --noCategories -p "$PID" >> "$REC" 2>&1 &
FP=$!
i=0
while [ $i -lt 10 ] && kill -0 "$FP" 2>/dev/null; do "$SLEEP" 1; i=$((i + 1)); done
if kill -0 "$FP" 2>/dev/null; then kill "$FP" 2>/dev/null; echo "(footprint timed out)" >> "$REC"; fi
wait "$FP" 2>/dev/null
{ echo "--- helper.log tail"; tail -n 20 "$LOG" 2>/dev/null; } >> "$REC"
chmod 0644 "$REC" 2>/dev/null

# Re-check right before the kill: same pid, still genuine.
PID2=$(genuine_pid) || PID2=
[ "$PID2" = "$PID" ] || refuse 69 "fseventsd changed from pid $PID to '${PID2:-none}' during the checks"

# Stamp before the kill so a crash after it still counts against the rate limit.
echo "$NOW" > "$STAMP"; chmod 0644 "$STAMP" 2>/dev/null
log "RESTARTING pid=$PID footprint_mb=$MB mode=$MODE evidence=$REC"
"$KILL" -TERM "$PID" || refuse 71 "kill -TERM $PID failed"

i=0
NEW=
while [ $i -lt "$RESPAWN_WAIT_S" ]; do
  "$SLEEP" 1; i=$((i + 1))
  NEW=$(genuine_pid) || NEW=
  if [ -n "$NEW" ] && [ "$NEW" != "$PID" ]; then break; fi
  NEW=
done

# Housekeeping: keep the newest records and a bounded log. The helper names the
# records itself (restart-<UTC stamp>.txt), so ls | grep is safe and orders by age.
# shellcheck disable=SC2010
ls -1t "$EVIDENCE_DIR" 2>/dev/null | grep '^restart-[0-9TZ]*\.txt$' | tail -n +$((KEEP_RECORDS + 1)) |
  while read -r f; do rm -f "$EVIDENCE_DIR/$f"; done
if [ "$(wc -l < "$LOG" | tr -d ' ')" -gt 2000 ]; then
  tail -n 1000 "$LOG" > "$LOG.tmp" && mv -f "$LOG.tmp" "$LOG"
fi

if [ -z "$NEW" ]; then
  log "NO-RESPAWN old=$PID waited_s=$RESPAWN_WAIT_S"
  echo "fseventsd-guard-restart: sent SIGTERM to $PID but saw no new fseventsd within $RESPAWN_WAIT_S s" >&2
  exit 72
fi
log "RESTARTED old=$PID new=$NEW footprint_mb_before=$MB mode=$MODE"
echo "restarted old=$PID new=$NEW footprint_mb_before=$MB mode=$MODE evidence=$REC"
exit 0
