# shellcheck shell=bash
# fseventsd-guard Docker step: record, the variant's before/after actions, restore,
# verify. Every docker call is time-bounded: a wedged engine is the failure we heal.
#
#   A  before: docker stop <running ids>      after: docker start <ids>
#   B  before: docker desktop stop            after: docker desktop start; start ids not running
#   C  before: nothing                        after: docker desktop restart; start ids not running
#   none: nothing (the naive restart; trial step 0)
#
# B and C need Docker Desktop. With another engine (colima, OrbStack, Linux engine)
# they fall back to A and the log says so. The engine is Docker Desktop only when
# the pinned socket is Desktop's own (FSG_DESKTOP_SOCKET, compared physically):
# `docker desktop` drives the app, whatever engine DOCKER_HOST names.
#
# Only a local engine is touched: the endpoint (DOCKER_HOST, else the current
# context's) must be a unix socket on this Mac, and it is pinned for every later
# docker call of the process. Anything else skips the step (DK_STATE=notlocal).

# The endpoint the docker CLI would use. Empty when the context cannot be read.
# DOCKER_HOST beats DOCKER_CONTEXT in the CLI too (DESIGN §6).
fsg__docker_host() {
  if [ -n "${DOCKER_HOST:-}" ]; then printf '%s\n' "$DOCKER_HOST"; return; fi
  fsg_timeout 10 docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null | head -n 1
}

# 0 when the endpoint is a local unix socket owned by this user or root (Docker
# Desktop's ~/.docker/run/docker.sock, /var/run/docker.sock, colima, OrbStack).
# Sets DK_ENDPOINT, and DK_EP_WHY when refused. MISSING-OK also accepts a socket
# path with nothing there yet (a stopped Docker Desktop, for the recovery).
fsg_docker_endpoint() { # [missing-ok]
  local p u
  DK_EP_WHY=
  DK_ENDPOINT=$(fsg__docker_host)
  case $DK_ENDPOINT in
    "") DK_EP_WHY="the docker context cannot be read" ;;
    unix:///*)
      p=${DK_ENDPOINT#unix://}
      if [ -S "$p" ]; then
        u=$(stat -L -f %u "$p" 2>/dev/null)
        [ "$u" = 0 ] || [ "$u" = "$(id -u)" ] || DK_EP_WHY="the socket $p belongs to uid ${u:-unknown}"
      elif [ -e "$p" ] || [ -z "${1:-}" ]; then
        DK_EP_WHY="no socket at $p"
      fi ;;
    *) DK_EP_WHY="$DK_ENDPOINT is not a local unix socket" ;;
  esac
  [ -z "$DK_EP_WHY" ]
}

# Every later docker call of this process goes to DK_ENDPOINT, whatever context
# is selected meanwhile.
fsg_docker_pin() { DOCKER_HOST=$DK_ENDPOINT; export DOCKER_HOST; unset DOCKER_CONTEXT; }

# The physical path of a socket path: symlinks resolved, the last one included
# (/var/run/docker.sock links to Desktop's). A missing target stays as named.
fsg_sock_phys() { # path
  local p=$1 t n=0 d
  while [ -L "$p" ] && [ $n -lt 32 ]; do
    t=$(readlink "$p") || break
    case $t in /*) p=$t ;; *) p="$(dirname "$p")/$t" ;; esac
    n=$((n + 1))
  done
  d=$(CDPATH='' cd -P "$(dirname "$p")" 2>/dev/null && pwd -P) || { printf '%s\n' "$p"; return; }
  printf '%s/%s\n' "${d%/}" "$(basename "$p")"
}

# 0 when endpoints A and B are one engine: equal, or unix sockets with one physical
# path (Desktop's `default` and `desktop-linux` contexts).
fsg_docker_same_endpoint() { # a b
  [ "$1" = "$2" ] && return 0
  case $1 in unix:///*) ;; *) return 1 ;; esac
  case $2 in unix:///*) ;; *) return 1 ;; esac
  [ "$(fsg_sock_phys "${1#unix://}")" = "$(fsg_sock_phys "${2#unix://}")" ]
}

# 0 when DK_ENDPOINT is Docker Desktop's own socket.
fsg_docker_is_desktop_ep() {
  fsg_docker_same_endpoint "$DK_ENDPOINT" "unix://${FSG_DESKTOP_SOCKET:-$HOME/.docker/run/docker.sock}"
}

# docker desktop status -> running|stopped|... or empty.
fsg_desktop_status() {
  fsg_timeout "$FSG_DOCKER_QUERY_TIMEOUT_S" docker desktop status --format json 2>/dev/null | tr -d ' \n\t' |
    sed -n 's/.*"Status":"\([A-Za-z]*\)".*/\1/p'
}

# 0 when Docker Desktop's app or backend process runs (it may still not answer).
fsg_desktop_procs() {
  pgrep -f 'Docker\.app/Contents/MacOS/(com\.docker\.backend|Docker Desktop)' >/dev/null 2>&1
}

# The pids of Docker Desktop's backend, sorted, on one line; empty when none runs.
fsg_desktop_backend_pids() {
  pgrep -f 'Docker\.app/Contents/MacOS/com\.docker\.backend' 2>/dev/null | sort -n | tr '\n' ' ' | sed 's/ $//'
}

# 0 when no pid of the second list is in the first.
fsg__pids_disjoint() { # old new
  local p
  for p in $2; do case " $1 " in *" $p "*) return 1 ;; esac; done
  return 0
}

