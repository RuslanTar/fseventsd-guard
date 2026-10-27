# shellcheck shell=bash
# fseventsd-guard heal, tick (the background agent) and trial (one Docker trial for
# docs/DOCKER-TRIALS.md). Only the agent's tick heals; `heal` and `trial` queue a
# request for it and wait (lib/request.sh, docs/DESIGN.md §5.3).
#
# heal exit codes:
#   0 healed                         3 cannot measure fseventsd / not macOS
#   4 drain cap reached, policy abort; or a wave heal below runaway found work
#     running (nothing was held)
#   6 nothing to do: the helper would refuse (healthy or rate limited)
#   7 the restart failed (Docker restored; held runs stay held unless it verified)
#   8 fseventsd restarted, but the Docker restore or a verification failed; or
#     refused while an earlier heal's Docker is not verified (nothing stopped)
#   9 not installed (helper, sudoers rule or agent missing, the agent older than
#     the request protocol, or sudo -n -l refuses the helper)
#  10 the request, the drain marker or the Docker intent could not be written, or
#     the request stayed unclaimed for two agent intervals while no tick ran, or
#     for FSG_REQUEST_MAX_AGE_S (nothing was stopped)
#  11 wave back-off: a recent wave heal gave up at the drain cap
#  12 queued or still running (--no-wait)   13 dropped before it started
#  14 refused after the drain: the Docker step would stop a running --rm container
#     with an anonymous volume, which Docker deletes with it, or Docker answers but
#     did not list its containers, so none could be checked (nothing was stopped)
# 130 the agent was stopped during the heal                          64 usage

FSG_COSTS="Restart costs: every FSEvents client rescans (Spotlight, IDEs, Docker file sharing, file watchers); Time Machine may run a longer backup next time. If a session stops seeing file changes after the heal, restart it."
FSG_MANUAL_FIX='sudo kill -TERM $(pgrep -x fseventsd)'

fsg_helper_meaning() {
  case $1 in
    0) echo "restarted" ;;
    1) echo "sudo refused to run the helper without a password (sudoers rule missing or changed; run: fseventsd-guard doctor)" ;;
    64) echo "the helper refused arguments" ;;
    65) echo "the helper found fseventsd healthy (below its floor)" ;;
    66) echo "the helper's rate limit applies" ;;
    69) echo "the helper found no genuine fseventsd" ;;
    70) echo "the helper could not measure fseventsd" ;;
    71) echo "kill -TERM failed" ;;
    72) echo "restarted, but fseventsd ignored SIGTERM for 10 s and needed SIGKILL" ;;
    73) echo "the helper signalled fseventsd but saw no new one (launchd did not respawn it while it waited)" ;;
    124) echo "the helper did not finish within FSG_HELPER_TIMEOUT_S" ;;
    75) echo "another restart was in progress" ;;
    77) echo "the helper did not run as root" ;;
    *) echo "the helper exited with $1" ;;
  esac
}

# Seconds left in the wave back-off, or nothing. After a wave heal gave up at the
# drain cap, the next wave boundary (of any session) would start another drain
# that holds every new leased run for up to the cap again; on a machine that is
# never free that repeats all day. Wave heals wait FSG_WAVE_RETRY_MIN instead.
fsg_wave_backoff_left() {
  [ "$HEAL_TRIGGER" = wave ] && [ "${FSG_WAVE_RETRY_MIN:-0}" -gt 0 ] || return 0
  local t age
  t=$(head -n 1 "$FSG_STATE_DIR/wave-gave-up" 2>/dev/null)
  fsg_is_uint "$t" || return 0
  age=$(( $(fsg_now) - t ))
  [ "$age" -ge 0 ] && [ "$age" -lt $((FSG_WAVE_RETRY_MIN * 60)) ] && echo $((FSG_WAVE_RETRY_MIN * 60 - age))
  return 0
}

fsg_installed() { [ -x "$FSG_HELPER_PATH" ] && [ -e "$FSG_SUDOERS_FILE" ]; }

# The heal lock is the directory heal.lock with an owner record (pid, lstart) in it.
# It only ever appears with that record inside: it is built under a private name
# and renamed into place, and rename(2) onto an existing non-empty directory fails.
# Nobody deletes heal.lock in place: it is renamed aside first and deleted only if
# it is the one that was judged (stale, or the caller's own); otherwise it goes back.

# 0 when a live process (the agent's tick, a tick run by hand, or an older guard's
# in-process heal) owns the lock. An ownerless lock (an older guard between its
# mkdir and its owner write) counts as held for its first minute.
fsg_heal_in_progress() {
  local l="$FSG_STATE_DIR/heal.lock" m age
  [ -d "$l" ] || return 1
  if [ -e "$l/owner" ]; then
    fsg__alive "$(fsg__kv "$l/owner" pid)" "$(fsg__kv "$l/owner" lstart)"
    return
  fi
  m=$(stat -f %m "$l" 2>/dev/null) || return 1
  age=$(( $(fsg_now) - m ))
  [ "$age" -ge 0 ] && [ "$age" -lt 60 ]
}

# Deletes heal.lock if its owner record is EXPECTED. 0 deleted, 1 not deleted
# (absent, or another owner: put back), 2 cannot rename (state dir not writable).
fsg__heal_lock_remove() { # expected-record tag
  local l="$FSG_STATE_DIR/heal.lock" aside="$FSG_STATE_DIR/heal.$2.$$"
  rm -rf "$aside"
  mkdir "$aside" 2>/dev/null || return 2
  if ! mv "$l" "$aside/" 2>/dev/null; then
    rmdir "$aside" 2>/dev/null
    [ -e "$l" ] && return 2
    return 1
  fi
  if [ "$(cat "$aside/heal.lock/owner" 2>/dev/null)" = "$1" ]; then
    rm -rf "$aside"
    return 0
  fi
  # Another heal took the lock between the check and the rename.
  mv "$aside/heal.lock" "$FSG_STATE_DIR/" 2>/dev/null ||
    fsg_log "HEAL could not put back the heal lock of pid $(fsg__kv "$aside/heal.lock/owner" pid) (a third heal took it); two heals may overlap"
  rm -rf "$aside"
  return 1
}

# 0 locked; 1 a live heal holds it; 2 cannot create it (disk full, state dir not
# writable), which the caller must not report as a heal in progress.
fsg_heal_lock() {
  local l="$FSG_STATE_DIR/heal.lock" new="$FSG_STATE_DIR/heal.new.$$" me lst seen n=0
  lst=$(fsg_lstart $$)
  [ -n "$lst" ] || return 2
  me=$(printf 'pid=%s\nlstart=%s' "$$" "$lst")
  mkdir -p "$FSG_STATE_DIR" 2>/dev/null
  rm -rf "$new"
  if ! { mkdir "$new" && mkdir "$new/heal.lock" && printf '%s\n' "$me" > "$new/heal.lock/owner"; } 2>/dev/null ||
     [ "$(cat "$new/heal.lock/owner" 2>/dev/null)" != "$me" ]; then
    rm -rf "$new"
    return 2
  fi
  while [ $n -lt 3 ]; do
    n=$((n + 1))
    # rename(2) does replace an empty directory: an older guard's ownerless lock.
    if [ ! -e "$l" ] && mv "$new/heal.lock" "$FSG_STATE_DIR/" 2>/dev/null; then
      rm -rf "$new"
      HEAL_LOCK_OWNER=$me; HEAL_LOCKED=1
      return 0
    fi
    seen=$(cat "$l/owner" 2>/dev/null)
    if fsg_heal_in_progress; then rm -rf "$new"; return 1; fi
    [ -e "$l" ] || continue
    fsg__heal_lock_remove "$seen" reclaim
    case $? in
      0) fsg_log "HEAL removed a stale heal lock (pid $(printf '%s\n' "$seen" | sed -n 's/^pid=//p'))" ;;
      2) rm -rf "$new"; return 2 ;;
    esac
  done
  rm -rf "$new"
  # Still no lock in place after the retries: the rename itself fails.
  [ -e "$l" ] && return 1
  return 2
}

# Releases the lock only if it is still this heal's.
fsg_heal_unlock() {
  [ "${HEAL_LOCKED:-0}" = 1 ] || return 0
  HEAL_LOCKED=0
  fsg__heal_lock_remove "$HEAL_LOCK_OWNER" release
  case $? in
    0) ;;
    # No room for the rename (disk full): delete in place, still only our own.
    2) [ "$(cat "$FSG_STATE_DIR/heal.lock/owner" 2>/dev/null)" = "$HEAL_LOCK_OWNER" ] && rm -rf "$FSG_STATE_DIR/heal.lock" ;;
    *) [ -e "$FSG_STATE_DIR/heal.lock" ] && fsg_log "HEAL the heal lock is no longer this heal's (owner pid $(fsg__kv "$FSG_STATE_DIR/heal.lock/owner" pid)); left in place" ;;
  esac
  return 0
}

# 0 while the lock's owner is in a heal: it owns the live drain (a tick that only
# measures holds the lock too). An ownerless lock in its first minute counts.
fsg_heal_running() {
  local p
  fsg_heal_in_progress || return 1
  p=$(fsg__kv "$FSG_STATE_DIR/heal.lock/owner" pid)
  [ -n "$p" ] || return 0
  [ "$(fsg__kv "$FSG_PENDING" owner_pid)" = "$p" ] && fsg_drain_active
}

# --- Docker intent -----------------------------------------------------------------
# docker-intent is written before the Docker before-step and removed only once
# Docker verified. A tick killed outright (SIGKILL, such as launchd's after
# ExitTimeOut) runs no trap, and runners ignore its drain once its owner is dead;
# this file is then the only record that Docker may be down. The next tick recovers
# it first (fsg_tick_recover).
fsg_intent_write() {
  local tmp="$FSG_DOCKER_INTENT.tmp.$$"
  {
    echo "state_version=$FSG_STATE_VERSION"
    echo "owner_pid=$$"
    echo "owner_lstart=$(fsg_lstart $$)"
    echo "started_epoch=$(fsg_now)"
    echo "request=${TICK_REQ:-}"
    echo "trigger=$HEAL_TRIGGER"
    echo "variant=$HEAL_VARIANT"
    echo "kind=$DK_KIND"
    echo "state=$DK_STATE"
    # The engine the recovery may act on (fsg__recover_endpoint).
    echo "endpoint=$DK_ENDPOINT"
    echo "restore_ids=$DK_IDS"
    echo "restore_names=$DK_NAMES"
    # Each one's health before the heal (fsg_docker_wait_containers).
    echo "restore_health=$DK_HEALTH"
    echo "heal_dir=${HEAL_DIR:-}"
    echo "action_ran=0"
    echo "action_epoch="
    echo "engine_done=0"
    echo "after_done=0"
    echo "fails="
    echo "hold_epoch="
    # The agent's expiry, so runners that hold behind the intent end with it.
    echo "hold_s=$FSG_FAILED_HOLD_S"
  } > "$tmp" 2>/dev/null && { [ -f "$FSG_DOCKER_INTENT" ] || [ ! -e "$FSG_DOCKER_INTENT" ]; } &&
    mv -f "$tmp" "$FSG_DOCKER_INTENT" 2>/dev/null &&
    [ "$(fsg__kv "$FSG_DOCKER_INTENT" owner_pid)" = "$$" ] && return 0
  rm -f "$tmp"
  return 1
}

fsg_intent_set() { # key value
  local tmp="$FSG_DOCKER_INTENT.tmp.$$"
  [ -f "$FSG_DOCKER_INTENT" ] || return 1
  # Appends a key an older guard's intent lacks.
  awk -v k="$1" -v v="$2" 'index($0, k "=") == 1 { print k "=" v; s = 1; next } { print } END { if (!s) print k "=" v }' "$FSG_DOCKER_INTENT" > "$tmp" 2>/dev/null &&
    mv -f "$tmp" "$FSG_DOCKER_INTENT" 2>/dev/null && return 0
  rm -f "$tmp"
  return 1
}

fsg_intent_owner_alive() {
  fsg__alive "$(fsg__kv "$FSG_DOCKER_INTENT" owner_pid)" "$(fsg__kv "$FSG_DOCKER_INTENT" owner_lstart)"
}

# The after-step's Docker action is about to run: recorded first, so a stop during
# it never runs it twice (C restarts Docker Desktop).
fsg_intent_action() {
  fsg_intent_set action_ran 1
  fsg_intent_set action_epoch "$(fsg_now)"
}

# engine_done=1 only once the engine answered after the action: until then a later
# pass starts Docker Desktop again.
fsg_intent_engine() {
  ! fsg_docker_off && fsg_docker_answers && fsg_intent_set engine_done 1
  return 0
}

# What the engine says about a container: its state (running, exited, ...), "gone"
# when it says there is no such container, or nothing when it did not answer. The
# CLI also exits 1 when it cannot reach the daemon, so only the message says gone.
fsg__container_state() { # target
  local out
  out=$(fsg_timeout 20 docker inspect --type container --format 'state={{.State.Status}}' "$1" 2>&1)
  case $out in
    *state=*) printf '%s\n' "$out" | sed -n 's/^state=//p' | head -n 1 ;;
    *"No such container"*|*"No such object"*) echo gone ;;
  esac
}

# 0 unless the engine says no such container (a timeout is not proof it is gone).
fsg__container_exists() { [ "$(fsg__container_state "$1")" != gone ]; }

