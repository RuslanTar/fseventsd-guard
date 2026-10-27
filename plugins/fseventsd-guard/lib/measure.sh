# shellcheck shell=bash
# fseventsd-guard measurement and the `status` command. Needs no root.

# ps etime ([[dd-]hh:]mm:ss) -> seconds.
fsg_etime_s() {
  echo "$1" | tr -d ' ' | awk -F'[-:]' '{
    if (NF == 4) print $1 * 86400 + $2 * 3600 + $3 * 60 + $4
    else if (NF == 3) print $1 * 3600 + $2 * 60 + $3
    else if (NF == 2) print $1 * 60 + $2
    else print "" }'
}

# ps time ([dd-][hh:]mm:ss.cc, cumulative CPU time) -> whole milliseconds.
fsg_cputime_ms() {
  echo "$1" | tr -d ' ' | awk '{
    d = 0; s = $0; i = index(s, "-")
    if (i) { d = substr(s, 1, i - 1); s = substr(s, i + 1) }
    if (s == "" || d !~ /^[0-9]+$/) exit 1
    n = split(s, f, ":"); t = 0
    for (k = 1; k <= n; k++) { if (f[k] !~ /^[0-9]+(\.[0-9]+)?$/) exit 1; t = t * 60 + f[k] }
    printf "%d\n", (d * 86400 + t) * 1000 }'
}

# top's MEM column (5504K, 612M, 17G, 1.5G, with an optional +/- trend) -> whole MB.
fsg_parse_mem_mb() {
  echo "$1" | awk '{ v = $1; sub(/[+-]$/, "", v); u = substr(v, length(v), 1); n = substr(v, 1, length(v) - 1)
    if (n !~ /^[0-9]+(\.[0-9]+)?$/) exit 1
    if (u == "B") mb = n / 1048576; else if (u == "K") mb = n / 1024
    else if (u == "M") mb = n; else if (u == "G") mb = n * 1024; else if (u == "T") mb = n * 1048576
    else exit 1
    printf "%d\n", mb }'
}

# Swap in use in whole MB, from `sysctl -n vm.swapusage` ("total = 3072.00M  used =
# 2051.00M  free = ...").
fsg_parse_swap_mb() {
  fsg_parse_mem_mb "$(printf '%s\n' "$1" | awk '{ for (i = 1; i < NF - 1; i++) if ($i == "used" && $(i + 1) == "=") { print $(i + 2); exit } }')"
}

# Measures fseventsd. Sets M_PID M_MB M_CPU M_UP M_ERR, M_CPU_MS (its CPU time so
# far, for fsg_tick_sample), and M_CMPRS_MB (compressed memory) and M_PORTS (Mach
# ports), which are logged only. Returns 0, or 3 when it cannot measure (M_ERR says
# why; M_SLOW=1 when top did not answer in time).
fsg_measure() {
  M_PID=; M_MB=; M_CPU=; M_UP=; M_ERR=; M_CMPRS_MB=; M_PORTS=; M_CPU_MS=; M_SLOW=0
  if [ "$(uname -s)" != Darwin ]; then M_ERR="not macOS"; return 3; fi
  local pids n raw row
  # Root-owned only: any user can start a process named fseventsd, and two
  # matches would make the guard blind.
  pids=$(pgrep -x -u 0 fseventsd 2>/dev/null)
  if [ -z "$pids" ]; then M_ERR="no root-owned fseventsd process"; return 3; fi
  n=$(printf '%s\n' "$pids" | wc -l | tr -d ' ')
  if [ "$n" != 1 ]; then M_ERR="$n root-owned processes are named fseventsd"; return 3; fi
  M_PID=$pids
  # top takes a second or two; bounded, so a wedged system cannot hang a tick or a hook.
  raw=$(fsg_timeout "$FSG_TOP_TIMEOUT_S" top -l 1 -pid "$M_PID" -stats pid,mem,cmprs,ports 2>/dev/null)
  if [ $? -eq 124 ]; then M_SLOW=1; M_ERR="top did not answer within ${FSG_TOP_TIMEOUT_S}s"; return 3; fi
  row=$(printf '%s\n' "$raw" | awk -v p="$M_PID" '$1 == p { print; exit }')
  M_MB=$(fsg_parse_mem_mb "$(printf '%s\n' "$row" | awk '{ print $2 }')") || M_MB=
  if [ -z "$M_MB" ]; then M_ERR="cannot read the footprint of pid $M_PID (top said: ${row:-$(printf '%s\n' "$raw" | tail -n 1)})"; return 3; fi
  M_CMPRS_MB=$(fsg_parse_mem_mb "$(printf '%s\n' "$row" | awk '{ print $3 }')") || M_CMPRS_MB=
  M_PORTS=$(printf '%s\n' "$row" | awk '{ v = $4; sub(/[+-]$/, "", v); if (v ~ /^[0-9]+$/) print v }')
  M_CPU=$(ps -o %cpu= -p "$M_PID" 2>/dev/null | tr -d ' ')
  M_UP=$(fsg_etime_s "$(ps -o etime= -p "$M_PID" 2>/dev/null)")
  M_CPU_MS=$(fsg_cputime_ms "$(ps -o time= -p "$M_PID" 2>/dev/null)") || M_CPU_MS=
  return 0
}