# The Docker Desktop sockets that still exist: its backend socket, its user socket
# and the pinned endpoint's. All gone once Docker Desktop has quit.
fsg__desktop_socks_left() {
  local p left=""
  for p in "${FSG_DESKTOP_BACKEND_SOCKET:-$HOME/Library/Containers/com.docker.docker/Data/backend.sock}" \
           "${FSG_DESKTOP_SOCKET:-$HOME/.docker/run/docker.sock}" "${DK_ENDPOINT#unix://}"; do
    [ -n "$p" ] && [ -S "$p" ] && case " $left " in *" $p "*) ;; *) left="${left:+$left }$p" ;; esac
  done
  printf '%s\n' "$left"
}

# One bounded `docker desktop status`: sets DS_STATUS (the Status word or empty),
# DS_RC, DS_S (seconds) and DS_OUT (stdout and stderr on one line, cut).
fsg__desktop_status_poll() { # seconds
  local t0 out
  t0=$(fsg_now)
  out=$(fsg_timeout "$1" docker desktop status --format json 2>&1); DS_RC=$?
  DS_S=$(( $(fsg_now) - t0 ))
  DS_STATUS=$(printf '%s' "$out" | tr -d ' \n\t' | sed -n 's/.*"Status":"\([A-Za-z]*\)".*/\1/p')
  DS_OUT=$(printf '%s' "$out" | tr '\t\r\n' '   ' | cut -c1-300)
}

# 0 when the engine answers one bounded `docker info`.
fsg_docker_answers() { fsg_timeout "$FSG_DOCKER_QUERY_TIMEOUT_S" docker info >/dev/null 2>&1; }

# Sets DK_KIND (desktop|engine|none), DK_STATE, DK_RUNNING (1 when it answers),
# DK_PS_OK, DK_ENDPOINT, DK_EP_WHY, DK_ENGINE (Docker Desktop, or another engine at
# its socket's path) and:
#   DK_STATE      running: it answers; stopped: no engine (and, on Desktop's socket,
#                 no Docker Desktop process); silent: it runs but answers neither query in time
#                 (wedged, the failure we heal: never treated as stopped);
#                 notlocal: the endpoint is not a local socket, nothing is asked
#   DK_STOP_IDS   every running container (variant A stops them all)
#   DK_IDS        the restore set: running containers that can be started again
#   DK_NAMES      their names
#   DK_HEALTH     their health status then, in the same order: healthy, unhealthy,
#                 starting, none (no health check), or - when it was not read
#   DK_EPHEMERAL  names of running --rm containers (HostConfig.AutoRemove): Docker
#                 deletes them when they stop, so they cannot be restored
#   DK_ONEOFF     names of running one-off containers (`docker compose run`, label
#                 com.docker.compose.oneoff=True) without --rm: starting one again
#                 runs its command again, detached, so they are not restored
#   DK_AT_RISK    the --rm containers among them with an anonymous volume, as
#                 "name (mount point, ...)" items joined by "; ": Docker deletes
#                 those volumes with the container, so no heal stops them
#   DK_RM_PLAIN   names of the other --rm containers (no anonymous volume)
#   DK_LISTED     0 when the containers or their settings could not be read (a
#                 wedged engine, a failed docker ps or inspect, an inspect that
#                 failed for a container that still runs, or a line of it that is
#                 not a whole record), so --rm volumes were not checked
fsg_docker_record() {
  DK_KIND=none; DK_STATE=stopped; DK_RUNNING=0; DK_IDS=; DK_NAMES=; DK_HEALTH=; DK_PS_OK=0; DK_STOP_IDS=; DK_EPHEMERAL=""; DK_ONEOFF=""
  DK_AT_RISK=""; DK_RM_PLAIN=""; DK_LISTED=1
  DK_ENDPOINT=; DK_EP_WHY=; DK_ENGINE=
  command -v docker >/dev/null 2>&1 || return 0
  local st irc
  if ! fsg_docker_endpoint; then
    DK_STATE=notlocal
    fsg_desktop_procs && DK_EP_WHY="$DK_EP_WHY; Docker Desktop runs on this Mac but is not the selected engine, so it is left as it is"
    fsg_log "DOCKER not a local engine ($DK_EP_WHY); the Docker step is skipped"
    return 0
  fi
  fsg_docker_pin
  if ! fsg_docker_is_desktop_ep; then
    # Another engine: `docker desktop` and Desktop's processes say nothing about it.
    DK_ENGINE="another engine at $(fsg_sock_phys "${DK_ENDPOINT#unix://}")"
    fsg_docker_answers; irc=$?
    if [ $irc -eq 0 ]; then
      DK_KIND=engine; DK_RUNNING=1; DK_STATE=running
    elif [ $irc -eq 124 ]; then
      DK_KIND=engine; DK_STATE=silent
    fi
    fsg_desktop_procs && fsg_log "DOCKER the selected engine is $DK_ENGINE, not Docker Desktop's socket; Docker Desktop runs and is left as it is"
  elif DK_ENGINE="Docker Desktop"; st=$(fsg_desktop_status); [ -n "$st" ]; then
    DK_KIND=desktop
    [ "$st" = running ] && { DK_RUNNING=1; DK_STATE=running; }
  else
    fsg_docker_answers; irc=$?
    if [ $irc -eq 0 ]; then
      DK_KIND=engine; DK_RUNNING=1; DK_STATE=running
    elif fsg_desktop_procs; then
      DK_KIND=desktop; DK_STATE=silent
    elif [ $irc -eq 124 ]; then
      DK_KIND=engine; DK_STATE=silent
    fi
  fi
  [ "$DK_STATE" = silent ] && {
    DK_LISTED=0
    fsg_log "DOCKER $DK_KIND runs but does not answer within ${FSG_DOCKER_QUERY_TIMEOUT_S}s; treated as wedged"
  }
  [ "$DK_RUNNING" = 1 ] || return 0
  fsg__docker_containers
}

# rec() in awk -F'\t' -v ids=IDS: 1 when the line is a whole container record
# (fsg__docker_containers) of one of IDS: its six fields, then three per mount, each
# holding what its part of the template prints (a JSON value for free text).
# shellcheck disable=SC2016
FSG__AWK_RECORD='
  function jv(s) { return s == "null" || s ~ /^"([^"\\]|\\.)*"$/ }
  function rec(   i) {
    if (NF < 6 || (NF - 6) % 3 || !($1 in want) || $2 !~ /^\/[a-zA-Z0-9][a-zA-Z0-9_.-]*$/ ||
      ($3 != "true" && $3 != "false") || !jv($4) || $5 !~ /^(null|\[.*\])(null|\[.*\])$/) return 0
    for (i = 6; i <= NF; i++) if (!jv($i)) return 0
    return 1
  }
  BEGIN { nw = split(ids, w, " "); for (iw = 1; iw <= nw; iw++) want[w[iw]] = 1 }'