# The intent's restore set as targets: each container by its recorded name (compose
# recreates one under the same name with a new id), by id when no name was recorded
# or only the id still exists. Sets DK_IDS (the targets), DK_NAMES and DK_HEALTH, in
# the intent's order. Unless OFFLINE, the engine is asked which name or id exists.
fsg__recover_targets() { # [offline]
  local f=$FSG_DOCKER_INTENT ids names id name t up=0
  ids=$(fsg__kv "$f" restore_ids); names=$(fsg__kv "$f" restore_names)
  # An intent of an older guard has none: each container then needs to be healthy.
  DK_HEALTH=$(fsg__kv "$f" restore_health)
  [ -z "${1:-}" ] && ! fsg_docker_off && fsg_docker_answers && up=1
  DK_IDS=; DK_NAMES=
  # shellcheck disable=SC2086
  set -- $names
  for id in $ids; do
    name=${1:-$id}
    [ $# -gt 0 ] && shift
    t=$name
    if [ $up = 1 ] && [ "$id" != "$t" ] && ! fsg__container_exists "$t" && fsg__container_exists "$id"; then
      t=$id
    fi
    DK_NAMES="${DK_NAMES:+$DK_NAMES }$name"; DK_IDS="${DK_IDS:+$DK_IDS }$t"
  done
}

# 0 when a container that is not back counts as a failed pass: the engine says it
# does not exist, or that it is not running. One that was healthy before the heal
# and runs but is not healthy yet (postgres after a Docker Desktop restart) and a
# query that timed out or did not reach the engine do not count.
fsg__container_failed() { # target
  local st
  st=$(fsg__container_state "$1")
  [ -n "$st" ] && [ "$st" != running ]
}

# Counts a failed pass for each container of the restore set whose target is in
# FAILED (not back within FSG_CONTAINER_TIMEOUT_S, with the engine answering) and
# is gone or not running, at most one per FSG_AGENT_INTERVAL_S: callers kick ticks
# seconds apart. At 2 failures it leaves the set, so one bad container cannot hold
# runs until the intent expires. The intent keeps name:count:epoch per container.
# DK_IDS and DK_NAMES are the targets (fsg__recover_targets, or the heal's own
# record). Sets RC_DROPPED and RC_FAILING (names), and keeps DK_IDS/DK_NAMES/
# DK_HEALTH to what is left.
fsg__recover_count() { # failed-targets
  local f=$FSG_DOCKER_INTENT prev fails="" n e i id name now keep_ids="" keep_names="" keep_t="" keep_n="" keep_h=""
  local -a I N T H
  # shellcheck disable=SC2206
  I=($(fsg__kv "$f" restore_ids)); N=($(fsg__kv "$f" restore_names)); T=($DK_IDS); H=($(fsg__kv "$f" restore_health))
  prev=" $(fsg__kv "$f" fails) "
  now=$(fsg_now)
  RC_DROPPED=; RC_FAILING=
  i=0
  while [ $i -lt ${#I[@]} ]; do
    id=${I[$i]}; name=${N[$i]:-${I[$i]}}
    n=$(printf '%s\n' "$prev" | tr ' ' '\n' | sed -n "s/^$name:\([0-9]*\).*/\1/p" | head -n 1)
    e=$(printf '%s\n' "$prev" | tr ' ' '\n' | sed -n "s/^$name:[0-9]*:\([0-9]*\)\$/\1/p" | head -n 1)
    n=${n:-0}
    case " $1 " in
      *" ${T[$i]:-$id} "*)
        if { [ -z "$e" ] || [ $((now - e)) -ge "$FSG_AGENT_INTERVAL_S" ] || [ $((now - e)) -lt 0 ]; } &&
           fsg__container_failed "${T[$i]:-$id}"; then
          n=$((n + 1)); e=$now
        fi
        if [ $n -ge 2 ]; then
          RC_DROPPED="${RC_DROPPED:+$RC_DROPPED }$name"
          i=$((i + 1)); continue
        fi
        [ $n -gt 0 ] && fails="${fails:+$fails }$name:$n:$e"
        RC_FAILING="${RC_FAILING:+$RC_FAILING }$name" ;;
    esac
    keep_ids="${keep_ids:+$keep_ids }$id"; keep_names="${keep_names:+$keep_names }$name"
    keep_t="${keep_t:+$keep_t }${T[$i]:-$id}"; keep_n="${keep_n:+$keep_n }$name"
    keep_h="${keep_h:+$keep_h }${H[$i]:--}"
    i=$((i + 1))
  done
  fsg_intent_set fails "$fails"
  [ -n "$RC_FAILING" ] && fsg_log "RECOVER containers not back: $RC_FAILING (now ${fails:-no failed passes}; gone or not running counts one per $(fsg_dur "$FSG_AGENT_INTERVAL_S"), dropped at the second)"
  [ -n "$RC_DROPPED" ] || return 0
  fsg_intent_set restore_ids "$keep_ids"; fsg_intent_set restore_names "$keep_names"; fsg_intent_set restore_health "$keep_h"
  DK_IDS=$keep_t; DK_NAMES=$keep_n; DK_HEALTH=$keep_h
  fsg_log "RECOVER dropped from the restore set after 2 failed passes (left as they are): $RC_DROPPED"
}

# Recovers the Docker intent of a heal whose tick died: holds new runs, runs the
# after-step if that heal had not, starts the recorded containers (by name) until
# each one ran once, verifies, then releases the hold or keeps it, and notifies.
# Before variant C's Docker Desktop restart it waits for runs leased since, with
# the emergency policy (proceed at FSG_DRAIN_CAP_S). An intent whose
# Docker action ran more than FSG_FAILED_HOLD_S ago expires instead: it never drives
# Docker again (a Docker the user quit since stays off), and new heals may start.
# The tick holds the heal lock. 0 when no intent is left; 1 Docker not verified;
# 2 expired; 3 the endpoint is not the heal's (Docker untouched, the intent and
# hold kept); 10 the drain marker cannot be written (Docker untouched, the intent
# kept).
fsg_intent_recover() {
  local f=$FSG_DOCKER_INTENT rc
  [ -f "$f" ] || return 0
  fsg_intent_owner_alive && return 0
  local HEAL_TRIGGER HEAL_VARIANT DK_KIND DK_STATE DK_IDS DK_NAMES DK_HEALTH="" DK_ERR="" DK_FAILED="" BM_RESULT="" BM_DETAIL=""
  local DK_ENDPOINT DK_EP_WHY="" DK_NOTE="" DK_STOP_DECISION="" DK_FOREIGN="" BM_NOTE=""
  local opid ran=0 released="" held="" what drc cut_n
  local cap=$FSG_DRAIN_CAP_S
  local RC_DROPPED="" RC_FAILING="" gone_note="" PASS_RAN=0
  opid=$(fsg__kv "$f" owner_pid)
  HEAL_TRIGGER=$(fsg__kv "$f" trigger); HEAL_VARIANT=$(fsg__kv "$f" variant)
  DK_KIND=$(fsg__kv "$f" kind); DK_STATE=$(fsg__kv "$f" state); DK_ENDPOINT=$(fsg__kv "$f" endpoint)
  local ae age
  ae=$(fsg__kv "$f" action_epoch)
  if [ "$(fsg__kv "$f" action_ran)" = 1 ] && fsg_is_uint "$ae"; then
    age=$(( $(fsg_now) - ae ))
    if [ "$age" -gt "$FSG_FAILED_HOLD_S" ]; then
      rm -f "$f"
      fsg_log "RECOVER the Docker step of the heal of tick pid $opid ran $(fsg_dur "$age") ago and never verified; the guard stops restoring it (FSG_FAILED_HOLD_S=$FSG_FAILED_HOLD_S)"
      fsg_notify "fseventsd-guard: Docker not verified" "the guard stops restoring it" \
        "Docker did not verify within $(fsg_dur "$FSG_FAILED_HOLD_S") of a heal (tick pid $opid, $HEAL_TRIGGER, variant $HEAL_VARIANT). The guard no longer restores it, so a Docker you quit since stays off, and heals may start again. The hold on new test runs ends by itself. Next: docker desktop status; docker ps; start what you need by hand."
      return 2
    fi
  fi
  # Runners ignore the dead tick's drain, so new runs are held first, by an ownerless
  # hold (once per intent) that outlives this tick: a stop at any point, SIGKILL
  # included, leaves them held. A signal from here on finishes the pass from the
  # tick's trap (fsg_recover_interrupted).
  TICK_RECOVERING=1
  if ! fsg_drain_hold_active && [ -z "$(fsg__kv "$f" hold_epoch)" ]; then
    if ! fsg_drain_hold "restoring Docker after the heal of tick pid $opid ended part way"; then
      TICK_RECOVERING=0
      fsg__recover_no_marker "$opid"
      return 10
    fi
    fsg_intent_set hold_epoch "$(fsg_now)"; held=1
  fi
  if ! fsg__recover_endpoint; then
    TICK_RECOVERING=0
    fsg_log "RECOVER refused for the heal of tick pid $opid: $DK_ERR; Docker left alone, the intent and the hold kept"
    fsg_throttle recover-endpoint "$FSG_WARN_RENOTIFY_MIN" &&
      fsg_notify "fseventsd-guard: Docker not restored" "the Docker endpoint changed" \
        "A heal (pid $opid, $HEAL_TRIGGER) ended before Docker verified, and $DK_ERR, so the guard touches no Docker and new test runs stay held. Next: select that engine again (docker context use ...), or recover Docker by hand, then: fseventsd-guard release"
    return 3
  fi
  if [ "$(fsg__kv "$f" action_ran)" != 1 ] && [ "$HEAL_VARIANT" = C ]; then
    # Restarting Docker Desktop cuts what runs on it: first wait for runs leased
    # since, under a drain of its own (the hold set aside comes back after it). A
    # and B only start what is down, so they need no wait.
    RECOVER_C_WAIT=1
    if ! fsg_drain_begin emergency "restoring Docker after the heal of tick pid $opid ended part way" "$cap"; then
      RECOVER_C_WAIT=0; TICK_RECOVERING=0
      fsg__recover_no_marker "$opid"
      return 10
    fi
    fsg_drain_wait emergency proceed "$cap"; drc=$?
    RECOVER_C_WAIT=0
    cut_n=$(printf '%s\n' "$DRAIN_CUT" | sed '/^$/d' | wc -l | tr -d ' ')
    if [ $drc -eq 10 ] || [ "$cut_n" -gt 0 ]; then
      fsg_notify "fseventsd: cutting running work" "restoring Docker after heal pid $opid" \
        "Restarting Docker Desktop (variant C)$( [ "$cut_n" -gt 0 ] && echo " with $cut_n item(s) still running; they may fail: $(printf '%s\n' "$DRAIN_CUT" | head -n 4 | tr '\n' ';' | sed 's/;$//; s/;/; /g' | cut -c1-240)").$(fsg_drain_unknown_text cut | sed 's/^/ /')"
    fi
  fi
  fsg__recover_pass "$opid"; rc=$?
  ran=$PASS_RAN
  TICK_RECOVERING=0
  [ -n "$RC_DROPPED" ] && gone_note=" Dropped from the restore set after 2 failed passes, left as they are (start them by hand): $RC_DROPPED."
  if [ $rc = 0 ]; then
    rm -f "$f"
    if [ "${DRAIN_HELD:-0}" = 1 ]; then
      [ "${DRAIN_SAVED_TRIGGER:-}" != trial ] && released=1
      fsg_drain_end verified
    elif fsg_drain_hold_active; then
      if [ "$(fsg__kv "$FSG_PENDING" trigger)" != trial ]; then released=1; rm -f "$FSG_PENDING"; fi
    elif [ -f "$FSG_PENDING" ] && ! fsg__alive "$(fsg__kv "$FSG_PENDING" owner_pid)" "$(fsg__kv "$FSG_PENDING" owner_lstart)"; then
      rm -f "$FSG_PENDING"
    fi
    fsg_log "RECOVER Docker verified after heal pid $opid${released:+; hold released}"
    if [ $ran = 1 ]; then
      fsg_notify "fseventsd-guard: Docker restored" "after an interrupted heal" \
        "A heal (pid $opid, $HEAL_TRIGGER) ended before it restored Docker. The guard ran the Docker after-step ($HEAL_VARIANT) and Docker verified.${DK_NOTE:+ $DK_NOTE.}${released:+ Held test runs start now.}$gone_note The agent was stopped part way (logout, launchctl bootout, a kill)."
    elif [ -n "$released" ]; then
      fsg_notify "fseventsd-guard: held runs released" "Docker is back" \
        "Docker answers, the containers run and a bind mount works again; held test runs start now.$gone_note"
    elif [ -n "$RC_DROPPED" ]; then
      fsg_notify "fseventsd-guard: Docker restored" "after an interrupted heal" \
        "Docker answers, the containers run and a bind mount works again.$gone_note"
    fi
    return 0
  fi
  what="$(fsg_docker_why)"
  fsg_drain_end
  if [ $ran = 1 ] || [ -n "$held" ] || [ -n "$RC_DROPPED" ]; then
    fsg_log "RECOVER Docker not verified after heal pid $opid: $what"
    fsg_notify "fseventsd-guard: heal interrupted" "Docker not verified" \
      "A heal (pid $opid, $HEAL_TRIGGER) ended before it restored Docker. The guard ran the after-step ($HEAL_VARIANT), but Docker is not fully back ($what).${DK_NOTE:+ $DK_NOTE.} $FSG_HOLD_NEXT.$gone_note Next: docker desktop status; docker ps."
  else
    fsg_log "RECOVER Docker still not verified after heal pid $opid: $what"
  fi
  return 1
}

# The recovery cannot write the hold or its drain (disk full): Docker is left
# alone and the intent kept; the agent retries every tick.
fsg__recover_no_marker() { # tick-pid-of-the-heal
  fsg_log "RECOVER cannot write the drain marker $FSG_PENDING; Docker left alone, the intent of heal pid $1 kept"
  fsg_throttle recover-no-drain "$FSG_WARN_RENOTIFY_MIN" &&
    fsg_notify "fseventsd-guard: Docker not restored" "cannot mark the drain" \
      "A heal (pid $1, $HEAL_TRIGGER) ended before Docker verified. Could not write $FSG_PENDING (disk full or state dir not writable), so new runs could not be held and Docker was left alone. Next: free disk space (the agent retries every 5 min), or recover Docker by hand, then: fseventsd-guard release"
  return 0
}

# A signal during a recovery pass, from the tick's EXIT trap. The hold is in place
# already (the hold set aside for C's drain comes back); the pass then runs to its
# end, and the hold lifts only if Docker verified. A recovery that still waits for
# runs before C's Docker Desktop restart leaves the restart to the next tick, which
# waits again.
fsg_recover_interrupted() {
  local f=$FSG_DOCKER_INTENT opid HEAL_TRIGGER HEAL_VARIANT DK_KIND DK_STATE DK_IDS DK_NAMES DK_HEALTH="" DK_ENDPOINT DK_EP_WHY=""
  local DK_ERR="" DK_FAILED="" BM_RESULT="" BM_DETAIL="" RC_DROPPED="" RC_FAILING="" PASS_RAN=0 DK_NOTE=""
  local DK_STOP_DECISION="" DK_FOREIGN="" BM_NOTE=""
  [ "${TICK_RECOVERING:-0}" = 1 ] || return 0
  TICK_RECOVERING=0
  fsg_drain_end
  if [ "${RECOVER_C_WAIT:-0}" = 1 ]; then
    RECOVER_C_WAIT=0
    fsg_log "RECOVER interrupted while it waited for runs before the Docker Desktop restart; the next tick waits again"
    return 0
  fi
  [ -f "$f" ] || return 0
  opid=$(fsg__kv "$f" owner_pid)
  HEAL_TRIGGER=$(fsg__kv "$f" trigger); HEAL_VARIANT=$(fsg__kv "$f" variant)
  DK_KIND=$(fsg__kv "$f" kind); DK_STATE=$(fsg__kv "$f" state); DK_ENDPOINT=$(fsg__kv "$f" endpoint)
  fsg_drain_hold_active || { fsg_drain_hold "interrupted recovery: Docker not verified" && fsg_intent_set hold_epoch "$(fsg_now)"; }
  if ! fsg__recover_endpoint; then
    fsg_log "RECOVER interrupted; refused for the heal of tick pid $opid: $DK_ERR; Docker left alone, the hold kept"
    return 0
  fi
  fsg_log "RECOVER interrupted by a signal; finishing the pass for the heal of tick pid $opid before the hold may lift"
  if fsg__recover_pass "$opid"; then
    rm -f "$f"
    if fsg_drain_hold_active && [ "$(fsg__kv "$FSG_PENDING" trigger)" != trial ]; then rm -f "$FSG_PENDING"; fi
    fsg_log "RECOVER Docker verified after the heal of tick pid $opid (the recovery was interrupted)"
    [ -n "$DK_NOTE" ] && fsg_notify "fseventsd-guard: Docker restored" "after an interrupted heal" \
      "The agent was stopped while it restored Docker after an earlier heal (tick pid $opid, $HEAL_TRIGGER); it finished the pass and Docker verified. $DK_NOTE."
  else
    fsg_log "RECOVER interrupted; Docker not verified: $(fsg_docker_why)"
    fsg_notify "fseventsd-guard: heal interrupted" "Docker not verified" \
      "The agent was stopped while it restored Docker after an earlier heal (tick pid $opid, $HEAL_TRIGGER), and Docker is not fully back ($(fsg_docker_why nobind)).${DK_NOTE:+ $DK_NOTE.} $FSG_HOLD_NEXT. Next: docker desktop status; docker ps."
  fi
  return 0
}

# The recovery acts only on the engine the heal recorded: the endpoint resolved now
# must be that local socket, by physical path (Desktop's default and desktop-linux
# contexts are one; a stopped Docker Desktop may have no socket yet), and it is then
# pinned. An intent with nothing to act on (Docker stopped, not local)
# passes. Sets DK_ERR when refused. The caller set DK_STATE and DK_ENDPOINT (the
# recorded one) from the intent.
fsg__recover_endpoint() {
  local rec=$DK_ENDPOINT
  fsg_docker_off && return 0
  if fsg_docker_endpoint missing-ok && [ -n "$rec" ] && fsg_docker_same_endpoint "$DK_ENDPOINT" "$rec"; then
    fsg_docker_pin
    return 0
  fi
  DK_ERR="the Docker endpoint is now ${DK_ENDPOINT:-unknown}${DK_EP_WHY:+ ($DK_EP_WHY)}, not the heal's ${rec:-(none recorded)}"
  DK_ENDPOINT=$rec
  return 1
}

# One recovery pass over the intent's Docker step: the after-step's Docker action if
# it has not run, or `docker desktop start` again (Desktop variants only) while the
# engine has not answered since the action; then the restore set's containers (by
# name) and the verify. The caller set HEAL_VARIANT, DK_KIND and DK_STATE from the
# intent. 0 verified; 1 not (DK_ERR, DK_FAILED, BM_* say why). PASS_RAN=1 when it
# acted on Docker itself; DK_NOTE names a C restart it skipped or ran unchecked.
fsg__recover_pass() { # tick-pid-of-the-heal
  local f=$FSG_DOCKER_INTENT after arc
  after=$(fsg__kv "$f" after_done)
  PASS_RAN=0
  fsg__recover_targets offline
  if [ "$(fsg__kv "$f" action_ran)" != 1 ]; then
    PASS_RAN=1
    fsg_log "RECOVER the heal of tick pid $1 (trigger $HEAL_TRIGGER) ended before it restored Docker; running the after-step (variant $HEAL_VARIANT)"
    fsg_drain_phase docker-after
    fsg_intent_action
    fsg_docker_after "$HEAL_VARIANT"; arc=$?
    # The verify below may still pass on the Docker C left running: the notice
    # names the skipped restart.
    [ $arc -eq 2 ] && DK_NOTE=$DK_ERR
    [ $arc -eq 0 ] || fsg_log "RECOVER docker after-step failed: $DK_ERR"
  elif [ "$(fsg__kv "$f" engine_done)" != 1 ] && [ "$after" != 1 ] && ! fsg_docker_off &&
       { [ "$HEAL_VARIANT" = B ] || [ "$HEAL_VARIANT" = C ]; } && ! fsg_docker_answers; then
    PASS_RAN=1
    fsg_drain_phase docker-after
    fsg_docker_desktop_start "desktop start again: the engine has not answered since the after-step (variant $HEAL_VARIANT)" ||
      fsg_log "RECOVER docker desktop start failed: $DK_ERR"
  fi
  fsg_intent_engine
  fsg_drain_phase verifying
  DK_FAILED=; BM_RESULT=skipped; BM_DETAIL=
  fsg_docker_off && return 0
  if ! fsg_docker_answers; then DK_ERR="the Docker engine does not answer"; return 1; fi
  fsg__recover_targets
  # Starts what is not running, again on later passes until each one ran.
  [ "$after" != 1 ] && fsg_docker_start_missing
  fsg_docker_wait_containers
  fsg__recover_count "$DK_FAILED"
  if [ -n "$RC_FAILING" ]; then
    DK_ERR="containers not back"; DK_FAILED=$RC_FAILING
    return 1
  fi
  fsg_intent_set after_done 1
  fsg_docker_verify_bind_mount || { DK_ERR="bind mount $BM_RESULT"; return 1; }
}

# Tick step 2: what an earlier tick left. A tick killed under a drain of its own
# left the hold that drain replaced as a copy: it comes back unless a live drain or
# hold is in place. Then the Docker intent of a heal that did not finish (§5.5).
# Sets RECOVER_OUTCOME (for the result of a request that tick left unfinished).
fsg_tick_recover() {
  local s rc
  RECOVER_OUTCOME="it had not reached its Docker step"
  for s in "$FSG_DRAIN_DIR"/pending.saved.*; do
    [ -f "$s" ] || continue
    fsg_drain_active || { mv -f "$s" "$FSG_PENDING" 2>/dev/null && fsg_log "RECOVER put back the hold a killed tick's drain had replaced"; }
    rm -f "$s"
  done
  [ -f "$FSG_DOCKER_INTENT" ] && ! fsg_intent_owner_alive || return 0
  fsg_intent_recover; rc=$?
  case $rc in
    0) RECOVER_OUTCOME="the agent then restored Docker and it verified" ;;
    2) RECOVER_OUTCOME="its Docker step never verified, and the agent stopped restoring it after FSG_FAILED_HOLD_S" ;;
    3) RECOVER_OUTCOME="the Docker endpoint changed since, so the agent left Docker alone; new test runs stay held (fseventsd-guard status)" ;;
    10) RECOVER_OUTCOME="the agent could not mark a drain to restore Docker (disk full?); Docker is as that heal left it" ;;
    *) RECOVER_OUTCOME="the agent restored Docker, but it does not verify yet; new test runs stay held (fseventsd-guard status)" ;;
  esac
  return 0
}

