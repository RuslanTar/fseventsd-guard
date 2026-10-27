# shellcheck shell=bash
# fseventsd-guard shared helpers. Sourced by the fseventsd-guard CLI (bash 3.2).

FSG_VERSION=1.0.0
FSG_STATE_VERSION=1
FSG_LABEL=io.github.ruslantar.fseventsd-guard
# Format of the heal requests (lib/request.sh) between a checkout's `heal`/`trial`
# and the installed agent; callers refuse an agent copy that speaks another.
FSG_REQUEST_PROTOCOL=2
# Longest trial window (install --trial-hours); the helper's TRIAL_MAX_S matches it.
FSG_TRIAL_MAX_HOURS=24

# --- Paths --------------------------------------------------------------------------
# Every path can be redirected for tests. FSG_PREFIX is a fake root for the root-owned
# parts; it is empty in a real install.
fsg_init_paths() {
  FSG_STATE_DIR=${FSG_STATE_DIR:-"$HOME/Library/Application Support/fseventsd-guard"}
  FSG_LOG=${FSG_LOG:-"$HOME/Library/Logs/fseventsd-guard.log"}
  FSG_AGENT_LOG=${FSG_AGENT_LOG:-"$HOME/Library/Logs/fseventsd-guard.agent.log"}
  FSG_LAUNCH_AGENTS_DIR=${FSG_LAUNCH_AGENTS_DIR:-"$HOME/Library/LaunchAgents"}
  # Docker Desktop's user socket: the only endpoint whose engine is Docker Desktop.
  FSG_DESKTOP_SOCKET=${FSG_DESKTOP_SOCKET:-"$HOME/.docker/run/docker.sock"}
  # The root-owned paths follow FSG_PREFIX only: the root steps and the sudoers
  # rule name them literally, so they cannot be redirected one by one.
  FSG_PREFIX=${FSG_PREFIX:-}
  FSG_HELPER_PATH="$FSG_PREFIX/usr/local/libexec/fseventsd-guard-restart"
  FSG_ROOT_STEPS="$FSG_PREFIX/usr/local/libexec/fseventsd-guard-root-steps"
  FSG_SUDOERS_FILE="$FSG_PREFIX/etc/sudoers.d/fseventsd-guard"
  FSG_ROOT_LOG_DIR="$FSG_PREFIX/Library/Logs/fseventsd-guard"
  FSG_PROBE_BIN=${FSG_PROBE_BIN:-"$FSG_STATE_DIR/bin/fsprobe"}
  FSG_PLIST="$FSG_LAUNCH_AGENTS_DIR/$FSG_LABEL.plist"
  FSG_DRAIN_DIR="$FSG_STATE_DIR/drain"
  FSG_PENDING="$FSG_DRAIN_DIR/pending"
  FSG_LEASE_DIR="$FSG_DRAIN_DIR/leases"
  FSG_DOCKER_INTENT="$FSG_STATE_DIR/docker-intent"
  FSG_REQ_DIR="$FSG_STATE_DIR/requests"
  # Docker Desktop's File Sharing list as install read it, for an agent that macOS
  # keeps from reading it (lib/docker.sh fsg_shared_dirs_known).
  FSG_SHARED_CACHE="$FSG_STATE_DIR/desktop-shared-dirs"
  # The Claude Code install hint's stamps (lib/hint.sh): outside the state dir, as
  # they exist while the guard is not installed.
  FSG_HINT_DIR=${FSG_HINT_DIR:-"$HOME/Library/Caches/fseventsd-guard-hint"}
  export FSG_STATE_DIR
}

# --- Config -------------------------------------------------------------------------
# defaults < user config < environment. config.defaults is part of the gated source
# and is sourced. The user config lives outside the repo, so it is only parsed
# (fsg_parse_config), never run: sourced, a function in it replaced the source gate.
fsg_load_config() {
  local v saved=""
  for v in $(compgen -A variable FSG_); do
    eval "_fsg_env_$v=\${$v}"
    saved="$saved $v"
  done
  # shellcheck disable=SC1090,SC1091
  . "$FSG_HOME/config.defaults"
  FSG_CONFIG_ERRORS=; FSG_CONFIG_IGNORED=
  if [ -r "$FSG_STATE_DIR/config" ]; then
    fsg_parse_config "$FSG_STATE_DIR/config" "$saved"
  fi
  for v in $saved; do
    eval "$v=\${_fsg_env_$v}"
    unset "_fsg_env_$v"
  done
  fsg_check_config "$saved"
}