# The running containers of the pinned engine: sets DK_PS_OK, DK_STOP_IDS, DK_IDS,
# DK_NAMES, DK_HEALTH, DK_EPHEMERAL, DK_ONEOFF, DK_AT_RISK, DK_RM_PLAIN and
# DK_LISTED (as in fsg_docker_record).
#
# A volume mount is anonymous when the container's own spec names no volume for it
# (an image VOLUME, `-v /path`, `--mount type=volume` without a source): Docker's
# --rm removes exactly those, and keeps named ones (`-v name:/path`, compose
# volumes). A volume inherited with --volumes-from also counts as anonymous here,
# so such a container is protected even if its volume would survive.
fsg__docker_containers() {
  local ps out ar="" arc skip_ids t unread now bad
  DK_PS_OK=0; DK_STOP_IDS=; DK_IDS=; DK_NAMES=; DK_HEALTH=; DK_EPHEMERAL=""; DK_ONEOFF=""; DK_AT_RISK=""; DK_RM_PLAIN=""; DK_LISTED=0
  ps=$(fsg_timeout 30 docker ps --no-trunc --format '{{.ID}} {{.Names}}' 2>/dev/null) || return 0
  DK_PS_OK=1; DK_LISTED=1
  DK_STOP_IDS=$(printf '%s\n' "$ps" | awk 'NF { print $1 }' | tr '\n' ' ' | sed 's/ $//')
  if [ -n "$DK_STOP_IDS" ]; then
    t=$(printf '\t')
    # docker inspect tries a template on its typed struct first and, when that fails
    # (here at once: the struct has ID, the JSON Id), on the raw JSON with
    # missingkey=error. Every key that JSON may lack (a mount's Name, absent for a
    # bind mount, and Type; HostConfig.Mounts, absent without --mount; State.Health,
    # absent without a health check) is read with index: a missing one prints null.
    # Free text (the label, a mount's name and destination) goes through json too, so
    # a tab or newline in it cannot shift the fields or split the record. A real engine's records:
    # test/fixtures/docker-cli-29.9.2/.
    # shellcheck disable=SC2086
    ar=$(fsg_timeout 20 docker inspect --format "{{.Id}}$t{{.Name}}$t{{.HostConfig.AutoRemove}}$t{{json (index .Config.Labels \"com.docker.compose.oneoff\")}}$t{{json (index .HostConfig \"Binds\")}}{{json (index .HostConfig \"Mounts\")}}$t{{with index .State \"Health\"}}{{json (index . \"Status\")}}{{else}}null{{end}}{{range .Mounts}}$t{{json (index . \"Type\")}}$t{{json (index . \"Name\")}}$t{{json (index . \"Destination\")}}{{end}}" $DK_STOP_IDS 2>/dev/null); arc=$?
    # A container that exited since docker ps fails inspect for itself only. One that
    # still runs but failed it (a per-container template error), or whose line is not
    # a whole record, was not checked.
    if [ $arc -eq 124 ] || { [ $arc -ne 0 ] && [ -z "$ar" ]; }; then
      fsg_log "DOCKER cannot read AutoRemove, the one-off label and the mounts; treating every container as restorable, --rm volumes not checked"
      ar=""; DK_LISTED=0
    else
      bad=$(printf '%s\n' "$ar" | awk -F'\t' -v ids="$DK_STOP_IDS" "$FSG__AWK_RECORD"' NF && !rec() { bad++ } END { print bad + 0 }')
      if [ "$bad" != 0 ]; then
        fsg_log "DOCKER docker inspect printed $bad line(s) that are not a whole container record; --rm volumes not checked"
        ar=$(printf '%s\n' "$ar" | awk -F'\t' -v ids="$DK_STOP_IDS" "$FSG__AWK_RECORD"' rec()'); DK_LISTED=0
      fi
      unread=$(printf '%s\n' "$ar" | awk -F'\t' -v ids="$DK_STOP_IDS" '{ got[$1] = 1 }
        END { n = split(ids, a, " "); for (i = 1; i <= n; i++) if (!(a[i] in got)) print a[i] }' | tr '\n' ' ' | sed 's/ $//')
      if [ -n "$unread" ] && now=$(fsg_timeout 30 docker ps -q --no-trunc 2>/dev/null); then
        unread=$(printf '%s\n' "$now" | awk -v u="$unread" 'BEGIN { n = split(u, a, " "); for (i = 1; i <= n; i++) want[a[i]] = 1 }
          $1 in want { print $1 }' | tr '\n' ' ' | sed 's/ $//')
      fi
      if [ -n "$unread" ]; then
        fsg_log "DOCKER cannot read AutoRemove, the one-off label and the mounts of $unread, which still run or could not be listed again; --rm volumes not checked"
        DK_LISTED=0
      fi
    fi
  fi
  DK_EPHEMERAL=$(printf '%s\n' "$ar" | awk -F'\t' '$3 == "true" { sub(/^\//, "", $2); print $2 }' | tr '\n' ' ' | sed 's/ $//')
  DK_ONEOFF=$(printf '%s\n' "$ar" | awk -F'\t' '$3 != "true" && $4 == "\"True\"" { sub(/^\//, "", $2); print $2 }' | tr '\n' ' ' | sed 's/ $//')
  # One line per --rm container: "V name (mount points)" with an anonymous volume,
  # else "R name". Field 4 is the one-off label (null when not set: not a one-off),
  # field 5 the spec (HostConfig.Binds, then HostConfig.Mounts; null for each that is
  # absent), field 6 the health status (null without a health check), and each mount
  # three more: type, name (null for a bind mount) and destination. Names are
  # compared, and mount points printed, as JSON escapes them.
  out=$(printf '%s\n' "$ar" | awk -F'\t' '$3 == "true" {
    name = $2; sub(/^\//, "", name); d = ""
    for (i = 7; i + 2 <= NF; i += 3) {
      if ($i != "\"volume\"") continue
      vn = $(i + 1); dest = $(i + 2)
      if (dest != "null") dest = substr(dest, 2, length(dest) - 2)
      if (vn != "null" && vn != "\"\"") {
        vn = substr(vn, 2, length(vn) - 2)
        if (index($5, "\"" vn ":") || index($5, "\"Source\":\"" vn "\"")) continue
      }
      d = d (d == "" ? "" : ", ") dest
    }
    if (d != "") print "V " name " (" d ")"; else print "R " name
  }')
  DK_AT_RISK=$(printf '%s\n' "$out" | sed -n 's/^V //p' | awk '{ s = s (NR > 1 ? "; " : "") $0 } END { print s }')
  DK_RM_PLAIN=$(printf '%s\n' "$out" | sed -n 's/^R //p' | tr '\n' ' ' | sed 's/ $//')
  skip_ids=$(printf '%s\n' "$ar" | awk -F'\t' '$3 == "true" || $4 == "\"True\"" { print $1 }' | tr '\n' ' ')
  out=$(printf '%s\n' "$ps" | awk -v e="$skip_ids" 'BEGIN { n = split(e, a, " "); for (i = 1; i <= n; i++) skip[a[i]] = 1 }
    NF && !($1 in skip)')
  DK_IDS=$(printf '%s\n' "$out" | awk 'NF { print $1 }' | tr '\n' ' ' | sed 's/ $//')
  DK_NAMES=$(printf '%s\n' "$out" | awk 'NF { print $2 }' | tr '\n' ' ' | sed 's/ $//')
  DK_HEALTH=$(printf '%s\n' "$ar" | awk -F'\t' -v ids="$DK_IDS" 'NF >= 6 {
      h = $6; if (h == "null") h = "none"; else if (h ~ /^"[a-z]+"$/) h = substr(h, 2, length(h) - 2); else h = "-"
      got[$1] = h }
    END { n = split(ids, a, " "); for (i = 1; i <= n; i++) printf "%s%s", (i > 1 ? " " : ""), (a[i] in got ? got[a[i]] : "-") }')
}

# The running --rm containers with an anonymous volume now, from a fresh listing, in
# AT_RISK_NOW (the record's restore set stays as it is). 1 when they could not be
# listed.
fsg_docker_at_risk_now() {
  local DK_PS_OK DK_STOP_IDS DK_IDS DK_NAMES DK_HEALTH DK_EPHEMERAL DK_ONEOFF DK_AT_RISK DK_RM_PLAIN DK_LISTED
  AT_RISK_NOW=
  fsg__docker_containers
  [ "$DK_LISTED" = 1 ] || return 1
  AT_RISK_NOW=$DK_AT_RISK
}

# 0 when VARIANT's Docker step stops running containers: A stops them, B quits Docker
# Desktop, C restarts it.
fsg_docker_stops_containers() { case $1 in A|B|C) return 0 ;; esac; return 1; }

# 0 when VARIANT's Docker step stops containers whose --rm volumes could not be
# checked (DK_LISTED=0): B and C stop every container, A only those docker ps listed.
fsg_docker_unchecked() { # variant
  [ "${DK_LISTED:-1}" = 0 ] || return 1
  case $1 in B|C) return 0 ;; A) [ -n "$DK_STOP_IDS" ] ;; *) return 1 ;; esac
}