# fsg_measure for the agent's tick and a heal's precheck: a top that did not answer
# in time is tried again, up to FSG_MEASURE_TRIES tries FSG_MEASURE_RETRY_S apart,
# as a runaway comes on a loaded Mac and no heal runs without a measurement. Other
# failures return at once. After the last try M_ERR also gives the number of tries
# and ps's resident size, a lower bound on the footprint (ps leaves out compressed
# and swapped pages), for the log and the notices only. Sets M_TRIES to the number
# of tries it took.
fsg_measure_retry() {
  local i=1 n=$FSG_MEASURE_TRIES rss note=
  [ "$n" -ge 1 ] || n=1
  while :; do
    M_TRIES=$i
    fsg_measure && return 0
    [ "$M_SLOW" = 1 ] || return 3
    fsg_log "MEASURE $M_ERR (try $i of $n)"
    [ "$i" -lt "$n" ] || break
    i=$((i + 1))
    fsg_sleep "$FSG_MEASURE_RETRY_S"
  done
  rss=$(ps -o rss= -p "$M_PID" 2>/dev/null | tr -d ' ')
  [ "$i" -gt 1 ] && note="$i tries"
  fsg_is_uint "$rss" && note="${note:+$note; }ps: resident $(fsg_size $((rss / 1024))), a lower bound on the footprint"
  M_ERR="$M_ERR${note:+ ($note)}"
  return 3
}

