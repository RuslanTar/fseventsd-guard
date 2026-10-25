# shellcheck shell=sh
# fseventsd-guard run leases: the runner side of the drain.
#
# A run that depends on Docker holds a LEASE while it runs. Before a heal stops
# Docker, the guard marks a drain as pending and waits until every live lease has
# ended. A run that starts while a drain is pending waits for the heal to finish.
#
# Sourceable from sh, bash 3.2 and zsh, safe under `set -eu`. It never blocks a run
# because the guard's state is unusable: on any internal problem it lets the run go.
#
# Two ways to take a lease:
#   fseventsd-guard run --label NAME -- CMD ARGS...   (wraps CMD, then execs it)
#   . ".../lib/lease.sh" && fsg_lease_acquire NAME || exit $?
#     (for scripts that cannot be wrapped; see docs/WORKFLOW-INTEGRATION.md)
#
# A lease is a file named after the process id. It records the pid and the process
# start time; a lease counts as live only while that same process is alive, so a
# reused pid never keeps a dead lease alive and a script that ends in `exec CMD`
# keeps its lease for CMD's whole run (exec keeps the pid and the start time).
# Releasing on exit is a courtesy; the guard reaps leases of dead processes.
# While a run waits for a drain it holds a PID.held marker instead, so the heal's
# fallback detection does not count it as running work. A heal's unverified Docker
# intent holds runs the same way, even when no tick is alive (fsg_intent_hold_active).
#
# Return codes of fsg_lease_acquire: 0 = go, 75 = gave up waiting for a drain.

fsg__state_dir() {
  printf '%s\n' "${FSG_STATE_DIR:-$HOME/Library/Application Support/fseventsd-guard}"
}

# Prints the start time of a process with runs of spaces squeezed, or nothing.
# ps formats lstart with strftime %c in the caller's TZ and locale, so the writer
# (a teammate's shell with LANG=de_DE or a TZ override) and the reader (the launchd
# agent, which has neither) would print different text for the same process.
# Pinning both makes the text a stable identity.
fsg__lstart() {
  LC_ALL=C TZ=UTC0 ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' | sed 's/^ //; s/ $//'
}

# Prints the value of KEY in a KEY=VALUE file.
fsg__kv() {
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1
}

# 0 when PID is alive and still the process that started at LSTART.
fsg__alive() {
  case ${1:-x} in *[!0-9]*) return 1 ;; esac
  [ -n "${2:-}" ] || return 1
  [ "$(fsg__lstart "$1")" = "$2" ]
}

# Reads a runner-side knob: environment first, then the user config, then DEFAULT.
# Config lines are read as fsg_parse_config reads them: leading whitespace and a
# trailing whitespace-# comment do not belong to the value.
fsg__knob() {
  eval "_fsg_v=\${$1:-}"
  if [ -z "$_fsg_v" ]; then
    _fsg_v=$(sed -n "s/^[[:space:]]*$1=//p" "$(fsg__state_dir)/config" 2>/dev/null | tail -n 1 |
      sed 's/[[:space:]][[:space:]]*#.*$//; s/[[:space:]]*$//' | tr -d "\"'")
  fi
  [ -n "$_fsg_v" ] || _fsg_v=$2
  printf '%s\n' "$_fsg_v"
}

# 0 when a drain is pending: the file exists, its owner process is alive, and its
# deadline has not passed. A drain whose owner died or overran is ignored, so a
# crashed heal can never block runs for good.
fsg_drain_active() {
  _fsg_df="$(fsg__state_dir)/drain/pending"
  [ -f "$_fsg_df" ] || return 1
  # A hold left by a heal that could not bring Docker back outlives the heal; it
  # lasts until its own deadline, capped at FSG_FAILED_HOLD_S after it was set.
  _fsg_hu=$(fsg__kv "$_fsg_df" hold_until_epoch)
  if [ -n "$_fsg_hu" ]; then
    case $_fsg_hu in *[!0-9]*) return 1 ;; esac
    _fsg_hs=$(fsg__kv "$_fsg_df" started_epoch)
    _fsg_hc=$(fsg__knob FSG_FAILED_HOLD_S 3600)
    case $_fsg_hs$_fsg_hc in ''|*[!0-9]*) ;; *) [ "$_fsg_hu" -le $((_fsg_hs + _fsg_hc)) ] || _fsg_hu=$((_fsg_hs + _fsg_hc)) ;; esac
    [ "$(date +%s)" -le "$_fsg_hu" ]
    return
  fi
  fsg__alive "$(fsg__kv "$_fsg_df" owner_pid)" "$(fsg__kv "$_fsg_df" owner_lstart)" || return 1
  _fsg_dl=$(fsg__kv "$_fsg_df" deadline_epoch)
  case ${_fsg_dl:-x} in *[!0-9]*) return 1 ;; esac
  [ "$(date +%s)" -le "$_fsg_dl" ]
}

