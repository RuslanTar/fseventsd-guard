# fseventsd-guard

Keeps macOS `fseventsd` from silently breaking file watching. On some macOS
versions the daemon's memory grows without limit (many GB against Apple's own
30 MB budget) and it stops delivering file events, with no error: IDEs, dev
servers, Docker bind mounts and Claude Code stop seeing file changes until
fseventsd is restarted as root.

fseventsd-guard watches the daemon and heals it: it waits for running test runs
to finish, stops or restarts Docker as needed, restarts fseventsd through a small
root helper, brings Docker and its containers back, and notifies you at each step.

This repo holds two things:

- **The guard** (`plugins/fseventsd-guard`): a launchd agent and a root helper you
  install once per Mac from a clone. Full manual:
  [`plugins/fseventsd-guard/README.md`](plugins/fseventsd-guard/README.md).
- **A Claude Code plugin** (the same directory): two hooks that tell you to install
  the guard on an affected Mac, and tell Claude when a heal stops Docker. The
  plugin never runs as root and never installs anything.

## Who needs it

Macs on macOS 15.6.1 or later (the range and the reports behind it are in
[`docs/DESIGN.md` §9](plugins/fseventsd-guard/docs/DESIGN.md#9-affected-versions)),
especially under heavy file churn: parallel agents and test suites, throwaway git
repos, Docker bind mounts. After cloning, this tells you:

```sh
~/fseventsd-guard/plugins/fseventsd-guard/fseventsd-guard doctor --affected   # exit 0 = you need it
```

Background and prior work:

- [anthropics/claude-code#98769](https://github.com/anthropics/claude-code/issues/98769):
  the issue body reports fseventsd at 24 GB on macOS 27.0 with a core pinned for
  two days; the comments add more Macs where file watching stopped.
- [talkstream/fseventsd-runaway@78396ba](https://github.com/talkstream/fseventsd-runaway/tree/78396ba):
  detection and a manual restart. With this guard installed, do not follow its
  plugin's raw `sudo kill` advice ([Reduce the trigger](plugins/fseventsd-guard/README.md#reduce-the-trigger)
  says why and how to make the runaway rarer).

## Install the guard (macOS)

Run this in a terminal, not through Claude: `install` asks for your password once.
It needs the Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/RuslanTar/fseventsd-guard.git ~/fseventsd-guard
~/fseventsd-guard/plugins/fseventsd-guard/fseventsd-guard install
~/fseventsd-guard/plugins/fseventsd-guard/fseventsd-guard doctor
```

`install` runs only from a clean clone of this repo that matches `origin/main`,
and prints what will run as root before it asks. It copies the guard from that
git tree to `~/Library/Application Support/fseventsd-guard/app`, which the agent
runs. To update, `git pull` in the clone and run `install` again; when the root
code did not change, that needs no password.

`install` refuses to run from the plugin's copy under `~/.claude/plugins`: that
copy is for the hooks only, and Claude Code updates it by itself.

## Uninstall the guard

From anywhere (the guard keeps a copy of itself; keep the quotes):

```sh
"$HOME/Library/Application Support/fseventsd-guard/app/fseventsd-guard" uninstall
```

It lists what it removes, asks once, then asks for your password once.

## The Claude Code plugin

```text
/plugin marketplace add RuslanTar/fseventsd-guard
/plugin install fseventsd-guard@fseventsd-guard
```

| Hook | Speaks when | Says |
|---|---|---|
| `UserPromptSubmit` | macOS on an affected version, guard not installed | fseventsd's footprint and the install commands above; at most once an hour (runaway), every 3 hours (growing) or once a day (fine) |
| `PreToolUse` and `PostToolUse` on Bash | Guard installed and a heal is running, holding runs, or ended in the last 10 minutes | To Claude only: that `docker`, `docker compose` and test commands may fail until the heal ends, once per heal phase and session |

The hooks read the guard's state files and their own stamps. They never run as
root, never change the installed guard, and always exit 0. Off macOS they exit at
once and print nothing.

To silence them: set `FSG_HINT=0` in the environment Claude Code starts with (for
example in the `env` block of a settings file), or create
`~/Library/Caches/fseventsd-guard-hint/off`.

### For a team

In a project's `.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "fseventsd-guard": {
      "source": { "source": "github", "repo": "RuslanTar/fseventsd-guard" },
      "autoUpdate": true
    }
  },
  "enabledPlugins": { "fseventsd-guard@fseventsd-guard": true }
}
```

Claude Code adds the marketplace once each teammate trusts the folder. The plugin
lives inside the marketplace, so no separate install step is needed.

To turn it off for yourself in that project, add this to
`.claude/settings.local.json`:

```json
{ "enabledPlugins": { "fseventsd-guard@fseventsd-guard": false } }
```

### Windows and Linux

Nothing to install. The hooks check `uname` first and exit with no output, so
they never suggest installing the guard. To turn the plugin off anyway, use the
`settings.local.json` line above. On native Windows without Git for Windows
(no `bash`), Claude Code may show a hook error on each prompt and Bash call
instead: turn the plugin off there with that line.

### Updates

Neither `plugins/fseventsd-guard/.claude-plugin/plugin.json` nor the marketplace
entry sets a `version` (a test checks it), so Claude Code versions the plugin by the
commit it was installed from. Merging to `main` is the release for the hooks: every
merge reaches users at their next update. `FSG_VERSION` in `lib/common.sh` names the
guard's own version (the app copy and its state), not the plugin's.

The team settings above turn auto-update on. A personal install does not update
by itself, as Claude Code leaves auto-update off for marketplaces it does not
ship: turn it on for `fseventsd-guard` in `/plugin` > Marketplaces, or pull the
latest `main` with `/plugin marketplace update fseventsd-guard`.

A plugin update changes only the hooks under `~/.claude/plugins`. The root helper
(`/usr/local/libexec/fseventsd-guard-restart`), the root-steps copy, the sudoers
rule (`/etc/sudoers.d/fseventsd-guard`) and the agent's app copy change only when
you run `install` from a clone. The hooks may therefore be newer or older than the
installed guard; they stay silent on any state they do not know.

## Tests

```sh
bash plugins/fseventsd-guard/test/run-tests.sh
```

No root, no Docker, no launchd: every outside command is a stub.

## License

MIT, see [LICENSE](LICENSE).