# 0 when the Docker step has nothing to act on or check: Docker stopped, or not local.
fsg_docker_off() { [ "$DK_STATE" = stopped ] || [ "$DK_STATE" = notlocal ]; }

fsg_docker_record_text() {
  echo "kind=$DK_KIND state=$DK_STATE ps_ok=$DK_PS_OK listed=$DK_LISTED"
  echo "engine=$DK_ENGINE"
  echo "endpoint=$DK_ENDPOINT${DK_EP_WHY:+ (not used: $DK_EP_WHY)}"
  echo "ids=$DK_IDS"
  echo "names=$DK_NAMES"
  echo "health=$DK_HEALTH"
  echo "not_restorable=$DK_EPHEMERAL"
  echo "not_restored_oneoff=$DK_ONEOFF"
  echo "rm_anonymous_volumes=$DK_AT_RISK"
}

# The variant actually used, after fallbacks. A silent Docker Desktop is restarted
# (A cannot list the containers to stop, so it becomes C); a silent other engine
# cannot be restarted from here, and the verify step decides.
fsg_docker_effective_variant() {
  local v=$1
  case $DK_STATE in
    stopped|notlocal) echo skip; return ;;
    silent) if [ "$DK_KIND" = desktop ] && [ "$v" = A ]; then echo C; return; fi ;;
  esac
  case $v in
    B|C) [ "$DK_KIND" = desktop ] && echo "$v" || echo A ;;
    *) echo "$v" ;;
  esac
}

