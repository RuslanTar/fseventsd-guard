# shellcheck shell=bash
# fseventsd-guard heal requests (docs/DESIGN.md §5.3). Only the launchd agent heals:
# `heal --trigger wave|manual` and `trial` write requests/<id>.req, kick the agent
# and wait for <id>.result, so a caller killed at any point leaves the heal running
# and Docker in the agent's hands. The agent's tick serves the queue (lib/heal.sh).
#
# A request is data: KEY=VALUE lines, each value checked against its allowed set
# before anything acts on it (fsg_req_parse); nothing in it is run.

# 0 when the agent can take a request: its plist and app copy exist, the app copy
# speaks this checkout's request protocol, and launchd has it loaded. Otherwise
# FSG_AGENT_WHY says what is wrong and how to fix it.
fsg_agent_ready() {
  local app="$FSG_STATE_DIR/app" p uid
  uid=$(id -u)
  FSG_AGENT_WHY=
  if [ ! -f "$FSG_PLIST" ] || [ ! -x "$app/fseventsd-guard" ]; then
    FSG_AGENT_WHY="the background agent is not installed ($FSG_PLIST or $app/fseventsd-guard missing), and only the agent heals: run fseventsd-guard install"
    return 1
  fi
  p=$(sed -n 's/^FSG_REQUEST_PROTOCOL=//p' "$app/lib/common.sh" 2>/dev/null | head -n 1)
  if [ -z "$p" ]; then
    FSG_AGENT_WHY="the installed agent predates heal requests (no FSG_REQUEST_PROTOCOL in $app/lib/common.sh): re-run fseventsd-guard install"
    return 1
  elif [ "$p" != "$FSG_REQUEST_PROTOCOL" ]; then
    FSG_AGENT_WHY="the installed agent speaks request protocol $p, this checkout $FSG_REQUEST_PROTOCOL: re-run fseventsd-guard install"
    return 1
  fi
  if ! launchctl print "gui/$uid/$FSG_LABEL" >/dev/null 2>&1; then
    FSG_AGENT_WHY="the background agent $FSG_LABEL is not loaded: launchctl bootstrap gui/$uid \"$FSG_PLIST\", or switch fseventsd-guard back on in System Settings > General > Login Items & Extensions, or re-run fseventsd-guard install"
    return 1
  fi
  return 0
}