# 0 while a heal's Docker intent says Docker may be down by the guard's hand: the
# heal writes it before its Docker before-step and removes it once Docker verified.
# A tick killed outright (SIGKILL) leaves its drain ownerless and no hold, so this
# holds runs without the agent: from the intent's start for A and B (their
# before-step stops Docker), from its after-step action for any variant (C restarts
# Docker Desktop there), for FSG_FAILED_HOLD_S, or until `fseventsd-guard release`
# removes it. Variants skip and none never touch Docker.
fsg_intent_hold_active() {
  _fsg_if="$(fsg__state_dir)/docker-intent"
  [ -f "$_fsg_if" ] || return 1
  _fsg_it=
  [ "$(fsg__kv "$_fsg_if" action_ran)" = 1 ] && _fsg_it=$(fsg__kv "$_fsg_if" action_epoch)
  case ${_fsg_it:-x} in
    *[!0-9]*)
      case $(fsg__kv "$_fsg_if" variant) in A|B) ;; *) [ "$(fsg__kv "$_fsg_if" action_ran)" = 1 ] || return 1 ;; esac
      _fsg_it=$(fsg__kv "$_fsg_if" started_epoch) ;;
  esac
  case ${_fsg_it:-x} in *[!0-9]*) return 1 ;; esac
  # The shorter of the agent's FSG_FAILED_HOLD_S (hold_s) and this run's.
  _fsg_ic=$(fsg__knob FSG_FAILED_HOLD_S 3600)
  case ${_fsg_ic:-x} in *[!0-9]*) _fsg_ic=3600 ;; esac
  _fsg_is=$(fsg__kv "$_fsg_if" hold_s)
  case ${_fsg_is:-x} in *[!0-9]*) ;; *) [ "$_fsg_is" -ge "$_fsg_ic" ] || _fsg_ic=$_fsg_is ;; esac
  [ "$(date +%s)" -le $((_fsg_it + _fsg_ic)) ]
}

fsg__lease_write() {
  _fsg_tmp="$1.tmp.$$"
  {
    printf 'pid=%s\n' "$$"
    printf 'lstart=%s\n' "$2"
    printf 'label=%s\n' "$3"
    printf 'started_epoch=%s\n' "$(date +%s)"
    printf 'cwd=%s\n' "$PWD"
    printf 'cmd=%s\n' "$(ps -o command= -p "$$" 2>/dev/null | cut -c1-300)"
  } > "$_fsg_tmp" 2>/dev/null && mv -f "$_fsg_tmp" "$1" 2>/dev/null
}