# A heal that ends between the Docker before-step and a verified (or held) restore
# holds runs first, so a second signal or launchd's SIGKILL cannot release them onto
# a Docker nobody checked, and marks its Docker for the restore (HEAL_DK_RESTORE).
fsg__heal_hold_first() {
  [ "${HEAL_DK_PRE_DONE:-0}" = 1 ] && [ "${HEAL_DK_VERIFIED:-0}" = 0 ] && [ "${HEAL_DK_HELD:-0}" = 0 ] || return 0
  HEAL_DK_PRE_DONE=0; HEAL_DK_RESTORE=1
  fsg_drain_hold "interrupted heal: Docker not verified" && { HEAL_DK_HELD=1; fsg_intent_set hold_epoch "$(fsg_now)"; }
  return 0
}

# Then it restores and verifies Docker, and lifts the hold only when that passes. A
# SIGKILL here leaves the Docker intent for the next tick. Runs at the end of every
# heal and from the tick's EXIT trap.
fsg_heal_cleanup() {
  fsg__heal_hold_first
  if [ "${HEAL_DK_RESTORE:-0}" = 1 ]; then
    HEAL_DK_RESTORE=0
    local ok=1
    if [ "${HEAL_DK_POST_DONE:-0}" = 0 ]; then
      fsg_log "HEAL interrupted after the Docker before-step; restoring Docker (variant $HEAL_VARIANT)"
      HEAL_DK_POST_DONE=1
      fsg_intent_action
      fsg_docker_after "$HEAL_VARIANT" || { ok=0; fsg_log "HEAL docker after-step failed: $DK_ERR"; }
      fsg_intent_engine
      [ $ok = 1 ] && fsg_intent_set after_done 1
    fi
    [ $ok = 1 ] && fsg_docker_verified || ok=0
    if [ $ok = 1 ]; then
      HEAL_DK_VERIFIED=1
      rm -f "$FSG_DOCKER_INTENT"
      if [ "$HEAL_DK_HELD" = 1 ] && [ "$(fsg__kv "$FSG_PENDING" trigger)" != trial ]; then
        rm -f "$FSG_PENDING"; fsg_log "DRAIN hold released: Docker verified after the interrupted heal"
      fi
      fsg_drain_end verified
      [ -n "${DK_NOTE:-}" ] && fsg_notify "fseventsd-guard: Docker restored" "after an interrupted heal" \
        "The heal was stopped part way; it restored Docker and Docker verified. $DK_NOTE."
    else
      fsg_log "HEAL interrupted; Docker not verified: $(fsg_docker_why)"
      fsg_notify "fseventsd-guard: heal interrupted" "Docker not verified" \
        "The heal was stopped part way and Docker is not fully back ($(fsg_docker_why nobind)).${DK_NOTE:+ $DK_NOTE.}$( [ "$HEAL_DK_HELD" = 1 ] && echo " $FSG_HOLD_NEXT.") Next: docker desktop status; docker ps."
    fi
  fi
  fsg_drain_end
}

# Waits for a new fseventsd that is below the warn threshold and delivers events.
fsg_wait_healthy() { # old pid
  local t0
  t0=$(fsg_now)
  while [ $(( $(fsg_now) - t0 )) -lt "$FSG_HEALTHY_TIMEOUT_S" ]; do
    if fsg_measure && [ "$M_PID" != "$1" ] && [ "$M_MB" -lt "$FSG_WARN_MB" ]; then
      fsg_probe
      [ "$P_RESULT" = ok ] || [ "$P_RESULT" = unavailable ] && return 0
    fi
    fsg_sleep 2
  done
  return 1
}