# fsg_req_write TRIGGER DRAIN_CAP ON_CAP VARIANT FORCE TRIAL_LABEL WAITS: writes
# requests/<id>.req under a temp name and renames it into place. The id is the UTC
# time plus this pid (zero-padded), so names sort in request order. WAITS is 1 when
# this process waits for the result (the heal exempts its chain's leases only then).
# Sets REQ_ID; 1 when it cannot be written (disk full, state dir not writable).
fsg_req_write() {
  local id f tmp
  id="$(date -u +%Y%m%dT%H%M%SZ)-$(printf '%07d' $$)"
  f="$FSG_REQ_DIR/$id.req"; tmp="$FSG_REQ_DIR/.$id.tmp"
  mkdir -p "$FSG_REQ_DIR" 2>/dev/null
  {
    echo "id=$id"
    echo "trigger=$1"
    echo "drain_cap=$2"
    echo "on_cap=$3"
    echo "docker_variant=$4"
    echo "force=$5"
    echo "trial_label=$6"
    echo "requester_pid=$$"
    echo "requester_lstart=$(fsg_lstart $$)"
    echo "requester_chain=$(fsg_req_chain)"
    echo "requester_waits=$7"
    echo "time=$(fsg_now)"
  } > "$tmp" 2>/dev/null
  if [ -n "$(fsg__kv "$tmp" time)" ] && [ ! -e "$f" ] && mv "$tmp" "$f" 2>/dev/null; then
    REQ_ID=$id
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# Runs one tick of the agent. Without -k kickstart never kills a running tick, and
# launchd never runs two instances of one job.
fsg_req_kick() { launchctl kickstart "gui/$(id -u)/$FSG_LABEL" >/dev/null 2>&1; }

# 0 while a tick runs (its heartbeat says running and its process lives).
fsg_tick_running() {
  local f="$FSG_STATE_DIR/heartbeat"
  [ "$(fsg__kv "$f" result)" = running ] && fsg__alive "$(fsg__kv "$f" pid)" "$(fsg__kv "$f" lstart)"
}

# 0 while a tick runs or a live process holds the heal lock (a tick run by hand):
# it serves the queue when its current heal is done.
fsg__agent_busy() { fsg_tick_running || fsg_heal_in_progress; }

# Prints the request log lines not shown yet (REQ_SHOWN counts them) on stderr.
fsg__req_stream() { # log
  local n
  [ -f "$1" ] || return 0
  n=$(wc -l < "$1" 2>/dev/null | tr -d ' ')
  fsg_is_uint "$n" && [ "$n" -gt "$REQ_SHOWN" ] || return 0
  sed -n "$((REQ_SHOWN + 1)),${n}p" "$1" >&2
  REQ_SHOWN=$n
}

# Prints a finished request's summary and returns its exit code.
fsg__req_result() { # id
  local r="$FSG_REQ_DIR/$1.result" rc
  sed -n 's/^summary=//p' "$r"
  rc=$(fsg__kv "$r" exit)
  fsg_is_uint "$rc" || rc=10
  return "$rc"
}

# fsg_req_wait ID [no-wait]: streams the request's log until its result appears,
# then prints the summary and returns the heal's exit code. The caller holds
# nothing: killing it leaves the heal running, and ends only the exemption of its
# chain's leases (fsg_exempt_chain). With no-wait: 12 while the
# request is queued or running. 10 when it stayed unclaimed for two agent
# intervals during which no tick ran, or for more than FSG_REQUEST_MAX_AGE_S (it is
# withdrawn), 64 for an unknown id.
fsg_req_wait() {
  local id=$1 nowait=${2:-0} d=$FSG_REQ_DIR now last_kick idle busy qtime why
  case $id in ''|*[!0-9A-Za-z-]*) fsg_say "heal: bad request id '$id'"; return 64 ;; esac
  if [ -e "$d/$id.withdrawn" ]; then
    fsg_say "heal: request $id was withdrawn: the agent did not take it in time; nothing was stopped"
    return 10
  fi
  if [ ! -e "$d/$id.req" ] && [ ! -e "$d/$id.run" ] && [ ! -e "$d/$id.result" ]; then
    fsg_say "heal: no request $id in $d"
    return 64
  fi
  if [ -f "$d/$id.result" ]; then fsg__req_result "$id"; return; fi
  if [ "$nowait" = 1 ]; then
    if [ -e "$d/$id.req" ]; then echo "$id queued"; else echo "$id running"; fi
    return 12
  fi
  REQ_STOP_MSG="stopped waiting; the heal goes on in the agent."
  [ "${REQ_ID:-}" = "$id" ] && REQ_STOP_MSG="$REQ_STOP_MSG It no longer exempts the leases of this process and its parents: $FSG_REQ_LEASES_HOLD."
  REQ_STOP_MSG="$REQ_STOP_MSG Re-attach: fseventsd-guard heal --result $id"
  trap 'echo >&2; fsg_say "$REQ_STOP_MSG"; exit 130' INT TERM HUP
  REQ_SHOWN=0; last_kick=0; idle=$(fsg_now)
  qtime=$(fsg__kv "$d/$id.req" time)
  while :; do
    fsg__req_stream "$d/$id.log"
    if [ -f "$d/$id.result" ]; then
      fsg__req_stream "$d/$id.log"
      trap - INT TERM HUP
      fsg__req_result "$id"
      return
    fi
    now=$(fsg_now)
    # Only time in which no tick runs counts: a tick busy with another heal (up to
    # its drain cap) takes this request, or joins it, when that heal is done.
    busy=0; fsg__agent_busy && { busy=1; idle=$now; }
    if [ -e "$d/$id.req" ]; then
      # A tick that cannot run (a full disk, a lock it cannot take) never claims it.
      # Nor does one that runs but cannot claim it; its runs keep the idle clock at
      # zero, so an unclaimed request also ends at the age the agent drops it at.
      why=
      if [ $((now - idle)) -ge $((2 * FSG_AGENT_INTERVAL_S)) ]; then
        why="no tick ran for $(fsg_dur $((2 * FSG_AGENT_INTERVAL_S)))"
      elif fsg_is_uint "$qtime" && [ $((now - qtime)) -gt "$FSG_REQUEST_MAX_AGE_S" ]; then
        why="it stayed unclaimed for more than $(fsg_dur "$FSG_REQUEST_MAX_AGE_S") (FSG_REQUEST_MAX_AGE_S)"
      fi
      if [ -n "$why" ] && mv "$d/$id.req" "$d/$id.withdrawn" 2>/dev/null; then
        trap - INT TERM HUP
        fsg_log "REQUEST $id withdrawn: $why"
        fsg_say "heal: the agent did not take request $id: $why; withdrawn, nothing was stopped (check: fseventsd-guard doctor; log $FSG_LOG)"
        return 10
      fi
      # A tick that was just finishing when the request landed never saw it.
      if [ $((now - last_kick)) -ge 10 ] && [ $busy = 0 ]; then
        fsg_req_kick; last_kick=$now
      fi
    elif [ ! -e "$d/$id.run" ]; then
      trap - INT TERM HUP
      fsg_say "heal: request $id is gone without a result"
      return 10
    elif [ $busy = 0 ] && ! fsg__alive "$(fsg__kv "$d/$id.run" claimed_pid)" "$(fsg__kv "$d/$id.run" claimed_lstart)"; then
      # The tick that took it was killed outright (no trap ran). The next tick gives
      # it 130 after restoring Docker; with no tick coming, stop waiting.
      if ! fsg_agent_ready || [ $((now - idle)) -ge $((2 * FSG_AGENT_INTERVAL_S)) ]; then
        trap - INT TERM HUP
        fsg_say "heal: the agent tick (pid $(fsg__kv "$d/$id.run" claimed_pid)) that ran request $id was stopped without a result, and no tick has run since${FSG_AGENT_WHY:+ ($FSG_AGENT_WHY)}. The agent's next tick restores Docker first if that heal had stopped it. Re-attach: fseventsd-guard heal --result $id"
        return 130
      fi
      if [ $((now - last_kick)) -ge 10 ]; then fsg_req_kick; last_kick=$now; fi
    fi
    fsg_sleep 1
  done
}