# Applies the KEY=VALUE lines of FILE whose KEY is set in config.defaults and not in
# the environment (which wins anyway). VALUE: digits for a key whose default is a
# number (anything else is a config error, see fsg_check_config); otherwise letters,
# digits and . _ - : / @, plus spaces inside double or single quotes. Blank lines and # comments
# are skipped, also after a value. Every other line is ignored, logged and listed in
# FSG_CONFIG_IGNORED ("line US text" each), which doctor warns about.
fsg_parse_config() { # file names-set-in-the-environment
  local line n=0 k v q def keys re us
  us=$(printf '\037')
  keys=" $(sed -n 's/^\(FSG_[A-Z0-9_]*\)=.*/\1/p' "$FSG_HOME/config.defaults" | tr '\n' ' ') "
  re="^(FSG_[A-Z0-9_]+)=(\"[^\"]*\"|'[^']*'|[^[:space:]\"'#]*)([[:space:]]+#.*)?\$"
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    case $line in ''|'#'*) continue ;; esac
    k=; v=; q=0
    if [[ $line =~ $re ]]; then
      k=${BASH_REMATCH[1]}; v=${BASH_REMATCH[2]}
      case $v in \"*|\'*) q=1; v=${v#?}; v=${v%?} ;; esac
      case $keys in *" $k "*) ;; *) k= ;; esac
    fi
    if [ -n "$k" ]; then
      eval "def=\${$k-}"
      if fsg_is_uint "$def"; then
        if ! fsg_is_uint "$v"; then
          case " $2 " in *" $k "*) ;; *) fsg_config_error "$k" "$v" "$def" "$1" ;; esac
          continue
        fi
      else
        case $v in *[!A-Za-z0-9._:/@\ -]*) k= ;; esac
        [ $q = 1 ] || case $v in *' '*) k= ;; esac
      fi
    fi
    if [ -z "$k" ]; then
      v=$(printf '%s' "$line" | tr -d '\000-\037' | cut -c1-120)
      FSG_CONFIG_IGNORED="$FSG_CONFIG_IGNORED$n$us$v
"
      fsg_log "CONFIG ignored line $n of $1: $v"
      fsg_say "config: ignored line $n of $1 (only KEY=VALUE for a key in config.defaults): $v"
      continue
    fi
    case " $2 " in *" $k "*) continue ;; esac
    printf -v "$k" '%s' "$v"
  done < "$1"
}

# Records a setting that is not a whole number; the caller keeps the default.
fsg_config_error() { # key value default source
  local us v
  us=$(printf '\037')
  v=$(printf '%s' "$2" | tr '\n\037' '  ')
  FSG_CONFIG_ERRORS="$FSG_CONFIG_ERRORS$1$us$v$us$3$us$4
"
  fsg_log "CONFIG $1='$v' from $4 is not a whole number; using the default $3"
  fsg_say "config: $1='$v' ($4) is not a whole number; using the default $3"
}

# Every setting whose default is a whole number must be one (no sign, unit, fraction
# or leading zero). Otherwise each numeric test on it errors and falls through:
# FSG_ACT_MB=2G classed a 17 GB daemon as warn and never healed it. A bad value is
# replaced by its default, logged, and listed in FSG_CONFIG_ERRORS (one
# "key US value US default US source" line each, US = \037), which doctor fails on.
fsg_check_config() { # names-set-in-the-environment
  local line k def v src
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    k=${line%%=*}; def=${line#*=}
    eval "v=\${$k-}"
    if fsg_is_uint "$v"; then case $v in 0?*) ;; *) continue ;; esac; fi
    case " $1 " in *" $k "*) src=environment ;; *) src="$FSG_STATE_DIR/config" ;; esac
    eval "$k=\$def"
    fsg_config_error "$k" "$v" "$def" "$src"
  done <<EOF
