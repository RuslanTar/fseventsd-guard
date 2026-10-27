# shellcheck shell=bash
# fseventsd-guard install / uninstall / doctor.
#
# install asks for sudo exactly once (lib/root-steps.sh). Everything else runs as
# the user. --prefix DIR puts the root-owned parts under a fake root for the test
# suite; a real install never uses it.

FSG_REAL_HELPER=/usr/local/libexec/fseventsd-guard-restart
FSG_REAL_ROOT_STEPS=/usr/local/libexec/fseventsd-guard-root-steps
FSG_REAL_SUDOERS=/etc/sudoers.d/fseventsd-guard
FSG_REAL_ROOT_LOG_DIR=/Library/Logs/fseventsd-guard
FSG_APP_FILES="fseventsd-guard config.defaults lib/common.sh lib/lease.sh lib/measure.sh lib/drain.sh lib/docker.sh lib/request.sh lib/heal.sh lib/install.sh lib/hint.sh lib/restart-helper.sh lib/root-steps.sh probe/fsprobe.swift launchd/agent.plist.template"

fsg_set_prefix() {
  FSG_PREFIX=$1
  FSG_HELPER_PATH="$FSG_PREFIX$FSG_REAL_HELPER"
  FSG_ROOT_STEPS="$FSG_PREFIX$FSG_REAL_ROOT_STEPS"
  FSG_SUDOERS_FILE="$FSG_PREFIX$FSG_REAL_SUDOERS"
  FSG_ROOT_LOG_DIR="$FSG_PREFIX$FSG_REAL_ROOT_LOG_DIR"
}

