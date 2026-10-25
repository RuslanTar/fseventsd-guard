# shellcheck shell=bash
# fseventsd-guard Claude Code hooks: `fseventsd-guard claude-hook prompt|bash`, run by
# the plugin's hooks/fseventsd-guard-hook.sh. Each prints one hook JSON object on
# stdout or nothing, and returns 0: a hook never blocks a prompt or a tool call. They
# run on every prompt and Bash call, so the entry script loads only this file and
# what it sources here.
#
#   prompt  UserPromptSubmit: the install nudge (fsg_hint_prompt)
#   bash    PreToolUse and PostToolUse on Bash: the heal notice (fsg_hint_bash)
#
# FSG_HINT=0 in Claude Code's environment, or a file $FSG_HINT_DIR/off, silences them.
#
# The hooks run from the plugin's copy, which a plugin update can make newer or older
# than the installed agent that writes the state they read: a state file they do not
# fully know makes them say nothing (fsg_hint_heal).

# Where the guard is published, and where the nudge's install command clones it.
FSG_HINT_REPO=https://github.com/RuslanTar/fseventsd-guard
# shellcheck disable=SC2088 # shown to the user, who runs it in a shell
FSG_HINT_CLONE="~/fseventsd-guard"

# shellcheck source=lib/common.sh
. "$FSG_HOME/lib/common.sh"
# shellcheck source=lib/lease.sh
. "$FSG_HOME/lib/lease.sh"

fsg_cmd_claude_hook() { # prompt|bash
  case ${FSG_HINT:-1} in 0|[Nn][Oo]|[Oo][Ff][Ff]|[Ff][Aa][Ll][Ss][Ee]) return 0 ;; esac
  [ "$(uname -s 2>/dev/null)" = Darwin ] || return 0
  fsg_init_paths
  [ -e "$FSG_HINT_DIR/off" ] && return 0
  case ${1:-} in
    prompt) fsg_hint_prompt ;;
    bash) fsg_hint_bash ;;
  esac
  return 0
}

# 0 when any part of the guard is installed for this user: the agent's plist or the
# app copy, as doctor and uninstall look for them.
fsg_hint_installed() { [ -f "$FSG_PLIST" ] || [ -d "$FSG_STATE_DIR/app" ]; }

# 0 once an install got past its root steps: the agent's plist or the root helper. An
# install stopped at the root question or at sudo leaves only the app copy, and the
# nudge goes on.
fsg_hint_nudge_done() { [ -f "$FSG_PLIST" ] || [ -e "$FSG_HELPER_PATH" ]; }

# The epoch in the hint stamp NAME, or nothing.
fsg_hint_stamp() {
  local v=
  read -r v 2>/dev/null < "$FSG_HINT_DIR/$1"
  fsg_is_uint "$v" && printf '%s' "$v"
}

# Seconds between two install nudges at a level.
fsg_hint_every() { case $1 in runaway) echo 3600 ;; warn) echo 10800 ;; *) echo 86400 ;; esac; }

# The install nudge, on an affected Mac without the guard: fseventsd's footprint and
# what to run, at most every hour (runaway), 3 hours (warn) or day (ok); a nudge at
# one level counts for the levels below it too. The stamps are shared by every
# session of the user and read before anything is measured, so a prompt costs a
# read; the measurement (top takes about 2 s) runs at most once an hour.
fsg_hint_prompt() {
  local now t l every
  fsg_hint_nudge_done && return 0
  now=$(fsg_now)
  t=$(fsg_hint_stamp checked)
  [ -n "$t" ] && [ $((now - t)) -ge 0 ] && [ $((now - t)) -lt 3600 ] && return 0
  # Stamped first: a measurement that hangs until the hook's timeout is not tried
  # again on the next prompt.
  { mkdir -p "$FSG_HINT_DIR" && echo "$now" > "$FSG_HINT_DIR/checked"; } 2>/dev/null || return 0
  fsg_load_config 2>/dev/null
  fsg_affected
  [ "$FSG_AFF" = yes ] || return 0
  # shellcheck source=lib/measure.sh
  . "$FSG_HOME/lib/measure.sh"
  fsg_measure || return 0
  P_RESULT=
  fsg_classify 0
  every=$(fsg_hint_every "$S_LEVEL")
  for l in runaway warn ok; do
    t=$(fsg_hint_stamp "last-$l")
    [ -n "$t" ] && [ $((now - t)) -ge 0 ] && [ $((now - t)) -lt "$every" ] && return 0
    [ "$l" = "$S_LEVEL" ] && break
  done
  echo "$now" 2>/dev/null > "$FSG_HINT_DIR/last-$S_LEVEL" || return 0
  fsg_hint_nudge_json
}