# The heal exempts the leases of its requester's chain only while the requester
# waits (fsg_exempt_chain); a requester that stops waiting, or never waits, is told.
FSG_REQ_LEASES_HOLD="while it drains, they hold it like any other run (a wave or manual heal gives up at its cap rather than cut them)"

# fsg_req_submit TRIGGER DRAIN_CAP ON_CAP VARIANT FORCE TRIAL_LABEL NO_WAIT: the
# caller side of heal and trial.
fsg_req_submit() {
  local what=heal
  [ "$1" = trial ] && what=trial
  if ! fsg_agent_ready; then
    fsg_say "$what: $FSG_AGENT_WHY"
    return 9
  fi
  if ! fsg_req_write "$1" "$2" "$3" "$4" "$5" "$6" "$([ "$7" = 1 ] && echo 0 || echo 1)"; then
    fsg_say "$what: cannot write a heal request in $FSG_REQ_DIR (disk full or state dir not writable); nothing was stopped"
    return 10
  fi
  fsg_req_kick
  if [ "$7" = 1 ]; then
    fsg_say "$what: request $REQ_ID queued for the agent; not waiting, so the heal does not exempt the leases of this process and its parents: $FSG_REQ_LEASES_HOLD. Result: fseventsd-guard heal --result $REQ_ID"
    echo "$REQ_ID"
    return 12
  fi
  fsg_say "$what: request $REQ_ID queued for the agent; waiting for its result (Ctrl-C stops only the wait)"
  fsg_req_wait "$REQ_ID"
}

# --- Agent side ---------------------------------------------------------------------
# Checks a request's fields against their allowed sets. Sets the REQ_* values; 1
# with REQ_BAD naming the first bad field.
fsg_req_parse() { # file id
  local f=$1 k v
  REQ_BAD=
  for k in id trigger drain_cap on_cap docker_variant force trial_label requester_pid requester_lstart requester_chain requester_waits time; do
    v=$(fsg__kv "$f" "$k")
    case $k in
      id) [ "$v" = "$2" ] || REQ_BAD=$k; REQ_ID_F=$v ;;
      trigger) case $v in wave|manual|trial) ;; *) REQ_BAD=$k ;; esac; REQ_TRIGGER=$v ;;
      drain_cap) fsg_is_uint "$v" || REQ_BAD=$k; REQ_CAP=$v ;;
      on_cap) case $v in proceed|abort) ;; *) REQ_BAD=$k ;; esac; REQ_POLICY=$v ;;
      docker_variant) case $v in A|B|C|none) ;; *) REQ_BAD=$k ;; esac; REQ_VARIANT=$v ;;
      force) case $v in 0|1) ;; *) REQ_BAD=$k ;; esac; REQ_FORCE=$v ;;
      trial_label) case $v in *[!A-Za-z0-9_.-]*) REQ_BAD=$k ;; esac; REQ_LABEL=$v ;;
      requester_pid) fsg_is_uint "$v" || REQ_BAD=$k; REQ_PID=$v ;;
      requester_lstart) case $v in *[!A-Za-z0-9\ :]*) REQ_BAD=$k ;; esac; REQ_LSTART=$v ;;
      requester_chain) case $v in *[!A-Za-z0-9\ :\;=]*) REQ_BAD=$k ;; esac; REQ_CHAIN=$v ;;
      # Absent in a request written before the field: it exempts nothing.
      requester_waits) case $v in 0|1) ;; '') v=0 ;; *) REQ_BAD=$k ;; esac; REQ_WAITS=$v ;;
      time) fsg_is_uint "$v" || REQ_BAD=$k; REQ_TIME=$v ;;
    esac
    [ -z "$REQ_BAD" ] || return 1
  done
  [ "$REQ_TRIGGER" != trial ] || [ -n "$REQ_LABEL" ] || { REQ_BAD=trial_label; return 1; }
  return 0
}