fsg_safe_path() { case $1 in /*) ;; *) return 1 ;; esac; case $1 in *[!A-Za-z0-9/._-]*) return 1 ;; esac; return 0; }

# A test prefix must be a plain absolute path: it ends up in the sudoers rule and
# in the helper's unquoted settings. It must also be a real separate directory:
# no . or .. components, and it must not resolve to / (which would make the
# "fake" root the real one). The resolved path replaces the given one.
fsg_check_root_paths() {
  [ -z "$FSG_PREFIX" ] && return 0
  fsg_safe_path "$FSG_PREFIX" || fsg_die 64 "--prefix must be an absolute path of letters, digits, / . _ - only"
  case "$FSG_PREFIX/" in */./*|*/../*) fsg_die 64 "--prefix must not contain . or .. components" ;; esac
  local d=$FSG_PREFIX rest="" r
  while [ ! -d "$d" ]; do rest="/$(basename "$d")$rest"; d=$(dirname "$d"); done
  r="$(cd -P "$d" && pwd)$rest"
  while [ "${r%/}" != "$r" ]; do r=${r%/}; done
  [ -n "$r" ] || fsg_die 64 "--prefix resolves to /; a test root must be a separate directory"
  fsg_safe_path "$r" || fsg_die 64 "--prefix resolves to an unsafe path: $r"
  fsg_set_prefix "$r"
}

# The lowest helper settings install renders (the helper raises a lower one to
# them too): the config is user-writable, and these bound what the NOPASSWD rule
# lets any process running as the user do. No floor applies in a trial window.
FSG_HELPER_LEAST_MB=150
FSG_HELPER_LEAST_INTERVAL_S=1800
FSG_TRIAL_LEAST_INTERVAL_S=120

fsg_check_helper_settings() {
  local v
  for v in "$FSG_HELPER_MIN_MB" "$FSG_HELPER_MIN_INTERVAL_S" "$FSG_TRIAL_MIN_MB" "$FSG_TRIAL_MIN_INTERVAL_S"; do
    fsg_is_uint "$v" || fsg_die 64 "helper settings must be whole numbers (got '$v')"
  done
  [ "$FSG_HELPER_MIN_MB" -ge "$FSG_HELPER_LEAST_MB" ] ||
    fsg_die 64 "FSG_HELPER_MIN_MB=$FSG_HELPER_MIN_MB is below $FSG_HELPER_LEAST_MB, the lowest floor the helper takes outside a trial window"
  [ "$FSG_HELPER_MIN_INTERVAL_S" -ge "$FSG_HELPER_LEAST_INTERVAL_S" ] ||
    fsg_die 64 "FSG_HELPER_MIN_INTERVAL_S=$FSG_HELPER_MIN_INTERVAL_S is below $FSG_HELPER_LEAST_INTERVAL_S, the shortest interval the helper takes outside a trial window"
  [ "$FSG_TRIAL_MIN_INTERVAL_S" -ge "$FSG_TRIAL_LEAST_INTERVAL_S" ] ||
    fsg_die 64 "FSG_TRIAL_MIN_INTERVAL_S=$FSG_TRIAL_MIN_INTERVAL_S is below $FSG_TRIAL_LEAST_INTERVAL_S, the shortest interval the helper takes in a trial window"
}

# Writes the rendered helper to OUT. TRIAL_UNTIL is an epoch (0 = no window).
fsg_render_helper() { # out trial_until
  local hist="/System/Volumes/Data/.fseventsd" tools=""
  if [ -n "$FSG_PREFIX" ]; then
    hist="$FSG_PREFIX/.fseventsd"
    # Stand-in tools only for the unprivileged test suite (root-steps refuses them
    # as root too).
    [ "$(id -u)" != 0 ] && tools=${FSG_TEST_HELPER_TOOLS:-}
  fi
  local v
  fsg_check_helper_settings
  fsg_is_uint "$2" || fsg_die 64 "helper settings must be whole numbers (got '$2')"
  for v in "$FSG_ROOT_LOG_DIR" "$hist"; do
    fsg_safe_path "$v" || fsg_die 64 "unsafe path for the helper: $v"
  done
  [ -z "$tools" ] || fsg_safe_path "$tools" || fsg_die 64 "unsafe tools path: $tools"
  awk -v ev="$FSG_ROOT_LOG_DIR" -v hd="$hist" -v mm="$FSG_HELPER_MIN_MB" -v mi="$FSG_HELPER_MIN_INTERVAL_S" \
      -v tu="$2" -v tm="$FSG_TRIAL_MIN_MB" -v ti="$FSG_TRIAL_MIN_INTERVAL_S" -v tools="$tools" '
    /@@SETTINGS-BEGIN@@/ { print; print "EVIDENCE_DIR=" ev; print "HISTORY_DIR=" hd; print "MIN_MB=" mm
      print "MIN_INTERVAL_S=" mi; print "TRIAL_UNTIL=" tu; print "TRIAL_MIN_MB=" tm
      print "TRIAL_MIN_INTERVAL_S=" ti; print "TOOLS=" tools; skip = 1; next }
    /@@SETTINGS-END@@/ { skip = 0 }
    !skip { print }' > "$1" <<EOF
$(fsg_helper_source)
EOF
}

# The helper source to render: the reviewed text the source gate loaded, else the
# checkout's file (doctor compares against the checkout).
fsg_helper_source() {
  if [ -n "${FSG_HELPER_TEXT:-}" ]; then printf '%s\n' "$FSG_HELPER_TEXT"; else cat "$FSG_HOME/lib/restart-helper.sh"; fi
}

# One warning line per helper setting that differs from config.defaults: the user
# config and the environment can set them, and they go into a root-owned file.
fsg_helper_drift() {
  local k v def
  for k in FSG_HELPER_MIN_MB FSG_HELPER_MIN_INTERVAL_S FSG_TRIAL_MIN_MB FSG_TRIAL_MIN_INTERVAL_S; do
    def=$(sed -n "s/^$k=\([0-9]*\)\$/\1/p" "$FSG_HOME/config.defaults" | head -n 1)
    eval "v=\${$k}"
    [ "$v" = "$def" ] ||
      echo "  WARNING: helper setting $k=$v differs from config.defaults ($def); it comes from $FSG_STATE_DIR/config or the environment"
  done
}

fsg_render_sudoers() { # out user
  {
    echo "# fseventsd-guard: lets $2 restart fseventsd through the root-owned helper only,"
    echo "# with no arguments. Installed by fseventsd-guard install."
    echo "# Remove with: fseventsd-guard uninstall"
    echo "$2 ALL=(root) NOPASSWD: $FSG_HELPER_PATH \"\""
  } > "$1"
}

fsg_xml_esc() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }
fsg_sed_esc() { printf '%s' "$1" | sed 's/[\\|&]/\\&/g'; }

# The Docker CLI dir comes from the caller's PATH: install itself runs on the fixed
# one (fsg_fixed_path), which has no Docker.
fsg_agent_path() {
  local p="" d docker
  docker=$(PATH=${FSG_CALLER_PATH:-$PATH}; command -v docker 2>/dev/null) || docker=/usr/local/bin/docker
  for d in "$(dirname "$docker")" /usr/local/bin /opt/homebrew/bin /usr/bin /bin /usr/sbin /sbin; do
    case ":$p:" in *":$d:"*) ;; *) p="${p:+$p:}$d" ;; esac
  done
  echo "$p"
}

# Seconds launchd should wait between SIGTERM and SIGKILL when it stops the agent. A
# heal stopped part way first lets the bounded call the signal cut into finish (the
# root helper, or a docker desktop stop|start|restart), then restores Docker from its
# EXIT trap: docker desktop start (timeout + 10 s), the engine wait (timeout) and
# docker start (timeout), plus the per-container inspects. launchd caps a user
# agent's value at 60 s (macOS 27.0.1; 5 s when unset), so past that minute the
# intent and the next tick recover Docker (docs/DESIGN.md §5.5); doctor shows the
# value launchd uses.
fsg_agent_exit_timeout() {
  local call=$((FSG_DOCKER_TIMEOUT_S + 10))
  [ "$FSG_HELPER_TIMEOUT_S" -gt "$call" ] && call=$FSG_HELPER_TIMEOUT_S
  echo $((3 * FSG_DOCKER_TIMEOUT_S + 180 + call))
}

fsg_render_plist() { # out [template-dir]
  local app="$FSG_STATE_DIR/app" dir=${2:-$FSG_HOME}
  sed -e "s|@LABEL@|$(fsg_sed_esc "$FSG_LABEL")|g" \
      -e "s|@SCRIPT@|$(fsg_sed_esc "$(fsg_xml_esc "$app/fseventsd-guard")")|g" \
      -e "s|@PATH@|$(fsg_sed_esc "$(fsg_xml_esc "$(fsg_agent_path)")")|g" \
      -e "s|@INTERVAL@|$FSG_AGENT_INTERVAL_S|g" \
      -e "s|@EXIT_TIMEOUT@|$(fsg_agent_exit_timeout)|g" \
      -e "s|@AGENT_LOG@|$(fsg_sed_esc "$(fsg_xml_esc "$FSG_AGENT_LOG")")|g" \
      -e "s|@STATE_DIR@|$(fsg_sed_esc "$(fsg_xml_esc "$FSG_STATE_DIR")")|g" \
      -e "s|@USER_LOG@|$(fsg_sed_esc "$(fsg_xml_esc "$FSG_LOG")")|g" \
      "$dir/launchd/agent.plist.template" > "$1"
}

# Launch agents other than this one that run this guard's app copy: an install left
# under another label, whose agent would heal next to this one. One
# "plist<TAB>label" line each.
fsg_other_agents() {
  local p lab want
  want="<string>$(fsg_xml_esc "$FSG_STATE_DIR/app/fseventsd-guard")</string>"
  for p in "$FSG_LAUNCH_AGENTS_DIR"/*.plist; do
    [ -f "$p" ] && [ "$p" != "$FSG_PLIST" ] || continue
    plutil -convert xml1 -o - "$p" 2>/dev/null | grep -qF -e "$want" || continue
    lab=$(plutil -extract Label raw -o - "$p" 2>/dev/null)
    printf '%s\t%s\n' "$p" "${lab:-?}"
  done
}

# The fix for one fsg_other_agents line.
fsg_other_agent_fix() { # plist label
  echo "run that install's own uninstall first (from the checkout it came from), or: launchctl bootout gui/$(id -u)/$2; rm \"$1\""
}

fsg_app_sum() { # dir
  local f
  ( cd "$1" 2>/dev/null || exit 1; for f in $FSG_APP_FILES; do cat "$f" 2>/dev/null || echo "missing:$f"; done ) | shasum -a 256 | awk '{print $1}'
}

# status run from a checkout other than the app copy: what re-running install from
# it would change, the root code (sudo) or only the app copy (no sudo). Nothing when
# both match, or when the guard is not installed.
fsg_status_install_text() {
  local app="$FSG_STATE_DIR/app" a h tu
  [ -x "$app/fseventsd-guard" ] || return 0
  a=$(cd -P "$app" 2>/dev/null && pwd -P); h=$(cd -P "$FSG_HOME" 2>/dev/null && pwd -P)
  [ "$a" != "$h" ] || return 0
  fsg_where
  # A trial window install opened is no change of root code.
  tu=$(fsg_helper_setting TRIAL_UNTIL)
  fsg_is_uint "$tu" || tu=0
  fsg_root_stale 0 1 "$tu"
  if [ -n "$FSG_ROOT_STALE" ]; then
    echo "install: root code changed ($(printf '%s\n' "$FSG_ROOT_STALE" | head -n 1)): $FSG_REDO_HERE; it asks for sudo"
  elif [ "$(fsg_app_sum "$app")" != "$(fsg_app_sum "$FSG_HOME")" ]; then
    if [ "$tu" -gt 0 ]; then
      echo "install: the app copy differs from $FSG_HERE and the root code is unchanged: $FSG_REDO_HERE; it asks for sudo only to end the trial window (pass --trial-hours to keep one)"
    else
      echo "install: the app copy differs from $FSG_HERE and the root code is unchanged: $FSG_REDO_HERE; it needs no sudo"
    fi
  fi
}

# How status and doctor name the copy they run from (FSG_HERE) and the install to
# re-run (FSG_REDO, FSG_REDO_HERE). install refuses the plugin's copy, so from there
# it is a clone, brought up to date first.
fsg_where() {
  if fsg_in_claude_plugins "$FSG_HOME"; then
    FSG_HERE="this plugin copy"; FSG_REDO="run install from a clone (git pull in it first)"; FSG_REDO_HERE=$FSG_REDO
  else
    FSG_HERE="this checkout"; FSG_REDO="re-run install"; FSG_REDO_HERE="re-run install from this checkout"
  fi
}

# The tools on the way to root, by absolute path: PATH holds user-writable dirs
# (/opt/homebrew/bin) where a shim could stand in for sudo or git. Only the
# unprivileged test suite, under a --prefix fake root, may name a dir of stand-ins
# (FSG_TEST_ROOT_TOOLS), as with the helper's TOOLS.
fsg_test_root_tools() {
  [ -n "${FSG_PREFIX:-}" ] && [ -n "${FSG_TEST_ROOT_TOOLS:-}" ] && [ "$(id -u)" != 0 ]
}
fsg_root_tool() { # sudo|git|shasum|visudo
  local p
  case $1 in
    sudo) p=/usr/bin/sudo ;; git) p=/usr/bin/git ;;
    shasum) p=/usr/bin/shasum ;; visudo) p=/usr/sbin/visudo ;;
    *) return 1 ;;
  esac
  if fsg_test_root_tools && [ -x "$FSG_TEST_ROOT_TOOLS/$1" ]; then p=$FSG_TEST_ROOT_TOOLS/$1; fi
  printf '%s\n' "$p"
}

# install, uninstall and doctor run every tool from the system dirs, so a shim for
# awk, sed or id in a user-writable PATH dir cannot change what reaches root or what
# doctor reports. Set at the entry and again once --prefix is parsed: the test
# suite's stand-ins go first only through fsg_test_root_tools.
fsg_fixed_path() {
  PATH=/usr/bin:/bin:/usr/sbin:/sbin
  if fsg_test_root_tools; then PATH=$FSG_TEST_ROOT_TOOLS:$PATH; fi
  export PATH
}

fsg_sha() { "$(fsg_root_tool shasum)" -a 256 "$@" | awk '{print $1}'; }

# install and uninstall run as the user and ask for sudo themselves. As root they
# would write the sudoers rule for root and use root's home for the user side.
fsg_refuse_root() { # action
  [ "$(id -u)" != 0 ] || fsg_die 1 "$1: run it as your user, not with sudo or as root; it asks for sudo itself"
}

# The root-steps text comes only from fsg_source_gate. -k: sudo asks for the
# password even with a cached ticket, and leaves no ticket behind for whatever runs
# next in this terminal.
fsg_root_steps() { # action args...
  [ -n "${FSG_ROOT_TEXT:-}" ] || { fsg_say "internal: the root steps were not loaded through the source gate"; return 1; }
  "$(fsg_root_tool sudo)" -k /bin/sh -c "$FSG_ROOT_TEXT" fsg-root "$@"
}

# The last look before sudo. A password typed by habit is no review, so a terminal
# gets a y/N question; without one, only --yes runs the root steps.
fsg_confirm_root() { # action yes(0|1)
  local ans
  [ "$2" = 1 ] && return 0
  [ -t 0 ] || { fsg_say "$1: stdin is not a terminal; read the lines above and pass --yes to run them as root"; return 1; }
  printf 'Run this as root? [y/N] '
  read -r ans || ans=
  case $ans in y|Y|yes|YES|Yes) return 0 ;; esac
  fsg_say "$1: not confirmed; nothing ran as root"
  return 1
}

# --- Source gate ----------------------------------------------------------------------
# The root-steps text runs as root at install and uninstall, and the helper rendered
# from restart-helper.sh runs as root on every heal. Both live in a checkout that
# agents can write. So the root code must be what was reviewed: the checkout's origin
# must be the repo whose main is trusted (FSG_REVIEWED_ORIGIN), the guard directory
# must have no uncommitted or untracked changes, and its tree at HEAD must equal its
# tree at FSG_REVIEWED_REF (origin/main). The texts and the app copy are then read
# from that git tree object, which cannot change after the check. --allow-unreviewed
# skips the checks (and uses the working tree); either way the commit, the guard's
# git tree id and the hashes are printed before the sudo prompt so the developer can
# check what they authorize. This catches accidental and unreviewed code, not a
# hostile writer with the developer's uid: such a writer can edit this file, .git or
# the shell profile.
# The full name: a local branch or tag named origin/main would win over the short
# one, which the messages use.
FSG_REVIEWED_REF=refs/remotes/origin/main FSG_REVIEWED_NAME=origin/main
FSG_REPO_URL=https://github.com/RuslanTar/fseventsd-guard

# host/path of a git remote URL in lower case, without scheme, user, port, trailing /
# or .git: https://github.com/O/R.git, git@github.com:O/R and
# ssh://git@github.com/O/R all give github.com/o/r.
fsg_origin_key() { # url
  local u=$1 a
  case $u in
    *://*) u=${u#*://}; a=${u%%/*}; a=${a##*@}; u="${a%%:*}/${u#*/}" ;;
    *:*) a=${u%%:*}; case $a in */*) ;; *) u="${a##*@}/${u#*:}" ;; esac ;;
  esac
  while [ "${u%/}" != "$u" ]; do u=${u%/}; done
  u=${u%.git}
  printf '%s\n' "$u" | tr '[:upper:]' '[:lower:]'
}

# 0 when DIR is in Claude Code's plugin directory (the marketplace clone, the plugin
# cache), by whole path segments after symlinks. Claude Code updates that directory
# on its own, so root code and the app copy never come from it.
fsg_in_claude_plugins() { # dir
  local d b
  d=$(cd -P "$1" 2>/dev/null && pwd -P) || return 1
  for b in "${HOME:-}/.claude/plugins" ${CLAUDE_CONFIG_DIR:+"$CLAUDE_CONFIG_DIR/plugins"} ${CLAUDE_CODE_PLUGIN_CACHE_DIR:+"$CLAUDE_CODE_PLUGIN_CACHE_DIR"}; do
    b=$(cd -P "$b" 2>/dev/null && pwd -P) || continue
    case "$d/" in "$b"/*) return 0 ;; esac
  done
  return 1
}

fsg_refuse_plugin_dir() { # action
  fsg_in_claude_plugins "$FSG_HOME" || return 0
  fsg_say "$1: $FSG_HOME is inside Claude Code's plugin directory, which Claude Code updates by itself; root code and the app copy never come from there"
  fsg_die 1 "$1: clone the repo and run $1 from the clone: git clone $FSG_REPO_URL.git ~/fseventsd-guard && ~/fseventsd-guard/plugins/fseventsd-guard/fseventsd-guard $1"
}

# No replace refs: a refs/replace/* entry for a blob changes what cat-file returns
# while the tree ids and git status stay the same.
fsg_git() {
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_REPLACE_OBJECTS=1 \
    "$(fsg_root_tool git)" -c core.fsmonitor=false -C "$@"
}

# The git blob id of TEXT as the gate loaded it, to compare with
# git rev-parse origin/main:plugins/fseventsd-guard/lib/<file> in another clone.
fsg_blob_id() { printf '%s\n' "$1" | fsg_git "$FSG_HOME" hash-object --stdin 2>/dev/null; }

# fsg_source_gate ACTION ALLOW(0|1). Sets FSG_ROOT_TEXT, FSG_HELPER_TEXT and
# FSG_GATE_NOTE, and for reviewed code FSG_GATE_TOP and FSG_GATE_OBJ (the guard's
# tree object, which install copies the app from), or dies (exit 1) before anything
# is changed.
fsg_source_gate() {
  local action=$1 allow=$2 top rel head tree ref_tree dirty st url want why=""
  FSG_ROOT_TEXT=; FSG_HELPER_TEXT=; FSG_GATE_NOTE=; FSG_GATE_TREE=; FSG_GATE_TOP=; FSG_GATE_OBJ=
  fsg_refuse_plugin_dir "$action"
  want=$(fsg_origin_key "${FSG_REVIEWED_ORIGIN:-}")
  top=$(fsg_git "$FSG_HOME" rev-parse --show-toplevel 2>/dev/null)
  if [ -z "$top" ]; then
    why="$FSG_HOME is not a git checkout, so its root code cannot be checked against $FSG_REVIEWED_NAME"
  else
    rel=$(fsg_git "$FSG_HOME" rev-parse --show-prefix 2>/dev/null); rel=${rel%/}
    head=$(fsg_git "$top" rev-parse --verify -q HEAD)
    dirty=$(fsg_git "$top" status --porcelain --untracked-files=all -- "${rel:-.}" 2>/dev/null); st=$?
    tree=$(fsg_git "$top" rev-parse --verify -q "$head:$rel")
    ref_tree=$(fsg_git "$top" rev-parse --verify -q "$FSG_REVIEWED_REF:$rel")
    url=$(fsg_git "$top" remote get-url origin 2>/dev/null)
    FSG_GATE_TREE="${tree:-none} ($rel at ${head:-no commit}; compare: git rev-parse $FSG_REVIEWED_NAME:$rel in another clone)"
    if [ -z "$url" ]; then
      why="$top has no origin remote, so $FSG_REVIEWED_NAME is not the main of the reviewed repo ($want)"
    elif [ -z "$want" ] || [ "$(fsg_origin_key "$url")" != "$want" ]; then
      why="origin of $top is $url, not the reviewed repo ${want:-(FSG_REVIEWED_ORIGIN is empty)} (a fork or an SSH host alias: set FSG_REVIEWED_ORIGIN in $FSG_STATE_DIR/config to the repo whose main you trust)"
    elif [ "$st" != 0 ]; then
      why="git status failed in $top, so uncommitted changes cannot be ruled out"
    elif [ -n "$dirty" ]; then
      FSG_GATE_TREE="${tree:-none} ($rel at HEAD; the working tree that runs differs from it)"
      why="$rel has uncommitted or untracked changes:
$(printf '%s\n' "$dirty" | head -n 10 | sed 's/^/    /')"
    elif [ -z "$ref_tree" ]; then
      why="$FSG_REVIEWED_NAME has no $rel (not merged yet, or fetch first: git -C $top fetch origin main)"
    elif [ "$tree" != "$ref_tree" ]; then
      why="$rel at HEAD ($head) differs from $FSG_REVIEWED_NAME (review: git -C $top diff $FSG_REVIEWED_NAME HEAD -- $rel; or fetch first)"
    fi
  fi
  if [ -n "$why" ]; then
    if [ "$allow" != 1 ]; then
      fsg_say "$action: refusing to run unreviewed code as root: $why"
      fsg_die 1 "$action: commit and merge the change, or read lib/root-steps.sh and lib/restart-helper.sh and pass --allow-unreviewed"
    fi
    FSG_GATE_NOTE="UNREVIEWED (--allow-unreviewed): working tree of $FSG_HOME${head:+ at commit $head}; $why"
    FSG_ROOT_TEXT=$(cat "$FSG_HOME/lib/root-steps.sh") || fsg_die 1 "$action: cannot read lib/root-steps.sh"
    FSG_HELPER_TEXT=$(cat "$FSG_HOME/lib/restart-helper.sh") || fsg_die 1 "$action: cannot read lib/restart-helper.sh"
    return 0
  fi
  FSG_GATE_NOTE="reviewed: commit $head ($(fsg_git "$top" log -1 --format=%s "$head" | cut -c1-80)); $rel matches $FSG_REVIEWED_NAME of $want"
  FSG_ROOT_TEXT=$(fsg_git "$top" cat-file blob "$tree:lib/root-steps.sh") || fsg_die 1 "$action: cannot read root-steps.sh from git"
  FSG_HELPER_TEXT=$(fsg_git "$top" cat-file blob "$tree:lib/restart-helper.sh") || fsg_die 1 "$action: cannot read restart-helper.sh from git"
  FSG_GATE_TOP=$top; FSG_GATE_OBJ=$tree
}

# The root-steps text install would place: the gate's, else this checkout's.
fsg_root_text() {
  if [ -n "${FSG_ROOT_TEXT:-}" ]; then printf '%s\n' "$FSG_ROOT_TEXT"; else printf '%s\n' "$(cat "$FSG_HOME/lib/root-steps.sh")"; fi
}

# Why install has to run its root steps, one reason per line; empty when the root
# files in place are the ones it would place now (from the gate's texts, else this
# checkout's) and doctor passes them. The drop-in is root-only (0440), so its rule is
# proved with sudo -n -l, as doctor does. CONTENT=1 compares the texts only (status).
# COMPARE_TRIAL_UNTIL renders the helper compared with that trial window (status
# passes the installed one, as doctor does). Sets FSG_ROOT_STALE.
fsg_root_stale() { # trial_until [content [compare_trial_until]]
  local tu=$1 content=${2:-0} ctu=${3:-0} want_uid=0 r="" tmp
  FSG_ROOT_STALE=
  [ -n "$FSG_PREFIX" ] && want_uid=$(id -u)
  if [ ! -e "$FSG_HELPER_PATH" ] && [ ! -e "$FSG_SUDOERS_FILE" ]; then
    FSG_ROOT_STALE="nothing is installed as root yet"; return 0
  fi
  if [ -L "$FSG_HELPER_PATH" ] || [ ! -f "$FSG_HELPER_PATH" ]; then
    r="$r
the helper $FSG_HELPER_PATH is missing or not a regular file"
  else
    tmp=$(mktemp "${TMPDIR:-/tmp}/fsg-doctor.XXXXXX")
    if [ "$tu" != 0 ]; then
      r="$r
--trial-hours opens a trial window in the helper"
    elif ! ( fsg_render_helper "$tmp" "$ctu" ) 2>/dev/null; then
      r="$r
this config cannot be rendered into a helper"
    elif ! cmp -s "$tmp" "$FSG_HELPER_PATH"; then
      if [ "$(sed '/@@SETTINGS-BEGIN@@/,/@@SETTINGS-END@@/d' "$tmp")" = "$(sed '/@@SETTINGS-BEGIN@@/,/@@SETTINGS-END@@/d' "$FSG_HELPER_PATH")" ]; then
        r="$r
the helper settings (floor, interval, trial window) differ from the installed helper's"
      else
        r="$r
lib/restart-helper.sh differs from the installed helper"
      fi
    fi
    rm -f "$tmp"
    if [ "$content" = 0 ]; then
      set -- $(fsg_stat "$FSG_HELPER_PATH")
      if [ "${1:-}" != "$want_uid" ] || [ "${3:-}" != 755 ] || [ -n "$(fsg_acl "$FSG_HELPER_PATH")" ]; then
        r="$r
the helper has owner uid ${1:-?}, mode ${3:-?} or an ACL (want uid $want_uid, 0755, none)"
      fi
    fi
  fi
  if [ ! -e "$FSG_ROOT_STEPS" ] && [ ! -L "$FSG_ROOT_STEPS" ]; then
    r="$r
the root-steps copy $FSG_ROOT_STEPS is missing"
  elif [ "$content" = 0 ] && ! fsg_root_steps_copy_ok; then
    r="$r
the root-steps copy cannot be trusted: $FSG_RS_WHY"
  elif ! fsg_root_text | cmp -s - "$FSG_ROOT_STEPS"; then
    r="$r
lib/root-steps.sh differs from the installed root-steps copy"
  fi
  if [ "$content" = 0 ]; then
    if [ -L "$FSG_SUDOERS_FILE" ] || [ ! -f "$FSG_SUDOERS_FILE" ]; then
      r="$r
the sudoers drop-in $FSG_SUDOERS_FILE is missing or not a regular file"
    else
      set -- $(fsg_stat "$FSG_SUDOERS_FILE")
      if [ "${1:-}" != "$want_uid" ] || [ "${3:-}" != 440 ] || [ -n "$(fsg_acl "$FSG_SUDOERS_FILE")" ]; then
        r="$r
the sudoers drop-in has owner uid ${1:-?}, mode ${3:-?} or an ACL (want uid $want_uid, 0440, none)"
      fi
    fi
    [ -d "$FSG_ROOT_LOG_DIR" ] || r="$r
the root log dir $FSG_ROOT_LOG_DIR is missing"
    if [ -z "$r" ] && ! "$(fsg_root_tool sudo)" -n -l "$FSG_HELPER_PATH" >/dev/null 2>&1; then
      r="
sudo -n -l: the rule does not allow the helper without a password"
    fi
  fi
  FSG_ROOT_STALE=${r#?}
}

# 0 when the root-steps copy that install placed may run as root without the gate:
# a regular file of root's, not writable by group or other, with no ACL, in
# directories only root can change (the helper's, as doctor checks them). Otherwise
# FSG_RS_WHY says why not.
fsg_root_steps_copy_ok() {
  local want_uid=0 d uid perm
  [ -n "$FSG_PREFIX" ] && want_uid=$(id -u)
  FSG_RS_WHY=
  if [ -L "$FSG_ROOT_STEPS" ] || [ ! -f "$FSG_ROOT_STEPS" ]; then FSG_RS_WHY="it is not a regular file"; return 1; fi
  set -- $(fsg_stat "$FSG_ROOT_STEPS")
  if [ "${1:-}" != "$want_uid" ] || [ $((0${3:-777} & 022)) -ne 0 ]; then
    FSG_RS_WHY="it has owner uid ${1:-?}, mode ${3:-?} (want uid $want_uid, not writable by group or other)"
    return 1
  fi
  [ -z "$(fsg_acl "$FSG_ROOT_STEPS")" ] || { FSG_RS_WHY="it has an access control list (ls -led)"; return 1; }
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    case $d in outside:*|unresolved:*) FSG_RS_WHY="a directory above it cannot be checked (${d#*:})"; return 1 ;; esac
    set -- $(fsg_stat "$d")
    uid=${1:-}; perm=${3:-777}
    if [ "$uid" != "$want_uid" ] || [ $((0$perm & 022)) -ne 0 ] || [ -n "$(fsg_acl "$d")" ]; then
      FSG_RS_WHY="$d (owner uid $uid, mode $perm$( [ -n "$(fsg_acl "$d")" ] && echo ', an access control list')) lets a non-root user swap it"
      return 1
    fi
  done <<EOF
$(fsg_helper_dirs | awk '!seen[$0]++')
EOF
  return 0
}

fsg_print_root_code() {
  echo "  root code: $FSG_GATE_NOTE"
  echo "  guard tree: ${FSG_GATE_TREE:-none (not a git checkout)}"
  echo "  lib/root-steps.sh blob: $(fsg_blob_id "$FSG_ROOT_TEXT")"
  echo "  lib/restart-helper.sh blob: $(fsg_blob_id "$FSG_HELPER_TEXT")"
  echo "  root-steps text sha256: $(printf '%s\n' "$FSG_ROOT_TEXT" | fsg_sha)"
}

# What the agent's copy of Docker Desktop's File Sharing list holds when read here
# (fsg_shared_dirs_known reads it back): #list and the list, or #default when
# Desktop's default sharing applies. 2 when it cannot be read here either.
fsg_shared_dirs_cache_text() {
  local list rc
  list=$(fsg_desktop_shared_dirs); rc=$?
  case $rc in
    0) echo '#list'; [ -z "$list" ] || printf '%s\n' "$list" ;;
    1) echo '#default' ;;
    *) return 2 ;;
  esac
}

# Replaces the agent's copy with TEXT (a temp file renamed into place); 1 when it
# cannot be written, the old copy kept.
fsg__shared_cache_put() { # text
  { printf '%s\n' "$1" > "$FSG_SHARED_CACHE.new" && mv -f "$FSG_SHARED_CACHE.new" "$FSG_SHARED_CACHE"; } 2>/dev/null && return 0
  rm -f "$FSG_SHARED_CACHE.new"
  return 1
}

# Install runs in a terminal, which macOS lets read Docker Desktop's settings; the
# agent may not, so it gets a copy. One that cannot be read here keeps the old copy.
fsg_shared_dirs_cache_write() {
  local text n
  if ! text=$(fsg_shared_dirs_cache_text); then
    echo "  WARNING: cannot read Docker Desktop's File Sharing list from here (macOS app-data protection refuses this terminal too), so nothing new is cached for the agent; heals may skip the bind-mount check: let this terminal app access other apps' data (macOS asks, or System Settings > Privacy & Security), then run doctor; or set FSG_PROBE_DIR"
    return 0
  fi
  if ! fsg__shared_cache_put "$text"; then
    echo "  WARNING: cannot write $FSG_SHARED_CACHE; heals may skip the bind-mount check"
    return 0
  fi
  [ "$text" = '#default' ] && return 0
  n=$(printf '%s\n' "$text" | sed 1d | grep -c .)
  echo "  Docker Desktop's File Sharing list ($n folder$( [ "$n" = 1 ] || echo s)) cached for the agent, which macOS may keep from reading it"
}

fsg_usage_install() {
  cat <<'EOF'
usage: fseventsd-guard install [--trial-hours N] [--force] [--no-agent] [--no-probe]
                              [--allow-unreviewed] [--yes]
  Run it from a git clone whose origin is the reviewed repo, never from Claude
  Code's plugin directory. Builds the delivery probe, copies the guard to
  ~/Library/Application Support/fseventsd-guard/app, installs the root helper and
  its sudoers rule (one y/N question, one sudo prompt; none when they are
  unchanged) and loads the launchd user agent.
  --trial-hours N  open a time-boxed window (floor 0 MB, 120 s interval) for the
                   Docker trials, N at most 24; it closes by itself
  --force          install on a macOS version outside the affected range
                   (doctor --affected says why)
  --allow-unreviewed  run root code that is not committed, differs from
                   origin/main or comes from another origin (read lib/root-steps.sh
                   and lib/restart-helper.sh first; the commit and hashes are
                   printed before the prompt)
  --yes            skip the "Run this as root?" question (needed without a terminal)

usage: fseventsd-guard uninstall [--keep-logs] [--force] [--allow-unreviewed] [--yes]
  Removes the guard, from a checkout or from anywhere through the installed copy:
    "$HOME/Library/Application Support/fseventsd-guard/app/fseventsd-guard" uninstall
  The root part runs the root-owned copy of the root steps that install placed
  (one sudo prompt, after one y/N question).
  --keep-logs      keep the user and root logs, and move the heal and trial
                   records and the config to
                   ~/Library/Logs/fseventsd-guard-records-<date>-<time>
  --force          go ahead while a heal or drain is in progress, or while an
                   earlier heal left Docker not verified (it prints what Docker
                   needs back first, and leaves Docker as it is)
  --allow-unreviewed  only for an install without that copy: run the root steps
                   from this directory's working tree
  --yes            skip the question (needed without a terminal)

usage: fseventsd-guard doctor [--affected]
EOF
}

fsg_cmd_install() {
  local trial_hours=0 force=0 no_agent=0 no_probe=0 allow=0 yes=0
  while [ $# -gt 0 ]; do
    case $1 in
      --prefix) fsg_set_prefix "${2:-}"; shift ;;
      --trial-hours) trial_hours=${2:-}; shift ;;
      --force) force=1 ;;
      --allow-unreviewed) allow=1 ;;
      --yes) yes=1 ;;
      --no-agent) no_agent=1 ;;
      --no-probe) no_probe=1 ;;
      -h|--help) fsg_usage_install; return 0 ;;
      *) fsg_say "install: unknown option $1"; fsg_usage_install; return 64 ;;
    esac
    shift
  done
  fsg_fixed_path
  fsg_refuse_root install
  [ "$(uname -s)" = Darwin ] || fsg_die 3 "install: macOS only"
  fsg_refuse_plugin_dir install
  fsg_is_uint "$trial_hours" || fsg_die 64 "install: --trial-hours takes whole hours"
  trial_hours=${trial_hours#"${trial_hours%%[!0]*}"}; trial_hours=${trial_hours:-0}
  if [ ${#trial_hours} -gt 2 ] || [ "$trial_hours" -gt "$FSG_TRIAL_MAX_HOURS" ]; then
    fsg_die 64 "install: --trial-hours is at most $FSG_TRIAL_MAX_HOURS (the helper ignores a longer window)"
  fi
  fsg_check_root_paths
  fsg_affected
  if [ "$FSG_AFF" != yes ] && [ $force = 0 ]; then
    # An update of an existing install is not a new suggestion: a macOS update past
    # a fix must not lock the owner out of updating the guard.
    [ -f "$FSG_HELPER_PATH" ] ||
      fsg_die 1 "install: not needed here: $FSG_AFF_WHY. Use --force to install anyway."
    echo "  note: $FSG_AFF_WHY; updating the existing install"
  fi
  local t
  for t in plutil launchctl awk; do
    command -v "$t" >/dev/null 2>&1 || fsg_die 1 "install: '$t' not found"
  done
  for t in sudo shasum visudo; do
    [ -x "$(fsg_root_tool "$t")" ] || fsg_die 1 "install: $(fsg_root_tool "$t") not found"
  done
  if [ $no_probe = 0 ] && ! command -v swiftc >/dev/null 2>&1; then
    fsg_die 1 "install: swiftc not found. Install the Command Line Tools (xcode-select --install), or pass --no-probe to install without the delivery probe."
  fi
  local user
  user=$(id -un)
  case $user in [A-Za-z_]*) ;; *) fsg_die 1 "install: unusual user name '$user'" ;; esac
  case $user in *[!A-Za-z0-9_.-]*) fsg_die 1 "install: unusual user name '$user'" ;; esac
  case $user in *[!A-Z0-9_]*) ;; *) fsg_die 1 "install: user name '$user' reads as ALL or an alias in sudoers" ;; esac
  # Before anything changes: which root code may run, with which settings.
  fsg_source_gate install "$allow"
  fsg_check_helper_settings
  # Reinstalling unloads the agent (launchctl bootout = SIGTERM). Under a running
  # heal that cuts its Docker restore short, so wait for the heal instead.
  if fsg_heal_running; then
    fsg_die 1 "install: a heal is in progress (pid $(fsg__kv "$FSG_STATE_DIR/heal.lock/owner" pid)); reinstalling now would unload the agent under it and could leave Docker stopped. Run install again when it has ended (check: fseventsd-guard leases)."
  fi
  local other p lab
  other=$(fsg_other_agents)
  if [ -n "$other" ]; then
    while IFS="$(printf '\t')" read -r p lab; do
      fsg_say "install: $p (label $lab) also runs $FSG_STATE_DIR/app/fseventsd-guard, so its agent would heal next to this one's ($FSG_LABEL): $(fsg_other_agent_fix "$p" "$lab")"
    done <<EOF
$other
EOF
    fsg_die 1 "install: refusing while another launch agent runs this guard's app copy; nothing was changed"
  fi
  # Root files that already match need no sudo: an update that changes only the
  # app copy or the plist runs as the user.
  local trial_until=0 root=1
  [ "$trial_hours" -gt 0 ] && trial_until=$(( $(fsg_now) + trial_hours * 3600 ))
  fsg_root_stale "$trial_until"
  [ -n "$FSG_ROOT_STALE" ] || root=0
  [ $root = 0 ] || [ $yes = 1 ] || [ -t 0 ] ||
    fsg_die 1 "install: stdin is not a terminal, so nobody can answer \"Run this as root?\"; run it in a terminal, or pass --yes"

  echo "[1/5] user files in $FSG_STATE_DIR"
  mkdir -p "$FSG_STATE_DIR" "$FSG_STATE_DIR/bin" "$FSG_LEASE_DIR" || fsg_die 1 "install: cannot create $FSG_STATE_DIR"
  chmod 0700 "$FSG_STATE_DIR"
  local f new="$FSG_STATE_DIR/app.new" old="$FSG_STATE_DIR/app.old"
  rm -rf "$new" "$old"
  # Reviewed code comes from the tree object the gate checked, so a working file that
  # git status does not show (assume-unchanged, skip-worktree, an edit after the
  # check) never reaches the agent. --allow-unreviewed copies the working tree.
  if [ -n "$FSG_GATE_OBJ" ]; then
    echo "  app copy from git tree $FSG_GATE_OBJ"
  else
    echo "  app copy from the working tree of $FSG_HOME"
  fi
  for f in $FSG_APP_FILES; do
    mkdir -p "$new/$(dirname "$f")"
    if [ -n "$FSG_GATE_OBJ" ]; then
      fsg_git "$FSG_GATE_TOP" cat-file blob "$FSG_GATE_OBJ:$f" > "$new/$f" || { rm -rf "$new"; fsg_die 1 "install: cannot read $f from git"; }
    else
      cp "$FSG_HOME/$f" "$new/$f" || fsg_die 1 "install: cannot copy $f"
    fi
  done
  chmod 0755 "$new/fseventsd-guard"
  # launchd runs this script directly (its #!/bin/bash line), so it must be executable.
  if [ ! -x "$new/fseventsd-guard" ] || [ "$(head -n 1 "$new/fseventsd-guard")" != '#!/bin/bash' ]; then
    rm -rf "$new"
    fsg_die 1 "install: the copied fseventsd-guard script is not an executable #!/bin/bash script; the agent could not run it"
  fi
  [ -d "$FSG_STATE_DIR/app" ] && mv "$FSG_STATE_DIR/app" "$old"
  mv "$new" "$FSG_STATE_DIR/app" || fsg_die 1 "install: cannot place the app copy"
  rm -rf "$old"
  if [ ! -f "$FSG_STATE_DIR/config" ]; then
    {
      echo "# fseventsd-guard user config. Uncomment a line to override the default."
      echo "# Defaults and their meaning: $FSG_STATE_DIR/app/config.defaults"
      sed -n 's/^\(FSG_[A-Z0-9_]*=.*\)/# \1/p' "$FSG_STATE_DIR/app/config.defaults"
    } > "$FSG_STATE_DIR/config"
  fi
  fsg_shared_dirs_cache_write

  echo "[2/5] delivery probe"
  if [ $no_probe = 1 ]; then
    echo "  skipped (--no-probe); stalls are not detected"
  else
    swiftc -O -o "$FSG_PROBE_BIN.new" "$FSG_STATE_DIR/app/probe/fsprobe.swift" || fsg_die 1 "install: swiftc failed to build the probe"
    mv -f "$FSG_PROBE_BIN.new" "$FSG_PROBE_BIN"
    fsg_probe
    echo "  built $FSG_PROBE_BIN; first probe: $P_RESULT${P_LATENCY_MS:+ (${P_LATENCY_MS} ms)}"
  fi

  if [ $root = 0 ]; then
    echo "[3/5] root files: unchanged, nothing to stage"
    echo "[4/5] root helper + sudoers rule: no sudo needed"
    echo "  the installed helper, sudoers drop-in and root-steps copy match this tree and config"
    echo "  root code: $FSG_GATE_NOTE"
  else
    echo "[3/5] stage and validate the root files"
    local tmp
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/fseventsd-guard-install.XXXXXX") || fsg_die 1 "install: mktemp failed"
    fsg_render_helper "$tmp/helper" "$trial_until"
    /bin/sh -n "$tmp/helper" || { rm -rf "$tmp"; fsg_die 1 "install: rendered helper has a syntax error"; }
    fsg_render_sudoers "$tmp/sudoers" "$user"
    "$(fsg_root_tool visudo)" -cf "$tmp/sudoers" >/dev/null || { rm -rf "$tmp"; fsg_die 1 "install: visudo rejected the sudoers drop-in"; }
    # The root-steps text exactly as it runs now (the gate's, or with --allow-unreviewed
    # the working tree's), for the root-owned copy uninstall runs.
    printf '%s\n' "$FSG_ROOT_TEXT" > "$tmp/root-steps"
    /bin/sh -n "$tmp/root-steps" || { rm -rf "$tmp"; fsg_die 1 "install: the root-steps text has a syntax error"; }
    echo "  helper, sudoers drop-in and root-steps copy staged; visudo -cf: parsed OK"

    echo "[4/5] root helper + sudoers rule (one sudo prompt)"
    local test=0 hsha ssha rsha
    [ -n "$FSG_PREFIX" ] && test=1
    hsha=$(fsg_sha "$tmp/helper")
    ssha=$(fsg_sha "$tmp/sudoers")
    rsha=$(fsg_sha "$tmp/root-steps")
    echo "  sudo is needed: $(printf '%s\n' "$FSG_ROOT_STALE" | awk 'NR > 1 { printf "; " } { printf "%s", $0 }')"
    fsg_print_root_code
    echo "  sudoers rule: $(grep -v '^#' "$tmp/sudoers")"
    echo "  root-steps copy: $FSG_ROOT_STEPS (the text above, sha256 $rsha; uninstall runs it, with your password)"
    echo "  rendered helper sha256: $hsha (staged at $tmp/helper)"
    echo "  rendered helper settings: $(sed -n '/@@SETTINGS-BEGIN@@/,/@@SETTINGS-END@@/p' "$tmp/helper" | grep -v '@@' | tr '\n' ' ')"
    fsg_helper_drift
    if [ "$trial_until" -gt 0 ]; then
      echo "  trial window: open until $(date -r "$trial_until" '+%Y-%m-%d %H:%M') ($trial_hours h): floor $FSG_TRIAL_MIN_MB MB, interval ${FSG_TRIAL_MIN_INTERVAL_S}s, even for a healthy daemon"
    else
      echo "  trial window: none"
    fi
    fsg_confirm_root install "$yes" || { rm -rf "$tmp"; exit 1; }
    if ! fsg_root_steps install "$FSG_PREFIX" "$tmp/helper" "$hsha" \
         "$tmp/sudoers" "$ssha" "$test" "$tmp/root-steps" "$rsha"; then
      rm -rf "$tmp"
      fsg_die 1 "install: the root steps failed; the message above says what was rolled back (run: fseventsd-guard doctor)"
    fi
    rm -rf "$tmp"
  fi

  echo "[5/5] launchd user agent $FSG_LABEL"
  if [ $no_agent = 1 ]; then
    echo "  skipped (--no-agent)"
  else
    mkdir -p "$FSG_LAUNCH_AGENTS_DIR"
    fsg_render_plist "$FSG_PLIST.new" "$FSG_STATE_DIR/app"
    plutil -lint "$FSG_PLIST.new" >/dev/null || { rm -f "$FSG_PLIST.new"; fsg_die 1 "install: the rendered plist is invalid"; }
    mv -f "$FSG_PLIST.new" "$FSG_PLIST"
    fsg_agent_disabled && fsg_die 1 "install: $(fsg_agent_disabled_text), then run install again"
    launchctl bootout "gui/$(id -u)/$FSG_LABEL" >/dev/null 2>&1
    launchctl bootstrap "gui/$(id -u)" "$FSG_PLIST" || fsg_die 1 "install: launchctl bootstrap failed (run: fseventsd-guard doctor)"
    echo "  loaded; it checks every $(fsg_dur "$FSG_AGENT_INTERVAL_S")"
  fi
  # The Claude Code install hint's stamps (lib/hint.sh) are moot once installed.
  fsg_uninstall_path_ok "$FSG_HINT_DIR" fseventsd-guard-hint && fsg_hint_stamps_rm
  fsg_log "INSTALL version=$FSG_VERSION prefix=${FSG_PREFIX:-/} trial_until=$trial_until agent=$((1 - no_agent)) probe=$((1 - no_probe)) root=$root"
  echo
  fsg_cmd_doctor
  echo
  echo "To uninstall, from anywhere (no checkout needed):"
  echo "  \"$FSG_STATE_DIR/app/fseventsd-guard\" uninstall"
  return 0
}

# What Docker may still need back after a heal that ended before Docker verified
# (its Docker intent, or the hold a failed restore left), and how to bring it back by
# hand. RELEASE=1 adds the release step for a guard that stays installed.
fsg_uninstall_docker_text() { # release
  local i=$FSG_DOCKER_INTENT v="" names="" ep="" fix=""
  if [ -f "$i" ]; then
    v=$(fsg__kv "$i" variant); names=$(fsg__kv "$i" restore_names); ep=$(fsg__kv "$i" endpoint)
    echo "  the heal of tick pid $(fsg__kv "$i" owner_pid) ($(fsg__kv "$i" trigger), Docker step $v) began its Docker step at $(date -u -r "$(fsg__kv "$i" started_epoch)" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) and $(fsg_intent_owner_alive && echo "is still in it" || echo "ended before Docker verified")"
  fi
  if fsg_drain_hold_active; then
    [ -n "$names" ] || names=$(fsg__kv "$FSG_PENDING" restore_names)
    [ -n "$ep" ] || ep=$(fsg__kv "$FSG_PENDING" endpoint)
    echo "  new test runs are held: $(fsg__kv "$FSG_PENDING" reason)"
  fi
  echo "  Docker step: ${v:-not recorded}; engine: ${ep:-not recorded}; containers to bring back: ${names:-none recorded}"
  case $v in
    A) ;;
    B|C) fix="docker desktop start; " ;;
    *) fix="docker desktop start (if Docker Desktop is not running); " ;;
  esac
  if [ -n "$names" ]; then
    fix="${fix}docker${ep:+ -H $ep} start $names (or: docker compose up -d in the repo that runs them)"
  else
    fix="${fix}docker compose up -d in the repo that runs your containers"
  fi
  echo "  by hand: $fix$( [ "$1" = 1 ] && echo '; then: fseventsd-guard release')"
}

# Before anything is removed: 1 (and why, on stderr) while the guard is in the middle
# of its work. A heal's Docker intent left by a tick that died first gets the agent
# kicked once (kickstart without -k never kills a running tick) and up to two agent
# intervals to restore Docker. With FORCE it only says what going ahead leaves.
fsg_uninstall_check() { # force
  local limit t0 lp
  U_DOCKER_TOLD=0
  lp=$(fsg__kv "$FSG_STATE_DIR/heal.lock/owner" pid)
  if fsg_heal_running || { [ -f "$FSG_DOCKER_INTENT" ] && fsg_intent_owner_alive; }; then
    if [ "$1" = 0 ]; then
      fsg_say "uninstall: a heal is in progress (tick pid ${lp:-$(fsg__kv "$FSG_DOCKER_INTENT" owner_pid)}, phase $(fsg__kv "$FSG_PENDING" phase)); uninstalling now would stop it part way. Wait for it to end (fseventsd-guard status), or pass --force: the agent's tick is then stopped as at logout and restores Docker before it exits."
      return 1
    fi
    echo "uninstall --force: a heal is in progress (tick pid ${lp:-$(fsg__kv "$FSG_DOCKER_INTENT" owner_pid)}); stopping the agent stops it, and its tick restores Docker before it exits"
    if [ -f "$FSG_DOCKER_INTENT" ]; then
      echo "  if it cannot, uninstall leaves Docker as it is; what to bring back then:"
      fsg_uninstall_docker_text 0
    fi
    return 0
  fi
  if [ -f "$FSG_DOCKER_INTENT" ] && [ "$1" = 0 ]; then
    if launchctl print "gui/$(id -u)/$FSG_LABEL" >/dev/null 2>&1 && fsg_req_kick; then
      limit=$((2 * FSG_AGENT_INTERVAL_S))
      echo "uninstall: an earlier heal left Docker not verified; asked the agent to restore it first, waiting up to $(fsg_dur "$limit")"
      t0=$(fsg_now)
      while [ -f "$FSG_DOCKER_INTENT" ] && [ $(( $(fsg_now) - t0 )) -lt "$limit" ]; do fsg_sleep 2; done
      [ -f "$FSG_DOCKER_INTENT" ] && fsg_say "uninstall: the agent did not restore Docker within $(fsg_dur "$limit")"
    else
      fsg_say "uninstall: an earlier heal left Docker not verified, and the agent is not loaded to restore it"
    fi
    # The tick that took the kick may have begun a heal of its own since.
    if fsg_heal_running; then
      fsg_say "uninstall: a heal is in progress (tick pid $(fsg__kv "$FSG_STATE_DIR/heal.lock/owner" pid)); wait for it to end, or pass --force"
      return 1
    fi
  fi
  if [ -f "$FSG_DOCKER_INTENT" ] || fsg_drain_hold_active; then
    if [ "$1" = 0 ]; then
      { echo "fseventsd-guard: uninstall: Docker may still be down after an earlier heal:"
        fsg_uninstall_docker_text 1
        echo "fseventsd-guard: uninstall: refusing, so the guard keeps its record of what to bring back. Recover Docker as above and run uninstall again, or pass --force (removes the guard and leaves Docker as it is)."
      } >&2
      return 1
    fi
    echo "uninstall --force: Docker may still be down after an earlier heal, and uninstall leaves it as it is:"
    fsg_uninstall_docker_text 0
    U_DOCKER_TOLD=1
    return 0
  fi
  if fsg_drain_active; then
    if [ "$1" = 0 ]; then
      fsg_say "uninstall: a drain is in progress (pid $(fsg__kv "$FSG_PENDING" owner_pid), phase $(fsg__kv "$FSG_PENDING" phase): $(fsg__kv "$FSG_PENDING" reason)); wait for it to end (fseventsd-guard leases), or pass --force"
      return 1
    fi
    echo "uninstall --force: a drain is in progress (pid $(fsg__kv "$FSG_PENDING" owner_pid)); stopping the agent ends it"
  fi
  return 0
}

# What of the guard still runs: the agent's tick, a tick run by hand that holds the
# heal lock, the root helper. Empty when nothing does.
fsg_uninstall_live() {
  local p uid=0 out=""
  fsg_tick_running && out="the agent's tick (pid $(fsg__kv "$FSG_STATE_DIR/heartbeat" pid))"
  if fsg_heal_in_progress; then
    p=$(fsg__kv "$FSG_STATE_DIR/heal.lock/owner" pid)
    [ -n "$out" ] && [ "$p" = "$(fsg__kv "$FSG_STATE_DIR/heartbeat" pid)" ] ||
      out="${out:+$out, }a tick that holds the heal lock (pid ${p:-?}; one run by hand ends only by itself or kill)"
  fi
  [ -n "$FSG_PREFIX" ] && uid=$(id -u)
  p=$(pgrep -u "$uid" -f "$FSG_HELPER_PATH" 2>/dev/null | tr '\n' ' ')
  [ -n "$p" ] && out="${out:+$out, }the root helper (pid ${p% })"
  printf '%s' "$out"
}

# After bootout: waits until nothing of the guard runs, so nothing writes into what
# is removed next (a helper still running would make /Library/Logs/fseventsd-guard
# again). launchd SIGKILLs the agent's tick ExitTimeOut seconds after bootout (60 s
# where launchd caps it); the plist's value stays the bound.
fsg_uninstall_wait() {
  local bound t0 w said=-30 what
  bound=$(plutil -extract ExitTimeOut raw -o - "$FSG_PLIST" 2>/dev/null)
  fsg_is_uint "$bound" || bound=$(fsg_agent_exit_timeout)
  bound=$((bound + 10))
  t0=$(fsg_now)
  while what=$(fsg_uninstall_live); [ -n "$what" ]; do
    w=$(( $(fsg_now) - t0 ))
    if [ "$w" -ge "$bound" ] || [ "${U_STOP:-0}" = 1 ]; then U_LIVE=$what; return 1; fi
    if [ $((w - said)) -ge 30 ]; then
      echo "  waiting for $what to end (up to $(fsg_dur "$bound")): a tick stopped in a heal restores Docker before it exits"
      said=$w
    fi
    fsg_sleep 1
  done
  return 0
}

# 0 when PATH is absolute, has no . or .. or empty component, and ends in NAME.
fsg_uninstall_path_ok() { # path name
  case $1 in /*) ;; *) return 1 ;; esac
  case "$1/" in */./*|*/../*|*//*) return 1 ;; esac
  [ "${1##*/}" = "$2" ]
}

