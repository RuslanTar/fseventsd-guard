# shellcheck shell=bash
# fseventsd-guard drain, guard side. The runner side is lib/lease.sh (sourced first).
#
# Drain protocol (docs/DESIGN.md "Drain"):
#   1. The heal writes drain/pending (owner pid + start time, deadline, phase,
#      Docker step).
#   2. New runs see it in fsg_lease_acquire and wait; they start when it is removed.
#   3. The heal waits until no lease and no unleased Docker work that started before
#      the drain is left: leased runs up to the cap, unleased work up to
#      FSG_UNLEASED_CAP_S. At a cap the trigger's policy decides (proceed or abort).
#      Interactive docker exec sessions are never waited for; engine work (exec
#      sessions, --rm and one-off containers) that an engine answering `docker info`
#      does not list is unknown, and waits like unleased work. A wedged engine,
#      which answers nothing, lists none.
#   4. After the restart and the restore the heal removes drain/pending.
# The deadline runners see is refreshed at every phase from that phase's own worst
# case (fsg_phase_budget) plus FSG_DRAIN_SLACK_S, so held runs never see the drain
# expire while Docker is still down.

# This process and its ancestors as "pid=lstart;..." (the request's requester_chain).
fsg_req_chain() {
  local p out=""
  for p in $(fsg_ancestors); do out="${out:+$out;}$p=$(fsg_lstart "$p")"; done
  printf '%s\n' "$out"
}

# The processes whose leases and work a heal ignores, as "pid=lstart;...". In a
# request's heal: the requester and its ancestors (HEAL_REQ_CHAIN), only while the
# requester (pid and start time) lives and waits for the result; once it is gone,
# or when it never waited (--no-wait), none, so its workflow's leases hold the drain
# like any other. Else this process and its ancestors. A leased workflow that waits
# for its heal must not wait on itself.
fsg_exempt_chain() {
  if [ -n "${HEAL_REQ_CHAIN+x}" ]; then
    fsg__req_exempting && printf '%s\n' "$HEAL_REQ_CHAIN"
  else fsg_req_chain; fi
  return 0
}
# Their pids, one per line.
fsg_exempt_pids() {
  if [ -n "${HEAL_REQ_CHAIN+x}" ]; then
    fsg__req_exempting && printf '%s\n' "$HEAL_REQ_CHAIN" | tr ';' '\n' | sed 's/=.*//; /^$/d'
  else fsg_ancestors; fi
  return 0
}
fsg__req_exempting() { [ "${HEAL_REQ_WAITS:-0}" = 1 ] && fsg__alive "${HEAL_REQ_PID:-}" "${HEAL_REQ_LSTART:-}"; }