# Prints the commands of a step without running them (dry-run plans).
fsg_docker_plan() { # variant before|after
  case "$1:$2" in
    skip:*) if [ "$DK_STATE" = notlocal ]; then echo "nothing (not a local Docker engine: $DK_EP_WHY)"
            else echo "nothing (Docker is stopped)"; fi ;;
    none:*) echo "nothing (variant none)" ;;
    A:before) echo "docker stop -t $FSG_STOP_TIMEOUT_S ${DK_STOP_IDS:-<no running containers>}" ;;
    A:after) echo "docker start ${DK_IDS:-<none>}" ;;
    B:before) echo "docker desktop stop --timeout $FSG_DOCKER_TIMEOUT_S" ;;
    B:after) echo "docker desktop start --timeout $FSG_DOCKER_TIMEOUT_S; docker start <recorded ids that are not running>" ;;
    C:before) echo "nothing (variant C acts after the restart)" ;;
    C:after) echo "docker desktop restart --timeout $FSG_DOCKER_TIMEOUT_S; docker start <recorded ids that are not running>" ;;
  esac
}

fsg_wait_engine() { # seconds
  local t0
  t0=$(fsg_now)
  while [ $(( $(fsg_now) - t0 )) -lt "$1" ]; do
    fsg_docker_answers && return 0
    fsg_sleep 2
  done
  return 1
}

# Waits for Docker Desktop to stop, up to FSG_DESKTOP_STOP_WAIT_S from T0 (when
# `docker desktop stop` was issued); one check always runs. Stopped: no Desktop
# process runs and its sockets are gone, or status says stopped. Once Desktop has
# quit, status fails only after ~16 s (it dials the missing backend socket), so the
# processes and sockets are checked every second, and status, bounded to 3 s, only
# when they do not decide, at most every 5 s. Each poll goes to LOG. Sets
# DK_STOP_WHY. 0 stopped; 2 a new backend runs (something else started Docker
# Desktop; DK_NEW_PIDS); 1 not stopped.
fsg__wait_desktop_stopped() { # t0 backend-pids-before log
  local procs pids socks st_next=0 gone=0 n=0 rc= last=unknown
  while :; do
    n=$((n + 1))
    pids=$(fsg_desktop_backend_pids)
    if fsg_desktop_procs; then procs=yes; else procs=no; gone=1; fi
    socks=$(fsg__desktop_socks_left)
    DS_STATUS=; DS_RC=; DS_S=; DS_OUT=
    if [ $procs = no ] && [ -z "$socks" ]; then
      rc=0; DK_STOP_WHY="no Docker Desktop process runs and its sockets are gone"
    elif [ -n "$pids" ] && fsg__pids_disjoint "$2" "$pids" && { [ -n "$2" ] || [ $gone = 1 ]; }; then
      rc=2; DK_NEW_PIDS=$pids; DK_STOP_WHY="a new Docker Desktop backend runs (pid $pids; before the stop: ${2:-none})"
    elif [ "$(fsg_now)" -ge "$st_next" ]; then
      fsg__desktop_status_poll 3
      st_next=$(( $(fsg_now) + 5 ))
      last="${DS_STATUS:-none (rc $DS_RC)}"
      [ "$DS_STATUS" = stopped ] && { rc=0; DK_STOP_WHY="docker desktop status says stopped"; }
    fi
    printf 'poll %s +%ss: procs=%s backend=%s sockets=%s status=%s rc=%s in %ss: %s\n' "$n" $(( $(fsg_now) - $1 )) \
      "$procs" "${pids:-none}" "${socks:-none}" "${DS_STATUS:--}" "${DS_RC:--}" "${DS_S:--}" "${DS_OUT:-(not asked)}" >> "$3"
    [ -n "$rc" ] && return $rc
    [ $(( $(fsg_now) - $1 )) -lt "$FSG_DESKTOP_STOP_WAIT_S" ] || break
    fsg_sleep 1
  done
  DK_STOP_WHY="still there after ${FSG_DESKTOP_STOP_WAIT_S}s: processes $procs, sockets ${socks:-none}, last status $last"
  return 1
}

# Something else started Docker Desktop during the heal (a new backend runs where
# none ran, or none of the old ones): sets DK_FOREIGN, said in the record and the
# notices. The guard does not fight it; the restore goes on as usual.
fsg__desktop_foreign() { # backend-pids-now
  DK_FOREIGN="something else started Docker Desktop during the heal (backend pid $1; before the stop: ${DK_PRE_PIDS:-none}); the guard left it running"
  fsg_log "DOCKER $DK_FOREIGN"
}