# The paths the installed agent uses, read back from its plist: a shell with
# FSG_STATE_DIR or a log path exported must not make uninstall remove another path,
# or miss the agent's. A path that does not end in its own name is left alone and
# listed in U_BAD; U_STATE_OK, U_LOG_OK and U_ALOG_OK say which may go.
fsg_uninstall_paths() {
  local v
  if [ -f "$FSG_PLIST" ]; then
    v=$(plutil -extract EnvironmentVariables.FSG_STATE_DIR raw -o - "$FSG_PLIST" 2>/dev/null) && [ -n "$v" ] && FSG_STATE_DIR=$v
    v=$(plutil -extract EnvironmentVariables.FSG_LOG raw -o - "$FSG_PLIST" 2>/dev/null) && [ -n "$v" ] && FSG_LOG=$v
    v=$(plutil -extract StandardOutPath raw -o - "$FSG_PLIST" 2>/dev/null) && [ -n "$v" ] && FSG_AGENT_LOG=$v
  fi
  FSG_DRAIN_DIR="$FSG_STATE_DIR/drain"; FSG_PENDING="$FSG_DRAIN_DIR/pending"; FSG_LEASE_DIR="$FSG_DRAIN_DIR/leases"
  FSG_DOCKER_INTENT="$FSG_STATE_DIR/docker-intent"; FSG_REQ_DIR="$FSG_STATE_DIR/requests"
  U_BAD=; U_STATE_OK=1; U_LOG_OK=1; U_ALOG_OK=1
  fsg_uninstall_path_ok "$FSG_STATE_DIR" fseventsd-guard || { U_STATE_OK=0; U_BAD="$U_BAD $FSG_STATE_DIR"; }
  fsg_uninstall_path_ok "$FSG_LOG" fseventsd-guard.log || { U_LOG_OK=0; U_BAD="$U_BAD $FSG_LOG"; }
  fsg_uninstall_path_ok "$FSG_AGENT_LOG" fseventsd-guard.agent.log || { U_ALOG_OK=0; U_BAD="$U_BAD $FSG_AGENT_LOG"; }
  # The Claude Code hint's stamps are no part of the install (the hint makes them
  # while the guard is not installed): removed when named as the guard names them,
  # else left alone without failing uninstall.
  U_HINT_OK=1
  fsg_uninstall_path_ok "$FSG_HINT_DIR" fseventsd-guard-hint || U_HINT_OK=0
}

