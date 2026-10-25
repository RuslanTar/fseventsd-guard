#!/bin/sh
# fseventsd-guard root steps: the only code that runs as root at install/uninstall.
#
# `fseventsd-guard install` passes this file's TEXT to
#   sudo /bin/sh -c "<text>" fsg-root ACTION ARGS...
# so the one sudo prompt runs code that cannot be swapped between the user's
# checks and the root run (the text is in argv, not in a user-writable file).
# Install also places a root-owned copy of that text at
# /usr/local/libexec/fseventsd-guard-root-steps, which `fseventsd-guard uninstall`
# runs as `sudo /bin/sh <copy> uninstall ...` (no sudoers rule: it asks the password).
# The staged helper, sudoers and root-steps files are verified by SHA-256 after
# they are copied into root-owned places, and the drop-in is checked with visudo
# before and after it goes live. A failure once the helper is in place puts back
# the helper, drop-in and root-steps copy that were there before (or removes them),
# so a failed install never leaves a helper without its drop-in.
#
#   install   PREFIX STAGED_HELPER HELPER_SHA STAGED_SUDOERS SUDOERS_SHA TEST [STAGED_ROOT_STEPS ROOT_STEPS_SHA]
#   uninstall PREFIX KEEP_LOGS TEST
#
# PREFIX is empty for a real install. TEST=1 (the test suite's fake root) is
# honoured only unprivileged and with a non-empty PREFIX: it skips the chown
# steps and the uid checks. As root, a PREFIX and a helper rendered with test
# tools are refused outright, so no test hook can produce a real install.

set -u
# Before any command runs: root never resolves a tool through the caller's PATH.
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
unset CDPATH
ACTION=${1:-}
PREFIX=${2:-}

ROLLBACK=0
PPREFIX=
die() {
  echo "fseventsd-guard (root): $*" >&2
  if [ "$ROLLBACK" = 1 ]; then ROLLBACK=0; rollback; fi
  exit 1
}

case $ACTION in
  install) TEST=${7:-0} ;;
  uninstall) TEST=${4:-0} ;;
  *) die "unknown action '$ACTION'" ;;
esac
[ -n "$PREFIX" ] || TEST=0
IS_ROOT=0
[ "$(id -u)" = 0 ] && IS_ROOT=1
if [ "$IS_ROOT" = 1 ]; then
  TEST=0
  [ -z "$PREFIX" ] || die "a test prefix ($PREFIX) is refused when running as root"
elif [ "$TEST" = 1 ]; then
  mkdir -p "$PREFIX" || die "cannot create the test prefix $PREFIX"
  PPREFIX=$(cd -P "$PREFIX" && pwd -P) || die "cannot resolve the test prefix $PREFIX"
  [ "$PPREFIX" != / ] || die "the test prefix resolves to /"
else
  die "must run as root"
fi
umask 022

HELPER_DIR=$PREFIX/usr/local/libexec
HELPER=$HELPER_DIR/fseventsd-guard-restart
RS=$HELPER_DIR/fseventsd-guard-root-steps
SUDOERS_DIR=$PREFIX/etc/sudoers.d
SUDOERS=$SUDOERS_DIR/fseventsd-guard
LOGDIR=$PREFIX/Library/Logs/fseventsd-guard
MANIFEST=$LOGDIR/install-manifest

owner_fix() { # path mode
  [ "$TEST" = 1 ] || chown root:wheel "$1" || return 1
  # An ACL entry inherited from the parent survives chown and a numeric chmod.
  chmod -N "$1" && chmod "$2" "$1"
}