# Before variant B's after-step: a backend that is not the one the stop saw, once
# the stop was seen (or the old backend is gone), was started by something else.
fsg__desktop_foreign_check() {
  local now
  [ -n "${DK_STOP_DECISION:-}" ] && [ -z "${DK_FOREIGN:-}" ] || return 0
  now=$(fsg_desktop_backend_pids)
  [ -n "$now" ] && fsg__pids_disjoint "${DK_PRE_PIDS:-}" "$now" || return 0
  [ -n "${DK_PRE_PIDS:-}" ] || [ "$DK_STOP_DECISION" = stopped ] || return 0
  fsg__desktop_foreign "$now"
}

# Runs the before-step. Returns non-zero on failure (DK_ERR says why).
fsg_docker_before() { # variant
  local t0 log wrc
  DK_ERR=
  case $1 in
    A)
      [ -n "$DK_STOP_IDS" ] || return 0
      fsg_log "DOCKER A stop ids=\"$DK_STOP_IDS\"${DK_EPHEMERAL:+ (not restorable, --rm: $DK_EPHEMERAL)}"
      # shellcheck disable=SC2086
      fsg_timeout "$FSG_DOCKER_TIMEOUT_S" docker stop -t "$FSG_STOP_TIMEOUT_S" $DK_STOP_IDS >/dev/null 2>&1 ||
        { DK_ERR="docker stop failed"; return 1; }
      ;;
    B)
      # The stop and each poll go to the heal record.
      log=/dev/null; [ -n "${HEAL_DIR:-}" ] && log="$HEAL_DIR/docker-stop.txt"
      DK_PRE_PIDS=$(fsg_desktop_backend_pids)
      fsg_log "DOCKER B desktop stop (backend pid ${DK_PRE_PIDS:-none})"
      echo "backend pid before the stop: ${DK_PRE_PIDS:-none}" >> "$log"
      echo "== docker desktop stop output" >> "$log"
      t0=$(fsg_now)
      # Not in a subshell: a signal meanwhile lets the stop finish (fsg_tick_cleanup).
      fsg_timeout $((FSG_DOCKER_TIMEOUT_S + 10)) docker desktop stop --timeout "$FSG_DOCKER_TIMEOUT_S" >> "$log" 2>&1
      DK_STOP_RC=$?; DK_STOP_S=$(( $(fsg_now) - t0 ))
      echo "== stop rc=$DK_STOP_RC in ${DK_STOP_S}s; polls (up to ${FSG_DESKTOP_STOP_WAIT_S}s from the stop):" >> "$log"
      fsg__wait_desktop_stopped "$t0" "$DK_PRE_PIDS" "$log"; wrc=$?
      case $wrc in
        0) DK_STOP_DECISION=stopped ;;
        2) DK_STOP_DECISION=started-by-other ;;
        *) DK_STOP_DECISION=not-stopped ;;
      esac
      echo "decision: $DK_STOP_DECISION ($DK_STOP_WHY)" >> "$log"
      fsg_log "DOCKER B stop rc=$DK_STOP_RC in ${DK_STOP_S}s: $DK_STOP_DECISION ($DK_STOP_WHY)"
      if [ $wrc = 2 ]; then fsg__desktop_foreign "$DK_NEW_PIDS"; return 0; fi
      [ $wrc = 0 ] || { DK_ERR="Docker Desktop did not stop within ${FSG_DESKTOP_STOP_WAIT_S}s of docker desktop stop ($DK_STOP_WHY)"; return 1; }
      ;;
  esac
  return 0
}

# Starts the recorded containers that are not running.
fsg_docker_start_missing() {
  [ -n "$DK_IDS" ] || return 0
  local id st missing=""
  for id in $DK_IDS; do
    st=$(fsg_timeout 20 docker inspect --format '{{.State.Status}}' "$id" 2>/dev/null)
    [ "$st" = running ] || missing="$missing $id"
  done
  [ -n "$missing" ] || return 0
  fsg_log "DOCKER start ids=\"${missing# }\""
  # shellcheck disable=SC2086
  fsg_timeout "$FSG_DOCKER_TIMEOUT_S" docker start $missing >/dev/null 2>&1
}

# `docker desktop start`, then the wait for the engine. Idempotent: a Docker
# Desktop that runs stays as it is.
fsg_docker_desktop_start() { # log-text
  DK_ERR=
  fsg_log "DOCKER $1"
  fsg_timeout $((FSG_DOCKER_TIMEOUT_S + 10)) docker desktop start --timeout "$FSG_DOCKER_TIMEOUT_S" >/dev/null 2>&1
  fsg_wait_engine "$FSG_DOCKER_TIMEOUT_S" || { DK_ERR="the Docker engine did not come back"; return 1; }
}