# last-heal: epoch result trigger variant wall_s record-dir (a joined request
# returns that heal's result and record, fsg_req_join).
fsg_heal_record() { # result wall_s
  echo "$(fsg_now) $1 $HEAL_TRIGGER $HEAL_VARIANT $2 ${HEAL_DIR:-}" > "$FSG_STATE_DIR/last-heal"
  case $1 in healed|restored-partly) fsg_daily_add heal ;; esac
  [ -n "${HEAL_DIR:-}" ] && {
    echo "result=$1"
    echo "trigger=$HEAL_TRIGGER"
    echo "variant_requested=$HEAL_VARIANT_REQ"
    echo "variant=$HEAL_VARIANT"
    echo "wall_s=$2"
    echo "drain_s=${T_DRAIN:-}"
    echo "drain_cut=$(printf '%s' "${DRAIN_CUT:-}" | tr '\t\n' ' ;')"
    echo "drain_exec_unknown=${DRAIN_UNKNOWN:-0}"
    echo "docker_before_s=${T_DPRE:-}"
    echo "restart_s=${T_RESTART:-}"
    echo "healthy_s=${T_HEALTHY:-}"
    echo "docker_after_s=${T_DPOST:-}"
    echo "containers_s=${T_CONT:-}"
    echo "verify_s=${T_VERIFY:-}"
    echo "heal_s_after_drain=${T_AFTER_DRAIN:-}"
    echo "helper_rc=${HELPER_RC:-}"
    echo "containers_failed=${DK_FAILED:-}"
    echo "containers_not_restorable=${DK_EPHEMERAL:-}"
    echo "containers_not_restored_oneoff=${DK_ONEOFF:-}"
    echo "containers_rm_anonymous_volumes=${DK_AT_RISK:-}"
    echo "docker_restart_unchecked=${DK_NOTE:-}"
    echo "docker_stop=${DK_STOP_DECISION:+rc=$DK_STOP_RC in ${DK_STOP_S}s: $DK_STOP_DECISION ($DK_STOP_WHY)}"
    echo "docker_started_by_other=${DK_FOREIGN:-}"
    echo "bind_mount=${BM_RESULT:-} ${BM_DETAIL:-}"
    echo "docker_endpoint=${DK_ENDPOINT:-}${DK_EP_WHY:+ (not local, Docker step skipped: $DK_EP_WHY)}"
    echo "docker_engine=${DK_ENGINE:-}"
    echo "footprint_mb_before=${HEAL_MB_BEFORE:-}"
    echo "footprint_mb_after=${HEAL_MB_AFTER:-}"
  } > "$HEAL_DIR/result.txt"
  # Keep the newest 20 heal records.
  ls -1d "$FSG_STATE_DIR"/heals/*/ 2>/dev/null | sort -r | tail -n +21 |
    while IFS= read -r d; do rm -rf "$d"; done
}

fsg_usage_heal() {
  cat <<'EOF'
usage: fseventsd-guard heal [--dry-run] [--trigger manual|wave]
                            [--docker-variant A|B|C|none] [--on-cap proceed|abort]
                            [--drain-cap SECONDS] [--force] [--no-wait]
       fseventsd-guard heal --result ID [--no-wait]
Asks the background agent to heal: it drains Docker-dependent runs, runs the Docker
step, restarts fseventsd through the root helper, restores Docker, verifies and
notifies. This waits for the result and prints the heal's progress; stopping the
wait (Ctrl-C, a timeout) does not stop the heal. --dry-run prints the plan only.
Exit: 0 healed, 3 cannot measure, 4 drain cap (abort), or a wave heal below
runaway with work running (nothing held), 6 helper would refuse,
7 restart failed, 8 Docker restore/verify failed, or refused while an earlier
heal's Docker is not verified, 9 not installed (or the agent is not loaded or
older than this checkout), 10 request, drain marker or Docker intent not written,
or no tick took the request in time (nothing stopped), 11 wave back-off (a
recent wave heal gave up at the cap), 12 queued or running (--no-wait),
13 dropped, 14 refused after the drain: the Docker step would stop a running --rm
container with an anonymous volume, or Docker answers but did not list its
containers (nothing stopped), 130 the agent was stopped during the heal, 64 usage.
EOF
}

fsg_cmd_heal() {
  local dry=0 force=0 policy="" cap=$FSG_DRAIN_CAP_S trigger=manual variant=$FSG_DOCKER_VARIANT nowait=0 result=""
  while [ $# -gt 0 ]; do
    case $1 in
      --dry-run) dry=1 ;;
      --force) force=1 ;;
      --no-wait) nowait=1 ;;
      --result) result=${2:-}; shift ;;
      --trigger) trigger=${2:-}; shift ;;
      --docker-variant) variant=${2:-}; shift ;;
      --on-cap) policy=${2:-}; shift ;;
      --drain-cap) cap=${2:-}; shift ;;
      -h|--help) fsg_usage_heal; return 0 ;;
      *) fsg_say "heal: unknown option $1"; fsg_usage_heal; return 64 ;;
    esac
    shift
  done
  [ -z "$result" ] || { fsg_req_wait "$result" "$nowait"; return; }
  case $trigger in
    manual|wave) ;;
    emergency) fsg_say "heal: --trigger emergency is the agent's own decision"; return 64 ;;
    trial) fsg_say "heal: trials run through: fseventsd-guard trial"; return 64 ;;
    *) fsg_say "heal: bad --trigger $trigger"; return 64 ;;
  esac
  case $variant in A|B|C|none) ;; *) fsg_say "heal: bad docker variant $variant"; return 64 ;; esac
  fsg_is_uint "$cap" || { fsg_say "heal: bad --drain-cap $cap"; return 64; }
  [ -n "$policy" ] || policy=$FSG_CAP_POLICY_MANUAL
  case $policy in proceed|abort) ;; *) fsg_say "heal: bad --on-cap $policy"; return 64 ;; esac
  if [ $dry = 1 ]; then
    fsg_heal_dry_run "$trigger" "$variant" "$policy" "$cap" "$force"
    return
  fi
  fsg_req_submit "$trigger" "$cap" "$policy" "$variant" "$force" "" "$nowait"
}

# Measures (a slow top is tried again: fsg_measure_retry) and checks whether the
# root helper would accept a restart, before any drain, so runs are not held for a
# restart that would be refused. Sets H_MRC (the measure's code), H_TRIES (its top
# tries), H_INSTALLED, H_REFUSE (why it would refuse, or empty), H_AGE and H_OLD_PID.
fsg_heal_precheck() { # force
  fsg_measure_retry; H_MRC=$?; H_TRIES=$M_TRIES
  HEAL_MB_BEFORE=$M_MB; H_OLD_PID=$M_PID
  # The probe tells a stall apart from a merely large daemon.
  P_RESULT=; P_DETAIL=
  [ $H_MRC -eq 0 ] && fsg_probe
  H_INSTALLED=1; H_REFUSE=
  fsg_installed || H_INSTALLED=0
  fsg_helper_limits
  H_AGE=$(fsg_helper_last_age)
  if [ $H_INSTALLED = 0 ]; then
    H_REFUSE="not installed (helper $FSG_HELPER_PATH or sudoers rule $FSG_SUDOERS_FILE missing)"
  elif ! "$(fsg_root_tool sudo)" -n -l "$FSG_HELPER_PATH" >/dev/null 2>&1; then
    # The files are there but sudo will not run the helper without a password
    # (drop-in ignored by a managed /etc/sudoers, requiretty, a renamed user).
    # Found before the drain, so Docker is never bounced for a restart that
    # cannot happen.
    H_INSTALLED=0
    H_REFUSE="sudo -n -l refuses the helper (the sudoers rule is not in effect: a managed /etc/sudoers without #includedir, requiretty, or a renamed user)"
  elif [ "$1" = 0 ] && [ $H_MRC -eq 0 ]; then
    if [ "$M_MB" -lt "$FSG_H_MIN_MB" ]; then
      if [ "$P_RESULT" = stalled ]; then
        H_REFUSE="delivery is stalled but the footprint ($M_MB MB) is below the helper's floor ($FSG_H_MIN_MB MB), so the helper would refuse. Manual fix: $FSG_MANUAL_FIX"
      else
        H_REFUSE="fseventsd is healthy ($M_MB MB < helper floor $FSG_H_MIN_MB MB)"
      fi
    elif [ -n "$H_AGE" ] && [ "$H_AGE" -ge 0 ] && [ "$H_AGE" -lt "$FSG_H_INTERVAL_S" ]; then
      H_REFUSE="the helper restarted fseventsd ${H_AGE}s ago; its minimum interval is ${FSG_H_INTERVAL_S}s"
    fi
  fi
  fsg_docker_record
  HEAL_VARIANT=$(fsg_docker_effective_variant "$HEAL_VARIANT_REQ")
}

# A wave heal below runaway heals only when nothing is running (owner, 2026-10-27).
# At warn file watching is degraded, not broken, and a runaway still heals (the
# agent's emergency tier; a wave heal at runaway drains with its full cap), so it
# must not hold every session's leased runs for up to the drain cap and then give
# up. 0 for such a heal (it sets HEAL_WAVE_IDLE=1 and S_LEVEL from the precheck's
# measurement, probe and CPU streak); its caller then drains with a cap of 0 and
# policy abort, and returns 4 at once, with no drain, notice or back-off, when
# fsg__heal_idle finds work.
fsg__heal_wave_idle_only() {
  [ "$HEAL_TRIGGER" = wave ] && [ "${H_MRC:-3}" -eq 0 ] || return 1
  fsg_classify 0
  [ "$S_LEVEL" != runaway ] || return 1
  HEAL_WAVE_IDLE=1
}

# 0 when nothing is live that a drain would wait for: no lease or unleased work (the
# requester's own leases left out while it waits, as in the drain), and engine work
# listed. Interactive sessions do not count. Sets HEAL_LIVE (the work lines),
# HEAL_LIVE_N and HEAL_LIVE_UNKNOWN (1 when the engine did not list its work).
fsg__heal_idle() {
  local rc
  HEAL_LIVE=$(fsg_live_work 0); rc=$?
  HEAL_LIVE=$(printf '%s\n' "$HEAL_LIVE" | awk -F'\t' 'NF >= 4 && $1 !~ /^interactive/')
  HEAL_LIVE_N=$(printf '%s\n' "$HEAL_LIVE" | sed '/^$/d' | wc -l | tr -d ' ')
  HEAL_LIVE_UNKNOWN=0; [ $rc -eq 2 ] && HEAL_LIVE_UNKNOWN=1
  [ "$HEAL_LIVE_N" = 0 ] && [ "$HEAL_LIVE_UNKNOWN" = 0 ]
}
fsg__heal_live_text() {
  local t=""
  [ "$HEAL_LIVE_N" -gt 0 ] && t=$(fsg_work_list "$HEAL_LIVE" 3)
  [ "$HEAL_LIVE_UNKNOWN" = 1 ] && t="${t:+$t; }$(fsg_drain_unknown_what), unknown (the engine did not list them)"
  printf '%s\n' "$t"
}

# heal --dry-run: what a request would do right now. Read-only, in the caller.
fsg_heal_dry_run() { # trigger variant policy cap force
  local policy=$3 cap=$4 work wrc held left idle=0
  HEAL_TRIGGER=$1; HEAL_VARIANT_REQ=$2
  fsg_heal_precheck "$5"
  if fsg__heal_wave_idle_only; then idle=1; cap=0; policy=abort; fi
  work=$(fsg_live_work 0); wrc=$?
  held=$(printf '%s\n' "$work" | awk -F'\t' 'NF >= 4 && $1 !~ /^interactive/' | wc -l | tr -d ' ')
  echo "fseventsd-guard heal --dry-run (trigger $HEAL_TRIGGER, docker variant $HEAL_VARIANT_REQ -> $HEAL_VARIANT, drain cap ${cap}s, unleased cap $(fsg_unleased_cap "$cap")s, at the cap: $policy)"
  [ $idle = 1 ] && echo "at $S_LEVEL a wave heal runs only when nothing is running (drain cap 0)"
  if [ $H_MRC -eq 0 ]; then
    echo "now: fseventsd pid $M_PID, footprint $M_MB MB, probe ${P_RESULT:-skipped}"
  else
    echo "now: cannot measure fseventsd ($M_ERR)"
  fi
  echo "helper: $( [ $H_INSTALLED = 1 ] && echo installed || echo 'NOT installed'), floor $FSG_H_MIN_MB MB, interval ${FSG_H_INTERVAL_S}s, trial window $( [ "$FSG_H_TRIAL" = 1 ] && echo open || echo closed), last restart ${H_AGE:-never}${H_AGE:+s ago}"
  echo "docker: $DK_KIND${DK_ENGINE:+ ($DK_ENGINE)}, $DK_STATE, endpoint ${DK_ENDPOINT:-none}${DK_EP_WHY:+ (not local: $DK_EP_WHY)}, containers: ${DK_NAMES:-none}${DK_EPHEMERAL:+; not restorable (--rm): $DK_EPHEMERAL}${DK_ONEOFF:+; not restored (one-off): $DK_ONEOFF}${DK_AT_RISK:+; --rm with an anonymous volume: $DK_AT_RISK}"
  fsg_req_status_fields
  echo "agent queue: $RQ_QUEUED request(s) waiting${RQ_ID:+; running: $RQ_ID ($RQ_TRIGGER, $RQ_PHASE)}"
  if [ -f "$FSG_DOCKER_INTENT" ]; then
    echo "an earlier heal's Docker step (tick pid $(fsg__kv "$FSG_DOCKER_INTENT" owner_pid), variant $(fsg__kv "$FSG_DOCKER_INTENT" variant)) is not verified: the agent refuses new heals until it verifies, or you recover Docker by hand and run: fseventsd-guard release"
  fi
  echo "plan:"
  echo "  1. queue a request in $FSG_REQ_DIR; the agent's tick runs it under its heal lock, after any request queued before it"
  echo "  2. mark the drain pending ($FSG_PENDING); new leased runs wait"
  echo "  3. wait for work that started before the drain (leased runs up to ${cap}s, other work up to $(fsg_unleased_cap "$cap")s; interactive sessions are not waited for), then $policy: $held item(s) now"
  [ -n "$work" ] && printf '%s\n' "$work" | fsg_work_brief text | head -n 20 | sed 's/^/       /'
  [ $wrc -eq 2 ] && echo "       $(fsg_drain_unknown_what): unknown (the engine did not list them); the drain waits for a listing like other work"
  [ $wrc -eq 3 ] && echo "       $(fsg_drain_unknown_what): not listed: Docker does not answer (wedged); the drain does not wait for them"
  echo "  4. record Docker state ($DK_KIND, $DK_STATE)"
  echo "  5. docker before-step ($HEAL_VARIANT): $(fsg_docker_plan "$HEAL_VARIANT" before)"
  if fsg_docker_stops_containers "$HEAL_VARIANT"; then
    [ -n "$DK_RM_PLAIN" ] && echo "       removes the --rm containers still running then (Docker deletes them when they stop): $DK_RM_PLAIN"
    [ -n "$DK_AT_RISK" ] && echo "       would stop here, before Docker and fseventsd (exit 14), if one still runs after the drain: --rm with an anonymous volume, which Docker would delete with it: $DK_AT_RISK"
    if [ "$DK_LISTED" = 0 ]; then
      if fsg_docker_answers; then
        echo "       would stop here, before Docker and fseventsd (exit 14), if Docker still answers but does not list its containers after the drain: their --rm volumes cannot be checked"
      elif fsg_docker_unchecked "$HEAL_VARIANT"; then
        echo "       Docker does not answer docker info (wedged), so its containers cannot be listed: a wedged Docker is acted on without the --rm volume check, and the result names it"
      fi
    fi
  fi
  echo "  6. restart: sudo -n $FSG_HELPER_PATH"
  echo "  7. wait for a new fseventsd below $FSG_WARN_MB MB with a working probe (<= ${FSG_HEALTHY_TIMEOUT_S}s)"
  echo "  8. docker after-step ($HEAL_VARIANT): $(fsg_docker_plan "$HEAL_VARIANT" after)"
  echo "  9. wait for the recorded containers to run (healthy when checked) (<= ${FSG_CONTAINER_TIMEOUT_S}s)"
  echo "  10. verify: status, Docker engine, bind-mount round trip"
  echo "  11. release the drain only if Docker verified (else hold runs), notify, log ($FSG_LOG)"
  if ! fsg_agent_ready; then echo "would stop before step 1: $FSG_AGENT_WHY (exit 9)"; return 9; fi
  if [ -f "$FSG_DOCKER_INTENT" ]; then echo "would stop before step 2: an earlier heal's Docker is not verified (exit 8)"; return 8; fi
  if [ $H_INSTALLED = 0 ]; then echo "would stop before step 2: $H_REFUSE (exit 9)"; return 9; fi
  if [ -n "$H_REFUSE" ]; then echo "would stop before step 2: $H_REFUSE (exit 6)"; return 6; fi
  left=$(fsg_wave_backoff_left)
  if [ -n "$left" ]; then echo "would stop before step 2: wave back-off, $(fsg_dur "$left") left (exit 11)"; return 11; fi
  if [ $idle = 1 ] && { [ "$held" -gt 0 ] || [ $wrc -eq 2 ]; }; then
    echo "would stop before step 2: at $S_LEVEL a wave heal runs only when nothing is running ($held item(s) now$( [ $wrc -eq 2 ] && echo ', engine work unknown')) (exit 4)"
    return 4
  fi
  return 0
}

# One heal, run by the agent's tick under the heal lock: the tick's own emergency
# heal, or a request's. Returns the heal's exit code; the tick's traps restore
# Docker if it is stopped part way (fsg_tick_cleanup).
fsg_heal_main() { # trigger variant policy cap force
  local policy=$3 cap=$4 t0 backoff hrc
  HEAL_TRIGGER=$1; HEAL_VARIANT_REQ=$2; HEAL_DIR=; HEAL_WAVE_IDLE=0
  HEAL_DK_PRE_DONE=0; HEAL_DK_POST_DONE=0; HEAL_DK_VERIFIED=0; HEAL_DK_HELD=0; HEAL_DK_RESTORE=0
  t0=$(fsg_now)
  fsg_heal_precheck "$5"
  if [ $H_MRC -ne 0 ]; then
    # The agent tries again every tick while the Mac stays loaded (nothing stamps
    # an attempt here): one notice per renotify window.
    if [ "$HEAL_TRIGGER" != emergency ] || fsg_throttle heal-cannot-measure "$FSG_WARN_RENOTIFY_MIN"; then
      fsg_notify "fseventsd-guard: cannot heal" "cannot measure" "$M_ERR. Next: fseventsd-guard doctor."
    fi
    fsg_say "heal: cannot measure fseventsd ($M_ERR)"
    return 3
  fi
  if [ $H_INSTALLED = 0 ]; then
    # The agent asks every tick; one notice per renotify window is enough.
    if [ "$HEAL_TRIGGER" != emergency ] || fsg_throttle not-installed "$FSG_WARN_RENOTIFY_MIN"; then
      fsg_notify "fseventsd-guard: cannot heal" "not installed" "${H_REFUSE}. Next: fseventsd-guard doctor, then install; or manually: $FSG_MANUAL_FIX"
    fi
    fsg_say "heal: $H_REFUSE"
    return 9
  fi
  if [ -n "$H_REFUSE" ]; then
    fsg_log "HEAL skipped trigger=$HEAL_TRIGGER reason=\"$H_REFUSE\""
    # The agent re-checks every tick; a stall it cannot act on is announced once
    # per renotify window, not every 5 minutes.
    if [ "$P_RESULT" = stalled ] &&
       { [ "$HEAL_TRIGGER" != emergency ] || fsg_throttle stall-not-restarted "$FSG_WARN_RENOTIFY_MIN"; }; then
      fsg_notify "fseventsd: delivery stalled" "not restarted" "$H_REFUSE"
    fi
    fsg_say "heal: nothing to do: $H_REFUSE"
    return 6
  fi
  backoff=$(fsg_wave_backoff_left)
  if [ -n "$backoff" ]; then
    fsg_log "HEAL wave back-off: ${backoff}s left after a wave heal gave up at the drain cap"
    fsg_say "heal: backing off: a recent wave heal gave up at the drain cap; the next wave heal may drain in $(fsg_dur "$backoff") (FSG_WAVE_RETRY_MIN=$FSG_WAVE_RETRY_MIN). The agent still heals a runaway, and a manual heal is not affected."
    return 11
  fi
  if fsg__heal_wave_idle_only; then
    cap=0; policy=abort
    if ! fsg__heal_idle; then
      fsg_log "HEAL skipped trigger=wave level=$S_LEVEL reason=\"$HEAL_LIVE_N item(s) running$( [ "$HEAL_LIVE_UNKNOWN" = 1 ] && echo ', engine work unknown')\""
      fsg_say "heal: not started: at $S_LEVEL a wave heal runs only when nothing is running; running now: $(fsg__heal_live_text). Nothing was held, stopped or restarted. A runaway still heals with the full drain cap (the agent's own emergency heal, or a wave heal at runaway)."
      return 4
    fi
  fi
  fsg_heal_run "$t0" "$H_OLD_PID" "$cap" "$policy"; hrc=$?
  fsg_heal_cleanup
  return $hrc
}

# A heal refused at the Docker step (exit 14): recorded, logged, notified, and told
# to the caller as "refused: WHAT"; nothing was stopped. An emergency refusal counts
# as an attempt, else the agent would drain again every tick for a cause that stays.
fsg__heal_refuse() { # result t0 subtitle body what
  fsg_heal_record "$1" $(( $(fsg_now) - $2 ))
  [ "$HEAL_TRIGGER" = emergency ] && fsg_now > "$FSG_STATE_DIR/last-attempt"
  fsg_log "HEAL refused: $5"
  fsg_notify "fseventsd: heal refused" "$3" "$4"
  fsg_say "heal: refused: $5; nothing was stopped or restarted"
}

# 0 when this heal's restart or attempt counts against the agent's emergency
# interval: an emergency heal's always (no restart loops), any other one only at a
# footprint (MB) at or above FSG_HELPER_MIN_MB. Below it (a trial, or a heal in a
# trial window) no runaway was healed, so it must not hold back the emergency heal
# of one that starts next; the helper's own interval still applies (owner, 2026-10-27).
fsg__heal_counts() { # mb
  [ "$HEAL_TRIGGER" = emergency ] && return 0
  fsg_is_uint "${1:-}" && [ "$1" -ge "$FSG_HELPER_MIN_MB" ]
}

# Logs the root helper's outcome (HELPER_RC) and stamps a restart it made: in
# last-restart when it counts (fsg__heal_counts, with the helper's own reading of the
# footprint, else the precheck's), else in last-restart-uncounted ("epoch mb
# trigger"), also for a call that stamped the helper's root stamp without a restart:
# the tick then ignores a root stamp no newer than that record (fsg_tick_check).
fsg__heal_helper_done() {
  local mb stamped=0
  fsg_log "HEAL helper rc=$HELPER_RC ($(fsg_helper_meaning "$HELPER_RC")) $(tr '\n' ' ' < "$HEAL_DIR/helper.out" 2>/dev/null | cut -c1-200)"
  mb=$(sed -n 's/.*footprint_mb_before=\([0-9][0-9]*\).*/\1/p' "$HEAL_DIR/helper.out" 2>/dev/null | head -n 1)
  [ -n "$mb" ] || mb=${HEAL_MB_BEFORE:-}
  case $HELPER_RC in 0|72|73) stamped=1 ;; esac
  if fsg__heal_counts "$mb"; then
    [ $stamped = 1 ] && fsg_now > "$FSG_STATE_DIR/last-restart"
    return 0
  fi
  if [ $stamped = 0 ]; then
    [ "$(head -n 1 "$FSG_ROOT_LOG_DIR/last-restart" 2>/dev/null)" != "${HEAL_ROOT_STAMP:-}" ] || return 0
    stamped=2
  fi
  echo "$(fsg_now) ${mb:-?} $HEAL_TRIGGER" > "$FSG_STATE_DIR/last-restart-uncounted"
  fsg_log "HEAL $( [ $stamped = 1 ] && echo restart || echo 'restart attempt') at ${mb:-?} MB, below the helper floor $FSG_HELPER_MIN_MB MB: it does not count against the emergency interval"
}