# Temp files of the user's that an interrupted guard command left: install's staging
# dir, doctor's rendered helper, fsg_timeout's flag. Real installs look in /tmp too,
# where they go without TMPDIR. Only those untouched for over an hour: a guard command
# running in another terminal keeps its own.
fsg_uninstall_tmp() {
  local d
  for d in "${TMPDIR:-/tmp}" $( [ -z "$FSG_PREFIX" ] && echo /tmp ); do
    find -H "${d%/}" -maxdepth 1 -user "$(id -u)" -mmin +60 \
      \( -name 'fseventsd-guard-install.*' -o -name 'fsg-doctor.*' -o -name 'fsg-timeout.*' \) 2>/dev/null
  done | awk '!seen[$0]++'
}

# 0 when launchd keeps the agent's label switched off (Login Items), a setting that
# outlives the plist. launchd does not load a label it keeps switched off.
fsg_agent_disabled() {
  launchctl print-disabled "gui/$(id -u)" 2>/dev/null |
    grep -qF -e "\"$FSG_LABEL\" => disabled" -e "\"$FSG_LABEL\" => true"
}

fsg_agent_disabled_text() {
  echo "launchd keeps the agent $FSG_LABEL switched off (Login Items), so it does not load it: switch fseventsd-guard back on in System Settings > General > Login Items & Extensions, or run: launchctl enable gui/$(id -u)/$FSG_LABEL"
}