fsg_lease_acquire() {
  _fsg_label=$(printf '%s' "${1:-unnamed}" | tr -d '\n' | cut -c1-120)
  [ "${FSG_DISABLE:-0}" = 1 ] && return 0
  # Not installed (no app copy, as after uninstall): no heal to wait for, and a lease
  # file here would re-create the state dir with nothing left to reap it.
  [ -d "$(fsg__state_dir)/app" ] || return 0

  # Nested runs (a wrapped script calling another wrapped script) inherit the
  # outer lease; taking a second one would wait on the drain the outer one holds up.
  if [ -n "${FSG_LEASE_FILE:-}" ] && [ -f "${FSG_LEASE_FILE:-}" ]; then
    if fsg__alive "$(fsg__kv "$FSG_LEASE_FILE" pid)" "$(fsg__kv "$FSG_LEASE_FILE" lstart)"; then
      return 0
    fi
  fi

  _fsg_ldir="$(fsg__state_dir)/drain/leases"
  mkdir -p "$_fsg_ldir" 2>/dev/null || return 0
  _fsg_lst=$(fsg__lstart "$$")
  [ -n "$_fsg_lst" ] || return 0
  _fsg_lf="$_fsg_ldir/$$.lease"
  _fsg_max=$(fsg__knob FSG_RUN_MAX_WAIT_S 0)
  _fsg_pol=$(fsg__knob FSG_RUN_ON_TIMEOUT fail)
  _fsg_poll=$(fsg__knob FSG_RUN_POLL_S 5)
  case $_fsg_max in ''|*[!0-9]*) _fsg_max=0 ;; esac
  case $_fsg_poll in ''|*[!0-9]*) _fsg_poll=5 ;; esac
  _fsg_t0=$(date +%s)
  _fsg_said=-1

  while :; do
    # Lease first, then look for a drain. The guard marks the drain first, then
    # counts leases. Either it sees this lease or this run sees its drain.
    fsg__lease_write "$_fsg_lf" "$_fsg_lst" "$_fsg_label" || { rm -f "$_fsg_ldir/$$.held"; return 0; }
    if fsg_drain_active; then _fsg_hi=0; elif fsg_intent_hold_active; then _fsg_hi=1; else break; fi
    rm -f "$_fsg_lf"
    # Marks this run as held, so the heal neither waits for it nor reports it cut.
    [ -f "$_fsg_ldir/$$.held" ] || fsg__lease_write "$_fsg_ldir/$$.held" "$_fsg_lst" "$_fsg_label"
    _fsg_w=$(( $(date +%s) - _fsg_t0 ))
    if [ "$_fsg_max" -gt 0 ] && [ "$_fsg_w" -ge "$_fsg_max" ]; then
      rm -f "$_fsg_ldir/$$.held"
      if [ "$_fsg_pol" = proceed ]; then
        echo "fseventsd-guard: '$_fsg_label' waited ${_fsg_w}s for a heal; starting anyway (FSG_RUN_ON_TIMEOUT=proceed)" >&2
        fsg__lease_write "$_fsg_lf" "$_fsg_lst" "$_fsg_label" || return 0
        break
      fi
      echo "fseventsd-guard: '$_fsg_label' gave up after waiting ${_fsg_w}s for a heal (FSG_RUN_MAX_WAIT_S=$_fsg_max). Check: fseventsd-guard status" >&2
      return 75
    fi
    if [ "$_fsg_said" -lt 0 ] || [ $((_fsg_w - _fsg_said)) -ge 60 ]; then
      _fsg_df="$(fsg__state_dir)/drain/pending"
      if [ "$_fsg_hi" = 1 ]; then
        _fsg_ph=docker-not-verified
        _fsg_rs="the heal of tick pid $(fsg__kv "$_fsg_if" owner_pid) ended before Docker verified (after recovering Docker by hand: fseventsd-guard release)"
      else
        _fsg_ph=$(fsg__kv "$_fsg_df" phase); _fsg_rs=$(fsg__kv "$_fsg_df" reason)
      fi
      echo "fseventsd-guard: holding '$_fsg_label' while fseventsd is healed (phase $_fsg_ph, reason: $_fsg_rs); waited ${_fsg_w}s. It starts by itself when the heal ends." >&2
      _fsg_said=$_fsg_w
    fi
    sleep "$_fsg_poll"
  done
  rm -f "$_fsg_ldir/$$.held"
  FSG_LEASE_FILE=$_fsg_lf
  export FSG_LEASE_FILE
  return 0
}

fsg_lease_release() {
  if [ -n "${FSG_LEASE_FILE:-}" ] && [ "$(fsg__kv "$FSG_LEASE_FILE" pid)" = "$$" ]; then
    rm -f "$FSG_LEASE_FILE"
  fi
  unset FSG_LEASE_FILE
  return 0
}