# 0 when the heal's Docker step acts on Docker: B and C always, A when it has
# containers to stop; never none, nor skip (Docker stopped or not local).
fsg__heal_docker_acts() { case $HEAL_VARIANT in B|C) return 0 ;; A) [ -n "$DK_STOP_IDS" ] ;; *) return 1 ;; esac; }

# One more top, right before the Docker step of a heal whose precheck needed more
# than one try: the root helper's own top (up to three 15 s tries) can miss too on
# such a Mac, and it refuses (70) after the Docker step. 1 when top did not answer again
# (H_GATE_ERR says so); any other result goes on, and the precheck's measurement
# stays as it was.
fsg__heal_top_gate() {
  local M_PID M_MB M_CPU M_UP M_ERR M_CMPRS_MB M_PORTS M_CPU_MS M_SLOW
  H_GATE_ERR=
  if fsg_measure; then
    fsg_log "HEAL top answered again before the Docker step (the precheck needed $H_TRIES tries)"
    return 0
  fi
  if [ "$M_SLOW" != 1 ]; then
    fsg_log "HEAL measure before the Docker step: $M_ERR (not a slow top; the heal goes on)"
    return 0
  fi
  H_GATE_ERR=$M_ERR
  return 1
}

# The part of a heal past the precheck: drain, Docker before-step, restart, Docker
# after-step, verify. fsg_heal_main ends the drain.
fsg_heal_run() { # t0 old_pid cap policy
  local t0=$1 old_pid=$2 cap=$3 policy=$4
  HEAL_DK_PRE_DONE=0; HEAL_DK_POST_DONE=0; HEAL_DK_VERIFIED=0; HEAL_DK_HELD=0; HEAL_DK_RESTORE=0; HELPER_RC=
  T_DRAIN=; T_DPRE=; T_RESTART=; T_HEALTHY=; T_DPOST=; T_CONT=; T_VERIFY=; T_AFTER_DRAIN=; DK_FAILED=; DRAIN_CUT=; DK_NOTE=
  DK_STOP_DECISION=; DK_STOP_RC=; DK_STOP_S=; DK_STOP_WHY=; DK_FOREIGN=; BM_NOTE=
  # One tick can run several heals within a second.
  HEAL_DIR="$FSG_STATE_DIR/heals/$(date -u +%Y%m%dT%H%M%SZ)-$$"
  [ -e "$HEAL_DIR" ] && HEAL_DIR="$HEAL_DIR-$RANDOM"
  mkdir -p "$HEAL_DIR"
  fsg_docker_record_text > "$HEAL_DIR/docker-before.txt"
  echo "$HEAL_DIR" > "$FSG_STATE_DIR/last-heal-dir"
  local why="footprint ${M_MB} MB, probe ${P_RESULT:-skipped}"
  fsg_log "HEAL start trigger=$HEAL_TRIGGER variant=$HEAL_VARIANT_REQ->$HEAL_VARIANT pid=$M_PID mb=$M_MB probe=${P_RESULT:-} record=$HEAL_DIR"

  # --- Drain ---
  local ts drc work_n
  ts=$(fsg_now)
  if ! fsg_drain_begin "$HEAL_TRIGGER" "$HEAL_TRIGGER heal: $why" "$cap"; then
    # Without the marker new runs would start against a stopped Docker.
    fsg_heal_record drain-not-marked $(( $(fsg_now) - t0 ))
    fsg_notify "fseventsd: heal not started" "cannot mark the drain" \
      "Could not write $FSG_PENDING (disk full or state dir not writable), so runs could not be held. Nothing was stopped. Next: free disk space, then fseventsd-guard heal."
    fsg_say "heal: cannot write the drain marker $FSG_PENDING; nothing was stopped"
    return 10
  fi
  # The first scan whose exec listing works also fixes which exec sessions count as
  # started before the drain.
  fsg_drain_scan 1
  local waits left="" cut_n wait_txt="" cut_txt="" ucap
  ucap=$(fsg_unleased_cap "$cap")
  waits=$(printf '%s\n' "$DS_LEASED" "$DS_UNLEASED" | sed '/^$/d')
  work_n=$(printf '%s\n' "$waits" | sed '/^$/d' | wc -l | tr -d ' ')
  [ "$work_n" -gt 0 ] && wait_txt="Waiting for $work_n item(s): $(fsg_work_list "$waits" 3) (leased runs up to $(fsg_dur "$cap"), other work up to $(fsg_dur "$ucap")). "
  [ "$DS_UNKNOWN" = 1 ] && wait_txt="${wait_txt}The engine did not list the $(fsg_drain_unknown_what): waiting up to $(fsg_dur "$ucap") for a listing. "
  [ -n "$DS_LEFT" ] && left=" Interactive sessions left alone (not waited for; they lose their connection): $(fsg_work_list "$DS_LEFT" 2)."
  # From the precheck's record: what the Docker step would delete if still running.
  local rm_txt=""
  if fsg_docker_stops_containers "$HEAL_VARIANT"; then
    [ -n "$DK_RM_PLAIN" ] && rm_txt=" --rm containers still running at the Docker step are removed (Docker deletes them when they stop): $DK_RM_PLAIN."
    [ -n "$DK_AT_RISK" ] && rm_txt="$rm_txt --rm containers with an anonymous volume, which Docker would delete with them: $DK_AT_RISK. If one still runs after the drain, the heal stops before it touches Docker or fseventsd (exit 14)."
  fi
  fsg_notify "fseventsd: healing ($(fsg_size "${M_MB:-0}"))" "$HEAL_TRIGGER heal" \
    "${wait_txt:-Nothing to wait for. }Then Docker step $HEAL_VARIANT and an fseventsd restart.$rm_txt$left Only leased runs (fseventsd-guard run, or an integrated runner) wait for the heal; other new runs start against a stopped Docker."
  fsg_drain_wait "$HEAL_TRIGGER" "$policy" "$cap"; drc=$?
  T_DRAIN=$(( $(fsg_now) - ts ))
  cut_n=$(printf '%s\n' "$DRAIN_CUT" | sed '/^$/d' | wc -l | tr -d ' ')
  left=""
  [ -n "$DRAIN_LEFT" ] && left=" Interactive sessions left alone: $(fsg_work_list "$DRAIN_LEFT" 2)."
  if [ $drc -eq 4 ]; then
    fsg_heal_record aborted-at-cap $(( $(fsg_now) - t0 ))
    # A wave heal below runaway held nothing for long (work started as it began).
    [ "$HEAL_TRIGGER" = wave ] && [ "${HEAL_WAVE_IDLE:-0}" = 0 ] && fsg_now > "$FSG_STATE_DIR/wave-gave-up"
    [ "$cut_n" -gt 0 ] && cut_txt="$cut_n item(s) still running after $(fsg_dur "$DRAIN_CAP_HIT"): $(printf '%s\n' "$DRAIN_CUT" | head -n 3 | tr '\n' ';' | sed 's/;$//; s/;/; /g'). "
    fsg_notify "fseventsd: heal given up" "drain cap reached" \
      "$cut_txt$(fsg_drain_unknown_text | sed 's/$/ /')Nothing was restarted. Next: run fseventsd-guard heal again when runs are done, or: fseventsd-guard heal --on-cap proceed"
    fsg_say "heal: drain cap reached; nothing restarted (policy abort)"
    return 4
  fi
  # --- Docker before-step ---
  fsg_drain_phase docker-before
  fsg_docker_record
  local pre_variant=$HEAL_VARIANT
  HEAL_VARIANT=$(fsg_docker_effective_variant "$HEAL_VARIANT_REQ")
  fsg_docker_record_text > "$HEAL_DIR/docker-before.txt"
  [ "$HEAL_VARIANT" != "$HEAL_VARIANT_REQ" ] && fsg_log "HEAL docker variant $HEAL_VARIANT_REQ -> $HEAL_VARIANT (kind=$DK_KIND state=$DK_STATE)"
  # The marker went out with the precheck's variant; the hooks name the step from it.
  [ "$HEAL_VARIANT" != "$pre_variant" ] && [ "${DRAIN_HELD:-0}" = 1 ] && fsg_drain_write docker-before 2>/dev/null
  if [ -n "$DK_AT_RISK" ] && fsg_docker_stops_containers "$HEAL_VARIANT"; then
    fsg__heal_refuse refused-anonymous-volumes "$t0" "a --rm container would lose its data" \
      "Docker step $HEAL_VARIANT would stop these --rm containers, and Docker deletes a --rm container's anonymous volumes with it: $DK_AT_RISK. Nothing was stopped or restarted. Next: stop it yourself once its data is safe, or start it again with a named volume (-v NAME:PATH), then run: fseventsd-guard heal" \
      "Docker step $HEAL_VARIANT would delete the anonymous volumes of running --rm containers: $DK_AT_RISK"
    return 14
  fi
  # A failed listing is not an empty one: with the engine answering, the step would
  # stop containers nobody checked. Only a wedged engine (no docker info either), the
  # failure the heal is for, is acted on unchecked, and that is named.
  if [ "$DK_LISTED" = 0 ] && fsg_docker_stops_containers "$HEAL_VARIANT"; then
    if fsg_docker_answers; then
      fsg__heal_refuse refused-unlisted "$t0" "Docker did not list its containers" \
        "Docker answers but could not list its containers (docker ps or docker inspect failed or timed out), so their --rm anonymous volumes could not be checked, and Docker step $HEAL_VARIANT would stop them. Nothing was stopped or restarted. Next: docker ps; once it lists the containers again, run: fseventsd-guard heal" \
        "Docker answers but did not list its containers, so Docker step $HEAL_VARIANT could delete a --rm container's anonymous volume unchecked"
      return 14
    fi
    fsg_log "HEAL Docker does not answer docker info (wedged) and did not list its containers; Docker step $HEAL_VARIANT goes ahead without the --rm volume check"
    # C lists them again before its restart (fsg_docker_after).
    [ "$HEAL_VARIANT" != C ] && fsg_docker_unchecked "$HEAL_VARIANT" &&
      DK_NOTE="Docker step $HEAL_VARIANT ran unchecked: Docker did not answer docker info (wedged), so its containers were not listed, and any --rm container with an anonymous volume that it stopped lost that volume"
  fi
  # A precheck that needed a second top ran on a Mac that misses FSG_TOP_TIMEOUT_S;
  # if top misses again now, the helper's own tries likely would too, after
  # Docker was stopped. Ends like the other refusals here: fsg_heal_main ends the drain,
  # and an emergency heal counts as an attempt, else the agent would drain again every
  # tick while the Mac stays loaded.
  if [ "${H_TRIES:-1}" -gt 1 ] && fsg__heal_docker_acts && ! fsg__heal_top_gate; then
    fsg_log "HEAL busy: top missed again before the Docker step; Docker left alone ($H_GATE_ERR)"
    fsg_heal_record refused-cannot-measure $(( $(fsg_now) - t0 ))
    [ "$HEAL_TRIGGER" = emergency ] && fsg_now > "$FSG_STATE_DIR/last-attempt"
    if [ "$HEAL_TRIGGER" != emergency ] || fsg_throttle heal-cannot-measure "$FSG_WARN_RENOTIFY_MIN"; then
      fsg_notify "fseventsd-guard: cannot heal" "cannot measure" \
        "top missed again before the Docker step; Docker left alone ($H_GATE_ERR; the precheck needed $H_TRIES tries). Nothing was stopped or restarted. Next: fseventsd-guard doctor."
    fi
    fsg_say "heal: cannot measure fseventsd before the Docker step ($H_GATE_ERR); Docker left alone, nothing was stopped or restarted"
    return 3
  fi
  rm_txt=""
  if fsg_docker_stops_containers "$HEAL_VARIANT"; then
    [ -n "$DK_EPHEMERAL" ] && rm_txt=" Removed by Docker step $HEAL_VARIANT (--rm: Docker deletes them when they stop; none has an anonymous volume): $DK_EPHEMERAL."
    fsg_docker_unchecked "$HEAL_VARIANT" &&
      rm_txt="$rm_txt Docker does not answer docker info (wedged), so it did not list its containers and --rm containers with an anonymous volume could not be checked: Docker deletes any it stops."
  fi
  if [ $drc -eq 10 ] || [ "$cut_n" -gt 0 ] || [ -n "$rm_txt" ]; then
    # After a drained wait (0) only runs started mid-drain are left to cut.
    [ "$cut_n" -gt 0 ] && cut_txt="Proceeding with $cut_n item(s) still running; they may fail: $(printf '%s\n' "$DRAIN_CUT" | head -n 4 | tr '\n' ';' | sed 's/;$//; s/;/; /g' | cut -c1-240)."
    [ "$DRAIN_UNKNOWN" = 1 ] && cut_txt="${cut_txt:-Proceeding.} $(fsg_drain_unknown_text cut)"
    cut_txt="$cut_txt$rm_txt$left"
    fsg_notify "fseventsd: cutting running work" "$HEAL_TRIGGER heal$( [ $drc -eq 10 ] && echo ", $( [ "$DRAIN_CAP_HIT" = ceiling ] && echo "emergency ceiling" || echo "cap $(fsg_dur "$DRAIN_CAP_HIT")")")" \
      "${cut_txt# }"
  fi
  if ! fsg_intent_write; then
    fsg_log "HEAL cannot write $FSG_DOCKER_INTENT; Docker left alone"
    fsg_heal_record intent-not-written $(( $(fsg_now) - t0 ))
    fsg_notify "fseventsd: heal not started" "cannot record the Docker step" \
      "Could not write $FSG_DOCKER_INTENT (disk full or state dir not writable), so a heal killed part way could leave Docker down unnoticed. Nothing was stopped. Next: free disk space, then fseventsd-guard heal."
    fsg_say "heal: cannot write the Docker intent $FSG_DOCKER_INTENT; nothing was stopped"
    return 10
  fi
  ts=$(fsg_now)
  # Every attempt that reaches Docker counts against the agent's emergency
  # interval, whether or not the restart then works (no restart loops); below the
  # helper floor, only an emergency heal's (fsg__heal_counts).
  fsg__heal_counts "$HEAL_MB_BEFORE" && fsg_now > "$FSG_STATE_DIR/last-attempt"
  HEAL_DK_PRE_DONE=1
  if ! fsg_docker_before "$HEAL_VARIANT"; then
    fsg_log "HEAL docker before-step failed: $DK_ERR (continuing: the restart is what heals Docker's file sharing)"
  fi
  T_DPRE=$(( $(fsg_now) - ts ))

  # --- Restart ---
  fsg_drain_phase restarting
  ts=$(fsg_now)
  # Bounded, so the phase budget runners see holds (sudo forwards the TERM).
  HEAL_ROOT_STAMP=$(head -n 1 "$FSG_ROOT_LOG_DIR/last-restart" 2>/dev/null)
  HEAL_IN_HELPER=1
  fsg_timeout "$FSG_HELPER_TIMEOUT_S" "$(fsg_root_tool sudo)" -n "$FSG_HELPER_PATH" > "$HEAL_DIR/helper.out" 2>&1
  HELPER_RC=$?
  HEAL_IN_HELPER=0
  T_RESTART=$(( $(fsg_now) - ts ))
  fsg__heal_helper_done

  # 72: restarted with SIGKILL after SIGTERM was ignored. 73: the signal went out
  # but the helper saw no respawn while it waited. launchd may still respawn it, so
  # wait for a new daemon before Docker is brought back.
  local healthy=0 restarted=0
  case $HELPER_RC in
    0|72|73)
      ts=$(fsg_now)
      fsg_drain_phase waiting-healthy
      fsg_wait_healthy "$old_pid" && healthy=1
      T_HEALTHY=$(( $(fsg_now) - ts )) ;;
  esac
  case $HELPER_RC in 0|72) restarted=1 ;; esac
  if [ $HELPER_RC -eq 73 ] && [ $healthy = 1 ]; then
    restarted=1
    fsg_log "HEAL fseventsd respawned after the helper stopped waiting (pid $M_PID)"
  fi

  # --- Docker after-step (always, so a failed restart still gets Docker back) ---
  fsg_drain_phase docker-after
  ts=$(fsg_now)
  local dk_ok=1
  HEAL_DK_POST_DONE=1
  fsg_intent_action
  fsg_docker_after "$HEAL_VARIANT" || { dk_ok=0; fsg_log "HEAL docker after-step failed: $DK_ERR"; }
  fsg_intent_engine
  # Containers it could not start stay to start for the recovery (after_done=0).
  [ $dk_ok = 1 ] && fsg_intent_set after_done 1
  T_DPOST=$(( $(fsg_now) - ts ))
  ts=$(fsg_now)
  DK_FAILED=
  if ! fsg_docker_off; then
    if ! fsg_docker_answers; then
      dk_ok=0; DK_ERR=${DK_ERR:-the Docker engine does not answer}; fsg_log "HEAL docker engine does not answer"
    elif ! fsg_docker_wait_containers; then
      # The first of the 2 failed passes after which the agent drops a container.
      dk_ok=0; fsg_log "HEAL containers not back: $DK_FAILED"
      fsg__recover_count "$DK_FAILED"
    fi
  fi
  T_CONT=$(( $(fsg_now) - ts ))

  # --- Verify (every path: held runs are released only onto a verified Docker) ---
  fsg_drain_phase verifying
  ts=$(fsg_now)
  BM_RESULT=skipped; BM_DETAIL=
  if [ $dk_ok = 1 ]; then
    fsg_docker_verify_bind_mount || dk_ok=0
  else
    BM_DETAIL="not checked: Docker not back"
  fi
  fsg_measure
  HEAL_MB_AFTER=$M_MB
  T_VERIFY=$(( $(fsg_now) - ts ))
  local wall=$(( $(fsg_now) - t0 )) held=""
  T_AFTER_DRAIN=$((wall - T_DRAIN))
  local dk_note="" nr_note="${DK_EPHEMERAL:+ Not restored (--rm, removed when stopped): $DK_EPHEMERAL.}"
  nr_note="$nr_note${DK_ONEOFF:+ Not restored (one-off, docker compose run: a start would run its command again): $DK_ONEOFF.}${DK_NOTE:+ $DK_NOTE.}"
  nr_note="$nr_note${DK_FOREIGN:+ Note: $DK_FOREIGN.}${BM_NOTE:+ $BM_NOTE}"
  [ "$HELPER_RC" = 72 ] && nr_note="$nr_note Note: fseventsd ignored SIGTERM for 10 s; the helper restarted it with SIGKILL."
  # A Docker that is not local was never touched nor checked: a hold in place
  # before the heal comes back.
  [ "$DK_STATE" = notlocal ] && dk_note=" Docker step skipped: not a local Docker engine ($DK_EP_WHY); no container was stopped, started or checked."
  if [ $dk_ok = 1 ]; then
    HEAL_DK_VERIFIED=1
    rm -f "$FSG_DOCKER_INTENT"
    if [ "$DK_STATE" = notlocal ]; then fsg_drain_end; else fsg_drain_end verified; fi
  elif fsg_drain_hold "$(fsg_docker_why)"; then
    # The intent stays until the agent sees Docker verified.
    HEAL_DK_HELD=1
    fsg_intent_set hold_epoch "$(fsg_now)"
    held=" $FSG_HOLD_NEXT."
  fi

  if [ $restarted = 0 ]; then
    fsg_heal_record restart-failed "$wall"
    fsg_notify "fseventsd: restart failed" "$(fsg_helper_meaning $HELPER_RC | cut -c1-60)" \
      "$(fsg_helper_meaning $HELPER_RC). $( [ -n "$dk_note" ] && echo "${dk_note# }" || { printf 'Docker was restored'; [ $dk_ok = 1 ] || printf ' only partly'; echo .; })$nr_note$held Next: fseventsd-guard doctor; log $FSG_LOG; manual fix: $FSG_MANUAL_FIX"
    fsg_say "heal: restart failed: $(fsg_helper_meaning $HELPER_RC)"
    return 7
  fi

  if [ $healthy = 1 ] && [ $dk_ok = 1 ]; then
    fsg_heal_record healed "$wall"
    rm -f "$FSG_STATE_DIR/wave-gave-up"
    fsg_log "HEAL done wall_s=$wall after_drain_s=$T_AFTER_DRAIN drain_s=$T_DRAIN variant=$HEAL_VARIANT bind_mount=$BM_RESULT"
    fsg_notify "fseventsd healed" "in $(fsg_dur "$wall") (drain $(fsg_dur "$T_DRAIN"))" \
      "Restarted (was $(fsg_size "${HEAL_MB_BEFORE:-0}")); $( [ -n "$dk_note" ] && echo "${dk_note# }" || echo "Docker step $HEAL_VARIANT ok, bind mount $BM_RESULT.")$nr_note $FSG_COSTS"
    echo "healed in $(fsg_dur "$wall") (drain $(fsg_dur "$T_DRAIN"), heal $(fsg_dur "$T_AFTER_DRAIN")); record: $HEAL_DIR"
    return 0
  fi
  local what=""
  [ $healthy = 1 ] || what="fseventsd did not come back healthy within ${FSG_HEALTHY_TIMEOUT_S}s"
  [ $dk_ok = 1 ] || what="${what:+$what; }Docker not fully restored ($(fsg_docker_why))"
  fsg_heal_record restored-partly "$wall"
  fsg_notify "fseventsd restarted, check needed" "heal incomplete" \
    "$what.$nr_note$held Next: fseventsd-guard status; docker desktop status; restart Docker Desktop if containers misbehave. Record: $HEAL_DIR"
  fsg_say "heal: incomplete: $what"
  return 8
}

# --- Background agent -----------------------------------------------------------------
# Releases a hold left by a heal that could not bring Docker back, once Docker
# answers, the containers it was restoring run (by name: compose may recreate
# them; healthy when they were before the heal) and a bind mount works. Trial holds
# wait for the operator.
fsg_tick_hold_check() {
  # An intent left after the recovery means Docker was just checked and failed.
  [ -f "$FSG_DOCKER_INTENT" ] && return 0
  fsg_drain_hold_active || return 0
  if [ "$(fsg__kv "$FSG_PENDING" trigger)" = trial ]; then
    fsg_log "TICK trial hold in place; waiting for: fseventsd-guard release"
    return 0
  fi
  fsg_docker_record
  if [ "$DK_RUNNING" != 1 ]; then fsg_log "TICK hold: Docker is $DK_STATE"; return 0; fi
  local hep
  hep=$(fsg__kv "$FSG_PENDING" endpoint)
  if [ -n "$hep" ] && ! fsg_docker_same_endpoint "$hep" "$DK_ENDPOINT"; then
    fsg_log "TICK hold: the Docker endpoint is now $DK_ENDPOINT, not the heal's $hep"; return 0
  fi
  DK_IDS=$(fsg__kv "$FSG_PENDING" restore_names); DK_HEALTH=$(fsg__kv "$FSG_PENDING" restore_health)
  if ! FSG_CONTAINER_TIMEOUT_S=0 fsg_docker_wait_containers; then
    fsg_log "TICK hold: containers not back: $DK_FAILED"; return 0
  fi
  if ! fsg_docker_verify_bind_mount; then fsg_log "TICK hold: bind mount $BM_RESULT: $BM_DETAIL"; return 0; fi
  rm -f "$FSG_PENDING"
  fsg_log "DRAIN hold released: Docker healthy again"
  fsg_notify "fseventsd-guard: held runs released" "Docker is back" \
    "Docker answers, the containers run and a bind mount works again; held test runs start now."
}

# The agent's heartbeat: rewritten as each tick starts (result=running) and as it
# ends (the level it found and its exit code). A tick that exits early, killed or
# through an emergency heal's exit, leaves result=running behind.
fsg_heartbeat_write() { # result exit
  local f="$FSG_STATE_DIR/heartbeat"
  mkdir -p "$FSG_STATE_DIR" 2>/dev/null
  printf 'epoch=%s\nresult=%s\nexit=%s\npid=%s\nlstart=%s\n' "$(fsg_now)" "$1" "${2:-}" "$$" "$(fsg_lstart $$)" \
    > "$f.new.$$" 2>/dev/null && mv -f "$f.new.$$" "$f" 2>/dev/null
}

# One agent round (docs/DESIGN.md §5.3): under the heal lock for the whole run,
# recover what an earlier tick left, serve the queued requests oldest first, check
# fseventsd once (the emergency tier), and serve requests that arrived meanwhile.
# Exits with the level found (0-3) or the emergency heal's code.
fsg_cmd_tick() {
  local rc
  TICK_LEVEL=unknown; TICK_REQ=; TICK_REQ_RC=; RECOVER_OUTCOME=; TICK_RECOVERING=0; RECOVER_C_WAIT=0; HEAL_IN_HELPER=0; FSG_TO_PID=
  fsg_heal_lock; rc=$?
  if [ $rc -eq 1 ]; then
    fsg_log "TICK the heal lock is held by pid $(fsg__kv "$FSG_STATE_DIR/heal.lock/owner" pid) (a tick run by hand?); that tick serves the queue"
    return 0
  elif [ $rc -ne 0 ]; then
    fsg_log "TICK cannot create the heal lock in $FSG_STATE_DIR (disk full or state dir not writable); queued requests wait"
    fsg_throttle lock-not-taken "$FSG_WARN_RENOTIFY_MIN" &&
      fsg_notify "fseventsd-guard: agent cannot run" "cannot take the heal lock" \
        "Could not create $FSG_STATE_DIR/heal.lock (disk full or state dir not writable), so the agent neither heals nor serves heal requests. Nothing was stopped. Next: free disk space."
    return 10
  fi
  # A heal stopped part way restores Docker and releases runs only onto a verified
  # Docker (fsg_tick_cleanup); launchd sends TERM at logout and on bootout.
  trap 'fsg_tick_cleanup' EXIT
  trap 'fsg_log "TICK interrupted by a signal"; exit 130' INT TERM HUP
  fsg_heartbeat_write running
  fsg_tick_round; rc=$?
  fsg_tick_cleanup
  trap - EXIT INT TERM HUP
  fsg_heartbeat_write "$TICK_LEVEL" "$rc"
  return "$rc"
}

# The tick's EXIT trap, and its normal end. A signal ends fsg_timeout's wait at
# once, not the Docker or helper command it bounds: runs are held first, then that
# command finishes under its own bound (a root restart or a Docker Desktop stop is
# never cut in half), and only then does the restore run what is left.
fsg_tick_cleanup() {
  local what rc
  fsg__heal_hold_first
  if [ -n "${FSG_TO_PID:-}" ]; then
    fsg_log "TICK waiting for the command the signal interrupted (pid $FSG_TO_PID) before the restore"
    fsg_timeout_wait; rc=$?
    if [ "${HEAL_IN_HELPER:-0}" = 1 ]; then HELPER_RC=$rc; fsg__heal_helper_done; fi
  fi
  HEAL_IN_HELPER=0
  fsg_recover_interrupted
  fsg_heal_cleanup
  if [ -n "${TICK_REQ:-}" ] && [ -e "$FSG_REQ_DIR/$TICK_REQ.result" ]; then
    TICK_REQ=
  elif [ -n "${TICK_REQ:-}" ] && [ -n "${TICK_REQ_RC:-}" ]; then
    # The heal had ended: its code stands.
    fsg_req_finish "$TICK_REQ" "$TICK_REQ_RC" "$(tail -n 1 "$FSG_REQ_DIR/$TICK_REQ.log" 2>/dev/null) (the agent was stopped after this heal ended)" "${HEAL_DIR:-}"
  elif [ -n "${TICK_REQ:-}" ]; then
    if [ "${HEAL_DK_VERIFIED:-0}" = 1 ]; then what="Docker was restored and verified"
    elif [ -f "$FSG_DOCKER_INTENT" ]; then what="Docker is not verified: new test runs stay held; the next tick restores and verifies it"
    else what="it had not touched Docker"; fi
    fsg_req_finish "$TICK_REQ" 130 "heal: the agent was stopped during this heal (logout, launchctl bootout, install); $what" "${HEAL_DIR:-}"
  fi
  fsg_heal_unlock
}

fsg_tick_round() {
  local erc=""
  fsg_tick_recover
  fsg_tick_hold_check
  fsg_req_orphans "$RECOVER_OUTCOME"
  while :; do
    fsg_tick_serve || break
    if [ -z "$erc" ]; then fsg_tick_check; erc=$?; fi
    fsg_req_queued || break
  done
  [ -n "$erc" ] || { fsg_tick_check; erc=$?; }
  fsg_req_prune
  return "$erc"
}

# Runs the queued requests, oldest first. 1 when one cannot be claimed (the queue
# is not writable): the next tick tries again.
fsg_tick_serve() {
  local f id
  while f=$(fsg_req_next); do
    id=$(basename "$f" .req)
    if ! mv "$f" "$FSG_REQ_DIR/$id.run" 2>/dev/null; then
      [ -e "$f" ] || continue
      fsg_log "TICK cannot claim request $id; the next tick tries again"
      return 1
    fi
    printf 'claimed_pid=%s\nclaimed_lstart=%s\n' "$$" "$(fsg_lstart $$)" >> "$FSG_REQ_DIR/$id.run" 2>/dev/null
    # A signal before this request's heal starts must not name the last one's.
    HEAL_DIR=; TICK_REQ_RC=; TICK_REQ=$id
    fsg_req_run "$id"
  done
  return 0
}

# A wave or manual request without --force joins a heal that reached its Docker
# step and ended after the request was written (in a later second: within the same
# second the order is unknown, and a request queued after that heal must run): a
# second drain right after it would hold every run again for nothing, or bounce
# Docker again after a failed restart. 0 when joined (the request then has that
# heal's result).
fsg_req_join() {
  local lh e r t code rec
  [ "$REQ_FORCE" = 0 ] && [ "$REQ_TRIGGER" != trial ] || return 1
  lh=$(head -n 1 "$FSG_STATE_DIR/last-heal" 2>/dev/null)
  # shellcheck disable=SC2086
  set -- $lh
  e=${1:-}; r=${2:-}; t=${3:-}
  fsg_is_uint "$e" && [ "$e" -gt "$REQ_TIME" ] || return 1
  case $r in healed) code=0 ;; restart-failed) code=7 ;; restored-partly) code=8 ;; *) return 1 ;; esac
  rec=$(printf '%s\n' "$lh" | cut -d' ' -f6-)
  fsg_log "REQUEST $REQ_ID_F joins the $t heal that ended at $e ($r)"
  fsg_req_finish "$REQ_ID_F" "$code" "heal: joined the $t heal that ended $(fsg_dur $(( $(fsg_now) - e ))) ago, after this request was queued ($r, exit $code); no second drain${rec:+. Record: $rec}" "$rec"
}