# The Claude Code install hint's stamps (lib/hint.sh) that exist. Its off switch in
# the same dir is the user's, and stays.
fsg_hint_stamps() {
  local f
  for f in "$FSG_HINT_DIR/checked" "$FSG_HINT_DIR"/last-*; do [ -e "$f" ] && echo "$f"; done
  return 0
}
fsg_hint_stamps_rm() {
  fsg_hint_stamps | while IFS= read -r f; do rm -f "$f"; done
  rmdir "$FSG_HINT_DIR" 2>/dev/null
  return 0
}

# --keep-logs: the heal and trial records and the user config leave the state dir for
# a dated dir next to the user log (~/Library/Logs). Sets U_RECORDS to it (empty
# when there was nothing to keep); 1 when a move failed.
fsg_uninstall_keep_records() {
  local f dst="" any=""
  U_RECORDS=
  for f in heals trials last-heal last-heal-dir daily config; do [ -e "$FSG_STATE_DIR/$f" ] && any=1; done
  [ -n "$any" ] || return 0
  if [ $U_LOG_OK = 1 ]; then dst=$(dirname "$FSG_LOG"); else dst="$HOME/Library/Logs"; fi
  dst="$dst/fseventsd-guard-records-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$dst" || return 1
  U_RECORDS=$dst
  for f in heals trials last-heal last-heal-dir daily config; do
    [ -e "$FSG_STATE_DIR/$f" ] || continue
    mv "$FSG_STATE_DIR/$f" "$dst/" || return 1
  done
}