# The agent's record between ticks (docs/DESIGN.md §4), in $FSG_STATE_DIR/tick-sample:
# fseventsd's share of one core from the CPU time it used since the last tick (an
# exact average, unlike the decayed ps %cpu), how many ticks in a row found it at or
# above FSG_CPU_ESCALATE_PCT with the footprint at or above warn, and the system's
# FSEvents rate from the probe's event ids. A new pid starts over; so does the rate
# after a reboot, as event ids jump then. Sets T_CPU_PCT and T_EV_S (empty when
# unknown) and T_CPU_STREAK.
fsg_tick_sample() {
  local f="$FSG_STATE_DIR/tick-sample" now pe pc pst pi boot same=0
  T_CPU_PCT=; T_CPU_STREAK=0; T_EV_S=
  now=$(fsg_now)
  boot=$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/^{ sec = \([0-9]*\),.*/\1/p')
  pe=$(fsg__kv "$f" epoch); pc=$(fsg__kv "$f" cpu_ms); pst=$(fsg__kv "$f" streak); pi=$(fsg__kv "$f" eid)
  [ "$(fsg__kv "$f" pid)" = "$M_PID" ] && fsg_is_uint "$pe" && [ "$now" -gt "$pe" ] && same=1
  if [ $same = 1 ] && fsg_is_uint "$pc" && fsg_is_uint "$M_CPU_MS" && [ "$M_CPU_MS" -ge "$pc" ]; then
    T_CPU_PCT=$(( (M_CPU_MS - pc) / ((now - pe) * 10) ))
  fi
  if [ $same = 1 ] && [ -n "$boot" ] && [ "$(fsg__kv "$f" boot)" = "$boot" ] &&
     fsg_is_uint "$pi" && fsg_is_uint "$P_EID" && [ "$P_EID" -ge "$pi" ]; then
    T_EV_S=$(( (P_EID - pi) / (now - pe) ))
  fi
  fsg_is_uint "$pst" || pst=0
  if [ -n "$T_CPU_PCT" ] && [ "$FSG_CPU_ESCALATE_PCT" -gt 0 ] && [ "$T_CPU_PCT" -ge "$FSG_CPU_ESCALATE_PCT" ] &&
     [ "$M_MB" -ge "$FSG_WARN_MB" ]; then
    T_CPU_STREAK=$((pst + 1))
  fi
  mkdir -p "$FSG_STATE_DIR" 2>/dev/null
  printf 'epoch=%s\npid=%s\ncpu_ms=%s\ncpu_pct=%s\nstreak=%s\nboot=%s\neid=%s\n' "$now" "$M_PID" "$M_CPU_MS" "$T_CPU_PCT" \
    "$T_CPU_STREAK" "$boot" "$P_EID" > "$f.new.$$" 2>/dev/null && mv -f "$f.new.$$" "$f" 2>/dev/null
}

# A restart of fseventsd the guard did not make (owner, 2026-10-27): the pid differs
# from the previous tick's record (tick-sample) on the same boot, and neither a
# restart the guard recorded (last-restart, last-restart-uncounted) nor the root
# helper's stamp is as new as that record. Logs one EXTERNAL_RESTART line and writes
# last-external-restart, which status shows; no notice, and nothing else changes.
# Runs before fsg_tick_sample replaces the record.
fsg_tick_external_restart() {
  local f="$FSG_STATE_DIR/tick-sample" pp pe boot g s now started= at=
  pp=$(fsg__kv "$f" pid); pe=$(fsg__kv "$f" epoch)
  fsg_is_uint "$pp" && fsg_is_uint "$pe" && fsg_is_uint "${M_PID:-}" && [ "$pp" != "$M_PID" ] || return 0
  boot=$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/^{ sec = \([0-9]*\),.*/\1/p')
  [ -n "$boot" ] && [ "$(fsg__kv "$f" boot)" = "$boot" ] || return 0
  for g in "$FSG_STATE_DIR/last-restart" "$FSG_STATE_DIR/last-restart-uncounted" "$FSG_ROOT_LOG_DIR/last-restart"; do
    s=$(awk 'NR == 1 { print $1 }' "$g" 2>/dev/null)
    fsg_is_uint "$s" && [ "$s" -ge "$pe" ] && return 0
  done
  now=$(fsg_now)
  if fsg_is_uint "${M_UP:-}"; then started=$((now - M_UP)); at=$(date -u -r "$started" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null); fi
  fsg_log "EXTERNAL_RESTART old_pid=$pp new_pid=$M_PID up_s=${M_UP:-} started_at=$at"
  printf 'epoch=%s\nold_pid=%s\nnew_pid=%s\nup_s=%s\nstarted_epoch=%s\n' "$now" "$pp" "$M_PID" "${M_UP:-}" "$started" \
    > "$FSG_STATE_DIR/last-external-restart.new.$$" 2>/dev/null &&
    mv -f "$FSG_STATE_DIR/last-external-restart.new.$$" "$FSG_STATE_DIR/last-external-restart" 2>/dev/null
  return 0
}

# status's line on the last restart the guard did not make, or nothing.
fsg_status_external_text() {
  local f="$FSG_STATE_DIR/last-external-restart" e s
  e=$(fsg__kv "$f" epoch); fsg_is_uint "$e" || return 0
  s=$(fsg__kv "$f" started_epoch)
  echo "last restart not made by the guard: pid $(fsg__kv "$f" old_pid) -> $(fsg__kv "$f" new_pid), started $(fsg_is_uint "$s" && date -u -r "$s" +%Y-%m-%dT%H:%M:%SZ || echo 'at an unknown time'), seen by the agent $(fsg_dur $(( $(fsg_now) - e ))) ago (logged as EXTERNAL_RESTART; the guard does not act on it)"
}

# The per-day summary, $FSG_STATE_DIR/daily: one line per local day, rewritten as
# the day goes on, with the ticks, the largest footprint and CPU share, the heals
# that restarted fseventsd and the event rate's median and 95th percentile. The
# day's own samples are in day-samples.
fsg_daily_add() { # tick MB CPU_PCT EV_S | heal (- for unknown)
  local f="$FSG_STATE_DIR/day-samples" d="$FSG_STATE_DIR/daily" day evs line
  day=$(date +%Y-%m-%d)
  mkdir -p "$FSG_STATE_DIR" 2>/dev/null
  [ "$(head -n 1 "$f" 2>/dev/null)" = "day $day" ] || echo "day $day" > "$f" 2>/dev/null || return 0
  echo "$*" >> "$f"
  evs=$(awk '$1 == "tick" && $4 ~ /^[0-9]+$/ { print $4 }' "$f" | sort -n | tr '\n' ' ')
  line=$(awk -v day="$day" -v evs="$evs" '
    function pct(p,  i) { if (n == 0) return "-"; i = int(p * n); if (i < p * n) i++; if (i < 1) i = 1; return e[i] }
    BEGIN { n = split(evs, e, " ") }
    $1 == "tick" { t++
      if ($2 ~ /^[0-9]+$/ && (m == 0 || $2 + 0 > mb)) { mb = $2 + 0; m = 1 }
      if ($3 ~ /^[0-9]+$/ && (c == 0 || $3 + 0 > cpu)) { cpu = $3 + 0; c = 1 } }
    $1 == "heal" { h++ }
    END { printf "%s ticks=%d max_mb=%s max_cpu_pct=%s heals=%d ev_s_p50=%s ev_s_p95=%s\n", day, t, (m ? mb : "-"), (c ? cpu : "-"), h, pct(0.5), pct(0.95) }' "$f")
  { grep -v "^$day " "$d" 2>/dev/null | tail -n 399; echo "$line"; } > "$d.new.$$" 2>/dev/null && mv -f "$d.new.$$" "$d" 2>/dev/null
}

# 0 when the agent's last FSG_CPU_ESCALATE_TICKS ticks in a row found this fseventsd
# at or above warn and FSG_CPU_ESCALATE_PCT of a core. Sets C_PCT and C_STREAK. A
# record older than two agent intervals does not count.
fsg_cpu_escalated() {
  local f="$FSG_STATE_DIR/tick-sample" e
  C_PCT=; C_STREAK=
  [ "$FSG_CPU_ESCALATE_PCT" -gt 0 ] && [ -f "$f" ] && [ "$(fsg__kv "$f" pid)" = "$M_PID" ] || return 1
  e=$(fsg__kv "$f" epoch)
  fsg_is_uint "$e" && [ $(( $(fsg_now) - e )) -le $((2 * FSG_AGENT_INTERVAL_S)) ] || return 1
  C_PCT=$(fsg__kv "$f" cpu_pct); C_STREAK=$(fsg__kv "$f" streak)
  fsg_is_uint "$C_STREAK" && [ "$C_STREAK" -gt 0 ] && [ "$C_STREAK" -ge "$FSG_CPU_ESCALATE_TICKS" ]
}

# Runs the delivery probe once. Sets P_RESULT (ok|stalled|error|unavailable),
# P_LATENCY_MS, P_START_MS (how long FSEventStreamStart took; logged only) and P_EID
# (the system's current FSEvents event id, for the tick's event rate). The probe has
# its own watchdog; the outer bound catches a probe wedged inside the FSEvents
# framework.
fsg_probe() {
  P_RESULT=unavailable; P_LATENCY_MS=; P_START_MS=; P_DETAIL=; P_EID=
  if [ ! -x "$FSG_PROBE_BIN" ]; then P_DETAIL="probe not built (run: fseventsd-guard install)"; return 0; fi
  local dir out rc
  dir="$FSG_STATE_DIR/probe-dir"
  mkdir -p "$dir" 2>/dev/null
  out=$(fsg_timeout $((FSG_PROBE_TIMEOUT_S + 5)) "$FSG_PROBE_BIN" "$dir" "$FSG_PROBE_TIMEOUT_S" 2>&1)
  rc=$?
  case $rc in
    0) P_RESULT=ok; P_LATENCY_MS=$(printf '%s\n' "$out" | sed -n 's/.*latency_ms=\([0-9]*\).*/\1/p' | head -n 1) ;;
    2|124) P_RESULT=stalled; P_DETAIL="no event within ${FSG_PROBE_TIMEOUT_S}s" ;;
    *) P_RESULT=error; P_DETAIL=$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200) ;;
  esac
  case $P_RESULT in
    ok|stalled)
      P_START_MS=$(printf '%s\n' "$out" | sed -n 's/.*start_ms=\([0-9]*\).*/\1/p' | head -n 1)
      P_EID=$(printf '%s\n' "$out" | sed -n 's/.* eid=\([0-9]*\).*/\1/p' | head -n 1) ;;
  esac
  return 0
}