# Runs one claimed request (tick step 4): dropped, joined, refused or run. Its
# output goes to requests/<id>.log, its result to <id>.result.
fsg_req_run() { # id
  local id=$1 f="$FSG_REQ_DIR/$1.run" log="$FSG_REQ_DIR/$1.log" now rc
  now=$(fsg_now)
  if ! fsg_req_parse "$f" "$id"; then
    fsg_req_finish "$id" 64 "heal: request $id is not valid (field $REQ_BAD); not run"
    return
  fi
  if [ $((now - REQ_TIME)) -gt "$FSG_REQUEST_MAX_AGE_S" ]; then
    fsg_req_finish "$id" 13 "heal: request $id was $(fsg_dur $((now - REQ_TIME))) old when the agent took it (more than FSG_REQUEST_MAX_AGE_S: it was queued while the agent was unloaded or you were logged out); dropped, nothing was done"
    return
  fi
  if [ "$REQ_TRIGGER" = trial ] && ! fsg__alive "$REQ_PID" "$REQ_LSTART"; then
    fsg_req_finish "$id" 13 "trial: request $id dropped: its requester (pid $REQ_PID) is gone"
    return
  fi
  fsg_req_join && return
  if [ -f "$FSG_DOCKER_INTENT" ]; then
    fsg_req_finish "$id" 8 "heal: refused: the Docker step of an earlier heal (tick pid $(fsg__kv "$FSG_DOCKER_INTENT" owner_pid), $(fsg__kv "$FSG_DOCKER_INTENT" trigger), variant $(fsg__kv "$FSG_DOCKER_INTENT" variant)) is not verified, so no new heal starts; nothing was held or stopped. Ways out: the agent checks Docker again every $(fsg_dur "$FSG_AGENT_INTERVAL_S"), and stops restoring it $(fsg_dur "$FSG_FAILED_HOLD_S") after that heal's Docker step ran; or recover Docker by hand (docker desktop status; docker ps), then: fseventsd-guard release"
    return
  fi
  fsg_log "REQUEST $id run trigger=$REQ_TRIGGER variant=$REQ_VARIANT cap_s=$REQ_CAP on_cap=$REQ_POLICY force=$REQ_FORCE requester=$REQ_PID"
  HEAL_REQ_CHAIN=$REQ_CHAIN HEAL_REQ_PID=$REQ_PID HEAL_REQ_LSTART=$REQ_LSTART HEAL_REQ_WAITS=$REQ_WAITS
  if [ "$REQ_TRIGGER" = trial ]; then
    fsg_trial_run "$id"
  else
    fsg_heal_main "$REQ_TRIGGER" "$REQ_VARIANT" "$REQ_POLICY" "$REQ_CAP" "$REQ_FORCE" >> "$log" 2>&1; rc=$?
    TICK_REQ_RC=$rc
    fsg_req_finish "$id" "$rc" "$(tail -n 1 "$log" 2>/dev/null)" "${HEAL_DIR:-}"
  fi
  unset HEAL_REQ_CHAIN HEAL_REQ_PID HEAL_REQ_LSTART HEAL_REQ_WAITS
}