# A stop between the agent's bootout and the user files: the agent is loaded again,
# so the install is as it was, unless root steps cut short removed part of it
# (PARTIAL; WHY names what went).
fsg_uninstall_abort() { # agent-was-loaded why [partial]
  if [ "$1" = 1 ] && [ -f "$FSG_PLIST" ] && launchctl bootstrap "gui/$(id -u)" "$FSG_PLIST" >/dev/null 2>&1; then
    fsg_say "uninstall: the agent is loaded again"
  fi
  [ -z "${3:-}" ] || fsg_die 1 "uninstall: $2. The rest of the install, your user state and user logs are kept; run uninstall again to finish$( { [ -e "$FSG_SUDOERS_FILE" ] && [ -e "$FSG_HELPER_PATH" ]; } || echo " (until then the agent cannot heal)")"
  fsg_die 1 "uninstall: $2. Nothing else was removed (the user state and logs are kept); run uninstall again"
}

fsg_cmd_uninstall() {
  local keep=0 force=0 allow=0 yes=0 root=0 via=gate loaded=0 test=0 ans
  while [ $# -gt 0 ]; do
    case $1 in
      --prefix) fsg_set_prefix "${2:-}"; shift ;;
      --keep-logs) keep=1 ;;
      --force) force=1 ;;
      --allow-unreviewed) allow=1 ;;
      --yes) yes=1 ;;
      -h|--help) fsg_usage_install; return 0 ;;
      *) fsg_say "uninstall: unknown option $1"; return 64 ;;
    esac
    shift
  done
  fsg_fixed_path
  fsg_refuse_root uninstall
  fsg_check_root_paths
  fsg_uninstall_paths
  [ -n "$FSG_PREFIX" ] && test=1
  [ $yes = 1 ] || [ -t 0 ] ||
    fsg_die 1 "uninstall: stdin is not a terminal, so nobody can answer its question; run it in a terminal, or pass --yes"
  if [ -e "$FSG_HELPER_PATH" ] || [ -e "$FSG_SUDOERS_FILE" ] || [ -d "$FSG_ROOT_LOG_DIR" ] || [ -e "$FSG_ROOT_STEPS" ]; then
    root=1
    # The copy is the text install ran as root (gate-checked, unless that install
    # used --allow-unreviewed), and only root can change it since, so it runs without
    # the gate and without this checkout.
    if [ -e "$FSG_ROOT_STEPS" ] || [ -L "$FSG_ROOT_STEPS" ]; then
      if fsg_root_steps_copy_ok; then
        via=copy
      else
        fsg_say "uninstall: not running $FSG_ROOT_STEPS as root: $FSG_RS_WHY; the root steps come from a reviewed checkout instead"
      fi
    else
      fsg_say "uninstall: this install has no root-owned copy of the root steps ($FSG_ROOT_STEPS; installs made before it existed), so they come from a reviewed checkout (or, with --allow-unreviewed, from $FSG_HOME)"
    fi
    [ $via = copy ] || fsg_source_gate uninstall "$allow"
  fi
  fsg_uninstall_check "$force" || exit 1
  launchctl print "gui/$(id -u)/$FSG_LABEL" >/dev/null 2>&1 && loaded=1

  # Everything that goes, then one question: a "no" leaves the install whole.
  echo "uninstall removes:"
  [ $loaded = 1 ] && echo "  launchd agent $FSG_LABEL (loaded: a tick still running is stopped and waited for)"
  [ -e "$FSG_PLIST" ] && echo "  $FSG_PLIST"
  if [ $root = 1 ]; then
    echo "  as root, with one sudo prompt:"
    echo "    $FSG_SUDOERS_FILE (first: the privilege goes before the binary)"
    echo "    $FSG_HELPER_PATH"
    echo "    $FSG_ROOT_STEPS"
    [ $keep = 1 ] || echo "    $FSG_ROOT_LOG_DIR (root logs)"
    echo "    each directory an install created, once it is empty"
    if [ $via = copy ]; then
      echo "  root steps: $FSG_ROOT_STEPS (the root-owned copy install placed)"
      echo "  root-steps sha256: $(fsg_sha "$FSG_ROOT_STEPS") (install printed it as the root-steps text sha256)"
    else
      fsg_print_root_code
    fi
  fi
  [ $U_STATE_OK = 1 ] && echo "  $FSG_STATE_DIR (app copy, delivery probe, config, heal and trial records, drain state)"
  [ $U_HINT_OK = 1 ] && [ -n "$(fsg_hint_stamps)" ] && echo "  the Claude Code install hint's stamps in $FSG_HINT_DIR (an off switch there stays)"
  if [ $keep = 0 ]; then
    [ $U_LOG_OK = 1 ] && echo "  $FSG_LOG"
    [ $U_ALOG_OK = 1 ] && echo "  $FSG_AGENT_LOG"
  fi
  local tmps
  tmps=$(fsg_uninstall_tmp)
  [ -n "$tmps" ] && echo "  temp files that interrupted guard commands left:" && printf '%s\n' "$tmps" | sed 's/^/    /'
  if [ $keep = 1 ]; then
    echo "kept (--keep-logs): $FSG_LOG, $FSG_AGENT_LOG$( [ $root = 1 ] && echo ", $FSG_ROOT_LOG_DIR")"
    echo "  the heal and trial records and the config move to $( [ $U_LOG_OK = 1 ] && dirname "$FSG_LOG" || echo "$HOME/Library/Logs")/fseventsd-guard-records-<date>-<time>"
  fi
  [ -n "$U_BAD" ] && echo "not removed: these paths do not end in the guard's own names (the agent's plist or the environment names them):$U_BAD"
  if [ $yes = 0 ]; then
    printf 'Uninstall: remove all of the above? [y/N] '
    read -r ans || ans=
    case $ans in y|Y|yes|YES|Yes) ;; *) fsg_die 1 "uninstall: not confirmed; nothing was removed" ;; esac
  fi

  # Directories earlier installs created (world-readable manifest), checked again
  # after the root steps: one that is still there and empty is a trace.
  local created_dirs
  created_dirs=$(sed -n 's/^created_dir=//p' "$FSG_ROOT_LOG_DIR/install-manifest" 2>/dev/null)
  # From here a Ctrl-C stops at the next step and puts the agent back.
  U_STOP=0
  trap 'U_STOP=1' INT TERM HUP
  echo "[1/4] launchd agent: unload, then wait until nothing of the guard runs"
  launchctl bootout "gui/$(id -u)/$FSG_LABEL" >/dev/null 2>&1
  fsg_uninstall_wait ||
    fsg_uninstall_abort $loaded "$( [ "$U_STOP" = 1 ] && echo "interrupted while waiting for $U_LIVE" || echo "still running after the wait: $U_LIVE (stop it, or wait)")"
  # A heal the bootout stopped (one --force went ahead with, or one that began after
  # the check above) whose restore failed, or that launchd killed, leaves Docker
  # not verified; removing the state dir would lose its record of what to bring back.
  if [ -f "$FSG_DOCKER_INTENT" ] || fsg_drain_hold_active; then
    if [ $force = 0 ]; then
      { echo "fseventsd-guard: uninstall: a heal ended as the agent stopped, and left Docker not verified:"
        fsg_uninstall_docker_text 1
      } >&2
      fsg_uninstall_abort $loaded "refusing to go on, so the guard keeps its record of what to bring back (recover Docker as above)"
    fi
    if [ "$U_DOCKER_TOLD" != 1 ]; then
      echo "uninstall --force: the stopped heal left Docker not verified, and uninstall leaves it as it is:"
      fsg_uninstall_docker_text 0
    fi
  fi
  echo "[2/4] root steps"
  if [ $root = 1 ]; then
    # What they remove, in their order (the drop-in, the helper, the root logs or with
    # --keep-logs the manifest, their copy): a run cut short has removed some of it.
    local rs_had="" rs_gone="" p
    for p in "$FSG_SUDOERS_FILE" "$FSG_HELPER_PATH" "$( [ $keep = 1 ] && echo "$FSG_ROOT_LOG_DIR/install-manifest" || echo "$FSG_ROOT_LOG_DIR")" "$FSG_ROOT_STEPS"; do
      { [ -e "$p" ] || [ -L "$p" ]; } && rs_had="$rs_had $p"
    done
    if [ $via = copy ]; then
      "$(fsg_root_tool sudo)" -k /bin/sh "$FSG_ROOT_STEPS" uninstall "$FSG_PREFIX" "$keep" "$test"
    else
      fsg_root_steps uninstall "$FSG_PREFIX" "$keep" "$test"
    fi || {
      for p in $rs_had; do [ -e "$p" ] || [ -L "$p" ] || rs_gone="$rs_gone $p"; done
      [ -z "$rs_gone" ] || fsg_uninstall_abort $loaded "the root steps stopped part way, after they removed:$rs_gone" partial
      fsg_uninstall_abort $loaded "the root steps did not run (wrong password, or cancelled) or failed"
    }
  else
    echo "  nothing root-owned installed"
  fi
  echo "[3/4] user files"
  rm -f "$FSG_PLIST" "$FSG_PLIST.new"
  U_RECORDS=
  local rm_state=$U_STATE_OK
  if [ $keep = 1 ] && [ $U_STATE_OK = 1 ] && ! fsg_uninstall_keep_records; then
    rm_state=0
    fsg_say "uninstall: could not move the records to ${U_RECORDS:-a dir next to $FSG_LOG}, so $FSG_STATE_DIR is kept"
  fi
  [ $rm_state = 1 ] && rm -rf "$FSG_STATE_DIR"
  [ $U_HINT_OK = 1 ] && fsg_hint_stamps_rm
  if [ $keep = 0 ]; then
    [ $U_LOG_OK = 1 ] && rm -f "$FSG_LOG" "$FSG_LOG.tmp"
    [ $U_ALOG_OK = 1 ] && rm -f "$FSG_AGENT_LOG"
  fi
  [ -n "$tmps" ] && printf '%s\n' "$tmps" | while IFS= read -r p; do rm -rf "$p"; done
  trap - INT TERM HUP

  echo "[4/4] check"
  local left="" p
  for p in "$FSG_PLIST" "$FSG_HELPER_PATH" "$FSG_SUDOERS_FILE" "$FSG_ROOT_STEPS"; do
    [ -e "$p" ] && left="$left $p"
  done
  [ $U_STATE_OK = 1 ] && [ -e "$FSG_STATE_DIR" ] && left="$left $FSG_STATE_DIR"
  if [ $keep = 0 ]; then
    [ -e "$FSG_ROOT_LOG_DIR" ] && left="$left $FSG_ROOT_LOG_DIR"
    [ $U_LOG_OK = 1 ] && [ -e "$FSG_LOG" ] && left="$left $FSG_LOG"
    [ $U_ALOG_OK = 1 ] && [ -e "$FSG_AGENT_LOG" ] && left="$left $FSG_AGENT_LOG"
  fi
  p=$(fsg_uninstall_tmp | tr '\n' ' '); [ -n "$p" ] && left="$left ${p% }"
  launchctl print "gui/$(id -u)/$FSG_LABEL" >/dev/null 2>&1 && left="$left launchd:$FSG_LABEL"
  # An install left under another label: its agent now runs a missing app copy.
  local oa ol
  while IFS="$(printf '\t')" read -r oa ol; do
    [ -n "$oa" ] || continue
    echo "  $oa (label $ol) runs the removed app copy: $(fsg_other_agent_fix "$oa" "$ol")"
    left="$left $oa"
  done <<EOF