$(sed -n 's/^\(FSG_[A-Z0-9_]*=[0-9][0-9]*\)[[:space:]]*$/\1/p' "$FSG_HOME/config.defaults")
EOF
}

# --- Small utilities ----------------------------------------------------------------
fsg_now() { date +%s; }
fsg_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

fsg_is_uint() { case ${1:-x} in *[!0-9]*) return 1 ;; esac; return 0; }

# Human size from MB.
fsg_size() {
  if [ "${1:-0}" -ge 1024 ]; then
    awk -v m="$1" 'BEGIN { printf "%.1f GB", m / 1024 }'
  else
    printf '%s MB' "$1"
  fi
}

fsg_dur() { # seconds -> 3m12s
  local s=${1:-0}
  if [ "$s" -ge 3600 ]; then printf '%dh%02dm' $((s / 3600)) $((s % 3600 / 60))
  elif [ "$s" -ge 60 ]; then printf '%dm%02ds' $((s / 60)) $((s % 60))
  else printf '%ds' "$s"; fi
}

fsg_sleep() { sleep "$1"; }

# JSON string literal for an arbitrary value.
fsg_json_str() {
  printf '"%s"' "$(printf '%s' "$1" | tr '\t\r\n' '   ' | tr -d '\000-\010\013\014\016-\037' |
    sed 's/\\/\\\\/g; s/"/\\"/g')"
}
# JSON number or null.
fsg_json_num() {
  case ${1:-} in
    '' ) printf 'null' ;;
    *[!0-9.-]*) printf 'null' ;;
    *) printf '%s' "$1" ;;
  esac
}

# --- Logging ------------------------------------------------------------------------
fsg_log() {
  local dir
  dir=$(dirname "$FSG_LOG")
  mkdir -p "$dir" 2>/dev/null
  printf '%s %s\n' "$(fsg_iso)" "$*" >> "$FSG_LOG" 2>/dev/null
  if [ -f "$FSG_LOG" ] && [ "$(wc -l < "$FSG_LOG" | tr -d ' ')" -gt 5000 ]; then
    tail -n 3000 "$FSG_LOG" > "$FSG_LOG.tmp" 2>/dev/null && mv -f "$FSG_LOG.tmp" "$FSG_LOG"
  fi
}

fsg_say() { printf 'fseventsd-guard: %s\n' "$*" >&2; }
fsg_die() { local code=$1; shift; fsg_say "$*"; exit "$code"; }

# --- Notifications ------------------------------------------------------------------
# fsg_notify TITLE SUBTITLE MESSAGE
fsg_notify() {
  [ "${FSG_NOTIFY:-1}" = 1 ] || return 0
  local title=$1 sub=$2 msg=$3
  fsg_log "NOTIFY title=\"$title\" subtitle=\"$sub\" message=\"$msg\""
  if command -v terminal-notifier >/dev/null 2>&1; then
    terminal-notifier -title "$title" -subtitle "$sub" -message "$msg" -group fseventsd-guard >/dev/null 2>&1 && return 0
  fi
  local esc_t esc_s esc_m
  esc_t=$(printf '%s' "$title" | sed 's/\\/\\\\/g; s/"/\\"/g')
  esc_s=$(printf '%s' "$sub" | sed 's/\\/\\\\/g; s/"/\\"/g')
  esc_m=$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g')
  osascript -e "display notification \"$esc_m\" with title \"$esc_t\" subtitle \"$esc_s\"" >/dev/null 2>&1 || true
}

# fsg_throttle KEY MINUTES: 0 (and stamps KEY) when no notice for KEY went out in
# the last MINUTES; 1 otherwise. Keeps the agent from repeating a notice every tick.
fsg_throttle() {
  local f="$FSG_STATE_DIR/notice-$1" last now
  now=$(fsg_now)
  last=$(head -n 1 "$f" 2>/dev/null)
  if fsg_is_uint "$last" && [ $((now - last)) -ge 0 ] && [ $((now - last)) -lt $(($2 * 60)) ]; then
    return 1
  fi
  mkdir -p "$FSG_STATE_DIR" 2>/dev/null
  echo "$now" > "$f" 2>/dev/null
  return 0
}