# Tick step 5: the emergency tier (docs/DESIGN.md §4), once per tick (a slow top is
# tried again; a tick blind after its tries counts once).
fsg_tick_check() {
  local mrc
  fsg_measure_retry; mrc=$?
  if [ $mrc -ne 0 ]; then
    # A blind guard must not be silent: after FSG_BLIND_NOTIFY_TICKS failed ticks
    # in a row, notify (once per renotify window).
    local n
    n=$(head -n 1 "$FSG_STATE_DIR/blind-ticks" 2>/dev/null)
    fsg_is_uint "$n" || n=0
    n=$((n + 1))
    mkdir -p "$FSG_STATE_DIR"; echo "$n" > "$FSG_STATE_DIR/blind-ticks"
    fsg_log "TICK cannot-measure n=$n \"$M_ERR\""
    if [ "$n" -ge "$FSG_BLIND_NOTIFY_TICKS" ] && fsg_throttle blind "$FSG_WARN_RENOTIFY_MIN"; then
      fsg_notify "fseventsd-guard cannot measure fseventsd" "$n checks in a row" \
        "$M_ERR. Until this clears the guard can neither warn nor heal. Next: fseventsd-guard doctor; fseventsd-guard status."
    fi
    return 3
  fi
  rm -f "$FSG_STATE_DIR/blind-ticks"
  DO_PROBE=$FSG_AGENT_PROBE
  P_RESULT=; P_LATENCY_MS=; P_START_MS=; P_DETAIL=; P_EID=
  if [ "$DO_PROBE" = 1 ]; then
    fsg_probe
    if [ "$P_RESULT" = stalled ]; then
      # Confirm: one slow probe on a machine at load 100+ is not a stall.
      fsg_probe
      [ "$P_RESULT" = stalled ] || fsg_log "TICK probe stalled once, then $P_RESULT (not counted)"
    fi
  fi
  fsg_tick_external_restart
  fsg_tick_sample
  fsg_classify 0
  TICK_LEVEL=$S_LEVEL
  fsg_log "TICK level=$S_LEVEL pid=$M_PID mb=$M_MB cmprs_mb=${M_CMPRS_MB:-} ports=${M_PORTS:-} cpu=${M_CPU:-} cpu_avg_pct=${T_CPU_PCT:-} cpu_streak=$T_CPU_STREAK up_s=${M_UP:-} swap_used_mb=$(fsg_parse_swap_mb "$(sysctl -n vm.swapusage 2>/dev/null)") probe=${P_RESULT:-skipped}${P_LATENCY_MS:+/${P_LATENCY_MS}ms}${P_START_MS:+ start_ms=$P_START_MS} eid=$P_EID ev_s=$T_EV_S"
  fsg_daily_add tick "$M_MB" "${T_CPU_PCT:--}" "${T_EV_S:--}"
  [ "$S_LEVEL" = ok ] && return 0
  [ -n "$C_STREAK" ] && fsg_log "TICK runaway by the cpu escalator: ${C_PCT}% of a core for $C_STREAK ticks at $M_MB MB"

  local now last_t=0 last_mb=0 renotify=0
  now=$(fsg_now)
  if [ -f "$FSG_STATE_DIR/last-notice" ]; then read -r last_t last_mb < "$FSG_STATE_DIR/last-notice"; fi
  fsg_is_uint "$last_t" || last_t=0
  fsg_is_uint "$last_mb" || last_mb=0
  if [ $((now - last_t)) -ge $((FSG_WARN_RENOTIFY_MIN * 60)) ] || [ "$M_MB" -ge $((last_mb * 2)) ]; then renotify=1; fi

  if [ "$S_LEVEL" = warn ]; then
    if [ $renotify = 1 ]; then
      mkdir -p "$FSG_STATE_DIR"; echo "$now $M_MB" > "$FSG_STATE_DIR/last-notice"
      fsg_notify "fseventsd at $(fsg_size "$M_MB")" "warn (budget $FSG_BUDGET_MB MB)" \
        "File watching may degrade. Next: run fseventsd-guard heal at a convenient point, such as before a long test run (it waits for running tests)."
    fi
    return 1
  fi

  # Runaway. An earlier heal's Docker that stays unverified refuses every new heal.
  if [ -f "$FSG_DOCKER_INTENT" ]; then
    fsg_log "TICK runaway; an earlier heal's Docker is not verified, so no emergency heal"
    fsg_throttle runaway-unverified "$FSG_WARN_RENOTIFY_MIN" &&
      fsg_notify "fseventsd runaway ($(fsg_size "$M_MB"))" "not healing: Docker not verified" \
        "An earlier heal's Docker step is not verified yet, so the agent starts no new heal. Next: get Docker back (docker desktop status; docker ps), then fseventsd-guard release; the agent heals at its next tick."
    return 2
  fi
  # The newest of: the guard's last restart, its last attempt that reached the
  # Docker step (a failing helper must not bounce Docker every tick), and the
  # root helper's own stamp (a restart made outside this state dir). Restarts and
  # attempts below the helper floor do not count (fsg__heal_counts), nor does a root
  # stamp no newer than the guard's last such restart: the helper wrote it first.
  local last_r=0 age stamp f low
  low=$(awk 'NR == 1 { print $1 }' "$FSG_STATE_DIR/last-restart-uncounted" 2>/dev/null)
  fsg_is_uint "$low" || low=0
  for f in "$FSG_STATE_DIR/last-restart" "$FSG_STATE_DIR/last-attempt" "$FSG_ROOT_LOG_DIR/last-restart"; do
    stamp=$(head -n 1 "$f" 2>/dev/null)
    fsg_is_uint "$stamp" || continue
    [ "$f" = "$FSG_ROOT_LOG_DIR/last-restart" ] && [ "$stamp" -le "$low" ] && continue
    [ "$stamp" -gt "$last_r" ] && last_r=$stamp
  done
  age=$((now - last_r))
  # A stamp in the future means the clock moved back; like the helper, ignore it.
  if [ "$last_r" -gt 0 ] && [ "$age" -ge 0 ] && [ "$age" -lt "$FSG_EMERGENCY_MIN_INTERVAL_S" ]; then
    fsg_log "TICK runaway within the emergency interval (last restart or attempt ${age}s ago); notify only"
    if [ $renotify = 1 ]; then
      mkdir -p "$FSG_STATE_DIR"; echo "$now $M_MB" > "$FSG_STATE_DIR/last-notice"
      fsg_notify "fseventsd runaway again ($(fsg_size "$M_MB"))" "not auto-healing" \
        "Last restart or attempt $(fsg_dur "$age") ago; the agent tries at most once per $(fsg_dur "$FSG_EMERGENCY_MIN_INTERVAL_S"). Next: fseventsd-guard heal (waits for running tests), or reduce file churn."
    fi
    return 2
  fi
  fsg_heal_main emergency "$FSG_DOCKER_VARIANT" "$FSG_CAP_POLICY_EMERGENCY" "$FSG_DRAIN_CAP_S" 0
}