# Classifies the last measurement. Sets S_LEVEL (ok|warn|runaway|unknown), S_EXIT
# and S_REASONS (one per line).
fsg_classify() {
  local mrc=$1
  S_REASONS=; C_STREAK=
  if [ "$mrc" -ne 0 ]; then S_LEVEL=unknown; S_EXIT=3; S_REASONS=$M_ERR; return; fi
  S_LEVEL=ok; S_EXIT=0
  if [ "$M_MB" -ge "$FSG_ACT_MB" ]; then
    S_LEVEL=runaway; S_EXIT=2; S_REASONS="footprint $M_MB MB >= act threshold $FSG_ACT_MB MB"
  elif [ "$M_MB" -ge "$FSG_WARN_MB" ]; then
    S_LEVEL=warn; S_EXIT=1; S_REASONS="footprint $M_MB MB >= warn threshold $FSG_WARN_MB MB"
    if fsg_cpu_escalated; then
      S_LEVEL=runaway; S_EXIT=2
      S_REASONS="$S_REASONS, and cpu ${C_PCT}% of a core for $C_STREAK ticks in a row (>= $FSG_CPU_ESCALATE_PCT% for $FSG_CPU_ESCALATE_TICKS ticks counts as runaway)"
    else
      C_STREAK=
    fi
  fi
  if [ "${P_RESULT:-}" = stalled ]; then
    S_LEVEL=runaway; S_EXIT=2
    S_REASONS=$(printf '%s\n%s' "$S_REASONS" "delivery stalled: $P_DETAIL" | sed '/^$/d')
  fi
}

