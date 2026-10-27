# fseventsd-guard

Keeps macOS `fseventsd` from silently breaking file watching on machines that run
heavily parallel agent and test workloads. It detects a runaway daemon, waits for
running test runs to finish, restarts fseventsd, and brings Docker back. It notifies
you at each step.

- Install, the Claude Code plugin and team settings: [`README.md`](../../README.md) at the repo root
- Design decisions, drain protocol, JSON schema, affected versions: [`docs/DESIGN.md`](docs/DESIGN.md)
- Workflow and runner integration (a check before long test runs, leases): [`docs/WORKFLOW-INTEGRATION.md`](docs/WORKFLOW-INTEGRATION.md)
- Docker trials runbook (picks the Docker step): [`docs/DOCKER-TRIALS.md`](docs/DOCKER-TRIALS.md)

## Why you may need it

- **fseventsd** is the system daemon that delivers file events to Spotlight, IDEs,
  the Next.js dev server, Docker Desktop's file sharing and every other file watcher
  (Claude Code's included).
- **The bug.** On macOS 15.6.1 and later (the reports are in
  [`docs/DESIGN.md` §9](docs/DESIGN.md#9-affected-versions)), a sustained file-event
  flood makes its memory grow without limit (17.7 GB measured on one affected
  Mac against Apple's own 30 MB budget) and it **stops delivering events**,
  silently. It never recovers by itself: only a restart helps, and a restart needs
  root. No source claims a fix yet.
- **What triggers it.** Parallel agent workflows and parallel spec suites
  churn thousands of files, tests create throwaway git repos in `$TMPDIR`, and
  Docker bind mounts turn writes inside containers into file events on the Mac.
- **What you see.** Nothing fails loudly: the IDE, the Next dev server,
  bind-mounted containers and Claude Code stop seeing file changes, and Spotlight
  goes stale. `fseventsd-guard status` shows the footprint far above 30 MB.
- **Who should install it.** Whoever's `fseventsd-guard doctor --affected` exits 0.
  Before 15.6.1 nobody has reported the runaway, and a version at or past a known
  fix (`FSG_AFFECTED_FIXED`, none yet) counts as fixed; `install` refuses there
  without `--force`.
- **What it costs.** One sudo prompt at install; then a notification on each heal,
  IDE and Spotlight rescans after it, and a Docker restart during it (by the Docker
  step, after the drain), as "What a restart costs" below details.
- **Without it.** Someone notices the silence, runs
  `sudo kill -TERM $(pgrep -x fseventsd)` by hand, and repairs Docker, since
  restarting fseventsd naively also breaks Docker Desktop ("hard fails every
  time", [`docs/DESIGN.md` §6](docs/DESIGN.md#6-docker-step)).

## What the guard does

| Part | Runs as | Job |
|---|---|---|
| `fseventsd-guard status [--json] [--probe]` | you | Footprint vs the 30 MB budget, CPU, uptime, optional delivery probe. Exit 0 ok, 1 warn, 2 runaway, 3 cannot measure. |
| `fseventsd-guard heal [--dry-run]` | you | Asks the agent to heal and waits for its result, showing its progress: drains running test runs, runs the Docker step, restarts fseventsd through the root helper, restores Docker and its containers, checks a bind mount round trip, notifies, logs. Stopping the command (Ctrl-C, a timeout) only stops the wait. |
| `fseventsd-guard run -- CMD` | you | Runs a Docker-dependent command under a lease, so a heal waits for it and it waits for a heal. |
| root helper `/usr/local/libexec/fseventsd-guard-restart` | root, via one sudoers rule, no arguments | Re-checks for itself that the target is the real fseventsd, that it is over the floor and not rate limited, saves a small evidence record, then sends SIGTERM (SIGKILL if the same daemon still runs 10 s later). launchd respawns the daemon at once. |
| launchd agent `io.github.ruslantar.fseventsd-guard` | you | The only process that heals. Every 5 minutes, and at once when `heal` or `trial` asks: runs the queued heal requests in order; warns at 256 MB (notification only); at 1 GB, a stalled probe, or 256 MB with fseventsd using half a core or more for 3 checks in a row, an emergency heal at most once per 3 hours. |
| `install` / `uninstall` / `doctor` | you, one sudo prompt | Sets everything up, removes every trace, checks every piece. |
| `claude-hook prompt\|bash` (run by the Claude Code plugin's `hooks/fseventsd-guard-hook.sh`) | you, from Claude Code, macOS only | Not installed: suggests installing, with fseventsd's footprint. Installed: warns when the agent stopped ticking, and tells Claude sessions when a heal stops Docker ("Claude Code hooks" below). |

Two tiers act:

- **Before a long test run (preferred).** A script or workflow calls `status`
  before a long or parallel test run (a workflow that runs in waves: before each
  wave) and `heal --trigger wave` on warn or runaway; the agent runs that heal. At
  warn it heals only when nothing is running, and otherwise returns at once (exit
  4) without holding any run; at runaway it drains first. See
  `docs/WORKFLOW-INTEGRATION.md`.
- **Emergency (the agent).** It acts only when the daemon is clearly broken. It still
  drains first: it waits for leased runs up to 60 minutes and for other detected
  work up to 10 minutes, then proceeds and tells you which runs it cut.

### The drain: which runs wait, which are cut

Your machine is never idle, so a heal cannot wait for a free moment. Instead:

1. The heal marks a **drain** as pending. Only **leased** runs wait for it: runs
   started with `fseventsd-guard run`, or by a runner that takes a lease itself
   (`docs/WORKFLOW-INTEGRATION.md`). They show
   `fseventsd-guard: holding 'specs' while fseventsd is healed ...` and start by
   themselves when the heal ends. Any other run that starts during a heal is not
   held: it starts against a stopped Docker and may fail.
2. It waits for the work that started **before** the drain: leased runs up to 60
   minutes (`FSG_DRAIN_CAP_S`), and as a fallback any running `rspec`,
   `parallel_rspec`, `parallel_test`, `docker exec`/`run` or `docker compose run/exec` process,
   container exec sessions, and running `--rm` or one-off (`docker compose run`)
   containers up to 10 minutes (`FSG_UNLEASED_CAP_S`). When Docker answers
   `docker info` but does not list them (`docker ps` or `docker inspect` fails or
   times out), they count as unknown and the drain waits for a listing up to the
   same 10 minutes. A Docker that answers nothing is wedged, the failure the heal is
   for: it lists none, so only the `docker` CLI processes are waited for.
   Work that starts after the drain began does not hold it. Interactive sessions (a shell or
   console run with a TTY, such as a `docker compose exec postgres psql` or
   `docker exec -it api bash` tab; `FSG_INTERACTIVE_COMMANDS` lists them) are never
   waited for; they lose their connection. A TTY exec of anything else, such as
   `docker compose exec api bundle exec rspec`, is work.
3. Then it stops Docker as the chosen variant requires, restarts fseventsd, restores
   Docker and the containers that were running, verifies (each container runs, and is
   healthy again if it was healthy before; one already unhealthy only needs to run),
   and releases the drain.
   While Docker answers, it stops no container and no Docker Desktop unless it
   listed every running container and none is a `--rm` container with an anonymous
   volume (Docker would delete the volume with the container). So when the drain
   ends with such a container running, or with Docker answering `docker info` but
   its `docker ps` or `docker inspect` failing (even for one running container),
   the heal stops there, touches neither Docker nor fseventsd, and says why (exit
   14). No flag lets a heal delete such a container's volume, by design: to heal,
   stop the container yourself (`docker stop NAME`). Only a wedged Docker, one
   that does not answer `docker info`, is acted on without that check, since it is
   the failure the heal is for: the `cutting running work` notification, the result
   notification and the heal record name it. Variant C restarts Docker Desktop
   after fseventsd, so it checks again right before that restart: it skips the
   restart (heal exit 8, runs held until Docker verifies as it is) when such a
   container runs by then, or when the listing fails while Docker still answers
   `docker info`.

Variant B counts Docker Desktop as stopped once its processes and sockets are gone
(or its status says `stopped`), within `FSG_DESKTOP_STOP_WAIT_S` of the stop. If
something else starts Docker Desktop during the heal (another session's
`open -a Docker`), the notice and the heal record say so; the guard leaves it
running and restores as usual. The bind-mount check needs its probe dir in Docker
Desktop's File Sharing list: the guard picks one there (or set `FSG_PROBE_DIR`),
and a probe Docker refuses ("Mounts denied") is reported as skipped, not as a
broken Docker. `doctor` warns when the probe dir is not shared. macOS can keep the
launchd agent from reading Docker Desktop's settings while a terminal reads them
(app-data protection), so `install` caches the list for the agent: re-run
`install` after you change File Sharing (`doctor` warns when the copy is stale).

The `healing` notification and `status` name what the drain waits for (command,
pid, age). At a cap a manual or pre-run (`--trigger wave`) heal gives up and tells you what was
still running. An emergency heal goes ahead, because by then file watching is
already broken, and names what it cut, including runs that started mid-drain. A
pre-run heal below runaway does not drain at all: it heals only when nothing is
running, and otherwise ends at once (exit 4) without a notification, naming what
runs.

## What a restart costs

Say this out loud before you heal by hand; the notifications repeat it.

- fseventsd's event history is erased, so **every FSEvents client rescans**:
  Spotlight re-indexes changed areas, IDEs (RubyMine, VS Code) rescan the project,
  Docker Desktop's file sharing resyncs, file watchers restart.
- **Time Machine probably runs a slower, deeper scan** on its next backup, because
  it uses the event history to find changes. This is an inference, not measured
  yet. Watch the next backup after a heal and report it.
- Docker: depending on the variant, containers are stopped and started (A), or
  Docker Desktop quits and starts again (B) or restarts (C). One-off containers
  (`docker compose run`) are stopped but never started again, since that would run
  their command a second time; the `healed` notification names them. `--rm`
  containers are deleted when they stop, so they are not started again either, and
  their named volumes are kept. One with an anonymous volume (data in an image
  `VOLUME` or `-v /path`) makes the heal refuse instead, and so does a Docker that
  answers but cannot list its containers; only a wedged Docker is acted on
  unchecked, and the notices name it (step 3 above). A heal takes about
  1-3 minutes once the drain is done (the trials measure the exact figure). Only a
  local engine is touched: when `DOCKER_HOST` or the selected Docker context is not
  a unix socket on this Mac (an `ssh://` or `tcp://` context, for example), the
  Docker step is skipped, nothing on that engine is stopped, and the notification
  says so. Docker Desktop is quit or restarted only when the selected socket is
  Docker Desktop's own (`~/.docker/run/docker.sock`, or a link to it such as
  `/var/run/docker.sock`); with colima, OrbStack or another local engine selected,
  only that engine's containers are stopped and started (A) and a running Docker
  Desktop is left alone. The endpoint a heal starts with is used for all of it,
  whatever context you select meanwhile, with the exceptions under "Known
  limitations" ([`docs/DESIGN.md` §6](docs/DESIGN.md#6-docker-step)).
- Dev servers (a Rails server, background workers) reconnect to Postgres and Redis
  on the next request. Restart one if it logs connection errors.
- Running Claude Code sessions may keep a file watcher that does not come back
  after the restart (one report of watchers not recovering). Still untested: a
  scripted check on 2026-10-25 never got fseventsd restarted, see
  [`docs/DOCKER-TRIALS.md`](docs/DOCKER-TRIALS.md). If a session stops seeing file
  changes after the heal, restart it.

## Reduce the trigger

The guard heals the runaway; fewer file events make it rarer. What seems to feed
it (the cause is not proven):

- **Temp-file churn in watched trees.** Every file created, renamed or deleted is
  an event. One runaway started after about 10k uniquely named temp files
  ([`docs/DESIGN.md` §9](docs/DESIGN.md#9-affected-versions), the 27.0.1 row).
- **Test suites that create thousands of uniquely named files**, such as a fresh
  `mktemp` dir or git repo per test. Reuse a fixed dir per worker and empty it.
- **Throwaway dirs inside watched roots.** Keep them outside the trees your IDE,
  dev servers and agents watch, or on a volume none of them watches.
- **Docker bind mounts.** Writes inside a container become events on the Mac.
  Bind-mount only the folders a container needs, not your home directory.

Prior work: [talkstream/fseventsd-runaway@78396ba](https://github.com/talkstream/fseventsd-runaway/tree/78396ba),
a case study of one Mac with a check script, a manual restart script and a Claude
Code plugin; its author calls the causes unproven. Do not follow its plugin's
advice to run `sudo kill -TERM $(pgrep -x fseventsd)` while this guard is
installed: two healers race, and the raw kill skips the drain and the Docker step.

## Install

macOS only, and only on affected versions
(`fseventsd-guard doctor --affected`; the range is in `config.defaults`).
Needs the Command Line Tools (`xcode-select --install`) for the probe.

```sh
git clone https://github.com/RuslanTar/fseventsd-guard.git ~/fseventsd-guard
cd ~/fseventsd-guard/plugins/fseventsd-guard
./fseventsd-guard doctor --affected   # exit 0 = you need it
./fseventsd-guard install             # as you, not with sudo: it asks for your password once
./fseventsd-guard doctor              # everything ok?
./fseventsd-guard notify-test         # see what a notification looks like
```

`install` does this:

1. Copies the guard to `~/Library/Application Support/fseventsd-guard/app`, from
   the git tree the gate checked, not from the working files. The agent runs that
   copy, so switching branches never breaks it. `install` runs only from a clone
   of this repo whose `plugins/fseventsd-guard` is clean and matches `origin/main`,
   and never from Claude Code's plugin directory (see the security model below).
2. Builds the delivery probe with `swiftc`.
3. Renders the root helper and the sudoers drop-in, and checks the drop-in with
   `visudo -cf`.
4. Says why it needs root (first install, changed root code, other helper
   settings, a trial window), prints what will run as root and asks
   `Run this as root? [y/N]` (`--yes` skips the question; without a terminal and
   without `--yes`, install refuses). Then
   one `sudo -k`, which always asks for your password and leaves no cached sudo
   ticket behind: installs the helper root-owned at
   `/usr/local/libexec/fseventsd-guard-restart` (0755), the drop-in at
   `/etc/sudoers.d/fseventsd-guard` (0440), and a root-owned copy of the root steps
   it runs at `/usr/local/libexec/fseventsd-guard-root-steps` (0755, not in the
   sudoers rule) for `uninstall`. The drop-in lets only you run only that
   path, with no arguments, without a password: the root steps refuse a rule for
   anyone but the user who ran `sudo` (`SUDO_USER`), for `ALL` or for an alias-style
   name, and install prints the exact rule before its question. It is validated
   again after it is in place, with the whole sudoers policy
   (`visudo -c -f /etc/sudoers`, which
   names any failing file). Any failure from here on puts back the helper, drop-in
   and root-steps copy that were there before, or removes them on a first install.
5. Loads the launchd agent, which runs every heal. System Settings > General >
   Login Items & Extensions lists it as `fseventsd-guard`; switching it off there
   stops the protection, and `heal` and `trial` then exit 9.

To update, `git pull` in the clone and run `install` again. When the installed
helper, drop-in and root-steps copy already match what it would put there, it
skips steps 3 and 4: it replaces only the app copy and the agent, with no question
and no password. The agent's plist is written only then too, so a plist change
reaches an install only through `install`: one made before 2026-10-26 lacks
`ProcessType Interactive`, which keeps launchd from throttling the agent on a busy
Mac, and `doctor` warns until `install` runs again. `doctor` and `status` (run
from the clone) say which kind of update is due: "re-run install; it needs no
sudo" for an old app copy, or "root code changed ... it asks for sudo".

Security model: the repo is writable by you and by agents. Two pieces of it run as
root: the root-steps text (`lib/root-steps.sh`, only during the one `sudo` of
`install`, and of `uninstall` through its root-owned copy) and the helper rendered
from `lib/restart-helper.sh` (a root-owned copy, on every heal). A **source gate**
keeps that to reviewed code: `install` refuses unless the clone's `origin` is this
repo (https, `git@github.com:` or `ssh://` form, any case; a fork, or a clone
through an SSH host alias such as `git@github-work:RuslanTar/fseventsd-guard.git`,
sets its origin URL as `FSG_REVIEWED_ORIGIN` in the user config), `plugins/fseventsd-guard` has no
uncommitted or untracked changes, and it matches `origin/main` (`git fetch` first).
It takes both texts and the app copy from that git tree rather than the working
tree (replace refs are ignored). `uninstall` runs the root-steps copy install placed, so it needs neither
the gate nor a checkout: the copy is the exact text that install ran as root
(checked by the gate against `origin/main`, unless that install used
`--allow-unreviewed`), and only root can change it since. Uninstall first checks
that the copy is a root-owned regular file, not writable by group or other, with no
ACL, in directories only root can change, and prints its SHA-256 (the "root-steps
text sha256" install printed) before its question; an install without the copy
goes through the gate instead.
Before `sudo` install prints the commit, the git tree id of `plugins/fseventsd-guard`
and the blob ids of `lib/root-steps.sh` and `lib/restart-helper.sh` (compare them
with `git rev-parse origin/main:plugins/fseventsd-guard` and
`git rev-parse origin/main:plugins/fseventsd-guard/lib/root-steps.sh` in another
clone), the SHA-256 of the root-steps text and of the rendered helper, the exact
sudoers rule, and the helper's settings, then ask
`Run this as root? [y/N]`. `sudo -k` asks for your password every time and
leaves no ticket behind. `install`, `uninstall` and `doctor` run every tool from
`/usr/bin`, `/bin`, `/usr/sbin` and `/sbin`, not through your `PATH`, heals run
`/usr/bin/sudo`, and the user config is parsed, never run as shell.
`--allow-unreviewed` overrides the gate once you have read the two files (needed,
for example, to try a branch that is not on main yet); the app copy then comes
from the working tree.

Claude Code keeps its own copy of the plugin under `~/.claude/plugins` (or
`$CLAUDE_CONFIG_DIR/plugins`, or `$CLAUDE_CODE_PLUGIN_CACHE_DIR`) and updates it by
itself. `install`, and an `uninstall` that needs the gate, refuse to run from
there, even with `--allow-unreviewed`, and say to clone the repo. So a plugin update never changes
the root helper, the root-steps copy, the sudoers rule or the app copy: only
`install` from a clone does. The hooks run from the plugin's copy as you and only
read the guard's state.

The gate catches accidental and unreviewed code: an agent's edit, an uncommitted
change, a branch not merged yet, a clone of another repo. It does not stop a
hostile process that runs as you: such a process can edit the gate itself (it runs
from the checkout it checks), move the local `origin/main` or the `origin` URL, or
wrap your terminal through your shell profile, and then the gate prints whatever
ids it likes. The printed ids and hashes only catch
accidental changes. Against a process running as you, the only check is to install
from a fresh clone and compare the ids from a different account or machine. The
installer refuses to put the helper in a directory a non-root user could write to,
by its mode or by an ACL entry, and strips any inherited ACL from the files and
directories it creates.
The helper accepts no arguments, uses no environment variable for a decision (see
Known limitations) and decides on its own whether a restart is justified. The
worst a compromised user account can do with the rule is restart fseventsd when it
is over the floor (150 MB), at most once per 30 minutes; while a trial window is
open (at most 24 hours after `install --trial-hours N`), at any footprint, once
per 120 seconds. Those are minimums: `install` refuses a lower floor or interval
from the config, the helper raises a lower value to them, and `install` prints each
helper setting that differs from `config.defaults` as a warning before its question.

## Uninstall

One command, from anywhere. The guard keeps a copy of itself, so no checkout is
needed (keep the quotes: the path has a space). `install` prints this line at its end.

```sh
"$HOME/Library/Application Support/fseventsd-guard/app/fseventsd-guard" uninstall
~/fseventsd-guard/plugins/fseventsd-guard/fseventsd-guard uninstall   # the same, from a clone
```

It lists everything it removes and asks once (`--yes` skips the question), then
asks for your password once. It removes the launchd agent and its plist, the
sudoers drop-in (first, so the privilege goes before the binary), the root helper,
the root logs, the root-owned copy of the root steps (last, so an uninstall cut
short runs again from it), every directory an install
created (such as `/usr/local/libexec`) once it is empty, the user state (app copy,
probe, config, heal and trial records), the user logs, the Claude Code install
hint's stamps (in `~/Library/Caches/fseventsd-guard-hint`, which `install` clears
too; its `off` file stays; "Claude Code hooks" below), and the temp files an
interrupted guard command left (those over an hour old, so a guard command
running in another terminal keeps its own). It takes the state and log paths from
the agent's plist, and removes nothing until no tick or root helper runs any more.
It ends by
checking that nothing is left and names anything it could not remove, including
an agent from an older install under another label that runs the removed app
copy (with how to remove it). If launchd
still keeps the agent switched off from Login Items, it prints the
`launchctl enable ...` line that clears that setting.

- `--keep-logs` keeps the user and root logs, and moves the heal and trial records
  and your config to `~/Library/Logs/fseventsd-guard-records-<date>-<time>/` (the
  last lines name it).
- It refuses while a heal or drain runs, and while an earlier heal left Docker not
  verified. In that last case it first asks the agent to restore Docker and waits
  up to two agent intervals (10 minutes). If Docker is still not back, it names the
  heal's Docker step, the engine, the containers and the fix: `docker desktop start`
  (variants B and C), `docker start <names>` or `docker compose up -d`, then
  `fseventsd-guard release`. It checks again once the agent is stopped: if a heal
  that began meanwhile left Docker not verified, it stops there, loads the agent
  again and prints the same.
- `--force` uninstalls anyway. A running heal is stopped as at logout: its tick
  restores Docker before it exits, and uninstall waits for it. Docker that an
  earlier heal left down, or that the stopped tick could not restore, stays as it
  is; uninstall prints what to bring back before it removes anything.
- A wrong or cancelled password stops it with nothing else removed and the agent
  loaded again. Run it again. Root steps cut short (a Ctrl-C, a closed terminal)
  may already have removed the drop-in, the helper and the root logs, in that
  order: it names what went, loads the agent again (it cannot heal without them)
  and keeps the rest. Run it again to finish (the root-steps copy goes last, so it
  can finish from that copy).
- Remove what you added yourself: lease snippets in runner scripts
  ([`docs/WORKFLOW-INTEGRATION.md`](docs/WORKFLOW-INTEGRATION.md)), the
  `status`/`heal` call before test runs, `FSG_*` exports. Leases do nothing once the guard is gone,
  and `heal` exits 9.

An install made before the root-steps copy existed (no
`/usr/local/libexec/fseventsd-guard-root-steps`; `doctor` warns) takes the root
steps from a reviewed clone instead (its origin this repo, clean and matching
`origin/main`), or from
the installed copy with `--allow-unreviewed`, and says so. Re-running `install`
first places the copy.

### Manual uninstall (if the command is gone)

If a heal may have left Docker down, check it first (`docker desktop status`,
`docker ps`).

```sh
launchctl bootout gui/$(id -u)/io.github.ruslantar.fseventsd-guard
sudo rm -f /etc/sudoers.d/fseventsd-guard    # first: the privilege goes before the binary
sudo rm -f /usr/local/libexec/fseventsd-guard-restart /usr/local/libexec/fseventsd-guard-root-steps
sudo rm -rf /Library/Logs/fseventsd-guard
rm -rf "$HOME/Library/Application Support/fseventsd-guard"
rm -f "$HOME/Library/LaunchAgents/io.github.ruslantar.fseventsd-guard.plist"
rm -f "$HOME/Library/Logs/fseventsd-guard.log" "$HOME/Library/Logs/fseventsd-guard.agent.log"
rm -rf "$HOME/Library/Caches/fseventsd-guard-hint"    # the Claude Code hint's stamps and off file
```

If the install created `/usr/local/libexec` and it is now empty,
`sudo rmdir /usr/local/libexec` removes it too.

## Notifications and what to do

| You see | Meaning | Do |
|---|---|---|
| `fseventsd at 612 MB` (warn) | Growing past its budget; watching may degrade | Nothing urgent. Run `fseventsd-guard heal` at a convenient point, such as before a long test run. |
| `fseventsd: healing (2.3 GB)` | A heal started; it names what it waits for, the interactive sessions it leaves alone, the `--rm` containers the Docker step would remove, and those with an anonymous volume that would make it refuse. New leased runs wait; other new runs are not held | Nothing for leased runs: they resume by themselves. Hold off starting unleased runs until `fseventsd healed`. |
| `fseventsd: cutting running work` | A heal proceeds with work still running: an emergency heal at a cap, or runs that started mid-drain; or the Docker Desktop restart that restores a killed heal's variant C step does. It says so when Docker's exec sessions and containers were still unknown (not listed) at the cap, names the `--rm` containers the Docker step now removes, and says when a wedged Docker (no answer to `docker info`) did not list its containers, so their volumes could not be checked | Re-run the listed test runs after the heal. |
| `fseventsd: heal refused` (a --rm container would lose its data) | The drain ended with a running `--rm` container that has an anonymous volume, and the Docker step would stop it: Docker would delete the volume with it. Nothing was stopped or restarted (heal exit 14). An emergency heal refused this way waits out the 3-hour emergency interval | Stop the container yourself once its data is safe, or start it again with a named volume (`-v NAME:PATH`), then `fseventsd-guard heal`. |
| `fseventsd: heal refused` (Docker did not list its containers) | When the drain ended, Docker answered `docker info` but its `docker ps` or `docker inspect` failed (even for one running container), so the heal could not check for `--rm` containers with an anonymous volume, and the Docker step would stop them. Nothing was stopped or restarted (heal exit 14). An emergency heal refused this way waits out the 3-hour emergency interval | `docker ps`; once Docker lists its containers again (restart Docker Desktop yourself if it does not), `fseventsd-guard heal`. |
| `fseventsd healed` | Done; wall time in the subtitle. It says when the Docker step stopped containers or Docker Desktop on a wedged Docker without checking for `--rm` containers with an anonymous volume | Expect IDE/Spotlight rescans. After such an unchecked step, look for a `--rm` container that was running. |
| `fseventsd: heal given up` | Manual/wave heal hit a cap; it names what was still running, or that Docker's exec sessions were still unknown | Re-run `heal` when runs are done (or Docker answers again), or `heal --on-cap proceed`. |
| `fseventsd: restart failed` | The helper refused or failed; Docker was restored (if it did not verify, new test runs stay held) | `fseventsd-guard doctor`; log at `~/Library/Logs/fseventsd-guard.log`. Manual fix: `sudo kill -TERM $(pgrep -x fseventsd)`. |
| `fseventsd restarted, check needed` | Restarted, but Docker or a container did not fully come back, or variant C skipped its Docker Desktop restart (a `--rm` container with an anonymous volume ran by then, or Docker answered but did not list its containers; the notice says which). New test runs stay held. | `docker desktop status`, `docker ps`; restart Docker Desktop if needed. The agent releases held runs when Docker is healthy again; or run `fseventsd-guard release`. |
| `fseventsd-guard: heal interrupted` | The agent was stopped during a heal (logout, `launchctl bootout`, a kill) and Docker did not verify after the restore. New test runs stay held. | As for `check needed`. |
| `fseventsd-guard: Docker restored` | The agent was stopped during a heal before it restored Docker; its next tick restored Docker and it verified. It names a variant C restart that was skipped or ran unchecked (the stopped tick sends this notice itself when Docker verified after a Docker step it ran unchecked on a wedged Docker: such a restart, or containers or Docker Desktop stopped), and any container it dropped from the restore set after 2 failed passes (gone or not running, counted at most once per agent interval; one that runs but is not healthy yet is never dropped) | Nothing, or start the named containers by hand. |
| `fseventsd-guard: Docker not restored` | The agent was stopped during a heal before it restored Docker, and the restore did not start: its drain marker could not be written (disk full). Docker was left alone | Free disk space; the agent retries every 5 minutes. Or recover Docker by hand, then `fseventsd-guard release`. |
| `fseventsd-guard: Docker not restored` (the Docker endpoint changed) | The agent was stopped during a heal before Docker verified, and the selected Docker context (or `DOCKER_HOST`) is no longer the engine that heal stopped. The agent touches no Docker; new test runs stay held | Select that engine again (`docker context use ...`); the agent restores it at its next tick. Or recover Docker by hand, then `fseventsd-guard release` |
| `fseventsd-guard: Docker not verified` (the guard stops restoring it) | Docker did not verify within `FSG_FAILED_HOLD_S` (60 min) of a heal's Docker step, so the agent stops restoring it: a Docker you quit since stays off, and heals may start again | Get Docker back by hand if you need it (`docker desktop status`, `docker ps`). |
| `fseventsd runaway ... not healing: Docker not verified` | A runaway while an earlier heal's Docker is still not verified: the agent starts no new heal (a `heal` exits 8) | Get Docker back (`docker desktop status`, `docker ps`), then `fseventsd-guard release`; the agent heals at its next tick. |
| `fseventsd-guard: agent cannot run` | The agent could not create its lock (disk full): it neither heals nor serves heal requests, and a waiting `heal` ends with exit 10 | Free disk space. |
| `fseventsd-guard: held runs released` | Docker is healthy again after an incomplete heal | Nothing. |
| `fseventsd runaway again ... not auto-healing` | Second runaway within 3 hours of the last restart or restart attempt. Only one made at 150 MB or more (the helper's floor), or by an emergency heal, counts: a trial's at a healthy footprint does not | Heal by hand (`fseventsd-guard heal`) and look for the file-churn source. |
| `fseventsd-guard cannot measure fseventsd` | Three checks in a row could not read the daemon; the guard can neither warn nor heal. A check tries a `top` that does not answer within 15 s three times, 5 s apart (a busy Mac), and the reason then gives `ps`'s resident size, a lower bound on the footprint | `fseventsd-guard doctor`, `fseventsd-guard status`. |
| `fseventsd: delivery stalled` | The probe got no event, but the footprint is below the helper's floor | Manual fix shown in the notification. Report it: it is an open question for the thresholds. |

Logs: `~/Library/Logs/fseventsd-guard.log` (user side, one line per check),
`/Library/Logs/fseventsd-guard/` (helper log and small evidence records),
`~/Library/Application Support/fseventsd-guard/heals/` (per-heal records with
phase timings; `docker-stop.txt` has variant B's stop and each poll), and `daily`
next to it (one line per day: checks, the largest footprint and CPU share, heals
that restarted fseventsd, and the median and 95th percentile of the event rate).

## Everyday commands

```sh
G=~/fseventsd-guard/plugins/fseventsd-guard/fseventsd-guard   # your clone
$G status                  # human summary, with the agent's last tick (STALE when overdue)
$G status --json --probe   # for scripts (schema in docs/DESIGN.md)
$G leases                  # drain state and what counts as running work
$G heal --dry-run          # what a heal would do right now
$G heal                    # the agent drains, restarts, restores; this waits for it
$G heal --result ID        # re-attach to a heal after Ctrl-C (or one queued with --no-wait)
$G run --label specs -- bin/parallel-specs   # run under a lease
$G release                 # end a hold left when a heal could not restore Docker
```

Tune thresholds in `~/Library/Application Support/fseventsd-guard/config`. Every
default is listed with its meaning in `config.defaults`. Settings rendered into the
root helper (floor, interval) need `install` again; `doctor` flags the drift.
`install` refuses a floor below 150 MB or an interval below 1800 s (a trial interval
below 120 s), and names each one that differs from `config.defaults`. The
file is read, never run as shell: only `KEY=VALUE` lines for a key in
`config.defaults` count, with a value of letters, digits and `. _ - : / @` (spaces
only inside quotes; a `# comment` may follow). Any other line is ignored, logged,
and makes `doctor` warn. A setting whose default is a number takes whole numbers
only (`2048`, not `2G`): any other value is replaced by its default, logged, and
makes `doctor` fail, naming the key and the value.

The drain's fallback detection knows `rspec`, `parallel_rspec` and `parallel_test`
by name. Add your project's own test runner names (a `bin/parallel-specs` wrapper,
say) to `FSG_DETECT_COMMANDS` in that config file, or better, run the runner under
a lease (`fseventsd-guard run`, or `lib/lease.sh`; see
`docs/WORKFLOW-INTEGRATION.md`).

## Claude Code hooks

The Claude Code plugin in this directory (`.claude-plugin/plugin.json`,
`hooks/hooks.json`) runs `hooks/fseventsd-guard-hook.sh`, which on macOS runs the
plugin's own `fseventsd-guard claude-hook prompt|bash` (`lib/hint.sh`). Off macOS,
or when the plugin's directory is gone, the command in `hooks.json` exits at once
with no output, and so does the wrapper; the repo's `.gitattributes` keeps every
file LF on a Windows checkout too. Each prints hook JSON or nothing, always exits 0,
and never allows, denies or asks. Install the plugin in Claude Code with
`/plugin marketplace add RuslanTar/fseventsd-guard`, then
`/plugin install fseventsd-guard@fseventsd-guard`. A team's project settings turn
the plugin on but do not install it: each teammate still runs the one-time
`claude plugin` install the root `README.md` gives ("For a team").

| Hook | Speaks when | Says | How often, at what cost |
|---|---|---|---|
| `UserPromptSubmit` (`prompt`): the install nudge | The guard is not installed (no agent plist, no root helper: an install stopped at the root question or at sudo does not count) on an affected macOS version | fseventsd's footprint in MB and as a multiple of the 30 MB budget, its uptime and level, why that matters, and what to run in a new terminal window (install asks for sudo): `if [ -d ~/fseventsd-guard ]; then git -C ~/fseventsd-guard pull --ff-only; else git clone https://github.com/RuslanTar/fseventsd-guard.git ~/fseventsd-guard; fi && ~/fseventsd-guard/plugins/fseventsd-guard/fseventsd-guard install` (an existing clone is updated first), then the same path with `doctor`. A short warning for you (`systemMessage`) and the facts for Claude, which says that you have not been told yet | At most hourly at runaway (1 GB and up), every 3 hours at warn (256 MB and up), daily below that; the stamps in `~/Library/Caches/fseventsd-guard-hint` are shared by every session. It measures (`top`, about 2 s) at most once an hour; any other prompt costs a file read (about 25 ms in all, through the wrapper) |
| `UserPromptSubmit` (`prompt`): the stopped-agent warning | The agent's plist is installed, but its last tick is older than twice `FSG_AGENT_INTERVAL_S` (5 minutes), as `status` and `doctor` judge it (the heartbeat, or with none the newest `TICK` line or the install; a tick still in a heal counts as running): the agent is unloaded, switched off in Login Items & Extensions, or hung. Never while the Mac has been up or awake for less than two intervals: launchd runs the agent at login and on wake, and a prompt can come first | How long ago the last tick was, that the guard is not watching fseventsd, the likely causes, and to run `"$HOME/Library/Application Support/fseventsd-guard/app/fseventsd-guard" doctor` in a terminal (the installed app copy, as the heal notice names it). A short warning for you (`systemMessage`) and the facts for Claude, which says that you have not been told yet | At most every 6 hours; its stamp in `~/Library/Caches/fseventsd-guard-hint` is shared by every session. A recent heartbeat costs the config and one file read (about 25 ms more per prompt than without the check, through the wrapper, on a loaded Mac); it never measures fseventsd or asks `launchctl` |
| `PreToolUse` and `PostToolUse` on Bash (`bash`): the heal notice | The guard is installed and a heal is draining, in its Docker step, holding runs because Docker did not verify, or ended in the last 10 minutes | To Claude only: since when, the trigger, what the heal's Docker step does to Docker, that `docker`, `docker compose` and test commands may fail or hang until it ends, that leased runs resume by themselves, that restarting Docker by hand interferes, and `status`; once it ended, the result, that a failure in that window is likely the heal, and (when fseventsd restarted) to restart a session that stops seeing file changes | Once per heal, phase (draining, Docker step, held, ended) and session; a subagent that Claude Code names (`agent_id`) gets its own. Stamps in `$TMPDIR/fseventsd-guard-hook`, removed after a day. It reads the guard's state files only, never Docker or fseventsd: about 15-20 ms per Bash call with no heal, through the wrapper |

Once the guard is installed the nudge stops, and the agent heals unattended; the
prompt hook then speaks only when that agent stops ticking.
To silence both hooks, set `FSG_HINT=0` in the environment Claude Code starts with
(an `export` in your shell profile, or `"env": {"FSG_HINT": "0"}` in
`.claude/settings.local.json`), or create the `off` file:

```sh
mkdir -p ~/Library/Caches/fseventsd-guard-hint && touch ~/Library/Caches/fseventsd-guard-hint/off
```

`install` and `uninstall` remove the nudge's and the stopped-agent warning's stamps
from that directory, not the `off` file.

## Replacing an older watcher

If you ran a temporary notify-only watcher (a launch agent that checks fseventsd's
memory), `doctor` lists it. After this guard is installed and `doctor` passes,
unload the old one (`launchctl bootout gui/$(id -u)/<its label>`) and move its plist
and script out of the way.

A launch agent that runs this guard's own app copy
(`~/Library/Application Support/fseventsd-guard/app/fseventsd-guard`) under another
label, such as an install made under an older label, would heal next to this one.
`install` refuses while one exists and changes nothing, and `doctor` fails on it.
Both name the plist and its label. Run that install's own `uninstall` first, or
unload and remove it: `launchctl bootout gui/$(id -u)/<its label>`, then delete
the plist.

## Known limitations

Found in pre-release security reviews and judged acceptable for now, or left for later.
None of them lets a non-root user gain root.

- **Helper rate limit fails open.** The helper's stamp write is unchecked, and a
  missing, empty or non-numeric stamp reads as "never restarted". `sudo` passes the
  caller's rlimits (`RLIMIT_FSIZE`), so the truncating write can be made to leave an
  empty stamp. The root-owned directory keeps users out otherwise. Fix later: write
  a temp file and `mv` it, refuse on failure, and treat an unreadable stamp as
  "restarted now".
- **Stale Docker Desktop sockets.** A Docker Desktop that crashed and left its
  socket files behind is seen as stopped only through its status; otherwise B's
  stop wait runs out (logged; the heal goes on). Accepted.
- **The agent's File Sharing list is install's copy.** Where macOS app-data
  protection refuses the agent Docker Desktop's settings (seen on 2026-10-25), the
  bind-mount probe picks its dir from the list `install` cached. Change File Sharing
  later and the agent works from the old list until `install` runs again; `doctor`
  reports the difference. A wrong pick only makes the check skip, never fail. With
  no copy (install could not read the list either), set `FSG_PROBE_DIR`.
- **PID reuse between the re-check and the kill.** Tens of milliseconds; macOS
  hands out pids in sequence, so reuse there is not practical, and a respawn in
  that window makes `kill` fail with ESRCH (exit 71). Accepted.
- **Helper environment.** macOS `sudo` keeps `LANG`, `LC_*`, `TZ` and `HOME`. None is
  used in a security-relevant way, but tool output could vary with the locale. Fix
  later: `LC_ALL=C; export LC_ALL` in the helper.
- **Heal lock put-back window.** The heal lock appears only with its owner record
  inside (built under a private name, then renamed into place), and a stale lock is
  renamed aside and deleted only if it is the one judged stale. If it turns out to
  be a lock another tick took in between, it is renamed back; a third tick (one run
  by hand) that takes the lock in that sub-millisecond gap makes two ticks overlap
  (logged; the helper's own lock still keeps the two kills apart). Accepted.
- **No second precheck after the drain.** After a drain of up to 60 minutes the heal
  does not check again whether a restart is still needed or allowed. If fseventsd
  was restarted meanwhile, Docker is stopped for a restart the helper then refuses
  (65/66, reported as exit 7). Fix later: re-run the precheck right before the
  Docker before-step and exit 6.
- **Runners trust the drain file.** With `FSG_RUN_MAX_WAIT_S=0`, a stray pending file
  with a far-future deadline and a long-lived owner pid holds runs until that
  deadline (a hold left after a failed restore is capped at `FSG_FAILED_HOLD_S`). A
  lease naming a long-lived pid (for example the sourced snippet run in an
  interactive shell) holds every drain to its cap. The lease dir follows `$HOME`,
  so a runner with a different `HOME` writes leases where the guard never looks.
- **Unleased runs are not held.** Until the runners take leases, a heal only waits
  (up to 10 minutes) for unleased work that started before it, and any unleased run
  started during the heal meets a stopped Docker. The heal names those runs as cut.
  Telling an interactive exec session from a scripted one asks the Docker engine API
  over its socket with curl; this has run only against the test stub so far. If it
  does not answer, every exec session counts as work (still capped at 10 minutes).
  A wedged Docker (one that answers neither the listing nor `docker info`) lists no
  exec sessions or containers, so the drain does not wait for them and a heal cuts
  any that run in it; a `docker` CLI process that drives one is still waited for.
  A Docker that answers `docker info` but fails the listing holds the drain those
  10 minutes instead; a manual or wave heal then gives up (exit 4) unless it runs
  with `--on-cap proceed`. Long-lived `--rm` and one-off containers: see the
  2026-10-23 items below.
- **launchd caps the agent's exit time at 60 s.** The plist asks for enough time to
  restore Docker after a signal (`ExitTimeOut`, 1390 s with the defaults), but
  launchd gives a user agent at most 60 s from SIGTERM to SIGKILL (measured on macOS
  27.0.1; `doctor` prints the value in use). A heal stopped at logout or by
  `launchctl bootout` past its Docker before-step can then be killed in its
  restore, and recovery comes from the Docker intent and the next tick (the item
  below).
- **A loaded Mac can still blind the guard.** The agent's check and a heal's
  precheck try a `top` that misses `FSG_TOP_TIMEOUT_S` (15 s) three times, 5 s
  apart, and the agent runs unthrottled (`ProcessType Interactive`). A Mac so
  loaded that every try misses stays blind: no warning, no heal, and no delivery
  probe, so a stall goes unseen too; three such checks in a row notify. The root
  helper takes its own `top` sample, bounded at 15 s and tried once: if it misses,
  the helper refuses (70) after the drain and the Docker step, and the heal ends
  with exit 7, Docker restored. A heal whose precheck needed a second try takes one
  more `top` right before the Docker step and, if that misses too, ends with exit 3
  before it touches Docker (an emergency heal ending this way waits out the 3-hour
  emergency interval); the helper can still miss after that one answered.
  Retrying in the helper is root code (a sudo install).
- **An agent killed outright mid-heal.** A caller cannot stop a heal, but the
  agent's tick can still be killed (`kill -9`, or launchd's SIGKILL at the end of
  its exit time, above). That runs no cleanup: Docker stays as the heal left it
  and runners ignore the dead tick's drain. Leased runs still wait, behind the heal's Docker
  intent, which they read themselves: after an A or B before-step, or any after-step
  action, for up to `FSG_FAILED_HOLD_S` (60 min) or until `fseventsd-guard release`,
  even if no tick ever runs again. The agent's next tick (at most 5 minutes) restores
  and verifies Docker under a drain of its own (variant C first waits for runs leased
  since) and so releases them; unleased runs can meet a stopped Docker until then. The waiting `heal` then ends with 130, or sooner when the
  agent is unloaded or no tick runs for two agent intervals; `status` and `doctor`
  show the intent.
- **Heals wait for the agent.** `heal` and `trial` need the agent loaded and as new
  as the checkout (exit 9 otherwise, naming the fix), and a heal starts only when
  the agent's tick takes the request: at once when nothing else runs, else after
  the heal in progress. Any `FSG_*` exported in the caller's shell reaches the heal
  only as the request's drain cap, cap policy and Docker variant.
- **Probe errors are not stalls.** A probe that fails (for example
  `FSEventStreamStart failed`, plausible against a wedged daemon) is classed as
  `error` and never triggers a heal or a notification.
- **Agent PATH order.** The agent's `PATH` puts the Docker CLI dir, `/usr/local/bin`
  and `/opt/homebrew/bin` before `/usr/bin`, so Homebrew tools (gawk as `awk`)
  replace the stock ones inside the agent. Fix later: `/usr/bin:/bin:/usr/sbin:/sbin`
  first.
- **`--rm` volume check.** A volume a `--rm` container got through `--volumes-from`
  counts as anonymous, so it makes a heal refuse even when Docker would keep it,
  and no flag overrides that (step 3 of the drain). A Docker that answers
  `docker info` but fails `docker ps` or `docker inspect` (even for one running
  container) makes a heal refuse too (exit 14), even when no such container runs:
  a failed listing is not an empty one. A wedged Docker (no answer to
  `docker info`) is acted on without the check, so a `--rm` container with an
  anonymous volume on it loses that volume; the notices and the heal record name
  such a step. The `ExitTimeOut` install computes does not count the
  `docker info` and container listing (up to 100 s) variant C runs before its
  restart (and launchd grants at most 60 s anyway, above).
- **Smaller inaccuracies.** `heal --dry-run` exits 0 when it cannot measure (a real
  heal exits 3). After helper exit 73 (signal sent, no respawn seen) the suggested
  manual fix `sudo kill -TERM $(pgrep -x fseventsd)` finds no process.
- **Open minor items (review of 2026-10-20).** Not fixed on purpose:
  - Helper refusals are not predicted by the precheck: it lacks the helper's comm and
    ppid checks, `sudo -n -l` passes for any NOPASSWD admin, and exit 7 has no
    cross-trigger back-off.
  - The drain cap and the runners' deadlines use wall-clock time, so a sleep during a
    heal cuts runs short at wake.
  - A stall-only emergency heal ignores the heal's own ok probe and does not re-check
    after the drain.
  - There is no stale-install notification, and leases carry no version.
  - The Command Line Tools check never fires: `/usr/bin/swiftc` is the xcrun shim, so
    a missing toolchain shows up only as a failed probe build.
- **Open minor items (review of 2026-10-21).** Not fixed yet:
  - The root steps do not check the staged helper against the reviewed
    `restart-helper.sh`, only against the caller's hash, so a same-uid writer racing
    the staged file in `TMPDIR` gets code installed behind the sudo rule; no check run
    from the same account catches it. Fix later: pass the helper text and settings to
    the root steps and render it there, as for the drop-in.
  - The entry script finds `dirname` and `readlink` through the caller's `PATH`
    before `fsg_fixed_path` runs, so a planted one picks the code `install`,
    `uninstall` and `doctor` load.
  - A request that can be neither claimed nor withdrawn (full or read-only volume)
    makes `heal` / `heal --result` wait forever without output; it should end with 10.
  - The recovery's hold expires `FSG_FAILED_HOLD_S` after it is written, the intent
    after the action, so a late or killed-then-resumed recovery can verify and fail
    with no hold; `action_ran` and `action_epoch` are two separate rewrites.
  - In a variant C recovery the drain deadline is refreshed before the container
    start, wait and bind-mount probe, so a slow one can outlast it and release held
    runs.
  - A request still queued when the agent is unloaded or switched off makes its
    caller wait 10 minutes and exit 10, not 9.
  - The `ExitTimeOut` install computes leaves out the EXIT trap's verify step, and
    launchd grants at most 60 s (above), so a restore during a `bootout` can be
    SIGKILLed mid-restore or mid-verify with no result and no notice; the next tick
    recovers it.
  - `install` and `uninstall` check for a running heal before the prompts but not
    again before `launchctl bootout`; a heal that starts meanwhile is cut (uninstall
    then waits for its tick, which restores Docker before it exits, and stops with
    the agent loaded again if Docker is still not verified).
  - A queued requester whose own lease the running heal waits for blocks until the
    drain cap, then gets 4 or 11 with no heal (two leased workflows asking for waves).
  - `heal --no-wait` / `--result ID --no-wait` polling never re-kicks, withdraws or
    notices a killed claimer, so it can report 12 indefinitely.
  - README, `docs/WORKFLOW-INTEGRATION.md` and the `heal` usage text promise exit 9
    for an agent "older than the checkout", but only the request protocol number is
    compared; `doctor` is the only stale-copy warning.
  - `status` and `doctor` show a busy agent as STALE during a tick past
    `2 * FSG_AGENT_INTERVAL_S` outside a drain (recovery pass, precheck of the next
    request, trial collection), because the heartbeat is written only at tick start
    and end.
  - Timing-flaky tests: a 1 s `FSG_RUN_MAX_WAIT_S` can give up before the first
    "holding" line, and a real process with pid 4242 looks like the fake fseventsd.
- **Open minor items (review of 2026-10-22).** Not fixed yet:
  - `install` replaces the loaded agent's app copy and rebuilds the probe before it
    asks `Run this as root?`, and does not put them back on `N` or when a root step
    fails (only the helper, drop-in and root-steps copy are rolled back). The next
    tick runs the new code against the old helper until `install` runs again.
  - `heal --result` with a missing or empty ID queues a new manual heal instead of
    failing with 64, so a polling script whose `$id` is empty queues one on every
    poll. Check the ID before polling.
  - `heal --drain-cap` and the request's `drain_cap` accept leading zeros (`0900`)
    and numbers of any size. Runners then compute a different deadline than the
    drain waits for, and a held run can start while the heal still waits. Pass a
    plain decimal number.
  - The Docker endpoint pin lasts the whole tick, so a request or emergency heal
    that follows another in the same tick acts on the engine resolved for the
    earlier one, even after you selected another context.
  - A Docker intent whose after-step never ran (the tick was killed in the Docker
    before-step) has no expiry. If you then select another engine, recovery refuses
    to touch Docker and `heal` exits 8, as do emergency heals, until you select that
    engine again or run `fseventsd-guard release`.
  - The agent never sees `DOCKER_HOST` from your shell: it uses the selected Docker
    context. `heal --dry-run` runs in your shell, so it can name another engine than
    the real heal acts on.
  - A heal that starts on a non-local endpoint does not pin it: if you select a
    local context during its drain, its Docker step acts on that engine.
  - `status --json` on a machine where fseventsd cannot be measured (level
    `unknown`) can break the schema: with `--probe` it reports `probe.ran` true with
    an empty `result`, and `pid` may be set instead of null. Check `level` first.
- **Open minor items (review of 2026-10-23).** Not fixed yet:
  - A long-lived `--rm` or one-off container (a dev database run with
    `docker run --rm`, a `docker compose run --service-ports` dev server) holds every
    drain up to `FSG_UNLEASED_CAP_S` (10 minutes). If it has an anonymous volume,
    the heal then refuses (exit 14), or a manual or wave heal gives up at the cap
    first (exit 4). `FSG_DETECT_DOCKER_CONTAINERS=0` turns the wait off, not the
    refusal.
  - A heal request queued behind a heal that was refused for anonymous volumes is
    not joined to it (requests join only results 0, 7 and 8): it drains again, up
    to `FSG_UNLEASED_CAP_S`, and likely is refused again.
  - Leasing is a no-op while the guard's app copy is missing, and a reinstall
    swaps it (`app` to `app.old`, then `app.new` to `app`): a run that starts in
    that moment takes no lease, so a heal does not wait for it.
  - `uninstall --keep-logs` can leave a stray `.install-manifest.XXXXXX` temp file,
    from an install that was cut short, in the kept root log dir.
  - `uninstall` does not check the agent's Background Items record (Login Items &
    Extensions in System Settings); it reports only the launchd switched-off
    setting.
  - `uninstall --force` during a heal's Docker step can print the Docker restore
    text twice: before its question, and again once the agent stopped if the
    stopped tick did not restore Docker.
  - A heal that starts between `uninstall`'s first Docker check and its
    `launchctl bootout` (while it waits for its question or the password) is
    reported only by the check after the bootout, and only if it left Docker not
    verified.
- **Live launchd checks still owed on a real Mac.** The suite stubs `launchctl`, so
  these have not run for real: Docker Desktop surviving the agent's process-group
  kill at job exit, the agent switched off in Background Items (the tick's trap and
  the waiting caller's exit 9), shutdown or `ExitTimeOut` recovery of a heal cut
  part way, and a real `uninstall` (its sudo of the root-owned root-steps copy,
  `bootout` of a running tick, the `launchctl print-disabled` line it looks for).
  Checked on 2026-10-26 with temporary agents under other labels, not with the
  guard's own: launchd's 60 s cap on the exit time (items above) and the priority
  each `ProcessType` gives (docs/DESIGN.md §5.3). The guard's agent has not run
  with `ProcessType Interactive` yet.
  Checked live on 2026-10-23 (Docker CLI 29.9.2): the two `docker inspect`
  templates, the container record and the drain's engine-work listing. A first
  record template failed on every container without a `--mount` or with a bind
  mount, which led to the missing-key-safe `index` reads. The final JSON-escaped
  templates then ran through the real parser against throwaway containers: an
  anonymous volume on a `--rm` container was flagged, also behind a mount whose
  destination holds a tab (Docker accepts one); a named-volume `--rm` container
  counted as removed, not at risk; a compose one-off was never restorable; an
  exec session was listed. The suite replays lines derived from that run's
  inspect JSON (`test/fixtures/docker-cli-29.9.2`, with the container, volume and
  path names anonymized).
- **Claude Code hooks not checked in a live session.** The suite runs
  `claude-hook` and the wrapper with the stdin JSON Claude Code documents and checks
  their output, but no live session has run them yet: whether Claude Code shows a
  `UserPromptSubmit` hook's `systemMessage` (the nudge and the stopped-agent
  warning also tell Claude that you have not been told, so it can pass them on),
  how the `additionalContext` of
  `PreToolUse` and `PostToolUse` reaches the model, and whether a subagent's hook
  input carries `agent_id` (without one, a subagent shares its session's notice),
  or that `FSG_HINT` set in a settings file's `env` reaches the hooks.
  The nudge's `top` sample (about 2 s on the author's Mac) is bounded at
  `FSG_TOP_TIMEOUT_S` (15 s), so the hook's 10 s timeout comes first; its stamp is
  written first, so a hang costs one prompt an hour. An agent installed before the drain marker named its Docker step
  writes none, so until `install` is re-run, the notice for a draining heal lists
  the three steps instead of naming one.
- **Heal notice costs and keys.** While a heal runs, each Bash call checks the
  drain's owner (a `ps` and a few reads) before the once-per-phase stamp, as the
  stamp's name comes from that check. A session id with JSON escapes reads as
  empty, so such sessions share one notice; Claude Code's ids are UUIDs. Accepted.
- **Native Windows without Git for Windows.** The hooks need `bash`. Where Claude
  Code finds none, it may show a hook error on each prompt and Bash call before
  the `uname` check runs. Turn the plugin off there with `enabledPlugins` false in
  `.claude/settings.local.json` (see the repo README).
- **Unreviewed app-only updates ask nothing.** `install --allow-unreviewed` whose
  root code is unchanged replaces the agent's app copy from the working tree with
  no question, terminal or `--yes`. It needs no sudo, but the agent then runs that
  code.
- **The gate's refusal names `--allow-unreviewed`.** An agent that reads it may
  retry with the flag. The root steps still need your password (`sudo -k`), but an
  app-only update then goes through with no question (the item above).
- **Only the usual origin URL forms are recognised.** The gate reads https,
  `ssh://` and `git@host:owner/repo` URLs. Other forms, such as an scp-style URL
  with a leading slash (`git@github.com:/RuslanTar/fseventsd-guard.git`), are
  refused; set that URL as `FSG_REVIEWED_ORIGIN` or pass `--allow-unreviewed`.
- **A sudoers rule change alone does not roll out.** Whether an update needs the
  root steps is decided by the helper and the root-steps text. The drop-in is
  root-only, so only its owner, mode and that it still allows the helper are
  checked, never its text. A changed rule takes effect only with a helper or
  root-steps change in the same release.
- **Test coverage.** The suite runs without root, so these paths are never
  exercised: the real-root branches of the root steps (uid ownership checks,
  `chown`, `visudo -c -f /etc/sudoers` on the real policy), the helper with its real absolute tools (`TOOLS` is always
  set in tests), and a corrupt helper stamp. Also covered: the heal
  request queue (a killed waiting caller, two requests in order, joined, dropped and
  withdrawn requests, a request queued behind a heal that drains past the withdraw
  bound, a caller waiting on a request whose tick was killed outright, a tick racing
  the agent's tick), the EXIT-trap Docker restore
  after a signal to the agent (it waits for the Docker Desktop stop or root helper
  call the signal cut into), an agent killed outright or during that restore (the
  next tick recovers its Docker intent), a Docker Desktop that runs but does not answer,
  a `top` that is slow once or never answers (the tick, an emergency and a requested
  heal), helper exit 73 with a late respawn, helper exit 72 (SIGKILL needed), leases and drains across TZ/locale, a helper that
  keeps failing under the agent, drain-marker write failure and a slow restore,
  reinstall then uninstall, `--rm` and one-off containers, install during a heal, planted temp
  names and pre-existing unsafe dirs (test mode), the simulated-root refusals, tools
  planted on the caller's `PATH`, a git replace ref for a root text, helper
  settings below the minimums, rules for another user, `ALL` or an alias, the
  source gate (origin forms and forks, files git status does not show, Claude
  Code's plugin directory), sudo-free updates, the drain's start-time filter,
  unleased cap, held-run marker and
  interactive exec sessions, and Docker endpoints (ssh, tcp, unreadable and missing
  sockets touch no Docker; a context switched mid-heal or before a recovery; another
  engine's socket while Docker Desktop runs leaves Docker Desktop alone; Desktop's
  socket through a link keeps B, and its two contexts count as one engine). The
  endpoint check's real-machine side (`docker context inspect`, socket owners) is
  stubbed: the suite links each case's socket to one it creates. Uninstall is
  covered from the app copy without a checkout (the root-owned root-steps copy, one
  that is not root's alone, an install without it), during a heal, a drain, a
  Docker intent the agent restores or does not, and a hold, with and without
  `--force`, with a tick or root helper still running, after a wrong password,
  with `--keep-logs`, with paths exported or planted in the plist, with leftover
  temp files and with the launchd switched-off setting; so are ACLs on the root
  paths (refused, stripped from what install creates, flagged by `doctor`) and
  leases after uninstall.

## Tests

```sh
bash plugins/fseventsd-guard/test/run-tests.sh          # all, from the repo root
bash plugins/fseventsd-guard/test/run-tests.sh heal     # sections whose name contains "heal"
```

No root needed. The suite never touches fseventsd, Docker, launchd or sudo. Every
external command is a stub on PATH, and the suite refuses to start if a real one
would be found first. The root helper runs as you against stand-in tools, and
install/uninstall run in a fake root (`--prefix`).