# --- Docker trial (docs/DOCKER-TRIALS.md) ----------------------------------------------
# The caller side: a trial is a request the agent runs (fsg_trial_run). Its
# requester must stay: a trial whose requester is gone is dropped.
fsg_cmd_trial() {
  local variant="" label="run"
  while [ $# -gt 0 ]; do
    case $1 in
      --variant) variant=${2:-}; shift ;;
      --label) label=${2:-run}; shift ;;
      --summary) fsg_trial_summary; return 0 ;;
      --no-wait) fsg_say "trial: --no-wait is not supported: a trial whose requester is gone is dropped"; return 64 ;;
      -h|--help) echo "usage: fseventsd-guard trial --variant A|B|C|none [--label NAME] | --summary"; return 0 ;;
      *) fsg_say "trial: unknown option $1"; return 64 ;;
    esac
    shift
  done
  case $variant in A|B|C|none) ;; *) fsg_say "trial: --variant A|B|C|none is required"; return 64 ;; esac
  case $label in ''|*[!A-Za-z0-9_.-]*) fsg_say "trial: --label may use letters, digits, . _ - only"; return 64 ;; esac
  fsg_req_submit trial "$FSG_DRAIN_CAP_S" abort "$variant" 0 "$label" 0
}

# The agent side of a trial request: the records around one heal. The heal's output
# goes straight to heal.out, and the request log the caller streams is that file.
fsg_trial_run() { # id (REQ_* set by fsg_req_run)
  local id=$1 variant=$REQ_VARIANT label=$REQ_LABEL dir start rc hold=""
  dir="$FSG_STATE_DIR/trials/$(date +%Y%m%dT%H%M%S)-$variant-$label"
  mkdir -p "$dir"
  : > "$dir/heal.out"
  ln -sf "$dir/heal.out" "$FSG_REQ_DIR/$id.log"
  start=$(fsg_now)
  {
    echo "== docker desktop status"; fsg_timeout 20 docker desktop status 2>&1
    echo "== docker ps -a"; fsg_timeout 30 docker ps -a --format '{{.ID}} {{.Names}} {{.Status}}' 2>&1
    echo "== docker processes (pid, uptime)"; ps -axo pid=,etime=,command= | grep -i '[c]om\.docker' | cut -c1-160
    echo "== fseventsd"; fsg_cmd_status --probe 2>&1
  } > "$dir/before.txt"
  # Through the drain like every heal; a trial's cap policy is always abort.
  fsg_heal_main trial "$variant" abort "$REQ_CAP" 0 >> "$dir/heal.out" 2>&1; rc=$?
  TICK_REQ_RC=$rc
  if fsg_drain_hold_active; then
    hold="Docker is not fully back, so held test runs stay held (at most $(fsg_dur "$FSG_FAILED_HOLD_S")).
Recover Docker by hand (docker desktop restart; docker compose up -d), check it, then run: fseventsd-guard release"
  fi
  {
    echo "== docker desktop status"; fsg_timeout 20 docker desktop status 2>&1
    echo "== docker ps -a"; fsg_timeout 30 docker ps -a --format '{{.ID}} {{.Names}} {{.Status}}' 2>&1
    echo "== docker info (first lines)"; fsg_timeout 20 docker info 2>&1 | head -n 15
    echo "== docker processes (pid, uptime)"; ps -axo pid=,etime=,command= | grep -i '[c]om\.docker' | cut -c1-160
    echo "== fseventsd"; fsg_cmd_status --probe 2>&1
  } > "$dir/after.txt"
  # -S takes a time span ("300s"), not a timestamp; a minute of margin covers clock steps.
  fsg_timeout 60 docker desktop logs --no-color -p 1 -S "$(( $(fsg_now) - start + 60 ))s" > "$dir/desktop-logs-warn.txt" 2>&1
  [ -n "${HEAL_DIR:-}" ] && [ -f "$HEAL_DIR/result.txt" ] && cp "$HEAL_DIR/result.txt" "$dir/result.txt"
  {
    echo "variant=$variant label=$label heal_exit=$rc"
    [ -f "$dir/result.txt" ] && cat "$dir/result.txt"
  } > "$dir/summary.txt"
  fsg_req_finish "$id" "$rc" "trial $variant ($label): record in $dir
$(cat "$dir/summary.txt")
$hold
files: $dir/{before.txt,heal.out,after.txt,desktop-logs-warn.txt,summary.txt}" "$dir"
}

# One markdown row per recorded trial, for docs/DOCKER-TRIALS.md "Results".
fsg_trial_summary() {
  local f
  echo "| trial | variant | heal exit | result | heal after drain (s) | drain (s) | docker before (s) | restart (s) | healthy (s) | docker after (s) | containers (s) | verify (s) | bind mount | containers not back |"
  echo "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"
  for f in "$FSG_STATE_DIR"/trials/*/summary.txt; do
    [ -f "$f" ] || continue
    awk -v name="$(basename "$(dirname "$f")")" '
      NR == 1 { for (i = 1; i <= NF; i++) { split($i, kv, "="); h[kv[1]] = kv[2] } next }
      { k = $0; sub(/=.*/, "", k); v = $0; sub(/^[^=]*=/, "", v); r[k] = v }
      END { printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", name, h["variant"], h["heal_exit"],
              r["result"], r["heal_s_after_drain"], r["drain_s"], r["docker_before_s"], r["restart_s"], r["healthy_s"],
              r["docker_after_s"], r["containers_s"], r["verify_s"], r["bind_mount"], r["containers_failed"] }' "$f"
  done
}
