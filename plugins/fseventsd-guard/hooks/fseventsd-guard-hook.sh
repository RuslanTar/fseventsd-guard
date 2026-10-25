#!/bin/bash
# The plugin's Claude Code hooks (hooks/hooks.json): `fseventsd-guard claude-hook
# prompt|bash` on macOS. Anywhere else, and whatever the guard does, nothing is
# printed and the exit is 0, so the plugin can be on for a whole team.
[ "$(uname -s 2>/dev/null)" = Darwin ] || exit 0
case ${FSG_HINT:-1} in 0|[Nn][Oo]|[Oo][Ff][Ff]|[Ff][Aa][Ll][Ss][Ee]) exit 0 ;; esac
case ${1:-} in prompt|bash) ;; *) exit 0 ;; esac
root=${CLAUDE_PLUGIN_ROOT:-$(cd -P "$(dirname "$0")/.." 2>/dev/null && pwd)}
[ -n "$root" ] && [ -f "$root/fseventsd-guard" ] || exit 0
/bin/bash "$root/fseventsd-guard" claude-hook "$1" 2>/dev/null
exit 0