# Every existing directory from DIR up to / (up to PREFIX in tests) must be owned by
# root, not writable by group or other, and carry no ACL entry (one can grant
# add_file or delete_child whatever the mode says); otherwise a user could rename the
# helper's directory and swap the helper. stat does not follow a symlinked
# component (/etc, or a /usr/local pointing elsewhere), so each one is also
# resolved with cd -P and every physical ancestor of the result is checked the
# same way. In tests the physical path must stay inside the physical PREFIX.
check_ancestors() {
  d=$1
  while :; do
    if [ -d "$d" ]; then
      check_dir "$d"
      p=$(cd -P "$d" && pwd -P) || die "cannot resolve $d"
      if [ "$TEST" = 1 ]; then
        case $p/ in "$PPREFIX"/*) ;; *) die "$d resolves to $p, outside the test prefix $PPREFIX" ;; esac
      fi
      while :; do
        check_dir "$p" "$d"
        [ "$p" = / ] && break
        [ "$TEST" = 1 ] && [ "$p" = "$PPREFIX" ] && break
        p=$(dirname "$p")
      done
    fi
    [ "$d" = / ] && break
    [ "$TEST" = 1 ] && [ "$d" = "$PREFIX" ] && break
    d=$(dirname "$d")
  done
}
check_dir() { # dir [lexical-dir-it-was-reached-from]
  via=; [ -n "${2:-}" ] && [ "$1" != "$2" ] && via=" (the physical path of $2)"
  # shellcheck disable=SC2046  # split "uid mode" into $1 $2 on purpose
  set -- "$1" $(stat -f '%u %Lp' "$1")
  [ $# -eq 3 ] || die "cannot stat $1$via"
  if [ "$TEST" != 1 ] && [ "$2" != 0 ]; then die "$1$via is not owned by root"; fi
  [ $((0$3 & 022)) -eq 0 ] || die "$1$via is writable by group or other (mode $3)"
  [ -z "$(ls -led "$1" | sed 1d)" ] || die "$1$via has an access control list (see: ls -led $1); refusing"
}

sha() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; }

# The drop-in may hold one rule only, for the helper path whose directories these
# steps check, and for the user who ran sudo (SUDO_USER, set by sudo itself). Only
# "# " lines are comments: #include and #includedir are directives.
check_rule() { # drop-in
  rule=$(grep -v -e '^# ' -e '^#$' -e '^[[:space:]]*$' "$1")
  r_user=${rule%% *}
  case $r_user in ''|*[!A-Za-z0-9._-]*) die "the drop-in's rule has no plain user name; refusing" ;; esac
  # sudoers reads ALL, and any name of capitals, digits and _, as every user or an alias.
  case $r_user in *[!A-Z0-9_]*) ;; *) die "the drop-in's rule names '$r_user', which sudoers reads as ALL or a User_Alias; refusing" ;; esac
  [ "$r_user" = "${SUDO_USER:-}" ] ||
    die "the drop-in's rule is for '$r_user', not for '${SUDO_USER:-}' who ran sudo; refusing"
  [ "$rule" = "$r_user ALL=(root) NOPASSWD: $HELPER \"\"" ] ||
    die "the drop-in must hold one rule for $HELPER only; refusing"
}

# A directory the steps write into. An existing one must already be safe all the
# way up (check_ancestors); it is never chowned or chmod-ed, so a directory that
# was user-writable is refused, not taken over with whatever was planted in it.
# A missing one is created here by root, one level at a time, and recorded.
ensure_dir() { # dir
  if [ "$TEST" = 1 ] && [ "$1" = "$PREFIX" ]; then mkdir -p "$1" || die "cannot create $1"; return 0; fi
  if [ -L "$1" ]; then die "$1 is a symlink; refusing"; fi
  if [ -d "$1" ]; then check_ancestors "$1"; return 0; fi
  if [ -e "$1" ]; then die "$1 exists and is not a directory"; fi
  ensure_dir "$(dirname "$1")"
  mkdir "$1" || die "cannot create $1"
  owner_fix "$1" 0755 || die "cannot set the owner of $1"
  record_dir "$1"
}

# Every created directory goes into the manifest as soon as it exists (once the
# manifest is open), so a later failure or a reinstall never loses track of it.
MANIFEST_OPEN=0
record_dir() { # dir
  created="$created $1"
  if [ "$MANIFEST_OPEN" = 1 ]; then echo "created_dir=$1" >> "$MANIFEST" || die "cannot write $MANIFEST"; fi
}

# The final path of an installed file must be a plain file or absent.
check_target() { # path
  if [ -L "$1" ]; then die "$1 is a symlink; refusing (inspect and remove it, then re-run install)"; fi
  if [ -e "$1" ] && [ ! -f "$1" ]; then die "$1 exists and is not a regular file; refusing"; fi
}

TMP_HELPER=; TMP_SUDOERS=; TMP_MANIFEST=; TMP_RS=; PREV_HELPER=; PREV_SUDOERS=; PREV_RS=; STAGED_RS=
trap 'rm -f "$TMP_HELPER" "$TMP_SUDOERS" "$TMP_MANIFEST" "$TMP_RS" "$PREV_HELPER" "$PREV_SUDOERS" "$PREV_RS"' EXIT
# A signal (Ctrl-C, a closed terminal) rolls back like any other failure.
trap 'die "interrupted by a signal"' INT TERM HUP

# Copies of the helper, drop-in and root-steps copy from an earlier install, taken
# before any is replaced. The temp names contain a dot, so sudo never reads the
# drop-in copy.
save_previous() {
  if [ -f "$HELPER" ]; then
    PREV_HELPER=$(mktemp "$HELPER_DIR/.fseventsd-guard-restart.prev.XXXXXX") || die "cannot create a temp file in $HELPER_DIR"
    cp -p "$HELPER" "$PREV_HELPER" || die "cannot keep a copy of the installed helper"
  fi
  if [ -f "$SUDOERS" ]; then
    PREV_SUDOERS=$(mktemp "$SUDOERS_DIR/fseventsd-guard.prev.XXXXXX") || die "cannot create a temp file in $SUDOERS_DIR"
    cp -p "$SUDOERS" "$PREV_SUDOERS" || die "cannot keep a copy of the installed drop-in"
  fi
  if [ -n "$STAGED_RS" ] && [ -f "$RS" ]; then
    PREV_RS=$(mktemp "$HELPER_DIR/.fseventsd-guard-root-steps.prev.XXXXXX") || die "cannot create a temp file in $HELPER_DIR"
    cp -p "$RS" "$PREV_RS" || die "cannot keep a copy of the installed root steps"
  fi
}

# The drop-in goes first: a helper is inert without it. A copy that cannot be put
# back is kept (the EXIT trap no longer sees it) and named.
rollback() {
  rb_ok=1
  restore "$PREV_SUDOERS" "$SUDOERS" drop-in; PREV_SUDOERS=
  restore "$PREV_HELPER" "$HELPER" helper; PREV_HELPER=
  if [ -n "$STAGED_RS" ]; then restore "$PREV_RS" "$RS" "root-steps copy"; PREV_RS=; fi
  if [ "$rb_ok" = 1 ]; then
    echo "fseventsd-guard (root): rolled back: $HELPER, $SUDOERS and $RS are as they were before this install" >&2
  else
    echo "fseventsd-guard (root): rollback incomplete; see the lines above and run: fseventsd-guard doctor" >&2
  fi
}
restore() { # saved-copy target what
  if [ -n "$1" ]; then
    mv -f "$1" "$2" && return 0
    echo "fseventsd-guard (root): could not put back the previous $3 at $2; it is kept at $1" >&2
  else
    rm -f "$2" && return 0
    echo "fseventsd-guard (root): could not remove the new $3 at $2" >&2
  fi
  rb_ok=0
}

if [ "$ACTION" = install ]; then
  STAGED_HELPER=$3; HELPER_SHA=$4; STAGED_SUDOERS=$5; SUDOERS_SHA=$6
  STAGED_RS=${8:-}; RS_SHA=${9:-}
  # The staged files sit in the user's TMPDIR. Only plain files are copied: a
  # symlink there could point root's cp at a root-only file.
  for f in "$STAGED_HELPER" "$STAGED_SUDOERS" ${STAGED_RS:+"$STAGED_RS"}; do
    if [ -L "$f" ] || [ ! -f "$f" ]; then die "staged file $f is not a regular file; refusing"; fi
  done
  # TOOLS (stand-in tools for the test suite) must never reach a root install.
  if [ "$IS_ROOT" = 1 ] && [ -n "$(sed -n '/@@SETTINGS-BEGIN@@/,/@@SETTINGS-END@@/s/^TOOLS=//p' "$STAGED_HELPER")" ]; then
    die "the staged helper names test tools (TOOLS=...); refusing as root"
  fi
  [ "$(sha "$STAGED_HELPER")" = "$HELPER_SHA" ] || die "staged helper changed before install"
  [ "$(sha "$STAGED_SUDOERS")" = "$SUDOERS_SHA" ] || die "staged sudoers drop-in changed before install"
  [ -z "$STAGED_RS" ] || [ "$(sha "$STAGED_RS")" = "$RS_SHA" ] || die "staged root steps changed before install"
  # Before anything is written; checked again on the root-owned copy below, since
  # the staged file can change in between.
  check_rule "$STAGED_SUDOERS"

  # The log dir first: it holds the manifest. The manifest keeps the dirs earlier
  # installs created (a reinstall creates none, but uninstall must still remove
  # them) and then gets each new dir as it is made.
  created=
  ensure_dir "$LOGDIR"
  check_target "$MANIFEST"
  prev=$(sed -n 's/^created_dir=//p' "$MANIFEST" 2>/dev/null)
  TMP_MANIFEST=$(mktemp "$LOGDIR/.install-manifest.XXXXXX") || die "cannot create a temp file in $LOGDIR"
  {
    echo "installed_epoch=$(date +%s)"
    for d in $prev $created; do echo "created_dir=$d"; done | awk '!seen[$0]++'
  } > "$TMP_MANIFEST" || die "cannot write the manifest"
  owner_fix "$TMP_MANIFEST" 0644 || die "cannot set the owner of the manifest"
  mv -f "$TMP_MANIFEST" "$MANIFEST" || die "cannot write the manifest"
  TMP_MANIFEST=
  MANIFEST_OPEN=1
  for d in "$HELPER_DIR" "$SUDOERS_DIR"; do ensure_dir "$d"; done
  check_target "$HELPER"
  check_target "$SUDOERS"
  check_target "$RS"

  # Helper: copy to a fresh temp name (mktemp creates it exclusively, so nothing
  # planted under a known name is followed). The copy stays root-only (0600)
  # until its hash matches: if the staged path was swapped for a link to a secret
  # between the checks and the cp, the secret is never world-readable, and the
  # mismatch deletes it. Then own, open up, and rename into place (atomic for
  # sudo). Temp names from older versions are removed first.
  rm -f "$HELPER_DIR/.fseventsd-guard-restart.new"
  old_umask=$(umask); umask 077
  TMP_HELPER=$(mktemp "$HELPER_DIR/.fseventsd-guard-restart.XXXXXX") || die "cannot create a temp file in $HELPER_DIR"
  cp "$STAGED_HELPER" "$TMP_HELPER" || die "cannot copy the helper"
  chmod 0600 "$TMP_HELPER" || die "cannot restrict the helper copy"
  [ "$(sha "$TMP_HELPER")" = "$HELPER_SHA" ] || die "helper changed while copying"
  owner_fix "$TMP_HELPER" 0755 || die "cannot set the owner of the helper"
  # The root steps' own text, the same way: uninstall runs this copy, so it needs
  # neither the checkout nor the source gate.
  if [ -n "$STAGED_RS" ]; then
    TMP_RS=$(mktemp "$HELPER_DIR/.fseventsd-guard-root-steps.XXXXXX") || die "cannot create a temp file in $HELPER_DIR"
    cp "$STAGED_RS" "$TMP_RS" || die "cannot copy the root steps"
    chmod 0600 "$TMP_RS" || die "cannot restrict the root-steps copy"
    [ "$(sha "$TMP_RS")" = "$RS_SHA" ] || die "root steps changed while copying"
    owner_fix "$TMP_RS" 0755 || die "cannot set the owner of the root-steps copy"
  fi
  save_previous
  ROLLBACK=1
  mv -f "$TMP_HELPER" "$HELPER" || die "cannot install the helper"
  TMP_HELPER=
  if [ -n "$TMP_RS" ]; then
    mv -f "$TMP_RS" "$RS" || die "cannot install the root-steps copy"
    TMP_RS=
  fi

  # Sudoers drop-in: sudo skips files whose name contains a dot, so the temp name
  # is never live. Validate it, rename it, validate the whole policy, roll back on
  # any failure. The policy check uses -f: plain `visudo -c` also demands mode 0440
  # of every included file, so another tool's 0644 drop-in (which sudo itself
  # accepts) would fail the install. -f checks the syntax of the same files.
  rm -f "$SUDOERS_DIR/fseventsd-guard.new"
  TMP_SUDOERS=$(mktemp "$SUDOERS_DIR/fseventsd-guard.XXXXXX") || die "cannot create a temp file in $SUDOERS_DIR"
  cp "$STAGED_SUDOERS" "$TMP_SUDOERS" || die "cannot copy the sudoers drop-in"
  chmod 0600 "$TMP_SUDOERS" || die "cannot restrict the drop-in copy"
  [ "$(sha "$TMP_SUDOERS")" = "$SUDOERS_SHA" ] || die "drop-in changed while copying"
  check_rule "$TMP_SUDOERS"
  owner_fix "$TMP_SUDOERS" 0440 || die "cannot set the owner of the drop-in"
  umask "$old_umask"
  visudo -cf "$TMP_SUDOERS" >/dev/null || die "visudo rejected the drop-in"
  mv -f "$TMP_SUDOERS" "$SUDOERS" || die "cannot install the drop-in"
  TMP_SUDOERS=
  # Tests check a fake policy under PREFIX when they provide one.
  POLICY=/etc/sudoers
  [ "$TEST" = 1 ] && POLICY=$PREFIX/etc/sudoers
  if [ "$TEST" != 1 ] || [ -f "$POLICY" ]; then
    out=$(visudo -c -f "$POLICY" 2>&1) ||
      die "the sudoers policy failed validation with the drop-in:
$(printf '%s\n' "$out" | grep -v ': parsed OK$' | head -n 8)"
  fi

  ROLLBACK=0
  { echo "file=$HELPER"; echo "file=$SUDOERS"; [ -z "$STAGED_RS" ] || echo "file=$RS"; } >> "$MANIFEST"
  echo "root steps done: $HELPER, $SUDOERS,${STAGED_RS:+ $RS,} $LOGDIR"
  exit 0
fi

# uninstall
KEEP_LOGS=${3:-0}
created=$(sed -n 's/^created_dir=//p' "$MANIFEST" 2>/dev/null)
# The privilege goes first, then the binary, the logs (with the manifest that names
# the created dirs) and the root-steps copy last: a run cut short before it (Ctrl-C,
# a closed terminal) runs again from the copy, without the source gate. Removing the
# copy while it runs is safe: sh keeps reading the file it opened.
rm -f "$SUDOERS" "$SUDOERS_DIR"/fseventsd-guard.*
rm -f "$HELPER" "$HELPER_DIR"/.fseventsd-guard-restart.*
if [ "$KEEP_LOGS" != 1 ]; then
  case $LOGDIR in */Library/Logs/fseventsd-guard) rm -rf "$LOGDIR" ;; esac
else
  rm -f "$MANIFEST" "$LOGDIR/.lock" 2>/dev/null
  rmdir "$LOGDIR/.lock" 2>/dev/null
fi
rm -f "$RS" "$HELPER_DIR"/.fseventsd-guard-root-steps.*
# Directories the install created, deepest first, only when empty: the copy's own
# directory is one of them, so they come after it.
for d in $(printf '%s\n' $created | sort -r); do
  [ "$d" = "$LOGDIR" ] && continue
  # /etc/sudoers.d is named by sudo's own #includedir; leave it even if we made it.
  [ "$d" = "$SUDOERS_DIR" ] && continue
  rmdir "$d" 2>/dev/null
done
echo "root steps done: removed $SUDOERS, $HELPER, $RS$( [ "$KEEP_LOGS" = 1 ] && echo " (kept $LOGDIR)" || echo " and $LOGDIR")"
exit 0