# Runs the after-step. Returns non-zero on failure (DK_ERR says why), 2 when C
# skipped its restart. Sets DK_NOTE when C restarted without checking the --rm
# volumes again, and keeps the one the heal set for a before-step it ran unchecked:
# the result notices name it.
fsg_docker_after() { # variant
  DK_ERR=
  case $1 in
    A)
      [ -n "$DK_IDS" ] || return 0
      fsg_log "DOCKER A start ids=\"$DK_IDS\""
      # shellcheck disable=SC2086
      fsg_timeout "$FSG_DOCKER_TIMEOUT_S" docker start $DK_IDS >/dev/null 2>&1 || { DK_ERR="docker start failed"; return 1; }
      ;;
    B)
      fsg__desktop_foreign_check
      fsg_docker_desktop_start "B desktop start" || return 1
      fsg_docker_start_missing || { DK_ERR="docker start failed"; return 1; }
      ;;
    C)
      # The restart comes minutes after the heal's check: a --rm container started
      # since would lose its anonymous volumes, so the containers are listed again.
      # A listing that fails while the engine answers skips the restart too. Only a
      # wedged engine (docker info does not answer: the failure C heals) is
      # restarted unchecked.
      if ! fsg_docker_answers; then
        DK_NOTE="Docker Desktop restarted unchecked: Docker did not answer docker info (wedged), so its containers were not listed again, and any --rm container with an anonymous volume started since the heal's check lost that volume"
        fsg_log "DOCKER C $DK_NOTE"
      elif ! fsg_docker_at_risk_now; then
        DK_ERR="Docker Desktop not restarted: Docker answers but did not list its containers, so --rm containers with an anonymous volume could not be checked"
        fsg_log "DOCKER C $DK_ERR"
        return 2
      elif [ -n "$AT_RISK_NOW" ]; then
        DK_ERR="Docker Desktop not restarted: it would delete these --rm containers and their anonymous volumes: $AT_RISK_NOW"
        fsg_log "DOCKER C $DK_ERR"
        return 2
      fi
      fsg_log "DOCKER C desktop restart"
      fsg_timeout $((FSG_DOCKER_TIMEOUT_S + 10)) docker desktop restart --timeout "$FSG_DOCKER_TIMEOUT_S" >/dev/null 2>&1
      fsg_wait_engine "$FSG_DOCKER_TIMEOUT_S" || { DK_ERR="the Docker engine did not come back"; return 1; }
      fsg_docker_start_missing || { DK_ERR="docker start failed"; return 1; }
      ;;
  esac
  return 0
}

# Waits until every recorded container is running and, when it was healthy at the
# record (DK_HEALTH, by position), healthy. One that was unhealthy, starting or had
# no health check then only needs to run; one whose health was not recorded (an
# older record) needs to be healthy when it has a check. Sets DK_FAILED to the ids
# that never got there.
fsg_docker_wait_containers() {
  DK_FAILED=
  [ -n "$DK_IDS" ] || return 0
  local t0 id line bad i
  local -a H
  # shellcheck disable=SC2206
  H=(${DK_HEALTH:-})
  t0=$(fsg_now)
  while :; do
    bad=; i=0
    for id in $DK_IDS; do
      # Typed fields only, so the CLI never falls back to the raw JSON, where the
      # absent Health key of a container without a health check would fail it.
      line=$(fsg_timeout 20 docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id" 2>/dev/null)
      case $line in
        "running healthy"|"running none") ;;
        "running "*) case ${H[$i]:-} in unhealthy|starting|none) ;; *) bad="$bad $id" ;; esac ;;
        *) bad="$bad $id" ;;
      esac
      i=$((i + 1))
    done
    if [ -z "$bad" ]; then return 0; fi
    if [ $(( $(fsg_now) - t0 )) -ge "$FSG_CONTAINER_TIMEOUT_S" ]; then
      DK_FAILED=${bad# }
      return 1
    fi
    fsg_sleep 3
  done
}

# Candidate images for the bind-mount probe; nothing is pulled.
fsg_probe_images() {
  if [ -n "$FSG_PROBE_IMAGE" ]; then echo "$FSG_PROBE_IMAGE"; return; fi
  {
    fsg_timeout 20 docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null |
      grep -E '(^|/)(alpine|busybox|bash):|alpine' | grep -v '<none>' | head -n 2
    # shellcheck disable=SC2086
    [ -n "$DK_IDS" ] && fsg_timeout 20 docker inspect --format '{{.Config.Image}}' $DK_IDS 2>/dev/null
  } | awk 'NF && !seen[$0]++' | head -n 3
}

# Docker Desktop's File Sharing list (FilesharingDirectories in its
# settings-store.json, read only), one path per line. 1 when the file or the key is
# missing or unreadable: Desktop's default sharing (/Users, /Volumes, /private, /tmp,
# /var/folders) applies.
fsg_desktop_shared_dirs() {
  local f=${FSG_DESKTOP_SETTINGS:-"$HOME/Library/Group Containers/group.com.docker/settings-store.json"} n i=0
  [ -r "$f" ] || return 1
  n=$(plutil -extract FilesharingDirectories raw -o - "$f" 2>/dev/null) && fsg_is_uint "$n" || return 1
  while [ $i -lt "$n" ]; do
    plutil -extract "FilesharingDirectories.$i" raw -o - "$f" 2>/dev/null | sed '/^$/d'
    i=$((i + 1))
  done
}

