#!/bin/bash
# The plugin's Claude Code hooks (hooks/hooks.json): `fseventsd-guard claude-hook
# prompt|bash` on macOS. Anywhere else, and whatever the guard does, nothing is
# printed and the exit is 0, so the plugin can be on for a whole team.
# Whatever is left of the hook's stdin JSON is read before the exit, on every path,
# so Claude Code's write never meets a closed pipe.
done_() { [ -t 0 ] || cat > /dev/null 2>&1; exit 0; }
[ "$(uname -s 2>/dev/null)" = Darwin ] || done_
case ${FSG_HINT:-1} in 0|[Nn][Oo]|[Oo][Ff][Ff]|[Ff][Aa][Ll][Ss][Ee]) done_ ;; esac
case ${1:-} in prompt|bash) ;; *) done_ ;; esac
root=${CLAUDE_PLUGIN_ROOT:-$(cd -P "$(dirname "$0")/.." 2>/dev/null && pwd)}
[ -n "$root" ] && [ -f "$root/fseventsd-guard" ] || done_
/bin/bash "$root/fseventsd-guard" claude-hook "$1" 2>/dev/null
done_
