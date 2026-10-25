#!/bin/bash
# fseventsd-guard test suite. Needs no root and never touches fseventsd, Docker,
# launchd or sudo: every external command the guard uses is a stub on PATH (see
# stubs/), the root helper runs as the user against stand-in tools (helper-tools/),
# and install/uninstall work in a fake root (--prefix).
#
#   bash plugins/fseventsd-guard/test/run-tests.sh [NAME-FILTER]
#
# Exit 0 when every test passes.

set -u
HERE=$(cd -P "$(dirname "$0")" && pwd)
GUARD_HOME=$(cd -P "$HERE/.." && pwd)
FILTER=${1:-}

# Dirs of earlier runs killed outright (SIGKILL skips the trap below): only those
# with this suite's owner file, and only once the run it names is gone.
for d in "${TMPDIR:-/tmp}"/fsg-test.*; do
  [ -f "$d/.owner" ] || continue
  p=$(cat "$d/.owner" 2>/dev/null)
  case $p in ''|*[!0-9]*) continue ;; esac
  kill -0 "$p" 2>/dev/null || rm -rf "$d"
done
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fsg-test.XXXXXX") || exit 1
ROOT=$(cd -P "$ROOT" && pwd)
echo $$ > "$ROOT/.owner"
BG_PIDS=""; INTERRUPTED=0
cleanup() {
  local p
  if [ "$INTERRUPTED" = 0 ]; then
    command -v agent_stop >/dev/null && agent_stop
    for p in $BG_PIDS; do kill "$p" 2>/dev/null; done
    wait 2>/dev/null
  else
    # No graceful waits (timeout -k allows 30 s). Agent ticks run in sessions of
    # their own (stubs/launchctl), out of reach of a signal to this process group:
    # each one of this run that still runs goes, with its children.
    for p in $(cat "$ROOT"/case-*/fake/agent-ticks 2>/dev/null); do
      /bin/ps -o command= -p "$p" 2>/dev/null | grep -qF "$ROOT/" && kill -KILL -- "-$p" 2>/dev/null
    done
    for p in $BG_PIDS; do kill -KILL "$p" 2>/dev/null; done
  fi
  rm -rf "$ROOT"
}
trap cleanup EXIT
trap 'INTERRUPTED=1; exit 130' INT TERM HUP
mkdir -p "$ROOT/tools"
cp -R "$HERE/stubs" "$HERE/helper-tools" "$HERE/fixtures" "$ROOT/tools/"
STUBS=$ROOT/tools/stubs
# Unix sockets for the fake engine endpoints (the guard accepts only a local socket):
# each case links its default context's docker.sock to the first.
mksock() { /usr/bin/perl -MIO::Socket::UNIX -e 'IO::Socket::UNIX->new(Type => SOCK_STREAM(), Local => $ARGV[0], Listen => 1) or die "socket $ARGV[0]: $!\n"' "$1"; }
mksock "$ROOT/tools/docker.sock" && mksock "$ROOT/tools/other.sock" || { echo "SETUP: cannot create the fake engine sockets" >&2; exit 2; }
TOOLS=$ROOT/tools/helper-tools

export PATH="$STUBS:/usr/bin:/bin:/usr/sbin:/sbin"
for c in sudo docker curl launchctl osascript pgrep top ps sw_vers swiftc sysctl; do
  if [ "$(command -v "$c")" != "$STUBS/$c" ]; then
    echo "SAFETY: '$c' resolves to $(command -v "$c"), not the stub; refusing to run" >&2
    exit 2
  fi
done
command -v terminal-notifier >/dev/null 2>&1 && { echo "SAFETY: terminal-notifier on PATH" >&2; exit 2; }

# The guard under test runs from a throwaway git repo whose origin is the reviewed
# repo's URL (never fetched) and whose origin/main is its own HEAD, so install's
# source gate sees a clean, reviewed tree (whatever state the real checkout is in)
# and the gate itself can be tested.
tgit() {
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid \
    GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid \
    git -c core.hooksPath=/dev/null -c commit.gpgsign=false -C "$REPO" "$@"
}
REPO=$ROOT/repo
mkdir -p "$REPO/plugins"
cp -R "$GUARD_HOME" "$REPO/plugins/fseventsd-guard"
# The repository root's marketplace and .gitattributes, which the plugin tests check,
# when this runs from a checkout of the whole repository (else those tests skip).
SRC_TOP=$(cd -P "$GUARD_HOME/../.." && pwd)
if [ "$(cd -P "$SRC_TOP/plugins/fseventsd-guard" 2>/dev/null && pwd)" = "$GUARD_HOME" ]; then
  for f in .gitattributes .claude-plugin; do [ -e "$SRC_TOP/$f" ] && cp -R "$SRC_TOP/$f" "$REPO/"; done
fi
tgit init -q && tgit add -A && tgit commit -q -m "guard under test" && tgit update-ref refs/remotes/origin/main HEAD &&
  tgit remote add origin https://github.com/RuslanTar/fseventsd-guard.git ||
  { echo "SETUP: cannot create the test repo" >&2; exit 2; }
GUARD_HOME=$REPO/plugins/fseventsd-guard

G="$GUARD_HOME/fseventsd-guard"
PASS=0; FAIL=0; CUR=""; N=0

# The tick the stub launchctl kickstart started (stubs/launchctl), if it still runs.
agent_pid() {
  local p
  p=$(cat "$FSG_FAKE/agent-tick.pid" 2>/dev/null)
  [ -n "$p" ] && /bin/ps -p "$p" >/dev/null 2>&1 && echo "$p"
}
# Waits until the agent's tick is done (a request's heal, then its fseventsd check).
agent_wait() { local n=600; while [ $n -gt 0 ] && [ -n "$(agent_pid)" ]; do sleep 0.2; n=$((n - 1)); done; }
agent_stop() {
  local p
  [ -n "${FSG_FAKE:-}" ] || return 0
  p=$(agent_pid) || return 0
  kill "$p" 2>/dev/null; agent_wait
}
# heal and trial through the agent, returning once its tick is done too.
heal() { "$G" heal "$@"; local rc=$?; agent_wait; return $rc; }
trial() { "$G" trial "$@"; local rc=$?; agent_wait; return $rc; }

# agent_env KEY=VALUE...: a knob for the agent's ticks from now on in this case.
agent_env() { printf '%s\n' "$@" >> "$FSG_FAKE/agent-env"; }

t() { # start a test: t NAME
  agent_stop
  CUR=$1
  N=$((N + 1))
  C="$ROOT/case-$N"
  mkdir -p "$C/fake/fsev" "$C/fake/docker" "$C/home/LaunchAgents" "$C/home/Logs" "$C/tmp"
  ln -s "$ROOT/tools/docker.sock" "$C/fake/docker/docker.sock"
  export FSG_FAKE="$C/fake"
  # The guard's temp files (and uninstall's sweep of them) stay in this case.
  export TMPDIR="$C/tmp"
  export FSG_STATE_DIR="$C/home/state/fseventsd-guard"
  export FSG_LOG="$C/home/Logs/fseventsd-guard.log"
  export FSG_AGENT_LOG="$C/home/Logs/fseventsd-guard.agent.log"
  export FSG_LAUNCH_AGENTS_DIR="$C/home/LaunchAgents"
  export FSG_PREFIX="$C/root"
  # The Claude Code hint's stamps; the hooks' environment comes from each case.
  export FSG_HINT_DIR="$C/home/Caches/fseventsd-guard-hint"
  unset FSG_HINT CLAUDE_PROJECT_DIR CLAUDE_PLUGIN_ROOT 2>/dev/null
  # Docker Desktop's socket for the guard: the default context's.
  export FSG_DESKTOP_SOCKET="$C/fake/docker/docker.sock"
  # Its backend socket (absent: gone) and settings (absent: default file sharing).
  export FSG_DESKTOP_BACKEND_SOCKET="$C/fake/docker/backend.sock" FSG_DESKTOP_SETTINGS="$C/fake/docker/settings-store.json"
  # The probe lives where install builds it; a fresh case starts with the stand-in.
  mkdir -p "$FSG_STATE_DIR/bin"; cp "$STUBS/fake-probe" "$FSG_STATE_DIR/bin/fsprobe"
  export FSG_TEST_HELPER_TOOLS="$TOOLS"
  # Install's root tools (sudo) come from here, never from PATH (lib/install.sh).
  export FSG_TEST_ROOT_TOOLS="$STUBS"
  export FSG_DRAIN_POLL_S=1 FSG_DRAIN_CAP_S=20 FSG_HEALTHY_TIMEOUT_S=6 FSG_CONTAINER_TIMEOUT_S=6
  export FSG_DOCKER_TIMEOUT_S=10 FSG_DOCKER_QUERY_TIMEOUT_S=2 FSG_PROBE_TIMEOUT_S=2 FSG_RUN_POLL_S=1
  # Unique command names: the real machine runs real rspec while this suite runs.
  export FSG_DETECT_COMMANDS="fsgtestrspec" FSG_DETECT_DOCKER_CLI=0 FSG_DETECT_DOCKER_EXECS=1 FSG_DETECT_DOCKER_CONTAINERS=1
  # The agent's ticks do not see this shell's environment (stubs/launchctl); its
  # knobs are these.
  : > "$FSG_FAKE/agent-env"
  agent_env FSG_DRAIN_POLL_S=1 FSG_DRAIN_CAP_S=20 FSG_HEALTHY_TIMEOUT_S=6 FSG_CONTAINER_TIMEOUT_S=6 \
    FSG_DOCKER_TIMEOUT_S=10 FSG_DOCKER_QUERY_TIMEOUT_S=2 FSG_PROBE_TIMEOUT_S=2 FSG_RUN_POLL_S=1 \
    FSG_DETECT_COMMANDS=fsgtestrspec FSG_DETECT_DOCKER_CLI=0 FSG_DETECT_DOCKER_EXECS=1 FSG_DETECT_DOCKER_CONTAINERS=1 \
    FSG_DESKTOP_SOCKET="$FSG_DESKTOP_SOCKET" FSG_DESKTOP_BACKEND_SOCKET="$FSG_DESKTOP_BACKEND_SOCKET" FSG_DESKTOP_SETTINGS="$FSG_DESKTOP_SETTINGS"
  unset FSG_AFFECTED FSG_AFFECTED_MIN FSG_AFFECTED_FIXED FSG_LEASE_FILE FSG_PROBE_BIN FSG_PROBE_DIR 2>/dev/null
  echo 4242 > "$FSG_FAKE/fsev/pids"
  echo 5000K > "$FSG_FAKE/fsev/4242.mem"
  : > "$FSG_FAKE/calls.log"
}
skip_case() { [ -n "$FILTER" ] && case $1 in *"$FILTER"*) return 1 ;; *) return 0 ;; esac; return 1; }
ok() { PASS=$((PASS + 1)); }
skip() { printf 'SKIP [%s] %s\n' "$CUR" "$*"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL [%s] %s\n' "$CUR" "$*"; }
eq() { [ "$1" = "$2" ] && ok || bad "${3:-}: expected '$2', got '$1'"; }
has() { printf '%s' "$1" | grep -qF -- "$2" && ok || bad "${3:-}: missing '$2' in: $(printf '%s' "$1" | head -c 400)"; }
hasnt() { printf '%s' "$1" | grep -qF -- "$2" && bad "${3:-}: unexpected '$2'" || ok; }
exists() { [ -e "$1" ] && ok || bad "${2:-}: missing $1"; }
absent() { [ -e "$1" ] && bad "${2:-}: still present $1" || ok; }
# before LOG A B: first line matching A comes before first line matching B.
before() {
  local a b
  a=$(grep -nF -- "$2" "$1" | head -n 1 | cut -d: -f1)
  b=$(grep -nF -- "$3" "$1" | head -n 1 | cut -d: -f1)
  if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then ok; else bad "order: '$2' (line ${a:-none}) before '$3' (line ${b:-none})"; fi
}
mem() { echo "$1" > "$FSG_FAKE/fsev/$(head -n 1 "$FSG_FAKE/fsev/pids").mem"; }
json_ok() {
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$1" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null && ok || bad "invalid JSON: $1"
  else ok; fi
}
# Test-only: evaluates the fixed d[...] expressions written in this file.
jget() { printf '%s' "$1" | python3 -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))" "$2" 2>/dev/null; }
containers() { printf '%s\n' "$@" > "$FSG_FAKE/docker/containers"; }
docker_default() {
  echo running > "$FSG_FAKE/docker/desktop"
  containers "c1 pg running healthy postgres:17 unless-stopped 0" "c2 redis running none redis:7 unless-stopped 0"
  echo "alpine:3" > "$FSG_FAKE/docker/images"
}
# live_containers: the running containers of a real engine (Docker CLI 29.9.2,
# 2026-10-23), with what the container record's and the engine-work listing's
# templates print for them (fixtures/docker-cli-29.9.2/record.txt and
# engine-work.txt: the probes' lines rendered from their captured inspect JSON, the
# compose services' re-encoded from the lines the previous templates printed for
# them in that run):
# fsg-probe-oneoff (a compose run), fsg-probe-anon (--rm -v /data),
# fsg-probe-named (--rm -v fsg-probe-vol:/data), fsg-probe-mount (--rm, --mount
# type=volume,dst=/m2 and a named --mount at /m3), and four compose services, one
# with a bind mount. The compose services' container, volume and bind-mount names
# are anonymized (app-*, /host_mnt/Users/dev/app); nothing else in the lines changed,
# except the health field the record's template gained later, null in every line as
# for the containers here (none has a health check).
live_containers() {
  local F=$ROOT/tools/fixtures/docker-cli-29.9.2
  awk -F'\t' '{ n = $2; sub(/^\//, "", n); print $1, n, "running none img:1 no 0", ($3 == "true" ? 1 : 0), ($4 == "\"True\"" ? 1 : 0) }' \
    "$F/record.txt" > "$FSG_FAKE/docker/containers"
  cp "$F/record.txt" "$FSG_FAKE/docker/inspect-real"
  cp "$F/engine-work.txt" "$FSG_FAKE/docker/inspect-real-work"
}
install_fake() { "$G" install --yes --prefix "$FSG_PREFIX" "$@" > "$C/install.out" 2>&1; }
# stub_dir DIR: DIR holds every stub, so a case can put a wrapper next to them and
# hand DIR to install as FSG_TEST_ROOT_TOOLS (install, uninstall and doctor ignore
# the caller's PATH).
stub_dir() { local f; mkdir -p "$1"; for f in "$STUBS"/*; do ln -sf "$f" "$1/"; done; }
# plant DIR NAME...: stand-ins that log "PLANTED name" and run the real tool.
plant() {
  local d=$1 n; shift; mkdir -p "$d"
  for n in "$@"; do
    printf '#!/bin/bash
echo "PLANTED %s $*" >> "$FSG_FAKE/calls.log"
for d in /usr/bin /bin /usr/sbin /sbin; do [ -x "$d/%s" ] && exec "$d/%s" "$@"; done
exit 127
' "$n" "$n" "$n" > "$d/$n"
    chmod +x "$d/$n"
  done
}
bg() { "$@" & BG_PIDS="$BG_PIDS $!"; LAST_BG=$!; }
# orphan CMD...: starts CMD outside this shell's children, so launchd reaps it and no
# zombie of it looks alive; prints its pid.
orphan() { /bin/sh -c '"$@" > /dev/null 2>&1 & echo $!' orphan "$@"; }
# waitfor SECONDS CMD...: 0 as soon as CMD succeeds (polled every 0.2 s).
waitfor() { local n=$(( $1 * 5 )); shift; while [ $n -gt 0 ]; do "$@" && return 0; sleep 0.2; n=$((n - 1)); done; return 1; }
# Kill and reap: an unreaped zombie still has a pid and a start time.
killbg() { kill "$1" 2>/dev/null; wait "$1" 2>/dev/null; }
# touch_ago SPEC FILE...: sets the files' mtime to now minus SPEC (date -v, as 20M or
# 2d), in UTC: local time is ambiguous in the hour a DST change repeats.
touch_ago() { local a; a=$(TZ=UTC0 date -v-"$1" +%Y%m%d%H%M.%S); shift; TZ=UTC0 touch -t "$a" "$@"; }
gone() { ! kill -0 "$1" 2>/dev/null; }
lstart() { LC_ALL=C TZ=UTC0 ps -o lstart= -p "$1" | tr -s ' ' | sed 's/^ //; s/ $//'; }
pending() { # owner-pid deadline-offset
  mkdir -p "$FSG_STATE_DIR/drain/leases"
  printf 'state_version=1\nowner_pid=%s\nowner_lstart=%s\nstarted_epoch=%s\ndeadline_epoch=%s\ntrigger=manual\nreason=test drain\nphase=draining\n' \
    "$1" "$(lstart "$1")" "$(date +%s)" $(( $(date +%s) + $2 )) > "$FSG_STATE_DIR/drain/pending"
}
# Leases are taken only while the guard is installed (its app copy exists).
app_copy() { mkdir -p "$FSG_STATE_DIR/app"; }
render_helper() { # out trial_until
  ( FSG_HOME=$GUARD_HOME
    . "$GUARD_HOME/lib/common.sh"; . "$GUARD_HOME/lib/install.sh"
    fsg_init_paths; fsg_load_config
    fsg_render_helper "$1" "$2" )
}
# root_steps WRAPDIR ARGS...: runs the root-steps text as the user, the way
# `sudo /bin/sh -c TEXT fsg-root ARGS` does, with SUDO_USER as sudo sets it
# ($RS_SUDO_USER when set). A non-empty WRAPDIR goes first on PATH, including on
# the PATH the root steps set for themselves (the only line changed).
root_steps() {
  local w=$1 text su
  shift
  su=${RS_SUDO_USER-$(id -un)}
  text=$(cat "$GUARD_HOME/lib/root-steps.sh")
  if [ -n "$w" ]; then
    text=$(printf '%s\n' "$text" | sed "s|^\( *\)PATH=/usr/bin:/bin:/usr/sbin:/sbin\$|\1PATH=$w:/usr/bin:/bin:/usr/sbin:/sbin|")
    SUDO_USER=$su PATH="$w:$PATH" /bin/sh -c "$text" fsg-root "$@"
  else
    SUDO_USER=$su /bin/sh -c "$text" fsg-root "$@"
  fi
}

# ======================================================================== status
if ! skip_case status; then
  t "status ok"
  out=$("$G" status --json); rc=$?
  eq $rc 0 "exit"; json_ok "$out"
  eq "$(jget "$out" 'd["level"]')" ok "level"
  eq "$(jget "$out" 'd["footprint_mb"]')" 4 "footprint_mb (5000K)"
  eq "$(jget "$out" 'd["schema"]')" "fseventsd-guard.status/1" "schema"
  eq "$(jget "$out" 'd["uptime_s"]')" 3723 "uptime from etime 01:02:03"
  eq "$(jget "$out" 'd["probe"]["ran"]')" False "probe not run by default"
  eq "$(jget "$out" 'd["os"]["affected"]')" True "affected on 27.0.1"

  t "status warn"
  mem 612M; out=$("$G" status --json); rc=$?
  eq $rc 1 "exit"; eq "$(jget "$out" 'd["level"]')" warn "level"
  has "$(jget "$out" 'd["reasons"][0]')" "warn threshold 500" "reason"

  t "status runaway"
  mem 3G; "$G" status >/dev/null; eq $? 2 "3G exit"
  mem 1.5G; "$G" status >/dev/null; eq $? 1 "1.5G = 1536 MB is warn"
  mem 17G; out=$("$G" status --json); eq "$(jget "$out" 'd["footprint_mb"]')" 17408 "17G in MB"
  mem 2048M; "$G" status >/dev/null; eq $? 2 "act threshold is inclusive"

  t "status cannot measure"
  : > "$FSG_FAKE/fsev/pids"; out=$("$G" status --json); rc=$?
  eq $rc 3 "no daemon"; json_ok "$out"; eq "$(jget "$out" 'd["level"]')" unknown "level"
  has "$(jget "$out" 'd["error"]')" "fseventsd process" "error"
  printf '4242\n4243\n' > "$FSG_FAKE/fsev/pids"; "$G" status >/dev/null; eq $? 3 "two daemons"
  echo 4242 > "$FSG_FAKE/fsev/pids"; mem garbage; "$G" status >/dev/null; eq $? 3 "unparseable top"
  mem 5000K; echo 5 > "$FSG_FAKE/top-delay"; s=$(date +%s)
  out=$(FSG_TOP_TIMEOUT_S=1 "$G" status --json); rc=$?
  eq $rc 3 "a top that does not answer"; has "$(jget "$out" 'd["error"]')" "top did not answer within 1s" "error"
  [ $(( $(date +%s) - s )) -lt 5 ] && ok || bad "top bounded: took $(( $(date +%s) - s )) s"

  t "status probe"
  echo stalled > "$FSG_FAKE/probe"; out=$("$G" status --json --probe); rc=$?
  eq $rc 2 "stalled probe is runaway"; eq "$(jget "$out" 'd["probe"]["result"]')" stalled "probe result"
  echo ok > "$FSG_FAKE/probe"; out=$("$G" status --json --probe)
  eq "$(jget "$out" 'd["probe"]["latency_ms"]')" 7 "latency"
  eq "$(jget "$out" 'd["probe"]["start_ms"]')" 0 "stream start time"
  FSG_STATUS_PROBE=1 "$G" status >/dev/null; eq $? 0 "probe via config"
  echo 7735 > "$FSG_FAKE/probe-start-ms"; out=$("$G" status --probe); eq $? 0 "a slow stream start is not a trigger"
  has "$out" "probe stream start: 7735 ms (a healthy fseventsd takes 0-1 ms" "status line"
  echo stalled > "$FSG_FAKE/probe"; out=$("$G" status --json --probe)
  eq "$(jget "$out" 'd["probe"]["start_ms"]')" 7735 "stream start time of a stalled probe"
  out=$("$G" status --json); eq "$(jget "$out" 'd["probe"]["start_ms"]')" None "null without a probe"
  printf '#!/bin/bash\necho "result=ok latency_ms=5"\n' > "$FSG_STATE_DIR/bin/fsprobe"
  echo ok > "$FSG_FAKE/probe"; out=$("$G" status --probe); eq $? 0 "a probe without start_ms still parses"
  has "$out" "delivery probe: ok (5 ms)" "latency from the old format"; hasnt "$out" "stream start" "no start line"

  t "status thresholds precedence"
  mem 300M
  "$G" status >/dev/null; eq $? 0 "300M default ok"
  FSG_WARN_MB=200 "$G" status >/dev/null; eq $? 1 "env warn 200"
  mkdir -p "$FSG_STATE_DIR"; echo "FSG_WARN_MB=250" > "$FSG_STATE_DIR/config"
  "$G" status >/dev/null; eq $? 1 "user config warn 250"
  FSG_WARN_MB=400 "$G" status >/dev/null; eq $? 0 "env beats user config"

  t "affected versions: a range"
  for v in 15.6.1 15.6.2 15.7.9 15.10 26.0 26.4.1 27.0 27.0.0 27.0.1 27.2 28.0; do
    echo "$v" > "$FSG_FAKE/sw_vers"; "$G" doctor --affected >/dev/null; eq $? 0 "$v affected (in the range)"
  done
  for v in 14.7 15.1.9 15.5 15.6 15.6.0; do
    echo "$v" > "$FSG_FAKE/sw_vers"; "$G" doctor --affected >/dev/null; eq $? 1 "$v not affected (before 15.6.1)"
  done
  out=$("$G" doctor --affected); has "$out" "macOS 15.6.0 is older than 15.6.1" "message names the version and the start"
  echo 27.0.1 > "$FSG_FAKE/sw_vers"; out=$("$G" doctor --affected); has "$out" "from 15.6.1, no fix known for 27.x" "message: no fix known"
  export FSG_AFFECTED_FIXED="26.8 27.1"
  for v in 15.7.9 26.7.9 27.0.1 28.0; do
    echo "$v" > "$FSG_FAKE/sw_vers"; "$G" doctor --affected >/dev/null; eq $? 0 "$v affected (before its line's fix, or no fix for the line)"
  done
  for v in 26.8 26.8.0 26.10 27.1 27.1.1 27.2; do
    echo "$v" > "$FSG_FAKE/sw_vers"; "$G" doctor --affected >/dev/null; eq $? 1 "$v not affected (fixed in its line)"
  done
  echo 26.10 > "$FSG_FAKE/sw_vers"; out=$("$G" doctor --affected); has "$out" "macOS 26.10 has the fix (fixed in 26.8)" "message names the fix"
  echo 26.7.9 > "$FSG_FAKE/sw_vers"; out=$("$G" doctor --affected); has "$out" "from 15.6.1, fixed in 26.8" "message names the line's fix"
  unset FSG_AFFECTED_FIXED
  mkdir -p "$FSG_STATE_DIR"; echo "FSG_AFFECTED_MIN=26.0" > "$FSG_STATE_DIR/config"
  echo 15.7.9 > "$FSG_FAKE/sw_vers"; "$G" doctor --affected >/dev/null; eq $? 1 "the start from the user config"
  : > "$FSG_STATE_DIR/config"
  echo 15.5 > "$FSG_FAKE/sw_vers"
  FSG_AFFECTED=yes "$G" doctor --affected >/dev/null; eq $? 0 "forced yes"
  echo 27.0.1 > "$FSG_FAKE/sw_vers"
  FSG_AFFECTED=no "$G" doctor --affected >/dev/null; eq $? 1 "forced no"
  echo 26.8 > "$FSG_FAKE/sw_vers"
  FSG_AFFECTED_FIXED=26.8 FSG_AFFECTED=yes "$G" doctor --affected >/dev/null; eq $? 0 "forced yes beats a fix"
  echo 28.0 > "$FSG_FAKE/sw_vers"
  out=$("$G" status --json); eq "$(jget "$out" 'd["os"]["version"]')" 28.0 "version in JSON"
  eq "$(jget "$out" 'd["os"]["affected"]')" True "a newer major line without a fix is affected"
fi

# ======================================================================== config-check
if ! skip_case config-check; then
  t "a non-numeric threshold falls back to its default"
  mkdir -p "$FSG_STATE_DIR"; echo "FSG_ACT_MB=2G" > "$FSG_STATE_DIR/config"
  mem 17G; out=$("$G" status --json 2> "$C/err"); rc=$?
  eq $rc 2 "17 GB is runaway with the default act threshold"
  eq "$(jget "$out" 'd["thresholds"]["act_mb"]')" 2048 "default used"
  has "$(cat "$C/err")" "FSG_ACT_MB='2G'" "stderr names the key and value"
  has "$(cat "$FSG_LOG")" "CONFIG FSG_ACT_MB='2G' from $FSG_STATE_DIR/config is not a whole number; using the default 2048" "logged"
  docker_default; install_fake --no-agent
  "$G" doctor --prefix "$FSG_PREFIX" > "$C/doc.out" 2>/dev/null; eq $? 2 "doctor fails"
  has "$(cat "$C/doc.out")" "FAIL  config: FSG_ACT_MB='2G' ($FSG_STATE_DIR/config) is not a whole number" "doctor names key and value"

  t "numeric config: environment, leading zeros, empty"
  FSG_DRAIN_POLL_S=abc "$G" doctor --prefix "$FSG_PREFIX" > "$C/doc.out" 2>/dev/null
  has "$(cat "$C/doc.out")" "FSG_DRAIN_POLL_S='abc' (environment)" "environment named as the source"
  mem 300M; FSG_WARN_MB=08 "$G" status >/dev/null 2>&1; eq $? 0 "leading zero rejected (default 500, not 8)"
  FSG_WARN_MB= "$G" status >/dev/null 2>"$C/err"; eq $? 0 "empty value: default 500"
  has "$(cat "$C/err")" "FSG_WARN_MB=''" "empty value reported"
  FSG_WARN_MB=200 "$G" status >/dev/null 2>"$C/err"; eq $? 1 "a valid value is kept"
  eq "$(cat "$C/err")" "" "nothing reported for valid values"
  FSG_TRIAL_MIN_MB=0 "$G" status >/dev/null 2>"$C/err"; eq "$(cat "$C/err")" "" "0 is valid"

  t "the user config is parsed, never run as shell"
  mkdir -p "$FSG_STATE_DIR"
  cat > "$FSG_STATE_DIR/config" <<EOF
FSG_WARN_MB=250   # a comment after a value
FSG_DOCKER_VARIANT="A"
FSG_CAP_POLICY_MANUAL=\$(touch $C/pwned1)
fsg_source_gate() { FSG_ROOT_TEXT='echo planted-root-text'; FSG_HELPER_TEXT=x; FSG_GATE_NOTE='reviewed: commit fake'; }
touch $C/pwned2
FSG_NOT_A_SETTING=1
FSG_STOP_TIMEOUT_S="30s"
EOF
  mem 300M; "$G" status >/dev/null 2>"$C/err"; eq $? 1 "a valid line applies (warn at 250)"
  absent "$C/pwned1" "a command substitution in a value did not run"
  absent "$C/pwned2" "a command line did not run"
  has "$(cat "$C/err")" "ignored line 3 of" "the unsafe value is ignored"
  has "$(cat "$C/err")" "ignored line 6 of" "an unknown key is ignored"
  has "$(cat "$C/err")" "FSG_STOP_TIMEOUT_S='30s'" "a non-numeric value for a number is rejected"
  has "$(cat "$FSG_LOG")" "CONFIG ignored line 4 of" "the function line is logged"
  docker_default; install_fake --no-agent; eq $? 0 "install"
  rs=$(git -C "$REPO" show "HEAD:plugins/fseventsd-guard/lib/root-steps.sh" | shasum -a 256 | awk '{print $1}')
  hasnt "$(cat "$C/install.out")" "root code: reviewed: commit fake" "the planted gate did not replace the real one"
  has "$(cat "$C/install.out")" "root code: reviewed: commit $(tgit rev-parse HEAD)" "the real gate ran"
  has "$(cat "$C/install.out")" "root-steps text sha256: $rs" "the reviewed root text ran"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "planted-root-text" "the planted root text never reached sudo"
  "$G" doctor --prefix "$FSG_PREFIX" > "$C/doc.out" 2>/dev/null; eq $? 2 "doctor fails (the non-numeric value)"
  has "$(cat "$C/doc.out")" "WARN  config: line 4 of $FSG_STATE_DIR/config is ignored" "doctor warns about ignored lines"
  has "$(cat "$C/doc.out")" "FAIL  config: FSG_STOP_TIMEOUT_S='30s'" "and fails the bad number"
  echo '# planted' >> "$GUARD_HOME/lib/root-steps.sh"
  install_fake --no-agent; eq $? 1 "an edited root-steps.sh is still refused with the planted gate"
  tgit checkout -q -- plugins/fseventsd-guard/lib/root-steps.sh
fi

# ======================================================================== helper
if ! skip_case helper; then
  t "helper refusals and restart"
  H="$C/helper"; render_helper "$H" 0; chmod +x "$H"
  EV="$FSG_PREFIX/Library/Logs/fseventsd-guard"
  /bin/sh -n "$H"; eq $? 0 "rendered helper parses"
  grep -q "^TOOLS=$TOOLS\$" "$H" && ok || bad "TOOLS rendered"
  /bin/sh "$H" extra 2>/dev/null; eq $? 64 "argument refused"
  /bin/sh "$H" "" 2>/dev/null; eq $? 64 "empty argument refused"
  echo 501 > "$FSG_FAKE/id-u"; /bin/sh "$H" 2>/dev/null; eq $? 77 "not root"; rm -f "$FSG_FAKE/id-u"
  mem 50M; /bin/sh "$H" 2>/dev/null; eq $? 65 "healthy refused"
  mem 3G; echo 501 > "$FSG_FAKE/fsev/4242.uid"; /bin/sh "$H" 2>/dev/null; eq $? 69 "non-root daemon"
  rm "$FSG_FAKE/fsev/4242.uid"; echo /tmp/fseventsd > "$FSG_FAKE/fsev/4242.comm"; /bin/sh "$H" 2>/dev/null; eq $? 69 "wrong binary path"
  rm "$FSG_FAKE/fsev/4242.comm"; echo 77 > "$FSG_FAKE/fsev/4242.ppid"; /bin/sh "$H" 2>/dev/null; eq $? 69 "not a launchd child"
  rm "$FSG_FAKE/fsev/4242.ppid"; printf '4242\n4243\n' > "$FSG_FAKE/fsev/pids"; /bin/sh "$H" 2>/dev/null; eq $? 69 "two daemons"
  echo 4242 > "$FSG_FAKE/fsev/pids"; mem "??"; /bin/sh "$H" 2>/dev/null; eq $? 70 "cannot measure"
  mkdir -p "$EV/.lock"; mem 3G; /bin/sh "$H" 2>/dev/null; eq $? 75 "fresh lock"; rmdir "$EV/.lock"
  : > "$FSG_FAKE/calls.log"
  out=$(/bin/sh "$H"); rc=$?
  eq $rc 0 "restart"; has "$out" "restarted old=4242 new=4243" "output"
  has "$(cat "$FSG_FAKE/calls.log")" "kill -TERM 4242" "SIGTERM sent to the genuine pid"
  exists "$EV/last-restart" "rate-limit stamp"
  ls "$EV"/restart-*.txt >/dev/null 2>&1 && ok || bad "evidence record"
  # Footprint is bounded at 10 s; under heavy load the stand-in may hit the bound.
  grep -qE 'fake footprint|footprint timed out' "$EV"/restart-*.txt && ok || bad "footprint section in evidence"
  has "$(cat "$EV"/restart-*.txt)" "--- history dir" "history dir counted, not copied"
  mem 3G; /bin/sh "$H" 2>/dev/null; eq $? 66 "rate limited"
  n=$(grep -c REFUSED "$EV/helper.log"); [ "$n" -ge 10 ] && ok || bad "every refusal logged ($n)"
  has "$(cat "$EV/helper.log")" "REFUSED code=64" "argument refusal logged"
  rm -f "$EV/last-restart"; touch "$FSG_FAKE/no-respawn"; /bin/sh "$H" 2> "$C/err"; eq $? 73 "no respawn"
  has "$(cat "$C/err")" "sent SIGTERM to 4243, but no new fseventsd appeared" "says so"
  rm -f "$FSG_FAKE/no-respawn"; echo 4242 > "$FSG_FAKE/fsev/pids"; mem 3G; rm -f "$EV/last-restart"
  touch "$FSG_FAKE/ignore-term"; : > "$FSG_FAKE/calls.log"
  out=$(/bin/sh "$H"); eq $? 72 "SIGTERM ignored: restarted with SIGKILL"
  has "$out" "restarted old=4242 new=4243" "new pid"; has "$out" "signal=KILL" "output names the signal"
  before "$FSG_FAKE/calls.log" "kill -TERM 4242" "kill -KILL 4242"
  has "$(cat "$EV/helper.log")" "KILL pid=4242 still running 10s after SIGTERM" "logged"
  echo 4242 > "$FSG_FAKE/fsev/pids"; mem 3G; rm -f "$EV/last-restart"; touch "$FSG_FAKE/no-respawn"
  /bin/sh "$H" 2> "$C/err"; eq $? 73 "SIGKILL and no respawn"
  has "$(cat "$C/err")" "sent SIGKILL to 4242, but no new fseventsd appeared" "says so"
  rm -f "$FSG_FAKE/ignore-term" "$FSG_FAKE/no-respawn"; echo 4242 > "$FSG_FAKE/fsev/pids"; mem 3G; rm -f "$EV/last-restart"
  touch "$FSG_FAKE/kill-fail"; /bin/sh "$H" 2>/dev/null; eq $? 71 "kill failed"; rm -f "$FSG_FAKE/kill-fail"

  t "helper bounds top, find and du"
  H="$C/helper"; render_helper "$C/h0" 0
  sed -e 's/^TOP_LIMIT_S=.*/TOP_LIMIT_S=1/' -e 's/^SCAN_LIMIT_S=.*/SCAN_LIMIT_S=1/' "$C/h0" > "$H"
  EV="$FSG_PREFIX/Library/Logs/fseventsd-guard"
  mkdir -p "$FSG_PREFIX/.fseventsd"; touch "$FSG_PREFIX/.fseventsd/a" "$FSG_PREFIX/.fseventsd/b" "$FSG_PREFIX/.fseventsd/c"
  mem 3G; /bin/sh "$C/h0" >/dev/null 2>&1; eq $? 0 "restart"
  rec=$(cat "$EV"/restart-*.txt)
  has "$rec" "files=3" "history files counted"; printf '%s' "$rec" | grep -q '^size_kb=[0-9][0-9]*$' && ok || bad "history size: $rec"
  has "$rec" "--- top (15 s limit)" "top bounded"; has "$rec" "PID MEM CMPRS PORTS" "top's columns"
  ls -A "$EV" | grep -q '^\.out' && bad "the output file is left behind" || ok
  rm -f "$EV"/restart-*.txt "$EV/last-restart"; echo 4242 > "$FSG_FAKE/fsev/pids"; mem 3G
  echo 5 > "$FSG_FAKE/find-delay"; echo 5 > "$FSG_FAKE/du-delay"; s=$(date +%s)
  /bin/sh "$H" >/dev/null 2>&1; eq $? 0 "a hung scan does not stop the restart"
  [ $(( $(date +%s) - s )) -lt 8 ] && ok || bad "scans bounded: took $(( $(date +%s) - s )) s"
  rec=$(cat "$EV"/restart-*.txt)
  has "$rec" "files=(find timed out)" "find bounded"; has "$rec" "size_kb=(du timed out)" "du bounded"
  rm -f "$FSG_FAKE/find-delay" "$FSG_FAKE/du-delay" "$EV/last-restart"; echo 4242 > "$FSG_FAKE/fsev/pids"; mem 3G
  echo 5 > "$FSG_FAKE/top-delay"; s=$(date +%s)
  /bin/sh "$H" 2> "$C/err"; eq $? 70 "a hung top: cannot measure"
  [ $(( $(date +%s) - s )) -lt 4 ] && ok || bad "top bounded: took $(( $(date +%s) - s )) s"
  rm -f "$FSG_FAKE/top-delay"

  t "helper trial window"
  H="$C/helper"; render_helper "$H" $(( $(date +%s) + 3600 ))
  mem 5000K; out=$(/bin/sh "$H"); eq $? 0 "trial: healthy daemon restarted"; has "$out" "mode=trial" "mode"
  echo 4242 > "$FSG_FAKE/fsev/pids"; mem 5000K
  /bin/sh "$H" >/dev/null 2>&1; eq $? 66 "trial interval 120 s still applies"
  render_helper "$H" $(( $(date +%s) - 10 )); rm -f "$FSG_PREFIX/Library/Logs/fseventsd-guard/last-restart"
  /bin/sh "$H" 2>/dev/null; eq $? 65 "expired window: normal floor again"
  render_helper "$H" $(( $(date +%s) + 2 * 86400 ))
  /bin/sh "$H" 2>/dev/null; eq $? 65 "a window more than 24 h ahead is ignored: normal floor"
  has "$(cat "$FSG_PREFIX/Library/Logs/fseventsd-guard/helper.log")" "more than 86400 s ahead; ignored" "logged"

  t "helper raises settings below its minimums"
  H="$C/helper"; render_helper "$C/h0" 0
  sed -e 's/^MIN_MB=.*/MIN_MB=0/' -e 's/^MIN_INTERVAL_S=.*/MIN_INTERVAL_S=0/' "$C/h0" > "$H"
  mem 50M; /bin/sh "$H" 2> "$C/err"; eq $? 65 "floor 0 outside a trial: a healthy daemon is still refused"
  has "$(cat "$C/err")" "below the 150 MB floor" "at the 150 MB floor"
  mem 3G; /bin/sh "$H" >/dev/null 2>&1; eq $? 0 "a runaway is restarted"
  echo 4242 > "$FSG_FAKE/fsev/pids"; mem 3G
  /bin/sh "$H" 2> "$C/err"; eq $? 66 "interval 0 outside a trial: still rate limited"
  has "$(cat "$C/err")" "the minimum interval is 1800 s" "at 1800 s"
  mv "$FSG_PREFIX/Library/Logs/fseventsd-guard/last-restart" "$C/last-restart.old"
  render_helper "$C/h0" $(( $(date +%s) + 3600 ))
  sed 's/^TRIAL_MIN_INTERVAL_S=.*/TRIAL_MIN_INTERVAL_S=0/' "$C/h0" > "$H"
  mem 5000K; /bin/sh "$H" >/dev/null 2>&1; eq $? 0 "trial: restarted"
  echo 4242 > "$FSG_FAKE/fsev/pids"; mem 5000K
  /bin/sh "$H" 2> "$C/err"; eq $? 66 "trial interval 0: still once per 120 s"
  has "$(cat "$C/err")" "the minimum interval is 120 s (trial)" "at 120 s"
fi

# ======================================================================== install
if ! skip_case install; then
  t "install, doctor, uninstall in a fake root"
  install_fake; rc=$?
  eq $rc 0 "install exit"; out=$(cat "$C/install.out")
  has "$out" "visudo -cf: parsed OK" "staged drop-in validated"
  HP="$FSG_PREFIX/usr/local/libexec/fseventsd-guard-restart"; SP="$FSG_PREFIX/etc/sudoers.d/fseventsd-guard"
  RS="$FSG_PREFIX/usr/local/libexec/fseventsd-guard-root-steps"
  eq "$(stat -f %Lp "$HP")" 755 "helper mode"
  eq "$(stat -f %Lp "$SP")" 440 "drop-in mode"
  eq "$(stat -f %Lp "$RS")" 755 "root-steps copy mode"
  rs=$(printf '%s\n' "$(cat "$GUARD_HOME/lib/root-steps.sh")" | shasum -a 256 | awk '{print $1}')
  eq "$(shasum -a 256 < "$RS" | awk '{print $1}')" "$rs" "the copy is the root-steps text that ran"
  has "$out" "root-steps copy: $RS (the text above, sha256 $rs" "install names the copy and its hash"
  has "$(cat "$FSG_PREFIX/Library/Logs/fseventsd-guard/install-manifest")" "file=$RS" "the manifest lists it"
  eq "$(grep -v '^#' "$SP")" "$(id -un) ALL=(root) NOPASSWD: $HP \"\"" "drop-in names exactly the helper, no arguments"
  visudo -cf "$SP" >/dev/null; eq $? 0 "installed drop-in passes visudo -cf without root"
  exists "$FSG_PREFIX/Library/Logs/fseventsd-guard/install-manifest" "manifest"
  exists "$FSG_LAUNCH_AGENTS_DIR/io.github.ruslantar.fseventsd-guard.plist" "plist"
  plutil -lint "$FSG_LAUNCH_AGENTS_DIR/io.github.ruslantar.fseventsd-guard.plist" >/dev/null; eq $? 0 "plist lint"
  has "$(cat "$FSG_LAUNCH_AGENTS_DIR/io.github.ruslantar.fseventsd-guard.plist")" "$FSG_STATE_DIR/app/fseventsd-guard" "agent runs the app copy"
  PL="$FSG_LAUNCH_AGENTS_DIR/io.github.ruslantar.fseventsd-guard.plist"
  eq "$(plutil -extract ProgramArguments.0 raw -o - "$PL")" "$FSG_STATE_DIR/app/fseventsd-guard" "launchd runs the guard script itself, not /bin/bash"
  eq "$(plutil -extract ProgramArguments.1 raw -o - "$PL")" tick "tick argument"
  eq "$(plutil -extract EnvironmentVariables.FSG_LOG raw -o - "$PL")" "$FSG_LOG" "the plist names the user log, for uninstall to read back"
  plutil -extract ProgramArguments.2 raw -o - "$PL" >/dev/null 2>&1 && bad "no third argument" || ok
  [ -x "$FSG_STATE_DIR/app/fseventsd-guard" ] && ok || bad "app script executable"
  eq "$(head -n 1 "$FSG_STATE_DIR/app/fseventsd-guard")" '#!/bin/bash' "app script shebang"
  has "$(cat "$FSG_FAKE/calls.log")" "launchctl bootstrap gui/" "agent loaded"
  n=$(grep -c '^sudo -k /bin/sh -c' "$FSG_FAKE/calls.log"); eq "$n" 1 "exactly one sudo call, with -k (no cached ticket used or left)"
  eq "$(grep -c '^sudo /bin/sh' "$FSG_FAKE/calls.log")" 0 "no sudo call without -k"
  exists "$FSG_STATE_DIR/app/lib/lease.sh" "app copy"
  has "$(cat "$FSG_FAKE/calls.log")" "swiftc -O -o $FSG_STATE_DIR/bin/fsprobe.new" "probe built with swiftc"
  grep -q '^# FSG_WARN_MB=' "$FSG_STATE_DIR/config" && ok || bad "commented user config"
  has "$out" "doctor: all checks passed" "doctor after install"
  "$G" doctor --prefix "$FSG_PREFIX" >/dev/null; eq $? 0 "doctor clean"

  chmod 775 "$HP"; "$G" doctor --prefix "$FSG_PREFIX" > "$C/doc.out"; eq $? 2 "doctor fails on a group-writable helper"
  has "$(cat "$C/doc.out")" "FAIL  helper" "message"; chmod 755 "$HP"
  chmod 777 "$(dirname "$HP")"; "$G" doctor --prefix "$FSG_PREFIX" >/dev/null; eq $? 2 "doctor fails on a writable helper dir"
  chmod 755 "$(dirname "$HP")"
  has "$("$G" doctor --prefix "$FSG_PREFIX")" "ok    root-steps copy $RS is owned by uid $(id -u), mode 0755, no ACL" "doctor checks the root-steps copy"
  chmod 775 "$RS"; "$G" doctor --prefix "$FSG_PREFIX" > "$C/doc.out"; eq $? 2 "doctor fails on a group-writable root-steps copy"
  has "$(cat "$C/doc.out")" "FAIL  root-steps copy $RS has owner uid $(id -u), mode 775" "message"; chmod 755 "$RS"
  mv "$RS" "$C/rs.was"; "$G" doctor --prefix "$FSG_PREFIX" > "$C/doc.out"; eq $? 1 "doctor warns on a missing root-steps copy"
  has "$(cat "$C/doc.out")" "WARN  root-steps copy $RS is missing" "message"; mv "$C/rs.was" "$RS"
  echo 1 > "$FSG_FAKE/sudo-l-rc"; "$G" doctor --prefix "$FSG_PREFIX" >/dev/null; eq $? 2 "doctor fails when sudo -l refuses"
  rm "$FSG_FAKE/sudo-l-rc"
  FSG_HELPER_MIN_MB=300 "$G" doctor --prefix "$FSG_PREFIX" > "$C/doc.out"; eq $? 1 "doctor warns on config drift"
  has "$(cat "$C/doc.out")" "differs from this checkout" "drift message"
  rm -f "$FSG_FAKE/launchctl-loaded"; "$G" doctor --prefix "$FSG_PREFIX" >/dev/null; eq $? 2 "doctor fails when the agent is not loaded"
  touch "$FSG_FAKE/launchctl-loaded"

  : > "$FSG_FAKE/calls.log"
  "$G" uninstall --yes --prefix "$FSG_PREFIX" > "$C/un.out" 2>&1; rc=$?
  eq $rc 0 "uninstall exit"; has "$(cat "$C/un.out")" "no traces left" "uninstall message"
  n=$(grep -c '^sudo -k /bin/sh ' "$FSG_FAKE/calls.log"); eq "$n" 1 "uninstall: one sudo call, with -k"
  has "$(cat "$FSG_FAKE/calls.log")" "sudo -k /bin/sh $RS uninstall" "it runs the root-owned root-steps copy"
  absent "$HP" "helper"; absent "$SP" "drop-in"; absent "$RS" "root-steps copy"; absent "$FSG_PREFIX/Library/Logs/fseventsd-guard" "root logs"
  absent "$FSG_PREFIX/usr/local/libexec" "created helper dir"
  absent "$FSG_LAUNCH_AGENTS_DIR/io.github.ruslantar.fseventsd-guard.plist" "plist"
  absent "$FSG_STATE_DIR" "state dir"; absent "$FSG_LOG" "user log"
  has "$(cat "$FSG_FAKE/calls.log")" "launchctl bootout gui/" "agent unloaded"
  exists "$FSG_PREFIX/etc/sudoers.d" "sudoers.d itself is left alone"

  t "agent plist runs the script; a non-executable copy stops the install"
  install_fake; eq $? 0 "install"
  PL="$FSG_LAUNCH_AGENTS_DIR/io.github.ruslantar.fseventsd-guard.plist"
  plutil -insert ProgramArguments.0 -string /bin/bash "$PL"
  "$G" doctor --prefix "$FSG_PREFIX" > "$C/doc.out" 2>&1; eq $? 1 "doctor warns on a plist that runs /bin/bash"
  has "$(cat "$C/doc.out")" "agent plist runs '/bin/bash'" "doctor names the program"
  has "$(cat "$C/doc.out")" "Background Items shows it as 'bash'" "doctor says how it shows"
  stub_dir "$C/wrap"
  printf '#!/bin/bash\ncase "$*" in *app.new/fseventsd-guard) exec /bin/chmod 0644 "${@: -1}" ;; esac\nexec /bin/chmod "$@"\n' > "$C/wrap/chmod"
  /bin/chmod 755 "$C/wrap/chmod"
  FSG_TEST_ROOT_TOOLS="$C/wrap" install_fake; eq $? 1 "install stops when the copied script is not executable"
  has "$(cat "$C/install.out")" "not an executable #!/bin/bash script" "message"
  [ -x "$FSG_STATE_DIR/app/fseventsd-guard" ] && ok || bad "the previous app copy stays in place"
  absent "$FSG_STATE_DIR/app.new" "staged copy removed"
  install_fake; eq $? 0 "install again"
  "$G" doctor --prefix "$FSG_PREFIX" >/dev/null 2>&1; eq $? 0 "doctor clean after reinstall"

  t "another launch agent that runs the app copy stops install and fails doctor"
  install_fake; eq $? 0 "install"
  PL="$FSG_LAUNCH_AGENTS_DIR/io.github.ruslantar.fseventsd-guard.plist"
  OLD="$FSG_LAUNCH_AGENTS_DIR/com.example.old-guard.plist"
  cp "$PL" "$OLD"; plutil -replace Label -string com.example.old-guard "$OLD"; plutil -convert binary1 "$OLD"
  fix="launchctl bootout gui/$(id -u)/com.example.old-guard; rm \"$OLD\""
  "$G" doctor --prefix "$FSG_PREFIX" > "$C/doc.out" 2>&1; eq $? 2 "doctor fails"
  has "$(cat "$C/doc.out")" "FAIL  agent plist $OLD (label com.example.old-guard) also runs $FSG_STATE_DIR/app/fseventsd-guard, so two agents heal: run that install's own uninstall first" "doctor names the plist and its label"
  has "$(cat "$C/doc.out")" "$fix" "doctor gives the fix"
  hasnt "$(cat "$C/doc.out")" "another fseventsd launch agent" "not listed again as an older watcher"
  echo "# app copy before" >> "$FSG_STATE_DIR/app/config.defaults"
  : > "$FSG_FAKE/calls.log"
  install_fake; eq $? 1 "install refuses"
  has "$(cat "$C/install.out")" "install: $OLD (label com.example.old-guard) also runs $FSG_STATE_DIR/app/fseventsd-guard" "install names the plist"
  has "$(cat "$C/install.out")" "$fix" "install gives the fix"
  has "$(cat "$C/install.out")" "nothing was changed" "install says nothing changed"
  hasnt "$(cat "$C/install.out")" "[1/5]" "it stops before the first step"
  has "$(tail -n 1 "$FSG_STATE_DIR/app/config.defaults")" "# app copy before" "the app copy is not replaced"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "sudo" "no root steps"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "launchctl" "no launchctl call"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "swiftc" "no probe build"
  plutil -insert ProgramArguments.0 -string /bin/bash "$OLD"
  install_fake; eq $? 1 "also when it runs the app copy through /bin/bash"
  mv "$OLD" "$C/old.plist"
  W="$FSG_LAUNCH_AGENTS_DIR/com.example.watcher.plist"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>Label</key><string>com.example.watcher</string><key>ProgramArguments</key><array><string>/bin/sh</string><string>-c</string><string>pgrep fseventsd</string></array></dict></plist>\n' > "$W"
  install_fake; eq $? 0 "a watcher that does not run the app copy does not stop install"
  "$G" doctor --prefix "$FSG_PREFIX" > "$C/doc.out" 2>&1; eq $? 0 "doctor passes"
  has "$(cat "$C/doc.out")" "info  another fseventsd launch agent is installed: $W " "doctor lists the watcher"

  t "install, uninstall and doctor ignore tools planted on the caller's PATH"
  plant "$C/plant" awk sed id shasum git sudo visudo cat tr grep mktemp
  docker_default
  PATH="$C/plant:$PATH" install_fake; eq $? 0 "install"
  HP="$FSG_PREFIX/usr/local/libexec/fseventsd-guard-restart"
  render_helper "$C/want" 0; cmp -s "$C/want" "$HP" && ok || bad "the installed helper is the one rendered without the planted tools"
  eq "$(plutil -extract EnvironmentVariables.PATH raw -o - "$FSG_LAUNCH_AGENTS_DIR/io.github.ruslantar.fseventsd-guard.plist")" \
    "$STUBS:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" "the agent's PATH still starts with the caller's Docker CLI dir"
  PATH="$C/plant:$PATH" "$G" doctor --prefix "$FSG_PREFIX" > "$C/doc.out" 2>&1; eq $? 0 "doctor"
  PATH="$C/plant:$PATH" "$G" uninstall --yes --prefix "$FSG_PREFIX" > "$C/un.out" 2>&1; eq $? 0 "uninstall"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "PLANTED" "no planted tool ran"

  t "install refuses helper settings below the minimums and names the ones that differ"
  for kv in FSG_HELPER_MIN_MB=149 FSG_HELPER_MIN_INTERVAL_S=1799 FSG_TRIAL_MIN_INTERVAL_S=119; do
    env "$kv" "$G" install --yes --prefix "$FSG_PREFIX" --no-agent > "$C/install.out" 2>&1; eq $? 64 "$kv refused"
    has "$(cat "$C/install.out")" "$kv is below" "message names $kv"
  done
  mkdir -p "$FSG_STATE_DIR"; echo "FSG_HELPER_MIN_INTERVAL_S=0" > "$FSG_STATE_DIR/config"
  install_fake --no-agent; eq $? 64 "the same from the user config"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "sudo" "no sudo call"
  absent "$FSG_STATE_DIR/app" "refused before anything changed"
  echo "FSG_HELPER_MIN_MB=300" > "$FSG_STATE_DIR/config"
  FSG_TRIAL_MIN_MB=10 install_fake --no-agent; eq $? 0 "higher values install"
  out=$(cat "$C/install.out")
  has "$out" "WARNING: helper setting FSG_HELPER_MIN_MB=300 differs from config.defaults (150)" "the floor named"
  has "$out" "WARNING: helper setting FSG_TRIAL_MIN_MB=10 differs from config.defaults (0)" "the trial floor named on a line of its own"
  hasnt "$out" "FSG_HELPER_MIN_INTERVAL_S=1800 differs" "an unchanged setting is not named"
  before "$C/install.out" "WARNING: helper setting" "root steps done"
  echo "FSG_HELPER_MIN_MB=0" > "$FSG_STATE_DIR/config"
  "$G" doctor --prefix "$FSG_PREFIX" > "$C/doc.out" 2>&1; eq $? 2 "doctor fails a config install would refuse"
  has "$(cat "$C/doc.out")" "FAIL  this config cannot be rendered into a helper, so install refuses it: FSG_HELPER_MIN_MB=0 is below 150" "doctor names it"

  t "install guards"
  echo 15.5 > "$FSG_FAKE/sw_vers"; install_fake; eq $? 1 "refuses on a version before the affected range"
  has "$(cat "$C/install.out")" "not needed here" "message"
  absent "$FSG_PREFIX/usr/local/libexec/fseventsd-guard-restart" "nothing installed"
  install_fake --force --no-agent; eq $? 0 "--force installs anyway"
  install_fake --no-agent; eq $? 0 "an existing install updates without --force"
  has "$(cat "$C/install.out")" "updating the existing install" "update note"
  out=$("$G" doctor --prefix "$FSG_PREFIX")
  has "$out" "this version is outside the affected range" "doctor on a version outside the range"
  hasnt "$out" "uninstall" "doctor does not advise uninstalling"
  echo 27.0.1 > "$FSG_FAKE/sw_vers"
  "$G" install --prefix "relative/dir" > /dev/null 2>&1; eq $? 64 "relative prefix refused"
  printf 'nobody ALL=(root) NOPASSWD /x\n' > "$C/broken"; visudo -cf "$C/broken" >/dev/null 2>&1; eq $? 1 "visudo -cf rejects a broken drop-in without root"

  t "uninstall keep-logs and trial install"
  install_fake --trial-hours 2; eq $? 0 "install with trial window"
  tu=$(sed -n 's/^TRIAL_UNTIL=//p' "$FSG_PREFIX/usr/local/libexec/fseventsd-guard-restart")
  [ "$tu" -gt "$(date +%s)" ] && ok || bad "TRIAL_UNTIL in the future ($tu)"
  has "$("$G" doctor --prefix "$FSG_PREFIX")" "trial window open" "doctor shows the window"
  "$G" uninstall --yes --prefix "$FSG_PREFIX" --keep-logs >/dev/null 2>&1; eq $? 0 "uninstall --keep-logs"
  exists "$FSG_PREFIX/Library/Logs/fseventsd-guard" "root log dir kept"
  absent "$FSG_PREFIX/usr/local/libexec/fseventsd-guard-restart" "helper removed"
  exists "$FSG_LOG" "user log kept"

  t "install and uninstall ask before running as root"
  HP="$FSG_PREFIX/usr/local/libexec/fseventsd-guard-restart"
  "$G" install --prefix "$FSG_PREFIX" --no-agent < /dev/null > "$C/o" 2>&1; eq $? 1 "no terminal and no --yes: refused"
  has "$(cat "$C/o")" "pass --yes" "message names --yes"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "sudo" "no sudo call"
  absent "$FSG_STATE_DIR/app" "refused before anything changed"
  # script(1) gives the guard a terminal; answer WORD QUESTION types WORD there once
  # QUESTION shows in $C/o (cleared first), within 60 s.
  answer() {
    local n=300
    while [ $n -gt 0 ] && ! grep -qF -- "$2" "$C/o" 2>/dev/null; do sleep 0.2; n=$((n - 1)); done
    printf '%s\n' "$1"
  }
  : > "$C/o"; answer n "Run this as root?" | FSG_HELPER_MIN_MB=300 script -q /dev/null "$G" install --prefix "$FSG_PREFIX" --no-agent > "$C/o" 2>&1
  has "$(cat "$C/o")" "Run this as root? [y/N]" "a terminal is asked"
  before "$C/o" "guard tree:" "Run this as root?"
  before "$C/o" "lib/root-steps.sh blob: " "Run this as root?"
  before "$C/o" "rendered helper settings: " "Run this as root?"
  before "$C/o" "WARNING: helper setting FSG_HELPER_MIN_MB=300" "Run this as root?"
  before "$C/o" "sudoers rule: $(id -un) ALL=(root) NOPASSWD: $HP \"\"" "Run this as root?"
  has "$(cat "$C/o")" "not confirmed" "no is a refusal"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "sudo" "no sudo call after no"
  absent "$HP" "no helper after no"
  : > "$C/o"; answer y "Run this as root?" | script -q /dev/null "$G" install --prefix "$FSG_PREFIX" --no-agent > "$C/o" 2>&1
  exists "$HP" "yes installs"
  has "$(cat "$FSG_FAKE/calls.log")" "sudo -k /bin/sh -c" "yes runs sudo"
  : > "$FSG_FAKE/calls.log"
  FSG_HELPER_MIN_MB=300 script -q /dev/null "$G" install --yes --prefix "$FSG_PREFIX" --no-agent < /dev/null > "$C/o" 2>&1
  hasnt "$(cat "$C/o")" "Run this as root?" "--yes is not asked"
  has "$(cat "$FSG_FAKE/calls.log")" "sudo -k /bin/sh -c" "--yes runs sudo"
  : > "$FSG_FAKE/calls.log"
  FSG_HELPER_MIN_MB=300 "$G" install --prefix "$FSG_PREFIX" --no-agent < /dev/null > "$C/o" 2>&1; eq $? 0 "unchanged root files: no terminal and no --yes needed"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "sudo -k" "and no sudo prompt"
  : > "$FSG_FAKE/calls.log"
  "$G" uninstall --prefix "$FSG_PREFIX" < /dev/null > "$C/o" 2>&1; eq $? 1 "uninstall: no terminal and no --yes: refused"
  : > "$C/o"; answer n "remove all of the above?" | script -q /dev/null "$G" uninstall --prefix "$FSG_PREFIX" > "$C/o" 2>&1
  has "$(cat "$C/o")" "Uninstall: remove all of the above? [y/N]" "uninstall asks a terminal once"
  before "$C/o" "uninstall removes:" "remove all of the above?"
  before "$C/o" "root-steps sha256: " "remove all of the above?"
  has "$(cat "$C/o")" "not confirmed; nothing was removed" "no is a refusal"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "sudo" "uninstall: no sudo call without a yes"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "launchctl bootout" "the agent stays loaded"
  exists "$HP" "helper kept"; exists "$FSG_STATE_DIR/app" "user files kept"

  t "the trial window is capped at 24 hours"
  install_fake --no-agent --trial-hours 25; eq $? 64 "25 h refused"
  install_fake --no-agent --trial-hours 99999999999999999999; eq $? 64 "a huge value refused"
  absent "$FSG_PREFIX/usr/local/libexec/fseventsd-guard-restart" "nothing installed"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "sudo" "no sudo call"
  install_fake --trial-hours 024; eq $? 0 "24 h (leading zero) accepted"
  HP="$FSG_PREFIX/usr/local/libexec/fseventsd-guard-restart"
  tu=$(sed -n 's/^TRIAL_UNTIL=//p' "$HP")
  [ "$tu" -le $(( $(date +%s) + 86400 )) ] && [ "$tu" -gt $(( $(date +%s) + 86000 )) ] && ok || bad "TRIAL_UNTIL is 24 h ahead ($tu)"
  before "$C/install.out" "trial window: open until" "root steps done"
  "$G" doctor --prefix "$FSG_PREFIX" > "$C/doc.out" 2>&1; eq $? 1 "doctor warns while the window is open"
  has "$(cat "$C/doc.out")" "WARN  trial window open until" "doctor names the window"
  has "$("$G" status 2>/dev/null)" "helper: trial window open until" "status shows the window"
  sed "s/^TRIAL_UNTIL=.*/TRIAL_UNTIL=$(( $(date +%s) + 3 * 86400 ))/" "$HP" > "$C/h" && cat "$C/h" > "$HP"
  "$G" doctor --prefix "$FSG_PREFIX" > "$C/doc.out" 2>&1
  has "$(cat "$C/doc.out")" "ends more than 24 h from now" "doctor flags a window beyond the cap"
  hasnt "$("$G" status 2>/dev/null)" "trial window open" "status: a window beyond the cap is not open"
fi

# ======================================================================== root-dirs
if ! skip_case root-dirs; then
  t "root steps refuse a pre-existing unsafe helper dir instead of taking it over"
  HD="$FSG_PREFIX/usr/local/libexec"
  mkdir -p "$HD"; chmod 775 "$HD"
  install_fake --no-agent; rc=$?
  [ $rc -ne 0 ] && ok || bad "install must refuse a group-writable pre-existing dir"
  eq "$(stat -f %Lp "$HD")" 775 "the pre-existing dir was not chmod-ed"
  absent "$HD/fseventsd-guard-restart" "no helper installed"

  t "root steps never follow a planted temp name or helper symlink"
  HD="$FSG_PREFIX/usr/local/libexec"; mkdir -p "$HD"; chmod 755 "$HD"
  echo "victim" > "$C/victim"
  ln -s "$C/victim" "$HD/.fseventsd-guard-restart.new"
  install_fake --no-agent; eq $? 0 "install succeeds past a planted temp symlink"
  eq "$(cat "$C/victim")" "victim" "the symlink target was not overwritten"
  [ -L "$HD/fseventsd-guard-restart" ] && bad "helper must not be a symlink" || ok
  "$G" uninstall --yes --prefix "$FSG_PREFIX" >/dev/null 2>&1
  mkdir -p "$HD"; echo "victim" > "$C/victim2"; ln -s "$C/victim2" "$HD/fseventsd-guard-restart"
  install_fake --no-agent; rc=$?
  [ $rc -ne 0 ] && ok || bad "install must refuse a helper path that is a symlink"
  eq "$(cat "$C/victim2")" "victim" "the helper symlink's target was not overwritten"
  [ -L "$HD/fseventsd-guard-restart" ] && ok || bad "the symlink is left for the user to inspect"

  t "root steps and doctor check where a symlinked helper ancestor really points"
  # usr/local -> a world-writable dir: stat on the link itself sees a closed 0755.
  EV="$FSG_PREFIX/evil"; mkdir -p "$EV/libexec" "$FSG_PREFIX/usr"; chmod 755 "$EV/libexec"; chmod 777 "$EV"
  ln -s "$EV" "$FSG_PREFIX/usr/local"
  install_fake --no-agent; rc=$?
  [ $rc -ne 0 ] && ok || bad "install must refuse a helper dir whose physical parent is writable"
  has "$(cat "$C/install.out")" "$EV (the physical path of $FSG_PREFIX/usr/local" "message names the physical dir"
  absent "$EV/libexec/fseventsd-guard-restart" "no helper installed through the symlink"
  # Outside the fake root: refused even when the target is closed.
  rm "$FSG_PREFIX/usr/local"; mkdir -p "$C/outside/libexec"; chmod 755 "$C/outside" "$C/outside/libexec"
  ln -s "$C/outside" "$FSG_PREFIX/usr/local"
  install_fake --no-agent; [ $? -ne 0 ] && ok || bad "install must refuse a helper dir outside the test prefix"
  has "$(cat "$C/install.out")" "outside the test prefix" "message"
  absent "$C/outside/libexec/fseventsd-guard-restart" "nothing written outside the prefix"
  # A link into a closed dir is fine, and doctor flags it once it is opened up.
  rm "$FSG_PREFIX/usr/local"; SAFE="$FSG_PREFIX/opt/local"; mkdir -p "$SAFE/libexec"; chmod 755 "$SAFE" "$SAFE/libexec"
  ln -s "$SAFE" "$FSG_PREFIX/usr/local"
  install_fake --no-agent; eq $? 0 "install accepts a symlink into a closed dir"
  exists "$SAFE/libexec/fseventsd-guard-restart" "helper installed at the physical path"
  "$G" doctor --prefix "$FSG_PREFIX" > "$C/doc.out" 2>&1
  hasnt "$(cat "$C/doc.out")" "swap the helper" "doctor: no dir flagged"
  chmod 777 "$FSG_PREFIX/opt"
  "$G" doctor --prefix "$FSG_PREFIX" > "$C/doc.out" 2>&1; eq $? 2 "doctor fails on a writable physical ancestor"
  has "$(cat "$C/doc.out")" "FAIL  $FSG_PREFIX/opt (owner uid $(id -u), mode 777) lets a non-root user swap the helper" "doctor names it"
  chmod 755 "$FSG_PREFIX/opt"
  mv "$SAFE" "$C/outside2"; rm "$FSG_PREFIX/usr/local"; ln -s "$C/outside2" "$FSG_PREFIX/usr/local"
  "$G" doctor --prefix "$FSG_PREFIX" > "$C/doc.out" 2>&1; eq $? 2 "doctor fails on a swap out of the prefix"
  has "$(cat "$C/doc.out")" "is outside the test prefix" "doctor names it"
fi

# ======================================================================== root-acl
if ! skip_case root-acl; then
  t "root steps refuse a helper dir or ancestor with an ACL entry, whatever its mode"
  HD="$FSG_PREFIX/usr/local/libexec"; mkdir -p "$HD"; chmod 755 "$HD" "$FSG_PREFIX/usr/local"
  chmod +a "everyone allow add_file,delete_child" "$HD"
  install_fake --no-agent; [ $? -ne 0 ] && ok || bad "install must refuse a 0755 dir with an ACL"
  has "$(cat "$C/install.out")" "$HD has an access control list" "message names the dir"
  absent "$HD/fseventsd-guard-restart" "no helper installed"
  chmod -N "$HD"; chmod +a "everyone allow add_subdirectory,delete_child" "$FSG_PREFIX/usr/local"
  install_fake --no-agent; [ $? -ne 0 ] && ok || bad "install must refuse an ancestor with an ACL"
  has "$(grep 'access control list' "$C/install.out")" "fseventsd-guard (root): $FSG_PREFIX/usr/local " "message names the ancestor"
  chmod -N "$FSG_PREFIX/usr/local"
  install_fake --no-agent; eq $? 0 "installs once the ACLs are gone"

  t "files and dirs the root steps create keep no inherited ACL"
  mkdir -p "$C/stage" "$C/wrap"; render_helper "$C/stage/helper" 0
  HP="$FSG_PREFIX/usr/local/libexec/fseventsd-guard-restart"; SP="$FSG_PREFIX/etc/sudoers.d/fseventsd-guard"
  printf '%s ALL=(root) NOPASSWD: %s ""\n' "$(id -un)" "$HP" > "$C/stage/sudoers"
  hs=$(shasum -a 256 "$C/stage/helper" | awk '{print $1}'); ss=$(shasum -a 256 "$C/stage/sudoers" | awk '{print $1}')
  printf '%s\n' "$(cat "$GUARD_HOME/lib/root-steps.sh")" > "$C/stage/root-steps"; rss=$(shasum -a 256 "$C/stage/root-steps" | awk '{print $1}')
  # Every new temp file and dir gets an ACL entry, as an inheritable entry on its parent would give it.
  printf '#!/bin/bash\nf=$(/usr/bin/mktemp "$@") || exit 1\n/bin/chmod +a "everyone allow read,write" "$f"\necho "$f"\n' > "$C/wrap/mktemp"
  printf '#!/bin/bash\n[ "$1" = -p ] && exec /bin/mkdir "$@"\n/bin/mkdir "$@" || exit 1\n/bin/chmod +a "everyone allow add_file,delete_child" "${@: -1}"\n' > "$C/wrap/mkdir"
  chmod +x "$C/wrap/mktemp" "$C/wrap/mkdir"
  root_steps "$C/wrap" install "$FSG_PREFIX" "$C/stage/helper" "$hs" "$C/stage/sudoers" "$ss" 1 "$C/stage/root-steps" "$rss" >/dev/null; eq $? 0 "installs"
  for p in "$HP" "$SP" "$(dirname "$HP")/fseventsd-guard-root-steps" "$FSG_PREFIX/Library/Logs/fseventsd-guard/install-manifest" "$FSG_PREFIX/usr/local/libexec" \
      "$FSG_PREFIX/usr/local" "$FSG_PREFIX/etc/sudoers.d" "$FSG_PREFIX/Library/Logs/fseventsd-guard"; do
    eq "$(/bin/ls -led "$p" | sed 1d)" "" "no ACL left on $p"
  done

  t "doctor flags an ACL on the helper, its dir and the drop-in"
  install_fake; eq $? 0 "install"
  HP="$FSG_PREFIX/usr/local/libexec/fseventsd-guard-restart"; SP="$FSG_PREFIX/etc/sudoers.d/fseventsd-guard"
  "$G" doctor --prefix "$FSG_PREFIX" >/dev/null 2>&1; eq $? 0 "doctor clean"
  for p in "$HP" "$(dirname "$HP")" "$SP"; do
    chmod +a "everyone allow write" "$p"
    "$G" doctor --prefix "$FSG_PREFIX" > "$C/doc.out" 2>&1; eq $? 2 "doctor fails on an ACL on $p"
    has "$(grep 'FAIL' "$C/doc.out")" "$p has an access control list" "doctor names $p"
    chmod -N "$p"
  done
  RS="$(dirname "$HP")/fseventsd-guard-root-steps"; chmod +a "everyone allow write" "$RS"
  "$G" doctor --prefix "$FSG_PREFIX" > "$C/doc.out" 2>&1; eq $? 2 "doctor fails on an ACL on the root-steps copy"
  has "$(grep 'FAIL' "$C/doc.out")" "root-steps copy $RS has owner uid $(id -u), mode 755 and an access control list" "doctor names it"
  chmod -N "$RS"
fi

# ======================================================================== root-staged
if ! skip_case root-staged; then
  t "root steps refuse a symlinked staged file and verify before exposing the copy"
  mkdir -p "$C/stage" "$C/wrap"
  render_helper "$C/stage/helper.real" 0
  ln -s "$C/stage/helper.real" "$C/stage/helper"
  printf '%s ALL=(root) NOPASSWD: %s ""\n' "$(id -un)" "$FSG_PREFIX/usr/local/libexec/fseventsd-guard-restart" > "$C/stage/sudoers"
  hs=$(shasum -a 256 "$C/stage/helper.real" | awk '{print $1}'); ss=$(shasum -a 256 "$C/stage/sudoers" | awk '{print $1}')
  root_steps "" install "$FSG_PREFIX" "$C/stage/helper" "$hs" "$C/stage/sudoers" "$ss" 1 2>/dev/null; rc=$?
  [ $rc -ne 0 ] && ok || bad "a symlinked staged helper must be refused"
  absent "$FSG_PREFIX/usr/local/libexec/fseventsd-guard-restart" "nothing installed through the symlink"
  # Record the copy's mode at the moment its hash is checked.
  printf '#!/bin/bash\nfor a; do case $a in %s/*) echo "sha-mode $(stat -f %%Lp "$a") $a" >> "$FSG_FAKE/calls.log" ;; esac; done\nexec /usr/bin/shasum "$@"\n' "$FSG_PREFIX" > "$C/wrap/shasum"
  chmod +x "$C/wrap/shasum"
  : > "$FSG_FAKE/calls.log"
  root_steps "$C/wrap" install "$FSG_PREFIX" "$C/stage/helper.real" "$hs" "$C/stage/sudoers" "$ss" 1 >/dev/null; eq $? 0 "a regular staged file installs"
  m=$(sed -n 's/^sha-mode \([0-9]*\) .*libexec.*/\1/p' "$FSG_FAKE/calls.log" | head -n 1)
  eq "$m" 600 "the helper copy is root-only (0600) until its hash matches"
  eq "$(stat -f %Lp "$FSG_PREFIX/usr/local/libexec/fseventsd-guard-restart")" 755 "then 0755"

  t "root steps install only a drop-in that names the checked helper path"
  mkdir -p "$C/stage"; render_helper "$C/stage/helper" 0
  hs=$(shasum -a 256 "$C/stage/helper" | awk '{print $1}')
  HP="$FSG_PREFIX/usr/local/libexec/fseventsd-guard-restart"
  for body in "$(id -un) ALL=(root) NOPASSWD: $C/elsewhere \"\"" \
      "$(printf '# ok\n%s ALL=(root) NOPASSWD: %s ""\n#includedir %s' "$(id -un)" "$HP" "$C")" \
      "$(printf '%s ALL=(root) NOPASSWD: %s ""\n%s ALL=(root) NOPASSWD: /bin/sh' "$(id -un)" "$HP" "$(id -un)")"; do
    printf '%s\n' "$body" > "$C/stage/sudoers"; ss=$(shasum -a 256 "$C/stage/sudoers" | awk '{print $1}')
    root_steps "" install "$FSG_PREFIX" "$C/stage/helper" "$hs" "$C/stage/sudoers" "$ss" 1 2> "$C/err"; rc=$?
    [ $rc -ne 0 ] && ok || bad "a drop-in with another rule must be refused: $body"
    has "$(cat "$C/err")" "one rule for $HP only" "message"
    absent "$FSG_PREFIX/etc/sudoers.d/fseventsd-guard" "no drop-in installed"
  done
  printf '# fseventsd-guard\n#\n%s ALL=(root) NOPASSWD: %s ""\n' "$(id -un)" "$HP" > "$C/stage/sudoers"
  ss=$(shasum -a 256 "$C/stage/sudoers" | awk '{print $1}')
  root_steps "" install "$FSG_PREFIX" "$C/stage/helper" "$hs" "$C/stage/sudoers" "$ss" 1 >/dev/null 2>&1; eq $? 0 "the helper's own rule with comments installs"
  # The staged file reads clean at the first check and extra after: the root-owned
  # copy is checked again, and the install rolls back.
  "$G" uninstall --yes --prefix "$FSG_PREFIX" >/dev/null 2>&1
  printf '%s ALL=(root) NOPASSWD: %s ""\n' "$(id -un)" "$HP" > "$C/stage/clean"
  { cat "$C/stage/clean"; printf '%s ALL=(root) NOPASSWD: /bin/sh\n' "$(id -un)"; } > "$C/stage/sudoers"
  ss=$(shasum -a 256 "$C/stage/sudoers" | awk '{print $1}')
  mkdir -p "$C/wrap"
  cat > "$C/wrap/grep" <<EOF
#!/bin/bash
[ "\${@: -1}" = "$C/stage/sudoers" ] && set -- "\${@:1:\$#-1}" "$C/stage/clean"
exec /usr/bin/grep "\$@"
EOF
  chmod +x "$C/wrap/grep"
  root_steps "$C/wrap" install "$FSG_PREFIX" "$C/stage/helper" "$hs" "$C/stage/sudoers" "$ss" 1 2> "$C/err"; rc=$?
  [ $rc -ne 0 ] && ok || bad "a drop-in that changes after the first check must be refused"
  has "$(cat "$C/err")" "one rule for $HP only" "message"
  has "$(cat "$C/err")" "rolled back" "rolled back"
  absent "$FSG_PREFIX/etc/sudoers.d/fseventsd-guard" "no drop-in installed"
  absent "$HP" "no helper left"

  t "root steps install only a rule for the user who ran sudo"
  mkdir -p "$C/stage"; render_helper "$C/stage/helper" 0
  hs=$(shasum -a 256 "$C/stage/helper" | awk '{print $1}')
  HP="$FSG_PREFIX/usr/local/libexec/fseventsd-guard-restart"
  for u in ALL STAFF ADMINS_2 daemon; do
    printf '%s ALL=(root) NOPASSWD: %s ""\n' "$u" "$HP" > "$C/stage/sudoers"; ss=$(shasum -a 256 "$C/stage/sudoers" | awk '{print $1}')
    root_steps "" install "$FSG_PREFIX" "$C/stage/helper" "$hs" "$C/stage/sudoers" "$ss" 1 2> "$C/err"; rc=$?
    [ $rc -ne 0 ] && ok || bad "a rule for $u must be refused"
    case $u in
      daemon) has "$(cat "$C/err")" "is for 'daemon', not for '$(id -un)' who ran sudo" "message: $u" ;;
      *) has "$(cat "$C/err")" "names '$u', which sudoers reads as ALL or a User_Alias" "message: $u" ;;
    esac
    absent "$FSG_PREFIX/etc/sudoers.d/fseventsd-guard" "no drop-in for $u"
    absent "$HP" "no helper for $u"
  done
  printf '%s ALL=(root) NOPASSWD: %s ""\n' "$(id -un)" "$HP" > "$C/stage/sudoers"; ss=$(shasum -a 256 "$C/stage/sudoers" | awk '{print $1}')
  RS_SUDO_USER= root_steps "" install "$FSG_PREFIX" "$C/stage/helper" "$hs" "$C/stage/sudoers" "$ss" 1 2> "$C/err"
  [ $? -ne 0 ] && ok || bad "without SUDO_USER even the own rule is refused"
  root_steps "" install "$FSG_PREFIX" "$C/stage/helper" "$hs" "$C/stage/sudoers" "$ss" 1 >/dev/null 2>&1; eq $? 0 "the rule for SUDO_USER installs"
  # install itself refuses a user name sudoers would read as ALL or an alias.
  "$G" uninstall --yes --prefix "$FSG_PREFIX" >/dev/null 2>&1
  stub_dir "$C/rt"
  printf '#!/bin/bash\n[ "$*" = -un ] && { echo ALL; exit 0; }\nexec /usr/bin/id "$@"\n' > "$C/rt/id.new"
  chmod +x "$C/rt/id.new"; mv -f "$C/rt/id.new" "$C/rt/id"
  : > "$FSG_FAKE/calls.log"
  FSG_TEST_ROOT_TOOLS="$C/rt" install_fake --no-agent; eq $? 1 "install refuses the user name ALL"
  has "$(cat "$C/install.out")" "user name 'ALL' reads as ALL or an alias in sudoers" "message"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "sudo" "no sudo call"
fi

# ======================================================================== root-policy
if ! skip_case root-policy; then
  t "root steps check the whole policy without mode checks and roll back on failure"
  SD="$FSG_PREFIX/etc/sudoers.d"; HP="$FSG_PREFIX/usr/local/libexec/fseventsd-guard-restart"; SP="$SD/fseventsd-guard"
  mkdir -p "$SD"
  printf 'root ALL=(ALL) ALL\n#includedir %s\n' "$SD" > "$FSG_PREFIX/etc/sudoers"
  # Another tool's drop-in at 0644: sudo accepts it, plain `visudo -c` does not.
  printf 'nobody ALL=(root) NOPASSWD: /bin/true\n' > "$SD/amphetamine_PowerProtect"; chmod 644 "$SD/amphetamine_PowerProtect"
  install_fake --no-agent; eq $? 0 "a 0644 third-party drop-in does not fail the install"
  exists "$HP" "helper installed"; exists "$SP" "drop-in installed"
  hp_sum=$(shasum -a 256 "$HP" | awk '{print $1}'); sp_sum=$(shasum -a 256 "$SP" | awk '{print $1}')

  printf 'nobody ALL=(root) NOPASSWD /x\n' > "$SD/broken"; chmod 440 "$SD/broken"
  FSG_HELPER_MIN_MB=300 install_fake --no-agent; eq $? 1 "a reinstall fails on a broken policy"
  out=$(cat "$C/install.out")
  has "$out" "$SD/broken:1" "the message names the failing file and line"
  has "$out" "rolled back" "the message says it rolled back"
  eq "$(shasum -a 256 "$HP" | awk '{print $1}')" "$hp_sum" "the previous helper is back"
  eq "$(shasum -a 256 "$SP" | awk '{print $1}')" "$sp_sum" "the previous drop-in is back"
  absent "$(ls -d "$SD"/fseventsd-guard.* "$(dirname "$HP")"/.fseventsd-guard-restart.* "$(dirname "$HP")"/.fseventsd-guard-root-steps.* 2>/dev/null | head -n 1)" "no temp or backup copies left"
  exists "$(dirname "$HP")/fseventsd-guard-root-steps" "the previous root-steps copy is back"

  "$G" uninstall --yes --prefix "$FSG_PREFIX" >/dev/null 2>&1
  install_fake --no-agent; eq $? 1 "a first install fails on a broken policy"
  absent "$HP" "a first install leaves no helper behind"
  absent "$SP" "a first install leaves no drop-in behind"
  absent "$(dirname "$HP")/fseventsd-guard-root-steps" "a first install leaves no root-steps copy behind"
  exists "$SD/broken" "other files are left alone"

  t "root steps roll back when a signal arrives mid-install"
  SD="$FSG_PREFIX/etc/sudoers.d"; HP="$FSG_PREFIX/usr/local/libexec/fseventsd-guard-restart"
  mkdir -p "$SD" "$C/stage" "$C/wrap"
  printf 'root ALL=(ALL) ALL\n#includedir %s\n' "$SD" > "$FSG_PREFIX/etc/sudoers"
  render_helper "$C/stage/helper" 0
  printf '%s ALL=(root) NOPASSWD: %s ""\n' "$(id -un)" "$HP" > "$C/stage/sudoers"
  hs=$(shasum -a 256 "$C/stage/helper" | awk '{print $1}'); ss=$(shasum -a 256 "$C/stage/sudoers" | awk '{print $1}')
  # The whole-policy check signals the topmost root-steps shell, the way a Ctrl-C
  # would, with the helper and drop-in already in place.
  cat > "$C/wrap/visudo" <<'EOF'
#!/bin/bash
if [ "${1:-}" = -c ] && [ "${2:-}" = -f ]; then
  p=$PPID top=
  while [ -n "$p" ] && [ "$p" -gt 1 ]; do
    ps -o args= -p "$p" | grep -q fsg-root && top=$p
    p=$(ps -o ppid= -p "$p" | tr -d ' ')
  done
  [ -n "$top" ] && kill -TERM "$top"
  sleep 1
fi
exec /usr/sbin/visudo "$@"
EOF
  chmod +x "$C/wrap/visudo"
  root_steps "$C/wrap" install "$FSG_PREFIX" "$C/stage/helper" "$hs" "$C/stage/sudoers" "$ss" 1 2> "$C/err"; rc=$?
  [ $rc -ne 0 ] && ok || bad "an interrupted install must fail"
  has "$(cat "$C/err")" "interrupted by a signal" "message names the signal"
  has "$(cat "$C/err")" "rolled back" "message says it rolled back"
  absent "$HP" "no helper left behind"; absent "$SD/fseventsd-guard" "no drop-in left behind"
fi

# ======================================================================== root-testmode
if ! skip_case root-testmode; then
  t "test hooks cannot reach a real install"
  "$G" install --yes --prefix / --no-agent > "$C/o" 2>&1; eq $? 64 "--prefix / refused"
  "$G" install --yes --prefix /private/.. --no-agent > "$C/o" 2>&1; eq $? 64 "--prefix /private/.. refused"
  FSG_PREFIX=/usr/.. "$G" install --yes --no-agent > "$C/o" 2>&1; eq $? 64 "FSG_PREFIX=/usr/.. refused"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "sudo" "no sudo call for a refused prefix"
  # Simulated root: a stand-in id says uid 0, and fence stand-ins refuse any write
  # outside this run's temp root, so a regression cannot touch the real system.
  W="$C/simroot"; mkdir -p "$W"
  printf '#!/bin/bash\nif [ "${1:-}" = -u ] && [ $# -eq 1 ]; then echo 0; else exec /usr/bin/id "$@"; fi\n' > "$W/id"
  cat > "$W/fence" <<'EOF'
#!/bin/bash
name=$(basename "$0")
echo "$name $*" >> "$FSG_FAKE/calls.log"
[ "$name" = chown ] && exit 0
for a in "$@"; do
  case $a in
    /*) case $a in "$FSG_FENCE"/*) ;; *) echo "FENCE-BLOCKED $name $a" >> "$FSG_FAKE/calls.log"; echo "fence: $name $a" >&2; exit 1 ;; esac ;;
  esac
done
for d in /bin /usr/bin /usr/sbin; do [ -x "$d/$name" ] && exec "$d/$name" "$@"; done
exit 127
EOF
  chmod +x "$W/id" "$W/fence"
  for c in mkdir cp mv chown chmod rm ln mktemp touch; do ln -s fence "$W/$c"; done
  # Install's root tools: fixed paths unless unprivileged under a test prefix.
  rt() { ( FSG_HOME=$GUARD_HOME; . "$GUARD_HOME/lib/common.sh"; . "$GUARD_HOME/lib/install.sh"; FSG_PREFIX=$1; fsg_root_tool "$2" ); }
  eq "$(rt "" sudo)" /usr/bin/sudo "no prefix: /usr/bin/sudo, not the sudo on PATH"
  eq "$(rt "" git)" /usr/bin/git "no prefix: /usr/bin/git"
  eq "$(rt "" visudo)" /usr/sbin/visudo "no prefix: /usr/sbin/visudo"
  eq "$(rt "$FSG_PREFIX" sudo)" "$STUBS/sudo" "test prefix: the suite's stand-in"
  eq "$(rt "$FSG_PREFIX" shasum)" /usr/bin/shasum "a tool with no stand-in keeps its fixed path"
  eq "$(PATH="$W:$PATH" rt "$FSG_PREFIX" sudo)" /usr/bin/sudo "as root, never the stand-in"
  # install and uninstall refuse root (sudo fseventsd-guard install): unit-tested, as
  # an end-to-end run with a uid-0 stand-in would reach the real sudo if it regressed.
  rr() { ( FSG_HOME=$GUARD_HOME; . "$GUARD_HOME/lib/common.sh"; . "$GUARD_HOME/lib/install.sh"; PATH="$1:/usr/bin:/bin"; fsg_refuse_root "$2"; echo "rc=$?" ) 2>&1; }
  for a in install uninstall; do
    out=$(rr "$W" "$a")
    has "$out" "$a: run it as your user, not with sudo or as root; it asks for sudo itself" "$a refuses root"
    hasnt "$out" "rc=" "$a stops as root"
    eq "$(rr "$STUBS" "$a")" "rc=0" "$a runs as the user"
    body=$(awk -v f="fsg_cmd_$a() {" '$0 == f { on = 1 } on && /^}/ { exit } on' "$GUARD_HOME/lib/install.sh")
    eq "$(printf '%s\n' "$body" | grep -A1 '^  fsg_fixed_path$' | sed -n 2p)" "  fsg_refuse_root $a" "$a checks right after fixing PATH"
  done
  export FSG_FENCE=$ROOT
  mkdir -p "$C/stage"; render_helper "$C/stage/helper" 0
  printf '%s ALL=(root) NOPASSWD: /usr/local/libexec/fseventsd-guard-restart ""\n' "$(id -un)" > "$C/stage/sudoers"
  hs=$(shasum -a 256 "$C/stage/helper" | awk '{print $1}'); ss=$(shasum -a 256 "$C/stage/sudoers" | awk '{print $1}')
  : > "$FSG_FAKE/calls.log"
  root_steps "$W" install "$FSG_PREFIX" "$C/stage/helper" "$hs" "$C/stage/sudoers" "$ss" 1 2> "$C/err"; rc=$?
  [ $rc -ne 0 ] && ok || bad "as root, a test prefix must be refused"
  has "$(cat "$C/err")" "prefix" "message names the prefix"
  absent "$FSG_PREFIX/usr/local/libexec/fseventsd-guard-restart" "nothing installed under the prefix as root"
  root_steps "$W" install "" "$C/stage/helper" "$hs" "$C/stage/sudoers" "$ss" 0 2> "$C/err"; rc=$?
  [ $rc -ne 0 ] && ok || bad "as root, a helper rendered with test TOOLS must be refused"
  has "$(cat "$C/err")" "TOOLS" "message names TOOLS"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "FENCE-BLOCKED" "refused before any write"
  unset FSG_FENCE
fi

# ======================================================================== source-gate
if ! skip_case source-gate; then
  t "install runs only reviewed root code and shows what it runs"
  head=$(tgit rev-parse HEAD)
  install_fake --no-agent; eq $? 0 "clean tree matching origin/main installs"
  out=$(cat "$C/install.out")
  has "$out" "$head" "the commit is printed before the sudo prompt"
  rs=$(git -C "$REPO" show "HEAD:plugins/fseventsd-guard/lib/root-steps.sh" | shasum -a 256 | awk '{print $1}')
  has "$out" "root-steps text sha256: $rs" "root-steps hash printed"
  hp=$(shasum -a 256 "$FSG_PREFIX/usr/local/libexec/fseventsd-guard-restart" | awk '{print $1}')
  has "$out" "rendered helper sha256: $hp" "rendered helper hash printed"
  has "$out" "guard tree: $(tgit rev-parse HEAD:plugins/fseventsd-guard) " "the guard's git tree id printed"
  has "$out" "rendered helper settings: EVIDENCE_DIR=" "the rendered settings printed"
  has "$out" " MIN_MB=150 " "with the floor"
  before "$C/install.out" "root-steps text sha256" "root steps done"
  has "$out" "lib/root-steps.sh blob: $(tgit rev-parse HEAD:plugins/fseventsd-guard/lib/root-steps.sh)" "root-steps blob id printed"
  has "$out" "lib/restart-helper.sh blob: $(tgit rev-parse HEAD:plugins/fseventsd-guard/lib/restart-helper.sh)" "helper source blob id printed"
  has "$out" "sudoers rule: $(id -un) ALL=(root) NOPASSWD: $FSG_PREFIX/usr/local/libexec/fseventsd-guard-restart \"\"" "the exact rule printed"

  t "a git replace ref cannot swap the root code"
  rsb=$(tgit rev-parse HEAD:plugins/fseventsd-guard/lib/root-steps.sh)
  evil=$( { echo '#!/bin/sh'; echo ': > "$FSG_FAKE/replaced"'; git -C "$REPO" show "$rsb" | tail -n +2; } | tgit hash-object -w --stdin)
  tgit replace "$rsb" "$evil"
  install_fake --no-agent; rc=$?
  tgit replace -d "$rsb" >/dev/null
  eq $rc 0 "installs"
  absent "$FSG_FAKE/replaced" "the reviewed root steps ran, not the replacement"
  has "$(cat "$C/install.out")" "lib/root-steps.sh blob: $rsb" "the printed blob id is the reviewed one"

  t "install refuses an edited or untracked root file"
  echo '# planted' >> "$GUARD_HOME/lib/root-steps.sh"
  install_fake --no-agent; eq $? 1 "an edited root-steps.sh is refused"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "sudo" "no sudo prompt"
  absent "$FSG_STATE_DIR/app" "nothing changed on the user side either"
  install_fake --no-agent --allow-unreviewed; eq $? 0 "--allow-unreviewed installs"
  has "$(cat "$C/install.out")" "UNREVIEWED" "and says so"
  # The copy install placed is what the --allow-unreviewed install ran; uninstall runs it.
  "$G" uninstall --yes --prefix "$FSG_PREFIX" > "$C/un.out" 2>&1; eq $? 0 "uninstall runs the root-owned copy, not the checkout's text"
  tgit checkout -q -- plugins/fseventsd-guard/lib/root-steps.sh
  echo 'x' > "$GUARD_HOME/lib/extra.sh"
  install_fake --no-agent; eq $? 1 "an untracked file in the guard dir is refused"
  tgit clean -q -f -- plugins/fseventsd-guard/lib/extra.sh

  t "install refuses a commit that is not on origin/main"
  head0=$(tgit rev-parse HEAD)
  tgit checkout -q -b feature
  echo '# change' >> "$GUARD_HOME/lib/restart-helper.sh"
  tgit commit -q -am "unreviewed helper change"
  install_fake --no-agent; eq $? 1 "refused"
  has "$(cat "$C/install.out")" "origin/main" "message names the reviewed ref"
  tgit branch -q origin/main HEAD 2>/dev/null; tgit tag origin/main HEAD
  install_fake --no-agent; eq $? 1 "a local branch or tag named origin/main is not the reviewed ref"
  tgit branch -q -D origin/main; tgit tag -d origin/main >/dev/null
  tgit update-ref refs/remotes/origin/main HEAD
  install_fake --no-agent; eq $? 0 "installs once origin/main has it"
  tgit checkout -q -; tgit update-ref refs/remotes/origin/main "$head0"

  t "install runs root code only from a clone of the reviewed repo"
  ORIGIN=https://github.com/RuslanTar/fseventsd-guard.git
  for u in https://github.com/RuslanTar/fseventsd-guard git@github.com:RuslanTar/fseventsd-guard.git \
           ssh://git@github.com/RuslanTar/fseventsd-guard.git https://github.com/ruslantar/FSEVENTSD-GUARD.git/; do
    tgit remote set-url origin "$u"
    install_fake --no-agent; eq $? 0 "origin $u is the reviewed repo"
  done
  has "$(cat "$C/install.out")" "matches origin/main of github.com/ruslantar/fseventsd-guard" "the reviewed repo is named"
  for u in https://github.com/someone/fseventsd-guard.git https://github.com/RuslanTar/fseventsd-guard-old git@git.example.com:RuslanTar/fseventsd-guard.git; do
    tgit remote set-url origin "$u"
    : > "$FSG_FAKE/calls.log"
    install_fake --no-agent; eq $? 1 "origin $u is refused"
    has "$(cat "$C/install.out")" "refusing to run unreviewed code as root: origin of $REPO is $u, not the reviewed repo github.com/ruslantar/fseventsd-guard" "message names $u"
    has "$(cat "$C/install.out")" "(a fork or an SSH host alias: set FSG_REVIEWED_ORIGIN in $FSG_STATE_DIR/config" "message names the fork setting"
    hasnt "$(cat "$FSG_FAKE/calls.log")" "sudo -k" "no sudo prompt"
  done
  echo '# app copy before' >> "$FSG_STATE_DIR/app/config.defaults"
  install_fake --no-agent; eq $? 1 "refused"
  has "$(tail -n 1 "$FSG_STATE_DIR/app/config.defaults")" "# app copy before" "the app copy is not replaced"
  install_fake --no-agent --allow-unreviewed; eq $? 0 "--allow-unreviewed installs from another origin"
  has "$(cat "$C/install.out")" "UNREVIEWED (--allow-unreviewed): working tree of $GUARD_HOME" "and says so"
  tgit remote set-url origin git@github.com:RuslanTar/fseventsd-guard-old.git
  FSG_REVIEWED_ORIGIN=github.com/RuslanTar/fseventsd-guard-old install_fake --no-agent; eq $? 0 "FSG_REVIEWED_ORIGIN trusts a fork"
  has "$(cat "$C/install.out")" "matches origin/main of github.com/ruslantar/fseventsd-guard-old" "the fork is named"
  tgit remote set-url origin git@github-work:RuslanTar/fseventsd-guard.git
  install_fake --no-agent; eq $? 1 "a clone through an SSH host alias is refused"
  FSG_REVIEWED_ORIGIN=git@github-work:RuslanTar/fseventsd-guard.git install_fake --no-agent; eq $? 0 "and installs with that URL as FSG_REVIEWED_ORIGIN"
  echo "FSG_REVIEWED_ORIGIN=https://github.com/someone/fseventsd-guard" > "$FSG_STATE_DIR/config"
  tgit remote set-url origin https://github.com/someone/fseventsd-guard.git
  install_fake --no-agent; eq $? 0 "the same from the user config"
  : > "$FSG_STATE_DIR/config"
  # remote remove drops origin/main too; it is put back after.
  om=$(tgit rev-parse refs/remotes/origin/main)
  tgit remote remove origin
  install_fake --no-agent; eq $? 1 "a clone without an origin is refused"
  has "$(cat "$C/install.out")" "$REPO has no origin remote" "message"
  tgit remote add origin "$ORIGIN"; tgit update-ref refs/remotes/origin/main "$om"
  install_fake --no-agent; eq $? 0 "the reviewed origin again"

  t "install checks a clone whose root is the guard dir for uncommitted changes too"
  R2="$C/flat"; cp -R "$GUARD_HOME" "$R2"
  ( REPO=$R2; tgit init -q && tgit add -A && tgit commit -q -m flat && tgit update-ref refs/remotes/origin/main HEAD &&
    tgit remote add origin https://github.com/RuslanTar/fseventsd-guard.git ) || bad "the flat test repo"
  "$R2/fseventsd-guard" install --yes --prefix "$FSG_PREFIX" --no-agent > "$C/o" 2>&1; eq $? 0 "a clean flat clone installs"
  echo 'x' > "$R2/lib/extra.sh"
  "$R2/fseventsd-guard" install --yes --prefix "$FSG_PREFIX" --no-agent > "$C/o" 2>&1; eq $? 1 "an untracked file at its root is refused"
  has "$(cat "$C/o")" "has uncommitted or untracked changes:" "message"
  has "$(cat "$C/o")" "lib/extra.sh" "and names the file"

  t "the app copy comes from the reviewed git tree, not from working files git does not show"
  install_fake --no-agent; eq $? 0 "install"
  echo '# local edit' >> "$GUARD_HOME/lib/hint.sh"
  tgit update-index --assume-unchanged plugins/fseventsd-guard/lib/hint.sh
  echo '# local edit' >> "$GUARD_HOME/config.defaults"
  tgit update-index --skip-worktree plugins/fseventsd-guard/config.defaults
  echo 'plugins/fseventsd-guard/lib/local.sh' >> "$REPO/.git/info/exclude"
  echo '# ignored' > "$GUARD_HOME/lib/local.sh"
  eq "$(tgit status --porcelain --untracked-files=all)" "" "git status shows none of them"
  install_fake --no-agent; eq $? 0 "the gate passes"
  has "$(cat "$C/install.out")" "app copy from git tree $(tgit rev-parse HEAD:plugins/fseventsd-guard)" "install says where the app copy comes from"
  same=1
  for f in fseventsd-guard config.defaults lib/common.sh lib/install.sh lib/hint.sh lib/root-steps.sh probe/fsprobe.swift launchd/agent.plist.template; do
    tgit show "HEAD:plugins/fseventsd-guard/$f" | cmp -s - "$FSG_STATE_DIR/app/$f" || { same=0; bad "app copy $f differs from the reviewed tree"; }
  done
  [ $same = 1 ] && ok
  hasnt "$(cat "$FSG_STATE_DIR/app/lib/hint.sh")" "# local edit" "an assume-unchanged edit stays out"
  hasnt "$(cat "$FSG_STATE_DIR/app/config.defaults")" "# local edit" "a skip-worktree edit stays out"
  absent "$FSG_STATE_DIR/app/lib/local.sh" "an ignored file stays out"
  [ -x "$FSG_STATE_DIR/app/fseventsd-guard" ] && ok || bad "the app script is executable"
  tgit remote set-url origin https://github.com/someone/fseventsd-guard.git
  install_fake --no-agent --allow-unreviewed; eq $? 0 "--allow-unreviewed"
  has "$(cat "$C/install.out")" "app copy from the working tree of $GUARD_HOME" "copies the working tree"
  has "$(cat "$FSG_STATE_DIR/app/lib/hint.sh")" "# local edit" "with its edits"
  tgit remote set-url origin "$ORIGIN"
  tgit update-index --no-assume-unchanged plugins/fseventsd-guard/lib/hint.sh
  tgit update-index --no-skip-worktree plugins/fseventsd-guard/config.defaults
  tgit checkout -q -- plugins/fseventsd-guard/lib/hint.sh plugins/fseventsd-guard/config.defaults
  mv "$GUARD_HOME/lib/local.sh" "$C/local.sh"
  eq "$(tgit status --porcelain --untracked-files=all)" "" "the test repo is clean again"

  t "install refuses to run from Claude Code's plugin directory; the hooks still run there"
  CH="$C/home"
  MP="$CH/.claude/plugins/marketplaces/fseventsd-guard"; mkdir -p "$(dirname "$MP")"; cp -R "$REPO" "$MP"
  CP="$CH/.claude/plugins/cache/fseventsd-guard/fseventsd-guard/1.0.0"; mkdir -p "$(dirname "$CP")"; cp -R "$GUARD_HOME" "$CP"
  mem 3G
  out=$(printf '{"session_id":"s1","hook_event_name":"UserPromptSubmit"}' | HOME=$CH CLAUDE_PLUGIN_ROOT="$CP" bash "$CP/hooks/fseventsd-guard-hook.sh" prompt 2>&1); rc=$?
  eq $rc 0 "the prompt hook runs from the plugin cache"
  has "$out" "fseventsd is running away" "and nudges"
  hasnt "$out" "plugin directory" "the hook is not refused"
  mem 5000K
  install_fake --no-agent; eq $? 0 "install from a clone"
  : > "$FSG_FAKE/calls.log"
  for g in "$MP/plugins/fseventsd-guard" "$CP"; do
    HOME=$CH "$g/fseventsd-guard" install --yes --prefix "$FSG_PREFIX" --no-agent > "$C/o" 2>&1; eq $? 1 "install refused from $g"
    has "$(cat "$C/o")" "install: $g is inside Claude Code's plugin directory" "message names the dir"
    has "$(cat "$C/o")" "clone the repo and run install from the clone: git clone https://github.com/RuslanTar/fseventsd-guard.git ~/fseventsd-guard" "message says to clone"
    HOME=$CH "$g/fseventsd-guard" install --yes --allow-unreviewed --prefix "$FSG_PREFIX" --no-agent > "$C/o" 2>&1; eq $? 1 "--allow-unreviewed does not lift it"
  done
  ln -s "$CP" "$C/link"
  HOME=$CH "$C/link/fseventsd-guard" install --yes --prefix "$FSG_PREFIX" --no-agent > "$C/o" 2>&1; eq $? 1 "also through a symlink"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "sudo" "no sudo call"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "swiftc" "nothing built"
  # status and doctor from the plugin's copy point at a clone, as install refuses there.
  echo '# stale' >> "$FSG_STATE_DIR/app/config.defaults"
  out=$(HOME=$CH "$CP/fseventsd-guard" status 2>&1)
  has "$out" "install: the app copy differs from this plugin copy and the root code is unchanged: run install from a clone (git pull in it first); it needs no sudo" "status from the plugin copy"
  hasnt "$out" "this checkout" "status does not send you back to the plugin copy"
  HOME=$CH "$CP/fseventsd-guard" doctor --prefix "$FSG_PREFIX" > "$C/o" 2>&1
  has "$(cat "$C/o")" "installed app copy differs from this plugin copy ($CP): run install from a clone (git pull in it first) to update the agent" "doctor from the plugin copy"
  hasnt "$(cat "$C/o")" "this checkout" "doctor does not send you back to the plugin copy"
  sed '$d' "$FSG_STATE_DIR/app/config.defaults" > "$C/cd" && cat "$C/cd" > "$FSG_STATE_DIR/app/config.defaults"
  CD="$C/cfg/plugins/cache/x/fseventsd-guard"; mkdir -p "$(dirname "$CD")"; cp -R "$GUARD_HOME" "$CD"
  CLAUDE_CONFIG_DIR="$C/cfg" "$CD/fseventsd-guard" install --yes --prefix "$FSG_PREFIX" --no-agent > "$C/o" 2>&1; eq $? 1 "refused under CLAUDE_CONFIG_DIR's plugins"
  has "$(cat "$C/o")" "inside Claude Code's plugin directory" "message"
  CC="$C/pcache/cache/x/fseventsd-guard"; mkdir -p "$(dirname "$CC")"; cp -R "$GUARD_HOME" "$CC"
  CLAUDE_CODE_PLUGIN_CACHE_DIR="$C/pcache" "$CC/fseventsd-guard" install --yes --prefix "$FSG_PREFIX" --no-agent > "$C/o" 2>&1; eq $? 1 "refused under CLAUDE_CODE_PLUGIN_CACHE_DIR"
  has "$(cat "$C/o")" "inside Claude Code's plugin directory" "message"
  RS="$FSG_PREFIX/usr/local/libexec/fseventsd-guard-root-steps"
  mv "$RS" "$C/rs.was"
  HOME=$CH "$MP/plugins/fseventsd-guard/fseventsd-guard" uninstall --yes --prefix "$FSG_PREFIX" > "$C/o" 2>&1; eq $? 1 "uninstall's root steps through the gate are refused there too"
  has "$(cat "$C/o")" "uninstall: $MP/plugins/fseventsd-guard is inside Claude Code's plugin directory" "message"
  exists "$FSG_PREFIX/usr/local/libexec/fseventsd-guard-restart" "nothing removed"
  mv "$C/rs.was" "$RS"
  PO="$CH/.claude/plugins-old/fseventsd-guard"; mkdir -p "$(dirname "$PO")"; cp -R "$REPO" "$PO"
  HOME=$CH "$PO/plugins/fseventsd-guard/fseventsd-guard" install --yes --prefix "$FSG_PREFIX" --no-agent > "$C/o" 2>&1; eq $? 0 "a sibling dir that only starts with plugins is not the plugin dir"
  hasnt "$(cat "$C/o")" "plugin directory" "no refusal"
fi

# ======================================================================== reinstall
if ! skip_case reinstall; then
  t "uninstall is clean after a reinstall"
  install_fake --no-agent; eq $? 0 "first install"
  # A changed floor: the second install runs the root steps again.
  FSG_HELPER_MIN_MB=300 install_fake --no-agent; eq $? 0 "second install"
  has "$(cat "$C/install.out")" "sudo is needed:" "the reinstall re-runs the root steps"
  "$G" uninstall --yes --prefix "$FSG_PREFIX" > "$C/un.out" 2>&1; eq $? 0 "uninstall exit"
  absent "$FSG_PREFIX/usr/local/libexec" "helper dir made by the first install"
  absent "$FSG_PREFIX/usr" "its parents made by the first install"
  has "$(cat "$C/un.out")" "no traces left" "message"

  t "install asks for sudo only when the root code changes; doctor and status say which"
  HP="$FSG_PREFIX/usr/local/libexec/fseventsd-guard-restart"; RS="$FSG_PREFIX/usr/local/libexec/fseventsd-guard-root-steps"
  install_fake; eq $? 0 "first install"
  has "$(cat "$C/install.out")" "sudo is needed: nothing is installed as root yet" "the first install says why"
  inodes() { ls -i "$HP" "$RS" "$FSG_PREFIX/etc/sudoers.d/fseventsd-guard" | awk '{print $1}' | tr '\n' ' '; }
  i0=$(inodes)
  echo '# stale' >> "$FSG_STATE_DIR/app/config.defaults"
  "$G" doctor --prefix "$FSG_PREFIX" > "$C/doc.out" 2>&1; eq $? 1 "doctor warns on an old app copy"
  has "$(cat "$C/doc.out")" "WARN  installed app copy differs from this checkout ($GUARD_HOME): re-run install to update the agent; the root code is unchanged, so it needs no sudo" "doctor: no sudo needed"
  has "$("$G" status 2>&1)" "install: the app copy differs from this checkout and the root code is unchanged: re-run install from this checkout; it needs no sudo" "status: no sudo needed"
  hasnt "$("$FSG_STATE_DIR/app/fseventsd-guard" status 2>&1)" "install:" "status from the app copy has no checkout to compare"
  : > "$FSG_FAKE/calls.log"
  "$G" install --prefix "$FSG_PREFIX" < /dev/null > "$C/install.out" 2>&1; eq $? 0 "the update installs without a terminal or --yes"
  out=$(cat "$C/install.out")
  has "$out" "[4/5] root helper + sudoers rule: no sudo needed" "install says no sudo is needed"
  hasnt "$out" "Run this as root?" "nothing is asked"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "sudo -k" "no sudo prompt"
  eq "$(inodes)" "$i0" "the root files are not replaced"
  hasnt "$(cat "$FSG_STATE_DIR/app/config.defaults")" "# stale" "the app copy is refreshed"
  has "$out" "doctor: all checks passed" "doctor after the update"
  has "$(cat "$FSG_LOG")" "root=0" "the log says the root steps did not run"
  hasnt "$("$G" status 2>&1)" "install:" "status is quiet once the app copy matches"
  # Each change below makes install run the root steps again, and say why.
  rootrun() { # why [install args]
    local why=$1; shift
    : > "$FSG_FAKE/calls.log"
    install_fake "$@"; eq $? 0 "install: $why"
    has "$(cat "$C/install.out")" "sudo is needed: $why" "install says why"
    eq "$(grep -c '^sudo -k /bin/sh -c' "$FSG_FAKE/calls.log")" 1 "one sudo prompt: $why"
  }
  FSG_HELPER_MIN_MB=300 "$G" doctor --prefix "$FSG_PREFIX" > "$C/doc.out" 2>&1
  has "$(cat "$C/doc.out")" "helper differs from this checkout's source or config (floor/interval changed?): review the change, then re-run install; root code changed, so it asks for sudo" "doctor: helper settings need sudo"
  echo '# stale' >> "$FSG_STATE_DIR/app/config.defaults"
  FSG_HELPER_MIN_MB=300 "$G" doctor --prefix "$FSG_PREFIX" > "$C/doc.out" 2>&1
  has "$(cat "$C/doc.out")" "re-run install to update the agent; it asks for sudo too, as the helper settings (floor, interval, trial window) differ from the installed helper's" "doctor: the app copy update needs sudo too"
  has "$(FSG_HELPER_MIN_MB=300 "$G" status 2>&1)" "install: root code changed (the helper settings (floor, interval, trial window) differ from the installed helper's): re-run install from this checkout; it asks for sudo" "status: sudo needed"
  FSG_HELPER_MIN_MB=300 rootrun "the helper settings (floor, interval, trial window) differ from the installed helper's"
  rootrun "the helper settings (floor, interval, trial window) differ from the installed helper's"
  echo '# old helper' >> "$HP"
  rootrun "lib/restart-helper.sh differs from the installed helper"
  echo '# old root steps' >> "$RS"
  "$G" doctor --prefix "$FSG_PREFIX" > "$C/doc.out" 2>&1; eq $? 1 "doctor warns on an old root-steps copy"
  has "$(cat "$C/doc.out")" "WARN  root-steps copy $RS differs from this checkout's lib/root-steps.sh: re-run install; root code changed, so it asks for sudo" "doctor names it"
  has "$("$G" status 2>&1)" "install: root code changed (lib/root-steps.sh differs from the installed root-steps copy)" "status names it"
  rootrun "lib/root-steps.sh differs from the installed root-steps copy"
  chmod 775 "$HP"
  rootrun "the helper has owner uid $(id -u), mode 775 or an ACL (want uid $(id -u), 0755, none)"
  mv "$RS" "$C/rs.was"
  rootrun "the root-steps copy $RS is missing"
  echo 1 > "$FSG_FAKE/sudo-l-rc"
  rootrun "sudo -n -l: the rule does not allow the helper without a password"
  rm -f "$FSG_FAKE/sudo-l-rc"
  rootrun "--trial-hours opens a trial window in the helper" --trial-hours 2
  rootrun "the helper settings (floor, interval, trial window) differ from the installed helper's"
  : > "$FSG_FAKE/calls.log"
  install_fake; eq $? 0 "and then nothing again"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "sudo -k" "no sudo prompt"

  t "a root step that fails after creating dirs still records them"
  mkdir -p "$FSG_PREFIX/etc/sudoers.d/fseventsd-guard"   # a dir where the drop-in goes
  install_fake --no-agent; [ $? -ne 0 ] && ok || bad "install must fail"
  has "$(cat "$FSG_PREFIX/Library/Logs/fseventsd-guard/install-manifest" 2>/dev/null)" "created_dir=$FSG_PREFIX/usr/local/libexec" "recorded before the failure"
  rmdir "$FSG_PREFIX/etc/sudoers.d/fseventsd-guard"
  "$G" uninstall --yes --prefix "$FSG_PREFIX" > "$C/un.out" 2>&1; eq $? 0 "uninstall exit"
  absent "$FSG_PREFIX/usr/local/libexec" "dir from the failed install removed"

  t "uninstall reports a created dir it could not remove"
  install_fake --no-agent
  chmod 555 "$FSG_PREFIX/usr/local"     # rmdir of libexec fails, like a busy dir
  "$G" uninstall --yes --prefix "$FSG_PREFIX" > "$C/un.out" 2>&1; eq $? 1 "uninstall reports the leftover"
  has "$(cat "$C/un.out")" "left behind:" "message"
  has "$(cat "$C/un.out")" "$FSG_PREFIX/usr/local/libexec" "names the dir"
  chmod 755 "$FSG_PREFIX/usr/local"
fi

# ======================================================================== install-heal
if ! skip_case install-heal; then
  t "install does not unload the agent under a running heal"
  install_fake; eq $? 0 "first install"
  sum0=$(cat "$FSG_STATE_DIR/app/fseventsd-guard" | shasum)
  mkdir -p "$FSG_STATE_DIR/heal.lock"; bg sleep 60
  printf 'pid=%s\nlstart=%s\n' "$LAST_BG" "$(lstart "$LAST_BG")" > "$FSG_STATE_DIR/heal.lock/owner"
  pending "$LAST_BG" 600
  : > "$FSG_FAKE/calls.log"
  install_fake; eq $? 1 "install refuses while a heal runs"
  has "$(cat "$C/install.out")" "heal" "message names the heal"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "launchctl bootout" "the agent was not unloaded"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "sudo" "no root steps"
  # A tick that holds the lock only to measure is not in a heal.
  mv "$FSG_STATE_DIR/drain/pending" "$C/pending.was"
  install_fake; eq $? 0 "install goes ahead under a tick that is not healing"
  killbg "$LAST_BG"

  t "the agent gets enough exit time to restore Docker"
  FSG_HELPER_TIMEOUT_S=40 install_fake; eq $? 0 "install"
  P="$FSG_LAUNCH_AGENTS_DIR/io.github.ruslantar.fseventsd-guard.plist"
  et=$(plutil -extract ExitTimeOut raw "$P" 2>/dev/null)
  eq "$et" $((3 * FSG_DOCKER_TIMEOUT_S + 180 + 40)) "ExitTimeOut covers the interrupted helper call, then desktop start + engine wait + docker start"
  FSG_HELPER_TIMEOUT_S=5 install_fake
  et=$(plutil -extract ExitTimeOut raw "$P" 2>/dev/null)
  eq "$et" $((3 * FSG_DOCKER_TIMEOUT_S + 180 + FSG_DOCKER_TIMEOUT_S + 10)) "or the interrupted docker desktop call, when that is longer"
fi

# ======================================================================== leases
if ! skip_case lease; then
  t "run wrapper lease"
  app_copy
  out=$("$G" run --label wrap -- /bin/sh -c 'echo "me=$$"; cat "$FSG_LEASE_FILE"'); rc=$?
  eq $rc 0 "exit"
  me=$(printf '%s\n' "$out" | sed -n 's/^me=//p'); lp=$(printf '%s\n' "$out" | sed -n 's/^pid=//p')
  eq "$lp" "$me" "lease pid is the exec'd command's pid"
  has "$out" "label=wrap" "label"
  "$G" run -- /bin/sh -c 'exit 7'; eq $? 7 "exit code passes through"
  has "$("$G" leases)" "live work: none" "finished runs hold no live lease"

  t "run waits for a pending drain"
  app_copy
  bg sleep 60; owner=$LAST_BG; pending "$owner" 600
  s=$(date +%s); FSG_RUN_MAX_WAIT_S=2 "$G" run --label held -- true 2> "$C/err"; rc=$?
  eq $rc 75 "gives up after the max wait"; has "$(cat "$C/err")" "holding 'held'" "visible message"
  [ $(( $(date +%s) - s )) -ge 2 ] && ok || bad "waited"
  FSG_RUN_MAX_WAIT_S=1 FSG_RUN_ON_TIMEOUT=proceed "$G" run -- true 2>/dev/null; eq $? 0 "proceed policy"
  ( sleep 2; rm -f "$FSG_STATE_DIR/drain/pending" ) &
  s=$(date +%s); "$G" run --label queued -- true 2>/dev/null; rc=$?
  eq $rc 0 "starts when the drain ends"; [ $(( $(date +%s) - s )) -ge 1 ] && ok || bad "it queued"
  eq "$(ls "$FSG_STATE_DIR/drain/leases" | grep -c '\.held$')" 0 "no held marker once the run starts"

  t "stale drains never block"
  app_copy
  bg sleep 60; owner=$LAST_BG; pending "$owner" -5
  timeout_s=$(date +%s); "$G" run -- true; eq $? 0 "overrun deadline ignored"
  /bin/sh -c 'exit 0' & dead=$!; wait $dead
  printf 'owner_pid=%s\nowner_lstart=x\ndeadline_epoch=%s\nphase=draining\n' "$dead" $(( $(date +%s) + 600 )) > "$FSG_STATE_DIR/drain/pending"
  "$G" run -- true; eq $? 0 "dead owner ignored"

  t "nested runs inherit the lease"
  app_copy
  bg sleep 60; owner=$LAST_BG
  export OWNER=$owner
  out=$(FSG_RUN_MAX_WAIT_S=3 "$G" run --label outer -- /bin/bash -c '
    printf "owner_pid=%s\nowner_lstart=%s\ndeadline_epoch=%s\nphase=draining\n" "$OWNER" "$(LC_ALL=C TZ=UTC0 ps -o lstart= -p "$OWNER" | tr -s " " | sed "s/^ //; s/ $//")" $(( $(date +%s) + 600 )) > "$FSG_STATE_DIR/drain/pending"
    "'"$G"'" run --label inner -- echo inner-ran' 2>&1); rc=$?
  eq $rc 0 "exit"; has "$out" "inner-ran" "inner ran despite the drain"
  rm -f "$FSG_STATE_DIR/drain/pending"

  t "sourced snippet in sh, bash -eu and zsh"
  app_copy
  L="$GUARD_HOME/lib/lease.sh"
  out=$(/bin/sh -c ". '$L' && fsg_lease_acquire sh-run && cat \"\$FSG_LEASE_FILE\" && fsg_lease_release && echo released"); eq $? 0 "sh"
  has "$out" "label=sh-run" "sh lease"; has "$out" released "sh release"
  out=$(/bin/bash -c "set -euo pipefail; . '$L'; fsg_lease_acquire bash-run; grep -c ^label=bash-run\$ \"\$FSG_LEASE_FILE\""); eq "$out" 1 "bash -euo pipefail"
  if command -v zsh >/dev/null 2>&1; then
    out=$(zsh -c "set -eu; . '$L'; fsg_lease_acquire zsh-run; cat \"\$FSG_LEASE_FILE\""); has "$out" "label=zsh-run" "zsh"
  fi
  FSG_DISABLE=1 /bin/sh -c ". '$L' && fsg_lease_acquire x && [ -z \"\${FSG_LEASE_FILE:-}\" ]"; eq $? 0 "FSG_DISABLE=1 is a no-op"

  t "the sourced snippet reads config lines the way the CLI does"
  app_copy
  L="$GUARD_HOME/lib/lease.sh"
  printf '%s\n' 'FSG_RUN_MAX_WAIT_S=1 # one second' "  FSG_RUN_ON_TIMEOUT='proceed'   # start anyway" \
    'FSG_FAILED_HOLD_S="60"' '# FSG_RUN_POLL_S=9' > "$FSG_STATE_DIR/config"
  out=$(env -u FSG_RUN_POLL_S /bin/sh -c ". '$L'; for k in FSG_RUN_MAX_WAIT_S FSG_RUN_ON_TIMEOUT FSG_FAILED_HOLD_S FSG_RUN_POLL_S; do printf '%s ' \"\$(fsg__knob \$k d)\"; done")
  eq "$out" "1 proceed 60 d " "comments, indentation and quotes are not part of a value"
  bg sleep 60; owner=$LAST_BG; pending "$owner" 600
  bg /bin/sh -c ". '$L'; fsg_lease_acquire commented 2>/dev/null; echo \$? > '$C/rc'"; sp=$LAST_BG
  waitfor 6 test -s "$C/rc" && ok || bad "a commented FSG_RUN_MAX_WAIT_S still limits the wait"
  eq "$(cat "$C/rc" 2>/dev/null)" 0 "and a commented FSG_RUN_ON_TIMEOUT=proceed still starts the run"
  killbg "$sp"; killbg "$owner"

  t "lease liveness: dead pids and reused pids"
  mkdir -p "$FSG_STATE_DIR/drain/leases"
  /bin/sh -c 'exit 0' & dead=$!; wait $dead
  printf 'pid=%s\nlstart=Mon Jan 1 00:00:00 2024\nlabel=dead\n' "$dead" > "$FSG_STATE_DIR/drain/leases/$dead.lease"
  bg sleep 60; live=$LAST_BG
  printf 'pid=%s\nlstart=Mon Jan 1 00:00:00 2024\nlabel=reused\n' "$live" > "$FSG_STATE_DIR/drain/leases/$live.lease"
  out=$("$G" leases); hasnt "$out" "dead" "dead pid not live"; hasnt "$out" "reused" "reused pid not live"
  printf 'pid=%s\nlstart=%s\nlabel=real\n' "$live" "$(lstart "$live")" > "$FSG_STATE_DIR/drain/leases/$live.lease"
  has "$("$G" leases)" "pid $live real" "matching start time is live"

  t "leasing is a no-op where the guard is not installed"
  rm -rf "$FSG_STATE_DIR"
  out=$("$G" run --label gone -- /bin/sh -c 'echo "lease=${FSG_LEASE_FILE:-none}"'); eq $? 0 "run runs the command"
  eq "$out" "lease=none" "without a lease"
  /bin/sh -c ". '$GUARD_HOME/lib/lease.sh' && fsg_lease_acquire snippet && [ -z \"\${FSG_LEASE_FILE:-}\" ]"; eq $? 0 "the sourced snippet too"
  absent "$FSG_STATE_DIR" "nothing re-creates the state dir"
fi

# ======================================================================== lease-tz
if ! skip_case lease-tz; then
  t "lease and drain liveness ignore the caller's TZ and locale"
  app_copy
  # Writer and reader disagree on TZ and locale, as the launchd agent (no LANG/TZ)
  # and a teammate's shell (LANG=de_DE, TZ override) do.
  OTHER="TZ=Pacific/Kiritimati LC_ALL=de_DE.UTF-8 LANG=de_DE.UTF-8"
  bg env $OTHER "$G" run --label tzrun -- sleep 30; tzp=$LAST_BG
  sleep 1
  has "$("$G" leases)" "tzrun" "a lease written under another TZ/locale is live"
  ( FSG_HOME=$GUARD_HOME; . "$GUARD_HOME/lib/common.sh"; . "$GUARD_HOME/lib/lease.sh"; . "$GUARD_HOME/lib/drain.sh"; . "$GUARD_HOME/lib/docker.sh"
    fsg_init_paths; fsg_load_config; fsg_live_leases 1 >/dev/null )
  exists "$FSG_STATE_DIR/drain/leases/$tzp.lease" "a heal's reaping keeps the live lease"
  killbg "$tzp"
  # A drain marked under another TZ/locale holds runs started under the defaults,
  # and the reverse.
  mark_drain() { # env-assignments...
    env "$@" /bin/bash -c '
      FSG_HOME=$1; . "$FSG_HOME/lib/common.sh"; . "$FSG_HOME/lib/lease.sh"; . "$FSG_HOME/lib/drain.sh"; . "$FSG_HOME/lib/docker.sh"
      fsg_init_paths; fsg_load_config
      # owner = the test runner (alive for the whole case)
      DRAIN_TRIGGER=manual DRAIN_REASON=tz; DRAIN_OWNER_LSTART=$(fsg_lstart "$2")
      DRAIN_STARTED=$(date +%s); DRAIN_DEADLINE=$((DRAIN_STARTED + 600))
      fsg_drain_write draining
      sed -i "" "s/^owner_pid=.*/owner_pid=$2/" "$FSG_PENDING"' fsg "$GUARD_HOME" "$$"
  }
  mark_drain $OTHER
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 75 "drain from another TZ/locale holds a default-env run"
  rm -f "$FSG_STATE_DIR/drain/pending"
  mark_drain TZ=America/New_York
  FSG_RUN_MAX_WAIT_S=1 env $OTHER "$G" run -- true 2>/dev/null; eq $? 75 "default-env drain holds a run under another TZ/locale"
  rm -f "$FSG_STATE_DIR/drain/pending"
fi

# ======================================================================== detect
if ! skip_case detect; then
  t "unleased process detection"
  # A script, not a copied system binary (macOS kills relocated platform binaries).
  mkdir -p "$C/bin"; printf '#!/bin/sh\nsleep "$1"\n' > "$C/bin/fsgtestrspec"; chmod +x "$C/bin/fsgtestrspec"
  bg "$C/bin/fsgtestrspec" 60; p=$LAST_BG
  has "$("$G" leases)" "process: pid $p" "a matching process is live work"
  FSG_DETECT_PROCESSES=0 "$G" leases | grep -q "pid $p" && bad "detection can be turned off" || ok
  killbg "$p"

  t "matcher rules"
  # The real matcher over a synthetic process table.
  out=$( FSG_HOME=$GUARD_HOME; . "$GUARD_HOME/lib/common.sh"; . "$GUARD_HOME/lib/lease.sh"; . "$GUARD_HOME/lib/drain.sh"; . "$GUARD_HOME/lib/docker.sh"
    fsg_init_paths; fsg_load_config
    FSG_DETECT_COMMANDS="rspec parallel-specs parallel_rspec parallel_test"; FSG_DETECT_DOCKER_CLI=1; FSG_DETECT_PROCESSES=1
    ps() { cat <<'EOF'
 9001 1 05:00 ?? ruby bin/rspec -O .rspec_parallel spec/a_spec.rb
 9002 1 05:00 ?? /opt/homebrew/bin/timeout 9000 bin/parallel-specs
 9003 9002 04:59 ?? /Users/x/.bundles/ruby/3.3.0/bin/parallel_rspec
 9004 9003 04:58 ?? ruby bin/rspec -O .rspec_parallel spec/b_spec.rb
 9005 1 05:00 ?? rg -n rspec scripts
 9006 1 05:00 ?? rtk rspec spec/c_spec.rb
 9007 1 05:00 ?? bundle exec rspec spec/d_spec.rb
 9008 1 05:00 ?? docker exec -i app-postgres psql
 9009 1 05:00 ?? docker compose -f x.yml run --rm api
 9010 1 05:00 ?? docker compose up -d
 9011 1 05:00 ?? docker ps -q
 9012 1 05:00 ?? /bin/zsh -c source snapshot && rtk rspec
 9013 1 05:00 ?? env RAILS_ENV=test bundle exec rspec
 9014 1 05:00 ?? vim spec/rspec_helper.rb
EOF
    }
    fsg_unleased_procs | cut -f2 | sort | tr '\n' ' ')
  eq "$out" "9001 9002 9006 9007 9008 9009 9013 " "matched pids (9003/9004 counted under 9002)"
  out=$( unset FSG_DETECT_COMMANDS; FSG_HOME=$GUARD_HOME; . "$GUARD_HOME/lib/common.sh"; fsg_init_paths; fsg_load_config; echo "$FSG_DETECT_COMMANDS")
  eq "$out" "rspec parallel_rspec parallel_test" "the default names no project's own runner"

  t "interactive docker execs are not waited for"
  out=$( FSG_HOME=$GUARD_HOME; . "$GUARD_HOME/lib/common.sh"; . "$GUARD_HOME/lib/lease.sh"; . "$GUARD_HOME/lib/drain.sh"; . "$GUARD_HOME/lib/docker.sh"
    fsg_init_paths; fsg_load_config
    FSG_DETECT_DOCKER_CLI=1; FSG_DETECT_PROCESSES=1
    ps() { cat <<'EOF'
 9101 1 10:00 ttys001 docker compose exec postgres psql
 9102 1 10:00 ttys001 docker compose exec -T postgres psql -c select
 9103 1 10:00 ttys002 docker exec -it app-postgres psql
 9104 1 10:00 ?? docker exec -it app-postgres psql
 9105 1 10:00 ttys003 docker exec -i app-postgres psql
 9106 1 10:00 ttys003 docker exec -e TERM=t pg bash
 9107 1 10:00 ttys004 docker --context desktop-linux exec --tty pg sh
 9108 1 10:00 ttys004 docker-compose exec --user postgres postgres psql
 9109 1 10:00 ttys005 docker compose exec api bundle exec fsgtestrspec
 9110 1 10:00 ttys005 docker exec -it api bash -lc bundle exec fsgtestrspec spec/a_spec.rb
 9111 1 10:00 ttys005 docker compose exec api bin/rails console
 9112 1 10:00 ttys005 docker compose exec -e X=1 api bundle exec rails c
 9113 1 10:00 ttys005 docker compose exec api bin/rails db:migrate
 9114 1 10:00 ttys005 docker exec -it api top
EOF
    }
    fsg_unleased_procs | cut -f1,2 | tr '\t\n' ': ')
  eq "$out" "interactive:9101 process:9102 interactive:9103 process:9104 process:9105 process:9106 interactive:9107 interactive:9108 process:9109 process:9110 interactive:9111 interactive:9112 process:9113 process:9114 " \
    "a TTY exec of a shell or console from a terminal is interactive; anything else, -T, no TTY or no terminal is work"

  t "a drain counts only work that started before it"
  bg sleep 60; oldl=$LAST_BG; bg sleep 60; newl=$LAST_BG
  out=$(/bin/bash -c '
    FSG_HOME=$1; . "$FSG_HOME/lib/common.sh"; . "$FSG_HOME/lib/lease.sh"; . "$FSG_HOME/lib/drain.sh"; . "$FSG_HOME/lib/docker.sh"
    fsg_init_paths; fsg_load_config
    FSG_DETECT_COMMANDS=rspec; FSG_DETECT_DOCKER_CLI=1; FSG_DETECT_PROCESSES=1; FSG_DETECT_DOCKER_EXECS=0; FSG_DETECT_DOCKER_CONTAINERS=0
    ps() { if [ "$1" = -axo ]; then printf "%s\n" \
      " 9201 1 10:00 ?? ruby bin/rspec spec/old_spec.rb" \
      " 9202 1 00:05 ?? ruby bin/rspec spec/new_spec.rb" \
      " 9203 1 01-02:00:00 ttys001 docker compose exec postgres psql"
      else command ps "$@"; fi; }
    # One clock for the scans and the ages printed from them: a second that ticks
    # over between the two would add a second to every age.
    now=$(date +%s); fsg_now() { echo "$now"; }
    DRAIN_STARTED=$((now - 60)); DRAIN_EXEC_SEEDED=1
    mkdir -p "$FSG_LEASE_DIR"
    printf "pid=%s\nlstart=%s\nlabel=old-run\nstarted_epoch=%s\n" "$2" "$(fsg_lstart "$2")" $((now - 120)) > "$FSG_LEASE_DIR/$2.lease"
    printf "pid=%s\nlstart=%s\nlabel=new-run\nstarted_epoch=%s\n" "$3" "$(fsg_lstart "$3")" $((now - 1)) > "$FSG_LEASE_DIR/$3.lease"
    ids() { printf "%s\n" "$1" | cut -f2 | sed "/^$/d" | tr "\n" " "; }
    fsg_drain_scan 0
    echo "first: L=$(ids "$DS_LEASED")U=$(ids "$DS_UNLEASED")M=$(ids "$DS_MID")I=$(ids "$DS_LEFT")"
    fsg_drain_scan 0
    echo "second: M=$(ids "$DS_MID")"
    printf "%s\n" "$DS_UNLEASED" "$DS_LEFT" | fsg_work_brief brief
  ' _ "$GUARD_HOME" "$oldl" "$newl" 2>&1)
  has "$out" "first: L=$oldl U=9201 M=9202 I=9203 " "leased and unleased work split at the drain start"
  has "$out" "second: M=$newl 9202 " "a lease written after the drain start is a mid-drain run once it stays"
  has "$out" "ruby bin/rspec spec/old_spec.rb (pid 9201, 10m00s)" "named with pid and age"
  has "$out" "docker compose exec postgres psql (pid 9203, 26h00m)" "interactive session named"
  killbg "$oldl"; killbg "$newl"

  # drain_scans SCRIPT: runs SCRIPT after sourcing the drain code, with a drain
  # that began a minute ago and no exec session seeded yet.
  drain_scans() {
    /bin/bash -c '
      FSG_HOME=$1; . "$FSG_HOME/lib/common.sh"; . "$FSG_HOME/lib/lease.sh"; . "$FSG_HOME/lib/drain.sh"; . "$FSG_HOME/lib/docker.sh"
      fsg_init_paths; fsg_load_config
      DRAIN_STARTED=$(( $(date +%s) - 60 )); DRAIN_EXEC_SEEDED=0
      ids() { printf "%s\n" "$1" | cut -f2 | sed "/^$/d" | tr "\n" " "; }
      eval "$2"' _ "$GUARD_HOME" "$1" 2>&1
  }
  t "exec sessions count as started before the drain until a listing works"
  docker_default; echo "pg 1" > "$FSG_FAKE/docker/execs"; echo 2 > "$FSG_FAKE/docker/ps-hang"
  out=$(drain_scans '
    fsg_docker_engine_work > /dev/null; echo "timed out: $?"
    fsg_drain_scan 0; echo "first: U=$(ids "$DS_UNLEASED")M=$(ids "$DS_MID")."
    fsg_drain_scan 0; echo "second: U=$(ids "$DS_UNLEASED")M=$(ids "$DS_MID")."
    fsg_drain_scan 0; echo "third: U=$(ids "$DS_UNLEASED")M=$(ids "$DS_MID")."')
  has "$out" "timed out: 2" "a docker ps that times out is a failed listing"
  has "$out" "first: U=M=." "nothing is listed while docker ps hangs"
  has "$out" "second: U=pge1n1 M=." "the first listing that works seeds the pre-drain sessions"
  has "$out" "third: U=pge1n1 M=." "and they stay pre-drain"

  t "exec sessions the engine does not list hold the drain until a listing works or the cap"
  docker_default; : > "$FSG_FAKE/docker/execs"; echo 99 > "$FSG_FAKE/docker/ps-fail"
  out=$(drain_scans '
    FSG_DRAIN_POLL_S=1; FSG_UNLEASED_CAP_S=2
    fsg_docker_engine_work > /dev/null; echo "failed: $?"
    fsg_drain_wait manual abort 20 2>/dev/null; echo "abort: $? unknown=$DRAIN_UNKNOWN cap=$DRAIN_CAP_HIT."
    fsg_drain_wait emergency proceed 20 2>/dev/null; echo "proceed: $? $(fsg_drain_unknown_text cut)"
    FSG_UNLEASED_CAP_S=20; echo 2 > "$FSG_FAKE/docker/ps-fail"
    fsg_drain_wait manual abort 20 2>/dev/null; echo "listed: $? unknown=$DRAIN_UNKNOWN waited=$( [ "$DRAIN_WAITED" -ge 1 ] && echo some || echo none)."
    echo stopped > "$FSG_FAKE/docker/desktop"
    fsg_docker_engine_work > /dev/null; echo "stopped: $?"')
  has "$out" "failed: 2" "a docker ps that fails is a failed listing"
  has "$out" "abort: 4 unknown=1 cap=2." "unknown sessions hold the drain to the unleased cap, then the policy applies"
  has "$out" "proceed: 10 The Docker exec sessions and --rm and one-off containers were unknown when the drain ended" "the cut notice says they were unknown"
  has "$out" "listed: 0 unknown=0 waited=some." "a listing that works ends the wait"
  has "$out" "stopped: 0" "an engine that refuses the connection runs no session"

  t "a Docker that answers nothing lists no engine work; docker CLI work still holds the drain"
  docker_default; echo "pg 1" > "$FSG_FAKE/docker/execs"
  containers "c1 pg running healthy postgres:17 unless-stopped 0 0 0" "c3 job running none alpine:3 no 0 1 0"
  touch "$FSG_FAKE/docker/hang"
  out=$(drain_scans '
    FSG_DETECT_DOCKER_CLI=1; FSG_DETECT_PROCESSES=1; FSG_UNLEASED_CAP_S=2
    ps() { if [ "$1" = -axo ]; then echo " 9301 1 10:00 ?? docker compose run --rm api bin/setup"; else command ps "$@"; fi; }
    fsg_drain_wait manual abort 20 2>/dev/null; echo "cli: $? unknown=$DRAIN_UNKNOWN cut=$DRAIN_CUT."
    unset -f ps; FSG_DETECT_DOCKER_CLI=0; FSG_UNLEASED_CAP_S=20
    fsg_drain_wait manual abort 20 2>/dev/null; echo "wedged: $? unknown=$DRAIN_UNKNOWN."
    rm -f "$FSG_FAKE/docker/hang"
    fsg_drain_scan 0; echo "back: U=$(ids "$DS_UNLEASED")."
    echo 1 > "$FSG_FAKE/docker/ps-fail"; fsg_docker_engine_work > /dev/null; echo "ps fails, info answers: $?"
    touch "$FSG_FAKE/docker/inspect-down"; fsg_docker_engine_work > /dev/null; echo "inspect fails, info answers: $?"')
  has "$out" "cli: 4 unknown=0 cut=docker compose run --rm api bin/setup (pid 9301, " "a docker CLI run is waited for to the cap; the engine work is not unknown"
  has "$out" "wedged: 0 unknown=0." "the engine work alone does not hold the drain"
  has "$out" "back: U=pge1n1 job ." "the first listing that works seeds the pre-drain sessions"
  has "$out" "ps fails, info answers: 2" "unknown while the engine answers info"
  has "$out" "inspect fails, info answers: 2" "the same for inspect"

  t "running --rm and one-off containers are live work by their start time"
  docker_default
  containers "c1 pg running healthy postgres:17 unless-stopped 0 0 0" "c3 job running none alpine:3 no 0 1 0" \
    "c4 api-run-1 running none api:1 no 0 0 1" "c5 late running none alpine:3 no 0 1 0 $(date +%s)" "c6 old exited none alpine:3 no 0 1 0"
  out=$(drain_scans '
    fsg_drain_scan 0; echo "scan: U=$(ids "$DS_UNLEASED")M=$(ids "$DS_MID")."
    printf "%s\n" "$DS_UNLEASED" "$DS_MID" | fsg_work_brief brief
    FSG_DETECT_DOCKER_CONTAINERS=0; fsg_drain_scan 0; echo "off: U=$(ids "$DS_UNLEASED")M=$(ids "$DS_MID")."')
  has "$out" "scan: U=job api-run-1 M=late ." "started before the drain: waited for; since: mid-drain; a plain or stopped container is not work"
  has "$out" "container job (--rm, 1h00m)" "named with its kind and age"
  has "$out" "container api-run-1 (one-off, 1h00m)" "a compose run container too"
  has "$out" "off: U=M=." "FSG_DETECT_DOCKER_CONTAINERS=0 turns it off"
  out=$("$G" leases); has "$out" "container: job (--rm, up 1h00m)" "leases lists them"

  t "the drain reads what a real engine's docker inspect printed"
  docker_default; live_containers
  out=$(drain_scans '
    fsg_drain_scan 0; echo "scan: U=$(ids "$DS_UNLEASED")M=$(ids "$DS_MID")unknown=$DS_UNKNOWN."
    printf "%s\n" "$DS_UNLEASED" | fsg_work_brief brief')
  has "$out" "scan: U=fsg-probe-oneoff fsg-probe-mount fsg-probe-named fsg-probe-anon M=unknown=0." "the --rm and one-off containers; an unset label (\"\") is not one"
  has "$out" "container fsg-probe-oneoff (one-off" "a one-off named as such"
  has "$out" "container fsg-probe-anon (--rm" "a --rm container named as such"

  t "a one-off label with a space, tab or newline hides no exec session or start time"
  docker_default; echo "job 1" > "$FSG_FAKE/docker/execs"
  containers "c1 pg running healthy postgres:17 unless-stopped 0 0 0" "c3 job running none alpine:3 no 0 1 0"
  for w in space tab newline; do
    case $w in space) printf 'x y' ;; tab) printf 'x\ty' ;; *) printf 'x\ny' ;; esac > "$FSG_FAKE/docker/label-c3"
    out=$(drain_scans '
      fsg_drain_scan 0; echo "scan: U=$(ids "$DS_UNLEASED")unknown=$DS_UNKNOWN."
      printf "%s\n" "$DS_UNLEASED" | fsg_work_brief brief')
    has "$out" "scan: U=job jobe1n1 unknown=0." "$w: the --rm container and its exec session"
    has "$out" "container job (--rm, 1h00m)" "$w: with its start time"
  done

  t "an engine-work row that is not whole leaves the engine's work unknown"
  docker_default
  containers "c1 pg running healthy postgres:17 unless-stopped 0 0 0" "c3 job running none alpine:3 no 0 1 0"
  for row in '/job\ttrue' '/job\ttrue\t""\t2026-10-23T02:33:34Z\tjob e1' '/job\ttrue\toneoff=\t2026-10-23T02:33:34Z'; do
    printf '%b\n' "$row" > "$FSG_FAKE/docker/work-text-c3"
    out=$(drain_scans 'fsg_docker_engine_work > /dev/null; echo "rc=$?"')
    has "$out" "rc=2" "$row: unknown while Docker answers"
  done
  rm -f "$FSG_FAKE/docker/work-text-c3"
  out=$(drain_scans 'fsg_docker_engine_work > /dev/null; echo "rc=$?"'); has "$out" "rc=0" "whole rows list"

  t "an exec session listed by one scan only is not mid-drain"
  docker_default; : > "$FSG_FAKE/docker/execs"
  out=$(drain_scans '
    fsg_drain_scan 0
    echo "pg 1" > "$FSG_FAKE/docker/execs-once"
    fsg_drain_scan 0; echo "probe: M=$(ids "$DS_MID")U=$(ids "$DS_UNLEASED")cut=$(fsg__drain_cut_list)."
    fsg_drain_scan 0; echo "gone: M=$(ids "$DS_MID")."
    echo "pg 1" > "$FSG_FAKE/docker/execs"
    fsg_drain_scan 0; echo "new: M=$(ids "$DS_MID")."
    fsg_drain_scan 0; echo "stays: M=$(ids "$DS_MID")cut=$(fsg__drain_cut_list)."')
  has "$out" "probe: M=U=cut=." "a session seen once is neither waited for nor cut"
  has "$out" "gone: M=." "and is forgotten"
  has "$out" "new: M=." "a session started mid-drain is not counted at its first scan"
  has "$out" "stays: M=pge1n1 cut=pg exec session pge1n1 - started mid-drain." "but is once the next scan lists it too"

  t "a run waiting for a drain is not live work"
  app_copy
  mkdir -p "$C/bin"
  printf '#!/bin/sh\n. "%s/lib/lease.sh"\nfsg_lease_acquire held-snippet || exit $?\n' "$GUARD_HOME" > "$C/bin/fsgtestrspec"
  chmod +x "$C/bin/fsgtestrspec"
  bg sleep 60; owner=$LAST_BG; pending "$owner" 600
  bg env FSG_RUN_MAX_WAIT_S=6 "$C/bin/fsgtestrspec" 2>/dev/null; hp=$LAST_BG
  waitfor 4 test -f "$FSG_STATE_DIR/drain/leases/$hp.held" && ok || bad "a waiting run leaves a held marker"
  out=$("$G" leases); hasnt "$out" "pid $hp" "the held run is not counted as running work"
  killbg "$hp"; killbg "$owner"

  t "docker exec sessions"
  docker_default; containers "c1 pg running healthy postgres:17 unless-stopped 0" "c2 redis running none redis:7 unless-stopped 0" \
    "c3 api running none api:1 unless-stopped 0" "c4 web running none api:1 unless-stopped 0"
  printf 'pg 2\nredis 1 tty\napi 1 tty bundle exec fsgtestrspec\nweb 1 tty bash -c bundle exec fsgtestrspec\n' > "$FSG_FAKE/docker/execs"
  out=$("$G" leases)
  eq "$(printf '%s\n' "$out" | grep -c 'exec: pg exec session')" 2 "exec sessions are live work"
  has "$out" "interactive, left alone: redis exec session redise2n1" "a session with a TTY for a console is not waited for"
  has "$out" "exec: api exec session apie3n1" "a session with a TTY for a test run is work"
  has "$out" "exec: web exec session webe4n1" "so is a shell that runs one"
fi

# ======================================================================== heal
if ! skip_case heal; then
  t "heal runs sudo by its fixed path, not through PATH"
  docker_default; install_fake || bad "install"
  # The agent's PATH starts with the stubs; the fixed-path sudo is this stand-in.
  stub_dir "$C/rt"
  printf '#!/bin/bash\necho "ROOT-TOOL sudo $*" >> "$FSG_FAKE/calls.log"\nexec "%s/sudo" "$@"\n' "$STUBS" > "$C/rt/sudo.new"
  chmod +x "$C/rt/sudo.new"; mv -f "$C/rt/sudo.new" "$C/rt/sudo"
  agent_env FSG_TEST_ROOT_TOOLS="$C/rt"
  mem 3G; : > "$FSG_FAKE/calls.log"
  FSG_TEST_ROOT_TOOLS="$C/rt" heal > "$C/o" 2>&1; eq $? 0 "healed"
  has "$(cat "$FSG_FAKE/calls.log")" "ROOT-TOOL sudo -n -l $FSG_PREFIX" "the precheck's sudo -n -l"
  has "$(cat "$FSG_FAKE/calls.log")" "ROOT-TOOL sudo -n $FSG_PREFIX/usr/local/libexec/fseventsd-guard-restart" "the helper call"

  for v in A B C none; do
    t "heal variant $v"
    docker_default; install_fake || bad "install"
    mem 3G; : > "$FSG_FAKE/calls.log"
    out=$(heal --docker-variant $v 2>&1); rc=$?
    eq $rc 0 "exit ($out)"
    L="$FSG_FAKE/calls.log"
    case $v in
      A) before "$L" "docker stop -t 30 c1 c2" "sudo -n $FSG_PREFIX"; before "$L" "sudo -n $FSG_PREFIX" "docker start c1 c2"
         hasnt "$(cat "$L")" "docker desktop stop" "A leaves Desktop running" ;;
      B) before "$L" "docker desktop stop" "sudo -n $FSG_PREFIX"; before "$L" "sudo -n $FSG_PREFIX" "docker desktop start" ;;
      C) before "$L" "sudo -n $FSG_PREFIX" "docker desktop restart"; hasnt "$(cat "$L")" "docker desktop stop" "C does not stop first" ;;
      none) hasnt "$(cat "$L")" "docker stop" "none: no stop"; hasnt "$(cat "$L")" "docker desktop stop" "none: Desktop not stopped"
         hasnt "$(cat "$L")" "docker desktop start" "none: Desktop not started" ;;
    esac
    before "$L" "kill -TERM 4242" "docker run --rm"
    eq "$(awk '$3 != "running"' "$FSG_FAKE/docker/containers")" "" "every container running again"
    has "$(cat "$FSG_STATE_DIR/last-heal")" " healed manual $v " "last-heal record"
    absent "$FSG_STATE_DIR/drain/pending" "drain released"; absent "$FSG_STATE_DIR/heal.lock" "lock released"
    absent "$FSG_STATE_DIR/docker-intent" "Docker intent cleared"
    has "$(cat "$FSG_FAKE/notifications.log")" "fseventsd healed" "success notification"
    has "$(cat "$FSG_FAKE/notifications.log")" "Time Machine" "costs in the notification"
    has "$(cat "$FSG_FAKE/notifications.log")" "If a session stops seeing file changes after the heal, restart it." "watcher advice in the notification"
    grep -q '^bind_mount=ok' "$(cat "$FSG_STATE_DIR/last-heal-dir")/result.txt" && ok || bad "bind mount verified"
  done

  t "heal fallbacks"
  docker_default; rm "$FSG_FAKE/docker/desktop"; touch "$FSG_FAKE/docker/engine-ok"
  install_fake; mem 3G; : > "$FSG_FAKE/calls.log"
  heal --docker-variant B >/dev/null 2>&1; eq $? 0 "B on a non-Desktop engine"
  before "$FSG_FAKE/calls.log" "docker stop" "sudo -n /"; has "$(cat "$FSG_LOG")" "docker variant B -> A" "fallback logged"
  rm "$FSG_FAKE/docker/engine-ok"; echo 4242 > "$FSG_FAKE/fsev/pids"; mem 3G; rm -f "$FSG_PREFIX/Library/Logs/fseventsd-guard/last-restart"
  : > "$FSG_FAKE/calls.log"; heal >/dev/null 2>&1; eq $? 0 "Docker not running: heal anyway"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "docker stop" "no Docker actions"

  t "the drain marker names the Docker step the heal takes, not the one it planned"
  docker_default; install_fake; mem 3G
  docker desktop stop >/dev/null 2>&1
  echo "$FSG_STATE_DIR/drain/pending" > "$FSG_FAKE/docker/snap"
  bg "$G" run --label first -- sleep 4; sleep 1
  heal_bg() { "$G" heal --docker-variant B > "$C/heal-bg.out" 2>&1; }
  bg heal_bg; hp=$LAST_BG
  waitfor 20 grep -qs '^phase=draining' "$FSG_STATE_DIR/drain/pending" || bad "the heal drains"
  has "$(cat "$FSG_STATE_DIR/drain/pending")" "variant=skip" "planned with Docker Desktop stopped: no Docker step"
  # Docker Desktop started during the drain: the heal takes step B after all.
  docker desktop start >/dev/null 2>&1
  wait "$hp"; eq $? 0 "healed"; agent_wait
  has "$(cat "$FSG_FAKE/docker/snap.out" 2>/dev/null)" "phase=docker-before" "the marker at the Docker step"
  has "$(cat "$FSG_FAKE/docker/snap.out" 2>/dev/null)" "variant=B" "names step B"

  t "heal refusals before the drain"
  docker_default
  heal > "$C/o" 2>&1; eq $? 9 "not installed"
  has "$(cat "$C/o")" "only the agent heals: run fseventsd-guard install" "the caller names the fix"
  install_fake
  mem 50M; : > "$FSG_FAKE/calls.log"; heal >/dev/null 2>&1; eq $? 6 "healthy: nothing to do"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "sudo -n /" "no restart attempted"; absent "$FSG_STATE_DIR/drain/pending" "no drain"
  echo stalled > "$FSG_FAKE/probe"; heal > "$C/o" 2>&1; eq $? 6 "stalled below the floor: helper would refuse"
  has "$(cat "$C/o")" "sudo kill -TERM" "manual fix offered"; rm "$FSG_FAKE/probe"
  mem 3G; date +%s > "$FSG_PREFIX/Library/Logs/fseventsd-guard/last-restart"
  heal >/dev/null 2>&1; eq $? 6 "helper rate limit seen before the drain"
  rm "$FSG_PREFIX/Library/Logs/fseventsd-guard/last-restart"
  heal --trigger emergency >/dev/null 2>&1; eq $? 64 "emergency heals are the agent's own"
  heal --trigger trial >/dev/null 2>&1; eq $? 64 "trials go through trial"

  t "heal dry-run"
  docker_default; install_fake; mem 3G; : > "$FSG_FAKE/calls.log"
  out=$("$G" heal --dry-run --docker-variant A); rc=$?
  eq $rc 0 "would proceed"
  has "$out" "5. docker before-step (A): docker stop -t 30 c1 c2" "plan step 5"
  has "$out" "6. restart: sudo -n $FSG_PREFIX/usr/local/libexec/fseventsd-guard-restart" "plan step 6"
  has "$out" "8. docker after-step (A): docker start c1 c2" "plan step 8"
  has "$out" "agent queue: 0 request(s) waiting" "the queue is shown"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "sudo -n /" "dry-run never runs the helper"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "docker stop" "dry-run stops nothing"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "launchctl kickstart" "dry-run queues nothing"
  absent "$FSG_STATE_DIR/drain/pending" "dry-run sets no drain"
  out=$("$G" heal --dry-run --docker-variant B); has "$out" "docker desktop stop --timeout 10" "B plan"
  out=$("$G" heal --dry-run --docker-variant C); has "$out" "nothing (variant C acts after the restart)" "C plan"
  mem 50M; "$G" heal --dry-run >/dev/null; eq $? 6 "dry-run reports a refusal"
  "$G" heal --docker-variant X >/dev/null 2>&1; eq $? 64 "bad variant"

  t "heal drains live work first"
  docker_default; install_fake; mem 3G
  bg "$G" run --label slow -- sleep 3
  sleep 1; : > "$FSG_FAKE/calls.log"
  s=$(date +%s); heal --docker-variant A > "$C/o" 2>&1; rc=$?
  eq $rc 0 "healed after the lease ended"; [ $(( $(date +%s) - s )) -ge 1 ] && ok || bad "it waited for the lease"
  has "$(cat "$FSG_LOG")" "DRAIN drained" "drain logged"

  t "heal drain cap: abort"
  docker_default; install_fake; mem 600M
  bg "$G" run --label long -- sleep 60; sleep 1; : > "$FSG_FAKE/calls.log"
  heal --drain-cap 2 > "$C/o" 2>&1; eq $? 4 "manual heal gives up at the cap"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "sudo -n /" "nothing restarted"
  absent "$FSG_STATE_DIR/drain/pending" "drain released"
  has "$(cat "$FSG_FAKE/notifications.log")" "heal given up" "notification"
  killbg "$LAST_BG"

  t "heal drain cap: emergency proceeds"
  docker_default; install_fake; mem 3G
  bg "$G" run --label long -- sleep 60; sleep 1
  FSG_DRAIN_CAP_S=2 "$G" tick > "$C/o" 2>&1; eq $? 0 "the agent's emergency heal proceeds at the cap"
  has "$(cat "$FSG_FAKE/notifications.log")" "cutting running work" "cut notification"
  grep -q 'drain_cut=.*long' "$(cat "$FSG_STATE_DIR/last-heal-dir")/result.txt" && ok || bad "cut run recorded"
  killbg "$LAST_BG"

  t "heal emergency ceiling"
  docker_default; install_fake; mem 9G
  bg "$G" run --label long -- sleep 60; sleep 1
  s=$(date +%s); "$G" tick > "$C/o" 2>&1; eq $? 0 "healed"
  [ $(( $(date +%s) - s )) -lt 15 ] && ok || bad "did not wait for the 20 s cap"
  has "$(cat "$FSG_LOG")" "emergency ceiling" "ceiling logged"
  killbg "$LAST_BG"

  t "runs wait while a heal drains"
  docker_default; install_fake; mem 3G
  bg "$G" run --label first -- sleep 3; sleep 1
  heal_bg() { "$G" heal --docker-variant A > "$C/heal-bg.out" 2>&1; }
  bg heal_bg; hp=$LAST_BG
  waitfor 20 test -f "$FSG_STATE_DIR/drain/pending" || bad "the agent's heal drains"
  s=$(date +%s); "$G" run --label second -- true 2> "$C/err"; rc=$?
  eq $rc 0 "the held run starts after the heal"; has "$(cat "$C/err")" "holding 'second'" "held message"
  wait "$hp"; eq $? 0 "heal result"
fi

# ======================================================================== request
if ! skip_case request; then
  t "a killed waiting caller neither stops the heal nor strands Docker"
  docker_default; install_fake; mem 3G
  echo 4 > "$FSG_FAKE/sudo-delay"
  "$G" heal --docker-variant B > "$C/heal.out" 2>&1 & hp=$!; BG_PIDS="$BG_PIDS $hp"
  waitfor 20 grep -qs '^phase=restarting' "$FSG_STATE_DIR/drain/pending" || bad "the heal reached the restart"
  kill -TERM "$hp"; wait "$hp"; eq $? 130 "the caller ends by the signal"
  has "$(cat "$C/heal.out")" "Re-attach: fseventsd-guard heal --result" "it says how to re-attach"
  id=$(basename "$(ls "$FSG_STATE_DIR"/requests/*.run)" .run)
  [ -n "$(agent_pid)" ] && ok || bad "the agent's tick goes on"
  out=$("$G" heal --result "$id" 2>/dev/null); eq $? 0 "re-attached: healed"
  has "$out" "healed in" "the summary"
  agent_wait
  eq "$(cat "$FSG_FAKE/docker/desktop")" running "Docker running again"
  eq "$(awk '$3 != "running"' "$FSG_FAKE/docker/containers")" "" "every container running again"
  absent "$FSG_STATE_DIR/docker-intent" "Docker verified"; absent "$FSG_STATE_DIR/drain/pending" "drain released"
  "$G" heal --result "$id" --no-wait >/dev/null 2>&1; eq $? 0 "--result --no-wait of a finished request returns its code"
  "$G" heal --result 20990101T000000Z-1 >/dev/null 2>&1; eq $? 64 "unknown id"

  t "a waiting caller killed with its whole process group neither stops the heal nor strands Docker"
  docker_default; install_fake; mem 3G
  echo 4 > "$FSG_FAKE/sudo-delay"
  # As a wave's timeout -k does: the caller leads its own group, and the signal goes
  # to every process in it.
  /usr/bin/perl -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
    "$G" heal --docker-variant B > "$C/heal.out" 2>&1 & hp=$!; BG_PIDS="$BG_PIDS $hp"
  waitfor 20 grep -qs '^phase=restarting' "$FSG_STATE_DIR/drain/pending" || bad "the heal reached the restart"
  ap=$(agent_pid)
  kill -TERM -- "-$hp"; wait "$hp"; eq $? 130 "the caller ends by the signal"
  eq "$(agent_pid)" "$ap" "the agent's tick goes on"
  agent_wait
  id=$(basename "$(ls "$FSG_STATE_DIR"/requests/*.run)" .run)
  eq "$(sed -n 's/^exit=//p' "$FSG_STATE_DIR/requests/$id.result")" 0 "the heal healed"
  eq "$(cat "$FSG_FAKE/docker/desktop")" running "Docker running again"
  eq "$(awk '$3 != "running"' "$FSG_FAKE/docker/containers")" "" "every container running again"
  has "$(cat "$FSG_FAKE/calls.log")" "docker run --rm" "Docker verified"
  absent "$FSG_STATE_DIR/docker-intent" "intent cleared"; absent "$FSG_STATE_DIR/drain/pending" "drain released"

  t "two requests run in order"
  docker_default; install_fake; mem 600M
  touch "$FSG_FAKE/kickstart-off"
  a=$("$G" heal --docker-variant A --no-wait 2>/dev/null); eq $? 12 "queued (--no-wait)"
  sleep 1
  b=$("$G" heal --docker-variant B --force --no-wait 2>/dev/null); eq $? 12 "second queued"
  "$G" heal --result "$a" --no-wait > "$C/o" 2>/dev/null; eq $? 12 "still queued"
  has "$(cat "$C/o")" "$a queued" "says queued"
  out=$("$G" status --json); eq "$(jget "$out" 'd["requests"]["queued"]')" 2 "status counts the queue"
  rm -f "$FSG_FAKE/kickstart-off"
  "$G" tick >/dev/null 2>&1
  eq "$(sed -n 's/^exit=//p' "$FSG_STATE_DIR/requests/$a.result")" 0 "first healed"
  # The second, forced past the precheck, meets the helper's own 30-minute limit.
  eq "$(sed -n 's/^exit=//p' "$FSG_STATE_DIR/requests/$b.result")" 7 "second (forced) ran too: the helper refused it"
  before "$FSG_LOG" "REQUEST $a run" "REQUEST $b run"
  before "$FSG_LOG" "REQUEST $a result" "REQUEST $b run"
  eq "$(grep -c 'HEAL start' "$FSG_LOG")" 2 "two heals, one after the other"

  t "a request queued behind a heal joins it"
  docker_default; install_fake; mem 600M
  # The heal ends seconds after the second request was written.
  touch "$FSG_FAKE/kickstart-off"; echo 2 > "$FSG_FAKE/sudo-delay"
  a=$("$G" heal --no-wait 2>/dev/null); sleep 1; b=$("$G" heal --trigger wave --no-wait 2>/dev/null)
  rm -f "$FSG_FAKE/kickstart-off"
  "$G" tick >/dev/null 2>&1
  out=$("$G" heal --result "$b" 2>/dev/null); eq $? 0 "the wave request returns the heal's result"
  has "$out" "joined the manual heal" "joined"
  eq "$(grep -c 'HEAL start' "$FSG_LOG")" 1 "one heal, not two"
  eq "$(grep -c 'DRAIN begin' "$FSG_LOG")" 1 "one drain"

  t "a request written in the second a heal ended does not join it"
  docker_default; install_fake; mem 600M
  touch "$FSG_FAKE/kickstart-off"
  id=$("$G" heal --no-wait 2>/dev/null)
  t0=$(sed -n 's/^time=//p' "$FSG_STATE_DIR/requests/$id.req")
  printf '%s healed manual B 3 %s\n' "$t0" "$C/no-record" > "$FSG_STATE_DIR/last-heal"
  rm -f "$FSG_FAKE/kickstart-off"
  "$G" tick >/dev/null 2>&1
  hasnt "$(cat "$FSG_STATE_DIR/requests/$id.result")" "joined" "not joined"
  eq "$(sed -n 's/^exit=//p' "$FSG_STATE_DIR/requests/$id.result")" 0 "it ran its own heal"
  eq "$(grep -c 'HEAL start' "$FSG_LOG")" 1 "one heal"

  t "the caller needs a loaded agent that speaks its protocol"
  docker_default; install_fake; mem 3G
  launchctl bootout "gui/$(id -u)/io.github.ruslantar.fseventsd-guard"
  heal > "$C/o" 2>&1; eq $? 9 "unloaded agent"
  has "$(cat "$C/o")" "launchctl bootstrap gui/$(id -u)" "names the fix"
  trial --variant A > "$C/o" 2>&1; eq $? 9 "trial too"
  launchctl bootstrap "gui/$(id -u)" "$FSG_LAUNCH_AGENTS_DIR/io.github.ruslantar.fseventsd-guard.plist"
  sed '/^FSG_REQUEST_PROTOCOL=/d' "$FSG_STATE_DIR/app/lib/common.sh" > "$C/common" && cat "$C/common" > "$FSG_STATE_DIR/app/lib/common.sh"
  : > "$FSG_FAKE/calls.log"
  heal > "$C/o" 2>&1; eq $? 9 "an agent copy that predates heal requests"
  has "$(cat "$C/o")" "predates heal requests" "says so"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "sudo -n /" "nothing healed in the caller"
  absent "$FSG_STATE_DIR/requests" "nothing queued"
  "$G" doctor --prefix "$FSG_PREFIX" > "$C/doc.out" 2>&1
  has "$(cat "$C/doc.out")" "WARN  the installed agent predates heal requests" "doctor warns"
  out=$("$G" status --json 2>/dev/null); eq "$(jget "$out" 'd["agent"]["requests"]')" False "status: agent.requests"

  t "a request the agent does not take is withdrawn"
  docker_default; install_fake; mem 600M
  touch "$FSG_FAKE/kickstart-off"; : > "$FSG_FAKE/calls.log"
  s=$(date +%s); FSG_AGENT_INTERVAL_S=2 heal > "$C/o" 2>&1; eq $? 10 "exit 10 after two agent intervals"
  [ $(( $(date +%s) - s )) -lt 15 ] && ok || bad "bounded wait"
  has "$(cat "$C/o")" "did not take request" "message"
  ls "$FSG_STATE_DIR"/requests/*.withdrawn >/dev/null 2>&1 && ok || bad "renamed aside"
  "$G" heal --result "$(basename "$(ls "$FSG_STATE_DIR"/requests/*.withdrawn)" .withdrawn)" >/dev/null 2>&1; eq $? 10 "re-attaching says withdrawn"
  [ "$(grep -c 'launchctl kickstart' "$FSG_FAKE/calls.log")" -ge 1 ] && ok || bad "kicked"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "sudo -n /" "nothing stopped"
  rm -f "$FSG_FAKE/kickstart-off"; "$G" tick >/dev/null 2>&1
  hasnt "$(cat "$FSG_FAKE/calls.log")" "sudo -n /" "a later tick does not run a withdrawn request"

  t "a request that ticks run but never claim is withdrawn at FSG_REQUEST_MAX_AGE_S"
  docker_default; install_fake; mem 600M
  # The app copy's ticks cannot claim a request (as if the rename failed), and each
  # one runs long enough for the waiting caller to see it.
  A=$FSG_STATE_DIR/app/lib/heal.sh
  sed 's|if ! mv "$f" "$FSG_REQ_DIR/$id.run" 2>/dev/null; then|if ! { sleep 2; false; }; then|' "$A" > "$C/h" && cat "$C/h" > "$A"
  grep -q 'sleep 2; false' "$A" && ok || bad "the app copy cannot claim"
  : > "$FSG_FAKE/calls.log"
  # Kicked every 10 s, the ticks keep the 20 s idle bound from ever running out.
  FSG_AGENT_INTERVAL_S=10 FSG_REQUEST_MAX_AGE_S=5 "$G" heal > "$C/o" 2>&1 & wp=$!; BG_PIDS="$BG_PIDS $wp"
  waitfor 40 gone "$wp" && ok || { bad "bounded wait, although ticks keep running"; kill -KILL "$wp"; }
  wait "$wp"; eq $? 10 "withdrawn"
  has "$(cat "$C/o")" "stayed unclaimed for more than 5s" "says why"
  [ "$(grep -c 'launchctl kickstart' "$FSG_FAKE/calls.log")" -ge 1 ] && ok || bad "kicked"
  has "$(cat "$FSG_LOG")" "cannot claim request" "the ticks ran"
  ls "$FSG_STATE_DIR"/requests/*.withdrawn >/dev/null 2>&1 && ok || bad "renamed aside"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "sudo -n /" "nothing stopped"

  t "a request queued behind a heal that drains past the withdraw bound joins it"
  docker_default; install_fake; mem 600M
  bg "$G" run --label long -- sleep 14; lr=$LAST_BG; sleep 1
  "$G" heal --drain-cap 30 > "$C/a.out" 2>&1 & hp=$!; BG_PIDS="$BG_PIDS $hp"
  waitfor 20 grep -qs '^phase=draining' "$FSG_STATE_DIR/drain/pending" || bad "the agent's heal drains"
  # The withdraw bound is 4 s; the drain holds the agent's tick for about 10 s more.
  FSG_AGENT_INTERVAL_S=2 "$G" heal --trigger wave > "$C/w.out" 2>&1 & wp=$!; BG_PIDS="$BG_PIDS $wp"
  b=$("$G" heal --trigger wave --no-wait 2>/dev/null); sleep 5
  FSG_AGENT_INTERVAL_S=2 "$G" heal --result "$b" > "$C/b.out" 2>&1; eq $? 0 "a re-attached request waits for the busy tick, then joins ($(tail -n 1 "$C/b.out"))"
  wait "$wp"; eq $? 0 "a waiting wave caller joins the heal ($(tail -n 1 "$C/w.out"))"
  has "$(cat "$C/w.out")" "joined the manual heal" "joined"
  wait "$hp"; eq $? 0 "the first caller heals"
  absent "$FSG_STATE_DIR/requests/$b.withdrawn" "nothing withdrawn"
  hasnt "$(cat "$FSG_LOG")" "withdrawn" "nothing withdrawn (log)"
  eq "$(grep -c 'HEAL start' "$FSG_LOG")" 1 "one heal"
  killbg "$lr"

  t "a caller waiting on a request whose tick was killed outright stops when no tick comes"
  docker_default; install_fake; mem 600M
  mkdir -p "$FSG_STATE_DIR/requests"
  bg sleep 60; dead=$LAST_BG; dl=$(lstart "$dead"); killbg "$dead"
  run_req() { # id
    printf 'id=%s\ntrigger=manual\ndrain_cap=20\non_cap=abort\ndocker_variant=B\nforce=0\ntrial_label=\nrequester_pid=%s\nrequester_lstart=%s\nrequester_chain=\ntime=%s\nclaimed_pid=%s\nclaimed_lstart=%s\n' \
      "$1" "$dead" "$dl" "$(date +%s)" "$dead" "$dl" > "$FSG_STATE_DIR/requests/$1.run"
  }
  touch "$FSG_FAKE/kickstart-off"; : > "$FSG_FAKE/calls.log"
  run_req 20260101T000001Z-1
  FSG_AGENT_INTERVAL_S=2 "$G" heal --result 20260101T000001Z-1 > "$C/o" 2>&1 & wp=$!; BG_PIDS="$BG_PIDS $wp"
  waitfor 15 gone "$wp" && ok || { bad "bounded wait"; kill -KILL "$wp"; }
  wait "$wp"; eq $? 130 "130 after two agent intervals without a tick"
  has "$(cat "$C/o")" "was stopped without a result" "says why"
  has "$(cat "$C/o")" "Re-attach: fseventsd-guard heal --result 20260101T000001Z-1" "re-attach hint"
  [ "$(grep -c 'launchctl kickstart' "$FSG_FAKE/calls.log")" -ge 1 ] && ok || bad "kicked the agent"
  launchctl bootout "gui/$(id -u)/io.github.ruslantar.fseventsd-guard"
  "$G" heal --result 20260101T000001Z-1 > "$C/o" 2>&1 & wp=$!; BG_PIDS="$BG_PIDS $wp"
  waitfor 4 gone "$wp" && ok || { bad "at once"; kill -KILL "$wp"; }
  wait "$wp"; eq $? 130 "130 at once with the agent unloaded"
  has "$(cat "$C/o")" "is not loaded" "names the unloaded agent"
  launchctl bootstrap "gui/$(id -u)" "$FSG_LAUNCH_AGENTS_DIR/io.github.ruslantar.fseventsd-guard.plist"
  rm -f "$FSG_FAKE/kickstart-off"
  out=$("$G" heal --result 20260101T000001Z-1 2>/dev/null); eq $? 130 "a kicked tick ends it with 130"
  has "$(cat "$FSG_STATE_DIR/requests/20260101T000001Z-1.result")" "was stopped during this request" "the agent's own 130"
  agent_wait

  t "a tick stopped between requests or after a heal ended reports that request's own result"
  docker_default; install_fake; mem 600M
  mkdir -p "$FSG_STATE_DIR/requests"
  # A tick that a TERM reaches at a chosen point: before a request's own heal starts
  # (the last heal's record is still set), or after its heal returned.
  cat > "$C/tick-sig.sh" <<'EOS'
set -u
FSG_HOME=$1 REC=$3
for l in common lease measure drain docker request heal install; do . "$FSG_HOME/lib/$l.sh"; done
fsg_init_paths; fsg_load_config
fsg_tick_check() { return 0; }
case $2 in
  between) HEAL_DIR=$REC
    fsg_req_join() { kill -TERM $$; return 1; } ;;
  after) fsg_heal_main() { echo "healed in 1s (stand-in)"; HEAL_DIR=$REC; return 0; }
    eval "fsg__real_finish() $(declare -f fsg_req_finish | tail -n +2)"
    fsg_req_finish() { [ -n "${SIG_SENT:-}" ] || { SIG_SENT=1; kill -TERM $$; }; fsg__real_finish "$@"; } ;;
esac
fsg_cmd_tick
EOS
  sig_req() { # id
    printf 'id=%s\ntrigger=manual\ndrain_cap=20\non_cap=abort\ndocker_variant=B\nforce=0\ntrial_label=\nrequester_pid=%s\nrequester_lstart=%s\nrequester_chain=\ntime=%s\n' \
      "$1" "$$" "$(lstart $$)" "$(date +%s)" > "$FSG_STATE_DIR/requests/$1.req"
  }
  sig_req 20260101T000001Z-1
  bash "$C/tick-sig.sh" "$GUARD_HOME" between "$C/last-heal-record" >/dev/null 2>&1
  r1=$FSG_STATE_DIR/requests/20260101T000001Z-1.result
  eq "$(sed -n 's/^exit=//p' "$r1")" 130 "stopped before its heal: 130"
  hasnt "$(cat "$r1")" "$C/last-heal-record" "it does not name the previous heal's record"
  sig_req 20260101T000002Z-2
  bash "$C/tick-sig.sh" "$GUARD_HOME" after "$C/this-heal-record" >/dev/null 2>&1
  r2=$FSG_STATE_DIR/requests/20260101T000002Z-2.result
  eq "$(sed -n 's/^exit=//p' "$r2")" 0 "stopped after its heal ended: the heal's code"
  has "$(cat "$r2")" "the agent was stopped after this heal ended" "says so"
  has "$(cat "$r2")" "record=$C/this-heal-record" "its own record"
  absent "$FSG_STATE_DIR/heal.lock" "lock released"

  t "a manual tick racing the agent's tick is refused by the lock"
  docker_default; install_fake; mem 600M
  bg "$G" run --label long -- sleep 60; lr=$LAST_BG; sleep 1
  "$G" heal --drain-cap 30 > "$C/h.out" 2>&1 & hp=$!; BG_PIDS="$BG_PIDS $hp"
  waitfor 20 grep -qs '^phase=draining' "$FSG_STATE_DIR/drain/pending" || bad "the agent's heal drains"
  ap=$(agent_pid)
  "$G" tick > "$C/t.out" 2>&1; eq $? 0 "the manual tick ends at once"
  has "$(cat "$FSG_LOG")" "TICK the heal lock is held by pid $ap" "it found the agent's lock"
  has "$(cat "$FSG_STATE_DIR/heal.lock/owner" 2>/dev/null)" "pid=$ap" "the lock is still the agent's"
  eq "$(grep -c 'HEAL start' "$FSG_LOG")" 1 "one heal"
  killbg "$lr"; wait "$hp"; eq $? 0 "the agent's heal heals"

  t "an FSG_* knob exported in the caller does not reach the agent's heal"
  docker_default; install_fake; mem 3G; : > "$FSG_FAKE/calls.log"
  FSG_VERIFY_BIND_MOUNT=0 heal --docker-variant A > "$C/o" 2>&1; eq $? 0 "healed"
  has "$(cat "$FSG_FAKE/calls.log")" "docker run --rm" "the agent verified the bind mount all the same"
  grep -q '^bind_mount=ok' "$(cat "$FSG_STATE_DIR/last-heal-dir")/result.txt" && ok || bad "recorded as verified, not disabled"

  t "a leased workflow that asks for a heal does not wait on its own lease"
  docker_default; install_fake; mem 3G
  s=$(date +%s); "$G" run --label workflow -- /bin/bash -c '"$1" heal --docker-variant A' _ "$G" > "$C/o" 2>&1; rc=$?
  agent_wait
  eq $rc 0 "healed ($(tail -n 1 "$C/o"))"
  [ $(( $(date +%s) - s )) -lt 20 ] && ok || bad "did not wait for its own lease to the cap"
  hasnt "$(cat "$FSG_LOG")" "DRAIN waiting" "nothing to wait for"

  t "a leased requester killed mid-wait: its workflow's lease then holds the drain"
  docker_default; install_fake; mem 600M
  bg "$G" run --label other -- sleep 60; op=$LAST_BG; sleep 1
  # The workflow goes on after its heal call, as a wave started on a timeout would.
  bg "$G" run --label workflow -- /bin/bash -c '"$1" heal --trigger wave --drain-cap 8 --docker-variant B > "$2/w.out" 2>&1; exec sleep 60' _ "$G" "$C"; wp=$LAST_BG
  waitfor 20 grep -qs '^phase=draining' "$FSG_STATE_DIR/drain/pending" || bad "the heal drains for the other run"
  id=$(basename "$(ls "$FSG_STATE_DIR"/requests/*.run)" .run)
  rp=$(sed -n 's/^requester_pid=//p' "$FSG_STATE_DIR/requests/$id.run")
  : > "$FSG_FAKE/calls.log"
  # As a wave does: it starts once its heal call has ended.
  kill -TERM "$rp"; waitfor 10 eval "! /bin/ps -p $rp >/dev/null 2>&1" || bad "the caller ends"
  killbg "$op"
  agent_wait
  eq "$(sed -n 's/^exit=//p' "$FSG_STATE_DIR/requests/$id.result")" 4 "the wave heal gives up at its cap"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "desktop stop" "Docker not stopped under the workflow"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "sudo -n /" "nothing restarted"
  has "$(cat "$FSG_LOG")" "DRAIN requester pid=$rp waits=1 not waiting" "the drain sees the requester stop waiting"
  has "$(cat "$FSG_STATE_DIR/requests/$id.log")" "requester (pid $rp) stopped waiting" "the heal output says so"
  has "$(cat "$C/w.out")" "no longer exempts the leases of this process and its parents" "the caller says its leases now hold the heal"
  killbg "$wp"

  t "a leased requester that does not wait exempts nothing"
  docker_default; install_fake; mem 600M
  bg "$G" run --label workflow -- /bin/bash -c 'id=$("$1" heal --trigger wave --no-wait --drain-cap 5 --docker-variant B 2> "$2/w.err"); echo "$id" > "$2/id"; exec sleep 60' _ "$G" "$C"; wp=$LAST_BG
  waitfor 20 test -s "$C/id" || bad "queued"
  id=$(cat "$C/id")
  grep -q '^requester_waits=0$' "$FSG_STATE_DIR/requests/$id."r* && ok || bad "the request says its caller does not wait"
  agent_wait
  eq "$(sed -n 's/^exit=//p' "$FSG_STATE_DIR/requests/$id.result")" 4 "the workflow's own lease holds the wave heal to its cap"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "desktop stop" "Docker not stopped under the workflow"
  has "$(cat "$C/w.err")" "does not exempt the leases of this process and its parents" "the caller is told"
  killbg "$wp"

  t "the agent drops stale requests and trials whose requester is gone"
  docker_default; install_fake; mem 600M
  mkdir -p "$FSG_STATE_DIR/requests"; : > "$FSG_FAKE/calls.log"
  bg sleep 60; dead=$LAST_BG; dl=$(lstart "$dead"); killbg "$dead"
  now=$(date +%s)
  req() { # id trigger time pid lstart [label]
    printf 'id=%s\ntrigger=%s\ndrain_cap=20\non_cap=abort\ndocker_variant=B\nforce=0\ntrial_label=%s\nrequester_pid=%s\nrequester_lstart=%s\nrequester_chain=\ntime=%s\n' \
      "$1" "$2" "${6:-}" "$4" "$5" "$3" > "$FSG_STATE_DIR/requests/$1.req"
  }
  req 20260101T000001Z-1 manual $((now - 9000)) "$dead" "$dl"
  req 20260101T000002Z-2 trial "$now" "$dead" "$dl" t1
  req 20260101T000003Z-3 manual "$now" "$dead" "$dl"
  sed 's/^docker_variant=B/docker_variant=$(touch x)/' "$FSG_STATE_DIR/requests/20260101T000003Z-3.req" > "$C/r" && mv "$C/r" "$FSG_STATE_DIR/requests/20260101T000003Z-3.req"
  "$G" tick >/dev/null 2>&1
  r() { sed -n 's/^exit=//p' "$FSG_STATE_DIR/requests/$1.result"; }
  eq "$(r 20260101T000001Z-1)" 13 "too old: dropped"
  eq "$(r 20260101T000002Z-2)" 13 "a trial whose requester is gone: dropped"
  eq "$(r 20260101T000003Z-3)" 64 "an invalid value: not run"
  has "$(cat "$FSG_STATE_DIR/requests/20260101T000003Z-3.result")" "field docker_variant" "names the field"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "sudo -n /" "none of them healed"
  req 20260101T000004Z-4 manual "$now" "$dead" "$dl"
  mem 3G; "$G" tick >/dev/null 2>&1
  eq "$(r 20260101T000004Z-4)" 0 "a heal request whose requester is gone still runs"
fi

# ======================================================================== drain-scope
if ! skip_case drain-scope; then
  t "unleased work holds a drain only up to its own cap"
  docker_default; install_fake; mem 600M
  # A stand-in runner whose sleep ends with it (else it would outlive the case).
  mkdir -p "$C/bin"; printf '#!/bin/sh\ntrap '"'"'kill $! 2>/dev/null; exit 143'"'"' TERM\nsleep "$1" & wait $!\n' > "$C/bin/fsgtestrspec"; chmod +x "$C/bin/fsgtestrspec"
  bg "$C/bin/fsgtestrspec" 600; up=$LAST_BG; sleep 1
  # The drain cap (300 s) far above the unleased cap (2 s): a slow machine stays
  # well inside the bound below.
  agent_env FSG_UNLEASED_CAP_S=2 FSG_DRAIN_CAP_S=300
  s=$(date +%s); heal > "$C/o" 2>&1; rc=$?
  eq $rc 4 "a manual heal gives up at the unleased cap"
  [ $(( $(date +%s) - s )) -lt 120 ] && ok || bad "did not wait for the 300 s drain cap"
  NL=$FSG_FAKE/notifications.log
  has "$(cat "$NL")" "Waiting for 1 item(s): sh fsgtestrspec 600 (pid $up" "the healing notice names the blocker"
  has "$(cat "$NL")" "Only leased runs (fseventsd-guard run, or an integrated runner) wait" "the healing notice says which runs wait"
  has "$(cat "$NL")" "still running after 2s: sh fsgtestrspec 600 (pid $up" "the give-up notice names the blocker"
  mem 3G
  s=$(date +%s); FSG_UNLEASED_CAP_S=2 FSG_DRAIN_CAP_S=300 "$G" tick > "$C/o" 2>&1; rc=$?
  eq $rc 0 "an emergency heal proceeds at the unleased cap"
  [ $(( $(date +%s) - s )) -lt 120 ] && ok || bad "emergency: did not wait for the 300 s drain cap"
  has "$(grep 'cutting running work' "$NL")" "(pid $up" "the cut notice names the cut run"
  killbg "$up"

  t "exec sessions the engine does not list hold a heal up to the unleased cap"
  docker_default; install_fake; mem 600M
  echo 999 > "$FSG_FAKE/docker/ps-fail"
  agent_env FSG_UNLEASED_CAP_S=2
  : > "$FSG_FAKE/calls.log"
  heal --docker-variant B > "$C/o" 2>&1; eq $? 4 "a manual heal gives up at the unleased cap"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "docker desktop stop" "Docker untouched"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "sudo -n /" "nothing restarted"
  NL=$FSG_FAKE/notifications.log
  has "$(cat "$NL")" "The engine did not list the Docker exec sessions and --rm and one-off containers: waiting up to 2s for a listing" "the healing notice says why it waits"
  has "$(grep 'heal given up' "$NL")" "The Docker exec sessions and --rm and one-off containers were unknown when the drain ended" "the give-up notice says they were unknown"
  grep -q '^drain_exec_unknown=1' "$(cat "$FSG_STATE_DIR/last-heal-dir")/result.txt" && ok || bad "recorded"
  mem 3G
  # Variant none: A, B and C refuse at the Docker step while Docker answers but
  # does not list its containers (heal-rm-volumes).
  FSG_DOCKER_VARIANT=none FSG_UNLEASED_CAP_S=2 "$G" tick > "$C/o" 2>&1; eq $? 0 "an emergency heal proceeds at the unleased cap"
  has "$(grep 'cutting running work' "$NL")" "Proceeding. The Docker exec sessions and --rm and one-off containers were unknown when the drain ended" "the cut notice says they were unknown"
  rm -f "$FSG_FAKE/docker/ps-fail"

  t "leased runs keep the full drain cap"
  docker_default; install_fake; mem 600M
  bg "$G" run --label long -- sleep 60; lp=$LAST_BG; sleep 1
  agent_env FSG_UNLEASED_CAP_S=1
  s=$(date +%s); heal --drain-cap 4 > "$C/o" 2>&1; rc=$?
  eq $rc 4 "gives up at the drain cap"
  [ $(( $(date +%s) - s )) -ge 4 ] && ok || bad "waited the drain cap, not the unleased cap"
  killbg "$lp"

  t "a run started mid-drain neither holds the drain nor goes unnamed"
  docker_default; install_fake; mem 3G
  mkdir -p "$C/bin"; printf '#!/bin/sh\nsleep "$1"\n' > "$C/bin/fsgtestrspec"; chmod +x "$C/bin/fsgtestrspec"
  bg "$G" run --label first -- sleep 9; sleep 1
  heal_mid() { "$G" heal --docker-variant A > "$C/heal.out" 2>&1; }
  bg heal_mid; hp=$LAST_BG
  waitfor 5 test -f "$FSG_STATE_DIR/drain/pending" || bad "drain marked"
  sleep 3; bg "$C/bin/fsgtestrspec" 60; late=$LAST_BG
  waitfor 5 grep -q "started mid-drain.*pid $late" "$FSG_STATE_DIR/drain/blockers" || bad "the heal sees the mid-drain run"
  out=$("$G" status --no-probe 2>&1)
  has "$out" "waiting for: first (pid" "status names what the drain waits for"
  has "$out" "started mid-drain, not waited for (a restart cuts it): sh fsgtestrspec 60 (pid $late" "status names the mid-drain run"
  has "$out" "heal requests: 0 queued; running:" "status names the running request"
  wait "$hp"; eq $? 0 "healed once the leased run ended"
  has "$(cat "$FSG_FAKE/notifications.log")" "(pid $late" "the cut notice names the run started mid-drain"
  has "$(cat "$FSG_FAKE/notifications.log")" "started mid-drain" "and says when it started"
  absent "$FSG_STATE_DIR/drain/blockers" "the blockers record ends with the drain"
  killbg "$late"

  t "an interactive exec session does not hold a drain"
  docker_default; install_fake; mem 3G
  echo "pg 1 tty" > "$FSG_FAKE/docker/execs"
  s=$(date +%s); heal --docker-variant none > "$C/o" 2>&1; rc=$?
  eq $rc 0 "healed"
  [ $(( $(date +%s) - s )) -lt 12 ] && ok || bad "did not wait for the interactive session"
  has "$(cat "$FSG_FAKE/notifications.log")" "Interactive sessions left alone (not waited for; they lose their connection): pg exec session pge1n1" "named in the healing notice"
  echo "pg 1" > "$FSG_FAKE/docker/execs"; echo 4242 > "$FSG_FAKE/fsev/pids"; mem 600M
  rm -f "$FSG_PREFIX/Library/Logs/fseventsd-guard/last-restart"
  agent_env FSG_UNLEASED_CAP_S=2
  heal --docker-variant none > "$C/o" 2>&1; eq $? 4 "a session without a TTY is waited for"
  echo "pg 1 tty fsgtestrspec" > "$FSG_FAKE/docker/execs"
  heal --docker-variant none > "$C/o" 2>&1; eq $? 4 "a session with a TTY for a test run is waited for"
fi

# ======================================================================== heal-drain
if ! skip_case heal-drain; then
  t "heal stops before Docker when the drain marker cannot be written"
  docker_default; install_fake; mem 600M
  mkdir -p "$FSG_STATE_DIR/drain/leases"; chmod 555 "$FSG_STATE_DIR/drain"
  : > "$FSG_FAKE/calls.log"
  heal --docker-variant B > "$C/o" 2>&1; rc=$?
  chmod 755 "$FSG_STATE_DIR/drain"
  eq $rc 10 "exit 10: drain not marked"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "docker desktop stop" "Docker untouched"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "sudo -n /" "no restart"
  absent "$FSG_STATE_DIR/heal.lock" "lock released"

  t "held runs stay held through a slow restore"
  docker_default; install_fake; mem 3G
  echo 8 > "$FSG_FAKE/docker/start-delay"
  # A tiny slack: only a deadline refreshed for the phase keeps the drain alive.
  agent_env FSG_HEAL_BUDGET_S=1 FSG_DRAIN_SLACK_S=1
  heal_slow() { "$G" heal --docker-variant B --drain-cap 0 > "$C/heal.out" 2>&1; }
  bg heal_slow; hp=$LAST_BG
  i=0; while [ $i -lt 40 ] && ! grep -q '^phase=docker-after' "$FSG_STATE_DIR/drain/pending" 2>/dev/null; do sleep 0.5; i=$((i + 1)); done
  grep -qx 'variant=B' "$FSG_STATE_DIR/drain/pending" && ok || bad "the drain marker names the heal's Docker step"
  sleep 3
  FSG_RUN_MAX_WAIT_S=1 "$G" run --label during-restore -- true 2>/dev/null; eq $? 75 "a run starting during docker desktop start is held"
  wait "$hp"; eq $? 0 "heal result"
fi

# ======================================================================== heal-lock
if ! skip_case heal-lock; then
  # $C/wrap/ps pauses once, when asked about the pid in $FSG_FAKE/pause-pid, until
  # $FSG_FAKE/resume exists. $C/wrap/as-self writes its own pid there and execs.
  pause_tools() {
    mkdir -p "$C/wrap" "$C/bin"
    cat > "$C/wrap/ps" <<EOF
#!/bin/bash
p=\$(cat "\$FSG_FAKE/pause-pid" 2>/dev/null)
for a; do
  if [ -n "\$p" ] && [ "\$a" = "\$p" ] && mkdir "\$FSG_FAKE/paused" 2>/dev/null; then
    while [ ! -e "\$FSG_FAKE/resume" ]; do sleep 0.1; done
  fi
done
exec "$STUBS/ps" "\$@"
EOF
    printf '#!/bin/bash\necho $$ > "$FSG_FAKE/pause-pid"\nexec "$@"\n' > "$C/wrap/as-self"
    printf '#!/bin/sh\nsleep "$1"\n' > "$C/bin/fsgtestrspec"
    chmod +x "$C/wrap/ps" "$C/wrap/as-self" "$C/bin/fsgtestrspec"
  }
  fake_lock() { # pid: a heal lock owned by PID
    mkdir -p "$FSG_STATE_DIR/heal.lock"
    printf 'pid=%s\nlstart=%s\n' "$1" "$(lstart "$1")" > "$FSG_STATE_DIR/heal.lock/owner"
  }

  t "a tick taking the lock is not robbed by a concurrent tick"
  docker_default; install_fake; mem 3G; pause_tools
  bg "$C/bin/fsgtestrspec" 60; work=$LAST_BG
  bg env PATH="$C/wrap:$PATH" "$C/wrap/as-self" "$G" tick > "$C/a.out" 2>&1; a=$LAST_BG
  waitfor 20 test -d "$FSG_FAKE/paused" || bad "tick A paused while taking the lock"
  bg "$G" tick > "$C/b.out" 2>&1; b=$LAST_BG
  waitfor 20 grep -qs '^phase=draining' "$FSG_STATE_DIR/drain/pending" || bad "tick B took the lock and drains"
  touch "$FSG_FAKE/resume"; wait "$a"; eq $? 0 "tick A ends at once"
  has "$(cat "$FSG_LOG")" "TICK the heal lock is held by pid $b" "tick A found tick B"
  has "$(cat "$FSG_STATE_DIR/heal.lock/owner" 2>/dev/null)" "pid=$b" "the lock is still tick B's"
  killbg "$work"; wait "$b"; eq $? 0 "tick B heals"
  eq "$(grep -c 'HEAL start' "$FSG_LOG")" 1 "one heal ran"
  absent "$FSG_STATE_DIR/heal.lock" "lock released"

  t "a stale-lock reclaim does not delete a lock another tick just took"
  docker_default; install_fake; mem 3G; pause_tools
  bg sleep 60; dead=$LAST_BG; fake_lock "$dead"; killbg "$dead"
  echo "$dead" > "$FSG_FAKE/pause-pid"; : > "$FSG_FAKE/calls.log"
  bg env PATH="$C/wrap:$PATH" "$G" tick > "$C/r.out" 2>&1; r=$LAST_BG
  waitfor 20 test -d "$FSG_FAKE/paused" || bad "paused while judging the stale lock"
  # Meanwhile another tick reclaims the stale lock and takes it.
  bg sleep 60; other=$LAST_BG
  rm -rf "$FSG_STATE_DIR/heal.lock"; fake_lock "$other"
  touch "$FSG_FAKE/resume"; wait "$r"; eq $? 0 "the reclaimer ends at once"
  has "$(cat "$FSG_STATE_DIR/heal.lock/owner" 2>/dev/null)" "pid=$other" "the new owner's lock survives"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "sudo -n /" "no restart"
  killbg "$other"

  t "a tick releases only its own lock"
  docker_default; install_fake; mem 3G; pause_tools
  bg "$C/bin/fsgtestrspec" 60; work=$LAST_BG
  bg "$G" tick > "$C/b.out" 2>&1; b=$LAST_BG
  waitfor 20 grep -qs '^phase=draining' "$FSG_STATE_DIR/drain/pending" || bad "the tick drains"
  bg sleep 60; other=$LAST_BG
  rm -rf "$FSG_STATE_DIR/heal.lock"; fake_lock "$other"
  killbg "$work"; wait "$b"; eq $? 0 "the tick heals"
  has "$(cat "$FSG_STATE_DIR/heal.lock/owner" 2>/dev/null)" "pid=$other" "another owner's lock is left in place"
  has "$(cat "$FSG_LOG")" "no longer this heal's" "logged"
  killbg "$other"

  t "a lock without an owner record is held for its first minute"
  docker_default; install_fake; mem 3G
  mkdir -p "$FSG_STATE_DIR/heal.lock"; : > "$FSG_FAKE/calls.log"
  "$G" tick >/dev/null 2>&1; eq $? 0 "fresh ownerless lock: the tick ends at once"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "docker desktop stop" "Docker untouched"
  touch_ago 2M "$FSG_STATE_DIR/heal.lock"
  "$G" tick >/dev/null 2>&1; eq $? 0 "an old ownerless lock is reclaimed"
  has "$(cat "$FSG_FAKE/calls.log")" "sudo -n /" "and the tick healed"
  absent "$FSG_STATE_DIR/heal.lock" "lock released"

  t "a tick that cannot create its lock says so, and a waiting heal ends with 10"
  docker_default; install_fake; mem 3G; : > "$FSG_FAKE/calls.log"
  mkdir -p "$FSG_STATE_DIR/requests"; chmod 555 "$FSG_STATE_DIR"
  "$G" tick > "$C/o" 2>&1; rc=$?
  FSG_AGENT_INTERVAL_S=2 heal --docker-variant B > "$C/h" 2>&1; hrc=$?
  chmod 755 "$FSG_STATE_DIR"
  eq $rc 10 "exit 10: lock not created"
  has "$(cat "$FSG_LOG")" "TICK cannot create the heal lock" "logged"
  has "$(cat "$FSG_FAKE/notifications.log" 2>/dev/null)" "cannot take the heal lock" "notified"
  eq $hrc 10 "the heal request ends with 10"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "docker desktop stop" "Docker untouched"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "sudo -n /" "no restart"
  absent "$FSG_STATE_DIR/heal.lock" "no lock left"
fi

# ======================================================================== heal-autoremove
if ! skip_case heal-autoremove; then
  for v in A B; do
    t "heal variant $v with a --rm container still running at the cap"
    docker_default; install_fake; mem 3G
    containers "c1 pg running healthy postgres:17 unless-stopped 0 0" "c3 job running none alpine:3 no 0 1"
    agent_env FSG_UNLEASED_CAP_S=1
    : > "$FSG_FAKE/calls.log"
    heal --docker-variant $v --on-cap proceed > "$C/o" 2>&1; eq $? 0 "healed: the --rm container is not part of the restore"
    has "$(grep 'fseventsd: healing' "$FSG_FAKE/notifications.log")" "Waiting for 1 item(s): container job (--rm, 1h00m)" "the drain waits for it"
    has "$(grep 'cutting running work' "$FSG_FAKE/notifications.log")" "container job (--rm" "and names it as cut at the cap"
    has "$(cat "$FSG_FAKE/notifications.log")" "job" "the notification names the container that cannot come back"
    grep -q '^containers_not_restorable=job' "$(cat "$FSG_STATE_DIR/last-heal-dir")/result.txt" && ok || bad "recorded"
    [ $v = A ] && has "$(cat "$FSG_FAKE/calls.log")" "docker stop -t 30 c1 c3" "A still stops it before the restart"
    hasnt "$(cat "$FSG_FAKE/calls.log")" "docker start c1 c3" "never restarted"
  done

  t "a heal waits for a --rm container that ends by itself"
  docker_default; install_fake; mem 3G
  containers "c1 pg running healthy postgres:17 unless-stopped 0 0" "c3 job running none alpine:3 no 0 1"
  : > "$FSG_FAKE/calls.log"
  ends() { sleep 5; awk '$1 != "c3"' "$FSG_FAKE/docker/containers" > "$FSG_FAKE/docker/c.ends" && mv "$FSG_FAKE/docker/c.ends" "$FSG_FAKE/docker/containers"; }
  bg ends
  heal --docker-variant A > "$C/o" 2>&1; eq $? 0 "healed once it ended"
  grep -q 'DRAIN drained waited_s=[1-9]' "$FSG_LOG" && ok || bad "the drain waited for it"
  has "$(cat "$FSG_FAKE/calls.log")" "docker stop -t 30 c1" "A stops the rest"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "docker stop -t 30 c1 c3" "the ended container is not stopped"
fi

# ======================================================================== heal-oneoff
if ! skip_case heal-oneoff; then
  for v in A B C; do
    t "heal variant $v does not start a one-off (compose run) container again"
    docker_default; install_fake; mem 3G
    containers "c1 pg running healthy postgres:17 unless-stopped 0 0 0" "c4 api-run-1 running none api:1 no 0 0 1"
    agent_env FSG_UNLEASED_CAP_S=1
    : > "$FSG_FAKE/calls.log"
    heal --docker-variant $v --on-cap proceed > "$C/o" 2>&1; eq $? 0 "healed: the one-off is not part of the restore ($(tail -n 1 "$C/o"))"
    has "$(grep 'fseventsd: healing' "$FSG_FAKE/notifications.log")" "Waiting for 1 item(s): container api-run-1 (one-off" "the drain waits for it"
    eq "$(grep '^docker start' "$FSG_FAKE/calls.log" | grep -c c4)" 0 "the one-off is never started"
    eq "$(awk '$1 == "c4" { print $3 }' "$FSG_FAKE/docker/containers")" exited "it stays stopped"
    has "$(grep 'fseventsd healed' "$FSG_FAKE/notifications.log")" "Not restored (one-off, docker compose run: a start would run its command again): api-run-1" "the result names it"
    grep -q '^containers_not_restored_oneoff=api-run-1$' "$(cat "$FSG_STATE_DIR/last-heal-dir")/result.txt" && ok || bad "recorded"
    eq "$(awk '$1 == "c1" { print $3 }' "$FSG_FAKE/docker/containers")" running "the other container is restored"
  done
  t "heal --dry-run names a one-off container as not restored"
  docker_default; install_fake; mem 3G
  containers "c1 pg running healthy postgres:17 unless-stopped 0 0 0" "c4 api-run-1 running none api:1 no 0 0 1"
  out=$("$G" heal --dry-run --docker-variant A)
  has "$out" "containers: pg; not restored (one-off): api-run-1" "named"
  has "$out" "8. docker after-step (A): docker start c1" "the plan starts only the restore set"
  hasnt "$out" "docker start c1 c4" "not the one-off"
fi

# ======================================================================== heal-rm-volumes
if ! skip_case heal-rm-volumes; then
  DEVDB="c3 devdb running none postgres:16 no 0 1 0 - anon:/var/lib/postgresql/data,cache:/cache"
  for v in A B C; do
    t "heal variant $v refuses to stop a --rm container with an anonymous volume"
    # Below the agent's emergency tier, so its own check after the request heals nothing.
    docker_default; install_fake; mem 600M
    containers "c1 pg running healthy postgres:17 unless-stopped 0 0 0" "$DEVDB"
    agent_env FSG_UNLEASED_CAP_S=1
    : > "$FSG_FAKE/calls.log"
    heal --docker-variant $v --on-cap proceed > "$C/o" 2>&1; eq $? 14 "refused ($(tail -n 1 "$C/o"))"
    L=$(cat "$FSG_FAKE/calls.log")
    hasnt "$L" "docker stop" "no container stopped"; hasnt "$L" "docker desktop stop" "Docker Desktop not stopped"
    hasnt "$L" "docker desktop restart" "nor restarted"
    hasnt "$L" "sudo -n /" "fseventsd not restarted"
    eq "$(awk '$1 == "c3" { print $3 }' "$FSG_FAKE/docker/containers")" running "the container and its volume are left as they are"
    NL=$FSG_FAKE/notifications.log
    has "$(grep 'fseventsd: healing' "$NL")" "--rm containers with an anonymous volume, which Docker would delete with them: devdb (/var/lib/postgresql/data). If one still runs after the drain, the heal stops before it touches Docker or fseventsd (exit 14)" "the healing notice warns first"
    has "$(grep 'heal refused' "$NL")" "Docker deletes a --rm container's anonymous volumes with it: devdb (/var/lib/postgresql/data). Nothing was stopped or restarted" "the refusal names the container and why"
    hasnt "$(grep 'heal refused' "$NL")" "/cache" "a named volume is not at risk"
    hasnt "$(cat "$NL")" "cutting running work" "no cut notice for a heal that stops"
    has "$(cat "$C/o")" "refused: Docker step $v would delete the anonymous volumes of running --rm containers: devdb" "the caller is told"
    grep -q '^result=refused-anonymous-volumes$' "$(cat "$FSG_STATE_DIR/last-heal-dir")/result.txt" && ok || bad "recorded"
    absent "$FSG_STATE_DIR/drain/pending" "drain released"; absent "$FSG_STATE_DIR/docker-intent" "no Docker intent"
    absent "$FSG_STATE_DIR/last-attempt" "a manual refusal leaves the agent's emergency interval alone"
  done

  t "variant none leaves a --rm container with an anonymous volume alone and heals"
  docker_default; install_fake; mem 3G
  containers "c1 pg running healthy postgres:17 unless-stopped 0 0 0" "$DEVDB"
  agent_env FSG_UNLEASED_CAP_S=1
  heal --docker-variant none --on-cap proceed > "$C/o" 2>&1; eq $? 0 "healed: nothing stops it"
  eq "$(awk '$1 == "c3" { print $3 }' "$FSG_FAKE/docker/containers")" running "still running"

  t "a --rm container with only named volumes is stopped, named as removed first"
  docker_default; install_fake; mem 3G
  containers "c1 pg running healthy postgres:17 unless-stopped 0 0 0" "c3 job running none alpine:3 no 0 1 0 - cache:/cache"
  agent_env FSG_UNLEASED_CAP_S=1
  heal --docker-variant B --on-cap proceed > "$C/o" 2>&1; eq $? 0 "healed"
  NL=$FSG_FAKE/notifications.log
  has "$(grep 'fseventsd: healing' "$NL")" "--rm containers still running at the Docker step are removed (Docker deletes them when they stop): job." "the healing notice names it as removed"
  has "$(grep 'cutting running work' "$NL")" "Removed by Docker step B (--rm: Docker deletes them when they stop; none has an anonymous volume): job." "named before Docker stops"
  before "$FSG_LOG" "Removed by Docker step B" "DOCKER B desktop stop"
  eq "$(awk '$1 == "c3"' "$FSG_FAKE/docker/containers")" "" "Docker removed it"

  t "an emergency refusal counts against the agent's emergency interval"
  docker_default; install_fake; mem 3G
  containers "c1 pg running healthy postgres:17 unless-stopped 0 0 0" "$DEVDB"
  FSG_UNLEASED_CAP_S=1 "$G" tick > "$C/o" 2>&1; eq $? 14 "the agent's emergency heal refuses"
  exists "$FSG_STATE_DIR/last-attempt" "stamped"
  FSG_UNLEASED_CAP_S=1 "$G" tick > "$C/o" 2>&1; eq $? 2 "the next tick notifies only"
  eq "$(grep -c 'heal refused' "$FSG_FAKE/notifications.log")" 1 "no second drain and refusal"
  eq "$(awk '$1 == "c3" { print $3 }' "$FSG_FAKE/docker/containers")" running "still running"

  t "heal --dry-run names a --rm container with an anonymous volume"
  docker_default; install_fake; mem 3G
  containers "c1 pg running healthy postgres:17 unless-stopped 0 0 0" "$DEVDB"
  out=$("$G" heal --dry-run --docker-variant B)
  has "$out" "--rm with an anonymous volume: devdb (/var/lib/postgresql/data)" "the docker line names it"
  has "$out" "would stop here, before Docker and fseventsd (exit 14), if one still runs after the drain: --rm with an anonymous volume, which Docker would delete with it: devdb (/var/lib/postgresql/data)" "the plan says what happens"
  has "$out" "container: devdb (--rm, up 1h00m)" "the drain waits for it"

  t "variant C does not restart Docker Desktop over a --rm container with an anonymous volume"
  docker_default
  containers "c1 pg running healthy postgres:17 unless-stopped 0 0 0" "$DEVDB"
  # c_after [SETUP]: C's after-step on the running Docker Desktop. With SETUP, the
  # heal's record is taken first, then SETUP changes the engine before the restart.
  c_after() {
    ( FSG_HOME=$GUARD_HOME; . "$GUARD_HOME/lib/common.sh"; . "$GUARD_HOME/lib/lease.sh"; . "$GUARD_HOME/lib/drain.sh"; . "$GUARD_HOME/lib/docker.sh"
      fsg_init_paths; fsg_load_config; DK_STATE=running; DK_IDS=
      fsg_docker_endpoint && fsg_docker_pin
      if [ -n "${1:-}" ]; then fsg_docker_record; echo "record: listed=$DK_LISTED"; eval "$1"; fi
      fsg_docker_after C; echo "rc=$? err=$DK_ERR note=${DK_NOTE:-}" )
  }
  : > "$FSG_FAKE/calls.log"; out=$(c_after)
  has "$out" "rc=2 err=Docker Desktop not restarted: it would delete these --rm containers and their anonymous volumes: devdb (/var/lib/postgresql/data)" "a container started since the check stops the restart"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "docker desktop restart" "not restarted"
  containers "c1 pg running healthy postgres:17 unless-stopped 0 0 0" "c3 job running none alpine:3 no 0 1 0 - cache:/cache"
  : > "$FSG_FAKE/calls.log"; out=$(c_after)
  has "$out" "rc=0 err= note=" "restarted otherwise"
  has "$(cat "$FSG_FAKE/calls.log")" "docker desktop restart" "restarted"

  t "variant C does not restart Docker Desktop when its fresh listing fails while Docker answers"
  docker_default
  : > "$FSG_FAKE/calls.log"; out=$(c_after 'echo 1 > "$FSG_FAKE/docker/ps-fail"')
  has "$out" "record: listed=1" "the heal's own listing worked"
  has "$out" "rc=2 err=Docker Desktop not restarted: Docker answers but did not list its containers, so --rm containers with an anonymous volume could not be checked" "a failed docker ps stops the restart"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "docker desktop restart" "not restarted"
  : > "$FSG_FAKE/calls.log"; out=$(c_after 'touch "$FSG_FAKE/docker/inspect-down"')
  has "$out" "rc=2 err=Docker Desktop not restarted: Docker answers but did not list its containers" "so does a failed docker inspect"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "docker desktop restart" "not restarted"
  rm -f "$FSG_FAKE/docker/inspect-down"

  t "variant C restarts a Docker Desktop that answers nothing without the check, and says so"
  docker_default; touch "$FSG_FAKE/docker/hang"
  : > "$FSG_FAKE/calls.log"; out=$(c_after)
  has "$out" "rc=0 err= note=Docker Desktop restarted unchecked: Docker did not answer docker info (wedged), so its containers were not listed again" "restarted, and named"
  has "$(cat "$FSG_FAKE/calls.log")" "docker desktop restart" "restarted"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "docker ps" "no listing on the wedged engine"
  has "$(cat "$FSG_LOG")" "DOCKER C Docker Desktop restarted unchecked" "logged"

  t "a heal's variant C restart is skipped when the fresh listing fails while Docker answers"
  docker_default; install_fake; mem 3G
  agent_env FSG_UNLEASED_CAP_S=1
  echo 2 > "$FSG_FAKE/sudo-delay"; : > "$FSG_FAKE/calls.log"
  # From the root helper's restart on, every docker ps fails; docker info still answers.
  ps_fails() { waitfor 60 grep -qs "sudo -n /" "$FSG_FAKE/calls.log" && echo 1000 > "$FSG_FAKE/docker/ps-fail"; }
  bg ps_fails
  heal --docker-variant C > "$C/o" 2>&1; eq $? 8 "Docker not verified: not restarted ($(tail -n 1 "$C/o"))"
  has "$(cat "$FSG_FAKE/calls.log")" "sudo -n /" "fseventsd restarted"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "docker desktop restart" "Docker Desktop not restarted"
  has "$(grep 'heal incomplete' "$FSG_FAKE/notifications.log")" "Docker Desktop not restarted: Docker answers but did not list its containers, so --rm containers with an anonymous volume could not be checked" "the notice says the check could not run"
  has "$(cat "$FSG_LOG")" "DOCKER C Docker Desktop not restarted: Docker answers but did not list" "logged"
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 75 "new runs held"
  rm -f "$FSG_FAKE/docker/ps-fail" "$FSG_FAKE/sudo-delay"; mem 5000K
  "$G" tick >/dev/null 2>&1
  absent "$FSG_STATE_DIR/docker-intent" "the agent verifies Docker as it is"
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 0 "and releases the runs"

  for v in A B C; do
    t "heal variant $v refuses when Docker answers but does not list its containers"
    docker_default; install_fake; mem 600M
    agent_env FSG_UNLEASED_CAP_S=1
    # docker inspect fails while docker info answers: the drain waits its 1 s for a
    # listing, and the heal's own record has none either.
    touch "$FSG_FAKE/docker/inspect-down"; : > "$FSG_FAKE/calls.log"
    heal --docker-variant $v --on-cap proceed > "$C/o" 2>&1; eq $? 14 "refused ($(tail -n 1 "$C/o"))"
    L=$(cat "$FSG_FAKE/calls.log")
    hasnt "$L" "docker stop" "no container stopped"; hasnt "$L" "docker desktop stop" "Docker Desktop not stopped"
    hasnt "$L" "docker desktop restart" "nor restarted"
    hasnt "$L" "sudo -n /" "fseventsd not restarted"
    NL=$FSG_FAKE/notifications.log
    has "$(grep 'heal refused' "$NL")" "Docker answers but could not list its containers (docker ps or docker inspect failed or timed out), so their --rm anonymous volumes could not be checked, and Docker step $v would stop them. Nothing was stopped or restarted" "the refusal says why"
    hasnt "$(cat "$NL")" "cutting running work" "no cut notice for a heal that stops"
    has "$(cat "$C/o")" "refused: Docker answers but did not list its containers, so Docker step $v could delete a --rm container's anonymous volume unchecked" "the caller is told"
    grep -q '^result=refused-unlisted$' "$(cat "$FSG_STATE_DIR/last-heal-dir")/result.txt" && ok || bad "recorded"
    absent "$FSG_STATE_DIR/drain/pending" "drain released"; absent "$FSG_STATE_DIR/docker-intent" "no Docker intent"
    absent "$FSG_STATE_DIR/last-attempt" "a manual refusal leaves the agent's emergency interval alone"
  done

  t "a failed docker ps refuses a heal too, also for variant A, which would then stop nothing"
  docker_default; install_fake; mem 600M
  agent_env FSG_UNLEASED_CAP_S=1
  echo 1000 > "$FSG_FAKE/docker/ps-fail"; : > "$FSG_FAKE/calls.log"
  heal --docker-variant A --on-cap proceed > "$C/o" 2>&1; eq $? 14 "refused ($(tail -n 1 "$C/o"))"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "sudo -n /" "fseventsd not restarted"
  grep -q '^result=refused-unlisted$' "$(cat "$FSG_STATE_DIR/last-heal-dir")/result.txt" && ok || bad "recorded"

  t "a docker inspect that fails for a running container leaves the listing incomplete"
  docker_default
  # record [SETUP]: the heal's record of the running Docker Desktop, SETUP run first.
  record() {
    ( FSG_HOME=$GUARD_HOME; . "$GUARD_HOME/lib/common.sh"; . "$GUARD_HOME/lib/lease.sh"; . "$GUARD_HOME/lib/drain.sh"; . "$GUARD_HOME/lib/docker.sh"
      fsg_init_paths; fsg_load_config; eval "${1:-}"
      fsg_docker_record; fsg_docker_record_text; fsg_docker_unchecked B && echo "B unchecked" )
  }
  echo c2 > "$FSG_FAKE/docker/record-fail"
  out=$(record)
  has "$out" "listed=0" "c2 runs and its record failed"
  has "$out" "B unchecked" "so its --rm volumes count as not checked"
  has "$(cat "$FSG_LOG")" "DOCKER cannot read AutoRemove, the one-off label and the mounts of c2, which still run or could not be listed again" "logged"
  rm -f "$FSG_FAKE/docker/record-fail"
  echo "c9 gone" > "$FSG_FAKE/docker/ps-ghost"; : > "$FSG_LOG"
  out=$(record)
  has "$out" "listed=1" "a container removed since docker ps fails the inspect for itself only"
  hasnt "$(cat "$FSG_LOG")" "cannot read AutoRemove" "nothing logged"
  # The check that it no longer runs fails too: it counts as not read.
  echo "c9 gone" > "$FSG_FAKE/docker/ps-ghost"
  out=$(record 'docker() { case "$1 $2" in "ps -q") return 1 ;; esac; command docker "$@"; }')
  has "$out" "listed=0" "not listed again"

  t "a heal refuses when docker inspect fails for a running container"
  docker_default; install_fake; mem 600M
  agent_env FSG_UNLEASED_CAP_S=1
  echo c2 > "$FSG_FAKE/docker/record-fail"; : > "$FSG_FAKE/calls.log"
  heal --docker-variant B --on-cap proceed > "$C/o" 2>&1; eq $? 14 "refused ($(tail -n 1 "$C/o"))"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "docker desktop stop" "Docker Desktop not stopped"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "sudo -n /" "fseventsd not restarted"
  grep -q '^result=refused-unlisted$' "$(cat "$FSG_STATE_DIR/last-heal-dir")/result.txt" && ok || bad "recorded"

  t "variant C does not restart Docker Desktop when docker inspect fails for a running container"
  docker_default
  : > "$FSG_FAKE/calls.log"; out=$(c_after 'echo c2 > "$FSG_FAKE/docker/record-fail"')
  has "$out" "record: listed=1" "the heal's own listing worked"
  has "$out" "rc=2 err=Docker Desktop not restarted: Docker answers but did not list its containers" "the fresh listing is incomplete"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "docker desktop restart" "not restarted"

  t "an emergency refusal for containers Docker does not list counts against the emergency interval"
  docker_default; install_fake; mem 3G; touch "$FSG_FAKE/docker/inspect-down"
  FSG_UNLEASED_CAP_S=1 "$G" tick > "$C/o" 2>&1; eq $? 14 "the agent's emergency heal refuses"
  exists "$FSG_STATE_DIR/last-attempt" "stamped"
  FSG_UNLEASED_CAP_S=1 "$G" tick > "$C/o" 2>&1; eq $? 2 "the next tick notifies only"
  eq "$(grep -c 'heal refused' "$FSG_FAKE/notifications.log")" 1 "no second drain and refusal"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "docker desktop stop" "Docker Desktop not stopped"

  t "heal --dry-run says whether a Docker that does not list its containers refuses the heal"
  docker_default; install_fake; mem 3G; touch "$FSG_FAKE/docker/inspect-down"
  out=$("$G" heal --dry-run --docker-variant B)
  has "$out" "would stop here, before Docker and fseventsd (exit 14), if Docker still answers but does not list its containers after the drain: their --rm volumes cannot be checked" "Docker answers: a refusal"
  rm -f "$FSG_FAKE/docker/inspect-down"
  export FSG_DETECT_DOCKER_EXECS=0 FSG_DETECT_DOCKER_CONTAINERS=0
  touch "$FSG_FAKE/docker/hang"
  out=$("$G" heal --dry-run --docker-variant B)
  has "$out" "Docker does not answer docker info (wedged), so its containers cannot be listed: a wedged Docker is acted on without the --rm volume check, and the result names it" "a wedged Docker: acted on, named"
  hasnt "$out" "if Docker still answers but does not list" "and no refusal"

  t "the docker-before deadline counts the docker info after a failed listing"
  out=$( FSG_HOME=$GUARD_HOME; . "$GUARD_HOME/lib/common.sh"; . "$GUARD_HOME/lib/lease.sh"; . "$GUARD_HOME/lib/drain.sh"
    fsg_init_paths; fsg_load_config; fsg_phase_budget docker-before )
  eq "$out" $((60 + 95 + 3 * FSG_DOCKER_QUERY_TIMEOUT_S)) "status and info, docker ps again, info again, desktop stop and its polls (FSG_DESKTOP_STOP_WAIT_S beats the stop's timeout here)"
  out=$( FSG_HOME=$GUARD_HOME; . "$GUARD_HOME/lib/common.sh"; . "$GUARD_HOME/lib/lease.sh"; . "$GUARD_HOME/lib/drain.sh"
    fsg_init_paths; fsg_load_config; FSG_DOCKER_TIMEOUT_S=300; fsg_phase_budget docker-before )
  eq "$out" $((300 + 10 + 95 + 3 * FSG_DOCKER_QUERY_TIMEOUT_S)) "the stop's timeout beats FSG_DESKTOP_STOP_WAIT_S"

  t "the record reads what a real engine's docker inspect printed"
  docker_default; live_containers
  out=$( FSG_HOME=$GUARD_HOME; . "$GUARD_HOME/lib/common.sh"; . "$GUARD_HOME/lib/lease.sh"; . "$GUARD_HOME/lib/drain.sh"; . "$GUARD_HOME/lib/docker.sh"
    fsg_init_paths; fsg_load_config
    fsg_docker_record; fsg_docker_record_text; echo "rm_plain=$DK_RM_PLAIN" )
  has "$out" "listed=1" "every container read: an absent HostConfig.Mounts and a bind mount's missing Name do not fail it"
  has "$out" "rm_anonymous_volumes=fsg-probe-mount (/m2); fsg-probe-anon (/data)" "an anonymous -v and --mount volume; not the named ones"
  has "$out" "rm_plain=fsg-probe-named" "a --rm container with a named volume only"
  has "$out" "not_restorable=fsg-probe-mount fsg-probe-named fsg-probe-anon" "the --rm containers"
  has "$out" "not_restored_oneoff=fsg-probe-oneoff" "a one-off; an unset label (null) and \"False\" are not"
  has "$out" "names=app-redis app-unleash app-postgres app-elasticsearch" "the restore set"
  has "$out" "health=none none none none" "their health, in the same order"

  t "a heal refuses over a real engine's --rm containers with anonymous volumes"
  docker_default; install_fake; mem 600M; live_containers
  agent_env FSG_UNLEASED_CAP_S=1
  : > "$FSG_FAKE/calls.log"
  heal --docker-variant B --on-cap proceed > "$C/o" 2>&1; eq $? 14 "refused ($(tail -n 1 "$C/o"))"
  has "$(grep 'heal refused' "$FSG_FAKE/notifications.log")" "fsg-probe-mount (/m2); fsg-probe-anon (/data)" "names them"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "docker desktop stop" "Docker Desktop not stopped"

  # A bind mount listed before devdb's anonymous volume, its destination holding a
  # tab or a newline (Docker accepts both): printed as is, either would shift the
  # record's fields or split it, and hide the volume.
  for v in A B C; do
    for w in tab newline; do
      t "heal variant $v refuses over an anonymous volume after a bind mount with a $w in its destination"
      docker_default; install_fake; mem 600M
      containers "c1 pg running healthy postgres:17 unless-stopped 0 0 0" "$DEVDB"
      if [ $w = tab ]; then printf '/host\tdata' > "$FSG_FAKE/docker/bind-c3"; else printf '/host\ndata' > "$FSG_FAKE/docker/bind-c3"; fi
      agent_env FSG_UNLEASED_CAP_S=1
      : > "$FSG_FAKE/calls.log"
      heal --docker-variant $v --on-cap proceed > "$C/o" 2>&1; eq $? 14 "refused ($(tail -n 1 "$C/o"))"
      L=$(cat "$FSG_FAKE/calls.log")
      hasnt "$L" "docker stop" "no container stopped"; hasnt "$L" "docker desktop stop" "Docker Desktop not stopped"
      hasnt "$L" "docker desktop restart" "nor restarted"; hasnt "$L" "sudo -n /" "fseventsd not restarted"
      has "$(grep 'heal refused' "$FSG_FAKE/notifications.log")" "anonymous volumes with it: devdb (/var/lib/postgresql/data). Nothing was stopped" "the volume is found"
      grep -q '^result=refused-anonymous-volumes$' "$(cat "$FSG_STATE_DIR/last-heal-dir")/result.txt" && ok || bad "recorded"
      eq "$(awk '$1 == "c3" { print $3 }' "$FSG_FAKE/docker/containers")" running "the container and its volume are left as they are"
    done
  done

  t "variant C's listing before its restart finds an anonymous volume after a bind mount with a tab or newline in its destination"
  docker_default
  containers "c1 pg running healthy postgres:17 unless-stopped 0 0 0" "$DEVDB"
  for w in tab newline; do
    if [ $w = tab ]; then printf '/host\tdata' > "$FSG_FAKE/docker/bind-c3"; else printf '/host\ndata' > "$FSG_FAKE/docker/bind-c3"; fi
    : > "$FSG_FAKE/calls.log"; out=$(c_after)
    has "$out" "rc=2 err=Docker Desktop not restarted: it would delete these --rm containers and their anonymous volumes: devdb (/var/lib/postgresql/data)" "$w: found"
    hasnt "$(cat "$FSG_FAKE/calls.log")" "docker desktop restart" "$w: not restarted"
  done

  t "a docker inspect line that is not a whole record leaves the listing incomplete"
  docker_default
  printf 'c2\t/redis\tfalse\t"False"\tnullnull\tnull\t"bind"\tnull\n' > "$FSG_FAKE/docker/record-text-c2"
  out=$(record)
  has "$out" "listed=0" "a mount cut short"; has "$out" "B unchecked" "so its --rm volumes count as not checked"
  has "$(cat "$FSG_LOG")" "DOCKER docker inspect printed 1 line(s) that are not a whole container record" "logged"
  printf 'c2\t/redis\tfalse\t"False"\tnullnull\tnull\t"bind"\tnull\t"/host\ndata"\n' > "$FSG_FAKE/docker/record-text-c2"
  out=$(record); has "$out" "listed=0" "a destination split by a newline"
  printf 'c2\t/redis\tfalse\t"False"\tnullnull\tnull\t"bind"\tnull\t/host\n' > "$FSG_FAKE/docker/record-text-c2"
  out=$(record); has "$out" "listed=0" "a destination that is not JSON"
  printf 'c2\t/redis\tyes\t"False"\tnullnull\tnull\n' > "$FSG_FAKE/docker/record-text-c2"
  out=$(record); has "$out" "listed=0" "an AutoRemove that is neither true nor false"
  printf 'c2\t/redis\tfalse\t"False"\tnullnull\thealthy\n' > "$FSG_FAKE/docker/record-text-c2"
  out=$(record); has "$out" "listed=0" "a health status that is not JSON"
  : > "$FSG_FAKE/docker/record-text-c2"; : > "$FSG_LOG"
  out=$(record); has "$out" "listed=0" "no line for a running container, inspect still succeeding"
  has "$(cat "$FSG_LOG")" "of c2, which still run" "logged"
  rm -f "$FSG_FAKE/docker/record-text-c2"
  out=$(record); has "$out" "listed=1" "whole records list"

  t "the record reads a one-off label and a volume name that hold a tab or a newline"
  docker_default
  containers "c1 pg running healthy postgres:17 unless-stopped 0 0 0" "$DEVDB"
  for w in tab newline; do
    if [ $w = tab ]; then printf 'x\ty' > "$FSG_FAKE/docker/label-c3"; else printf 'x\ny' > "$FSG_FAKE/docker/label-c3"; fi
    out=$(record)
    has "$out" "listed=1" "$w in the label: read"
    has "$out" "rm_anonymous_volumes=devdb (/var/lib/postgresql/data)" "$w in the label: the volume is found"
  done
  rm -f "$FSG_FAKE/docker/label-c3"
  # A named volume whose name has a tab, as the template prints it: matched to the
  # spec in its JSON form, so only the anonymous volume is at risk.
  printf 'c3\t/devdb\ttrue\tnull\t["my\\tvol:/m"]null\tnull\t"volume"\t"my\\tvol"\t"/m"\t"volume"\t"%s"\t"/var/lib/postgresql/data"\n' \
    "$(printf 'f%063d' 1)" > "$FSG_FAKE/docker/record-text-c3"
  out=$(record)
  has "$out" "listed=1" "read"; has "$out" "rm_anonymous_volumes=devdb (/var/lib/postgresql/data)" "the named volume is not at risk"

  for v in A B C; do
    t "heal variant $v refuses when a docker inspect line is not a whole record"
    docker_default; install_fake; mem 600M
    agent_env FSG_UNLEASED_CAP_S=1
    printf 'c2\t/redis\tfalse\t"False"\tnullnull\tnull\t"bind"\tnull\t/host\n' > "$FSG_FAKE/docker/record-text-c2"; : > "$FSG_FAKE/calls.log"
    heal --docker-variant $v --on-cap proceed > "$C/o" 2>&1; eq $? 14 "refused ($(tail -n 1 "$C/o"))"
    L=$(cat "$FSG_FAKE/calls.log")
    hasnt "$L" "docker stop" "no container stopped"; hasnt "$L" "docker desktop stop" "Docker Desktop not stopped"
    hasnt "$L" "docker desktop restart" "nor restarted"; hasnt "$L" "sudo -n /" "fseventsd not restarted"
    grep -q '^result=refused-unlisted$' "$(cat "$FSG_STATE_DIR/last-heal-dir")/result.txt" && ok || bad "recorded"
  done

  t "variant C does not restart Docker Desktop when a docker inspect line is not a whole record"
  docker_default
  printf 'c2\t/redis\tfalse\t"False"\tnullnull\tnull\t"bind"\tnull\n' > "$C/cut"
  : > "$FSG_FAKE/calls.log"; out=$(c_after 'cp "$C/cut" "$FSG_FAKE/docker/record-text-c2"')
  has "$out" "record: listed=1" "the heal's own listing worked"
  has "$out" "rc=2 err=Docker Desktop not restarted: Docker answers but did not list its containers" "the fresh listing is incomplete"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "docker desktop restart" "not restarted"
fi

# ======================================================================== blind
if ! skip_case blind; then
  t "a user process named fseventsd does not blind the guard or block the helper"
  docker_default; install_fake
  printf '4242\n9999\n' > "$FSG_FAKE/fsev/pids"; echo 501 > "$FSG_FAKE/fsev/9999.uid"; echo 1M > "$FSG_FAKE/fsev/9999.mem"
  "$G" status >/dev/null; eq $? 0 "status measures the root daemon"
  "$G" tick >/dev/null 2>&1; eq $? 0 "tick measures"
  H="$C/helper"; render_helper "$H" 0; mem 3G
  /bin/sh "$H" >/dev/null 2>&1; eq $? 0 "the helper restarts the root daemon"
  has "$(cat "$FSG_FAKE/calls.log")" "kill -TERM 4242" "the genuine pid"

  t "the agent says so when it cannot measure"
  docker_default; install_fake
  : > "$FSG_FAKE/fsev/pids"; : > "$FSG_FAKE/notifications.log"
  "$G" tick >/dev/null 2>&1; eq $? 3 "tick 1"
  "$G" tick >/dev/null 2>&1; "$G" tick >/dev/null 2>&1
  eq "$(grep -c 'cannot measure' "$FSG_FAKE/notifications.log")" 1 "notified after 3 ticks in a row"
  "$G" tick >/dev/null 2>&1; "$G" tick >/dev/null 2>&1
  eq "$(grep -c 'cannot measure' "$FSG_FAKE/notifications.log")" 1 "not repeated within the renotify window"
  echo 4242 > "$FSG_FAKE/fsev/pids"; "$G" tick >/dev/null 2>&1; eq $? 0 "measures again"
  absent "$FSG_STATE_DIR/blind-ticks" "the streak resets"
fi

# ======================================================================== stall-notice
if ! skip_case stall-notice; then
  t "a stall below the helper's floor is notified once per window"
  docker_default; install_fake
  mem 100M; echo stalled > "$FSG_FAKE/probe"; : > "$FSG_FAKE/notifications.log"
  "$G" tick >/dev/null 2>&1; eq $? 6 "tick 1: the helper would refuse"
  "$G" tick >/dev/null 2>&1; "$G" tick >/dev/null 2>&1
  eq "$(grep -c 'delivery stalled' "$FSG_FAKE/notifications.log")" 1 "one notification for three ticks"
  heal > "$C/o" 2>&1; eq $? 6 "a manual heal still explains"
  has "$(cat "$C/o")" "sudo kill -TERM" "manual fix on the terminal"
fi

# ======================================================================== wave-backoff
if ! skip_case wave-backoff; then
  t "a wave heal that gave up at the cap does not start another drain at the next wave"
  docker_default; install_fake; mem 600M
  bg "$G" run --label long -- sleep 60; sleep 1
  heal --trigger wave --drain-cap 2 >/dev/null 2>&1; eq $? 4 "first wave heal gives up at the cap"
  s=$(date +%s); heal --trigger wave --drain-cap 2 > "$C/o" 2>&1; eq $? 11 "the next wave heal backs off"
  [ $(( $(date +%s) - s )) -lt 8 ] && ok || bad "it did not drain again"
  eq "$(grep -c 'DRAIN begin' "$FSG_LOG")" 1 "one drain, not two"
  has "$(cat "$C/o")" "FSG_WAVE_RETRY_MIN" "the message names the knob"
  heal --drain-cap 1 >/dev/null 2>&1; eq $? 4 "a manual heal is not affected"
  killbg "$LAST_BG"

  t "a wave caller stopped while waiting leaves the heal draining and starts no back-off"
  docker_default; install_fake; mem 600M
  bg "$G" run --label long -- sleep 60; lr=$LAST_BG; sleep 1
  for sig in TERM KILL; do
    "$G" heal --trigger wave --drain-cap 30 > "$C/w.out" 2>&1 & hp=$!; BG_PIDS="$BG_PIDS $hp"
    waitfor 20 grep -qs '^phase=draining' "$FSG_STATE_DIR/drain/pending" || bad "$sig: the wave heal drains"
    kill -$sig "$hp"; wait "$hp" 2>/dev/null
    sleep 1
    ap=$(agent_pid)
    [ -n "$ap" ] && ok || bad "$sig: the agent's tick goes on"
    has "$(cat "$FSG_STATE_DIR/drain/pending" 2>/dev/null)" "owner_pid=$ap" "$sig: the agent's drain goes on"
    absent "$FSG_STATE_DIR/wave-gave-up" "$sig: no back-off"
    # End this heal before the next round.
    [ $sig = TERM ] && agent_stop
  done
  id=$(basename "$(ls -t "$FSG_STATE_DIR"/requests/*.run | head -n 1)" .run)
  killbg "$lr"
  "$G" heal --result "$id" >/dev/null 2>&1; eq $? 0 "the KILLed caller's heal healed"
fi

# ======================================================================== heal-hold
if ! skip_case heal-hold; then
  t "runs stay held when Docker is not restored"
  docker_default; install_fake; mem 3G
  touch "$FSG_FAKE/docker/bind-broken"
  heal --docker-variant C > "$C/o" 2>&1; eq $? 8 "restarted, Docker not fully back"
  has "$(grep 'heal incomplete' "$FSG_FAKE/notifications.log")" "Docker not fully restored (bind mount: the container ran" "the reason has no empty part first"
  grep -qx 'variant=C' "$FSG_STATE_DIR/drain/pending" && ok || bad "the hold names the heal's Docker step"
  FSG_RUN_MAX_WAIT_S=1 "$G" run --label after-broken -- true 2> "$C/err"; eq $? 75 "a new run is held"
  has "$(cat "$C/err")" "holding 'after-broken'" "held message"
  has "$(cat "$FSG_FAKE/notifications.log")" "fseventsd-guard release" "the notification says how to release"
  has "$(cat "$FSG_STATE_DIR/docker-intent" 2>/dev/null)" "after_done=1" "the intent stays until Docker verifies"
  "$G" release > "$C/o" 2>&1; eq $? 0 "release"
  absent "$FSG_STATE_DIR/docker-intent" "release clears the intent"
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 0 "runs start after release"

  t "the agent releases a hold once Docker is healthy again"
  docker_default; install_fake; mem 3G
  touch "$FSG_FAKE/docker/bind-broken"
  heal --docker-variant C >/dev/null 2>&1; eq $? 8 "heal exit"
  mem 5000K; "$G" tick >/dev/null 2>&1
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 75 "still held while the bind mount is broken"
  mv "$FSG_FAKE/docker/bind-broken" "$FSG_FAKE/docker/bind-broken.was"
  "$G" tick >/dev/null 2>&1
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 0 "released by the agent"
  has "$(tail -n 1 "$FSG_FAKE/notifications.log")" "released" "notification"
  absent "$FSG_STATE_DIR/docker-intent" "intent cleared"

  t "a trial hold waits for the operator"
  docker_default; install_fake --trial-hours 1
  touch "$FSG_FAKE/docker/bind-broken"
  trial --variant none --label broken > "$C/o" 2>&1; eq $? 8 "trial exit"
  has "$(cat "$C/o")" "fseventsd-guard release" "the trial says how to release"
  mv "$FSG_FAKE/docker/bind-broken" "$FSG_FAKE/docker/bind-broken.was"
  "$G" tick >/dev/null 2>&1
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 75 "the agent does not release a trial hold"
  "$G" release >/dev/null 2>&1; FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 0 "the operator does"

  t "a hold ends at its deadline"
  docker_default; install_fake; mem 3G
  touch "$FSG_FAKE/docker/bind-broken"
  agent_env FSG_FAILED_HOLD_S=1
  heal --docker-variant C >/dev/null 2>&1; eq $? 8 "heal exit"
  sleep 2
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 0 "expired hold ignored"

  # hold_in_place TRIGGER: a hold an earlier heal left (Docker not verified).
  hold_in_place() {
    mkdir -p "$FSG_STATE_DIR/drain/leases"
    printf 'state_version=1\nowner_pid=0\nstarted_epoch=%s\nhold_until_epoch=%s\ntrigger=%s\nreason=test hold\nphase=held-docker-not-restored\nrestore_names=pg redis\n' \
      "$(date +%s)" $(( $(date +%s) + 600 )) "$1" > "$FSG_STATE_DIR/drain/pending"
  }

  t "a standing hold survives a later heal that gives up at the cap or is stopped while draining"
  # The bind mount stays broken, so the agent's hold check keeps the hold too.
  docker_default; install_fake; mem 600M; touch "$FSG_FAKE/docker/bind-broken"
  bg "$G" run --label long -- sleep 60; lr=$LAST_BG; sleep 1
  for tr in manual trial; do
    hold_in_place $tr
    heal --drain-cap 2 > "$C/o" 2>&1; eq $? 4 "$tr hold: the heal gives up at the cap"
    has "$(cat "$FSG_STATE_DIR/drain/pending" 2>/dev/null)" "trigger=$tr" "$tr hold: back after the cap"
    FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 75 "$tr hold: new runs stay held"
  done
  hold_in_place manual
  "$G" heal --drain-cap 30 > "$C/h.out" 2>&1 & hp=$!; BG_PIDS="$BG_PIDS $hp"
  waitfor 20 grep -qs '^phase=draining' "$FSG_STATE_DIR/drain/pending" || bad "the heal drains over the hold"
  agent_stop
  wait "$hp"; eq $? 130 "the agent was stopped while draining"
  has "$(cat "$FSG_STATE_DIR/drain/pending" 2>/dev/null)" "reason=test hold" "the hold is back"
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 75 "new runs stay held"
  ls "$FSG_STATE_DIR"/drain/pending.saved.* >/dev/null 2>&1 && bad "no copy left behind" || ok
  killbg "$lr"

  t "a trial hold in place survives a later heal, verified or not"
  docker_default; install_fake; mem 600M
  hold_in_place trial
  heal > "$C/o" 2>&1; eq $? 0 "healed"
  has "$(cat "$FSG_STATE_DIR/drain/pending" 2>/dev/null)" "trigger=trial" "a verified heal puts the trial hold back"
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 75 "runs wait for the operator"
  echo 4242 > "$FSG_FAKE/fsev/pids"; mem 600M; rm -f "$FSG_PREFIX/Library/Logs/fseventsd-guard/last-restart"
  touch "$FSG_FAKE/docker/bind-broken"
  heal --docker-variant C > "$C/o" 2>&1; eq $? 8 "Docker not verified"
  has "$(cat "$FSG_STATE_DIR/drain/pending" 2>/dev/null)" "trigger=trial" "the heal's own hold stays the operator's"
  mv "$FSG_FAKE/docker/bind-broken" "$FSG_FAKE/docker/bind-broken.was"
  "$G" tick >/dev/null 2>&1
  absent "$FSG_STATE_DIR/docker-intent" "Docker verified at the next tick"
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 75 "the agent does not release it"

  t "the reason joins only the parts it has"
  out=$( FSG_HOME=$GUARD_HOME; . "$GUARD_HOME/lib/common.sh"; . "$GUARD_HOME/lib/docker.sh"
    DK_ERR=; DK_FAILED=c1; BM_DETAIL="not checked"; fsg_docker_why
    DK_ERR="containers not back"; DK_FAILED=c1; BM_DETAIL=; fsg_docker_why
    DK_ERR=; DK_FAILED=; BM_DETAIL="x"; fsg_docker_why
    DK_ERR="e"; DK_FAILED=c1; BM_DETAIL="x"; fsg_docker_why nobind )
  eq "$out" "containers: c1; bind mount: not checked
containers not back containers: c1
bind mount: x
e containers: c1" "joined"
fi

# ======================================================================== docker-silent
if ! skip_case docker-silent; then
  for v in A B; do
    t "heal variant $v restarts a Docker Desktop that runs but does not answer"
    docker_default; install_fake; mem 3G
    # Engine work scans (exec sessions, containers) would each wait out their own 15 s timeout on the wedged engine.
    export FSG_DETECT_DOCKER_EXECS=0 FSG_DETECT_DOCKER_CONTAINERS=0; agent_env FSG_DETECT_DOCKER_EXECS=0 FSG_DETECT_DOCKER_CONTAINERS=0
    touch "$FSG_FAKE/docker/hang"; : > "$FSG_FAKE/calls.log"
    heal --docker-variant $v > "$C/o" 2>&1; eq $? 0 "healed once Docker verified ($(tail -n 1 "$C/o"))"
    has "$(cat "$FSG_LOG")" "runs but does not answer within 2s" "silent is not stopped"
    case $v in
      A) has "$(cat "$FSG_LOG")" "docker variant A -> C" "A cannot list containers: C"
         before "$FSG_FAKE/calls.log" "sudo -n /" "docker desktop restart"
         has "$(grep 'fseventsd healed' "$FSG_FAKE/notifications.log")" "Docker Desktop restarted unchecked: Docker did not answer docker info (wedged)" "the result names the unchecked restart"
         grep -q '^docker_restart_unchecked=Docker Desktop restarted unchecked: ' "$(cat "$FSG_STATE_DIR/last-heal-dir")/result.txt" && ok || bad "recorded" ;;
      B) before "$FSG_FAKE/calls.log" "docker desktop stop" "sudo -n /"
         before "$FSG_FAKE/calls.log" "sudo -n /" "docker desktop start"
         has "$(grep 'fseventsd healed' "$FSG_FAKE/notifications.log")" "Docker step B ran unchecked: Docker did not answer docker info (wedged), so its containers were not listed" "the result names the unchecked stop"
         grep -q '^docker_restart_unchecked=Docker step B ran unchecked: ' "$(cat "$FSG_STATE_DIR/last-heal-dir")/result.txt" && ok || bad "recorded" ;;
    esac
    grep -q '^bind_mount=ok' "$(cat "$FSG_STATE_DIR/last-heal-dir")/result.txt" && ok || bad "bind mount verified, not skipped"
    has "$(grep 'cutting running work' "$FSG_FAKE/notifications.log")" "Docker does not answer docker info (wedged), so it did not list its containers and --rm containers with an anonymous volume could not be checked" "says the --rm volumes went unchecked"
    hasnt "$(cat "$FSG_FAKE/notifications.log")" "heal refused" "a wedged Docker is not refused"
  done

  t "a manual heal of a Docker that answers nothing does not wait for the work it cannot list"
  docker_default; install_fake; mem 3G
  echo "pg 1" > "$FSG_FAKE/docker/execs"
  touch "$FSG_FAKE/docker/hang"; : > "$FSG_FAKE/calls.log"
  heal --docker-variant B > "$C/o" 2>&1; eq $? 0 "healed, not given up at the cap ($(tail -n 1 "$C/o"))"
  hasnt "$(cat "$FSG_FAKE/notifications.log")" "unknown" "no unknown work held it"
  has "$(cat "$FSG_LOG")" "DRAIN drained" "drained"
  grep -q '^drain_exec_unknown=0' "$(cat "$FSG_STATE_DIR/last-heal-dir")/result.txt" && ok || bad "recorded as known"

  t "a Docker Desktop that stays silent is not reported healed and runs stay held"
  docker_default; install_fake; mem 3G
  export FSG_DETECT_DOCKER_EXECS=0 FSG_DETECT_DOCKER_CONTAINERS=0 FSG_DOCKER_TIMEOUT_S=4; agent_env FSG_DETECT_DOCKER_EXECS=0 FSG_DETECT_DOCKER_CONTAINERS=0 FSG_DOCKER_TIMEOUT_S=4
  touch "$FSG_FAKE/docker/hang" "$FSG_FAKE/docker/hang-sticky"
  heal --docker-variant C > "$C/o" 2>&1; eq $? 8 "restarted, Docker not verified"
  hasnt "$(cat "$FSG_STATE_DIR/last-heal")" " healed " "not recorded as healed"
  hasnt "$(cat "$FSG_FAKE/notifications.log")" "fseventsd healed" "no healed notification"
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 75 "new runs held"
  mem 5000K; "$G" tick >/dev/null 2>&1
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 75 "the agent keeps the hold while Docker is silent"
  rm -f "$FSG_FAKE/docker/hang" "$FSG_FAKE/docker/hang-sticky"
  "$G" tick >/dev/null 2>&1
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 0 "released once Docker answers and verifies"
fi

# ======================================================================== docker-stop
if ! skip_case docker-stop; then
  # stop_record: variant B's stop record of the last heal.
  stop_record() { cat "$(cat "$FSG_STATE_DIR/last-heal-dir")/docker-stop.txt" 2>/dev/null; }
  heal_result() { cat "$(cat "$FSG_STATE_DIR/last-heal-dir")/result.txt" 2>/dev/null; }

  t "B sees Docker Desktop stopped once its processes and sockets are gone, though status fails"
  docker_default; install_fake; mem 3G
  touch "$FSG_FAKE/docker/status-fail" "$FSG_FAKE/docker/sock-gone-on-stop"; echo 20 > "$FSG_FAKE/docker/status-delay"
  heal --docker-variant B > "$C/o" 2>&1; eq $? 0 "healed ($(tail -n 1 "$C/o"))"
  has "$(cat "$FSG_LOG")" "stopped (no Docker Desktop process runs and its sockets are gone)" "decided by processes and sockets"
  hasnt "$(cat "$FSG_LOG")" "before-step failed" "not a failed stop"
  has "$(stop_record)" "backend pid before the stop: 7777" "the record has the backend pid"
  has "$(stop_record)" "== stop rc=0 in " "the record has the stop's code and duration"
  has "$(stop_record)" "poll 1 +" "the record has the polls"
  has "$(stop_record)" "procs=no backend=none sockets=none status=- rc=- in -s: (not asked)" "status not asked once processes and sockets decide"
  has "$(stop_record)" "decision: stopped" "the record has the decision"
  has "$(heal_result)" "docker_stop=rc=0 in " "result.txt has the stop"
  v=$(heal_result | sed -n 's/^docker_before_s=//p'); [ "${v:-99}" -lt 8 ] && ok || bad "the stop did not wait out a slow status (docker_before_s=$v)"
  exists "$FSG_FAKE/docker/docker.sock" "Docker Desktop's start put its socket back"

  t "B asks a slow or failing status only within its bound, and gives up at FSG_DESKTOP_STOP_WAIT_S"
  docker_default; install_fake; mem 3G
  agent_env FSG_DESKTOP_STOP_WAIT_S=8
  # The user socket stays: processes and sockets never decide, and status is slow.
  echo 20 > "$FSG_FAKE/docker/status-delay"
  s=$(date +%s); heal --docker-variant B > "$C/o" 2>&1; eq $? 0 "the heal goes on and heals ($(tail -n 1 "$C/o"))"
  has "$(cat "$FSG_LOG")" "Docker Desktop did not stop within 8s of docker desktop stop (still there after 8s: processes no, sockets $FSG_FAKE/docker/docker.sock" "the reason names what was left"
  has "$(stop_record)" "rc=124 in" "a status poll was cut at its bound"
  has "$(stop_record)" "decision: not-stopped" "decision recorded"
  v=$(heal_result | sed -n 's/^docker_before_s=//p'); [ "${v:-99}" -le 16 ] && ok || bad "the wait is bounded (docker_before_s=$v)"
  rm -f "$FSG_FAKE/docker/status-delay"
  echo 4242 > "$FSG_FAKE/fsev/pids"; mem 3G; rm -f "$FSG_PREFIX/Library/Logs/fseventsd-guard/last-restart"
  touch "$FSG_FAKE/docker/status-fail"
  heal --docker-variant B > "$C/o" 2>&1; eq $? 0 "healed again"
  has "$(stop_record)" "backend.sock: connect: no such file or directory" "the raw status error is recorded"

  t "B: something else starts Docker Desktop right after the stop"
  docker_default; install_fake; mem 3G
  touch "$FSG_FAKE/docker/foreign-start"
  heal --docker-variant B > "$C/o" 2>&1; eq $? 0 "healed ($(tail -n 1 "$C/o"))"
  has "$(cat "$FSG_LOG")" "something else started Docker Desktop during the heal (backend pid 8888; before the stop: 7777)" "logged"
  hasnt "$(cat "$FSG_LOG")" "before-step failed" "not reported as a failed stop"
  has "$(grep 'fseventsd healed' "$FSG_FAKE/notifications.log")" "something else started Docker Desktop during the heal" "the notice says it"
  has "$(heal_result)" "docker_started_by_other=something else started" "recorded"
  has "$(stop_record)" "decision: started-by-other" "the stop record says it"
  hasnt "$(grep -v "^osascript" "$FSG_FAKE/calls.log")" "8888" "the guard does not kill it"

  t "B: something else starts Docker Desktop during the fseventsd restart"
  docker_default; install_fake; mem 3G
  echo 3 > "$FSG_FAKE/sudo-delay"
  foreign_at_restart() {
    waitfor 60 grep -qs '^phase=restarting' "$FSG_STATE_DIR/drain/pending" &&
      echo 8888 > "$FSG_FAKE/docker/backend-pid" && echo running > "$FSG_FAKE/docker/desktop"
  }
  bg foreign_at_restart
  heal --docker-variant B > "$C/o" 2>&1; eq $? 0 "healed ($(tail -n 1 "$C/o"))"
  has "$(cat "$FSG_LOG")" "something else started Docker Desktop during the heal (backend pid 8888; before the stop: 7777)" "logged"
  has "$(grep 'fseventsd healed' "$FSG_FAKE/notifications.log")" "something else started Docker Desktop" "the notice says it"
fi

# ======================================================================== bind-probe
if ! skip_case bind-probe; then
  # probe_dir: BM_SHARED and BM_DIR as fsg_probe_dir picks them, HOME=$C/home.
  probe_dir() {
    ( HOME=$C/home; FSG_HOME=$GUARD_HOME; . "$GUARD_HOME/lib/common.sh"; . "$GUARD_HOME/lib/lease.sh"
      . "$GUARD_HOME/lib/drain.sh"; . "$GUARD_HOME/lib/docker.sh"
      fsg_init_paths; fsg_load_config; fsg_probe_dir; echo "${BM_SHARED:--} $BM_DIR" )
  }
  sharing() { # dirs...: Docker Desktop's File Sharing list
    local d j=""
    for d in "$@"; do j="${j:+$j,}\"$d\""; done
    printf '{"AutoStart":false,"FilesharingDirectories":[%s]}\n' "$j" > "$FSG_DESKTOP_SETTINGS"
  }

  t "the probe dir follows Docker Desktop's File Sharing list"
  eq "$(probe_dir)" "- $FSG_STATE_DIR/mountprobe" "no settings file: default sharing, the state dir"
  echo '{"AutoStart":false}' > "$FSG_DESKTOP_SETTINGS"
  eq "$(probe_dir)" "- $FSG_STATE_DIR/mountprobe" "no FilesharingDirectories: default sharing"
  sharing "$C/home"
  eq "$(probe_dir)" "1 $FSG_STATE_DIR/mountprobe" "the state dir is in a shared folder"
  mkdir -p "$C/home/.local/share" "$C/home/Projects"
  sharing /Volumes/elsewhere "$C/home/.local/share" "$C/home/Projects"
  eq "$(probe_dir)" "1 $C/home/.local/share/.fseventsd-guard-mountprobe" "the first shared folder under home"
  sharing "$C/home/sta" /Volumes/elsewhere
  eq "$(probe_dir)" "0 $FSG_STATE_DIR/mountprobe" "whole components only, nothing shared under home: not shared"
  sharing
  eq "$(probe_dir)" "0 $FSG_STATE_DIR/mountprobe" "an empty list shares nothing"
  sharing "$C/home/Projects"
  eq "$(FSG_PROBE_DIR=$C/home/Projects/p probe_dir)" "1 $C/home/Projects/p" "FSG_PROBE_DIR in a shared folder"
  eq "$(FSG_PROBE_DIR=$C/other probe_dir)" "0 $C/other" "FSG_PROBE_DIR is kept even when not shared"

  t "a probe dir Docker Desktop does not share skips the bind check, not fails it"
  docker_default; install_fake; mem 3G
  touch "$FSG_FAKE/docker/mounts-denied"
  heal --docker-variant B > "$C/o" 2>&1; eq $? 0 "healed, not restored-partly ($(tail -n 1 "$C/o"))"
  grep -q '^bind_mount=skipped the probe dir .* is not shared with Docker Desktop (mounts denied)' "$(cat "$FSG_STATE_DIR/last-heal-dir")/result.txt" && ok || bad "recorded as skipped"
  has "$(grep 'fseventsd healed' "$FSG_FAKE/notifications.log")" "Bind mount check skipped: the probe dir" "the notice says it"
  absent "$FSG_STATE_DIR/drain/pending" "no hold"; absent "$FSG_STATE_DIR/docker-intent" "verified"
  eq "$(ls -A "$FSG_STATE_DIR/mountprobe" 2>/dev/null)" "" "the probe left no file"
  absent "$FSG_STATE_DIR/mountprobe.out" "nor its output"

  t "the probe removes its file when no probe container runs"
  docker_default; install_fake; mem 3G
  agent_env FSG_PROBE_IMAGE=nosuch:1
  heal --docker-variant B > "$C/o" 2>&1; eq $? 8 "no probe container could run"
  has "$(grep 'heal incomplete' "$FSG_FAKE/notifications.log")" "Docker not fully restored (bind mount: no probe container could run (tried: nosuch:1))" "reason without a leading separator"
  hasnt "$(cat "$FSG_FAKE/notifications.log")" "(; " "no empty part joined"
  eq "$(ls -A "$FSG_STATE_DIR/mountprobe" 2>/dev/null)" "" "no file left after a failed run"

  t "the probe removes its file after a broken round trip"
  docker_default; install_fake; mem 3G
  touch "$FSG_FAKE/docker/bind-broken"
  heal --docker-variant B > "$C/o" 2>&1; eq $? 8 "round trip broken"
  has "$(grep 'heal incomplete' "$FSG_FAKE/notifications.log" | tail -n 1)" "Docker not fully restored (bind mount: the container ran (alpine:3) but the round trip did not match" "reason without a leading separator"
  eq "$(ls -A "$FSG_STATE_DIR/mountprobe" 2>/dev/null)" "" "no file left after a broken round trip"

  t "doctor warns when Docker Desktop does not share the probe dir"
  docker_default; install_fake
  sharing /Volumes/elsewhere
  "$G" doctor --prefix "$FSG_PREFIX" > "$C/doc.out" 2>/dev/null
  has "$(cat "$C/doc.out")" "bind-mount probe dir $FSG_STATE_DIR/mountprobe is not in Docker Desktop's File Sharing list" "warned"
  sharing "$C/home"
  "$G" doctor --prefix "$FSG_PREFIX" > "$C/doc.out" 2>/dev/null
  hasnt "$(cat "$C/doc.out")" "File Sharing list" "no warning once shared"
fi

# ======================================================================== heal-signal
if ! skip_case heal-signal; then
  # term_agent FILE PATTERN: a heal request whose agent tick gets TERM once PATTERN
  # shows in FILE. Sets HP (the waiting caller) and AP (the tick).
  term_agent() { # file pattern
    "$G" heal --docker-variant B > "$C/heal.out" 2>&1 & HP=$!; BG_PIDS="$BG_PIDS $HP"
    waitfor 30 grep -qs "$2" "$1" || bad "the heal reached $2"
    AP=$(agent_pid); kill -TERM "$AP"; agent_wait
  }

  t "an agent stopped during the restart keeps runs held when a container cannot start"
  docker_default; install_fake; mem 3G
  containers "c1 pg running healthy postgres:17 unless-stopped 0" "c3 job running none alpine:3 no 0"
  echo c3 > "$FSG_FAKE/docker/start-fail"; echo 6 > "$FSG_FAKE/sudo-delay"
  term_agent "$FSG_STATE_DIR/drain/pending" '^phase=restarting'
  wait "$HP"; eq $? 130 "the request ends with 130"
  has "$(cat "$C/heal.out")" "the agent was stopped during this heal" "the caller says why"
  has "$(cat "$FSG_FAKE/calls.log")" "docker desktop start" "the trap restored Docker"
  has "$(cat "$FSG_STATE_DIR/drain/pending" 2>/dev/null)" "hold_until_epoch=" "a hold, not a release"
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 75 "new runs held"
  has "$(cat "$FSG_FAKE/notifications.log")" "heal interrupted" "notified"
  absent "$FSG_STATE_DIR/heal.lock" "lock released"

  t "a signal during the container wait does not release runs onto an unhealthy container"
  docker_default; install_fake; mem 3G
  containers "c1 pg running healthy postgres:17 unless-stopped 0"
  echo "c1 starting" > "$FSG_FAKE/docker/health-after-start"
  export FSG_CONTAINER_TIMEOUT_S=8; agent_env FSG_CONTAINER_TIMEOUT_S=8
  term_agent "$FSG_FAKE/calls.log" 'State.Health'
  wait "$HP"; eq $? 130 "the request ends with 130"
  has "$(cat "$FSG_STATE_DIR/drain/pending" 2>/dev/null)" "hold_until_epoch=" "a hold, not a release"
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 75 "new runs held"

  t "an agent stopped during the restart releases runs once Docker verifies"
  docker_default; install_fake; mem 3G
  echo 6 > "$FSG_FAKE/sudo-delay"
  term_agent "$FSG_STATE_DIR/drain/pending" '^phase=restarting'
  wait "$HP"; eq $? 130 "the request ends with 130"
  has "$(cat "$C/heal.out")" "Docker was restored and verified" "the caller says Docker is back"
  has "$(cat "$FSG_LOG")" "Docker verified after the interrupted heal" "verified before the release"
  before "$FSG_FAKE/calls.log" "docker desktop start" "docker run --rm"
  absent "$FSG_STATE_DIR/drain/pending" "released"
  absent "$FSG_STATE_DIR/docker-intent" "intent cleared"
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 0 "runs start"

  t "an agent stopped before C's restart names a restart of a Docker that answers nothing, run unchecked"
  docker_default; install_fake; mem 3G
  echo 6 > "$FSG_FAKE/sudo-delay"
  "$G" heal --docker-variant C > "$C/heal.out" 2>&1 & HP=$!; BG_PIDS="$BG_PIDS $HP"
  waitfor 30 grep -qs '^phase=restarting' "$FSG_STATE_DIR/drain/pending" || bad "the heal reached the restart"
  touch "$FSG_FAKE/docker/hang"
  AP=$(agent_pid); kill -TERM "$AP"; agent_wait
  wait "$HP"; eq $? 130 "the request ends with 130"
  has "$(cat "$FSG_FAKE/calls.log")" "docker desktop restart" "the trap restarted Docker Desktop"
  has "$(grep 'Docker restored' "$FSG_FAKE/notifications.log")" "Docker Desktop restarted unchecked: Docker did not answer docker info (wedged)" "the notice names it"
  absent "$FSG_STATE_DIR/docker-intent" "verified"

  # term_mid_call FILE PATTERN: like term_agent, with a leased run held by the drain
  # that logs run-started to calls.log once it is released. Sets HP, AP and RP.
  term_mid_call() { # file pattern
    "$G" heal --docker-variant B > "$C/heal.out" 2>&1 & HP=$!; BG_PIDS="$BG_PIDS $HP"
    waitfor 30 grep -qs -- "$2" "$1" || bad "the heal reached $2"
    "$G" run --label held -- /bin/sh -c 'echo run-started >> "$FSG_FAKE/calls.log"' > "$C/run.out" 2>&1 & RP=$!; BG_PIDS="$BG_PIDS $RP"
    sleep 0.5; AP=$(agent_pid); kill -TERM "$AP"; agent_wait
  }

  t "an agent stopped during the Docker Desktop stop lets it finish, then starts Docker"
  docker_default; install_fake; mem 3G
  echo 4 > "$FSG_FAKE/docker/stop-delay"
  term_mid_call "$FSG_FAKE/calls.log" 'docker desktop stop --timeout'
  wait "$HP"; eq $? 130 "the request ends with 130"
  waitfor 10 gone "$RP"; wait "$RP"; eq $? 0 "the held run started"
  before "$FSG_FAKE/calls.log" "stop-done" "docker desktop start"
  before "$FSG_FAKE/calls.log" "docker desktop start" "docker run --rm"
  before "$FSG_FAKE/calls.log" "docker run --rm" "run-started"
  eq "$(cat "$FSG_FAKE/docker/desktop")" running "Docker Desktop ends running"
  eq "$(awk '$3 != "running"' "$FSG_FAKE/docker/containers")" "" "every container running"
  has "$(cat "$C/heal.out")" "Docker was restored and verified" "the caller says Docker is back"
  absent "$FSG_STATE_DIR/docker-intent" "intent cleared"
  absent "$FSG_STATE_DIR/drain/pending" "released"

  t "an agent stopped during the restart lets the root helper finish before Docker comes back"
  docker_default; install_fake; mem 3G
  echo 4 > "$FSG_FAKE/sudo-delay"
  term_mid_call "$FSG_STATE_DIR/drain/pending" '^phase=restarting'
  wait "$HP"; eq $? 130 "the request ends with 130"
  waitfor 10 gone "$RP"; wait "$RP"; eq $? 0 "the held run started"
  before "$FSG_FAKE/calls.log" "kill -TERM 4242" "docker desktop start"
  before "$FSG_FAKE/calls.log" "kill -TERM 4242" "run-started"
  before "$FSG_FAKE/calls.log" "docker run --rm" "run-started"
  has "$(cat "$FSG_LOG")" "HEAL helper rc=0 (restarted)" "the helper's outcome is recorded"
  exists "$FSG_STATE_DIR/last-restart" "the restart is stamped"
  eq "$(cat "$FSG_FAKE/docker/desktop")" running "Docker Desktop ends running"
  absent "$FSG_STATE_DIR/docker-intent" "intent cleared"
fi

# dead_intent VARIANT [AFTER_DONE [HEALTH]]: the Docker intent of a heal whose tick
# died before its after-step (AFTER_DONE 1: after it, Docker not verified). HEALTH:
# its restore_health; without it, an intent of a guard that did not record it.
dead_intent() {
  local dead dl
  bg sleep 60; dead=$LAST_BG; dl=$(lstart "$dead"); killbg "$dead"
  printf 'state_version=1\nowner_pid=%s\nowner_lstart=%s\nstarted_epoch=%s\nrequest=\ntrigger=wave\nvariant=%s\nkind=desktop\nstate=running\nendpoint=unix://%s\nrestore_ids=c1 c2\nrestore_names=pg redis\nheal_dir=\nafter_done=%s\nhold_epoch=\n' \
    "$dead" "$dl" "$(date +%s)" "$1" "$FSG_FAKE/docker/docker.sock" "${2:-0}" > "$FSG_STATE_DIR/docker-intent"
  [ -n "${3:-}" ] && echo "restore_health=$3" >> "$FSG_STATE_DIR/docker-intent"
  DEAD=$dead
}
# ======================================================================== heal-kill
if ! skip_case heal-kill; then

  t "an agent killed outright leaves a Docker intent and the next tick restores Docker"
  docker_default; install_fake; mem 3G
  echo 6 > "$FSG_FAKE/sudo-delay"; echo 0 > "$FSG_FAKE/sudo-rc"
  "$G" heal --docker-variant B > "$C/heal.out" 2>&1 & hp=$!; BG_PIDS="$BG_PIDS $hp"
  waitfor 20 grep -qs '^phase=restarting' "$FSG_STATE_DIR/drain/pending" || bad "the heal reached the restart"
  # The waiting caller kicks the agent once its tick is dead; that kick starts nothing
  # here, so the tick below is the one that recovers.
  touch "$FSG_FAKE/kickstart-off"
  ap=$(agent_pid); kill -KILL "$ap"; agent_wait
  eq "$(cat "$FSG_FAKE/docker/desktop")" stopped "Docker left down"
  has "$(cat "$FSG_STATE_DIR/docker-intent" 2>/dev/null)" "variant=B" "the intent survives the kill"
  out=$("$G" status 2>&1); has "$out" "docker: NOT VERIFIED - the heal of tick pid $ap" "status shows it"
  out=$("$G" status --json); json_ok "$out"
  eq "$(jget "$out" 'd["docker_intent"]["owner_pid"]')" "$ap" "status --json owner"
  eq "$(jget "$out" 'd["docker_intent"]["after_step_done"]')" False "status --json after-step"
  out=$("$G" doctor 2>&1); has "$out" "Docker NOT VERIFIED - the heal of tick pid $ap" "doctor shows it"
  mem 5000K; rm -f "$FSG_FAKE/sudo-delay"; : > "$FSG_FAKE/calls.log"
  "$G" tick >/dev/null 2>&1; eq $? 0 "tick"
  has "$(cat "$FSG_FAKE/calls.log")" "docker desktop start" "the tick ran the after-step"
  eq "$(cat "$FSG_FAKE/docker/desktop")" running "Docker running again"
  eq "$(awk '$3 != "running"' "$FSG_FAKE/docker/containers")" "" "every container running again"
  has "$(cat "$FSG_FAKE/calls.log")" "docker run --rm" "verified with a bind mount"
  absent "$FSG_STATE_DIR/docker-intent" "intent cleared once Docker verified"
  absent "$FSG_STATE_DIR/drain/pending" "the dead tick's drain is gone"
  absent "$FSG_STATE_DIR/heal.lock" "lock released"
  has "$(cat "$FSG_FAKE/notifications.log")" "Docker restored" "notified"
  out=$("$G" status --json); eq "$(jget "$out" 'd["docker_intent"]')" None "status is clear"
  wait "$hp"; eq $? 130 "the waiting caller gets 130"
  has "$(cat "$C/heal.out")" "the agent then restored Docker and it verified" "naming the recovery's outcome"

  t "a tick killed outright after Docker stopped holds runs without the agent until expiry or release"
  docker_default; install_fake; mem 3G
  # The restart stays in flight until the tick is killed, however slow the machine.
  echo 600 > "$FSG_FAKE/sudo-delay"; echo 0 > "$FSG_FAKE/sudo-rc"
  "$G" heal --docker-variant A > "$C/heal.out" 2>&1 & hp=$!; BG_PIDS="$BG_PIDS $hp"
  waitfor 60 grep -qs '^phase=restarting' "$FSG_STATE_DIR/drain/pending" || bad "the heal reached the restart"
  # No tick runs from here on: the dead tick wrote no hold and nothing recovers.
  touch "$FSG_FAKE/kickstart-off"
  # The tick leads its own process group (stubs/launchctl): the restart goes with it.
  ap=$(agent_pid); kill -KILL -- "-$ap"; agent_wait
  rm -f "$FSG_FAKE/sudo-delay"; mem 5000K
  eq "$(awk '$3 == "running"' "$FSG_FAKE/docker/containers")" "" "Docker's containers left stopped"
  hasnt "$(cat "$FSG_STATE_DIR/drain/pending" 2>/dev/null)" "hold_until_epoch=" "no hold written"
  out=$(FSG_RUN_MAX_WAIT_S=1 FSG_RUN_POLL_S=1 "$G" run --label after-kill -- true 2>&1); eq $? 75 "a guarded run stays held"
  has "$out" "holding 'after-kill' while fseventsd is healed (phase docker-not-verified" "the hold message"
  has "$out" "gave up after waiting" "the FSG_RUN_MAX_WAIT_S rule"
  out=$(FSG_RUN_MAX_WAIT_S=1 FSG_RUN_POLL_S=1 FSG_RUN_ON_TIMEOUT=proceed "$G" run --label after-kill -- true 2>&1); eq $? 0 "FSG_RUN_ON_TIMEOUT=proceed"
  has "$out" "starting anyway" "said"
  # Expiry: FSG_FAILED_HOLD_S after the intent's start, or after its after-step action.
  now=$(date +%s); old=$((now - 4000))
  sed "s/^started_epoch=.*/started_epoch=$old/" "$FSG_STATE_DIR/docker-intent" > "$C/intent" && cp "$C/intent" "$FSG_STATE_DIR/docker-intent"
  FSG_RUN_MAX_WAIT_S=1 FSG_RUN_POLL_S=1 "$G" run -- true 2>/dev/null; eq $? 0 "runs start once the intent is FSG_FAILED_HOLD_S old"
  sed "s/^action_ran=.*/action_ran=1/; s/^action_epoch=.*/action_epoch=$now/" "$C/intent" > "$FSG_STATE_DIR/docker-intent"
  FSG_RUN_MAX_WAIT_S=1 FSG_RUN_POLL_S=1 "$G" run -- true 2>/dev/null; eq $? 75 "held again while its after-step action is recent"
  "$G" release > "$C/o" 2>&1; eq $? 0 "release"
  has "$(cat "$C/o")" "released: held runs start now" "release says runs start"
  absent "$FSG_STATE_DIR/docker-intent" "release cleared the intent"
  FSG_RUN_MAX_WAIT_S=1 FSG_RUN_POLL_S=1 "$G" run -- true 2>/dev/null; eq $? 0 "runs start after release"
  dead_intent C
  FSG_RUN_MAX_WAIT_S=1 FSG_RUN_POLL_S=1 "$G" run -- true 2>/dev/null; eq $? 0 "a C intent before its restart holds nothing"
  killbg "$hp"

  t "an agent killed during its EXIT trap's restore is finished by the next tick"
  docker_default; install_fake; mem 3G
  echo 6 > "$FSG_FAKE/sudo-delay"; echo 0 > "$FSG_FAKE/sudo-rc"; echo 8 > "$FSG_FAKE/docker/start-delay"
  "$G" heal --docker-variant B > "$C/heal.out" 2>&1 & hp=$!; BG_PIDS="$BG_PIDS $hp"
  waitfor 20 grep -qs '^phase=restarting' "$FSG_STATE_DIR/drain/pending" || bad "the heal reached the restart"
  ap=$(agent_pid); kill -TERM "$ap"
  waitfor 20 grep -q 'docker desktop start' "$FSG_FAKE/calls.log" || bad "the trap began the restore"
  touch "$FSG_FAKE/kickstart-off"; kill -KILL "$ap"; agent_wait
  rm -f "$FSG_FAKE/docker/start-delay" "$FSG_FAKE/sudo-delay"
  eq "$(cat "$FSG_FAKE/docker/desktop")" stopped "Docker still down"
  has "$(cat "$FSG_STATE_DIR/drain/pending" 2>/dev/null)" "hold_until_epoch=" "the trap held runs first"
  has "$(cat "$FSG_STATE_DIR/docker-intent" 2>/dev/null)" "after_done=0" "the intent says the restore did not finish"
  mem 5000K; : > "$FSG_FAKE/calls.log"
  "$G" tick >/dev/null 2>&1
  has "$(cat "$FSG_FAKE/calls.log")" "docker desktop start" "the tick ran the after-step"
  absent "$FSG_STATE_DIR/docker-intent" "intent cleared"
  absent "$FSG_STATE_DIR/drain/pending" "hold released onto a verified Docker"
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 0 "runs start"
  wait "$hp"; eq $? 130 "the waiting caller gets 130"

  t "a dead heal's intent that does not verify holds runs once, then releases them"
  docker_default; install_fake
  docker desktop stop >/dev/null 2>&1; touch "$FSG_FAKE/docker/bind-broken"
  dead_intent B; : > "$FSG_FAKE/calls.log"; : > "$FSG_FAKE/notifications.log"
  "$G" tick >/dev/null 2>&1
  eq "$(cat "$FSG_FAKE/docker/desktop")" running "Docker started"
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 75 "runs held while the bind mount is broken"
  has "$(cat "$FSG_FAKE/notifications.log")" "heal interrupted" "notified"
  "$G" tick >/dev/null 2>&1
  eq "$(grep -c 'desktop start' "$FSG_FAKE/calls.log")" 1 "the after-step runs once"
  eq "$(grep -c 'heal interrupted' "$FSG_FAKE/notifications.log")" 1 "notified once"
  mv "$FSG_FAKE/docker/bind-broken" "$FSG_FAKE/docker/bind-broken.was"
  "$G" tick >/dev/null 2>&1
  absent "$FSG_STATE_DIR/docker-intent" "intent cleared once Docker verified"
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 0 "released"
  has "$(tail -n 1 "$FSG_FAKE/notifications.log")" "released" "release notified"

  t "a dead heal's hold is released once its containers run again under new ids"
  docker_default; install_fake; mem 3G
  touch "$FSG_FAKE/docker/bind-broken"
  heal --docker-variant C >/dev/null 2>&1; eq $? 8 "heal exit"
  # docker compose up -d: same names, new ids.
  containers "c7 pg running healthy postgres:17 unless-stopped 0" "c8 redis running none redis:7 unless-stopped 0"
  rm -f "$FSG_FAKE/docker/bind-broken"; mem 5000K
  "$G" tick >/dev/null 2>&1
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 0 "released"
  absent "$FSG_STATE_DIR/docker-intent" "intent cleared"
  hasnt "$("$G" status 2>&1)" "NOT VERIFIED" "status is clear"

  t "a dead heal's recovery starts stopped containers recreated under its names, across ticks"
  docker_default; install_fake
  # docker compose up --no-start: same names, new ids, not running.
  containers "c7 pg exited healthy postgres:17 unless-stopped 1" "c8 redis exited none redis:7 unless-stopped 1"
  echo c7 > "$FSG_FAKE/docker/start-fail"
  dead_intent A; : > "$FSG_FAKE/calls.log"
  "$G" tick >/dev/null 2>&1
  has "$(cat "$FSG_FAKE/calls.log")" "docker start pg redis" "started by name, not by the dead ids"
  eq "$(awk '$1 == "c8" { print $3 }' "$FSG_FAKE/docker/containers")" running "redis's replacement runs"
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 75 "pg cannot start yet: runs held"
  has "$(cat "$FSG_STATE_DIR/docker-intent" 2>/dev/null)" "after_done=0" "the restore stays to retry"
  has "$("$G" status 2>&1)" "not every container started" "status says so"
  rm -f "$FSG_FAKE/docker/start-fail"
  "$G" tick >/dev/null 2>&1
  eq "$(awk '$1 == "c7" { print $3 }' "$FSG_FAKE/docker/containers")" running "the next tick starts pg's replacement"
  absent "$FSG_STATE_DIR/docker-intent" "intent cleared"
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 0 "released"

  t "a heal that could not start a container leaves it to the agent, which starts it"
  docker_default; install_fake; mem 3G
  containers "c1 pg running healthy postgres:17 unless-stopped 0" "c3 job running none alpine:3 no 0"
  echo c3 > "$FSG_FAKE/docker/start-fail"
  heal --docker-variant B >/dev/null 2>&1; eq $? 8 "not healed: job did not start"
  has "$(cat "$FSG_STATE_DIR/docker-intent" 2>/dev/null)" "after_done=0" "the start stays to retry"
  rm -f "$FSG_FAKE/docker/start-fail"; mem 5000K
  "$G" tick >/dev/null 2>&1
  eq "$(awk '$1 == "c3" { print $3 }' "$FSG_FAKE/docker/containers")" running "the tick starts it"
  absent "$FSG_STATE_DIR/docker-intent" "intent cleared"
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 0 "released"

  t "a container that keeps failing to start is dropped after two passes and named"
  docker_default; install_fake; mem 3G
  containers "c1 pg running healthy postgres:17 unless-stopped 0" "c3 job running none alpine:3 no 0"
  echo c3 > "$FSG_FAKE/docker/start-fail"
  heal --docker-variant B >/dev/null 2>&1; eq $? 8 "not healed: job did not start"
  has "$(cat "$FSG_STATE_DIR/docker-intent" 2>/dev/null)" "fails=job:1:" "the heal's after-step is the first failed pass"
  mem 5000K; : > "$FSG_FAKE/notifications.log"
  # A tick kicked seconds after the heal is not a second failed pass.
  "$G" tick >/dev/null 2>&1
  has "$(cat "$FSG_STATE_DIR/docker-intent" 2>/dev/null)" "fails=job:1:" "a pass within the agent interval does not count"
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 75 "runs still held"
  sleep 1; FSG_AGENT_INTERVAL_S=1 "$G" tick >/dev/null 2>&1
  absent "$FSG_STATE_DIR/docker-intent" "the second failed pass, an interval later, drops it and Docker verifies"
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 0 "runs released"
  has "$(cat "$FSG_FAKE/notifications.log")" "Dropped from the restore set after 2 failed passes, left as they are (start them by hand): job" "named"
  eq "$(awk '$1 == "c3" { print $3 }' "$FSG_FAKE/docker/containers")" exited "left as it is"

  t "a container that runs but is not healthy yet is never dropped"
  docker_default; install_fake; mem 3G
  echo "c1 starting" > "$FSG_FAKE/docker/health-after-start"
  heal --docker-variant B >/dev/null 2>&1; eq $? 8 "not verified: pg was healthy and is not yet"
  has "$(cat "$FSG_STATE_DIR/docker-intent" 2>/dev/null)" "restore_health=healthy none" "the intent keeps each one's health before the heal"
  hasnt "$(cat "$FSG_STATE_DIR/docker-intent" 2>/dev/null)" "pg:" "no failed pass counted"
  mem 5000K; : > "$FSG_FAKE/notifications.log"
  sleep 1; FSG_AGENT_INTERVAL_S=1 "$G" tick >/dev/null 2>&1
  sleep 1; FSG_AGENT_INTERVAL_S=1 "$G" tick >/dev/null 2>&1
  exists "$FSG_STATE_DIR/docker-intent" "still restoring pg"
  hasnt "$(cat "$FSG_STATE_DIR/docker-intent" 2>/dev/null)" "pg:" "still no failed pass"
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 75 "runs held while pg is unhealthy"
  containers "c1 pg running healthy postgres:17 unless-stopped 0" "c2 redis running none redis:7 unless-stopped 0"
  "$G" tick >/dev/null 2>&1
  absent "$FSG_STATE_DIR/docker-intent" "verified once pg is healthy"
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 0 "released"
  hasnt "$(cat "$FSG_FAKE/notifications.log")" "Dropped" "nothing dropped"

  t "a container already unhealthy before the heal does not fail its verify"
  docker_default; install_fake; mem 3G
  containers "c1 pg running unhealthy postgres:17 unless-stopped 0" "c2 redis running none redis:7 unless-stopped 0"
  heal --docker-variant B >/dev/null 2>&1; eq $? 0 "healed: pg runs, unhealthy as before"
  has "$(cat "$(cat "$FSG_STATE_DIR/last-heal-dir")/docker-before.txt")" "health=unhealthy none" "the record keeps each one's health"
  absent "$FSG_STATE_DIR/docker-intent" "verified"
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 0 "runs released"

  t "a container healthy before the heal that stays unhealthy still fails the verify"
  docker_default; install_fake; mem 3G
  echo "c1 unhealthy" > "$FSG_FAKE/docker/health-after-start"
  heal --docker-variant B >/dev/null 2>&1; eq $? 8 "not verified: pg was healthy"
  has "$(grep 'heal incomplete' "$FSG_FAKE/notifications.log")" "containers: c1" "named"
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 75 "runs held"

  t "a dead heal's recovery needs healthy only where the intent recorded it"
  docker_default; install_fake
  containers "c1 pg running unhealthy postgres:17 unless-stopped 0" "c2 redis running none redis:7 unless-stopped 0"
  dead_intent B 1 "unhealthy none"
  FSG_CONTAINER_TIMEOUT_S=1 "$G" tick >/dev/null 2>&1
  absent "$FSG_STATE_DIR/docker-intent" "verified: pg was unhealthy before the heal"
  dead_intent B 1
  FSG_CONTAINER_TIMEOUT_S=1 "$G" tick >/dev/null 2>&1
  exists "$FSG_STATE_DIR/docker-intent" "an intent without restore_health needs pg healthy, as before"
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 75 "runs held"

  t "a hold is released over a container that was unhealthy before the heal, not one that was healthy"
  docker_default; install_fake
  containers "c1 pg running unhealthy postgres:17 unless-stopped 0" "c2 redis running none redis:7 unless-stopped 0"
  for h in "" "healthy none" "unhealthy none"; do
    mkdir -p "$FSG_STATE_DIR/drain/leases"
    printf 'state_version=1\nowner_pid=0\nstarted_epoch=%s\nhold_until_epoch=%s\ntrigger=manual\nreason=test hold\nphase=held-docker-not-restored\nrestore_names=pg redis\n%s' \
      "$(date +%s)" $(( $(date +%s) + 600 )) "${h:+restore_health=$h
}" > "$FSG_STATE_DIR/drain/pending"
    "$G" tick >/dev/null 2>&1
    if [ "$h" = "unhealthy none" ]; then absent "$FSG_STATE_DIR/drain/pending" "released (restore_health=$h)"
    else exists "$FSG_STATE_DIR/drain/pending" "kept (restore_health=${h:-absent})"; fi
  done

  t "a container gone from a dead heal's restore set is named and dropped, not held for good"
  docker_default; install_fake
  echo stopped > "$FSG_FAKE/docker/desktop"
  # redis was removed (docker compose rm) after the heal died.
  containers "c1 pg exited healthy postgres:17 unless-stopped 0"
  dead_intent B; : > "$FSG_FAKE/notifications.log"
  "$G" tick >/dev/null 2>&1
  eq "$(cat "$FSG_FAKE/docker/desktop")" running "Docker started"
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 75 "held while redis is missing once"
  has "$(cat "$FSG_STATE_DIR/docker-intent" 2>/dev/null)" "fails=redis:1:" "one failed pass counted"
  has "$(cat "$FSG_FAKE/notifications.log")" "containers: redis" "the notification names it"
  sleep 1; FSG_AGENT_INTERVAL_S=1 "$G" tick >/dev/null 2>&1
  absent "$FSG_STATE_DIR/docker-intent" "intent cleared without redis"
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 0 "released"
  has "$(tail -n 1 "$FSG_FAKE/notifications.log")" "Dropped from the restore set after 2 failed passes, left as they are (start them by hand): redis" "the release names it"
  has "$(cat "$FSG_LOG")" "dropped from the restore set after 2 failed passes (left as they are): redis" "logged"

  t "a container inspect that cannot reach the engine is not a failed pass"
  docker_default; install_fake
  containers "c1 pg running healthy postgres:17 unless-stopped 0" "c2 redis exited none redis:7 no 0"
  dead_intent A
  # docker info answers, docker inspect does not: the engine dropped between them.
  touch "$FSG_FAKE/docker/inspect-down"
  FSG_CONTAINER_TIMEOUT_S=1 FSG_AGENT_INTERVAL_S=1 "$G" tick >/dev/null 2>&1
  sleep 1.2; FSG_CONTAINER_TIMEOUT_S=1 FSG_AGENT_INTERVAL_S=1 "$G" tick >/dev/null 2>&1
  exists "$FSG_STATE_DIR/docker-intent" "still restoring"
  has "$(cat "$FSG_STATE_DIR/docker-intent" 2>/dev/null)" "restore_names=pg redis" "nothing dropped from the restore set"
  hasnt "$(cat "$FSG_STATE_DIR/docker-intent" 2>/dev/null)" "fails=pg" "no failed pass for pg"
  hasnt "$(cat "$FSG_STATE_DIR/docker-intent" 2>/dev/null)" "redis:" "no failed pass for redis"
  hasnt "$(cat "$FSG_LOG")" "dropped from the restore set" "nothing dropped (log)"
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 75 "runs held"
  rm -f "$FSG_FAKE/docker/inspect-down"
  "$G" tick >/dev/null 2>&1
  absent "$FSG_STATE_DIR/docker-intent" "verified once the engine answers, with both containers checked"
  eq "$(awk '$3 != "running"' "$FSG_FAKE/docker/containers")" "" "both containers running"

  t "a heal is refused while an earlier heal's Docker is not verified"
  docker_default; install_fake
  touch "$FSG_FAKE/docker/bind-broken"; date +%s > "$FSG_STATE_DIR/last-attempt"
  dead_intent A
  "$G" tick >/dev/null 2>&1
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 75 "recovery failed: runs held"
  exists "$FSG_STATE_DIR/docker-intent" "intent kept"
  mem 3G; rm -f "$FSG_STATE_DIR/last-attempt"; : > "$FSG_FAKE/calls.log"; : > "$FSG_FAKE/notifications.log"
  heal --docker-variant A > "$C/o" 2>&1; eq $? 8 "refused"
  has "$(cat "$C/o")" "refused: the Docker step of an earlier heal" "says why"
  has "$(cat "$C/o")" "fseventsd-guard release" "and the way out"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "docker stop" "nothing stopped"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "sudo -n /" "no restart"
  hasnt "$(cat "$FSG_LOG")" "DRAIN begin trigger=manual" "no drain"
  has "$(cat "$FSG_FAKE/notifications.log")" "not healing: Docker not verified" "the agent's runaway check notifies instead of healing"
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 75 "runs stay held"
  "$G" heal --dry-run > "$C/o" 2>&1; eq $? 8 "dry-run says so too"

  t "a request's tick restores Docker left down by a dead heal first"
  docker_default; install_fake; mem 50M
  docker desktop stop >/dev/null 2>&1; dead_intent B; : > "$FSG_FAKE/calls.log"
  out=$("$G" heal --dry-run 2>&1); has "$out" "an earlier heal's Docker step (tick pid $DEAD, variant B) is not verified" "dry-run says so"
  eq "$(cat "$FSG_FAKE/docker/desktop")" stopped "dry-run touches nothing"
  heal >/dev/null 2>&1; eq $? 6 "nothing to heal"
  eq "$(cat "$FSG_FAKE/docker/desktop")" running "Docker restored first"
  absent "$FSG_STATE_DIR/docker-intent" "intent cleared"

  # lease_after_death: a run that took its lease after the heal died (runners ignore
  # a dead heal's drain; an A or B intent holds them, so it proceeds past it). Sets LP.
  lease_after_death() {
    bg env FSG_RUN_MAX_WAIT_S=1 FSG_RUN_POLL_S=1 FSG_RUN_ON_TIMEOUT=proceed "$G" run --label after-death -- sleep 60; LP=$LAST_BG
    waitfor 10 test -f "$FSG_STATE_DIR/drain/leases/$LP.lease" || bad "the run took its lease"
  }

  t "a dead heal's variant C recovery waits for runs leased since, and holds new ones"
  docker_default; install_fake
  dead_intent C; lease_after_death; : > "$FSG_FAKE/calls.log"
  "$G" tick > "$C/tick.out" 2>&1 & tp=$!; BG_PIDS="$BG_PIDS $tp"
  waitfor 10 grep -qs "^owner_pid=$tp\$" "$FSG_STATE_DIR/drain/pending" || bad "the recovery marked a drain of its own"
  sleep 3
  hasnt "$(cat "$FSG_FAKE/calls.log")" "docker desktop restart" "no Docker Desktop restart under the leased run"
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 75 "a new run is held during the recovery"
  exists "$FSG_STATE_DIR/docker-intent" "intent kept while it waits"
  killbg "$LP"
  wait "$tp"; eq $? 0 "tick"
  has "$(cat "$FSG_FAKE/calls.log")" "docker desktop restart" "Docker Desktop restarted once the run ended"
  absent "$FSG_STATE_DIR/docker-intent" "intent cleared"
  absent "$FSG_STATE_DIR/drain/pending" "the recovery's drain is released"
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 0 "runs start"

  t "a dead heal's variant B recovery starts Docker under a hold, without waiting"
  docker_default; install_fake
  docker desktop stop >/dev/null 2>&1; dead_intent B; lease_after_death
  echo 4 > "$FSG_FAKE/docker/start-delay"; : > "$FSG_FAKE/calls.log"
  "$G" tick > "$C/tick.out" 2>&1 & tp=$!; BG_PIDS="$BG_PIDS $tp"
  waitfor 10 grep -q 'docker desktop start' "$FSG_FAKE/calls.log" || bad "the after-step began with the leased run still running"
  has "$(cat "$FSG_STATE_DIR/drain/pending" 2>/dev/null)" "hold_until_epoch=" "under a hold that outlives the tick"
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 75 "a new run is held while Docker comes back"
  wait "$tp"
  absent "$FSG_STATE_DIR/docker-intent" "intent cleared"
  absent "$FSG_STATE_DIR/drain/pending" "released once Docker verified"
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 0 "runs start"
  killbg "$LP"

  t "a recovery that cannot write its drain marker leaves Docker alone and keeps the intent"
  docker_default; install_fake
  docker desktop stop >/dev/null 2>&1; dead_intent B
  mkdir -p "$FSG_STATE_DIR/drain/leases"; chmod 555 "$FSG_STATE_DIR/drain"
  : > "$FSG_FAKE/calls.log"; : > "$FSG_FAKE/notifications.log"
  "$G" tick >/dev/null 2>&1; "$G" tick >/dev/null 2>&1
  chmod 755 "$FSG_STATE_DIR/drain"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "docker desktop start" "Docker untouched"
  has "$(cat "$FSG_STATE_DIR/docker-intent" 2>/dev/null)" "after_done=0" "intent kept"
  eq "$(grep -c 'cannot mark the drain' "$FSG_FAKE/notifications.log")" 1 "notified once"
  absent "$FSG_STATE_DIR/heal.lock" "lock released"
  "$G" tick >/dev/null 2>&1
  eq "$(cat "$FSG_FAKE/docker/desktop")" running "recovered once the marker can be written"
  absent "$FSG_STATE_DIR/docker-intent" "intent cleared"

  t "a recovery keeps a trial hold that was in place once Docker verified"
  docker_default; install_fake
  docker desktop stop >/dev/null 2>&1; dead_intent B
  printf 'state_version=1\nowner_pid=0\nstarted_epoch=%s\nhold_until_epoch=%s\ntrigger=trial\nreason=test\nphase=held-docker-not-restored\nrestore_names=pg redis\n' \
    "$(date +%s)" $(( $(date +%s) + 600 )) > "$FSG_STATE_DIR/drain/pending"
  "$G" tick >/dev/null 2>&1
  eq "$(cat "$FSG_FAKE/docker/desktop")" running "Docker started"
  absent "$FSG_STATE_DIR/docker-intent" "intent cleared"
  has "$(cat "$FSG_STATE_DIR/drain/pending" 2>/dev/null)" "trigger=trial" "the trial hold is back"
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 75 "runs wait for the operator"

  t "a hold replaced by a recovery that was killed comes back at the next recovery"
  docker_default; install_fake
  touch "$FSG_FAKE/docker/bind-broken"; dead_intent B 1
  sed "s/^hold_epoch=\$/hold_epoch=$(date +%s)/" "$FSG_STATE_DIR/docker-intent" > "$C/intent" && mv "$C/intent" "$FSG_STATE_DIR/docker-intent"
  pending "$DEAD" 600
  printf 'state_version=1\nowner_pid=0\nstarted_epoch=%s\nhold_until_epoch=%s\ntrigger=manual\nreason=test\nphase=held-docker-not-restored\nrestore_names=pg redis\n' \
    "$(date +%s)" $(( $(date +%s) + 600 )) > "$FSG_STATE_DIR/drain/pending.saved.99999"
  "$G" tick >/dev/null 2>&1
  has "$(cat "$FSG_STATE_DIR/drain/pending" 2>/dev/null)" "hold_until_epoch=" "the hold is back"
  absent "$FSG_STATE_DIR/drain/pending.saved.99999" "the copy is gone"
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 75 "runs stay held while Docker does not verify"

  t "a Docker Desktop start that failed is tried again at the next pass"
  docker_default; install_fake
  export FSG_DOCKER_TIMEOUT_S=2
  docker desktop stop >/dev/null 2>&1; dead_intent B; touch "$FSG_FAKE/docker/desktop-start-fail"
  : > "$FSG_FAKE/calls.log"
  "$G" tick >/dev/null 2>&1
  eq "$(cat "$FSG_FAKE/docker/desktop")" stopped "the first start failed"
  hasnt "$(cat "$FSG_STATE_DIR/docker-intent" 2>/dev/null)" "engine_done=1" "engine_done stays unset: the engine never answered"
  has "$(cat "$FSG_STATE_DIR/docker-intent" 2>/dev/null)" "action_ran=1" "the action is recorded as run"
  has "$("$G" status 2>&1)" "the engine has not answered since" "status says so"
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 75 "runs held"
  rm -f "$FSG_FAKE/docker/desktop-start-fail"
  "$G" tick >/dev/null 2>&1
  eq "$(grep -c 'docker desktop start' "$FSG_FAKE/calls.log")" 2 "docker desktop start again at the next pass"
  eq "$(cat "$FSG_FAKE/docker/desktop")" running "Docker running"
  absent "$FSG_STATE_DIR/docker-intent" "verified"
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 0 "released"

  t "a variant C restart never runs twice for one intent"
  docker_default; install_fake
  docker desktop stop >/dev/null 2>&1; dead_intent C
  # Its tick died during the restart.
  echo "action_ran=1" >> "$FSG_STATE_DIR/docker-intent"; : > "$FSG_FAKE/calls.log"
  "$G" tick >/dev/null 2>&1
  hasnt "$(cat "$FSG_FAKE/calls.log")" "docker desktop restart" "no second restart"
  has "$(cat "$FSG_FAKE/calls.log")" "docker desktop start" "an idempotent start instead"
  eq "$(cat "$FSG_FAKE/docker/desktop")" running "Docker running"
  absent "$FSG_STATE_DIR/docker-intent" "verified"

  t "a dead heal's variant C recovery skips the restart when Docker answers but does not list, and says so"
  docker_default; install_fake
  # The drain's engine scans would hold it for a listing; this case is about the restart.
  export FSG_DETECT_DOCKER_EXECS=0 FSG_DETECT_DOCKER_CONTAINERS=0
  dead_intent C; echo 1000 > "$FSG_FAKE/docker/ps-fail"; : > "$FSG_FAKE/calls.log"; : > "$FSG_FAKE/notifications.log"
  "$G" tick >/dev/null 2>&1
  rm -f "$FSG_FAKE/docker/ps-fail"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "docker desktop restart" "not restarted"
  has "$(grep 'Docker restored' "$FSG_FAKE/notifications.log")" "Docker verified. Docker Desktop not restarted: Docker answers but did not list its containers, so --rm containers with an anonymous volume could not be checked." "the notice names the skipped restart"
  absent "$FSG_STATE_DIR/docker-intent" "Docker verified as it is"

  t "a dead heal's variant C recovery restarts a Docker that answers nothing unchecked, and says so"
  docker_default; install_fake
  export FSG_DETECT_DOCKER_EXECS=0 FSG_DETECT_DOCKER_CONTAINERS=0
  dead_intent C; touch "$FSG_FAKE/docker/hang"; : > "$FSG_FAKE/calls.log"; : > "$FSG_FAKE/notifications.log"
  "$G" tick >/dev/null 2>&1
  has "$(cat "$FSG_FAKE/calls.log")" "docker desktop restart" "restarted"
  before "$FSG_FAKE/calls.log" "docker info" "docker desktop restart"
  hasnt "$(sed '/docker desktop restart/,$d' "$FSG_FAKE/calls.log")" "docker ps" "without listing the wedged engine first"
  has "$(grep 'Docker restored' "$FSG_FAKE/notifications.log")" "Docker verified. Docker Desktop restarted unchecked: Docker did not answer docker info (wedged)" "the notice names the unchecked restart"
  absent "$FSG_STATE_DIR/docker-intent" "verified"

  t "a recovery the agent's stop finishes names a C restart it ran unchecked"
  docker_default; install_fake
  dead_intent C; touch "$FSG_FAKE/docker/hang"; : > "$FSG_FAKE/calls.log"; : > "$FSG_FAKE/notifications.log"
  # The tick's EXIT trap, as a signal right before the recovery's after-step leaves it.
  ( FSG_HOME=$GUARD_HOME
    for l in common lease measure drain docker request heal; do . "$GUARD_HOME/lib/$l.sh"; done
    fsg_init_paths; fsg_load_config; TICK_RECOVERING=1; RECOVER_C_WAIT=0
    fsg_recover_interrupted ) > "$C/o" 2>&1
  has "$(cat "$FSG_FAKE/calls.log")" "docker desktop restart" "the trap's pass restarted Docker Desktop"
  has "$(grep 'Docker restored' "$FSG_FAKE/notifications.log")" "it finished the pass and Docker verified. Docker Desktop restarted unchecked: Docker did not answer docker info (wedged)" "the notice names it"
  absent "$FSG_STATE_DIR/docker-intent" "verified"

  t "an unverified Docker intent expires and never starts a Docker the user quit"
  docker_default; install_fake; mem 3G
  touch "$FSG_FAKE/docker/bind-broken"
  heal --docker-variant B >/dev/null 2>&1; eq $? 8 "Docker not verified"
  has "$(cat "$FSG_STATE_DIR/docker-intent" 2>/dev/null)" "engine_done=1" "the engine had answered"
  docker desktop stop >/dev/null 2>&1   # the user quits Docker Desktop
  mem 5000K; : > "$FSG_FAKE/calls.log"
  "$G" tick >/dev/null 2>&1
  hasnt "$(cat "$FSG_FAKE/calls.log")" "docker desktop start" "a tick inside the window leaves the quit Docker alone"
  exists "$FSG_STATE_DIR/docker-intent" "the intent stands inside the window"
  # The heal's Docker action ran longer ago than FSG_FAILED_HOLD_S.
  sed "s/^action_epoch=.*/action_epoch=$(( $(date +%s) - 7200 ))/" "$FSG_STATE_DIR/docker-intent" > "$C/intent" && mv "$C/intent" "$FSG_STATE_DIR/docker-intent"
  : > "$FSG_FAKE/notifications.log"
  "$G" tick >/dev/null 2>&1
  absent "$FSG_STATE_DIR/docker-intent" "expired"
  has "$(cat "$FSG_FAKE/notifications.log")" "the guard stops restoring it" "notified"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "docker desktop start" "still not started"
  eq "$(cat "$FSG_FAKE/docker/desktop")" stopped "the quit Docker stays off"
  echo 4242 > "$FSG_FAKE/fsev/pids"; mem 3G; rm -f "$FSG_PREFIX/Library/Logs/fseventsd-guard/last-restart" "$FSG_STATE_DIR/last-attempt"
  : > "$FSG_FAKE/calls.log"
  heal > "$C/o" 2>&1; eq $? 0 "a new heal is no longer refused ($(tail -n 1 "$C/o"))"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "docker desktop start" "and leaves the quit Docker off"

  t "an agent stopped during a recovery keeps runs held, and finishes the pass first"
  docker_default; install_fake
  docker desktop stop >/dev/null 2>&1; touch "$FSG_FAKE/docker/bind-broken"; dead_intent B
  echo 6 > "$FSG_FAKE/docker/start-delay"; : > "$FSG_FAKE/calls.log"; : > "$FSG_FAKE/notifications.log"
  "$G" tick > "$C/tick.out" 2>&1 & tp=$!; BG_PIDS="$BG_PIDS $tp"
  waitfor 20 grep -q 'docker desktop start' "$FSG_FAKE/calls.log" || bad "the recovery began docker desktop start"
  kill -TERM "$tp"; wait "$tp"; eq $? 130 "the tick ends by the signal"
  has "$(cat "$FSG_STATE_DIR/drain/pending" 2>/dev/null)" "hold_until_epoch=" "a hold, not a release"
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 75 "new runs held: Docker did not verify"
  has "$(cat "$FSG_LOG")" "finishing the pass" "the trap finished the pass"
  has "$(cat "$FSG_FAKE/notifications.log")" "heal interrupted" "notified"
  has "$(cat "$FSG_STATE_DIR/docker-intent" 2>/dev/null)" "action_ran=1" "the intent records the start"
  absent "$FSG_STATE_DIR/heal.lock" "lock released"

  t "an agent stopped while a recovery waits before C's restart puts the hold back and restarts nothing"
  docker_default; install_fake
  dead_intent C; lease_after_death; : > "$FSG_FAKE/calls.log"
  printf 'state_version=1\nowner_pid=0\nstarted_epoch=%s\nhold_until_epoch=%s\ntrigger=manual\nreason=test hold\nphase=held-docker-not-restored\nrestore_names=pg redis\n' \
    "$(date +%s)" $(( $(date +%s) + 600 )) > "$FSG_STATE_DIR/drain/pending"
  "$G" tick > "$C/tick.out" 2>&1 & tp=$!; BG_PIDS="$BG_PIDS $tp"
  waitfor 10 grep -qs "^owner_pid=$tp\$" "$FSG_STATE_DIR/drain/pending" || bad "the recovery drains over the hold"
  kill -TERM "$tp"; wait "$tp"; eq $? 130 "the tick ends by the signal"
  has "$(cat "$FSG_STATE_DIR/drain/pending" 2>/dev/null)" "reason=test hold" "the hold is back"
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 75 "new runs held"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "docker desktop restart" "no restart"
  hasnt "$(cat "$FSG_STATE_DIR/docker-intent" 2>/dev/null)" "action_ran=1" "the restart is left to the next tick"
  ls "$FSG_STATE_DIR"/drain/pending.saved.* >/dev/null 2>&1 && bad "no copy left behind" || ok
  killbg "$LP"

  t "release clears a dead heal's intent"
  docker_default; install_fake
  dead_intent A
  "$G" release > "$C/o" 2>&1; eq $? 0 "release"
  has "$(cat "$C/o")" "cleared the record" "said"
  absent "$FSG_STATE_DIR/docker-intent" "cleared"

  t "a heal that cannot write its Docker intent leaves Docker alone"
  docker_default; install_fake; mem 600M
  mkdir -p "$FSG_STATE_DIR/docker-intent"; : > "$FSG_FAKE/calls.log"
  heal --docker-variant B > "$C/o" 2>&1; eq $? 10 "exit 10"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "docker desktop stop" "Docker untouched"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "sudo -n /" "no restart"
  has "$(cat "$FSG_FAKE/notifications.log" 2>/dev/null)" "cannot record the Docker step" "notified"
  absent "$FSG_STATE_DIR/drain/pending" "drain released"; absent "$FSG_STATE_DIR/heal.lock" "lock released"
fi

# ======================================================================== docker-endpoint
if ! skip_case docker-endpoint; then
  # ep_calls VERBS: the endpoints the stub logged for those docker commands.
  ep_calls() { awk -v v=" $1 " 'index(v, " " $2 " ") { print $1 }' "$FSG_FAKE/docker/endpoints.log" 2>/dev/null | sort -u; }

  for ep in "ssh://dev@build-host" "tcp://10.0.0.5:2376" "context-fail" "unix://missing"; do
    t "a heal under a $ep endpoint touches no Docker"
    docker_default; install_fake || bad "install"
    case $ep in
      context-fail) touch "$FSG_FAKE/docker/context-fail" ;;
      unix://missing) echo "unix://$C/no.sock" > "$FSG_FAKE/docker/context-host" ;;
      *) echo "$ep" > "$FSG_FAKE/docker/context-host" ;;
    esac
    # B on a non-Desktop engine falls back to A: the remote containers would be stopped.
    rm "$FSG_FAKE/docker/desktop"; touch "$FSG_FAKE/docker/engine-ok"
    echo "pg 1 tty fsgtestrspec" > "$FSG_FAKE/docker/execs"
    mem 3G; : > "$FSG_FAKE/calls.log"
    heal --docker-variant B > "$C/o" 2>&1; eq $? 0 "the fseventsd restart still runs"
    L=$(cat "$FSG_FAKE/calls.log")
    has "$L" "kill -TERM 4242" "fseventsd restarted"
    hasnt "$L" "docker stop" "no container stopped"; hasnt "$L" "docker start" "no container started"
    hasnt "$L" "docker desktop" "Docker Desktop untouched"; hasnt "$L" "docker run" "no probe container"
    hasnt "$L" "ExecIDs" "no exec listing on that engine"; hasnt "$L" "curl " "no engine API call"
    eq "$(awk '$3 != "running"' "$FSG_FAKE/docker/containers")" "" "every container still running"
    has "$(cat "$FSG_FAKE/notifications.log")" "Docker step skipped: not a local Docker engine" "the notification says so"
    has "$(cat "$(cat "$FSG_STATE_DIR/last-heal-dir")/result.txt")" "(not local, Docker step skipped:" "the record says so"
    absent "$FSG_STATE_DIR/docker-intent" "no intent left"; absent "$FSG_STATE_DIR/drain/pending" "no hold"
  done

  t "a remote context on Docker Desktop: variant A stops nothing"
  docker_default; install_fake; echo "ssh://dev@build-host" > "$FSG_FAKE/docker/context-host"
  mem 3G; : > "$FSG_FAKE/calls.log"
  heal --docker-variant A >/dev/null 2>&1; eq $? 0 "healed"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "docker stop" "no container stopped"
  has "$(cat "$FSG_FAKE/notifications.log")" "not a local Docker engine (ssh://dev@build-host is not a local unix socket" "names the endpoint"

  t "DOCKER_HOST wins over the context, and a tcp one plans no Docker step"
  docker_default; install_fake; mem 3G; : > "$FSG_FAKE/calls.log"
  out=$(DOCKER_HOST=tcp://10.0.0.5:2376 "$G" heal --dry-run --docker-variant A)
  has "$out" "5. docker before-step (skip): nothing (not a local Docker engine: tcp://10.0.0.5:2376 is not a local unix socket; Docker Desktop runs on this Mac but is not the selected engine, so it is left as it is)" "plan"
  hasnt "$out" "docker stop -t" "no stop planned"
  out=$("$G" heal --dry-run --docker-variant A); has "$out" "docker stop -t 30 c1 c2" "the local context plans the stop"
  has "$out" "endpoint unix://$FSG_FAKE/docker/docker.sock" "the endpoint is shown"

  t "a context switched mid-heal: its docker calls stay on the local socket"
  docker_default; install_fake; mem 3G
  echo 4 > "$FSG_FAKE/sudo-delay"; : > "$FSG_FAKE/docker/endpoints.log"
  "$G" heal --docker-variant A > "$C/heal.out" 2>&1 & hp=$!; BG_PIDS="$BG_PIDS $hp"
  waitfor 20 grep -qs '^phase=restarting' "$FSG_STATE_DIR/drain/pending" || bad "the heal reached the restart"
  echo "ssh://dev@build-host" > "$FSG_FAKE/docker/context-host"
  wait "$hp"; eq $? 0 "healed"; agent_wait
  eq "$(ep_calls "stop start inspect run")" "unix://$FSG_FAKE/docker/docker.sock" "every heal call on the pinned socket"
  eq "$(awk '$3 != "running"' "$FSG_FAKE/docker/containers")" "" "every container running again"
  has "$(cat "$(cat "$FSG_STATE_DIR/last-heal-dir")/result.txt")" "docker_endpoint=unix://$FSG_FAKE/docker/docker.sock" "the record names the socket"

  t "another engine's socket with Docker Desktop running: Desktop untouched, A on that engine"
  docker_default; install_fake || bad "install"
  # Desktop's own containers have no restart policy: a Desktop stop would leave them down.
  containers "c1 pg running healthy postgres:17 no 0" "c2 redis running none redis:7 no 0"
  ln -s "$ROOT/tools/other.sock" "$FSG_FAKE/docker/other.sock"
  mkdir -p "$FSG_FAKE/docker/other"; touch "$FSG_FAKE/docker/other/engine-ok"
  printf '%s\n' "k1 web running none nginx:1 no 0" "k2 db running healthy postgres:16 no 0" > "$FSG_FAKE/docker/other/containers"
  echo "unix://$FSG_FAKE/docker/other.sock" > "$FSG_FAKE/docker/context-host"
  mem 3G; : > "$FSG_FAKE/calls.log"
  heal --docker-variant B > "$C/o" 2>&1; eq $? 0 "healed ($(tail -n 1 "$C/o"))"
  L=$(cat "$FSG_FAKE/calls.log")
  hasnt "$L" "docker desktop" "no docker desktop call"
  has "$L" "docker stop -t 30 k1 k2" "the selected engine's containers stopped"
  has "$L" "docker start k1 k2" "and started again"
  eq "$(cat "$FSG_FAKE/docker/desktop")" running "Docker Desktop still runs"
  eq "$(awk '$3 != "running"' "$FSG_FAKE/docker/containers")" "" "Desktop's containers untouched"
  eq "$(awk '$3 != "running"' "$FSG_FAKE/docker/other/containers")" "" "the engine's containers run"
  has "$(cat "$FSG_LOG")" "docker variant B -> A" "the fallback is logged"
  has "$(cat "$(cat "$FSG_STATE_DIR/last-heal-dir")/result.txt")" "docker_engine=another engine at $ROOT/tools/other.sock" "the record names the engine"
  absent "$FSG_STATE_DIR/docker-intent" "verified"

  t "a wedged other engine while Docker Desktop's processes run: Desktop untouched"
  docker_default; install_fake || bad "install"
  ln -s "$ROOT/tools/other.sock" "$FSG_FAKE/docker/other.sock"
  echo "unix://$FSG_FAKE/docker/other.sock" > "$FSG_FAKE/docker/context-host"
  # A wedged engine lists no engine work, so the drain would wait out its cap first.
  agent_env FSG_FAILED_HOLD_S=600 FSG_DETECT_DOCKER_EXECS=0 FSG_DETECT_DOCKER_CONTAINERS=0
  mem 3G; : > "$FSG_FAKE/calls.log"; touch "$FSG_FAKE/docker/hang" "$FSG_FAKE/docker/hang-sticky"
  heal --docker-variant B > "$C/o" 2>&1; eq $? 8 "not verified ($(tail -n 1 "$C/o"))"
  rm -f "$FSG_FAKE/docker/hang" "$FSG_FAKE/docker/hang-sticky"
  eq "$(grep '^docker desktop' "$FSG_FAKE/calls.log")" "" "no docker desktop call"
  has "$(cat "$FSG_LOG")" "DOCKER engine runs but does not answer" "treated as a wedged other engine"
  eq "$(cat "$FSG_FAKE/docker/desktop")" running "Docker Desktop still runs"

  t "Docker Desktop's socket through a symlink (/var/run/docker.sock) keeps B"
  docker_default; install_fake || bad "install"
  ln -s "$FSG_FAKE/docker/docker.sock" "$C/var-run-docker.sock"
  echo "unix://$C/var-run-docker.sock" > "$FSG_FAKE/docker/context-host"
  mem 3G; : > "$FSG_FAKE/calls.log"
  heal --docker-variant B > "$C/o" 2>&1; eq $? 0 "healed ($(tail -n 1 "$C/o"))"
  L=$(cat "$FSG_FAKE/calls.log")
  has "$L" "docker desktop stop" "Docker Desktop quit"; has "$L" "docker desktop start" "and started"
  hasnt "$(cat "$FSG_LOG")" "docker variant B -> A" "no fallback"
  has "$(cat "$(cat "$FSG_STATE_DIR/last-heal-dir")/result.txt")" "docker_engine=Docker Desktop" "the record names Docker Desktop"

  t "a recovery across Desktop's default and desktop-linux contexts is accepted"
  docker_default; install_fake
  docker desktop stop >/dev/null 2>&1; dead_intent B
  ln -s "$FSG_FAKE/docker/docker.sock" "$C/var-run-docker.sock"
  echo "unix://$C/var-run-docker.sock" > "$FSG_FAKE/docker/context-host"
  : > "$FSG_FAKE/calls.log"
  "$G" tick >/dev/null 2>&1
  has "$(cat "$FSG_FAKE/calls.log")" "docker desktop start" "recovered on the same engine"
  absent "$FSG_STATE_DIR/docker-intent" "intent cleared"; absent "$FSG_STATE_DIR/drain/pending" "hold released"

  t "a hold check across Desktop's default and desktop-linux contexts releases the hold"
  docker_default; install_fake
  ln -s "$FSG_FAKE/docker/docker.sock" "$C/var-run-docker.sock"
  echo "unix://$C/var-run-docker.sock" > "$FSG_FAKE/docker/context-host"
  mkdir -p "$FSG_STATE_DIR/drain/leases"
  printf 'state_version=1\nowner_pid=0\nstarted_epoch=%s\nhold_until_epoch=%s\ntrigger=manual\nreason=test hold\nphase=held-docker-not-restored\nrestore_names=pg redis\nendpoint=unix://%s\n' \
    "$(date +%s)" $(( $(date +%s) + 600 )) "$FSG_FAKE/docker/docker.sock" > "$FSG_STATE_DIR/drain/pending"
  "$G" tick >/dev/null 2>&1
  absent "$FSG_STATE_DIR/drain/pending" "the hold check releases it ($(grep 'TICK hold' "$FSG_LOG" | tail -n 1))"

  for ep in "unix://$ROOT/tools/other.sock" "tcp://10.0.0.5:2376"; do
    t "a recovery under another endpoint ($ep) is refused until it is back"
    docker_default; install_fake
    docker desktop stop >/dev/null 2>&1; dead_intent B
    echo "$ep" > "$FSG_FAKE/docker/context-host"
    : > "$FSG_FAKE/calls.log"; : > "$FSG_FAKE/notifications.log"
    "$G" tick >/dev/null 2>&1
    hasnt "$(cat "$FSG_FAKE/calls.log")" "docker desktop start" "Docker left alone"
    eq "$(cat "$FSG_FAKE/docker/desktop")" stopped "Docker still down"
    exists "$FSG_STATE_DIR/docker-intent" "the intent is kept"
    has "$(cat "$FSG_STATE_DIR/drain/pending" 2>/dev/null)" "phase=held-docker-not-restored" "runs held"
    has "$(cat "$FSG_FAKE/notifications.log")" "the Docker endpoint is now $ep" "notified"
    "$G" tick >/dev/null 2>&1
    eq "$(grep -c 'the Docker endpoint changed' "$FSG_FAKE/notifications.log")" 1 "notified once"
    mem 3G; heal >/dev/null 2>&1; eq $? 8 "no new heal meanwhile"; mem 5000K
    rm "$FSG_FAKE/docker/context-host"; : > "$FSG_FAKE/calls.log"
    "$G" tick >/dev/null 2>&1
    has "$(cat "$FSG_FAKE/calls.log")" "docker desktop start" "recovered on the heal's endpoint"
    absent "$FSG_STATE_DIR/docker-intent" "intent cleared"; absent "$FSG_STATE_DIR/drain/pending" "hold released"
  done
fi

# ======================================================================== helper-73
if ! skip_case helper-73; then
  t "helper exit 73: the heal waits for the respawn, then restores and verifies Docker"
  docker_default; install_fake; mem 3G
  echo 73 > "$FSG_FAKE/sudo-rc"
  respawn_late() {
    waitfor 30 grep -q "sudo -n $FSG_PREFIX" "$FSG_FAKE/calls.log" || return 1
    sleep 2; echo 3000K > "$FSG_FAKE/fsev/4343.mem"; echo 4343 > "$FSG_FAKE/fsev/pids"
  }
  bg respawn_late
  heal --docker-variant B > "$C/o" 2>&1; eq $? 0 "healed: launchd respawned it late ($(tail -n 1 "$C/o"))"
  before "$FSG_LOG" "respawned after the helper stopped waiting" "DOCKER B desktop start"
  has "$(cat "$FSG_FAKE/calls.log")" "docker run --rm" "bind mount checked"
  absent "$FSG_STATE_DIR/drain/pending" "released"

  t "helper exit 73 with a broken bind mount keeps runs held"
  docker_default; install_fake; mem 3G
  echo 73 > "$FSG_FAKE/sudo-rc"; touch "$FSG_FAKE/docker/bind-broken"
  heal --docker-variant B > "$C/o" 2>&1; eq $? 7 "no respawn: restart failed"
  has "$(cat "$FSG_FAKE/calls.log")" "docker run --rm" "bind mount checked"
  FSG_RUN_MAX_WAIT_S=1 "$G" run -- true 2>/dev/null; eq $? 75 "new runs held"
  has "$(cat "$FSG_FAKE/notifications.log")" "fseventsd-guard release" "the notification says how to release"

  t "helper exit 72: fseventsd needed SIGKILL; the heal reports it"
  docker_default; install_fake; mem 3G; touch "$FSG_FAKE/ignore-term"
  heal --docker-variant B > "$C/o" 2>&1; eq $? 0 "healed ($(tail -n 1 "$C/o"))"
  has "$(cat "$FSG_LOG")" "HEAL helper rc=72 (restarted, but fseventsd ignored SIGTERM for 10 s and needed SIGKILL)" "logged"
  has "$(grep healed "$FSG_FAKE/notifications.log")" "the helper restarted it with SIGKILL" "the notice says so"
  has "$(cat "$(sed -n 's/.* //p' "$FSG_STATE_DIR/last-heal")/result.txt")" "helper_rc=72" "recorded"
  exists "$FSG_STATE_DIR/last-restart" "counts as a restart"
fi

# ======================================================================== tick
if ! skip_case tick; then
  t "tick tiers"
  docker_default; install_fake --no-agent
  "$G" tick; eq $? 0 "ok"
  mem 600M; "$G" tick; eq $? 1 "warn"
  n=$(grep -c 'fseventsd at 600 MB' "$FSG_FAKE/notifications.log"); eq "$n" 1 "warn notified"
  "$G" tick; n=$(grep -c 'fseventsd at' "$FSG_FAKE/notifications.log"); eq "$n" 1 "no repeat within the renotify window"
  mem 1300M; "$G" tick; n=$(grep -c 'fseventsd at' "$FSG_FAKE/notifications.log"); eq "$n" 2 "renotify when doubled"
  has "$(tail -n 1 "$FSG_FAKE/notifications.log")" "Next: run fseventsd-guard heal" "next step"
  mem 3G; : > "$FSG_FAKE/calls.log"; "$G" tick > /dev/null 2>&1; eq $? 0 "runaway: emergency heal"
  has "$(cat "$FSG_FAKE/calls.log")" "sudo -n /" "restart happened"
  has "$(cat "$FSG_STATE_DIR/last-heal")" "healed emergency" "trigger recorded"
  mem 3G; : > "$FSG_FAKE/calls.log"; rm -f "$FSG_STATE_DIR/last-notice"
  "$G" tick; eq $? 2 "second runaway inside 3 h: notify only"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "sudo -n /" "no second restart"
  has "$(tail -n 1 "$FSG_FAKE/notifications.log")" "not auto-healing" "notification"

  t "tick logs compressed memory, ports and swap"
  docker_default; install_fake --no-agent
  echo 1.5G > "$FSG_FAKE/fsev/4242.cmprs"; echo 118+ > "$FSG_FAKE/fsev/4242.ports"
  echo "total = 14336.00M  used = 13548.50M  free = 787.50M  (encrypted)" > "$FSG_FAKE/swapusage"
  "$G" tick; eq $? 0 "ok"
  line=$(grep ' TICK level=' "$FSG_LOG" | tail -n 1)
  has "$line" "mb=4 cmprs_mb=1536 ports=118 cpu=" "compressed memory and ports from the same top sample"
  has "$line" "swap_used_mb=13548 " "swap in use"
  echo garbage > "$FSG_FAKE/swapusage"; echo "?" > "$FSG_FAKE/fsev/4242.ports"; "$G" tick; eq $? 0 "unreadable extras do not matter"
  line=$(grep ' TICK level=' "$FSG_LOG" | tail -n 1)
  has "$line" "ports= cpu=" "empty ports"; has "$line" "swap_used_mb= " "empty swap"

  # cpu_step PCT: the last tick's record moves 300 s back and fseventsd uses PCT% of
  # a core over that gap.
  cpu_step() {
    local f="$FSG_STATE_DIR/tick-sample" e c ms
    e=$(sed -n 's/^epoch=//p' "$f"); c=$(sed -n 's/^cpu_ms=//p' "$f")
    sed "s/^epoch=.*/epoch=$((e - 300))/" "$f" > "$f.t" && mv "$f.t" "$f"
    ms=$((c + $1 * 3000))
    printf '%d:%02d.%02d\n' $((ms / 60000)) $((ms % 60000 / 1000)) $((ms % 1000 / 10)) > "$FSG_FAKE/fsev/$(head -n 1 "$FSG_FAKE/fsev/pids").time"
  }

  t "tick cpu escalator: warn plus a pinned core for 3 ticks heals"
  docker_default; install_fake --no-agent; mem 600M
  "$G" tick; eq $? 1 "first tick: warn, no CPU share yet"
  has "$(grep ' TICK level=' "$FSG_LOG" | tail -n 1)" "cpu_avg_pct= cpu_streak=0" "no share without an earlier tick"
  cpu_step 60; "$G" tick; eq $? 1 "1 tick at 60%: warn"
  has "$(grep ' TICK level=' "$FSG_LOG" | tail -n 1)" "cpu_streak=1" "streak 1"
  cpu_step 60; "$G" tick; eq $? 1 "2 ticks: warn"
  "$G" status >/dev/null; eq $? 1 "status: warn at 2 ticks"
  cpu_step 60; : > "$FSG_FAKE/calls.log"; "$G" tick >/dev/null 2>&1; eq $? 0 "3 ticks: runaway, emergency heal"
  line=$(grep ' TICK level=' "$FSG_LOG" | tail -n 1)
  has "$line" "level=runaway" "level"; has "$line" "cpu_streak=3" "streak 3"
  case $line in *cpu_avg_pct=59*|*cpu_avg_pct=60*) ok ;; *) bad "share from the CPU time between ticks: $line" ;; esac
  has "$(cat "$FSG_LOG")" "TICK runaway by the cpu escalator" "logged"
  has "$(cat "$FSG_FAKE/calls.log")" "sudo -n /" "restart happened"
  has "$(cat "$FSG_STATE_DIR/last-heal")" "healed emergency" "the act threshold's path"

  t "tick cpu escalator: a quiet tick, a small footprint or a new pid start over"
  docker_default; install_fake --no-agent; mem 600M
  "$G" tick; cpu_step 60; "$G" tick; cpu_step 60; "$G" tick
  cpu_step 10; "$G" tick; eq $? 1 "a quiet tick"
  has "$(grep ' TICK level=' "$FSG_LOG" | tail -n 1)" "cpu_streak=0" "streak reset"
  cpu_step 60; "$G" tick; cpu_step 60; "$G" tick; eq $? 1 "2 more ticks: warn"
  mem 300M; cpu_step 90; "$G" tick; eq $? 0 "below warn: ok"
  has "$(grep ' TICK level=' "$FSG_LOG" | tail -n 1)" "cpu_streak=0" "below warn does not count"
  mem 600M; cpu_step 60; "$G" tick; cpu_step 60; "$G" tick
  echo 4300 > "$FSG_FAKE/fsev/pids"; echo 600M > "$FSG_FAKE/fsev/4300.mem"; echo 9:00.00 > "$FSG_FAKE/fsev/4300.time"
  "$G" tick; eq $? 1 "a new pid: warn"
  has "$(grep ' TICK level=' "$FSG_LOG" | tail -n 1)" "cpu_avg_pct= cpu_streak=0" "no share across pids"
  printf 'epoch=%s\npid=4300\ncpu_ms=1\ncpu_pct=97\nstreak=3\n' "$(date +%s)" > "$FSG_STATE_DIR/tick-sample"
  out=$("$G" status --json); eq $? 2 "status: the agent's streak counts"
  has "$(jget "$out" 'd["reasons"][0]')" "cpu 97% of a core for 3 ticks in a row" "reason"
  FSG_CPU_ESCALATE_PCT=0 "$G" status >/dev/null; eq $? 1 "0 turns it off"
  FSG_CPU_ESCALATE_TICKS=4 "$G" status >/dev/null; eq $? 1 "4 ticks needed"
  mem 300M; "$G" status >/dev/null; eq $? 0 "below warn: ok"
  mem 600M; printf 'epoch=%s\npid=4300\ncpu_ms=1\ncpu_pct=97\nstreak=3\n' $(( $(date +%s) - 700 )) > "$FSG_STATE_DIR/tick-sample"
  "$G" status >/dev/null; eq $? 1 "a record older than two intervals does not count"
  printf 'epoch=%s\npid=4242\ncpu_ms=1\ncpu_pct=97\nstreak=3\n' "$(date +%s)" > "$FSG_STATE_DIR/tick-sample"
  "$G" status >/dev/null; eq $? 1 "another pid's record does not count"

  t "tick logs the FSEvents rate from the probe's event ids"
  docker_default; install_fake --no-agent
  echo 5000000 > "$FSG_FAKE/probe-eid"; "$G" tick; eq $? 0 "ok"
  has "$(grep ' TICK level=' "$FSG_LOG" | tail -n 1)" "start_ms=0 eid=5000000 ev_s=" "event id, no rate on the first tick"
  cpu_step 0; echo 5060000 > "$FSG_FAKE/probe-eid"; "$G" tick
  line=$(grep ' TICK level=' "$FSG_LOG" | tail -n 1)
  case $line in *"eid=5060000 ev_s=200"|*"eid=5060000 ev_s=199"|*"eid=5060000 ev_s=198") ok ;; *) bad "60000 events in about 300 s: $line" ;; esac
  echo "{ sec = 1760009999, usec = 0 } Thu Oct  9 11:39:59 2025" > "$FSG_FAKE/boottime"
  cpu_step 0; echo 9000000000 > "$FSG_FAKE/probe-eid"; "$G" tick
  has "$(grep ' TICK level=' "$FSG_LOG" | tail -n 1)" "eid=9000000000 ev_s=" "a reboot starts the rate over"
  cpu_step 0; rm -f "$FSG_FAKE/probe-eid"; "$G" tick; eq $? 0 "a probe without an event id still parses"
  has "$(grep ' TICK level=' "$FSG_LOG" | tail -n 1)" "start_ms=0 eid= ev_s=" "no id, no rate"

  t "tick keeps a per-day summary"
  docker_default; install_fake --no-agent; mem 600M; day=$(date +%Y-%m-%d)
  echo 5000000 > "$FSG_FAKE/probe-eid"; "$G" tick
  has "$(cat "$FSG_STATE_DIR/daily")" "$day ticks=1 max_mb=600 max_cpu_pct=- heals=0 ev_s_p50=- ev_s_p95=-" "first tick: nothing to rate yet"
  cpu_step 60; echo 5030000 > "$FSG_FAKE/probe-eid"; "$G" tick
  cpu_step 10; echo 5090000 > "$FSG_FAKE/probe-eid"; mem 700M; "$G" tick
  eq "$(wc -l < "$FSG_STATE_DIR/daily" | tr -d ' ')" 1 "one line per day, rewritten"
  line=$(cat "$FSG_STATE_DIR/daily")
  has "$line" "$day ticks=3 max_mb=700 max_cpu_pct=" "ticks and the largest footprint"
  case $line in *"max_cpu_pct=59 "*|*"max_cpu_pct=60 "*) ok ;; *) bad "largest CPU share: $line" ;; esac
  case $line in *"ev_s_p50=98 "*|*"ev_s_p50=99 "*|*"ev_s_p50=100 "*) ok ;; *) bad "median rate: $line" ;; esac
  case $line in *"ev_s_p95=198"|*"ev_s_p95=199"|*"ev_s_p95=200") ok ;; *) bad "95th percentile rate: $line" ;; esac
  mem 3G; "$G" tick >/dev/null 2>&1; eq $? 0 "an emergency heal"
  has "$(cat "$FSG_STATE_DIR/daily")" "$day ticks=4 max_mb=3072" "the heal's tick"
  has "$(cat "$FSG_STATE_DIR/daily")" " heals=1 " "the heal counted"
  { echo "day 2000-01-01"; echo "tick 5 1 100"; } > "$FSG_STATE_DIR/day-samples"
  printf '2000-01-01 ticks=1 max_mb=5 max_cpu_pct=1 heals=0 ev_s_p50=100 ev_s_p95=100\n%s\n' "$(cat "$FSG_STATE_DIR/daily")" > "$FSG_STATE_DIR/daily"
  "$G" tick
  eq "$(head -n 1 "$FSG_STATE_DIR/daily")" "2000-01-01 ticks=1 max_mb=5 max_cpu_pct=1 heals=0 ev_s_p50=100 ev_s_p95=100" "an earlier day stays"
  has "$(tail -n 1 "$FSG_STATE_DIR/daily")" "$day ticks=1 " "a new day's samples start over"
  eq "$(wc -l < "$FSG_STATE_DIR/daily" | tr -d ' ')" 2 "today's line replaced, not added"

  t "tick stall confirmation"
  docker_default; install_fake --no-agent
  printf 'stalled\nok\n' > "$FSG_FAKE/probe-seq"; "$G" tick; eq $? 0 "one slow probe is not a stall"
  has "$(cat "$FSG_LOG")" "probe stalled once, then ok" "logged"
  has "$(grep ' TICK level=' "$FSG_LOG" | tail -n 1)" "probe=ok/7ms start_ms=0" "the stream start time in the tick line"
  mem 300M; printf 'stalled\nstalled\nstalled\n' > "$FSG_FAKE/probe-seq"; : > "$FSG_FAKE/calls.log"
  "$G" tick >/dev/null 2>&1; rc=$?
  eq $rc 0 "confirmed stall above the floor heals"
  has "$(cat "$FSG_FAKE/calls.log")" "sudo -n /" "restart"
fi

# ======================================================================== tick-loop
if ! skip_case tick-loop; then
  t "emergency tier: a failing helper does not loop"
  docker_default; install_fake --no-agent; mem 3G
  echo 1 > "$FSG_FAKE/sudo-rc"; : > "$FSG_FAKE/calls.log"
  "$G" tick >/dev/null 2>&1; eq $? 7 "first tick: restart failed"
  "$G" tick >/dev/null 2>&1; eq $? 2 "second tick inside the interval: notify only"
  eq "$(grep -c 'docker desktop stop' "$FSG_FAKE/calls.log")" 1 "Docker bounced once, not every tick"
  has "$(tail -n 1 "$FSG_FAKE/notifications.log")" "not auto-healing" "notify-only notice"
  rm -f "$FSG_FAKE/sudo-rc"

  t "emergency tier: sudo refusing the rule stops before the drain"
  docker_default; install_fake --no-agent; mem 3G
  echo 1 > "$FSG_FAKE/sudo-l-rc"; : > "$FSG_FAKE/calls.log"; : > "$FSG_FAKE/notifications.log"
  "$G" tick >/dev/null 2>&1; eq $? 9 "not-installed path"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "docker desktop stop" "Docker untouched"
  hasnt "$(cat "$FSG_LOG")" "DRAIN begin" "no drain"
  has "$(cat "$FSG_FAKE/notifications.log")" "sudo" "notification names sudo"
  "$G" tick >/dev/null 2>&1
  eq "$(grep -c 'cannot heal' "$FSG_FAKE/notifications.log")" 1 "the agent does not repeat it every tick"
  rm -f "$FSG_FAKE/sudo-l-rc"

  t "emergency tier: the helper's root stamp counts"
  docker_default; install_fake --no-agent; mem 3G
  # Older than the helper's 30 min interval, inside the agent's 3 h interval.
  echo $(( $(date +%s) - 2000 )) > "$FSG_PREFIX/Library/Logs/fseventsd-guard/last-restart"
  : > "$FSG_FAKE/calls.log"
  "$G" tick >/dev/null 2>&1; eq $? 2 "notify only"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "sudo -n /" "no restart"
fi

# ======================================================================== heartbeat
if ! skip_case heartbeat; then
  hb() { # epoch-offset result exit pid lstart
    printf 'epoch=%s\nresult=%s\nexit=%s\npid=%s\nlstart=%s\n' $(( $(date +%s) - $1 )) "$2" "$3" "$4" "$5" > "$FSG_STATE_DIR/heartbeat"
  }
  hbv() { sed -n "s/^$1=//p" "$FSG_STATE_DIR/heartbeat"; }

  t "each tick writes a heartbeat; status reports it"
  docker_default; install_fake
  out=$("$G" status --json 2>"$C/err")
  eq "$(jget "$out" 'd["agent"]["installed"]')" True "installed"
  eq "$(jget "$out" 'd["agent"]["heartbeat_epoch"]')" None "no tick yet"
  eq "$(jget "$out" 'd["agent"]["stale"]')" False "a fresh install is not stale"
  "$G" tick; eq $? 0 "tick"
  eq "$(hbv result)" ok "result"; eq "$(hbv exit)" 0 "exit"
  e=$(hbv epoch); [ $(( $(date +%s) - e )) -le 5 ] && ok || bad "epoch is now ($e)"
  out=$("$G" status --json 2>"$C/err"); json_ok "$out"
  eq "$(jget "$out" 'd["agent"]["result"]')" ok "json result"
  eq "$(jget "$out" 'd["agent"]["exit"]')" 0 "json exit"
  eq "$(jget "$out" 'd["agent"]["interval_s"]')" 300 "json interval"
  eq "$(jget "$out" 'd["agent"]["running"]')" False "json running"
  eq "$(jget "$out" 'd["agent"]["stale"]')" False "json stale"
  eq "$(cat "$C/err")" "" "no warning"
  has "$("$G" status)" "agent: last tick" "text status"
  has "$("$G" doctor --prefix "$FSG_PREFIX" 2>&1)" "ok    agent heartbeat: last tick" "doctor"
  mem 600M; "$G" tick; eq "$(hbv result)" warn "warn tick"; eq "$(hbv exit)" 1 "warn exit"
  : > "$FSG_FAKE/fsev/pids"; "$G" tick; eq "$(hbv result)" unknown "blind tick"; eq "$(hbv exit)" 3 "blind exit"

  t "a stale heartbeat warns in status, the pre-wave call and doctor"
  docker_default; install_fake
  hb 700 ok 0 1 x
  out=$("$G" status --json 2>"$C/err"); rc=$?
  eq $rc 0 "status exit is about fseventsd only"; json_ok "$out"
  eq "$(jget "$out" 'd["agent"]["stale"]')" True "older than twice the interval"
  age=$(jget "$out" 'd["agent"]["age_s"]'); [ "${age:-0}" -ge 700 ] && ok || bad "age_s ($age)"
  has "$(cat "$C/err")" "warning: agent STALE" "stderr warning for the pre-wave call"
  has "$("$G" status)" "agent: STALE" "text status"
  "$G" doctor --prefix "$FSG_PREFIX" > "$C/doc.out" 2>&1; eq $? 1 "doctor warns"
  has "$(cat "$C/doc.out")" "WARN  agent heartbeat: STALE" "doctor line"
  FSG_AGENT_INTERVAL_S=400 "$G" status --json >/dev/null 2>"$C/err"; eq "$(cat "$C/err")" "" "within twice a longer interval"
  hb 500 ok 0 1 x
  out=$("$G" status --json); eq "$(jget "$out" 'd["agent"]["stale"]')" False "500 s is within 600"
  "$G" doctor --prefix "$FSG_PREFIX" >/dev/null 2>&1; eq $? 0 "doctor clean"

  t "no tick since install; running and dead ticks"
  docker_default; install_fake
  touch_ago 20M "$FSG_LAUNCH_AGENTS_DIR/io.github.ruslantar.fseventsd-guard.plist"
  out=$("$G" status --json 2>"$C/err")
  eq "$(jget "$out" 'd["agent"]["stale"]')" True "no tick 20 min after install"
  has "$(cat "$C/err")" "no tick recorded since the agent was installed" "message"
  bg sleep 60; p=$LAST_BG
  hb 900 running "" "$p" "$(lstart "$p")"
  out=$("$G" status --json 2>/dev/null)
  eq "$(jget "$out" 'd["agent"]["running"]')" True "running"
  eq "$(jget "$out" 'd["agent"]["stale"]')" True "a tick running 15 min outside a heal is stale"
  mkdir -p "$FSG_STATE_DIR/heal.lock"; printf 'pid=%s\nlstart=%s\n' "$p" "$(lstart "$p")" > "$FSG_STATE_DIR/heal.lock/owner"
  out=$("$G" status --json 2>/dev/null)
  eq "$(jget "$out" 'd["agent"]["stale"]')" True "a tick that holds the lock but is not in a heal is stale"
  pending "$p" 600
  out=$("$G" status --json 2>"$C/err")
  eq "$(jget "$out" 'd["agent"]["stale"]')" False "a tick in a heal is not stale"
  eq "$(cat "$C/err")" "" "no warning during a heal"
  killbg "$p"; rm -rf "$FSG_STATE_DIR/heal.lock" "$FSG_STATE_DIR/drain/pending"
  hb 60 running "" "$p" x
  out=$("$G" status --json); eq "$(jget "$out" 'd["agent"]["running"]')" False "dead tick"
  has "$("$G" status)" "ended without recording a result" "text"
  has "$("$G" doctor --prefix "$FSG_PREFIX" 2>&1)" "info  agent heartbeat:" "doctor reports it as info, not ok"

  t "an agent from before heartbeats is judged by its TICK lines"
  docker_default; install_fake
  PL="$FSG_LAUNCH_AGENTS_DIR/io.github.ruslantar.fseventsd-guard.plist"
  plutil -insert ProgramArguments.0 -string /bin/bash "$PL"
  touch_ago 20M "$PL"
  printf '%s TICK level=ok pid=4242 mb=5\n' "$(date -u -v-1M +%Y-%m-%dT%H:%M:%SZ)" >> "$FSG_LOG"
  out=$("$G" status --json 2>"$C/err")
  eq "$(jget "$out" 'd["agent"]["stale"]')" False "a ticking old agent is not stale"
  eq "$(cat "$C/err")" "" "no STALE warning for the pre-wave call"
  eq "$(jget "$out" 'd["agent"]["requests"]')" True "the app copy is current"
  "$G" doctor --prefix "$FSG_PREFIX" > "$C/doc.out" 2>&1
  has "$(cat "$C/doc.out")" "WARN  agent predates heartbeats: re-run install (its last tick in $FSG_LOG was" "doctor says to re-install"
  printf '%s TICK level=ok pid=4242 mb=5\n' "$(date -u -v-20M +%Y-%m-%dT%H:%M:%SZ)" > "$FSG_LOG"
  out=$("$G" status --json 2>"$C/err")
  eq "$(jget "$out" 'd["agent"]["stale"]')" True "stale once its TICK lines stop"
  has "$(cat "$C/err")" "warning: agent STALE" "and the pre-wave call says so"
  : > "$FSG_LOG"
  out=$("$G" status --json 2>"$C/err")
  eq "$(jget "$out" 'd["agent"]["stale"]')" False "with no TICK line an old agent is not judged by its plist's age"
  eq "$(cat "$C/err")" "" "and the pre-wave call warns of nothing"
  "$G" doctor --prefix "$FSG_PREFIX" > "$C/doc.out" 2>&1
  has "$(cat "$C/doc.out")" "WARN  agent predates heartbeats: re-run install (no TICK line in $FSG_LOG" "doctor still says to re-install"
  hasnt "$(cat "$C/doc.out")" "STALE" "and not that it is stale"

  t "an agent without a heartbeat is judged by its newest TICK line"
  docker_default; install_fake
  PL="$FSG_LAUNCH_AGENTS_DIR/io.github.ruslantar.fseventsd-guard.plist"
  touch_ago 20M "$PL"
  printf '%s TICK level=ok pid=4242 mb=5\n' "$(date -u -v-1M +%Y-%m-%dT%H:%M:%SZ)" >> "$FSG_LOG"
  out=$("$G" status --json 2>"$C/err")
  eq "$(jget "$out" 'd["agent"]["stale"]')" False "a recent TICK line is a live agent"
  eq "$(cat "$C/err")" "" "no STALE warning"
  has "$("$G" status 2>&1)" "agent: no heartbeat; the last tick in $FSG_LOG was" "status says what it judged by"
  printf '%s TICK level=ok pid=4242 mb=5\n' "$(date -u -v-30M +%Y-%m-%dT%H:%M:%SZ)" > "$FSG_LOG"
  out=$("$G" status --json 2>"$C/err")
  eq "$(jget "$out" 'd["agent"]["stale"]')" True "a TICK line older than the install does not save it"

  t "doctor reports launchctl's last exit status"
  docker_default; install_fake
  printf '\tstate = not running\n\truns = 4\n\tlast exit code = 0\n' > "$FSG_FAKE/launchctl-print"
  out=$("$G" doctor --prefix "$FSG_PREFIX" 2>&1); rc=$?
  has "$out" "ok    launchctl: the agent's last tick exited 0" "exit 0"; eq $rc 0 "doctor clean"
  printf '\tlast exit code = 8\n' > "$FSG_FAKE/launchctl-print"
  out=$("$G" doctor --prefix "$FSG_PREFIX" 2>&1); rc=$?
  has "$out" "info  launchctl: the agent's last tick exited 8, an emergency heal's exit code" "heal code"; eq $rc 0 "a heal code is not a doctor warning"
  printf '\tlast exit code = 126: Unknown error: 126\n' > "$FSG_FAKE/launchctl-print"
  out=$("$G" doctor --prefix "$FSG_PREFIX" 2>&1); rc=$?
  has "$out" "WARN  launchctl: the agent's last run exited 126: Unknown error: 126" "cannot execute"; eq $rc 1 "doctor warns"
  printf '\tlast exit code = (never exited)\n' > "$FSG_FAKE/launchctl-print"
  has "$("$G" doctor --prefix "$FSG_PREFIX" 2>&1)" "info  launchctl: the agent's last exit status: (never exited)" "never exited"
  printf '\tlast terminating signal = Terminated: 15\n' > "$FSG_FAKE/launchctl-print"
  has "$("$G" doctor --prefix "$FSG_PREFIX" 2>&1)" "ended by a signal (Terminated: 15)" "signal"

  t "no agent installed: no heartbeat warning"
  docker_default; install_fake --no-agent
  hb 7000 ok 0 1 x
  out=$("$G" status --json 2>"$C/err")
  eq "$(jget "$out" 'd["agent"]["installed"]')" False "not installed"
  eq "$(jget "$out" 'd["agent"]["stale"]')" False "not stale"
  eq "$(cat "$C/err")" "" "no warning"
fi

# ======================================================================== trial
if ! skip_case trial; then
  t "trial record"
  docker_default; install_fake --trial-hours 1
  out=$(trial --variant A --label t1); rc=$?
  eq $rc 0 "trial exit (healthy daemon restarted inside the window)"
  has "$out" "variant=A label=t1 heal_exit=0" "summary"
  has "$out" "result=healed" "result"
  grep -Eq 'docker desktop logs --no-color -p 1 -S [0-9]+s$' "$FSG_FAKE/calls.log" && ok || bad "desktop logs gets a time span: $(grep 'desktop logs' "$FSG_FAKE/calls.log")"
  d=$(ls -d "$FSG_STATE_DIR"/trials/*-A-t1)
  for f in before.txt heal.out after.txt desktop-logs-warn.txt summary.txt; do exists "$d/$f" "trial file"; done
  "$G" trial --variant Z >/dev/null 2>&1; eq $? 64 "bad variant"
  "$G" trial --variant A --no-wait >/dev/null 2>&1; eq $? 64 "a trial cannot be left to run without its requester"
  has "$(cat "$d/heal.out")" "healed in" "heal.out holds the heal's output"
  has "$out" "record in $d" "the summary names the record"
  [ -L "$(ls "$FSG_STATE_DIR"/requests/*.log)" ] && ok || bad "the request log is the trial's heal.out"
  out=$("$G" trial --summary); has "$out" "| A | 0 | healed |" "summary table row"
fi

# ======================================================================== uninstall
if ! skip_case uninstall; then
  RS_REL=usr/local/libexec/fseventsd-guard-root-steps
  t "uninstall runs the root-owned root-steps copy, also from the app copy without a checkout"
  install_fake; eq $? 0 "install"
  RS="$FSG_PREFIX/$RS_REL"; HP="$FSG_PREFIX/usr/local/libexec/fseventsd-guard-restart"
  has "$(cat "$C/install.out")" "\"$FSG_STATE_DIR/app/fseventsd-guard\" uninstall" "install ends with the uninstall command"
  rs=$(shasum -a 256 < "$RS" | awk '{print $1}')
  # An edit the gate would refuse: the copy runs anyway, and the edit does not.
  echo ': > "$FSG_FAKE/planted-ran"' >> "$GUARD_HOME/lib/root-steps.sh"
  : > "$FSG_FAKE/calls.log"
  "$FSG_STATE_DIR/app/fseventsd-guard" uninstall --yes --prefix "$FSG_PREFIX" > "$C/un.out" 2>&1; eq $? 0 "uninstall from the app copy, without --allow-unreviewed"
  has "$(cat "$C/un.out")" "root-steps sha256: $rs" "the copy's hash is printed"
  before "$C/un.out" "root-steps sha256: $rs" "root steps done"
  eq "$(grep -cF "sudo -k /bin/sh $RS uninstall" "$FSG_FAKE/calls.log")" 1 "one sudo call runs the copy"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "sudo -k /bin/sh -c" "and not a text from a checkout"
  absent "$FSG_FAKE/planted-ran" "the checkout's edit never ran"
  absent "$RS" "the copy removed itself"; absent "$HP" "helper"; absent "$FSG_STATE_DIR" "state dir"
  has "$(cat "$C/un.out")" "no traces left" "clean"
  tgit checkout -q -- plugins/fseventsd-guard/lib/root-steps.sh

  t "uninstall names an agent left under another label instead of reporting no traces"
  install_fake; eq $? 0 "install"
  OLD="$FSG_LAUNCH_AGENTS_DIR/com.example.old-guard.plist"
  cp "$FSG_LAUNCH_AGENTS_DIR/io.github.ruslantar.fseventsd-guard.plist" "$OLD"; plutil -replace Label -string com.example.old-guard "$OLD"
  "$G" uninstall --yes --prefix "$FSG_PREFIX" > "$C/un.out" 2>&1; eq $? 1 "uninstall exits 1"
  has "$(cat "$C/un.out")" "$OLD (label com.example.old-guard) runs the removed app copy: run that install's own uninstall first" "names the plist and the fix"
  has "$(cat "$C/un.out")" "left behind: $OLD" "lists it as left behind"
  hasnt "$(cat "$C/un.out")" "no traces left" "does not claim a clean uninstall"
  absent "$FSG_STATE_DIR" "the rest is removed"

  t "a root-steps copy that is not root's alone is not run; a reviewed checkout's text runs instead"
  install_fake; RS="$FSG_PREFIX/$RS_REL"
  chmod 775 "$RS"; : > "$FSG_FAKE/calls.log"
  "$G" uninstall --yes --prefix "$FSG_PREFIX" > "$C/un.out" 2>&1; eq $? 0 "uninstall from the reviewed checkout"
  has "$(cat "$C/un.out")" "not running $RS as root: it has owner uid $(id -u), mode 775" "says why"
  has "$(cat "$FSG_FAKE/calls.log")" "sudo -k /bin/sh -c" "the gated text ran"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "sudo -k /bin/sh $RS" "not the copy"
  absent "$RS" "the copy is removed anyway"
  install_fake; chmod +a "everyone allow write" "$RS"; : > "$FSG_FAKE/calls.log"
  "$FSG_STATE_DIR/app/fseventsd-guard" uninstall --yes --prefix "$FSG_PREFIX" > "$C/un.out" 2>&1; eq $? 1 "from the app copy the gate then refuses"
  has "$(cat "$C/un.out")" "not running $RS as root: it has an access control list" "says why"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "sudo" "no sudo call"; exists "$RS" "nothing removed"
  chmod -N "$RS"; chmod +a "everyone allow add_file,delete_child" "$(dirname "$RS")"; : > "$FSG_FAKE/calls.log"
  "$G" uninstall --yes --prefix "$FSG_PREFIX" > "$C/un.out" 2>&1; eq $? 0 "a helper dir with an ACL: the reviewed checkout's text runs"
  has "$(cat "$C/un.out")" "$(dirname "$RS") (owner uid $(id -u), mode 755, an access control list) lets a non-root user swap it" "names the dir"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "sudo -k /bin/sh $RS" "not the copy"

  t "an install without the root-steps copy uninstalls through the gate and says why"
  install_fake; RS="$FSG_PREFIX/$RS_REL"
  mv "$RS" "$C/rs.was"; : > "$FSG_FAKE/calls.log"
  "$FSG_STATE_DIR/app/fseventsd-guard" uninstall --yes --prefix "$FSG_PREFIX" > "$C/un.out" 2>&1; eq $? 1 "the app copy is no reviewed checkout"
  has "$(cat "$C/un.out")" "this install has no root-owned copy of the root steps ($RS" "says why the gate applies"
  has "$(cat "$C/un.out")" "is not a git checkout" "and the gate's reason"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "sudo" "no sudo call"
  exists "$FSG_PREFIX/usr/local/libexec/fseventsd-guard-restart" "nothing removed"
  "$FSG_STATE_DIR/app/fseventsd-guard" uninstall --yes --allow-unreviewed --prefix "$FSG_PREFIX" > "$C/un.out" 2>&1; eq $? 0 "--allow-unreviewed"
  has "$(cat "$FSG_FAKE/calls.log")" "sudo -k /bin/sh -c" "the app copy's text ran"
  has "$(cat "$C/un.out")" "no traces left" "clean"

  # nothing_removed: the install is whole and nothing ran as root.
  nothing_removed() {
    hasnt "$(cat "$FSG_FAKE/calls.log")" "sudo" "no sudo call"
    exists "$FSG_PREFIX/usr/local/libexec/fseventsd-guard-restart" "helper kept"
    exists "$FSG_STATE_DIR/app" "user state kept"; exists "$FSG_LAUNCH_AGENTS_DIR/io.github.ruslantar.fseventsd-guard.plist" "plist kept"
    exists "$FSG_FAKE/launchctl-loaded" "agent loaded"
  }

  t "uninstall refuses during a heal; --force stops it and waits for its tick"
  docker_default; install_fake
  mkdir -p "$FSG_STATE_DIR/heal.lock"; bg sleep 60
  printf 'pid=%s\nlstart=%s\n' "$LAST_BG" "$(lstart "$LAST_BG")" > "$FSG_STATE_DIR/heal.lock/owner"
  pending "$LAST_BG" 600; : > "$FSG_FAKE/calls.log"
  "$G" uninstall --yes --prefix "$FSG_PREFIX" > "$C/un.out" 2>&1; eq $? 1 "refused"
  has "$(cat "$C/un.out")" "a heal is in progress (tick pid $LAST_BG, phase draining)" "names the heal"
  has "$(cat "$C/un.out")" "pass --force: the agent's tick is then stopped as at logout and restores Docker before it exits" "says what --force does"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "launchctl bootout" "the agent was not unloaded"; nothing_removed
  killbg "$LAST_BG"
  # A tick in a heal that ends 3 s after the bootout, as one restoring Docker would.
  tp=$(orphan sleep 3)
  printf 'pid=%s\nlstart=%s\n' "$tp" "$(lstart "$tp")" > "$FSG_STATE_DIR/heal.lock/owner"
  pending "$tp" 600; : > "$FSG_FAKE/calls.log"
  "$G" uninstall --yes --force --prefix "$FSG_PREFIX" > "$C/un.out" 2>&1; eq $? 0 "--force"
  has "$(cat "$C/un.out")" "uninstall --force: a heal is in progress (tick pid $tp)" "says what it stops"
  has "$(cat "$C/un.out")" "waiting for a tick that holds the heal lock (pid $tp" "waits for the tick"
  before "$C/un.out" "waiting for a tick" "root steps done"
  gone "$tp" && ok || bad "the tick had ended before the root steps"
  absent "$FSG_STATE_DIR" "state dir"; has "$(cat "$C/un.out")" "no traces left" "clean"

  t "uninstall --force during a heal's Docker step names what Docker needs back before it asks"
  docker_default; install_fake
  containers "c1 pg exited healthy postgres:17 unless-stopped 1" "c2 redis exited none redis:7 unless-stopped 1"
  # A tick in its Docker step that ends 3 s after the bootout without restoring Docker.
  tp=$(orphan sleep 3)
  mkdir -p "$FSG_STATE_DIR/heal.lock"
  printf 'pid=%s\nlstart=%s\n' "$tp" "$(lstart "$tp")" > "$FSG_STATE_DIR/heal.lock/owner"
  printf 'state_version=1\nowner_pid=%s\nowner_lstart=%s\nstarted_epoch=%s\nrequest=\ntrigger=wave\nvariant=A\nkind=desktop\nstate=running\nendpoint=unix://%s\nrestore_ids=c1 c2\nrestore_names=pg redis\nheal_dir=\nafter_done=0\nhold_epoch=\n' \
    "$tp" "$(lstart "$tp")" "$(date +%s)" "$FSG_FAKE/docker/docker.sock" > "$FSG_STATE_DIR/docker-intent"
  "$G" uninstall --yes --force --prefix "$FSG_PREFIX" > "$C/un.out" 2>&1; eq $? 0 "--force"
  has "$(cat "$C/un.out")" "uninstall --force: a heal is in progress (tick pid $tp)" "names the heal"
  has "$(cat "$C/un.out")" "if it cannot, uninstall leaves Docker as it is; what to bring back then:" "says what is at stake"
  has "$(cat "$C/un.out")" "the heal of tick pid $tp (wave, Docker step A) began its Docker step at" "the heal's Docker step"
  before "$C/un.out" "and is still in it" "uninstall removes:"
  before "$C/un.out" "containers to bring back: pg redis" "[1/4]"
  # Its tick ended without restoring Docker: said again, as a fact, before anything goes.
  before "$C/un.out" "[1/4]" "uninstall --force: the stopped heal left Docker not verified, and uninstall leaves it as it is:"
  before "$C/un.out" "uninstall --force: the stopped heal left Docker not verified" "root steps done"
  before "$C/un.out" "the stopped heal left Docker not verified" "ended before Docker verified"
  eq "$(awk '$3 != "exited"' "$FSG_FAKE/docker/containers")" "" "Docker is left as it is"
  absent "$FSG_STATE_DIR" "state dir"

  t "a heal the agent's stop leaves without Docker verified stops uninstall; --force names it and goes on"
  docker_default; install_fake
  # The bootout stops a heal that began after uninstall's check, as one begun
  # while uninstall waited for its question or the password would be.
  mkdir -p "$C/at-bootout"; stub_dir "$C/rt"
  printf '#!/bin/bash\n[ "$1" = bootout ] && cp -R %q/. %q/\nexec %q "$@"\n' "$C/at-bootout" "$FSG_STATE_DIR" "$STUBS/launchctl" > "$C/rt/launchctl.new"
  chmod +x "$C/rt/launchctl.new"; mv -f "$C/rt/launchctl.new" "$C/rt/launchctl"
  dead_intent A; mv "$FSG_STATE_DIR/docker-intent" "$C/at-bootout/docker-intent"
  : > "$FSG_FAKE/calls.log"
  FSG_TEST_ROOT_TOOLS="$C/rt" "$G" uninstall --yes --prefix "$FSG_PREFIX" > "$C/un.out" 2>&1; eq $? 1 "stopped"
  out=$(cat "$C/un.out")
  has "$out" "uninstall: a heal ended as the agent stopped, and left Docker not verified:" "says why"
  has "$out" "the heal of tick pid $DEAD (wave, Docker step A) began its Docker step at" "names the heal"
  has "$out" "by hand: docker -H unix://$FSG_FAKE/docker/docker.sock start pg redis (or: docker compose up -d in the repo that runs them); then: fseventsd-guard release" "the manual fix"
  has "$out" "the agent is loaded again" "the agent is back to recover it"
  has "$out" "Nothing else was removed (the user state and logs are kept); run uninstall again" "says what is left"
  before "$FSG_FAKE/calls.log" "launchctl bootout" "launchctl bootstrap"
  nothing_removed; exists "$FSG_STATE_DIR/docker-intent" "the record is kept"
  # A failed restore's hold alone, with --force: said once the agent stopped, then removed.
  "$G" release >/dev/null 2>&1; rm -f "$C/at-bootout/docker-intent"; mkdir -p "$C/at-bootout/drain"
  printf 'state_version=1\nowner_pid=0\nstarted_epoch=%s\nhold_until_epoch=%s\ntrigger=wave\nreason=Docker not restored after a heal: containers: pg\nphase=held-docker-not-restored\nrestore_names=pg redis\nendpoint=unix:///x.sock\n' \
    "$(date +%s)" $(( $(date +%s) + 600 )) > "$C/at-bootout/drain/pending"
  : > "$FSG_FAKE/calls.log"
  FSG_TEST_ROOT_TOOLS="$C/rt" "$G" uninstall --yes --force --prefix "$FSG_PREFIX" > "$C/un.out" 2>&1; eq $? 0 "--force"
  before "$C/un.out" "[1/4]" "uninstall --force: the stopped heal left Docker not verified, and uninstall leaves it as it is:"
  before "$C/un.out" "new test runs are held: Docker not restored after a heal: containers: pg" "root steps done"
  has "$(cat "$C/un.out")" "by hand: docker desktop start (if Docker Desktop is not running); docker -H unix:///x.sock start pg redis" "the fix"
  hasnt "$(grep 'by hand' "$C/un.out")" "release" "no release step once the guard is gone"
  absent "$FSG_STATE_DIR" "state dir"; has "$(cat "$C/un.out")" "no traces left" "clean"

  t "uninstall waits for a root helper still running"
  install_fake; HP="$FSG_PREFIX/usr/local/libexec/fseventsd-guard-restart"
  hp=$(orphan /bin/sh -c 'sleep 3; :' "$HP"); sleep 0.5
  "$G" uninstall --yes --prefix "$FSG_PREFIX" > "$C/un.out" 2>&1; eq $? 0 "uninstall"
  has "$(cat "$C/un.out")" "waiting for the root helper (pid $hp)" "names it"
  absent "$FSG_PREFIX/Library/Logs/fseventsd-guard" "root logs gone"

  t "a tick still running after ExitTimeOut stops the uninstall and loads the agent again"
  install_fake; PL="$FSG_LAUNCH_AGENTS_DIR/io.github.ruslantar.fseventsd-guard.plist"
  plutil -replace ExitTimeOut -integer 1 "$PL"
  mkdir -p "$FSG_STATE_DIR/heal.lock"; bg sleep 60
  printf 'pid=%s\nlstart=%s\n' "$LAST_BG" "$(lstart "$LAST_BG")" > "$FSG_STATE_DIR/heal.lock/owner"
  : > "$FSG_FAKE/calls.log"
  "$G" uninstall --yes --prefix "$FSG_PREFIX" > "$C/un.out" 2>&1; eq $? 1 "stopped"
  has "$(cat "$C/un.out")" "still running after the wait: a tick that holds the heal lock (pid $LAST_BG" "names it"
  has "$(cat "$C/un.out")" "Nothing else was removed (the user state and logs are kept); run uninstall again" "says what is left"
  before "$FSG_FAKE/calls.log" "launchctl bootout" "launchctl bootstrap"
  nothing_removed
  killbg "$LAST_BG"

  t "a wrong or cancelled password removes nothing else and loads the agent again"
  install_fake; echo 1 > "$FSG_FAKE/sudo-rc"; : > "$FSG_FAKE/calls.log"
  "$G" uninstall --yes --prefix "$FSG_PREFIX" > "$C/un.out" 2>&1; eq $? 1 "stopped"
  has "$(cat "$C/un.out")" "the root steps did not run (wrong password, or cancelled) or failed. Nothing else was removed" "says so"
  has "$(cat "$C/un.out")" "the agent is loaded again" "and that the agent is back"
  exists "$FSG_STATE_DIR/app" "user state kept"; exists "$FSG_LOG" "user log kept"
  exists "$FSG_LAUNCH_AGENTS_DIR/io.github.ruslantar.fseventsd-guard.plist" "plist kept"; exists "$FSG_FAKE/launchctl-loaded" "agent loaded"
  rm -f "$FSG_FAKE/sudo-rc"
  "$G" uninstall --yes --prefix "$FSG_PREFIX" > "$C/un.out" 2>&1; eq $? 0 "running it again finishes"
  has "$(cat "$C/un.out")" "no traces left" "clean"

  t "uninstall root steps cut short keep the root-steps copy, which then finishes the job"
  install_fake; RS="$FSG_PREFIX/$RS_REL"; HD="$FSG_PREFIX/usr/local/libexec"; LD="$FSG_PREFIX/Library/Logs/fseventsd-guard"
  # A stand-in rm that stops the root steps where they remove the root logs, as a
  # Ctrl-C or a closed terminal there would.
  mkdir -p "$C/w"
  printf '#!/bin/sh\nfor a; do [ "$a" = "%s" ] && { kill -TERM $PPID; exit 1; }; done\nexec /bin/rm "$@"\n' "$LD" > "$C/w/rm"
  chmod +x "$C/w/rm"
  root_steps "$C/w" uninstall "$FSG_PREFIX" 0 1 > "$C/rs.out" 2>&1; eq $? 1 "stopped part way"
  has "$(cat "$C/rs.out")" "interrupted by a signal" "by the signal"
  absent "$FSG_PREFIX/etc/sudoers.d/fseventsd-guard" "the drop-in went first"; absent "$HD/fseventsd-guard-restart" "then the helper"
  exists "$RS" "the root-steps copy is kept to run again"; exists "$LD/install-manifest" "and the manifest"
  /bin/sh "$RS" uninstall "$FSG_PREFIX" 0 1 > "$C/rs.out" 2>&1; eq $? 0 "the copy runs again"
  has "$(cat "$C/rs.out")" "root steps done" "to the end"
  absent "$RS" "the copy went last"; absent "$LD" "the root logs"
  absent "$HD" "the dirs the install created, as the manifest names them"

  t "root steps cut short: uninstall names what they removed, and running it again finishes"
  install_fake; LD="$FSG_PREFIX/Library/Logs/fseventsd-guard"; stub_dir "$C/rt"; mkdir -p "$C/w"
  # sudo runs the root-steps copy with a stand-in rm that stops it where it removes
  # the root logs, as a Ctrl-C or a closed terminal there would.
  printf '#!/bin/sh\nfor a; do [ "$a" = "%s" ] && { kill -TERM $PPID; exit 1; }; done\nexec /bin/rm "$@"\n' "$LD" > "$C/w/rm"
  printf '#!/bin/bash\necho "sudo $*" >> "$FSG_FAKE/calls.log"\ntext=$(sed "s|^PATH=/usr/bin:/bin:/usr/sbin:/sbin\\$|PATH=%s:/usr/bin:/bin:/usr/sbin:/sbin|" "$3")\nshift 3\nexec /bin/sh -c "$text" fsg-root "$@"\n' "$C/w" > "$C/rt/sudo.new"
  chmod +x "$C/w/rm" "$C/rt/sudo.new"; mv -f "$C/rt/sudo.new" "$C/rt/sudo"
  FSG_TEST_ROOT_TOOLS="$C/rt" "$G" uninstall --yes --prefix "$FSG_PREFIX" > "$C/un.out" 2>&1; eq $? 1 "stopped"
  out=$(cat "$C/un.out")
  has "$out" "the root steps stopped part way, after they removed: $FSG_PREFIX/etc/sudoers.d/fseventsd-guard $FSG_PREFIX/usr/local/libexec/fseventsd-guard-restart." "names what went"
  hasnt "$out" "Nothing else was removed" "never says nothing went"
  has "$out" "the agent is loaded again" "the agent is back"
  has "$out" "The rest of the install, your user state and user logs are kept; run uninstall again to finish (until then the agent cannot heal)" "says what is left and what to do"
  exists "$FSG_PREFIX/$RS_REL" "the root-steps copy is kept"; exists "$LD/install-manifest" "the root logs"
  exists "$FSG_STATE_DIR/app" "user state kept"; exists "$FSG_LAUNCH_AGENTS_DIR/io.github.ruslantar.fseventsd-guard.plist" "plist kept"
  "$G" uninstall --yes --prefix "$FSG_PREFIX" > "$C/un.out" 2>&1; eq $? 0 "running it again finishes"
  has "$(cat "$C/un.out")" "no traces left" "clean"

  t "an earlier heal's Docker intent: uninstall has the agent restore Docker first"
  docker_default; install_fake
  containers "c1 pg exited healthy postgres:17 unless-stopped 1" "c2 redis exited none redis:7 unless-stopped 1"
  dead_intent A; : > "$FSG_FAKE/calls.log"
  FSG_AGENT_INTERVAL_S=15 "$G" uninstall --yes --prefix "$FSG_PREFIX" > "$C/un.out" 2>&1; eq $? 0 "uninstalled once Docker verified"
  has "$(cat "$C/un.out")" "asked the agent to restore it first, waiting up to 30s" "says it waits"
  has "$(cat "$FSG_FAKE/calls.log")" "launchctl kickstart gui/" "kicked the agent"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "kickstart -k" "without killing a running tick"
  before "$FSG_FAKE/calls.log" "docker start" "launchctl bootout"
  eq "$(awk '$3 != "running"' "$FSG_FAKE/docker/containers")" "" "the containers run again"
  absent "$FSG_STATE_DIR" "state dir"; has "$(cat "$C/un.out")" "no traces left" "clean"

  t "uninstall refuses while an earlier heal's Docker stays unverified, and says how to recover it"
  docker_default; install_fake; touch "$FSG_FAKE/kickstart-off"
  dead_intent A; : > "$FSG_FAKE/calls.log"
  FSG_AGENT_INTERVAL_S=1 "$G" uninstall --yes --prefix "$FSG_PREFIX" > "$C/un.out" 2>&1; eq $? 1 "refused"
  out=$(cat "$C/un.out")
  has "$out" "the agent did not restore Docker within 2s" "the kick did not help"
  has "$out" "the heal of tick pid $DEAD (wave, Docker step A) began its Docker step at" "names the heal"
  has "$out" "Docker step: A; engine: unix://$FSG_FAKE/docker/docker.sock; containers to bring back: pg redis" "variant, engine, restore set"
  has "$out" "by hand: docker -H unix://$FSG_FAKE/docker/docker.sock start pg redis (or: docker compose up -d in the repo that runs them); then: fseventsd-guard release" "the manual fix"
  has "$out" "or pass --force (removes the guard and leaves Docker as it is)" "and --force"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "launchctl bootout" "the agent stays"; nothing_removed
  exists "$FSG_STATE_DIR/docker-intent" "the record is kept"
  FSG_AGENT_INTERVAL_S=1 "$G" uninstall --yes --prefix "$FSG_PREFIX" > /dev/null 2>&1; eq $? 1 "and again"
  launchctl bootout "gui/$(id -u)/io.github.ruslantar.fseventsd-guard"
  "$G" uninstall --yes --prefix "$FSG_PREFIX" > "$C/un.out" 2>&1; eq $? 1 "an unloaded agent is not waited for"
  has "$(cat "$C/un.out")" "and the agent is not loaded to restore it" "says so"

  t "uninstall --force prints what Docker needs back, then removes everything"
  docker_default; install_fake; touch "$FSG_FAKE/kickstart-off"
  dead_intent B; : > "$FSG_FAKE/calls.log"
  "$G" uninstall --yes --force --prefix "$FSG_PREFIX" > "$C/un.out" 2>&1; eq $? 0 "--force"
  has "$(cat "$C/un.out")" "uninstall --force: Docker may still be down after an earlier heal, and uninstall leaves it as it is" "says so"
  has "$(cat "$C/un.out")" "by hand: docker desktop start; docker -H unix://$FSG_FAKE/docker/docker.sock start pg redis" "the manual fix, Docker Desktop first"
  hasnt "$(grep 'by hand' "$C/un.out")" "release" "no release step once the guard is gone"
  before "$C/un.out" "containers to bring back: pg redis" "[1/4]"
  eq "$(grep -c 'containers to bring back' "$C/un.out")" 1 "said once"
  hasnt "$(cat "$FSG_FAKE/calls.log")" "kickstart" "no wait for the agent"
  absent "$FSG_STATE_DIR" "state dir"

  t "a hold left by a failed restore refuses until release"
  docker_default; install_fake
  mkdir -p "$FSG_STATE_DIR/drain"
  printf 'state_version=1\nowner_pid=0\nstarted_epoch=%s\nhold_until_epoch=%s\ntrigger=manual\nreason=Docker not restored after a heal: containers: pg\nphase=held-docker-not-restored\nrestore_names=pg redis\nendpoint=unix:///x.sock\n' \
    "$(date +%s)" $(( $(date +%s) + 600 )) > "$FSG_STATE_DIR/drain/pending"
  : > "$FSG_FAKE/calls.log"
  "$G" uninstall --yes --prefix "$FSG_PREFIX" > "$C/un.out" 2>&1; eq $? 1 "refused"
  has "$(cat "$C/un.out")" "new test runs are held: Docker not restored after a heal: containers: pg" "names the hold"
  has "$(cat "$C/un.out")" "by hand: docker desktop start (if Docker Desktop is not running); docker -H unix:///x.sock start pg redis" "the fix"
  has "$(cat "$C/un.out")" "then: fseventsd-guard release" "release"
  nothing_removed
  "$G" release >/dev/null 2>&1
  "$G" uninstall --yes --prefix "$FSG_PREFIX" > /dev/null 2>&1; eq $? 0 "uninstalls after release"

  t "uninstall removes the paths the agent's plist names, not the ones the shell exports"
  install_fake; echo agent > "$FSG_AGENT_LOG"
  S0=$FSG_STATE_DIR; L0=$FSG_LOG; A0=$FSG_AGENT_LOG
  O="$C/other"; mkdir -p "$O/fseventsd-guard"; echo keep > "$O/fseventsd-guard/file"; echo keep > "$O/fseventsd-guard.log"; echo keep > "$O/fseventsd-guard.agent.log"
  FSG_STATE_DIR="$O/fseventsd-guard" FSG_LOG="$O/fseventsd-guard.log" FSG_AGENT_LOG="$O/fseventsd-guard.agent.log" \
    "$G" uninstall --yes --prefix "$FSG_PREFIX" > "$C/un.out" 2>&1; eq $? 0 "uninstall"
  absent "$S0" "the agent's state dir"; absent "$L0" "the agent's user log"; absent "$A0" "the agent's stdout log"
  exists "$O/fseventsd-guard/file" "the exported state dir is left alone"
  exists "$O/fseventsd-guard.log" "the exported user log"; exists "$O/fseventsd-guard.agent.log" "the exported agent log"
  has "$(cat "$C/un.out")" "no traces left" "clean"

  t "a path in the plist that is not the guard's own is left alone and reported"
  install_fake; PL="$FSG_LAUNCH_AGENTS_DIR/io.github.ruslantar.fseventsd-guard.plist"
  echo precious > "$C/home/precious.txt"
  plutil -replace StandardOutPath -string "$C/home/precious.txt" "$PL"
  plutil -replace EnvironmentVariables.FSG_STATE_DIR -string "$C/home" "$PL"
  "$G" uninstall --yes --prefix "$FSG_PREFIX" > "$C/un.out" 2>&1; eq $? 1 "uninstall says it left them"
  exists "$C/home/precious.txt" "a file the plist names as its log"
  exists "$C/home/LaunchAgents" "a dir the plist names as its state dir"
  has "$(cat "$C/un.out")" "not removed, as they do not end in the guard's own names: $C/home $C/home/precious.txt" "names them"
  absent "$PL" "the plist itself goes"; absent "$FSG_PREFIX/usr/local/libexec/fseventsd-guard-restart" "and the root part"

  t "uninstall sweeps the temp files interrupted guard commands left, not those in use"
  install_fake
  mkdir "$TMPDIR/fseventsd-guard-install.abc123"; : > "$TMPDIR/fseventsd-guard-install.abc123/helper"
  : > "$TMPDIR/fsg-doctor.abc123"; : > "$TMPDIR/fsg-timeout.abc123"; : > "$TMPDIR/unrelated.txt"
  touch_ago 2H "$TMPDIR/fseventsd-guard-install.abc123" "$TMPDIR/fsg-doctor.abc123" "$TMPDIR/fsg-timeout.abc123"
  # A guard command running in another terminal (an install staging, a timeout flag).
  mkdir "$TMPDIR/fseventsd-guard-install.new123"; : > "$TMPDIR/fsg-timeout.new123"
  touch_ago 50M "$TMPDIR/fsg-timeout.new123"
  "$G" uninstall --yes --prefix "$FSG_PREFIX" > "$C/un.out" 2>&1; eq $? 0 "uninstall"
  has "$(cat "$C/un.out")" "temp files that interrupted guard commands left:" "listed"
  has "$(cat "$C/un.out")" "$TMPDIR/fsg-timeout.abc123" "by name"
  absent "$TMPDIR/fseventsd-guard-install.abc123" "install staging"; absent "$TMPDIR/fsg-doctor.abc123" "doctor"
  absent "$TMPDIR/fsg-timeout.abc123" "timeout flag"; exists "$TMPDIR/unrelated.txt" "other files stay"
  exists "$TMPDIR/fseventsd-guard-install.new123" "a staging dir in use stays"; exists "$TMPDIR/fsg-timeout.new123" "so does a flag under an hour old"
  hasnt "$(cat "$C/un.out")" "new123" "neither is listed nor reported as left"
  has "$(cat "$C/un.out")" "no traces left" "clean"

  t "uninstall names a launchd switched-off setting and the command that clears it"
  install_fake
  printf 'disabled services = {\n\t"com.apple.x" => disabled\n\t"io.github.ruslantar.fseventsd-guard" => disabled\n}\n' > "$FSG_FAKE/launchctl-disabled"
  "$G" uninstall --yes --prefix "$FSG_PREFIX" > "$C/un.out" 2>&1; eq $? 0 "uninstall"
  has "$(cat "$C/un.out")" "launchd still keeps io.github.ruslantar.fseventsd-guard switched off (from Login Items); clear that setting with: launchctl enable gui/$(id -u)/io.github.ruslantar.fseventsd-guard" "the one command"
  has "$(cat "$C/un.out")" "uninstalled: no files left, only the launchd setting named above" "and the summary says so"
  install_fake; printf '\t"io.github.ruslantar.fseventsd-guard" => enabled\n' > "$FSG_FAKE/launchctl-disabled"
  "$G" uninstall --yes --prefix "$FSG_PREFIX" > "$C/un.out" 2>&1
  hasnt "$(cat "$C/un.out")" "launchctl enable" "an enabled entry is not reported"

  # records: a heal record, a trial record and the last-heal stamps, as heals leave them.
  records() {
    mkdir -p "$FSG_STATE_DIR/heals/20261023T000000Z-1" "$FSG_STATE_DIR/trials/20261023T000000-B-t1"
    echo result=healed > "$FSG_STATE_DIR/heals/20261023T000000Z-1/result.txt"
    echo "variant=B" > "$FSG_STATE_DIR/trials/20261023T000000-B-t1/summary.txt"
    echo "1 healed manual B 60" > "$FSG_STATE_DIR/last-heal"; echo "$FSG_STATE_DIR/heals/20261023T000000Z-1" > "$FSG_STATE_DIR/last-heal-dir"
    echo "FSG_WARN_MB=600" >> "$FSG_STATE_DIR/config"
    echo "2026-10-23 ticks=288 max_mb=5 max_cpu_pct=1 heals=0 ev_s_p50=120 ev_s_p95=900" > "$FSG_STATE_DIR/daily"
  }

  t "uninstall --keep-logs keeps the logs and moves the records and the config out"
  install_fake; records; echo agent > "$FSG_AGENT_LOG"
  "$G" uninstall --yes --keep-logs --prefix "$FSG_PREFIX" > "$C/un.out" 2>&1; eq $? 0 "uninstall --keep-logs"
  R=$(ls -d "$C/home/Logs"/fseventsd-guard-records-* 2>/dev/null)
  [ -n "$R" ] && [ -d "$R" ] && ok || bad "a dated records dir next to the user log"
  exists "$R/heals/20261023T000000Z-1/result.txt" "heal record"; exists "$R/trials/20261023T000000-B-t1/summary.txt" "trial record"
  exists "$R/last-heal" "last-heal"; exists "$R/last-heal-dir" "last-heal-dir"; exists "$R/daily" "the per-day summary"
  has "$(cat "$R/config" 2>/dev/null)" "FSG_WARN_MB=600" "the config"
  exists "$FSG_LOG" "user log"; exists "$FSG_AGENT_LOG" "agent log"; exists "$FSG_PREFIX/Library/Logs/fseventsd-guard" "root logs"
  absent "$FSG_STATE_DIR" "the rest of the state dir goes"
  has "$(cat "$C/un.out")" "kept: the heal and trial records and the config, moved to $R" "the final message names it"
  has "$(cat "$C/un.out")" "to remove it later: sudo rm -rf $FSG_PREFIX/Library/Logs/fseventsd-guard" "and how to remove the root logs later"

  t "uninstall without --keep-logs removes the records too"
  install_fake; records
  "$G" uninstall --yes --prefix "$FSG_PREFIX" > "$C/un.out" 2>&1; eq $? 0 "uninstall"
  eq "$(ls -d "$C/home/Logs"/fseventsd-guard-records-* 2>/dev/null)" "" "no records dir"
  absent "$FSG_STATE_DIR" "state dir"; absent "$FSG_LOG" "user log"

  # hint_cache: the Claude Code install hint's stamps and off switch, as it leaves them.
  hint_cache() { mkdir -p "$FSG_HINT_DIR"; date +%s > "$FSG_HINT_DIR/checked"; date +%s > "$FSG_HINT_DIR/last-warn"; : > "$FSG_HINT_DIR/off"; }

  t "install and uninstall remove the Claude Code install hint's stamps"
  hint_cache; install_fake; eq $? 0 "install"
  absent "$FSG_HINT_DIR" "install removes them: moot once installed"
  hint_cache
  "$G" uninstall --yes --prefix "$FSG_PREFIX" > "$C/un.out" 2>&1; eq $? 0 "uninstall"
  has "$(cat "$C/un.out")" "$FSG_HINT_DIR (the Claude Code install hint's stamps and off switch)" "listed"
  absent "$FSG_HINT_DIR" "uninstall removes them"
  has "$(cat "$C/un.out")" "uninstalled: no traces left" "clean"
  install_fake; hint_cache
  "$G" uninstall --yes --keep-logs --prefix "$FSG_PREFIX" > "$C/un.out" 2>&1; eq $? 0 "uninstall --keep-logs"
  absent "$FSG_HINT_DIR" "--keep-logs removes them too (no log)"
  # Named otherwise (an exported FSG_HINT_DIR), the dir is not the guard's to remove.
  export FSG_HINT_DIR="$C/home/Caches/other"; hint_cache
  install_fake; eq $? 0 "install"; exists "$FSG_HINT_DIR/checked" "install leaves another name alone"
  "$G" uninstall --yes --prefix "$FSG_PREFIX" > "$C/un.out" 2>&1; eq $? 0 "uninstall does not fail over it"
  exists "$FSG_HINT_DIR/checked" "uninstall leaves another name alone"
  hasnt "$(cat "$C/un.out")" "$FSG_HINT_DIR" "nor lists it"
fi

# hook MODE [EVENT [SESSION]]: the Claude Code hook subcommand, fed the stdin JSON
# Claude Code sends, with a command that quotes the field names as a Bash call may.
hook() {
  printf '{"session_id":"%s","transcript_path":"/t.jsonl","cwd":"/w","hook_event_name":"%s","tool_name":"Bash","tool_input":{"command":"echo \\"session_id\\": \\"x\\", \\"hook_event_name\\": \\"Stop\\""}}' \
    "${3:-s1}" "${2:-UserPromptSubmit}" | "$G" claude-hook "$1"
}
# The model's context and the user's warning in a hook's JSON.
hook_ctx() { jget "$1" 'd["hookSpecificOutput"]["additionalContext"]'; }
hook_msg() { jget "$1" 'd["systemMessage"]'; }
# fake_uname DIR NAME: a uname that says NAME, for PATH="DIR:$PATH"; not_darwin: Linux.
fake_uname() { mkdir -p "$1"; printf '#!/bin/sh\necho %s\n' "$2" > "$1/uname"; chmod +x "$1/uname"; }
not_darwin() { fake_uname "$1" Linux; }
# appg: the installed app copy's command, as the heal notice names it.
appg() {
  local g="$FSG_STATE_DIR/app/fseventsd-guard"
  case $g in "$HOME"/*) g="\$HOME${g#"$HOME"}" ;; esac
  printf '"%s"' "$g"
}
# hint_stamp NAME SECONDS-AGO: an install hint stamp written that long ago.
hint_stamp() { mkdir -p "$FSG_HINT_DIR"; echo $(( $(date +%s) - $2 )) > "$FSG_HINT_DIR/$1"; }

# ======================================================================== claude-hook-prompt
if ! skip_case claude-hook-prompt; then
  t "claude-hook prompt: a runaway nudge names the footprint, the command and how to silence it"
  export CLAUDE_PROJECT_DIR="$REPO"
  mem 3G
  out=$(hook prompt); rc=$?
  eq $rc 0 "exit"; json_ok "$out"
  eq "$(jget "$out" 'd["hookSpecificOutput"]["hookEventName"]')" UserPromptSubmit "event name"
  m=$(hook_msg "$out"); x=$(hook_ctx "$out")
  has "$m" "fseventsd is running away: 3.0 GB, 102x Apple's 30 MB budget (up 1h02m)" "the user's line"
  has "$m" "On macOS 27.0.1 it can grow without limit and silently stop delivering file events" "why it matters"
  has "$m" "new terminal window (it asks for sudo): if [ -d ~/fseventsd-guard ]; then git -C ~/fseventsd-guard pull --ff-only; else git clone https://github.com/RuslanTar/fseventsd-guard.git ~/fseventsd-guard; fi && ~/fseventsd-guard/plugins/fseventsd-guard/fseventsd-guard install." "the install command, from an up-to-date clone of the public repo"
  has "$m" "Silence: FSG_HINT=0, or touch $FSG_HINT_DIR/off" "how to silence it"
  has "$x" "a footprint of 3072 MB (102x Apple's 30 MB budget), uptime 1h02m, level runaway (the guard warns at 500 MB and heals at 2048 MB)" "the facts"
  has "$x" "On macOS 27.0.1 fseventsd has a known bug" "the version"
  has "$x" "IDE, dev servers, Docker bind mounts and Claude Code stop seeing file changes" "the symptoms"
  has "$x" "runs in a new terminal window, not through Claude: if [ -d ~/fseventsd-guard ]; then git -C ~/fseventsd-guard pull --ff-only; else git clone https://github.com/RuslanTar/fseventsd-guard.git ~/fseventsd-guard; fi && ~/fseventsd-guard/plugins/fseventsd-guard/fseventsd-guard install, then the same path with doctor." "install, then doctor"
  has "$x" "Why and what it costs: https://github.com/RuslanTar/fseventsd-guard#readme." "the README"
  hasnt "$out" "$REPO" "no project checkout or its path assumed"
  has "$x" "once an hour at this level" "the cadence"
  has "$x" "FSG_HINT=0 in Claude Code's environment, or a file $FSG_HINT_DIR/off, silences it" "how to silence it"
  has "$x" "The user has not been told about this in the conversation yet." "to relay once"
  [ ${#x} -lt 1400 ] && ok || bad "context under ~1,300 chars plus the test paths (${#x})"
  hasnt "$out" "permissionDecision" "never allows or denies"
  exists "$FSG_HINT_DIR/last-runaway" "stamped"

  t "claude-hook prompt: warn and ok nudges"
  export CLAUDE_PROJECT_DIR="$REPO"
  mem 612M; out=$(hook prompt); json_ok "$out"
  has "$(hook_msg "$out")" "fseventsd is growing: 612 MB, 20x Apple's 30 MB budget (up 1h02m)" "warn line"
  has "$(hook_ctx "$out")" "level warn (the guard warns at 500 MB" "warn facts"
  has "$(hook_ctx "$out")" "every 3 hours at this level" "warn cadence"
  rm -rf "$FSG_HINT_DIR"; mem 5000K; out=$(hook prompt); json_ok "$out"
  has "$(hook_msg "$out")" "fseventsd is fine now (4 MB, within Apple's 30 MB budget), but it can grow" "ok line"
  has "$(hook_ctx "$out")" "once a day at this level" "ok cadence"
  mem 600M; rm -rf "$FSG_HINT_DIR"
  FSG_WARN_MB=700 hook prompt > "$C/o"; has "$(cat "$C/o")" "fseventsd is fine now (600 MB, 20x" "the thresholds follow the config"

  t "claude-hook prompt: silent when installed, not affected, off macOS or switched off"
  mem 3G
  app_copy; eq "$(hook prompt)" "" "app copy installed"; rm -rf "$FSG_STATE_DIR/app"
  : > "$FSG_LAUNCH_AGENTS_DIR/io.github.ruslantar.fseventsd-guard.plist"; eq "$(hook prompt)" "" "agent plist installed"
  rm "$FSG_LAUNCH_AGENTS_DIR/io.github.ruslantar.fseventsd-guard.plist"
  absent "$FSG_HINT_DIR" "an installed guard is neither measured nor stamped"
  echo 15.5 > "$FSG_FAKE/sw_vers"; eq "$(hook prompt)" "" "a version before the range"; rm "$FSG_FAKE/sw_vers"
  rm -rf "$FSG_HINT_DIR"; eq "$(FSG_AFFECTED=no hook prompt)" "" "FSG_AFFECTED=no"
  rm -rf "$FSG_HINT_DIR"; not_darwin "$C/bin"
  eq "$(PATH="$C/bin:$PATH" hook prompt)" "" "not macOS"; absent "$FSG_HINT_DIR" "nothing written off macOS"
  for v in 0 off OFF False No; do eq "$(FSG_HINT=$v hook prompt)" "" "FSG_HINT=$v"; done
  absent "$FSG_HINT_DIR" "FSG_HINT=0 measures nothing"
  mkdir -p "$FSG_HINT_DIR"; : > "$FSG_HINT_DIR/off"; eq "$(hook prompt)" "" "the off file"
  absent "$FSG_HINT_DIR/checked" "the off file measures nothing"
  rm "$FSG_HINT_DIR/off"; has "$(hook prompt)" "running away" "shown otherwise"
  eq "$("$G" claude-hook < /dev/null; echo "rc=$?")" "rc=0" "no mode: nothing, exit 0"
  eq "$("$G" claude-hook other < /dev/null; echo "rc=$?")" "rc=0" "an unknown mode: nothing, exit 0"

  t "claude-hook prompt: silent when fseventsd cannot be measured"
  : > "$FSG_FAKE/fsev/pids"; eq "$(hook prompt)" "" "no daemon"
  exists "$FSG_HINT_DIR/checked" "the check is stamped, so the next prompts do not measure"
  ls "$FSG_HINT_DIR"/last-* >/dev/null 2>&1 && bad "no nudge stamped" || ok

  t "claude-hook prompt: one nudge per level's interval, for every session"
  export CLAUDE_PROJECT_DIR="$REPO"
  mem 3G; has "$(hook prompt UserPromptSubmit a)" "running away" "the first prompt"
  eq "$(hook prompt UserPromptSubmit b)" "" "another session within the hour"
  c0=$(( $(date +%s) - 100 )); echo "$c0" > "$FSG_HINT_DIR/checked"
  eq "$(hook prompt)" "" "checked 100 s ago: silent"
  eq "$(cat "$FSG_HINT_DIR/checked")" "$c0" "and nothing measured (the check stamp is untouched)"
  hint_stamp checked 3700; hint_stamp last-runaway 1800; eq "$(hook prompt)" "" "runaway: within its hour"
  hint_stamp checked 3700; hint_stamp last-runaway 3700; has "$(hook prompt)" "running away" "runaway: after an hour"
  mem 612M
  hint_stamp checked 3700; hint_stamp last-runaway 7200; eq "$(hook prompt)" "" "warn: a runaway nudge 2 h ago counts"
  rm "$FSG_HINT_DIR/last-runaway"
  hint_stamp checked 3700; hint_stamp last-warn 7200; eq "$(hook prompt)" "" "warn: within 3 h"
  hint_stamp checked 3700; hint_stamp last-warn 11000; has "$(hook prompt)" "is growing" "warn: after 3 h"
  mem 5000K; rm -f "$FSG_HINT_DIR"/last-*
  hint_stamp checked 3700; hint_stamp last-warn 72000; eq "$(hook prompt)" "" "ok: a warn nudge 20 h ago counts"
  hint_stamp checked 3700; hint_stamp last-warn 90000; has "$(hook prompt)" "is fine now" "ok: after a day"
  hint_stamp checked 3700; eq "$(hook prompt)" "" "ok: once a day"
  mem 3G; hint_stamp checked 3700; has "$(hook prompt)" "running away" "a lower level's stamp does not hold back a higher one"

  t "claude-hook prompt: the same nudge in any project, or none"
  d="$C/a \"quoted\" \\ dir"; mkdir -p "$d"; export CLAUDE_PROJECT_DIR="$d"
  mem 3G; out=$(hook prompt); json_ok "$out"
  has "$(hook_msg "$out")" ": if [ -d ~/fseventsd-guard ]; then git -C ~/fseventsd-guard pull --ff-only; else git clone https://github.com/RuslanTar/fseventsd-guard.git " "the clone command"
  hasnt "$out" "quoted" "the project path is not used"
  unset CLAUDE_PROJECT_DIR; rm -rf "$FSG_HINT_DIR"
  eq "$(hook prompt)" "$out" "no project dir: the same nudge"

  t "claude-hook prompt: the install command updates an existing clone before install"
  mem 3G; m=$(hook_msg "$(hook prompt)")
  cmd=${m#*it asks for sudo): }; cmd=${cmd%%. Why:*}
  # A stand-in git that logs its call and fails when $C/git-fails exists; the clone's
  # guard is a stand-in that logs its install.
  mkdir -p "$C/gitbin" "$C/h"
  printf '#!/bin/sh\necho "git $*" >> "%s/cmd.log"\n[ ! -e "%s/git-fails" ]\n' "$C" "$C" > "$C/gitbin/git"; chmod +x "$C/gitbin/git"
  runcmd() { : > "$C/cmd.log"; HOME="$C/h" PATH="$C/gitbin:$PATH" bash -c "$cmd" >/dev/null 2>&1; cat "$C/cmd.log"; }
  eq "$(runcmd)" "git clone https://github.com/RuslanTar/fseventsd-guard.git $C/h/fseventsd-guard" "no clone yet: it clones"
  mkdir -p "$C/h/fseventsd-guard/plugins/fseventsd-guard"
  printf '#!/bin/sh\necho "guard $*" >> "%s/cmd.log"\n' "$C" > "$C/h/fseventsd-guard/plugins/fseventsd-guard/fseventsd-guard"
  chmod +x "$C/h/fseventsd-guard/plugins/fseventsd-guard/fseventsd-guard"
  eq "$(runcmd)" "git -C $C/h/fseventsd-guard pull --ff-only
guard install" "an existing clone: fast-forwarded, then install"
  touch "$C/git-fails"
  eq "$(runcmd)" "git -C $C/h/fseventsd-guard pull --ff-only" "a clone that cannot fast-forward: no install of the old release"
fi

# heal_state PHASE VARIANT OWNER-PID [STARTED]: the drain marker of a live emergency
# heal that began at the epoch STARTED (default: a minute ago). Pass the same STARTED
# for each phase of one heal: the drain marker keeps it.
heal_state() {
  mkdir -p "$FSG_STATE_DIR/drain/leases"
  printf 'state_version=1\nowner_pid=%s\nowner_lstart=%s\nstarted_epoch=%s\ndeadline_epoch=%s\ntrigger=emergency\nreason=emergency heal: footprint 3072 MB\nphase=%s\nvariant=%s\n' \
    "$3" "$(lstart "$3")" "${4:-$(( $(date +%s) - 60 ))}" $(( $(date +%s) + 600 )) "$1" "$2" > "$FSG_STATE_DIR/drain/pending"
}

# ======================================================================== claude-hook-bash
if ! skip_case claude-hook-bash; then
  t "claude-hook bash: silent without a heal, or without the guard"
  app_copy
  eq "$(hook bash PreToolUse)" "" "no heal state"
  echo "$(( $(date +%s) - 700 )) healed manual B 95 /x" > "$FSG_STATE_DIR/last-heal"
  eq "$(hook bash PostToolUse)" "" "a heal that ended over 10 minutes ago"
  absent "$TMPDIR/fseventsd-guard-hook" "nothing stamped"
  bg sleep 120; own=$LAST_BG; heal_state draining B "$own"
  eq "$(hook bash UserPromptSubmit)" "" "another event"
  eq "$("$G" claude-hook bash < /dev/null)" "" "no stdin JSON"
  rm -rf "$FSG_STATE_DIR/app"; eq "$(hook bash PreToolUse)" "" "the guard not installed"
  app_copy; eq "$(FSG_HINT=0 hook bash PreToolUse)" "" "FSG_HINT=0"
  for v in OFF False; do eq "$(FSG_HINT=$v hook bash PreToolUse)" "" "FSG_HINT=$v"; done
  not_darwin "$C/bin"; eq "$(PATH="$C/bin:$PATH" hook bash PreToolUse)" "" "not macOS, even when called directly"
  absent "$TMPDIR/fseventsd-guard-hook" "nothing stamped by those"
  has "$(hook bash PreToolUse)" "waiting for runs" "the same call on macOS gets the notice"
  killbg "$own"; eq "$(hook bash PreToolUse s2)" "" "a drain whose heal died"

  t "claude-hook bash: one notice per session and phase, while a heal drains, works on Docker and after it ended"
  app_copy; bg sleep 120; own=$LAST_BG; hs=$(( $(date +%s) - 60 ))
  heal_state draining B "$own" "$hs"
  at=$(date -r "$(sed -n 's/^started_epoch=//p' "$FSG_STATE_DIR/drain/pending")" +%H:%M)
  out=$(hook bash PreToolUse s1); json_ok "$out"
  eq "$(jget "$out" 'd["hookSpecificOutput"]["hookEventName"]')" PreToolUse "event name"
  x=$(hook_ctx "$out")
  has "$x" "fseventsd-guard is healing fseventsd on this Mac: a heal began at $at (trigger emergency; Docker step B: it quits Docker Desktop before the fseventsd restart, then starts it and the containers again)" "since when, and what it does to Docker"
  has "$x" "It is waiting for runs that started before it to finish (the drain); Docker is untouched until then." "the drain"
  has "$x" "docker, docker compose and test commands may fail, hang or find Docker stopped" "what may fail"
  has "$x" "Runs under a drain lease (fseventsd-guard run, integrated runners) are held and start by themselves when it ends" "leased runs"
  has "$x" "Restarting Docker or containers by hand during the heal interferes with it." "hands off Docker"
  has "$x" "Progress: $(appg) status" "how to check, with the installed app copy"
  hasnt "$x" "$REPO" "no project checkout assumed"
  [ ${#x} -lt 1200 ] && ok || bad "under 1,200 chars (${#x})"
  has "$(hook_ctx "$(HOME="$C/home" hook bash PreToolUse s9)")" "Progress: \"\$HOME/state/fseventsd-guard/app/fseventsd-guard\" status" "under the home dir: \$HOME, which a shell expands in the quotes"
  hasnt "$out" "permissionDecision" "never allows or denies"; hasnt "$out" "systemMessage" "context only"
  eq "$(hook bash PostToolUse s1)" "" "once per session and phase"
  out=$(hook bash PostToolUse s2)
  eq "$(jget "$out" 'd["hookSpecificOutput"]["hookEventName"]')" PostToolUse "another session gets it, on PostToolUse"
  out=$(printf '{"session_id":"s1","hook_event_name":"PreToolUse","agent_id":"a1","tool_name":"Bash"}' | "$G" claude-hook bash)
  has "$(hook_ctx "$out")" "waiting for runs" "a subagent gets its own"
  heal_state restarting B "$own" "$hs"
  x=$(hook_ctx "$(hook bash PreToolUse s1)")
  has "$x" "and is in its Docker step and fseventsd restart (phase restarting)" "the Docker phase"
  has "$x" "a failure in this window is likely the heal, not the code, and is worth re-running once it ends" "failures explained"
  eq "$(hook bash PreToolUse s1)" "" "once for the Docker phase too"
  heal_state verifying B "$own" "$hs"; eq "$(hook bash PreToolUse s1)" "" "a later Docker phase is the same phase"
  killbg "$own"; rm -f "$FSG_STATE_DIR/drain/pending"
  e=$(( $(date +%s) - 5 )); echo "$e healed manual B 95 $FSG_STATE_DIR/heals/x" > "$FSG_STATE_DIR/last-heal"
  out=$(hook bash PostToolUse s1); json_ok "$out"; x=$(hook_ctx "$out")
  has "$x" "fseventsd-guard: a heal of fseventsd (trigger manual; Docker step B" "which heal"
  has "$x" "ran from $(date -r $((e - 95)) +%H:%M) to $(date -r $e +%H:%M) and ended: fseventsd restarted, and Docker and its containers verified." "when, and the result"
  has "$x" "A docker, docker compose or test failure in that window is likely the heal, not the code, and is worth re-running." "re-run advice"
  has "$x" "If a session stops seeing file changes after the heal, restart it." "watcher advice after a restart"
  eq "$(hook bash PostToolUse s1)" "" "once after it ended"

  t "claude-hook bash: a heal that left Docker not verified, or was stopped part way"
  app_copy; mkdir -p "$FSG_STATE_DIR/drain/leases"; e=$(date +%s)
  printf 'state_version=1\nowner_pid=0\nstarted_epoch=%s\nhold_until_epoch=%s\ntrigger=emergency\nreason=Docker not restored after a heal: containers: pg\nphase=held-docker-not-restored\nvariant=C\nrestore_names=pg redis\n' \
    "$e" $((e + 600)) > "$FSG_STATE_DIR/drain/pending"
  out=$(hook bash PreToolUse s1); json_ok "$out"; x=$(hook_ctx "$out")
  has "$x" "a heal of fseventsd (trigger emergency; Docker step C: it restarts Docker Desktop after the fseventsd restart" "which heal"
  has "$x" "did not get Docker verified (since $(date -r $e +%H:%M): Docker not restored after a heal: containers: pg)" "why"
  has "$x" "stay held until the guard's agent sees Docker back (it checks every 5 minutes)" "the agent's next step"
  has "$x" "and runs $(appg) release" "the way out"
  eq "$(hook bash PostToolUse s1)" "" "once"
  rm -f "$FSG_STATE_DIR/drain/pending"
  # A tick killed in its Docker step leaves only its intent, which holds runs.
  printf 'state_version=1\nowner_pid=999999\nowner_lstart=gone\nstarted_epoch=%s\ntrigger=wave\nvariant=A\naction_ran=0\nhold_s=3600\n' \
    $((e - 30)) > "$FSG_STATE_DIR/docker-intent"
  x=$(hook_ctx "$(hook bash PreToolUse s1)")
  has "$x" "(trigger wave; Docker step A" "named from the intent"
  has "$x" "its agent tick stopped before Docker verified" "why"
  sed 's/^variant=A$/variant=none/' "$FSG_STATE_DIR/docker-intent" > "$C/i" && cat "$C/i" > "$FSG_STATE_DIR/docker-intent"
  eq "$(hook bash PreToolUse s2)" "" "an intent that holds no runs (variant none) is no heal to tell of"

  t "claude-hook bash: a heal that ended without touching Docker"
  app_copy; e=$(date +%s)
  echo "$e aborted-at-cap wave B 30 /x" > "$FSG_STATE_DIR/last-heal"
  x=$(hook_ctx "$(hook bash PostToolUse s1)")
  has "$x" "and ended: it gave up at the drain cap, and nothing was stopped or restarted." "the result"
  hasnt "$x" "stops seeing file changes" "no watcher advice without a restart"
  hasnt "$x" "worth re-running" "no failure to explain"
  echo "$((e - 1)) healed manual none 30 /x" > "$FSG_STATE_DIR/last-heal"
  x=$(hook_ctx "$(hook bash PostToolUse s1)")
  has "$x" "Docker step none: it leaves Docker alone" "variant none"; hasnt "$x" "worth re-running" "nor for variant none"

  t "claude-hook bash: a failed restart says what happened to Docker"
  app_copy; e=$(date +%s)
  echo "$e restart-failed manual skip 30 /x" > "$FSG_STATE_DIR/last-heal"
  x=$(hook_ctx "$(hook bash PostToolUse s1)")
  has "$x" "and ended: the fseventsd restart failed ($(appg) doctor says why), and Docker was left alone." "no Docker step"
  hasnt "$x" "brought back" "not brought back"
  echo "$((e - 1)) restart-failed manual B 30 /x" > "$FSG_STATE_DIR/last-heal"
  has "$(hook_ctx "$(hook bash PostToolUse s1)")" "and ended: the fseventsd restart failed ($(appg) doctor says why), and Docker was brought back." "Docker verified"
  # An intent that holds no runs (C before its restart) is left until Docker verified.
  printf 'state_version=1\nowner_pid=999999\nowner_lstart=gone\nstarted_epoch=%s\ntrigger=manual\nvariant=C\naction_ran=0\nhold_s=3600\n' \
    $((e - 30)) > "$FSG_STATE_DIR/docker-intent"
  echo "$((e - 2)) restart-failed manual C 30 /x" > "$FSG_STATE_DIR/last-heal"
  x=$(hook_ctx "$(hook bash PostToolUse s1)")
  has "$x" "and ended: the fseventsd restart failed ($(appg) doctor says why), and Docker is not verified back ($(appg) status says what is left)." "Docker not verified"
  hasnt "$x" "brought back" "not claimed back"

  t "claude-hook bash: a drain marker or hold a killed heal left costs no process"
  app_copy; mkdir -p "$FSG_STATE_DIR/drain/leases" "$C/log"
  printf '#!/bin/bash\necho "ps $*" >> "%s/calls"\nexec "%s/ps" "$@"\n' "$C/log" "$STUBS" > "$C/log/ps"
  printf '#!/bin/bash\necho "sed $*" >> "%s/calls"\nexec /usr/bin/sed "$@"\n' "$C/log" > "$C/log/sed"
  chmod +x "$C/log/ps" "$C/log/sed"; e=$(date +%s)
  printf 'state_version=1\nowner_pid=999999\nowner_lstart=gone\nstarted_epoch=%s\ndeadline_epoch=%s\ntrigger=manual\nreason=x\nphase=restarting\nvariant=B\n' \
    $((e - 7200)) $((e - 3600)) > "$FSG_STATE_DIR/drain/pending"
  eq "$(PATH="$C/log:$PATH" hook bash PreToolUse)" "" "a drain past its deadline: silent"
  eq "$(cat "$C/log/calls" 2>/dev/null)" "" "and neither ps nor sed ran"
  printf 'state_version=1\nowner_pid=0\nstarted_epoch=%s\nhold_until_epoch=%s\ntrigger=manual\nreason=x\nphase=held-docker-not-restored\nvariant=B\n' \
    $((e - 7200)) $((e - 3600)) > "$FSG_STATE_DIR/drain/pending"
  eq "$(PATH="$C/log:$PATH" hook bash PreToolUse)" "" "a hold past its end: silent"
  eq "$(cat "$C/log/calls" 2>/dev/null)" "" "and neither ps nor sed ran"
  echo "$((e - 5)) healed manual B 60 /x" > "$FSG_STATE_DIR/last-heal"
  has "$(hook_ctx "$(hook bash PostToolUse)")" "and ended: fseventsd restarted" "a heal that just ended is still told"

  t "claude-hook bash: a real heal, as the agent runs it"
  docker_default; install_fake; mem 3G
  bg "$G" run --label first -- sleep 4; sleep 1
  heal_bg() { "$G" heal --docker-variant A > "$C/heal-bg.out" 2>&1; }
  bg heal_bg; hp=$LAST_BG
  waitfor 20 grep -qs '^phase=draining' "$FSG_STATE_DIR/drain/pending" || bad "the agent's heal drains"
  has "$(hook_ctx "$(hook bash PreToolUse s1)")" "(trigger manual; Docker step A: it stops the running containers" "the notice names the heal's own step"
  wait "$hp"; eq $? 0 "healed"; agent_wait
  x=$(hook_ctx "$(hook bash PostToolUse s1)")
  has "$x" "(trigger manual; Docker step A" "ended: the step"
  has "$x" "and ended: fseventsd restarted, and Docker and its containers verified." "ended: healed"

  # The hooks run from the plugin's copy, which an update can make newer or older
  # than the agent that wrote the state: what they do not know, they do not tell.
  t "claude-hook bash: silent, exit 0, on a state field it does not know"
  app_copy; bg sleep 120; own=$LAST_BG; n=0
  # quiet WHY: the bash hook prints nothing, on either stream, and exits 0.
  quiet() { n=$((n + 1)); eq "$(hook bash PreToolUse "q$n" 2>&1; echo "rc=$?")" "rc=0" "$1"; }
  # kv KEY [VALUE]: the drain marker with KEY set to VALUE, or without KEY.
  kv() {
    if [ $# -gt 1 ]; then sed "s/^$1=.*/$1=$2/" "$FSG_STATE_DIR/drain/pending" > "$C/kv"
    else sed "/^$1=/d" "$FSG_STATE_DIR/drain/pending" > "$C/kv"; fi
    cat "$C/kv" > "$FSG_STATE_DIR/drain/pending"
  }
  heal_state draining B "$own"; has "$(hook bash PreToolUse q0)" "waiting for runs" "a state it knows is told"
  heal_state draining B "$own"; kv state_version 2; quiet "a newer state version"
  heal_state draining B "$own"; kv state_version; quiet "no state version"
  heal_state draining B "$own"; kv phase preflight; quiet "an unknown phase"
  heal_state draining B "$own"; kv phase; quiet "no phase"
  heal_state restarting B "$own"; kv trigger nightly; quiet "an unknown trigger"
  heal_state restarting B "$own"; kv trigger; quiet "no trigger"
  heal_state restarting D "$own"; quiet "an unknown Docker variant"
  heal_state restarting B "$own"; kv started_epoch soon; quiet "an odd start"
  heal_state restarting B "$own"; kv trigger 'manual wave'; quiet "two words"
  killbg "$own"; rm -f "$FSG_STATE_DIR/drain/pending"
  e=$(date +%s)
  printf 'state_version=2\nowner_pid=999999\nowner_lstart=gone\nstarted_epoch=%s\ntrigger=wave\nvariant=A\naction_ran=0\nhold_s=3600\n' \
    $((e - 30)) > "$FSG_STATE_DIR/docker-intent"
  quiet "an intent of a newer state version"; rm -f "$FSG_STATE_DIR/docker-intent"
  for l in "$e healed-twice manual B 30 /x" "$e healed nightly B 30 /x" "$e healed manual Z 30 /x" \
           "$e healed manual B 3s /x" "$e healed" "$e" "$e  healed manual B 30 /x" "x y z" ""; do
    echo "$l" > "$FSG_STATE_DIR/last-heal"; quiet "last-heal '$l'"
  done
  echo "$e aborted-at-cap wave  30 /x" > "$FSG_STATE_DIR/last-heal"
  x=$(hook_ctx "$(hook bash PostToolUse q99)")
  has "$x" "(trigger wave; its Docker step is not recorded" "a heal that ended before its Docker step was chosen is still told"
  has "$x" "and ended: it gave up at the drain cap" "with its result"

  t "claude-hook bash: stamps are per session, under a safe name, kept a day"
  app_copy; bg sleep 120; own=$LAST_BG; heal_state draining B "$own"
  S=$TMPDIR/fseventsd-guard-hook; mkdir -p "$S"
  : > "$S/old-draining-1"; touch_ago 2d "$S/old-draining-1"; : > "$S/recent-draining-1"
  out=$(hook bash PreToolUse "../../a b"); json_ok "$out"
  absent "$S/old-draining-1" "a stamp older than a day goes"; exists "$S/recent-draining-1" "a recent one stays"
  eq "$(ls -A "$S" | grep -c '^\.\._\.\._a_b-draining-[0-9]*$')" 1 "the session id is reduced to a file name in the stamp dir"
  killbg "$own"
fi

# ======================================================================== claude-hook-wrapper
# The plugin's hooks/fseventsd-guard-hook.sh, which Claude Code runs, its wiring in
# hooks/hooks.json, and the plugin and marketplace manifests.
if ! skip_case claude-hook-wrapper; then
  WRAP=$GUARD_HOME/hooks/fseventsd-guard-hook.sh
  # wrap MODE EVENT [SESSION]: the wrapper as Claude Code runs it, with its stdin JSON.
  wrap() { printf '{"session_id":"%s","hook_event_name":"%s","tool_name":"Bash"}' "${3:-w1}" "$2" | bash "$WRAP" "$1"; echo "rc=$?"; }

  t "the hook wrapper passes the hooks' JSON through on macOS"
  exists "$WRAP" "the wrapper"
  mem 3G; out=$(wrap prompt UserPromptSubmit)
  has "$out" "rc=0" "exit 0"; json_ok "${out%rc=0}"
  has "$(hook_msg "${out%rc=0}")" "fseventsd is running away" "the install nudge, without CLAUDE_PLUGIN_ROOT: the guard next to it"
  rm -rf "$FSG_HINT_DIR"; export CLAUDE_PLUGIN_ROOT="$GUARD_HOME"
  has "$(hook_msg "$(wrap prompt UserPromptSubmit | sed '$d')")" "fseventsd is running away" "the install nudge, from CLAUDE_PLUGIN_ROOT"
  app_copy; bg sleep 120; own=$LAST_BG; heal_state restarting B "$own"
  out=$(wrap bash PostToolUse)
  has "$out" "rc=0" "exit 0"; json_ok "${out%rc=0}"
  has "$(hook_ctx "${out%rc=0}")" "is in its Docker step and fseventsd restart" "the heal notice"
  eq "$(wrap bash PostToolUse)" "rc=0" "nothing the second time"
  killbg "$own"

  t "the hook wrapper exits 0 and prints nothing off macOS, switched off, without the guard, or when the guard fails"
  export CLAUDE_PLUGIN_ROOT="$GUARD_HOME"; mem 3G
  # No app copy yet: on macOS this prompt gets the install nudge (the case above).
  for u in Linux MINGW64_NT-10.0 MSYS_NT-10.0 CYGWIN_NT-10.0; do
    fake_uname "$C/u-$u" "$u"
    eq "$(PATH="$C/u-$u:$PATH" wrap prompt UserPromptSubmit 2>&1)" "rc=0" "$u: prompt"
  done
  app_copy; bg sleep 120; own=$LAST_BG; heal_state restarting B "$own"
  for u in Linux MINGW64_NT-10.0 MSYS_NT-10.0 CYGWIN_NT-10.0; do
    eq "$(PATH="$C/u-$u:$PATH" wrap bash PreToolUse "$u" 2>&1)" "rc=0" "$u: bash"
  done
  for v in 0 off OFF False No; do eq "$(FSG_HINT=$v wrap bash PreToolUse "h$v" 2>&1)" "rc=0" "FSG_HINT=$v: bash"; done
  absent "$TMPDIR/fseventsd-guard-hook" "no heal notice stamped"
  killbg "$own"; rm -rf "$FSG_STATE_DIR/app"
  eq "$(FSG_HINT=0 wrap prompt UserPromptSubmit 2>&1)" "rc=0" "FSG_HINT=0: prompt"
  eq "$(wrap other UserPromptSubmit 2>&1)" "rc=0" "an unknown mode"
  eq "$(wrap '' UserPromptSubmit 2>&1)" "rc=0" "no mode"
  mkdir -p "$C/empty"; export CLAUDE_PLUGIN_ROOT="$C/empty"
  eq "$(wrap prompt UserPromptSubmit 2>&1)" "rc=0" "no guard in the plugin root"
  mkdir -p "$C/broken"
  printf '#!/bin/bash\necho "broken guard" >&2\nexit 3\n' > "$C/broken/fseventsd-guard"
  export CLAUDE_PLUGIN_ROOT="$C/broken"
  eq "$(wrap prompt UserPromptSubmit 2>&1)" "rc=0" "a failing guard: exit 0, nothing printed"
  absent "$FSG_HINT_DIR" "nothing measured in any of these"

  t "the hooks honour FSG_HINT from Claude Code's environment (a settings file's env)"
  # Claude Code exports a settings file's env to its hook processes: here, the
  # hooks.json command run with FSG_HINT in its environment.
  # envrun MODE-EVENT VALUE: that command for EVENT, as Claude Code runs it.
  envrun() {
    local cmd
    cmd=$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["hooks"][sys.argv[2]][0]["hooks"][0]["command"])' "$GUARD_HOME/hooks/hooks.json" "$1")
    printf '{"session_id":"e%s","hook_event_name":"%s","tool_name":"Bash"}' "$2" "$1" |
      env FSG_HINT="$2" CLAUDE_PLUGIN_ROOT="$GUARD_HOME" bash -c "$cmd" 2>&1; echo "rc=$?"
  }
  mem 3G
  for v in 0 no NO off Off false FALSE; do
    eq "$(envrun UserPromptSubmit "$v")" "rc=0" "FSG_HINT=$v: no nudge"
  done
  absent "$FSG_HINT_DIR" "nothing measured"
  has "$(envrun UserPromptSubmit 1)" "fseventsd is running away" "FSG_HINT=1: the nudge"
  app_copy; bg sleep 120; own=$LAST_BG; heal_state restarting B "$own"
  for v in 0 no off False; do
    eq "$(envrun PreToolUse "$v")" "rc=0" "FSG_HINT=$v: no heal notice"
  done
  absent "$TMPDIR/fseventsd-guard-hook" "no heal notice stamped"
  has "$(envrun PostToolUse yes)" "is in its Docker step" "FSG_HINT=yes: the heal notice"
  killbg "$own"

  t "the hook wrapper reads all of its stdin on every path"
  # bigwrap MODE [ARGS]: a PostToolUse JSON larger than a pipe holds, written into the
  # wrapper; prints the writer's and the wrapper's exit codes (141: SIGPIPE).
  bigwrap() {
    { printf '{"session_id":"b1","hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":"'
      head -c 400000 /dev/zero | tr '\0' x; printf '"}'; } | bash "$WRAP" "$1" > /dev/null 2>&1
    echo "${PIPESTATUS[0]} ${PIPESTATUS[1]}"
  }
  eq "$(bigwrap bash)" "0 0" "not installed"
  app_copy
  eq "$(bigwrap bash)" "0 0" "installed, no heal"
  eq "$(FSG_HINT=0 bigwrap bash)" "0 0" "switched off"
  eq "$(bigwrap other)" "0 0" "an unknown mode"
  fake_uname "$C/u-l" Linux; eq "$(PATH="$C/u-l:$PATH" bigwrap bash)" "0 0" "off macOS"
  bg sleep 120; own=$LAST_BG; heal_state restarting B "$own"
  eq "$(bigwrap bash)" "0 0" "with a heal notice"
  killbg "$own"

  t "the plugin's hooks.json runs the wrapper, and the manifests name the plugin"
  # The marketplace sits at the repository root, two levels above the plugin.
  MKT=$REPO/.claude-plugin/marketplace.json
  if [ ! -f "$MKT" ]; then
    skip "no .claude-plugin/marketplace.json: run the suite from a checkout of the whole repository to check it"
    MKT=
  fi
  for f in "$GUARD_HOME/hooks/hooks.json" "$GUARD_HOME/.claude-plugin/plugin.json" ${MKT:+"$MKT"}; do
    /usr/bin/plutil -convert json -o /dev/null "$f" 2>/dev/null && ok || bad "not JSON: $f"
  done
  out=$(/usr/bin/python3 - "$GUARD_HOME" "$MKT" <<'PY'
import json, os, sys
root, mkt = sys.argv[1:]
want = {"UserPromptSubmit": (None, "prompt"), "PreToolUse": ("Bash", "bash"), "PostToolUse": ("Bash", "bash")}
hooks = json.load(open(os.path.join(root, "hooks/hooks.json")))["hooks"]
if sorted(hooks) != sorted(want):
    print("events: %s, want %s (no SessionStart: the prompt nudge covers it)" % (sorted(hooks), sorted(want)))
for ev, (matcher, mode) in want.items():
    hs = [(e.get("matcher"), h) for e in hooks.get(ev, []) for h in e["hooks"]]
    if len(hs) != 1:
        print("%s: %d handlers, want 1" % (ev, len(hs))); continue
    m, h = hs[0]
    wrapper = "${CLAUDE_PLUGIN_ROOT}/hooks/fseventsd-guard-hook.sh"
    cmd = '[ "$(uname -s 2>/dev/null)" = Darwin ] && [ -f "%s" ] || exit 0; bash "%s" %s' % (wrapper, wrapper, mode)
    if (m, h.get("type"), h.get("command"), h.get("shell"), h.get("timeout")) != (matcher, "command", cmd, "bash", 10):
        print("%s: %r, want matcher %r, command %r, shell bash, timeout 10" % (ev, (m, h), matcher, cmd))
    path = wrapper.replace("${CLAUDE_PLUGIN_ROOT}", root)
    if not (os.path.isfile(path) and os.access(path, os.X_OK)):
        print("%s: %s is not an executable file" % (ev, path))
p = json.load(open(os.path.join(root, ".claude-plugin/plugin.json")))
for k, v in (("name", "fseventsd-guard"), ("license", "MIT"),
             ("repository", "https://github.com/RuslanTar/fseventsd-guard")):
    if p.get(k) != v:
        print("plugin.json %s: %r, want %r" % (k, p.get(k), v))
# No version anywhere: Claude Code then versions the plugin by the commit of main.
if "version" in p:
    print("plugin.json has a version: users would stay on it until it is bumped")
if mkt:
    m = json.load(open(mkt))
    es = [e for e in m.get("plugins", []) if e.get("name") == "fseventsd-guard"]
    if m.get("name") != "fseventsd-guard":
        print("marketplace name: %r" % m.get("name"))
    if len(es) != 1 or es[0].get("source") != "./plugins/fseventsd-guard":
        print("marketplace entry: %r" % es)
    elif "version" in es[0]:
        print("marketplace entry has a version: users would stay on it until it is bumped")
    elif not os.path.isfile(os.path.join(os.path.dirname(os.path.dirname(mkt)), "plugins/fseventsd-guard/.claude-plugin/plugin.json")):
        print("marketplace entry source has no plugin.json")
PY
)
  eq "$out" "" "hooks.json and the manifests"

  t "the hooks.json commands are silent off macOS even from a CRLF checkout, and when the plugin dir is gone"
  # hcmd ROOT EVENT: the command hooks.json under ROOT gives for EVENT.
  hcmd() { /usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["hooks"][sys.argv[2]][0]["hooks"][0]["command"])' "$1/hooks/hooks.json" "$2"; }
  # hrun ROOT EVENT: that command as Claude Code runs it (shell bash), with its stdin JSON.
  hrun() {
    local cmd; cmd=$(hcmd "$1" "$2") || { echo "no command"; return; }
    printf '{"session_id":"h1","hook_event_name":"%s","tool_name":"Bash"}' "$2" | CLAUDE_PLUGIN_ROOT="$1" bash -c "$cmd"; echo "rc=$?"
  }
  # The repository forces LF, so a Windows checkout (core.autocrlf=true) gets none.
  if [ -f "$REPO/.gitattributes" ]; then
    eq "$(GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$REPO" check-attr eol -- plugins/fseventsd-guard/hooks/fseventsd-guard-hook.sh \
      plugins/fseventsd-guard/hooks/hooks.json plugins/fseventsd-guard/fseventsd-guard plugins/fseventsd-guard/lib/hint.sh | grep -c ': eol: lf$')" 4 \
      "the hook files check out with LF"
  else
    skip "no .gitattributes: run the suite from a checkout of the whole repository to check the LF rule"
  fi
  mem 3G
  has "$(hook_msg "$(hrun "$GUARD_HOME" UserPromptSubmit | sed '$d')")" "fseventsd is running away" "on macOS the command runs the wrapper"
  rm -rf "$FSG_HINT_DIR"
  # A CRLF copy, as a checkout without .gitattributes would get on Windows.
  cp -R "$GUARD_HOME" "$C/crlf"
  find "$C/crlf" -type f ! -path '*/test/*' -exec /usr/bin/perl -pi -e 's/\r?\n/\r\n/' {} +
  grep -q "$(printf '\r')$" "$C/crlf/hooks/fseventsd-guard-hook.sh" && ok || bad "the copy has no CRLF"
  for u in Linux MINGW64_NT-10.0 MSYS_NT-10.0 CYGWIN_NT-10.0; do
    fake_uname "$C/u-$u" "$u"
    for ev in UserPromptSubmit PreToolUse PostToolUse; do
      eq "$(PATH="$C/u-$u:$PATH" hrun "$C/crlf" "$ev" 2>&1)" "rc=0" "$u, CRLF: $ev"
      eq "$(PATH="$C/u-$u:$PATH" hrun "$GUARD_HOME" "$ev" 2>&1)" "rc=0" "$u: $ev"
    done
  done
  # The plugin's cache dir removed under a running session: Claude Code still runs
  # the command it read at start.
  mkdir -p "$C/gone/hooks"; cp "$GUARD_HOME/hooks/hooks.json" "$C/gone/hooks/"
  for ev in UserPromptSubmit PreToolUse; do
    cmd=$(hcmd "$C/gone" "$ev")
    eq "$(printf '{}' | CLAUDE_PLUGIN_ROOT="$C/nothing-here" bash -c "$cmd" 2>&1; echo "rc=$?")" "rc=0" "plugin dir gone: $ev"
  done
  absent "$FSG_HINT_DIR" "nothing measured off macOS or without the plugin"
fi

echo
echo "fseventsd-guard tests: $PASS passed, $FAIL failed ($N cases)"
[ $FAIL -eq 0 ]