# Live leases after reaping, as "pid<TAB>label" lines (defined in drain.sh).
fsg_status_drain_fields() {
  D_PENDING=false; D_PHASE=; D_REASON=; D_LEASES=0
  if fsg_drain_active; then
    D_PENDING=true
    D_PHASE=$(fsg__kv "$FSG_PENDING" phase)
    D_REASON=$(fsg__kv "$FSG_PENDING" reason)
  fi
  D_LEASES=$(fsg_live_leases | sed '/^$/d' | wc -l | tr -d ' ')
  # A heal's Docker intent: Docker may be down until it verifies (lib/heal.sh).
  D_INTENT=0; D_I_PID=; D_I_ALIVE=false; D_I_TRIGGER=; D_I_VARIANT=; D_I_SINCE=; D_I_AFTER=false; D_I_ENGINE=false; D_I_ACTION=false
  if [ -f "$FSG_DOCKER_INTENT" ]; then
    D_INTENT=1
    D_I_PID=$(fsg__kv "$FSG_DOCKER_INTENT" owner_pid)
    fsg_intent_owner_alive && D_I_ALIVE=true
    D_I_TRIGGER=$(fsg__kv "$FSG_DOCKER_INTENT" trigger)
    D_I_VARIANT=$(fsg__kv "$FSG_DOCKER_INTENT" variant)
    D_I_SINCE=$(fsg__kv "$FSG_DOCKER_INTENT" started_epoch)
    [ "$(fsg__kv "$FSG_DOCKER_INTENT" action_ran)" = 1 ] && D_I_ACTION=true
    [ "$(fsg__kv "$FSG_DOCKER_INTENT" after_done)" = 1 ] && D_I_AFTER=true D_I_ENGINE=true D_I_ACTION=true
    [ "$(fsg__kv "$FSG_DOCKER_INTENT" engine_done)" = 1 ] && D_I_ENGINE=true
  fi
}