# --- Bounded commands ---------------------------------------------------------------
# fsg_timeout SECONDS CMD...: runs CMD; returns 124 when it had to be killed. The
# watcher polls every second and exits with the command, so it leaves no orphans,
# and its output goes to /dev/null so $(fsg_timeout ...) returns as soon as CMD ends.
# A trapped signal cuts the `wait` short, not CMD: FSG_TO_PID, FSG_TO_WATCH and
# FSG_TO_FLAG name the running call until it returns, so a trap can finish it with
# fsg_timeout_wait.
fsg_timeout() {
  local secs=$1
  shift
  FSG_TO_FLAG=$(mktemp "${TMPDIR:-/tmp}/fsg-timeout.XXXXXX") || return 125
  rm -f "$FSG_TO_FLAG"
  "$@" &
  FSG_TO_PID=$!
  (
    i=0
    while [ "$i" -lt "$secs" ]; do
      sleep 1
      kill -0 "$FSG_TO_PID" 2>/dev/null || exit 0
      i=$((i + 1))
    done
    : > "$FSG_TO_FLAG"
    kill -TERM "$FSG_TO_PID" 2>/dev/null
    sleep 2
    kill -KILL "$FSG_TO_PID" 2>/dev/null
  ) > /dev/null 2>&1 &
  FSG_TO_WATCH=$!
  fsg_timeout_wait
}

# Waits for the running fsg_timeout call (still bounded by its watcher) and returns
# its code, 124 when the watcher had to kill it; 0 when none runs.
fsg_timeout_wait() {
  local rc
  [ -n "${FSG_TO_PID:-}" ] || return 0
  wait "$FSG_TO_PID"
  rc=$?
  kill "$FSG_TO_WATCH" 2>/dev/null
  wait "$FSG_TO_WATCH" 2>/dev/null
  [ -f "$FSG_TO_FLAG" ] && { rm -f "$FSG_TO_FLAG"; rc=124; }
  FSG_TO_PID=; FSG_TO_WATCH=; FSG_TO_FLAG=
  return "$rc"
}

# --- Process identity ---------------------------------------------------------------
# Same pinned TZ and locale as fsg__lstart in lib/lease.sh: the start time is
# compared across processes with different environments.
fsg_lstart() { fsg__lstart "$1"; }

# Pids of this process and its ancestors, one per line.
fsg_ancestors() {
  local p=$$ n=0
  while fsg_is_uint "$p" && [ "$p" -gt 1 ] && [ $n -lt 64 ]; do
    echo "$p"
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    n=$((n + 1))
  done
}

# --- Affected macOS versions --------------------------------------------------------
# 0 when version A >= version B, compared numerically component by component.
fsg_ver_ge() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    na = split(a, x, "."); nb = split(b, y, "."); n = (na > nb) ? na : nb
    for (i = 1; i <= n; i++) { p = x[i] + 0; q = y[i] + 0
      if (p > q) exit 0; if (p < q) exit 1 }
    exit 0 }'
}