$(fsg_other_agents)
EOF
  local sdir
  sdir=$(dirname "$FSG_SUDOERS_FILE")
  for p in $created_dirs; do
    # sudoers.d (and its parents) stay by design: sudo's #includedir names it.
    case "$sdir/" in "$p"/*) continue ;; esac
    # The root log dir is checked above; with --keep-logs it and its parents stay.
    [ "$p" = "$FSG_ROOT_LOG_DIR" ] && continue
    if [ $keep = 1 ]; then case "$FSG_ROOT_LOG_DIR/" in "$p"/*) continue ;; esac; fi
    [ -d "$p" ] || continue
    if [ -z "$(ls -A "$p" 2>/dev/null)" ]; then left="$left $p"
    else echo "  kept $p: the install created it, but it now holds other files"; fi
  done
  local what="no traces left"
  if fsg_agent_disabled; then
    what="no files left, only the launchd setting named above"
    echo "  launchd still keeps $FSG_LABEL switched off (from Login Items); clear that setting with: launchctl enable gui/$(id -u)/$FSG_LABEL"
  fi
  if [ $keep = 1 ]; then
    echo "kept: $FSG_LOG, $FSG_AGENT_LOG"
    [ -d "$FSG_ROOT_LOG_DIR" ] && echo "kept: $FSG_ROOT_LOG_DIR (root-owned; to remove it later: sudo rm -rf $FSG_ROOT_LOG_DIR)"
    [ -n "$U_RECORDS" ] && [ -d "$U_RECORDS" ] && echo "kept: the heal and trial records and the config, moved to $U_RECORDS"
  fi
  [ -n "$U_BAD" ] && fsg_say "uninstall: not removed, as they do not end in the guard's own names:$U_BAD"
  if [ -n "$left" ]; then
    fsg_say "uninstall: left behind:$left"
    return 1
  fi
  [ -n "$U_BAD" ] && return 1
  echo "uninstalled: $what"
  return 0
}

# --- doctor -------------------------------------------------------------------------
fsg_doc() { # ok|warn|fail|info message
  case $1 in
    ok) printf '  ok    %s\n' "$2" ;;
    info) printf '  info  %s\n' "$2" ;;
    warn) printf '  WARN  %s\n' "$2"; DOC_WARN=$((DOC_WARN + 1)) ;;
    fail) printf '  FAIL  %s\n' "$2"; DOC_FAIL=$((DOC_FAIL + 1)) ;;
  esac
}

fsg_stat() { stat -f '%u %g %Lp' "$1" 2>/dev/null; }
# The ACL entries of a file or dir (ls -le lists them under it), or nothing.
fsg_acl() { ls -led "$1" 2>/dev/null | sed 1d; }

# The dirs whose owner could swap the helper: each existing dir above it (up to the
# prefix in tests) and, since stat does not follow a symlinked one, every physical
# ancestor of where that dir really is (as lib/root-steps.sh checks at install).
# A dir that resolves outside the test prefix prints as "outside:DIR -> PATH".
fsg_helper_dirs() {
  local d p top=""
  [ -n "$FSG_PREFIX" ] && { top=$(cd -P "$FSG_PREFIX" 2>/dev/null && pwd -P) || top=$FSG_PREFIX; }
  d=$(dirname "$FSG_HELPER_PATH")
  while :; do
    if [ -d "$d" ]; then
      echo "$d"
      p=$(CDPATH='' cd -P "$d" 2>/dev/null && pwd -P)
      case "$p/" in
        /) echo "unresolved:$d" ;;
        "$top"/*)
          while :; do
            echo "$p"
            [ "$p" = / ] && break
            [ -n "$top" ] && [ "$p" = "$top" ] && break
            p=$(dirname "$p")
          done ;;
        *) echo "outside:$d -> ${p:-?}" ;;
      esac
    fi
    [ "$d" = / ] && break
    [ -n "$FSG_PREFIX" ] && [ "$d" = "$FSG_PREFIX" ] && break
    d=$(dirname "$d")
  done
}

# Reports the agent's last exit status from `launchctl print` output. A tick exits
# with its level (0-3), an emergency heal's code (4-11, or 14 when it refused to
# stop Docker; docs/DESIGN.md §7) or 130 when a signal stopped it; any other code
# means the job itself failed (126/127: the script could not run).
fsg_doctor_last_exit() { # launchctl-print-output
  local ec sig n res dir
  ec=$(printf '%s\n' "$1" | sed -n 's/^[[:space:]]*last exit code = //p' | head -n 1)
  sig=$(printf '%s\n' "$1" | sed -n 's/^[[:space:]]*last terminating signal = //p' | head -n 1)
  n=${ec%%[!0-9]*}
  if [ -n "$sig" ]; then
    fsg_doc info "launchctl: the agent's last run ended by a signal ($sig)"
  elif [ -z "$n" ]; then
    fsg_doc info "launchctl: the agent's last exit status: ${ec:-not reported}"
  elif [ "$n" -le 3 ]; then
    fsg_doc ok "launchctl: the agent's last tick exited $ec (0 ok, 1 warn, 2 runaway, 3 cannot measure)"
  elif [ "$n" -le 11 ]; then
    fsg_doc info "launchctl: the agent's last tick exited $ec, an emergency heal's exit code (docs/DESIGN.md §7)"
  elif [ "$n" = 14 ]; then
    # last-heal: epoch result trigger variant wall_s record-dir
    res=; dir=
    read -r _ res _ _ _ dir 2>/dev/null < "$FSG_STATE_DIR/last-heal"
    fsg_doc info "launchctl: the agent's last tick exited 14: its heal refused to stop Docker, for data safety (last heal: ${res:-not recorded}${dir:+, record $dir}); see the README, Notifications and what to do: heal refused"
  elif [ "$n" = 130 ]; then
    fsg_doc info "launchctl: the agent's last tick was stopped by a signal (exit 130) and cleaned up after itself"
  else
    fsg_doc warn "launchctl: the agent's last run exited $ec, which no tick returns (126/127: the app copy could not run): see $FSG_AGENT_LOG, then re-run install"
  fi
}

# Reports an exit timeout in `launchctl print` output below the plist's ExitTimeOut:
# launchd caps a user agent's (60 s on macOS 27.0.1).
fsg_doctor_exit_timeout() { # launchctl-print-output
  local got want
  got=$(printf '%s\n' "$1" | sed -n 's/^[[:space:]]*exit timeout = \([0-9][0-9]*\).*/\1/p' | head -n 1)
  want=$(plutil -extract ExitTimeOut raw -o - "$FSG_PLIST" 2>/dev/null)
  fsg_is_uint "$got" && fsg_is_uint "$want" && [ "$got" -lt "$want" ] || return 0
  fsg_doc info "launchctl: launchd gives the agent $got s from SIGTERM to SIGKILL, not the plist's ExitTimeOut of $want s (launchd caps it), so a heal stopped part way (logout, launchctl bootout) can be killed in its Docker restore; its Docker intent stays, and the next tick, once the agent is loaded again (at login, or with launchctl bootstrap), restores Docker; leased runs hold behind the Docker intent meanwhile, for at most FSG_FAILED_HOLD_S (docs/DESIGN.md §5.5)"
}

fsg_cmd_doctor() {
  local affected_only=0
  while [ $# -gt 0 ]; do
    case $1 in
      --prefix) fsg_set_prefix "${2:-}"; shift ;;
      --affected) affected_only=1 ;;
      -h|--help) fsg_usage_install; return 0 ;;
      *) fsg_say "doctor: unknown option $1"; return 64 ;;
    esac
    shift
  done
  fsg_fixed_path
  fsg_affected
  if [ $affected_only = 1 ]; then
    echo "affected: $FSG_AFF - $FSG_AFF_WHY"
    [ -n "$FSG_AFF_NOTE" ] && echo "$FSG_AFF_NOTE"
    case $FSG_AFF in yes) return 0 ;; no) return 1 ;; *) return 3 ;; esac
  fi
  DOC_WARN=0; DOC_FAIL=0
  local want_uid=0 st uid perm d
  [ -n "$FSG_PREFIX" ] && want_uid=$(id -u)
  echo "fseventsd-guard doctor (version $FSG_VERSION)"
  fsg_where
  fsg_doc info "macOS ${FSG_OS_VER:-?} (${FSG_OS_BUILD:-?}): affected=$FSG_AFF - $FSG_AFF_WHY"
  [ -n "$FSG_AFF_NOTE" ] && fsg_doc info "${FSG_AFF_NOTE#info: }"
  if [ "$FSG_AFF" != yes ] && [ -f "$FSG_HELPER_PATH" ]; then
    fsg_doc info "this version is outside the affected range (docs/DESIGN.md §9). Keep the guard if fseventsd still runs away here"
  fi
  local k v def src
  while IFS=$(printf '\037') read -r k v def src; do
    [ -n "$k" ] || continue
    fsg_doc fail "config: $k='$v' ($src) is not a whole number; the guard uses the default $def until you fix it"
  done <<EOF
${FSG_CONFIG_ERRORS:-}
EOF
  while IFS=$(printf '\037') read -r k v; do
    [ -n "$k" ] || continue
    fsg_doc warn "config: line $k of $FSG_STATE_DIR/config is ignored (only KEY=VALUE for a key in config.defaults; it is never run as shell): $v"
  done <<EOF
${FSG_CONFIG_IGNORED:-}
EOF
  local mt
  if [ $(( FSG_MEASURE_TRIES * (FSG_TOP_TIMEOUT_S + FSG_MEASURE_RETRY_S) )) -ge "$FSG_AGENT_INTERVAL_S" ]; then
    mt=$(fsg_measure_tries_max)
    fsg_doc warn "config: FSG_MEASURE_TRIES=$FSG_MEASURE_TRIES tries of FSG_TOP_TIMEOUT_S ($FSG_TOP_TIMEOUT_S s) and FSG_MEASURE_RETRY_S ($FSG_MEASURE_RETRY_S s) take up to $(( FSG_MEASURE_TRIES * (FSG_TOP_TIMEOUT_S + FSG_MEASURE_RETRY_S) )) s, at least the agent interval ($FSG_AGENT_INTERVAL_S s): a check stops after $mt tr$( [ "$mt" = 1 ] && echo y || echo ies), at half the interval"
  fi

  # Root helper.
  if [ -f "$FSG_HELPER_PATH" ]; then
    set -- $(fsg_stat "$FSG_HELPER_PATH")
    if [ "${1:-}" = "$want_uid" ] && [ "${3:-}" = 755 ]; then
      fsg_doc ok "helper $FSG_HELPER_PATH is owned by uid $want_uid, mode 0755"
    else
      fsg_doc fail "helper $FSG_HELPER_PATH has owner uid ${1:-?}, mode ${3:-?} (want uid $want_uid, 0755): re-run install"
    fi
    [ -z "$(fsg_acl "$FSG_HELPER_PATH")" ] ||
      fsg_doc fail "helper $FSG_HELPER_PATH has an access control list (ls -led), which can let a non-root user change it: re-run install"
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      case $d in
        outside:*) fsg_doc fail "${d#outside:} is outside the test prefix: a dir above the helper resolves out of the fake root"; continue ;;
        unresolved:*) fsg_doc fail "${d#unresolved:} cannot be resolved (cd -P failed), so the dirs the helper really sits in are unchecked"; continue ;;
      esac
      set -- $(fsg_stat "$d")
      uid=${1:-}; perm=${3:-777}
      if [ "$uid" != "$want_uid" ] || [ $((0$perm & 022)) -ne 0 ]; then
        fsg_doc fail "$d (owner uid $uid, mode $perm) lets a non-root user swap the helper"
      elif [ -n "$(fsg_acl "$d")" ]; then
        fsg_doc fail "$d has an access control list (ls -led), which can let a non-root user swap the helper: remove it (sudo chmod -N $d)"
      fi
    done <<EOF