# The background agent's liveness from its heartbeat (lib/heal.sh). Sets
# A_INSTALLED (the plist exists), A_REQUESTS (the installed app copy serves this
# checkout's heal requests), A_EPOCH, A_AGE, A_RESULT, A_EXIT, A_RUNNING (the tick
# that wrote it still runs), A_SINCE (the seconds judged below, empty when not
# judged), A_STALE and A_TEXT (one line). Stale: the last write,
# or with no heartbeat the newest TICK line in the user log or else the install, is
# older than twice the interval. A tick that is still in a heal is not stale: a
# drain takes up to its cap. An agent from before heartbeats (A_LEGACY: no
# heartbeat, its plist runs /bin/bash) is judged by its TICK lines only, which every
# tick of it writes; without one it is not judged.
fsg_agent_fields() {
  local f="$FSG_STATE_DIR/heartbeat" now limit since pid t pl
  A_INSTALLED=false; A_REQUESTS=false; A_LEGACY=false; A_EPOCH=; A_AGE=; A_RESULT=; A_EXIT=; A_RUNNING=false; A_SINCE=; A_STALE=false; A_TEXT=
  [ -f "$FSG_PLIST" ] && A_INSTALLED=true
  [ "$(sed -n 's/^FSG_REQUEST_PROTOCOL=//p' "$FSG_STATE_DIR/app/lib/common.sh" 2>/dev/null | head -n 1)" = "$FSG_REQUEST_PROTOCOL" ] &&
    A_REQUESTS=true
  now=$(fsg_now)
  limit=$((2 * FSG_AGENT_INTERVAL_S))
  if [ -f "$f" ]; then
    A_EPOCH=$(fsg__kv "$f" epoch); fsg_is_uint "$A_EPOCH" || A_EPOCH=
    A_RESULT=$(fsg__kv "$f" result)
    A_EXIT=$(fsg__kv "$f" exit); fsg_is_uint "$A_EXIT" || A_EXIT=
    pid=$(fsg__kv "$f" pid)
    [ "$A_RESULT" = running ] && fsg__alive "$pid" "$(fsg__kv "$f" lstart)" && A_RUNNING=true
  fi
  if [ -n "$A_EPOCH" ]; then
    A_AGE=$((now - A_EPOCH))
    # A heartbeat from the future means the clock moved back.
    [ "$A_AGE" -lt 0 ] && A_AGE=0
    if [ "$A_RUNNING" = true ]; then
      A_TEXT="tick pid $pid running for $(fsg_dur "$A_AGE")"
    elif [ "$A_RESULT" = running ]; then
      A_TEXT="last tick (pid $pid) started $(fsg_dur "$A_AGE") ago and ended without recording a result"
    else
      A_TEXT="last tick $(fsg_dur "$A_AGE") ago (${A_RESULT:-?}, exit ${A_EXIT:-?})"
    fi
    since=$A_AGE
  elif [ "$A_INSTALLED" = true ]; then
    t=$(sed -n 's/^\([0-9][0-9T:-]*Z\) TICK .*/\1/p' "$FSG_LOG" 2>/dev/null | tail -n 1)
    [ -n "$t" ] && t=$(date -j -u -f %Y-%m-%dT%H:%M:%SZ "$t" +%s 2>/dev/null)
    fsg_is_uint "$t" || t=
    if [ "$(plutil -extract ProgramArguments.0 raw -o - "$FSG_PLIST" 2>/dev/null)" = /bin/bash ]; then
      A_LEGACY=true
      A_TEXT="predates heartbeats: re-run install"
      [ -n "$t" ] || { A_TEXT="$A_TEXT (no TICK line in $FSG_LOG to judge it by)"; return 0; }
      since=$((now - t))
      [ "$since" -lt 0 ] && since=0
      A_TEXT="$A_TEXT (its last tick in $FSG_LOG was $(fsg_dur "$since") ago)"
    else
      pl=$(stat -f %m "$FSG_PLIST" 2>/dev/null || echo "$now")
      if [ -n "$t" ] && [ "$t" -gt "$pl" ]; then
        since=$((now - t))
        [ "$since" -lt 0 ] && since=0
        A_TEXT="no heartbeat; the last tick in $FSG_LOG was $(fsg_dur "$since") ago"
      else
        since=$((now - pl))
        [ "$since" -lt 0 ] && since=0
        A_TEXT="no tick recorded since the agent was installed $(fsg_dur "$since") ago"
      fi
    fi
  else
    A_TEXT="not installed"
    return 0
  fi
  [ "$A_INSTALLED" = true ] || { A_TEXT="$A_TEXT; the agent is not installed"; return 0; }
  A_SINCE=$since
  [ "$since" -gt "$limit" ] || return 0
  if [ "$A_RUNNING" = true ] && fsg_heal_running; then
    A_TEXT="$A_TEXT (in a heal)"
    return 0
  fi
  A_STALE=true
  A_TEXT="STALE: $A_TEXT, more than twice the $(fsg_dur "$FSG_AGENT_INTERVAL_S") interval. The agent may be unloaded, switched off in Background Items, or hung, and is not protecting this Mac (run: fseventsd-guard doctor)"
}

# One line on the Docker intent, or nothing.
fsg_status_intent_text() {
  [ "$D_INTENT" = 1 ] || return 0
  if [ "$D_I_ALIVE" = true ]; then
    echo "docker: the agent's tick (pid $D_I_PID) is in a heal's Docker step (variant $D_I_VARIANT)"
  else
    echo "docker: NOT VERIFIED - the heal of tick pid $D_I_PID ($D_I_TRIGGER, variant $D_I_VARIANT) began its Docker step at $(date -u -r "${D_I_SINCE:-0}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) and ended before Docker verified (after-step $( if [ "$D_I_AFTER" = true ]; then echo run; elif [ "$D_I_ENGINE" = true ]; then echo 'run, not every container started'; elif [ "$D_I_ACTION" = true ]; then echo 'run, the engine has not answered since'; else echo 'not run'; fi)); the agent restores and verifies it every tick and refuses new heals (exit 8) until then (after recovering Docker by hand: fseventsd-guard release)"
  fi
}