# Sets FSG_AFF (yes|no|unknown), FSG_AFF_WHY and FSG_OS_VER / FSG_OS_BUILD, and
# FSG_AFF_NOTE: the info line for a release the range counts as affected that is
# newer than FSG_AFFECTED_REVIEWED, else empty (docs/DESIGN.md §9).
fsg_affected() {
  FSG_OS_VER=; FSG_OS_BUILD=; FSG_AFF_NOTE=
  if [ "$(uname -s)" != Darwin ]; then
    FSG_AFF=no; FSG_AFF_WHY="not macOS"; return 0
  fi
  FSG_OS_VER=$(sw_vers -productVersion 2>/dev/null)
  FSG_OS_BUILD=$(sw_vers -buildVersion 2>/dev/null)
  case ${FSG_AFFECTED:-} in
    yes) FSG_AFF=yes; FSG_AFF_WHY="forced by FSG_AFFECTED=yes"; return 0 ;;
    no) FSG_AFF=no; FSG_AFF_WHY="forced by FSG_AFFECTED=no"; return 0 ;;
  esac
  if [ -z "$FSG_OS_VER" ]; then
    FSG_AFF=unknown; FSG_AFF_WHY="sw_vers gave no version"; return 0
  fi
  local v fixed='' min=${FSG_AFFECTED_MIN:-}
  for v in ${FSG_AFFECTED_FIXED:-}; do
    [ "${v%%.*}" = "${FSG_OS_VER%%.*}" ] && fixed=$v
  done
  if [ -n "$min" ] && ! fsg_ver_ge "$FSG_OS_VER" "$min"; then
    FSG_AFF=no; FSG_AFF_WHY="macOS $FSG_OS_VER is older than $min, the first version the runaway is reported on"; return 0
  fi
  if [ -n "$fixed" ] && fsg_ver_ge "$FSG_OS_VER" "$fixed"; then
    FSG_AFF=no; FSG_AFF_WHY="macOS $FSG_OS_VER has the fix (fixed in $fixed)"; return 0
  fi
  FSG_AFF=yes
  FSG_AFF_WHY="macOS $FSG_OS_VER is in the affected range (from ${min:-any version}, ${fixed:+fixed in $fixed}${fixed:-no fix known for ${FSG_OS_VER%%.*}.x})"
  local rev=${FSG_AFFECTED_REVIEWED:-}
  if [ -n "$rev" ] && ! fsg_ver_ge "$rev" "$FSG_OS_VER"; then
    FSG_AFF_NOTE="info: macOS $FSG_OS_VER is newer than $rev, the newest release the affected range was checked against: it counts as affected until a fix is recorded; report it if Apple names an fseventsd fix"
  fi
}

# --- Installed helper facts -----------------------------------------------------------
# Reads one setting from the installed (world-readable) helper's settings block.
fsg_helper_setting() {
  sed -n "/@@SETTINGS-BEGIN@@/,/@@SETTINGS-END@@/s/^$1=//p" "$FSG_HELPER_PATH" 2>/dev/null | head -n 1
}

# Effective floor and interval of the installed helper, honouring its trial window.
# Sets FSG_H_MIN_MB, FSG_H_INTERVAL_S, FSG_H_TRIAL (1 when the window is open) and
# FSG_H_TRIAL_IGNORED (1 when it ends more than FSG_TRIAL_MAX_HOURS ahead, which the
# helper ignores as its TRIAL_MAX_S does).
fsg_helper_limits() {
  FSG_H_MIN_MB=$(fsg_helper_setting MIN_MB)
  FSG_H_INTERVAL_S=$(fsg_helper_setting MIN_INTERVAL_S)
  FSG_H_TRIAL=0; FSG_H_TRIAL_IGNORED=0
  local until now
  until=$(fsg_helper_setting TRIAL_UNTIL)
  now=$(fsg_now)
  if fsg_is_uint "$until" && [ "$now" -lt "$until" ] && [ $((until - now)) -gt $((FSG_TRIAL_MAX_HOURS * 3600)) ]; then
    FSG_H_TRIAL_IGNORED=1
  elif fsg_is_uint "$until" && [ "$now" -lt "$until" ]; then
    FSG_H_TRIAL=1
    FSG_H_MIN_MB=$(fsg_helper_setting TRIAL_MIN_MB)
    FSG_H_INTERVAL_S=$(fsg_helper_setting TRIAL_MIN_INTERVAL_S)
  fi
  fsg_is_uint "$FSG_H_MIN_MB" || FSG_H_MIN_MB=$FSG_HELPER_MIN_MB
  fsg_is_uint "$FSG_H_INTERVAL_S" || FSG_H_INTERVAL_S=$FSG_HELPER_MIN_INTERVAL_S
}

# Seconds since the helper's last restart, or empty.
fsg_helper_last_age() {
  local last
  last=$(head -n 1 "$FSG_ROOT_LOG_DIR/last-restart" 2>/dev/null)
  fsg_is_uint "$last" || return 0
  echo $(( $(fsg_now) - last ))
}