# Writes the request's result (exit code, summary lines, heal record) and ends it.
fsg_req_finish() { # id exit summary [record]
  local r="$FSG_REQ_DIR/$1.result"
  {
    echo "exit=$2"
    printf '%s\n' "$3" | sed '/^$/d; s/^/summary=/'
    echo "record=${4:-}"
  } > "$r.tmp.$$" 2>/dev/null && mv -f "$r.tmp.$$" "$r" 2>/dev/null
  rm -f "$r.tmp.$$"
  fsg_log "REQUEST $1 result exit=$2 summary=\"$(printf '%s' "$3" | head -n 1)\""
  [ "${TICK_REQ:-}" = "$1" ] && TICK_REQ=
  return 0
}

# The oldest queued request file, or nothing.
fsg_req_next() {
  local f
  for f in "$FSG_REQ_DIR"/*.req; do
    [ -f "$f" ] && { printf '%s\n' "$f"; return 0; }
  done
  return 1
}

fsg_req_queued() { fsg_req_next >/dev/null; }

# Gives each request that a tick claimed and never finished (that tick is gone)
# the result 130. It is not run again.
fsg_req_orphans() { # recovery outcome
  local f id
  for f in "$FSG_REQ_DIR"/*.run; do
    [ -f "$f" ] || continue
    id=$(basename "$f" .run)
    [ -e "$FSG_REQ_DIR/$id.result" ] && continue
    fsg__alive "$(fsg__kv "$f" claimed_pid)" "$(fsg__kv "$f" claimed_lstart)" && continue
    fsg_req_finish "$id" 130 "heal: the agent (tick pid $(fsg__kv "$f" claimed_pid)) was stopped during this request; ${1:-nothing was left to recover}"
  done
}

# Keeps the newest 20 finished requests.
fsg_req_prune() {
  local f id
  for id in $(for f in "$FSG_REQ_DIR"/*.result "$FSG_REQ_DIR"/*.withdrawn; do
                [ -e "$f" ] || continue
                f=$(basename "$f"); printf '%s\n' "${f%.*}"
              done | sort -u | sort -r | tail -n +21); do
    rm -f "$FSG_REQ_DIR/$id".*
  done
}

# `status` fields for the queue: RQ_QUEUED and the running request (RQ_ID empty
# when none runs).
fsg_req_status_fields() {
  local f id
  RQ_QUEUED=0; RQ_ID=; RQ_TRIGGER=; RQ_PID=; RQ_ALIVE=false; RQ_PHASE=
  for f in "$FSG_REQ_DIR"/*.req; do [ -f "$f" ] && RQ_QUEUED=$((RQ_QUEUED + 1)); done
  for f in "$FSG_REQ_DIR"/*.run; do
    [ -f "$f" ] || continue
    id=$(basename "$f" .run)
    [ -e "$FSG_REQ_DIR/$id.result" ] && continue
    fsg__alive "$(fsg__kv "$f" claimed_pid)" "$(fsg__kv "$f" claimed_lstart)" || continue
    RQ_ID=$id; RQ_TRIGGER=$(fsg__kv "$f" trigger); RQ_PID=$(fsg__kv "$f" requester_pid)
    fsg__alive "$RQ_PID" "$(fsg__kv "$f" requester_lstart)" && RQ_ALIVE=true
    RQ_PHASE=running
    if [ "$(fsg__kv "$FSG_PENDING" owner_pid)" = "$(fsg__kv "$f" claimed_pid)" ]; then
      RQ_PHASE=$(fsg__kv "$FSG_PENDING" phase)
    fi
  done
}
