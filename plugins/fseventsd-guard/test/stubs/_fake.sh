# Shared state helpers for the test stubs. Every stub logs its call to
# $FSG_FAKE/calls.log; the fake fseventsd lives in $FSG_FAKE/fsev/.
: "${FSG_FAKE:?FSG_FAKE must point at the fake state dir of the test}"
FSEV=$FSG_FAKE/fsev
REAL_FSEVENTSD=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/FSEvents.framework/Versions/A/Support/fseventsd

fake_log() { printf '%s\n' "$*" >> "$FSG_FAKE/calls.log"; }

# fake_attr PID NAME DEFAULT
fake_attr() {
  if [ -f "$FSEV/$1.$2" ]; then cat "$FSEV/$1.$2"; else printf '%s\n' "$3"; fi
}

is_fake_pid() { [ -n "${1:-}" ] && grep -qx "$1" "$FSEV/pids" 2>/dev/null || [ -f "$FSEV/$1.mem" ]; }