fsg_status_json() {
  local reasons_json="[" first=1 line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ $first = 1 ] || reasons_json="$reasons_json,"
    reasons_json="$reasons_json$(fsg_json_str "$line")"; first=0
  done <<EOF
$S_REASONS
EOF
  reasons_json="$reasons_json]"
  local probe_json
  if [ "$DO_PROBE" = 1 ]; then
    probe_json="{\"ran\":true,\"result\":$(fsg_json_str "$P_RESULT"),\"latency_ms\":$(fsg_json_num "$P_LATENCY_MS"),\"timeout_s\":$FSG_PROBE_TIMEOUT_S,\"start_ms\":$(fsg_json_num "$P_START_MS")}"
  else
    probe_json="{\"ran\":false,\"result\":\"skipped\",\"latency_ms\":null,\"timeout_s\":$FSG_PROBE_TIMEOUT_S,\"start_ms\":null}"
  fi
  local last_json=null lh
  lh=$(cat "$FSG_STATE_DIR/last-heal" 2>/dev/null)
  if [ -n "$lh" ]; then
    # last-heal: <epoch> <result> <trigger> <variant> <wall_s>
    set -- $lh
    last_json="{\"epoch\":$(fsg_json_num "$1"),\"result\":$(fsg_json_str "${2:-}"),\"trigger\":$(fsg_json_str "${3:-}"),\"docker_variant\":$(fsg_json_str "${4:-}"),\"wall_s\":$(fsg_json_num "${5:-}")}"
  fi
  local aff_json
  case $FSG_AFF in yes) aff_json=true ;; no) aff_json=false ;; *) aff_json=null ;; esac
  printf '{"schema":"fseventsd-guard.status/1","time":%s,"level":%s,"exit":%s,' \
    "$(fsg_json_str "$(fsg_iso)")" "$(fsg_json_str "$S_LEVEL")" "$S_EXIT"
  printf '"pid":%s,"footprint_mb":%s,"cpu_pct":%s,"uptime_s":%s,' \
    "$(fsg_json_num "$M_PID")" "$(fsg_json_num "$M_MB")" "$(fsg_json_num "$M_CPU")" "$(fsg_json_num "$M_UP")"
  printf '"thresholds":{"budget_mb":%s,"warn_mb":%s,"act_mb":%s},' "$FSG_BUDGET_MB" "$FSG_WARN_MB" "$FSG_ACT_MB"
  printf '"probe":%s,' "$probe_json"
  printf '"drain":{"pending":%s,"phase":%s,"reason":%s,"live_leases":%s},' \
    "$D_PENDING" "$( [ -n "$D_PHASE" ] && fsg_json_str "$D_PHASE" || printf null)" \
    "$( [ -n "$D_REASON" ] && fsg_json_str "$D_REASON" || printf null)" "$D_LEASES"
  printf '"last_heal":%s,' "$last_json"
  if [ -n "$RQ_ID" ]; then
    printf '"requests":{"queued":%s,"running":{"id":%s,"trigger":%s,"requester_pid":%s,"requester_alive":%s,"phase":%s}},' \
      "$RQ_QUEUED" "$(fsg_json_str "$RQ_ID")" "$(fsg_json_str "$RQ_TRIGGER")" "$(fsg_json_num "$RQ_PID")" "$RQ_ALIVE" "$(fsg_json_str "$RQ_PHASE")"
  else
    printf '"requests":{"queued":%s,"running":null},' "$RQ_QUEUED"
  fi
  printf '"agent":{"installed":%s,"interval_s":%s,"heartbeat_epoch":%s,"age_s":%s,"result":%s,"exit":%s,"running":%s,"stale":%s,"requests":%s},' \
    "$A_INSTALLED" "$FSG_AGENT_INTERVAL_S" "$(fsg_json_num "$A_EPOCH")" "$(fsg_json_num "$A_AGE")" \
    "$( [ -n "$A_RESULT" ] && fsg_json_str "$A_RESULT" || printf null)" "$(fsg_json_num "$A_EXIT")" "$A_RUNNING" "$A_STALE" "$A_REQUESTS"
  if [ "$D_INTENT" = 1 ]; then
    printf '"docker_intent":{"owner_pid":%s,"owner_alive":%s,"trigger":%s,"docker_variant":%s,"since_epoch":%s,"after_step_done":%s},' \
      "$(fsg_json_num "$D_I_PID")" "$D_I_ALIVE" "$(fsg_json_str "$D_I_TRIGGER")" "$(fsg_json_str "$D_I_VARIANT")" \
      "$(fsg_json_num "$D_I_SINCE")" "$D_I_AFTER"
  else
    printf '"docker_intent":null,'
  fi
  printf '"os":{"version":%s,"build":%s,"affected":%s},' \
    "$(fsg_json_str "$FSG_OS_VER")" "$(fsg_json_str "$FSG_OS_BUILD")" "$aff_json"
  printf '"reasons":%s,"error":%s}\n' "$reasons_json" \
    "$( [ -n "$M_ERR" ] && fsg_json_str "$M_ERR" || printf null)"
}