$(fsg_helper_dirs | awk '!seen[$0]++')
EOF
    if [ -z "$FSG_PREFIX" ] && [ -n "$(fsg_helper_setting TOOLS)" ]; then
      fsg_doc fail "the installed helper has test tools set (TOOLS=$(fsg_helper_setting TOOLS)): re-run install"
    fi
    local tmp tu err
    tmp=$(mktemp "${TMPDIR:-/tmp}/fsg-doctor.XXXXXX")
    tu=$(fsg_helper_setting TRIAL_UNTIL)
    fsg_is_uint "$tu" || tu=0
    if ! err=$( ( fsg_render_helper "$tmp" "$tu" ) 2>&1 ); then
      fsg_doc fail "this config cannot be rendered into a helper, so install refuses it: ${err#fseventsd-guard: }"
    elif cmp -s "$tmp" "$FSG_HELPER_PATH"; then
      fsg_doc ok "helper matches $FSG_HERE's source and config"
    else
      fsg_doc warn "helper differs from $FSG_HERE's source or config (floor/interval changed?): review the change, then $FSG_REDO; root code changed, so it asks for sudo (it runs only code that matches origin/main)"
    fi
    rm -f "$tmp"
    fsg_helper_limits
    if [ "$FSG_H_TRIAL" = 1 ]; then
      fsg_doc warn "trial window open until $(date -r "$(fsg_helper_setting TRIAL_UNTIL)" '+%Y-%m-%d %H:%M') (floor $FSG_H_MIN_MB MB, interval ${FSG_H_INTERVAL_S}s): until then the helper restarts even a healthy daemon; to close it now, re-run install without --trial-hours"
    elif [ "$FSG_H_TRIAL_IGNORED" = 1 ]; then
      fsg_doc warn "the helper's trial window ends more than $FSG_TRIAL_MAX_HOURS h from now ($(date -r "$(fsg_helper_setting TRIAL_UNTIL)" '+%Y-%m-%d %H:%M')); this helper version ignores it, an older one does not: re-run install"
    else
      fsg_doc info "helper floor $FSG_H_MIN_MB MB, interval ${FSG_H_INTERVAL_S}s"
    fi
  else
    fsg_doc fail "helper $FSG_HELPER_PATH is missing: run install"
  fi
  # uninstall runs this copy as root without the source gate, so it must stay root's
  # (it sits in the helper's directories, checked above).
  if [ -L "$FSG_ROOT_STEPS" ] || { [ -e "$FSG_ROOT_STEPS" ] && [ ! -f "$FSG_ROOT_STEPS" ]; }; then
    fsg_doc fail "root-steps copy $FSG_ROOT_STEPS is not a regular file: re-run install"
  elif [ -f "$FSG_ROOT_STEPS" ]; then
    set -- $(fsg_stat "$FSG_ROOT_STEPS")
    if [ "${1:-}" = "$want_uid" ] && [ "${3:-}" = 755 ] && [ -z "$(fsg_acl "$FSG_ROOT_STEPS")" ]; then
      fsg_doc ok "root-steps copy $FSG_ROOT_STEPS is owned by uid $want_uid, mode 0755, no ACL"
      fsg_root_text | cmp -s - "$FSG_ROOT_STEPS" ||
        fsg_doc warn "root-steps copy $FSG_ROOT_STEPS differs from $FSG_HERE's lib/root-steps.sh: $FSG_REDO; root code changed, so it asks for sudo"
    else
      fsg_doc fail "root-steps copy $FSG_ROOT_STEPS has owner uid ${1:-?}, mode ${3:-?}$( [ -n "$(fsg_acl "$FSG_ROOT_STEPS")" ] && echo ' and an access control list') (want uid $want_uid, 0755, no ACL): re-run install"
    fi
  else
    fsg_doc warn "root-steps copy $FSG_ROOT_STEPS is missing (installed before it existed), so removing the guard needs a clean clone of the repo: re-run install"
  fi

  # Sudoers drop-in. Its content is root-only (0440); sudo -l proves the rule works.
  if [ -e "$FSG_SUDOERS_FILE" ]; then
    set -- $(fsg_stat "$FSG_SUDOERS_FILE")
    if [ "${1:-}" = "$want_uid" ] && [ "${3:-}" = 440 ]; then
      fsg_doc ok "sudoers drop-in $FSG_SUDOERS_FILE is owned by uid $want_uid, mode 0440"
    else
      fsg_doc fail "sudoers drop-in has owner uid ${1:-?}, mode ${3:-?} (want uid $want_uid, 0440): re-run install"
    fi
    [ -z "$(fsg_acl "$FSG_SUDOERS_FILE")" ] ||
      fsg_doc fail "sudoers drop-in $FSG_SUDOERS_FILE has an access control list (ls -led), which can let a non-root user change the rule: re-run install"
    if "$(fsg_root_tool sudo)" -n -l "$FSG_HELPER_PATH" >/dev/null 2>&1; then
      fsg_doc ok "sudo -n -l: you may run the helper without a password"
    else
      fsg_doc fail "sudo -n -l: the rule does not allow the helper without a password: re-run install"
    fi
  else
    fsg_doc fail "sudoers drop-in $FSG_SUDOERS_FILE is missing: run install"
  fi
  if [ -d "$FSG_ROOT_LOG_DIR" ]; then
    set -- $(fsg_stat "$FSG_ROOT_LOG_DIR")
    [ "${1:-}" = "$want_uid" ] && fsg_doc ok "root log dir $FSG_ROOT_LOG_DIR" ||
      fsg_doc warn "root log dir $FSG_ROOT_LOG_DIR is owned by uid ${1:-?}"
  else
    fsg_doc warn "root log dir $FSG_ROOT_LOG_DIR is missing"
  fi

  # User side.
  if [ -f "$FSG_PLIST" ]; then
    plutil -lint "$FSG_PLIST" >/dev/null 2>&1 && fsg_doc ok "agent plist $FSG_PLIST" || fsg_doc fail "agent plist $FSG_PLIST is invalid: re-run install"
    # Older installs ran /bin/bash, which Background Items lists as "bash".
    local prog
    prog=$(plutil -extract ProgramArguments.0 raw -o - "$FSG_PLIST" 2>/dev/null)
    if [ "$prog" != "$FSG_STATE_DIR/app/fseventsd-guard" ]; then
      fsg_doc warn "agent plist runs '${prog:-?}', not $FSG_STATE_DIR/app/fseventsd-guard (Background Items shows it as '$(basename "${prog:-?}")'): re-run install"
    fi
    [ "$(plutil -extract ProcessType raw -o - "$FSG_PLIST" 2>/dev/null)" = Interactive ] ||
      fsg_doc warn "agent plist sets no ProcessType Interactive, so launchd throttles the agent and on a loaded Mac its top sample can miss FSG_TOP_TIMEOUT_S (cannot measure, no heal): re-run install"
    local lc
    if lc=$(launchctl print "gui/$(id -u)/$FSG_LABEL" 2>/dev/null); then
      fsg_doc ok "agent $FSG_LABEL is loaded"
      fsg_doctor_last_exit "$lc"
      fsg_doctor_exit_timeout "$lc"
    elif fsg_agent_disabled; then
      fsg_doc fail "agent $FSG_LABEL is not loaded: $(fsg_agent_disabled_text); launchctl bootstrap gui/$(id -u) \"$FSG_PLIST\""
    else
      fsg_doc fail "agent $FSG_LABEL is not loaded: launchctl bootstrap gui/$(id -u) \"$FSG_PLIST\""
    fi
    fsg_agent_fields
    if [ "$A_STALE" = true ]; then fsg_doc warn "agent heartbeat: $A_TEXT"
    elif [ "$A_LEGACY" = true ]; then fsg_doc warn "agent $A_TEXT"
    elif [ -n "$A_EPOCH" ] && { [ "$A_RESULT" != running ] || [ "$A_RUNNING" = true ]; }; then
      fsg_doc ok "agent heartbeat: $A_TEXT"
    else fsg_doc info "agent heartbeat: $A_TEXT"; fi
  else
    fsg_doc fail "agent plist $FSG_PLIST is missing: run install"
  fi
  if [ -x "$FSG_STATE_DIR/app/fseventsd-guard" ]; then
    if [ "$(fsg_app_sum "$FSG_STATE_DIR/app")" = "$(fsg_app_sum "$FSG_HOME")" ]; then
      fsg_doc ok "installed app copy matches $FSG_HERE"
    else
      fsg_root_stale 0
      if [ -n "$FSG_ROOT_STALE" ]; then
        fsg_doc warn "installed app copy differs from $FSG_HERE ($FSG_HOME): $FSG_REDO to update the agent; it asks for sudo too, as $(printf '%s\n' "$FSG_ROOT_STALE" | head -n 1)"
      else
        fsg_doc warn "installed app copy differs from $FSG_HERE ($FSG_HOME): $FSG_REDO to update the agent; the root code is unchanged, so it needs no sudo"
      fi
    fi
    if [ "${A_INSTALLED:-false}" = true ] && [ "${A_REQUESTS:-false}" != true ] && ! fsg_agent_ready; then
      fsg_doc warn "$FSG_AGENT_WHY; until then heal and trial exit 9"
    fi
  else
    fsg_doc fail "installed app copy $FSG_STATE_DIR/app is missing: run install"
  fi
  if [ -x "$FSG_PROBE_BIN" ]; then
    fsg_probe
    case $P_RESULT in
      ok) fsg_doc ok "delivery probe: event in ${P_LATENCY_MS:-?} ms" ;;
      stalled) fsg_doc warn "delivery probe: stalled ($P_DETAIL) - fseventsd may need a heal" ;;
      *) fsg_doc warn "delivery probe: $P_RESULT ${P_DETAIL:-}" ;;
    esac
  else
    fsg_doc warn "delivery probe not built: stalls are not detected (re-run install with the Command Line Tools)"
  fi
  if [ "$FSG_VERIFY_BIND_MOUNT" = 1 ]; then
    fsg_probe_dir
    [ "$BM_SHARED" = 0 ] &&
      fsg_doc warn "bind-mount probe dir $BM_DIR is not in Docker Desktop's File Sharing list, so heals skip the bind-mount check: set FSG_PROBE_DIR to a dir in a shared folder, or share one in Docker Desktop (Settings > Resources > File sharing)"
    # The agent works from its copy when macOS keeps it from Desktop's file (and
    # checks FSG_PROBE_DIR against it too). This runs where the live one may be
    # readable, so doctor refreshes the copy from it when they differ, or when there
    # is none and sharing is not the default; a live list it cannot read leaves the
    # copy as it is. doctor --affected returns before this and writes nothing.
    local want what
    if want=$(fsg_shared_dirs_cache_text); then
      if { [ -f "$FSG_SHARED_CACHE" ] && [ "$(cat "$FSG_SHARED_CACHE" 2>/dev/null)" != "$want" ]; } ||
         { [ ! -f "$FSG_SHARED_CACHE" ] && [ "$want" != '#default' ]; }; then
        if [ "$want" = '#default' ]; then what="default sharing"
        else what=$(printf '%s\n' "$want" | sed 1d | grep -c .); what="$what folder$( [ "$what" = 1 ] || echo s)"; fi
        if fsg__shared_cache_put "$want"; then
          fsg_doc ok "refreshed the agent's copy of Docker Desktop's File Sharing list ($what), which macOS may keep it from reading"
        else
          fsg_doc warn "cannot write $FSG_SHARED_CACHE, the agent's copy of Docker Desktop's File Sharing list, which is missing or differs from the current list: heals may probe an unshared dir and skip the bind-mount check"
        fi
      fi
    elif [ -z "${FSG_PROBE_DIR:-}" ] && [ "$BM_LIST_SRC" = none ]; then
      fsg_doc warn "Docker Desktop's File Sharing list cannot be read and no copy is cached for the agent, so heals probe $BM_DIR and skip the bind-mount check if Docker Desktop does not share it: let this terminal app access other apps' data (macOS asks, or System Settings > Privacy & Security), then run doctor again; or set FSG_PROBE_DIR"
    fi
  fi
  if fsg_drain_hold_active; then
    fsg_doc warn "test runs are held: $(fsg__kv "$FSG_PENDING" reason). Recover Docker, then: fseventsd-guard release"
  fi
  if [ -f "$FSG_PENDING" ] && ! fsg_drain_active; then
    fsg_doc info "a stale drain file is left from an interrupted heal; runs ignore it, the next heal replaces it"
  fi
  fsg_status_drain_fields
  if [ "$D_INTENT" = 1 ] && [ "$D_I_ALIVE" = true ]; then
    fsg_doc info "$(fsg_status_intent_text | sed 's/^docker: //')"
  elif [ "$D_INTENT" = 1 ]; then
    fsg_doc warn "Docker $(fsg_status_intent_text | sed 's/^docker: //')"
  fi
  if [ -d "$FSG_STATE_DIR/heal.lock" ] && ! fsg_heal_in_progress; then
    fsg_doc info "a stale heal lock is left; the next heal removes it"
  fi
  local dup other="" p lab
  dup=$(fsg_other_agents)
  while IFS="$(printf '\t')" read -r p lab; do
    [ -n "$p" ] || continue
    fsg_doc fail "agent plist $p (label $lab) also runs $FSG_STATE_DIR/app/fseventsd-guard, so two agents heal: $(fsg_other_agent_fix "$p" "$lab")"
  done <<EOF
$dup
EOF
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    printf '%s\n' "$dup" | cut -f1 | grep -qxF -e "$p" || other="$other$p "
  done <<EOF
$(grep -l fseventsd "$FSG_LAUNCH_AGENTS_DIR"/*.plist 2>/dev/null | grep -v "/$FSG_LABEL.plist$")
EOF
  [ -n "$other" ] && fsg_doc info "another fseventsd launch agent is installed: $other(retire it once this guard is installed; README 'Replacing an older watcher')"

  if [ $DOC_FAIL -gt 0 ]; then echo "doctor: $DOC_FAIL failure(s), $DOC_WARN warning(s)"; return 2; fi
  if [ $DOC_WARN -gt 0 ]; then echo "doctor: $DOC_WARN warning(s)"; return 1; fi
  echo "doctor: all checks passed"
  return 0
}