# Live leases as "pid<TAB>label<TAB>started_epoch" lines. With REAP=1, removes the
# leases of dead processes. Leases of the requester and its ancestors (the same
# pid and start time, fsg_exempt_chain) are left out while the requester waits: a
# heal asked for from inside a leased run must not wait for that run.
fsg_live_leases() {
  local reap=${1:-0} f pid lst chain
  [ -d "$FSG_LEASE_DIR" ] || return 0
  chain=";$(fsg_exempt_chain);"
  for f in "$FSG_LEASE_DIR"/*.lease; do
    [ -f "$f" ] || continue
    pid=$(fsg__kv "$f" pid)
    lst=$(fsg__kv "$f" lstart)
    if fsg__alive "$pid" "$lst"; then
      case $chain in *";$pid=$lst;"*) continue ;; esac
      printf '%s\t%s\t%s\n' "$pid" "$(fsg__kv "$f" label)" "$(fsg__kv "$f" started_epoch)"
    elif [ "$reap" = 1 ]; then
      rm -f "$f"
      fsg_log "LEASE reaped pid=$pid label=\"$(fsg__kv "$f" label 2>/dev/null)\" (process gone)"
    fi
  done
  if [ "$reap" = 1 ]; then
    for f in "$FSG_LEASE_DIR"/*.held; do
      [ -f "$f" ] || continue
      fsg__alive "$(fsg__kv "$f" pid)" "$(fsg__kv "$f" lstart)" || rm -f "$f"
    done
    # Leftover temp files of interrupted writers.
    find "$FSG_LEASE_DIR" -name '*.tmp.*' -mmin +10 -exec rm -f {} + 2>/dev/null
  fi
  return 0
}

# Pids of runs that wait for a drain in fsg_lease_acquire (lib/lease.sh): held, so
# neither live work nor cut.
fsg_held_pids() {
  local f pid
  [ -d "$FSG_LEASE_DIR" ] || return 0
  for f in "$FSG_LEASE_DIR"/*.held; do
    [ -f "$f" ] || continue
    pid=$(fsg__kv "$f" pid)
    fsg__alive "$pid" "$(fsg__kv "$f" lstart)" && echo "$pid"
  done
  return 0
}

# Awk text shared by the exec classifiers, run with -v cmds, launchers and consoles
# (FSG_DETECT_COMMANDS, FSG_DETECT_LAUNCHERS, FSG_INTERACTIVE_COMMANDS).
# console_cmd(s) is 1 when the command in words[s..nw] is a shell or console (after
# launchers; prog:sub entries need that first argument) and names no detected
# command: only then is an exec of it with a TTY an interactive session.
# shellcheck disable=SC2016
FSG__AWK_EXEC_CMD='
  function base(w) { sub(/.*\//, "", w); return w }
  function console_cmd(s,   j, w, b, p) {
    p = 0
    for (j = s; j <= nw; j++) {
      w = words[j]; b = base(w)
      if (b in cmd) return 0
      if (p || w == "" || w ~ /^-/ || w ~ /^[0-9.]+[smhd]?$/ || w ~ /^[A-Za-z_][A-Za-z0-9_]*=/) continue
      if ((b in console) || ((b ":" words[j + 1]) in console)) p = 1
      else if (!(b in launch)) return 0
    }
    return p
  }
  BEGIN {
    n = split(cmds, a, " "); for (i = 1; i <= n; i++) cmd[a[i]] = 1
    n = split(launchers, a, " "); for (i = 1; i <= n; i++) launch[a[i]] = 1
    n = split(consoles, a, " "); for (i = 1; i <= n; i++) console[a[i]] = 1
  }'

# Unleased Docker-dependent processes as "kind<TAB>pid<TAB>start_epoch<TAB>command"
# lines. Kind is process, or interactive for a docker exec of a shell or console
# that has a TTY and a terminal (an open psql or shell tab: waiting for it would
# hold every drain to the cap). Processes that belong to a live lease or a held run
# (the holder and its descendants), this process and its descendants, and the
# requester and its ancestors while it waits (fsg_exempt_pids) are left out.
fsg_unleased_procs() {
  [ "$FSG_DETECT_PROCESSES" = 1 ] || [ "$FSG_DETECT_DOCKER_CLI" = 1 ] || return 0
  local leased anc
  leased=$( { fsg_live_leases | cut -f1; fsg_held_pids; } | tr '\n' ' ')
  anc=$(fsg_exempt_pids | tr '\n' ' ')
  ps -axo pid=,ppid=,etime=,tty=,command= 2>/dev/null | awk \
    -v self="$$" -v leased="$leased" -v anc="$anc" -v now="$(fsg_now)" \
    -v cmds="$FSG_DETECT_COMMANDS" -v launchers="$FSG_DETECT_LAUNCHERS" -v consoles="$FSG_INTERACTIVE_COMMANDS" \
    -v detp="$FSG_DETECT_PROCESSES" -v detd="$FSG_DETECT_DOCKER_CLI" "$FSG__AWK_EXEC_CMD"'
    # ps etime: [[dd-]hh:]mm:ss
    function secs(e,   d, n, a, i, s) {
      d = 0
      if (index(e, "-")) { d = substr(e, 1, index(e, "-") - 1); e = substr(e, index(e, "-") + 1) }
      n = split(e, a, ":"); s = 0
      for (i = 1; i <= n; i++) s = s * 60 + a[i]
      return d * 86400 + s
    }
    # 2 when the exec asks for a TTY (compose exec does unless -T) and runs a shell
    # or console, else 1.
    function exec_kind(start, tty,   j, w, skipval) {
      skipval = 0
      for (j = start; j <= nw; j++) {
        w = words[j]
        if (skipval) { skipval = 0; continue }
        if (w !~ /^-/) break
        if (w == "--tty" || w == "--tty=true") tty = 1
        else if (w == "-T" || w == "--no-TTY" || w == "--no-tty" || w == "--tty=false") tty = 0
        else if (w ~ /^(--env|--user|--workdir|--detach-keys|--env-file|--index)$/) skipval = 1
        else if (w ~ /^-[A-Za-z]+$/) { if (index(w, "t")) tty = 1; if (w ~ /[euw]$/) skipval = 1 }
      }
      return (tty && console_cmd(j + 1)) ? 2 : 1
    }
    function compose_match(start,   j) {
      for (j = start; j <= nw; j++) {
        if (words[j] == "run") return 1
        if (words[j] == "exec") return exec_kind(j + 1, 1)
      }
      return 0
    }
    function docker_match(start,   j, w, skipval) {
      skipval = 0
      for (j = start; j <= nw; j++) {
        w = words[j]
        if (skipval) { skipval = 0; continue }
        if (w ~ /^-/) { if (w ~ /^(--context|-c|--host|-H|--config|--log-level|-l)$/) skipval = 1; continue }
        if (w == "run") return 1
        if (w == "exec") return exec_kind(j + 1, 0)
        if (w == "compose") return compose_match(j + 1)
        return 0
      }
      return 0
    }
    function matches(c,   i, w, b) {
      nw = split(c, words, /[ \t]+/)
      i = 1
      while (i <= nw) {
        w = words[i]
        if (w == "" || w ~ /^-/ || w ~ /^[0-9.]+[smhd]?$/ || w ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { i++; continue }
        b = base(w)
        if (detp == 1 && (b in cmd)) return 1
        if (detd == 1 && b == "docker") return docker_match(i + 1)
        if (detd == 1 && b == "docker-compose") return compose_match(i + 1)
        if (b in launch) { i++; continue }
        return 0
      }
      return 0
    }
    BEGIN {
      n = split(leased, a, " "); for (i = 1; i <= n; i++) subtree[a[i]] = 1
      subtree[self] = 1
      n = split(anc, a, " "); for (i = 1; i <= n; i++) exact[a[i]] = 1
    }
    {
      p = $1; par[p] = $2; start[p] = now - secs($3); tty[p] = $4
      $1 = ""; $2 = ""; $3 = ""; $4 = ""; sub(/^[ \t]+/, ""); line[p] = $0; order[++k] = p
    }
    END {
      for (i = 1; i <= k; i++) {
        p = order[i]
        if (p in exact) continue
        q = p; d = 0; skip = 0
        while (q > 1 && d < 64) { if (q in subtree) { skip = 1; break }; q = par[q]; d++ }
        if (skip) continue
        r = matches(line[p])
        if (r) hit[p] = 1
        # A TTY without a terminal (an agent shell) fails or runs scripted: work.
        if (r == 2 && tty[p] != "" && tty[p] != "??") inter[p] = 1
      }
      # One line per run: a match whose ancestor also matched is counted under the
      # topmost matching ancestor (parallel_rspec and its workers are one run).
      for (p in hit) {
        top = p; q = par[p]; d = 0
        while (q > 1 && d < 64) { if (q in hit) top = q; q = par[q]; d++ }
        if (top != p) under[top]++
      }
      for (i = 1; i <= k; i++) {
        p = order[i]
        if (!(p in hit)) continue
        q = par[p]; d = 0; nested = 0
        while (q > 1 && d < 64) { if (q in hit) { nested = 1; break }; q = par[q]; d++ }
        if (nested) continue
        extra = (p in under) ? " (+" under[p] " child process(es))" : ""
        print ((p in inter) ? "interactive" : "process") "\t" p "\t" start[p] "\t" substr(line[p], 1, 140) extra
      }
    }'
}

# 0 when an engine exec record (GET /exec/ID/json) is an interactive session: a TTY
# for a shell or console (console_cmd), or an open stdin without a TTY (an attached
# CLI that pipes stdin is live work on the CLI side).
fsg__exec_interactive() { # exec-json
  printf '%s\n' "$1" | awk -v cmds="$FSG_DETECT_COMMANDS" -v launchers="$FSG_DETECT_LAUNCHERS" \
    -v consoles="$FSG_INTERACTIVE_COMMANDS" "$FSG__AWK_EXEC_CMD"'
    { s = s $0 }
    END {
      if (s !~ /"tty": ?true/) exit (s ~ /"OpenStdin": ?true/) ? 0 : 1
      c = ""
      if (match(s, /"entrypoint": ?"[^"]*"/)) { c = substr(s, RSTART, RLENGTH); sub(/^"entrypoint": ?"/, "", c); sub(/"$/, "", c) }
      if (match(s, /"arguments": ?\[[^]]*\]/)) {
        g = substr(s, RSTART, RLENGTH); sub(/^"arguments": ?\[/, "", g); sub(/\]$/, "", g); gsub(/[",]/, " ", g); c = c " " g
      }
      nw = split(c, words, /[ \t]+/)
      exit console_cmd(1) ? 0 : 1
    }'
}

# The engine's own work, from one listing of the running containers:
# - with FSG_DETECT_DOCKER_CONTAINERS=1, each running --rm (HostConfig.AutoRemove)
#   or one-off (`docker compose run`) container, as "container<TAB>name<TAB>
#   start_epoch<TAB>name --rm|one-off": Docker deletes the first kind when it stops,
#   and a heal never starts the second again, so both are runs to wait for;
# - with FSG_DETECT_DOCKER_EXECS=1, its exec sessions as "kind<TAB>exec-id<TAB><TAB>
#   container" lines. Kind is interactive-exec for an interactive session
#   (fsg__exec_interactive), else exec. The docker CLI cannot inspect an exec
#   session, so this asks the engine API; when that fails the session counts as work.
# Returns 2, with no lines, when the containers could not be listed (docker ps or
# inspect failed or timed out, or inspect printed a row that is not whole) while the
# engine answers `docker info`: that work is unknown; 3 when it answers nothing
# (fsg__engine_unlisted). A daemon that refuses the connection (Docker stopped or
# still starting) runs nothing, so that is no work. Only a local engine is asked
# (fsg_docker_endpoint, pinned): a heal cuts nothing on any other.
fsg_docker_engine_work() {
  [ "$FSG_DETECT_DOCKER_EXECS" = 1 ] || [ "${FSG_DETECT_DOCKER_CONTAINERS:-0}" = 1 ] || return 0
  command -v docker >/dev/null 2>&1 || return 0
  local ids rows rc sock="" name ar oneoff started rest id kind js st t DK_ENDPOINT DK_EP_WHY
  fsg_docker_endpoint || return 0
  fsg_docker_pin
  ids=$(fsg_timeout 15 docker ps -q 2>&1); rc=$?
  if [ $rc -ne 0 ]; then
    case $rc:$ids in 124:*) ;; *"Cannot connect to the Docker daemon"*) return 0 ;; esac
    fsg__engine_unlisted; return
  fi
  ids=$(printf '%s\n' "$ids" | grep -E '^[0-9a-f]+$')
  [ -n "$ids" ] || return 0
  t=$(printf '\t')
  # Typed fields only, so the CLI keeps to its typed struct (a label that is not set
  # prints ""; on the raw JSON it would print null). The label is free text: it goes
  # through json and the fields are tab-separated, so a space, tab or newline in it
  # cannot shift the exec ids or split the row. A real engine's rows:
  # test/fixtures/docker-cli-29.9.2/engine-work.txt.
  # shellcheck disable=SC2086
  rows=$(fsg_timeout 15 docker inspect --format "{{.Name}}$t{{.HostConfig.AutoRemove}}$t{{json (index .Config.Labels \"com.docker.compose.oneoff\")}}$t{{.State.StartedAt}}{{range .ExecIDs}}$t{{.}}{{end}}" $ids 2>/dev/null); rc=$?
  # A container that exited since docker ps fails inspect for itself only.
  if [ $rc -eq 124 ] || { [ $rc -ne 0 ] && [ -z "$rows" ]; }; then fsg__engine_unlisted; return; fi
  # A row that is not whole (name, AutoRemove, label, start time, then exec ids) leaves
  # the work unknown.
  printf '%s\n' "$rows" | awk -F'\t' 'NF {
      ok = NF >= 4 && $1 ~ /^\/[a-zA-Z0-9][a-zA-Z0-9_.-]*$/ && ($2 == "true" || $2 == "false") &&
        $3 ~ /^"([^"\\]|\\.)*"$/ && $4 ~ /^[0-9][-0-9T:.Z+]*$/
      for (i = 5; ok && i <= NF; i++) ok = $i ~ /^[0-9A-Za-z]+$/
      if (!ok) bad = 1
    } END { exit bad }' || { fsg__engine_unlisted; return; }
  command -v curl >/dev/null 2>&1 && sock=${DK_ENDPOINT#unix://}
  printf '%s\n' "$rows" | while IFS=$t read -r name ar oneoff started rest; do
    [ -n "$name" ] || continue
    if [ "${FSG_DETECT_DOCKER_CONTAINERS:-0}" = 1 ]; then
      kind=
      if [ "$ar" = true ]; then kind=--rm; elif [ "$oneoff" = '"True"' ]; then kind=one-off; fi
      if [ -n "$kind" ]; then
        # StartedAt is UTC with nanoseconds; one that cannot be read counts as before the drain.
        st=$(date -j -u -f %Y-%m-%dT%H:%M:%S "${started%%[.Z]*}" +%s 2>/dev/null)
        printf 'container\t%s\t%s\t%s %s\n' "${name#/}" "$st" "${name#/}" "$kind"
      fi
    fi
    [ "$FSG_DETECT_DOCKER_EXECS" = 1 ] || continue
    for id in $rest; do
      case $id in *[!0-9A-Za-z]*) continue ;; esac
      kind='exec'
      if [ -n "$sock" ]; then
        js=$(fsg_timeout 10 curl -s --max-time 5 --unix-socket "$sock" "http://localhost/exec/$id/json" 2>/dev/null)
        fsg__exec_interactive "$js" && kind=interactive-exec
      fi
      printf '%s\t%s\t\t%s\n' "$kind" "$id" "${name#/}"
    done
  done
  return 0
}

# After a failed listing: 2 (unknown) while the engine answers `docker info`, else 3.
# An engine that answers nothing (info fails or times out too) is wedged, the
# failure a heal is for: waiting for its listing would only hold that heal to the
# cap, so its own work counts as none. Work driven from the docker CLI still shows
# in the process scan.
fsg__engine_unlisted() { fsg_docker_answers && return 2; return 3; }

# Everything that is live work now, as "kind<TAB>id<TAB>start_epoch<TAB>text" lines.
# Kind: lease (id = pid, text = label), process, interactive (a TTY docker exec CLI),
# exec or interactive-exec (id = exec id, no start time, text = container), container
# (id = name, text = "name --rm|one-off"). Returns 2 when the engine's work could not
# be listed, 3 when the engine answers nothing (fsg_docker_engine_work).
fsg_live_work() {
  local reap=${1:-0}
  fsg_live_leases "$reap" | awk -F'\t' '{ print "lease\t" $1 "\t" $3 "\t" $2 }'
  fsg_unleased_procs
  fsg_docker_engine_work
}

# Work lines as one short line each. Mode brief (notifications): "what (pid, age)";
# mode text (leases, dry-run): "kind: pid what (up age)".
fsg_work_brief() { # [brief|text] < lines
  awk -F'\t' -v now="$(fsg_now)" -v mode="${1:-brief}" '
    function age(s,   d) {
      if (s !~ /^[0-9]+$/) return ""
      d = now - s; if (d < 0) d = 0
      if (d >= 3600) return sprintf("%dh%02dm", d / 3600, d % 3600 / 60)
      if (d >= 60) return sprintf("%dm%02ds", d / 60, d % 60)
      return d "s"
    }
    NF < 4 { next }
    $1 == "container" {
      a = age($3); split($4, c, " ")
      if (mode == "text") print "container: " c[1] " (" c[2] (a == "" ? "" : ", up " a) ")"
      else print "container " c[1] " (" c[2] (a == "" ? "" : ", " a) ")"
      next
    }
    {
      a = age($3); exe = ($1 == "exec" || $1 == "interactive-exec")
      kind = ($1 ~ /^interactive/) ? "interactive, left alone" : $1
      if (mode == "text") {
        if (exe) print kind ": " $4 " exec session " substr($2, 1, 12)
        else print kind ": pid " $2 " " $4 (a == "" ? "" : " (up " a ")")
      } else if (exe) print $4 " exec session " substr($2, 1, 12)
      else print short($4) " (pid " $2 ($1 == "lease" ? ", leased" : "") (a == "" ? "" : ", " a) ")"
    }
    # Directories dropped from absolute paths, so the program names fit.
    function short(c,   n, w, i, s) {
      n = split(c, w, " ")
      for (i = 1; i <= n; i++) { if (w[i] ~ /^\//) sub(/.*\//, "", w[i]); s = s (i > 1 ? " " : "") w[i] }
      return substr(s, 1, 70)
    }'
}

# Up to MAX work lines as "a; b; c and N more".
fsg_work_list() { # lines max
  printf '%s\n' "$1" | sed '/^$/d' | fsg_work_brief brief | awk -v max="${2:-3}" '
    NR <= max { s = s (NR > 1 ? "; " : "") $0 }
    END { if (NR > max) s = s " and " (NR - max) " more"; print s }'
}

# Sorts live work for the running drain: DS_LEASED (leases taken before the drain),
# DS_UNLEASED (other work that started before it), DS_MID (unleased work started
# since: it never holds the drain, it is what a restart cuts besides the remainder)
# and DS_LEFT (interactive sessions, never waited for). An exec session has no start
# time: one listed by the drain's first scan whose exec listing worked counts as
# started before it. A lease written after the drain began is a run that met it and
# is about to wait, and an exec session listed only since may be a healthcheck probe
# that ends within a poll: either is mid-drain only once the next scan still sees it
# (for a lease, FSG_RUN_ON_TIMEOUT=proceed). DS_UNKNOWN=1 when the engine's work (exec
# sessions, --rm and one-off containers) could not be listed while the engine
# answers; one that answers nothing lists none, and seeds no exec session either.
fsg_drain_scan() { # [reap]
  local work cut rc
  if [ -n "${HEAL_REQ_CHAIN:-}" ] && [ "${DRAIN_REQ_EXEMPT:-1}" = 1 ] && ! fsg__req_exempting; then
    DRAIN_REQ_EXEMPT=0
    fsg_say "drain: the requester (pid ${HEAL_REQ_PID:-?}) $([ "${HEAL_REQ_WAITS:-0}" = 1 ] && echo 'stopped waiting' || echo 'does not wait'): the leases of it and its parents now hold the drain like any other run"
    fsg_log "DRAIN requester pid=${HEAL_REQ_PID:-?} waits=${HEAL_REQ_WAITS:-0} not waiting: its chain's leases count"
  fi
  work=$(fsg_live_work "${1:-0}"); rc=$?
  DS_UNKNOWN=0; [ $rc -eq 2 ] && DS_UNKNOWN=1
  if [ "${DRAIN_EXEC_SEEDED:-0}" != 1 ] && [ $rc -eq 0 ]; then
    DRAIN_EXEC_PRE=" $(printf '%s\n' "$work" | awk -F'\t' '$1 ~ /exec$/ { printf "%s ", $2 }')"
    DRAIN_EXEC_SEEDED=1
  fi
  # ps etime has whole seconds; the slack counts a run that started as the drain
  # began as started before it.
  cut=$(( ${DRAIN_STARTED:-$(fsg_now)} + 2 ))
  work=$(printf '%s\n' "$work" | awk -F'\t' -v cut="$cut" -v pre="$DRAIN_EXEC_PRE" -v seen="${DRAIN_MID_SEEN:-}" '
    BEGIN {
      n = split(pre, a, " "); for (i = 1; i <= n; i++) old[a[i]] = 1
      n = split(seen, a, " "); for (i = 1; i <= n; i++) was[a[i]] = 1
    }
    NF < 4 { next }
    $1 ~ /^interactive/ { print "I\t" $0; next }
    $1 == "exec" { print (($2 in old) ? "U" : (($2 in was) ? "M" : "m")) "\t" $0; next }
    $1 == "lease" && $3 ~ /^[0-9]+$/ && $3 > cut { print (($2 ":" $3) in was ? "M" : "m") "\t" $0; next }
    $3 ~ /^[0-9]+$/ && $3 > cut { print "M\t" $0; next }
    $1 == "lease" { print "L\t" $0; next }
    { print "U\t" $0 }')
  DS_LEASED=$(fsg__ds_pick L "$work")
  DS_UNLEASED=$(fsg__ds_pick U "$work")
  DS_MID=$(fsg__ds_pick M "$work")
  DS_LEFT=$(fsg__ds_pick I "$work")
  DRAIN_MID_SEEN=$(printf '%s\n' "$work" | awk -F'\t' '$1 == "m" || $1 == "M" {
    if ($2 == "lease") printf "%s:%s ", $3, $4; else if ($2 == "exec") printf "%s ", $3 }')
}
fsg__ds_pick() { printf '%s\n' "$2" | awk -F'\t' -v c="$1" '$1 == c { sub(/^[^\t]*\t/, ""); print }'; }

# What a restart now cuts: the work still running, then the mid-drain starts.
fsg__drain_cut_list() {
  { printf '%s\n' "$DS_LEASED" "$DS_UNLEASED" | sed '/^$/d' | fsg_work_brief brief
    printf '%s\n' "$DS_MID" | sed '/^$/d' | fsg_work_brief brief | sed 's/$/ - started mid-drain/'; } | sed '/^$/d'
}

# What a failed engine listing leaves unknown (fsg_docker_engine_work).
fsg_drain_unknown_what() {
  case $FSG_DETECT_DOCKER_EXECS:${FSG_DETECT_DOCKER_CONTAINERS:-0} in
    1:1) echo "Docker exec sessions and --rm and one-off containers" ;;
    1:*) echo "Docker exec sessions" ;;
    *) echo "Docker --rm and one-off containers" ;;
  esac
}

# The notices' sentence for a drain that ended with the engine's work unknown; with
# cut, the heal goes ahead.
fsg_drain_unknown_text() { # [cut]
  [ "${DRAIN_UNKNOWN:-0}" = 1 ] || return 0
  printf '%s%s\n' "The $(fsg_drain_unknown_what) were unknown when the drain ended: the engine did not list them (docker ps or docker inspect failed or timed out)." \
    "$( [ "${1:-}" = cut ] && echo " Any that run are cut too.")"
}

# The heal's view of the drain for `status`: what it waits for, what it will cut,
# what it leaves alone.
fsg__drain_blockers_write() {
  local f="$FSG_DRAIN_DIR/blockers"
  {
    printf '%s\n' "$DS_LEASED" "$DS_UNLEASED" | sed '/^$/d' | fsg_work_brief brief | head -n 5 | sed 's/^/waiting for: /'
    [ "${DS_UNKNOWN:-0}" = 1 ] && echo "waiting for: $(fsg_drain_unknown_what), unknown (the engine did not list them)"
    printf '%s\n' "$DS_MID" | sed '/^$/d' | fsg_work_brief brief | head -n 5 | sed 's/^/started mid-drain, not waited for (a restart cuts it): /'
    printf '%s\n' "$DS_LEFT" | sed '/^$/d' | fsg_work_brief brief | head -n 5 | sed 's/^/interactive session left alone: /'
  } > "$f.tmp.$$" 2>/dev/null && mv -f "$f.tmp.$$" "$f" 2>/dev/null
}

fsg_drain_write() { # phase
  local tmp="$FSG_PENDING.tmp.$$"
  mkdir -p "$FSG_DRAIN_DIR" "$FSG_LEASE_DIR" 2>/dev/null || return 1
  {
    echo "state_version=$FSG_STATE_VERSION"
    echo "owner_pid=$$"
    echo "owner_lstart=$DRAIN_OWNER_LSTART"
    echo "started_epoch=$DRAIN_STARTED"
    echo "deadline_epoch=$DRAIN_DEADLINE"
    echo "trigger=$DRAIN_TRIGGER"
    echo "reason=$DRAIN_REASON"
    echo "phase=$1"
    echo "variant=${HEAL_VARIANT:-}"
  } > "$tmp" && mv -f "$tmp" "$FSG_PENDING"
}

# Returns 1 when the marker cannot be written (a full disk, an unwritable state
# dir); the heal must then stop before it touches Docker. A hold already in place
# (Docker not verified after an earlier heal, or a trial's) is copied aside first
# (DRAIN_SAVED) and comes back when this drain ends, unless this drain's own Docker
# verified (fsg_drain_end); the next tick puts back the copy of a killed tick.
fsg_drain_begin() { # trigger reason cap
  DRAIN_TRIGGER=$1; DRAIN_REASON=$2
  DRAIN_OWNER_LSTART=$(fsg_lstart $$)
  DRAIN_STARTED=$(fsg_now)
  DRAIN_EXEC_SEEDED=0; DRAIN_EXEC_PRE=; DRAIN_MID_SEEN=; DRAIN_REQ_EXEMPT=1
  DRAIN_DEADLINE=$((DRAIN_STARTED + $(fsg_phase_budget draining "$3") + FSG_DRAIN_SLACK_S))
  DRAIN_SAVED=; DRAIN_SAVED_TRIGGER=
  if fsg_drain_hold_active; then
    DRAIN_SAVED_TRIGGER=$(fsg__kv "$FSG_PENDING" trigger)
    if ! cp "$FSG_PENDING" "$FSG_DRAIN_DIR/pending.saved.$$" 2>/dev/null; then
      rm -f "$FSG_DRAIN_DIR/pending.saved.$$"
      fsg_log "DRAIN cannot copy the hold in place aside"
      return 1
    fi
    DRAIN_SAVED="$FSG_DRAIN_DIR/pending.saved.$$"
  fi
  if ! fsg_drain_write draining; then
    rm -f "$FSG_PENDING.tmp.$$" "$DRAIN_SAVED"; DRAIN_SAVED=
    fsg_log "DRAIN cannot write $FSG_PENDING"
    return 1
  fi
  DRAIN_HELD=1
  fsg_log "DRAIN begin trigger=$1 cap_s=$3 deadline=$DRAIN_DEADLINE reason=\"$2\"${DRAIN_SAVED:+ (the ${DRAIN_SAVED_TRIGGER:-manual} hold in place is kept aside)}"
}

# Worst-case seconds of one heal phase, from the knobs that bound its steps.
fsg_phase_budget() { # phase [cap]
  local dt=$FSG_DOCKER_TIMEOUT_S q=$FSG_DOCKER_QUERY_TIMEOUT_S n
  n=$(printf '%s\n' ${DK_IDS:-} | sed '/^$/d' | wc -l | tr -d ' ')
  case $1 in
    # cap, one more poll, and a live-work scan (ps, docker ps/inspect 15 s each, and
    # docker info when they fail)
    draining) echo $(( ${2:-0} + FSG_DRAIN_POLL_S + 60 + q )) ;;
    # the record's status and info queries, docker ps again after an inspect that
    # left a container unread (30 s), docker info again after a failed listing,
    # desktop stop (timeout + 10 s) and the stop polls (FSG_DESKTOP_STOP_WAIT_S
    # from the stop, one more poll of up to 5 s after it)
    docker-before) n=$(( dt + 10 )); [ "$FSG_DESKTOP_STOP_WAIT_S" -gt $n ] && n=$FSG_DESKTOP_STOP_WAIT_S
      echo $(( n + 95 + 3 * q )) ;;
    restarting) echo $(( FSG_HELPER_TIMEOUT_S + 10 )) ;;
    waiting-healthy) echo $(( FSG_HEALTHY_TIMEOUT_S + FSG_PROBE_TIMEOUT_S + 30 )) ;;
    # C's container listing before its restart (docker ps 30 s, inspect 20 s, docker
    # ps again 30 s after an inspect that left a container unread), desktop
    # start/restart (timeout + 10), engine wait (timeout), inspect each container
    # (20 s) and docker start (timeout); then one engine query and the container wait
    docker-after) echo $(( 80 + 3 * dt + 10 + 20 * n + q + FSG_CONTAINER_TIMEOUT_S + 20 * n + 20 )) ;;
    # docker images + inspect (20 s each), up to 3 probe containers (90 s each), measure
    verifying) echo $(( 40 + 3 * 90 + 30 )) ;;
    *) echo 300 ;;
  esac
}

# Moves the drain to PHASE and gives runners a deadline that covers it.
fsg_drain_phase() {
  [ "${DRAIN_HELD:-0}" = 1 ] || return 0
  DRAIN_DEADLINE=$(( $(fsg_now) + $(fsg_phase_budget "$1") + FSG_DRAIN_SLACK_S ))
  if fsg_drain_write "$1"; then
    fsg_log "DRAIN phase=$1 deadline=$DRAIN_DEADLINE"
  else
    fsg_log "DRAIN cannot write phase=$1 (runners keep the previous deadline)"
  fi
  return 0
}

# After a heal that could not bring Docker back: new runs stay held after the heal
# exits, until the agent sees Docker healthy again (not for trials: the operator
# confirms with `release`), `fseventsd-guard release`, or FSG_FAILED_HOLD_S passes.
# The hold names no owner process, so it outlives the heal on purpose.
fsg_drain_hold() { # what failed
  local tmp="$FSG_PENDING.tmp.$$" now until trigger=${HEAL_TRIGGER:-manual}
  # It replaces a hold copied aside, and stays the operator's when that was a trial's.
  [ -n "${DRAIN_SAVED:-}" ] && [ "${DRAIN_SAVED_TRIGGER:-}" = trial ] && trigger=trial
  now=$(fsg_now); until=$((now + FSG_FAILED_HOLD_S))
  mkdir -p "$FSG_DRAIN_DIR" 2>/dev/null
  if {
    echo "state_version=$FSG_STATE_VERSION"
    echo "owner_pid=0"
    echo "started_epoch=$now"
    echo "hold_until_epoch=$until"
    echo "trigger=$trigger"
    echo "reason=Docker not restored after a heal: $1"
    echo "phase=held-docker-not-restored"
    echo "variant=${HEAL_VARIANT:-}"
    echo "restore_names=${DK_NAMES:-}"
    echo "restore_health=${DK_HEALTH:-}"
    echo "endpoint=${DK_ENDPOINT:-}"
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$FSG_PENDING"; then
    DRAIN_HELD=0
    [ -n "${DRAIN_SAVED:-}" ] && rm -f "$DRAIN_SAVED"
    DRAIN_SAVED=
    fsg_log "DRAIN hold until=$until trigger=$trigger reason=\"$1\""
    return 0
  fi
  fsg_log "DRAIN cannot write the hold"
  return 1
}

fsg_drain_hold_active() { [ -n "$(fsg__kv "$FSG_PENDING" hold_until_epoch)" ] && fsg_drain_active; }

FSG_HOLD_NEXT="New test runs stay held until Docker is back (the agent checks every 5 min) or you run: fseventsd-guard release"

fsg_cmd_release() {
  if [ -z "$(fsg__kv "$FSG_PENDING" hold_until_epoch)" ] && fsg_drain_active; then
    fsg_say "release: a running heal (pid $(fsg__kv "$FSG_PENDING" owner_pid)) holds the drain; it releases it when it ends"
    return 1
  fi
  # The operator vouches for Docker: the agent stops recovering a dead heal's intent,
  # and the runners that hold behind it without the agent (lib/lease.sh) start.
  local held=""
  if [ -f "$FSG_DOCKER_INTENT" ] && ! fsg_intent_owner_alive; then
    fsg_intent_hold_active && held=1
    fsg_log "DOCKER intent of heal pid $(fsg__kv "$FSG_DOCKER_INTENT" owner_pid) cleared by hand"
    rm -f "$FSG_DOCKER_INTENT"
    echo "release: cleared the record of a heal that ended before Docker verified"
  fi
  if [ ! -f "$FSG_PENDING" ]; then
    if [ -n "$held" ]; then echo "released: held runs start now"; else echo "release: nothing is held"; fi
    return 0
  fi
  rm -f "$FSG_PENDING"
  fsg_log "DRAIN released by hand"
  echo "released: held runs start now"
}

# Ends this process's drain. The hold copied aside at its start comes back, unless
# VERIFIED (this drain's own Docker verified) and it was not a trial's: only the
# operator releases a trial hold.
fsg_drain_end() { # [verified]
  [ "${DRAIN_HELD:-0}" = 1 ] || return 0
  DRAIN_HELD=0
  rm -f "$FSG_DRAIN_DIR/blockers"
  if [ -n "${DRAIN_SAVED:-}" ] && { [ "${1:-}" != verified ] || [ "$DRAIN_SAVED_TRIGGER" = trial ]; } &&
     mv -f "$DRAIN_SAVED" "$FSG_PENDING" 2>/dev/null; then
    DRAIN_SAVED=
    fsg_log "DRAIN end; the ${DRAIN_SAVED_TRIGGER:-manual} hold in place before it is back"
    return 0
  fi
  [ -n "${DRAIN_SAVED:-}" ] && rm -f "$DRAIN_SAVED"
  DRAIN_SAVED=
  if [ "$(fsg__kv "$FSG_PENDING" owner_pid)" = "$$" ]; then rm -f "$FSG_PENDING"; fi
  fsg_log "DRAIN end"
}

# Seconds unleased work may hold a drain: FSG_UNLEASED_CAP_S, never more than CAP.
fsg_unleased_cap() { # cap
  local u=${FSG_UNLEASED_CAP_S:-600}
  fsg_is_uint "$u" || u=600
  [ "$u" -le "$1" ] || u=$1
  echo "$u"
}

# fsg_drain_wait TRIGGER POLICY CAP. Leased runs that started before the drain hold
# it up to CAP; other detected work only up to fsg_unleased_cap, because nothing
# holds new unleased runs, so waiting longer delays the heal without making it safer.
# Engine work that could not be listed holds it like unleased work, until a listing
# works. Returns 0 when drained, 10 when a cap or the emergency ceiling was hit and
# the policy is proceed, 4 when a cap was hit and the policy is abort. DRAIN_CUT
# names what a restart now cuts (work still running and runs started mid-drain, also
# after 0), DRAIN_LEFT the interactive sessions left alone, DRAIN_CAP_HIT the cap
# reached, DRAIN_UNKNOWN=1 that the engine's work was still unknown then.
fsg_drain_wait() {
  local trigger=$1 policy=$2 cap=$3 ucap t0 waited n hold last_report=-60
  DRAIN_CUT=; DRAIN_LEFT=; DRAIN_CAP_HIT=; DRAIN_WAITED=0; DRAIN_UNKNOWN=0
  ucap=$(fsg_unleased_cap "$cap")
  t0=$(fsg_now)
  while :; do
    fsg_drain_scan 1
    waited=$(( $(fsg_now) - t0 ))
    DRAIN_WAITED=$waited
    DRAIN_LEFT=$DS_LEFT
    DRAIN_CUT=$(fsg__drain_cut_list)
    DRAIN_UNKNOWN=$DS_UNKNOWN
    if [ -z "$DS_LEASED$DS_UNLEASED" ] && [ "$DS_UNKNOWN" = 0 ]; then
      rm -f "$FSG_DRAIN_DIR/blockers"
      fsg_log "DRAIN drained waited_s=$waited${DRAIN_CUT:+ cut_mid_drain=\"$(printf '%s' "$DRAIN_CUT" | tr '\n' ';')\"}"
      return 0
    fi
    fsg__drain_blockers_write
    n=$(printf '%s\n' "$DS_LEASED" "$DS_UNLEASED" | sed '/^$/d' | wc -l | tr -d ' ')
    if [ $((waited - last_report)) -ge 60 ]; then
      fsg_say "drain: waiting for $n item(s) that started before the drain$( [ "$DS_UNKNOWN" = 1 ] && echo ", and for a listing of the $(fsg_drain_unknown_what) (the engine did not list them)") (waited $(fsg_dur "$waited"); leased runs up to $(fsg_dur "$cap"), other work up to $(fsg_dur "$ucap"); at the cap: $policy)"
      sed 's/^/  /' "$FSG_DRAIN_DIR/blockers" >&2 2>/dev/null
      fsg_log "DRAIN waiting items=$n waited_s=$waited first=\"$(printf '%s' "$DRAIN_CUT" | head -n 1)\""
      last_report=$waited
    fi
    if [ "$trigger" = emergency ] && [ "${FSG_EMERGENCY_CUT_MB:-0}" -gt 0 ]; then
      if fsg_measure && [ "$M_MB" -ge "$FSG_EMERGENCY_CUT_MB" ]; then
        DRAIN_CAP_HIT=ceiling
        rm -f "$FSG_DRAIN_DIR/blockers"
        fsg_log "DRAIN emergency ceiling footprint_mb=$M_MB >= $FSG_EMERGENCY_CUT_MB; proceeding with $n live item(s)"
        return 10
      fi
    fi
    hold=
    [ -n "$DS_LEASED" ] && [ "$waited" -lt "$cap" ] && hold=1
    [ -n "$DS_UNLEASED" ] && [ "$waited" -lt "$ucap" ] && hold=1
    [ "$DS_UNKNOWN" = 1 ] && [ "$waited" -lt "$ucap" ] && hold=1
    if [ -z "$hold" ]; then
      if [ -n "$DS_LEASED" ]; then DRAIN_CAP_HIT=$cap; else DRAIN_CAP_HIT=$ucap; fi
      rm -f "$FSG_DRAIN_DIR/blockers"
      if [ "$policy" = proceed ]; then
        fsg_log "DRAIN cap reached cap_s=$DRAIN_CAP_HIT waited_s=$waited policy=proceed cut=\"$(printf '%s' "$DRAIN_CUT" | tr '\n' ';')\" unknown=$DS_UNKNOWN"
        return 10
      fi
      fsg_log "DRAIN cap reached cap_s=$DRAIN_CAP_HIT waited_s=$waited policy=abort live=$n unknown=$DS_UNKNOWN"
      return 4
    fi
    fsg_sleep "$FSG_DRAIN_POLL_S"
  done
}

fsg_cmd_leases() {
  local work rc
  if fsg_drain_active; then
    echo "drain: pending - phase $(fsg__kv "$FSG_PENDING" phase), trigger $(fsg__kv "$FSG_PENDING" trigger), reason: $(fsg__kv "$FSG_PENDING" reason)"
  else
    echo "drain: none"
  fi
  work=$(fsg_live_work 0); rc=$?
  if [ -z "$work" ]; then echo "live work: none"
  else
    echo "live work:"
    printf '%s\n' "$work" | fsg_work_brief text | sed 's/^/  /'
  fi
  [ $rc -eq 2 ] && echo "$(fsg_drain_unknown_what): unknown (the engine did not list them; a drain waits for a listing)"
  [ $rc -eq 3 ] && echo "$(fsg_drain_unknown_what): not listed: Docker does not answer (wedged); a drain does not wait for them"
  return 0
}