# The nudge as hook JSON: a short warning for the user (systemMessage) and the facts
# for Claude (additionalContext), as Claude Code may not show the first on a prompt.
fsg_hint_nudge_json() {
  local g size x lead every cmd doc off ctx msg
  g="$FSG_HINT_CLONE/plugins/fseventsd-guard/fseventsd-guard"
  size=$(fsg_size "$M_MB")
  if [ "$M_MB" -lt "$FSG_BUDGET_MB" ] || [ "$FSG_BUDGET_MB" -eq 0 ]; then
    x="within Apple's $FSG_BUDGET_MB MB budget"
  else
    x="$(awk -v m="$M_MB" -v b="$FSG_BUDGET_MB" 'BEGIN { printf "%.0f", m / b }')x Apple's $FSG_BUDGET_MB MB budget"
  fi
  case $S_LEVEL in
    runaway) lead="fseventsd is running away: $size, $x"; every="once an hour" ;;
    warn) lead="fseventsd is growing: $size, $x"; every="every 3 hours" ;;
    *) lead="fseventsd is fine now ($size, $x), but it can grow"; every="once a day" ;;
  esac
  # An older clone is brought up to date first: install would install its release.
  cmd="if [ -d $FSG_HINT_CLONE ]; then git -C $FSG_HINT_CLONE pull --ff-only; else git clone $FSG_HINT_REPO.git $FSG_HINT_CLONE; fi && $g install"
  doc="$FSG_HINT_REPO#readme"
  off=$FSG_HINT_DIR
  case $off in "$HOME"/*) off="~${off#"$HOME"}" ;; esac
  msg="fseventsd-guard: $lead (up $(fsg_dur "${M_UP:-0}")). On macOS $FSG_OS_VER it can grow without limit and silently stop delivering file events. Install the guard in a new terminal window (it asks for sudo): $cmd. Why: $doc. Silence: FSG_HINT=0, or mkdir -p $off && touch $off/off"
  off="$off/off"
  ctx="fseventsd-guard install hint (from its Claude Code plugin; $every at this level). Measured now: fseventsd, the macOS file-events daemon, has a footprint of $M_MB MB ($x), uptime $(fsg_dur "${M_UP:-0}"), level $S_LEVEL (the guard warns at $FSG_WARN_MB MB and heals at $FSG_ACT_MB MB). On macOS $FSG_OS_VER fseventsd has a known bug: its memory grows without limit and it silently stops delivering file events, so the IDE, dev servers, Docker bind mounts and Claude Code stop seeing file changes until it is restarted as root. fseventsd-guard, which restarts it safely (it lets test runs finish and brings Docker back), is not installed here. Install asks for sudo, so it runs in a new terminal window, not through Claude: $cmd, then the same path with doctor. Why and what it costs: $doc. The hint stops once the guard is installed; FSG_HINT=0 in Claude Code's environment, or a file $off, silences it. The user has not been told about this in the conversation yet."
  printf '{"systemMessage":%s,"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":%s}}\n' \
    "$(fsg_json_str "$msg")" "$(fsg_json_str "$ctx")"
}

# The heal notice, with the guard installed: while a heal drains, works on Docker or
# leaves runs held, and for 10 minutes after one ended, what it does to Docker and
# what that means for commands, once per heal, phase and session (and subagent). It
# runs before and after every Bash call, so with no heal it reads at most one small
# file, and it never measures fseventsd or asks Docker.
fsg_hint_bash() {
  local now= e rest key dir stamp ctx
  fsg_hint_installed || return 0
  { [ -f "$FSG_PENDING" ] || [ -f "$FSG_DOCKER_INTENT" ]; } && now=$(fsg_now)
  if [ ! -f "$FSG_DOCKER_INTENT" ] && { [ ! -f "$FSG_PENDING" ] || ! fsg_hint_marker_live "$now"; }; then
    e=; read -r e rest 2>/dev/null < "$FSG_STATE_DIR/last-heal"
    fsg_is_uint "$e" || return 0
    now=${now:-$(fsg_now)}
    [ $((now - e)) -ge 0 ] && [ $((now - e)) -lt 600 ] || return 0
  fi
  fsg_hint_heal "${now:-$(fsg_now)}" || return 0
  fsg_hint_input || return 0
  case $HI_EVENT in PreToolUse|PostToolUse) ;; *) return 0 ;; esac
  key=$HI_SID${HI_AGENT:+.$HI_AGENT}
  key=${key//[!A-Za-z0-9_.-]/_}
  key=${key:0:120}
  dir=${TMPDIR:-/tmp}; dir="${dir%/}/fseventsd-guard-hook"
  stamp="$dir/${key:-none}-$HN_PHASE-$HN_ID"
  [ -e "$stamp" ] && return 0
  ctx=$(fsg_hint_heal_text) || return 0
  # No stamp, no notice: else it would repeat on every call.
  { mkdir -p "$dir" && : > "$stamp"; } 2>/dev/null || return 0
  # Other sessions' and heals' stamps go after a day.
  find "$dir" -type f -mtime +0 -delete 2>/dev/null
  printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":%s}}\n' "$HI_EVENT" "$(fsg_json_str "$ctx")"
}

# 0 unless the drain marker is past its deadline (a drain) or its end (a hold), as the
# one a killed heal leaves until the next heal replaces it. Read with builtins: such a
# marker can stay for days, and this runs on every Bash call.
fsg_hint_marker_live() { # now
  local k v t=
  while IFS='=' read -r k v; do
    case $k in deadline_epoch|hold_until_epoch) t=$v ;; esac
  done 2>/dev/null < "$FSG_PENDING"
  fsg_is_uint "$t" && [ "$1" -le "$t" ]
}

# The heal as the guard's state files tell it. Sets HN_PHASE (draining: waiting for
# runs, Docker untouched; docker: the Docker step and the restart; held: it ended
# before Docker verified and runs are held; ended: in the last 10 minutes), HN_ID (one
# per heal and phase), HN_AT (when it began, or for held when it ended), HN_TRIGGER,
# HN_VARIANT, HN_STEP (the drain's phase), HN_WHY (held), HN_RESULT and HN_WALL
# (ended: from last-heal). 1 when there is no heal to tell of, or when a field is one
# this copy does not know (a state version, phase, trigger, variant or result).
fsg_hint_heal() { # now
  local f=$FSG_PENDING i=$FSG_DOCKER_INTENT line="" e r t v w rest
  HN_PHASE=; HN_ID=; HN_AT=; HN_TRIGGER=; HN_VARIANT=; HN_STEP=; HN_WHY=; HN_RESULT=; HN_WALL=
  if [ -f "$f" ] && fsg_drain_active; then
    [ "$(fsg__kv "$f" state_version)" = "$FSG_STATE_VERSION" ] || return 1
    HN_ID=$(fsg__kv "$f" started_epoch); HN_AT=$HN_ID
    HN_TRIGGER=$(fsg__kv "$f" trigger); HN_VARIANT=$(fsg__kv "$f" variant); HN_STEP=$(fsg__kv "$f" phase)
    [ -n "$HN_VARIANT" ] || HN_VARIANT=$(fsg__kv "$i" variant)
    fsg_hint_known "$HN_STEP" draining docker-before restarting waiting-healthy docker-after verifying held-docker-not-restored || return 1
    if [ -n "$(fsg__kv "$f" hold_until_epoch)" ]; then
      HN_PHASE=held; HN_WHY=$(fsg__kv "$f" reason | cut -c1-200)
    elif [ "$HN_STEP" = draining ]; then HN_PHASE=draining
    else HN_PHASE=docker; fi
  elif [ -f "$i" ]; then
    [ "$(fsg__kv "$i" state_version)" = "$FSG_STATE_VERSION" ] || return 1
    # A tick killed outright leaves its intent, and no live drain: runs hold behind it.
    HN_ID=$(fsg__kv "$i" started_epoch); HN_AT=$HN_ID
    HN_TRIGGER=$(fsg__kv "$i" trigger); HN_VARIANT=$(fsg__kv "$i" variant)
    if fsg__alive "$(fsg__kv "$i" owner_pid)" "$(fsg__kv "$i" owner_lstart)"; then HN_PHASE=docker
    elif fsg_intent_hold_active; then HN_PHASE=held; HN_WHY="its agent tick stopped before Docker verified"; fi
  fi
  if [ -n "$HN_PHASE" ]; then
    fsg_is_uint "$HN_ID" && fsg_hint_known "$HN_TRIGGER" "$FSG_HINT_TRIGGERS" && fsg_hint_variant "$HN_VARIANT"
    return
  fi
  # last-heal: epoch result trigger variant wall_s record-dir, one space apart; the
  # variant is empty for a heal that ended before its Docker step was chosen.
  read -r line 2>/dev/null < "$FSG_STATE_DIR/last-heal"
  IFS='|' read -r e r t v w rest <<EOF
${line// /|}
EOF
  fsg_is_uint "$e" && [ $(($1 - e)) -ge 0 ] && [ $(($1 - e)) -lt 600 ] || return 1
  case $r in refused-?*) ;; *) fsg_hint_known "$r" "$FSG_HINT_RESULTS" || return 1 ;; esac
  fsg_hint_known "$t" "$FSG_HINT_TRIGGERS" && fsg_hint_variant "$v" && fsg_is_uint "$w" || return 1
  HN_PHASE=ended; HN_ID=$e; HN_RESULT=$r; HN_TRIGGER=$t; HN_VARIANT=$v; HN_WALL=$w
  return 0
}

# The values of the state fields this copy knows.
FSG_HINT_TRIGGERS="emergency manual wave trial"
FSG_HINT_RESULTS="healed restart-failed restored-partly aborted-at-cap drain-not-marked intent-not-written"

# 0 when VALUE is one of the WORDS: a plain word, not empty.
fsg_hint_known() { # value words...
  local v=${1:-}
  shift
  case $v in ''|*[!A-Za-z0-9-]*) return 1 ;; esac
  case " $* " in *" $v "*) return 0 ;; esac
  return 1
}

# 0 for a Docker variant this copy knows, or none recorded yet.
fsg_hint_variant() { [ -z "${1:-}" ] || fsg_hint_known "$1" A B C none skip; }

# Session, event and subagent of the hook's stdin JSON: HI_SID, HI_EVENT, HI_AGENT
# (string values without escapes; the fields come first, so 64 KB is plenty, and the
# rest is read so Claude Code's write does not fail). 1 without stdin.
fsg_hint_input() {
  local us
  HI_SID=; HI_EVENT=; HI_AGENT=
  [ -t 0 ] && return 1
  us=$(printf '\037')
  IFS=$us read -r HI_SID HI_EVENT HI_AGENT <<EOF
$( { head -c 65536; cat > /dev/null; } 2>/dev/null | tr '\n' ' ' | awk -v us="$us" '
  function field(k,   s) {
    if (!match($0, "\"" k "\"[ \t]*:[ \t]*\"[^\"\\\\]*\"")) return ""
    s = substr($0, RSTART, RLENGTH); sub(/^[^:]*:[ \t]*"/, "", s); sub(/"$/, "", s)
    return s
  }
  { printf "%s%s%s%s%s\n", field("session_id"), us, field("hook_event_name"), us, field("agent_id") }')
EOF
  return 0
}

# What a Docker step does, in a few words.
fsg_hint_step() { # variant
  case $1 in
    A) echo "Docker step A: it stops the running containers before the fseventsd restart and starts them again after" ;;
    B) echo "Docker step B: it quits Docker Desktop before the fseventsd restart, then starts it and the containers again" ;;
    C) echo "Docker step C: it restarts Docker Desktop after the fseventsd restart and starts the containers again" ;;
    none) echo "Docker step none: it leaves Docker alone" ;;
    skip) echo "no Docker step: Docker is stopped or not a local engine, so it is left alone" ;;
    *) echo "its Docker step is not recorded (A stops the containers, B quits and restarts Docker Desktop, C restarts Docker Desktop)" ;;
  esac
}

# The notice for the heal fsg_hint_heal found, as plain statements. Its commands name
# the installed app copy, the agent's own version, as the session's project may hold
# no checkout of the guard.
fsg_hint_heal_text() {
  local g="$FSG_STATE_DIR/app/fseventsd-guard" at r docker=1 out
  case $g in "$HOME"/*) g="\$HOME${g#"$HOME"}" ;; esac
  g="\"$g\""
  at=$(date -r "$HN_AT" +%H:%M 2>/dev/null)
  case $HN_VARIANT in none|skip) docker=0 ;; esac
  case $HN_PHASE in
    draining)
      out="fseventsd-guard is healing fseventsd on this Mac: a heal began at $at (trigger ${HN_TRIGGER:-?}; $(fsg_hint_step "$HN_VARIANT")). It is waiting for runs that started before it to finish (the drain); Docker is untouched until then."
      [ $docker = 1 ] && out="$out After that, until the heal ends, docker, docker compose and test commands may fail, hang or find Docker stopped." ;;
    docker)
      out="fseventsd-guard is healing fseventsd on this Mac: a heal began at $at (trigger ${HN_TRIGGER:-?}; $(fsg_hint_step "$HN_VARIANT")) and is in its Docker step and fseventsd restart (phase ${HN_STEP:-docker})."
      [ $docker = 1 ] && out="$out Until it ends, docker, docker compose and test commands may fail, hang or find Docker stopped; a failure in this window is likely the heal, not the code, and is worth re-running once it ends." ;;
    held)
      out="fseventsd-guard: a heal of fseventsd (trigger ${HN_TRIGGER:-?}; $(fsg_hint_step "$HN_VARIANT")) did not get Docker verified (since $at: $HN_WHY). Docker may still be stopped or partly up, so docker, docker compose and test commands may fail. New runs under a drain lease stay held until the guard's agent sees Docker back (it checks every 5 minutes), or until someone brings Docker back by hand (docker desktop start, docker compose up -d) and runs $g release. Details: $g status"
      printf '%s\n' "$out"; return 0 ;;
    ended)
      local restarted=0
      case $HN_RESULT in
        healed) r="fseventsd restarted, and Docker and its containers verified"; restarted=1 ;;
        # The Docker intent stays until Docker verified (a hold shows as held first).
        restart-failed)
          r="the fseventsd restart failed ($g doctor says why)"
          if [ $docker = 0 ]; then r="$r, and Docker was left alone"
          elif [ -f "$FSG_DOCKER_INTENT" ]; then r="$r, and Docker is not verified back ($g status says what is left)"
          else r="$r, and Docker was brought back"; fi ;;
        restored-partly) r="fseventsd restarted, but the heal ended incomplete (fseventsd not healthy in time, or Docker not fully back; $g status says what is left)"; restarted=1 ;;
        aborted-at-cap) r="it gave up at the drain cap, and nothing was stopped or restarted"; docker=0 ;;
        refused-*) r="it was refused before its Docker step, and nothing was stopped or restarted"; docker=0 ;;
        drain-not-marked|intent-not-written) r="it could not write its state, and nothing was stopped"; docker=0 ;;
      esac
      out="fseventsd-guard: a heal of fseventsd (trigger $HN_TRIGGER; $(fsg_hint_step "$HN_VARIANT")) ran from $(date -r $((HN_ID - HN_WALL)) +%H:%M 2>/dev/null) to $(date -r "$HN_ID" +%H:%M 2>/dev/null) and ended: $r."
      [ $docker = 1 ] && out="$out A docker, docker compose or test failure in that window is likely the heal, not the code, and is worth re-running."
      # Untested: watchers may not re-register after a restart (DOCKER-TRIALS.md).
      [ $restarted = 1 ] && out="$out If a session stops seeing file changes after the heal, restart it."
      printf '%s Details: %s status\n' "$out" "$g"; return 0 ;;
  esac
  out="$out Runs under a drain lease (fseventsd-guard run, integrated runners) are held and start by themselves when it ends; other new runs are not held."
  [ $docker = 1 ] && out="$out Restarting Docker or containers by hand during the heal interferes with it."
  printf '%s Progress: %s status\n' "$out" "$g"
}