# 0 when PATH is one of the dirs in LIST (lines) or under one, by whole components.
fsg__under_any() { # path list
  local e
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    e=${e%/}
    case $1 in "$e"|"$e"/*) return 0 ;; esac
  done <<EOF
$2
EOF
  return 1
}

# The bind-mount probe's host dir in BM_DIR: FSG_PROBE_DIR, else the state dir's
# mountprobe when Docker Desktop shares it (default sharing does), else a dir in the
# first shared folder under your home. BM_SHARED: 1 in the File Sharing list, 0 not,
# empty when Desktop uses its default sharing.
fsg_probe_dir() {
  local list e
  BM_SHARED=; BM_DIR=${FSG_PROBE_DIR:-"$FSG_STATE_DIR/mountprobe"}
  list=$(fsg_desktop_shared_dirs) || return 0
  if fsg__under_any "$BM_DIR" "$list"; then BM_SHARED=1; return 0; fi
  BM_SHARED=0
  [ -z "${FSG_PROBE_DIR:-}" ] || return 0
  while IFS= read -r e; do
    case $e in
      "$HOME"/*) if [ -d "$e" ] && [ -w "$e" ]; then BM_DIR="${e%/}/.fseventsd-guard-mountprobe"; BM_SHARED=1; return 0; fi ;;
    esac
  done <<EOF
$list
EOF
}

# The probe's file in BM_DIR; the container's side of the bind mount is /fsg-probe.
FSG__PROBE_FILE=fsg-probe.txt

# Writes a file on the host, reads it in a throwaway container that writes its reply
# into it, reads that on the host, and removes the file (and the dir if it made it).
# Sets BM_RESULT (ok|failed|skipped), BM_DETAIL and BM_NOTE (a skip the notices
# name: the probe dir is not shared with Docker Desktop).
fsg_docker_verify_bind_mount() {
  BM_RESULT=skipped; BM_DETAIL=; BM_NOTE=
  if [ "$FSG_VERIFY_BIND_MOUNT" != 1 ]; then BM_DETAIL="disabled"; return 0; fi
  if [ "$DK_STATE" = stopped ]; then BM_DETAIL="Docker was not running"; return 0; fi
  if [ "$DK_STATE" = notlocal ]; then BM_DETAIL="not a local Docker engine"; return 0; fi
  local dir f out nonce img got rc made=0 tried=""
  fsg_probe_dir
  dir=$BM_DIR; f="$BM_DIR/$FSG__PROBE_FILE"; out="$FSG_STATE_DIR/mountprobe.out"
  [ -d "$dir" ] || made=1
  mkdir -p "$dir" || { BM_RESULT=failed; BM_DETAIL="cannot create $dir"; return 1; }
  nonce="fsg-$(fsg_now)-$$"
  while IFS= read -r img; do
    [ -n "$img" ] || continue
    tried="$tried $img"
    printf '%s\n' "$nonce" > "$f"
    fsg_timeout 90 docker run --rm --pull never --network none --entrypoint /bin/sh \
      -v "$dir:/fsg-probe" "$img" -c "read -r v < /fsg-probe/$FSG__PROBE_FILE && echo \"back:\$v\" > /fsg-probe/$FSG__PROBE_FILE" \
      > "$out" 2>&1; rc=$?
    got=$(cat "$f" 2>/dev/null)
    if [ $rc -ne 0 ]; then
      case $(tr 'A-Z' 'a-z' < "$out" 2>/dev/null) in
        *"mounts denied"*|*"is not shared"*)
          BM_RESULT=skipped
          BM_DETAIL="the probe dir $dir is not shared with Docker Desktop (mounts denied); set FSG_PROBE_DIR to a dir in a folder of its File Sharing list"
          BM_NOTE="Bind mount check skipped: $BM_DETAIL."
          break ;;
      esac
      BM_RESULT=failed
      continue
    fi
    if [ "$got" = "back:$nonce" ]; then BM_RESULT=ok; BM_DETAIL="round trip ok via $img"
    else BM_RESULT=failed; BM_DETAIL="the container ran ($img) but the round trip did not match (got '${got:-nothing}')"; fi
    break
  done <<EOF
$(fsg_probe_images)
EOF
  rm -f "$f" "$out"
  [ $made = 1 ] && rmdir "$dir" 2>/dev/null
  [ -n "$BM_NOTE" ] && fsg_log "DOCKER $BM_NOTE"
  if [ -z "$tried" ]; then BM_DETAIL="no local image with /bin/sh (set FSG_PROBE_IMAGE)"; return 0; fi
  [ -n "$BM_DETAIL" ] || BM_DETAIL="no probe container could run (tried:$tried)"
  [ "$BM_RESULT" != failed ]
}

# Why Docker is not verified: DK_ERR, the containers not back and, unless NOBIND,
# the bind mount's detail, joined so that none that is empty leaves a separator.
fsg_docker_why() { # [nobind]
  local s=${DK_ERR:-}
  [ -n "${DK_FAILED:-}" ] && s="${s:+$s }containers: $DK_FAILED"
  [ -z "${1:-}" ] && [ -n "${BM_DETAIL:-}" ] && s="${s:+$s; }bind mount: $BM_DETAIL"
  printf '%s\n' "$s"
}

# Docker is back: the engine answers, the recorded containers run (healthy when
# they were) and a bind mount round trip works. A Docker that was stopped needs
# nothing, nor does one that is not local (never touched). Returns non-zero
# otherwise (DK_ERR, DK_FAILED, BM_* say why).
fsg_docker_verified() {
  DK_FAILED=; BM_RESULT=skipped; BM_DETAIL=
  if [ "$DK_STATE" = stopped ]; then BM_DETAIL="Docker was not running"; return 0; fi
  if [ "$DK_STATE" = notlocal ]; then BM_DETAIL="not a local Docker engine"; return 0; fi
  fsg_docker_answers || { DK_ERR="the Docker engine does not answer"; return 1; }
  fsg_docker_wait_containers || { DK_ERR="containers not back"; return 1; }
  fsg_docker_verify_bind_mount || { DK_ERR="bind mount $BM_RESULT"; return 1; }
}