fsg_cmd_status() {
  local json=0
  DO_PROBE=$FSG_STATUS_PROBE
  while [ $# -gt 0 ]; do
    case $1 in
      --json) json=1 ;;
      --probe) DO_PROBE=1 ;;
      --no-probe) DO_PROBE=0 ;;
      -h|--help) fsg_usage_status; return 0 ;;
      *) fsg_say "status: unknown option $1"; fsg_usage_status; return 64 ;;
    esac
    shift
  done
  local mrc
  fsg_measure; mrc=$?
  P_RESULT=; P_LATENCY_MS=; P_START_MS=; P_DETAIL=; P_EID=
  if [ "$DO_PROBE" = 1 ] && [ $mrc -eq 0 ]; then fsg_probe; fi
  fsg_classify $mrc
  fsg_affected
  fsg_status_drain_fields
  fsg_agent_fields
  fsg_req_status_fields
  if [ $json = 1 ]; then
    fsg_status_json
    # Scripts keep stdout as JSON; the pre-wave call's log gets the warning.
    [ "$A_STALE" = true ] && fsg_say "warning: agent $A_TEXT"
  else
    if [ $mrc -ne 0 ]; then
      echo "fseventsd: cannot measure ($M_ERR)"
    else
      echo "fseventsd: $S_LEVEL - pid $M_PID, footprint $(fsg_size "$M_MB") (budget $FSG_BUDGET_MB MB, warn $FSG_WARN_MB, act $FSG_ACT_MB), cpu ${M_CPU:-?}%, up $(fsg_dur "${M_UP:-0}")"
      [ "$DO_PROBE" = 1 ] && echo "delivery probe: $P_RESULT${P_LATENCY_MS:+ (${P_LATENCY_MS} ms)}${P_DETAIL:+ - $P_DETAIL}"
      [ -n "$P_START_MS" ] && echo "probe stream start: $P_START_MS ms (a healthy fseventsd takes 0-1 ms; logged only, no heal acts on it)"
    fi
    [ -n "$S_REASONS" ] && [ $mrc -eq 0 ] && printf '%s\n' "$S_REASONS" | sed 's/^/  reason: /'
    fsg_status_external_text
    if [ "$D_PENDING" = true ]; then echo "drain: pending (phase $D_PHASE; $D_REASON); live leases: $D_LEASES"
    else echo "drain: none; live leases: $D_LEASES"; fi
    # Written by the draining heal at each poll (lib/drain.sh).
    if [ "$D_PENDING" = true ] && [ "$D_PHASE" = draining ] && [ -s "$FSG_DRAIN_DIR/blockers" ]; then
      sed 's/^/  /' "$FSG_DRAIN_DIR/blockers"
    fi
    fsg_status_intent_text
    [ -n "$RQ_ID" ] || [ "$RQ_QUEUED" -gt 0 ] &&
      echo "heal requests: $RQ_QUEUED queued${RQ_ID:+; running: $RQ_ID ($RQ_TRIGGER, phase $RQ_PHASE, requester pid $RQ_PID$( [ "$RQ_ALIVE" = true ] || echo ', gone'))}"
    fsg_helper_limits
    if [ "$FSG_H_TRIAL" = 1 ]; then
      echo "helper: trial window open until $(/bin/date -r "$(fsg_helper_setting TRIAL_UNTIL)" '+%Y-%m-%d %H:%M') (floor $FSG_H_MIN_MB MB, interval ${FSG_H_INTERVAL_S}s)"
    fi
    echo "agent: $A_TEXT"
    fsg_status_install_text
    echo "macOS ${FSG_OS_VER:-?} (${FSG_OS_BUILD:-?}): affected=$FSG_AFF - $FSG_AFF_WHY"
    [ -n "$FSG_AFF_NOTE" ] && echo "$FSG_AFF_NOTE"
  fi
  return "$S_EXIT"
}
