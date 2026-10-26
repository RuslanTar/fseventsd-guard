# fseventsd-guard: design record

Every design choice and the reason for it, so a later change can tell a deliberate
decision from an accident. The user-facing summary is `../README.md`.

## 1. Owner decisions this implements

| Decision | Source |
|---|---|
| Auto-restart plus notify (not notify-only, not workflow-only) | original requirements |
| Docker must be handled; the variant is chosen by an experiment (`DOCKER-TRIALS.md`) | original requirements |
| Clean uninstall | owner, 2026-10-16 |
| Its own public repo, the guard and its Claude Code plugin in `plugins/fseventsd-guard/` | owner, 2026-10-25 |
| The machine is never free: trials and every heal go through a graceful **drain** | owner, 2026-10-16 |
| Drain sketch: a lock that runners respect, running specs finish (cap ~60 min, configurable), then stop Docker, restart, start again, release | owner, 2026-10-16 (improved on, §5) |
| Emergency tier: stop and heal, but through the drain | owner, 2026-10-16 |
| Suggest the guard only on affected macOS versions | owner, 2026-10-16 (§9) |
| Affected = a range: from the first version with a reported runaway (15.6.1) up to the first fixed version of each major line (replaces an explicit list, 2026-10-20) | owner, 2026-10-25 (§9) |
| Only the launchd agent runs heals; wave, manual and trial callers write a request and wait for its result | owner, 2026-10-20 (§5.3) |
| The plugin's prompt hook warns when the guard is installed but its agent stopped ticking | owner, 2026-10-26 (§14) |

## 2. Parts and where they live

| Part | Path | Why there |
|---|---|---|
| CLI + libraries (bash 3.2) | `plugins/fseventsd-guard/` | The plugin directory, so the Claude Code hooks run the same code. bash 3.2 is `/bin/bash` on every Mac, so nothing needs installing. |
| Installed app copy | `~/Library/Application Support/fseventsd-guard/app/` | The agent must not depend on a checkout's branch or a worktree that may be deleted. Copied from the git tree the source gate checked (§3). `doctor` and `status` report a stale copy, and whether updating it needs sudo. |
| User state (drain, leases, heal requests and records, config, probe binary) | `~/Library/Application Support/fseventsd-guard/` | One place for every worktree and every repo on the machine. Not `$TMPDIR` (purged, and the flood source), not a repo (per-checkout, so worktrees would not see each other's runs). |
| Root helper | `/usr/local/libexec/fseventsd-guard-restart` (root:wheel 0755) | Outside the repo; root-owned all the way up (§3). |
| Root-steps copy | `/usr/local/libexec/fseventsd-guard-root-steps` (root:wheel 0755) | The root-steps text install ran, for `uninstall` to run with `sudo` from anywhere (the app copy too) without the source gate (§3). Not in the sudoers rule. Next to the helper, so the same directory checks cover it. |
| Sudoers drop-in | `/etc/sudoers.d/fseventsd-guard` (root:wheel 0440) | Standard include dir. No dot in the name (sudo skips dotted names; the installer's temp file uses that). |
| Root evidence | `/Library/Logs/fseventsd-guard/` | Root writes its evidence where the user cannot alter it. |
| User log | `~/Library/Logs/fseventsd-guard.log` | The standard per-user log dir; bounded to 5000 lines. |
| launchd agent | `~/Library/LaunchAgents/io.github.ruslantar.fseventsd-guard.plist` | Per-user, no root. The only process that heals (§5.3). It runs the app copy's `fseventsd-guard` script directly (`#!/bin/bash`), so Background Items lists it by the guard's name, not as "bash". It runs as `ProcessType` `Interactive`, unthrottled, so it can measure on a loaded Mac (§5.3; `doctor` warns on a plist without it). `doctor` reports launchctl's last exit status for it: a tick exits 0-3 (its level), 4-11 (an emergency heal's code, or 10 when it cannot take its lock), 14 (its emergency heal refused to stop Docker for data safety, §6: `doctor` names the last heal's result and record, with no reinstall advice) or 130 (stopped by a signal, after its trap cleaned up), so any other code is a warning. Another plist in the LaunchAgents dir that runs the app copy under another label (an install left under an older label) would heal next to it: `install` refuses before it changes anything, and `doctor` fails, naming the plist, its label and the fix. |

The runner-side lease code (`lib/lease.sh`) is POSIX sh so that sh, bash and zsh
scripts can source it. The root helper is `/bin/sh` with absolute tool paths.

## 3. Security model

- **Root runs reviewed code, unless the developer says otherwise.** The checkout is
  writable by the user and by agents. Two pieces of it do reach root: the text of
  `lib/root-steps.sh` (run by the one `sudo` of `install`, and of `uninstall`
  through the root-owned copy below) and the
  helper rendered from `lib/restart-helper.sh` (a root-owned copy; the sudoers rule
  names that path only, and the root steps refuse a staged drop-in holding anything
  but that one rule for the path they checked). So `install` passes a **source gate**
  first (and `uninstall` too, but only for an install without the root-steps copy):
  the clone's `origin` must be the reviewed repo (`FSG_REVIEWED_ORIGIN`, compared
  as host/owner/repo without case, so https, `git@host:` and `ssh://` forms match;
  a fork sets its own), `plugins/fseventsd-guard` must have no uncommitted or
  untracked changes, and its tree at HEAD must equal its tree at `origin/main`
  (reviewed, merged code). Both texts and the app copy are then read from that git
  tree object, not from the working tree, so they cannot change after the check
  and a file `git status` does not show (assume-unchanged, skip-worktree) never
  reaches the agent; every gate git call runs with
  `GIT_NO_REPLACE_OBJECTS=1`, since a `refs/replace/*` entry for a blob changes what
  `cat-file` returns while the tree ids and `git status` stay the same. Before
  `sudo` the installer prints the commit, the git tree id of
  `plugins/fseventsd-guard` and the blob ids of `lib/root-steps.sh` and
  `lib/restart-helper.sh` (computed from the texts it loaded, checkable in another
  clone), the SHA-256 of the root-steps text and of the rendered helper and the
  rendered helper settings (a warning line for each that differs from
  `config.defaults`), then asks `Run this as root? [y/N]` (`--yes` skips the
  question; without a terminal it is required). `sudo -k` asks for the password
  even with a cached ticket and caches none, so nothing that runs later in the
  terminal inherits root. `install`, `uninstall` and `doctor` set `PATH` to
  `/usr/bin:/bin:/usr/sbin:/sbin` at their entry, so a shim for `awk`, `sed` or `id`
  in a user-writable `PATH` dir (`/opt/homebrew/bin`) cannot change what reaches
  root or what doctor reports; only the unprivileged test suite under a fake root
  puts its stand-ins first. git, sudo, shasum and visudo are also run by absolute
  path (`/usr/bin`, `/usr/sbin`), sudo in doctor and in heals too (the gate's git also
  ignores the system and global git config), and the user config is parsed as
  `KEY=VALUE` lines, never sourced: a sourced config could define a function that
  replaced the gate.
  `--allow-unreviewed` skips the gate (and uses the working tree) and says so in
  the same printout.
- **A plugin update never reaches root code or the app copy.** Claude Code keeps
  the plugin under `${CLAUDE_CONFIG_DIR:-~/.claude}/plugins` and updates it by
  itself (`autoUpdate`). The hooks run from there as the user and only read the
  guard's state. `install`, and an `uninstall` that needs the gate, refuse to run
  from inside that directory (compared by whole path segments after `pwd -P`),
  even with `--allow-unreviewed`: the marketplace clone there would pass the gate,
  so without this an update would become root code at the next `install`. The
  helper, the root-steps copy, the drop-in and the app copy change only through
  `install` from a clone.
- **Updates that change no root code need no sudo.** `install` compares the
  installed helper (with the helper it would render), the root-steps copy (with
  the gate's text) and the owners, modes and ACLs `doctor` checks, and proves the
  root-only drop-in with `sudo -n -l`. When all match it replaces only the app copy
  and the plist; otherwise it prints why it needs root before the question.
  `doctor` and `status` use the same comparison to say which kind of update is due.
- **Uninstall runs the root steps install placed, so it needs no gate.** The one
  `sudo` of `install` also places the root-steps text it runs at
  `/usr/local/libexec/fseventsd-guard-root-steps`: staged, copied root-only
  under a `mktemp` name, checked by SHA-256 (the "root-steps text sha256" install
  prints), then owned by root, opened to 0755 and renamed into place, and rolled
  back with the helper and drop-in. `uninstall` runs it as
  `sudo -k /bin/sh /usr/local/libexec/fseventsd-guard-root-steps uninstall ...`,
  which removes the drop-in first and the copy itself last (only the empty
  directories the install created come after it), so an uninstall cut short runs
  again from the copy.
  The copy is whatever text that install ran as root: the text the gate checked
  against `origin/main`, or, if the install used `--allow-unreviewed`, the working
  tree's, unreviewed (install printed its SHA-256 either way). Only root can change
  the copy since, so running it again adds nothing that install did not already
  run, and needs neither the gate nor a checkout: a teammate on another
  branch, with a stale `origin/main`, without the Command Line Tools' git, or with
  the checkout gone uninstalls from the app copy. Before it runs, uninstall checks
  that the copy is a regular file owned by root, not writable by group or other,
  with no ACL, in directories that pass the helper's checks (as `doctor` checks
  them), and prints its SHA-256 before the y/N question. The copy is not in the
  sudoers rule, so running it still asks for the password: it adds no way to root.
  A copy that fails the check is not run, and an install from
  before the copy existed has none: both fall back to the gate (a reviewed checkout,
  or `--allow-unreviewed`), and uninstall says why.
- **What the gate does not stop.** It catches accidental and unreviewed code (an
  agent's edit, an uncommitted change, an unmerged branch), not a hostile writer
  with the developer's uid. Such a writer can edit the gate itself (it runs from
  the checkout it checks), move the local `origin/main` ref or the `origin` URL in
  `.git`, or wrap the
  terminal through the shell profile; no design that runs from the user's own
  account can close that, and such a writer can make the gate print any ids it
  likes. So the printed ids and hashes only catch accidental changes; against a
  same-uid writer the only check is to install from a fresh clone and compare the
  ids from a different account or machine. `doctor` keeps reporting a helper that
  differs from the checkout.
- **The rule allows no arguments:** `user ALL=(root) NOPASSWD: /usr/local/libexec/fseventsd-guard-restart ""`,
  and names only the user who ran `sudo`: the root steps refuse a rule whose user is
  not `SUDO_USER` (set by sudo, not by the caller), is `ALL`, or is all capitals,
  digits and `_` (a `User_Alias`), and install prints the exact rule line before
  its y/N question.
  The helper also refuses any argument itself (exit 64), resets `PATH` and `IFS`, and
  uses no environment variable for a decision. (`sudo` resets most of the
  environment; macOS's `env_keep` still passes `LANG`, `LC_*`, `TZ` and `HOME`, which
  the helper does not read: README "Known limitations".)
- **The helper decides for itself.** It acts only on the one root-owned process
  named `fseventsd` (`pgrep -x -u 0`, so a user process with that name can neither
  block it nor blind the guard's measurement) that runs as uid 0 with launchd (ppid 1) as parent and whose `ps` comm
  (the process's argv[0], not a verified executable path) is the system fseventsd path, when its footprint is at or above the floor (150 MB) and its own
  rate limit (30 min, root-owned stamp) allows. It re-checks the pid right before
  `kill -TERM`. Worst case for a compromised user account: one fseventsd restart
  per 30 minutes while the daemon is already over 150 MB; while a trial window is
  open (at most 24 h after an install with `--trial-hours`), one restart per 120 s
  at any footprint. The config can set these (it is user-writable), so they are
  minimums: `install` refuses a lower floor or interval, the helper raises a lower
  value in its settings block to them, and install prints each helper setting
  that differs from `config.defaults` as a warning before its y/N question.
- **No swappable parents.** The installer and `doctor` require every directory from
  the helper up to `/` to be root-owned, not group- or world-writable, and without
  any ACL entry (an inheritable `allow add_file,delete_child` entry, such as a
  multi-user Homebrew setup adds to `/usr/local`, grants write whatever the mode
  says). Otherwise a user could rename the directory and drop in another "helper".
  Every directory and file the root steps create gets `chmod -N` before it goes
  live, so an entry inherited from a parent never sticks, and `doctor` flags an ACL
  on the helper, its directories, the drop-in and the root-steps copy. `stat` does not
  follow a symlinked component (`/etc` is one; a `/usr/local` pointing into a
  user-owned tree would be another), so every directory on the path is also
  resolved with `cd -P` and every physical ancestor of where it really is gets the
  same check; the same holds for the sudoers and log directories at install. A
  symlink into a closed root-owned tree (`/etc` -> `/private/etc`) passes. An existing
  directory is never chowned or chmod-ed: if it is not already root-owned and
  closed, install refuses, so nothing planted while it was user-writable survives.
  Missing directories are created by root, one level at a time. (On Intel Macs,
  Homebrew may own parts of `/usr/local`; install then refuses instead of
  installing an escalation path.)
- **No planted names are followed.** The helper, the drop-in and the root-steps copy
  are copied to fresh `mktemp` names and renamed into place; the final paths are
  refused if they are symlinks or not regular files.
- **Nothing can be swapped between check and install.** The one `sudo` runs
  `/bin/sh -c "<text of lib/root-steps.sh>"`, so the root code is in argv, not in a
  user-writable file. The staged helper, drop-in and root-steps text must be regular
  files (not symlinks); they are copied into root-owned places as root-only (0600)
  files and verified by SHA-256 there, and only then opened up (0755 / 0440), so a staged
  path swapped for a link to a root-only file never yields a readable copy. The drop-in is checked with `visudo -cf`
  before sudo (no root needed, verified on macOS 27.0.1), again as root on the
  copy, and the whole policy is checked with `visudo -c -f /etc/sudoers` after it
  is live. Plain `visudo -c` is not used: it also demands mode 0440 of every
  included file, so another tool's 0644 drop-in (which sudo accepts) failed a
  real install on 2026-10-19. Any failure after the helper is in place puts back
  the previous helper, drop-in and root-steps copy, or removes them on a first
  install.
- **Test hooks cannot reach a real install.** The root steps reset `PATH` before
  any command. Test mode exists only unprivileged: running as root, the root steps
  refuse any `--prefix`/`FSG_PREFIX` and any staged helper whose `TOOLS` (stand-in
  tools for the test suite) is set, before they write anything. `install` refuses a
  prefix with `.`/`..` components or one that resolves to `/`, and renders `TOOLS`
  only unprivileged under a prefix. `doctor` fails a real install whose helper has
  `TOOLS` set.
- **Heals run installed code; requests are data.** Every heal runs in the agent from
  the app copy that `install` placed (gated like the root texts), never from a
  checkout's working tree. A heal request is parsed as `KEY=VALUE` lines and each
  value checked against its allowed set; nothing in it is run. Any process with the
  developer's uid can queue a heal, which is what it could do before by running
  `heal`; the helper still decides for itself. The app copy is user-writable, so
  this is about reviewed code, not a privilege boundary.
- **Trial window instead of a second sudo.** The Docker trials must restart a
  healthy daemon several times, which the floor and the rate limit forbid.
  `install --trial-hours N` renders a looser floor (0 MB) and interval (120 s) that
  apply only until a fixed epoch. The window closes by itself, so nobody has to
  remember to undo it. N is at most 24, and the helper ignores a `TRIAL_UNTIL`
  more than 24 h ahead, so a typo cannot open it for years. The end time is
  printed before the sudo prompt; `doctor` warns and `status` shows it while it is
  open.

## 4. When to act

| Tier | Trigger | Action | Value | Why |
|---|---|---|---|---|
| warn | footprint ≥ `FSG_WARN_MB` | notify (renotify after 60 min or when doubled) | 500 MB | healthy was 4-90 MB |
| wave boundary | workflow calls `status` → 1 or 2 | `heal --trigger wave`: a request the agent runs (cap policy abort) | n/a | preferred tier |
| wave back-off | a wave heal gave up at the drain cap < 60 min ago | wave heals exit 11 without draining | 60 min | a never-free machine would otherwise get an hour-long hold at every wave boundary; whether a warn alone should drain at all is an open question (§12) |
| emergency | footprint ≥ `FSG_ACT_MB`, or a **confirmed** stalled probe | the tick's own emergency heal (cap policy proceed) | 2 GB | well above warn, before the machine suffers |
| CPU escalator | footprint ≥ `FSG_WARN_MB` and fseventsd at ≥ `FSG_CPU_ESCALATE_PCT` of one core for `FSG_CPU_ESCALATE_TICKS` ticks in a row | counts as runaway, so as emergency above; `status` says runaway too (a wave boundary drains with the full cap) | 50%, 3 ticks | a runaway pins a core: 1.2 GB at 100% CPU ([claude-code#96008](https://github.com/anthropics/claude-code/issues/96008)) sat between warn and act. macOS's own CPU report fires at 50% over 180 s ([talkstream/fseventsd-runaway@78396ba](https://github.com/talkstream/fseventsd-runaway/tree/78396ba)) |
| emergency interval | last guard restart, last heal attempt that reached the Docker step (or an emergency heal refused there, exit 14, or ended there by a `top` that missed again, exit 3), or the helper's root stamp < 3 h ago | notify only | 10800 s | the original requirements: "at most once per ~3 h", "no restart loops". Counted from the newest of the three, so a wave heal plus an emergency heal cannot loop, and neither can a helper that keeps failing after Docker was stopped, nor a drain repeated every tick for a `--rm` container that keeps running (§6) or on a Mac too loaded for `top` (§5.3) |
| helper floor | helper refuses below | n/a | 150 MB | above healthy (≤ 90 MB), below warn |
| helper interval | helper refuses within | n/a | 1800 s | hard backstop under every tier |
| emergency ceiling | footprint ≥ `FSG_EMERGENCY_CUT_MB` during an emergency drain | stop waiting, proceed | 8 GB | the daemon reached 17 GB on a 96%-full disk; waiting 60 min more risks the machine |

The CPU share is the CPU time fseventsd used since the previous tick divided by the
wall time between the two (`ps -o time`, kept in `tick-sample` in the state dir), an
exact average over the 5 minutes rather than the decayed `ps -o %cpu`. A new pid
starts over, so a restart resets the count. `status` honours the agent's count
only for the same pid and a record younger than two agent intervals.

A stall counts only if a second probe, run right away, also stalls. At load
average 100-300 one slow probe is not evidence. All values are config knobs, to be
calibrated from a few days of logs (open question, §12).

## 5. The drain

### 5.1 The owner's sketch, and what changed

The owner sketched this: a hidden lock file; runners check it and hold while it is
set; running specs finish (cap about 60 min); then stop Docker, restart, start
again, release. The guard keeps that shape and adds what makes it safe on a
machine that is always busy:

| Gap in a bare lock file | What the guard does |
|---|---|
| The guard cannot see which runs are still going, so "when all have finished" is unobservable | Each run holds a **lease** (one file per run). The drain waits for leases, not for time. |
| A run that crashes leaves its marker behind for good | A lease is live only while its pid is alive **and** has the same start time (`ps -o lstart`, read with `LC_ALL=C TZ=UTC0` so a writer and a reader with different locales or time zones agree). A dead or reused pid is reaped automatically. |
| A heal that crashes leaves the lock set and blocks every run | The drain file names its owner (pid + start time) and a deadline. Runners ignore a drain whose owner is gone or whose deadline has passed. The heal refreshes the deadline at every phase from that phase's worst case (its timeouts) plus `FSG_DRAIN_SLACK_S`, so a slow restore never releases held runs early. If the drain file cannot be written at all, the heal stops before Docker (exit 10). |
| Two heals at once both drive Docker and one releases the other's drain | Only the launchd agent heals; callers queue a request (§5.3). launchd never runs two instances of one job, so heals are serialized. The heal lock `heal.lock` (owner record, built under a private name and renamed into place; a stale lock renamed aside and deleted only if it is the one judged stale) stays as the guard against a `tick` run by hand. |
| A heal killed part way leaves Docker stopped, and runners ignore its drain once its owner is dead | A caller cannot kill a heal: killing it only ends its wait. The agent's tick can still be stopped (logout or `bootout`: TERM, then SIGKILL after `ExitTimeOut`). Before the Docker before-step the heal writes a **Docker intent** (`docker-intent`); it is removed only once Docker verified, runners hold behind it on their own (§5.2), and the next tick recovers it first (§5.5). If it cannot be written, the heal stops before Docker (exit 10). |
| Check-then-start races (a run starts just as the drain is set) | Runners write the lease **first** and then check for a drain. The guard marks the drain **first** and then counts leases. One of them always sees the other. |
| A wrapped script calling another wrapped script waits on the drain its parent holds up (deadlock) | Nested acquisitions inherit the outer lease (`FSG_LEASE_FILE`). Leases of the requester and its ancestors (the request's `requester_chain`, pid and start time each) are ignored while the requester waits for the result (§5.3), so a leased workflow that asks for a heal does not wait on itself. |
| Runners are not integrated yet | Fallback detection of unleased work (§5.4), under its own short cap. It cannot hold new unleased runs, so only work that started before the drain counts, and runs that start mid-drain are named as cut. |
| Holding runs for a restart that would be refused anyway | `heal` checks the helper's floor and rate limit (read from the world-readable helper and stamp) **before** it sets the drain. |

### 5.2 Leases (runner side, `lib/lease.sh`)

- `fseventsd-guard run --label L -- CMD` takes a lease and `exec`s CMD. `exec` keeps
  the pid and the start time, so the lease covers CMD's whole run and ends with it.
  No wrapper process stays behind; signals and the exit code go straight to CMD.
- Scripts that cannot be wrapped source `lib/lease.sh` and call
  `fsg_lease_acquire LABEL || exit $?`. If the script ends in `exec` (like a
  `bin/parallel-specs` that ends in `exec bundle exec parallel_rspec`), the lease
  lasts for the exec'd command too.
- A run that meets a pending drain removes its lease, leaves a `PID.held` marker
  (so the heal's fallback detection neither waits for it nor names it as cut) and
  waits, printing
  `holding '<label>' while fseventsd is healed (phase, reason); waited Ns` at once
  and every minute. It starts by itself when the drain ends.
- A heal's unverified Docker intent (§5.5) holds runs the same way, read by the
  runner itself, so it holds even when the tick that wrote it was killed outright
  and no tick runs again (phase `docker-not-verified`): for variants A and B from
  the intent's start (their before-step stops Docker), for any variant from its
  after-step action (`action_epoch`), for at most `FSG_FAILED_HOLD_S` after that
  time (the shorter of the run's and the agent's, `hold_s`), and only while the intent stands: it goes once Docker verified, at expiry,
  or when `fseventsd-guard release` clears it. A variant C intent whose restart has not run, and skip or none, hold
  nothing: Docker has not been touched.
- Max wait: `FSG_RUN_MAX_WAIT_S` (default 0 = until the drain's own deadline).
  At the limit, `FSG_RUN_ON_TIMEOUT=fail` (default) returns 75 (EX_TEMPFAIL), and
  `proceed` starts anyway.
- It never blocks a run because of its own problems. If the state directory cannot
  be created or the start time cannot be read, the run goes ahead.
  `FSG_DISABLE=1` turns it off. Where the guard is not installed (no app copy, as
  after `uninstall`) it takes no lease and writes nothing, so a wrapped run never
  re-creates the state directory with a lease nothing would reap.

### 5.3 Heal requests and the tick (`lib/request.sh`, `lib/heal.sh`)

Only the launchd agent runs heals (owner, 2026-10-20). A caller that is killed (a
`timeout -k`, Ctrl-C, a closed terminal) therefore cannot leave Docker stopped or
release runs onto it, and no heal ever takes over another heal's Docker step.

**The caller.** `heal --trigger wave|manual` and `trial` check their options, then:

1. Check that the agent can take a request: its plist and app copy exist, it is
   loaded (`launchctl print gui/<uid>/io.github.ruslantar.fseventsd-guard`), and the app
   copy speaks the caller's request protocol (`FSG_REQUEST_PROTOCOL` in its
   `lib/common.sh`). Otherwise exit 9, naming the fix: `launchctl bootstrap
   gui/<uid> <plist>`, switching the agent back on in Login Items, or `install`.
   There is no in-process fallback, so `install --no-agent` leaves nothing that heals.
2. Write `requests/<id>.req` in the state dir under a temp name and `mv` it into
   place. The id is the UTC time plus the requester's pid (zero-padded), so names
   sort in request order. Fields: `id`, `trigger` (wave|manual|trial), `drain_cap` (`--drain-cap`,
   else the caller's `FSG_DRAIN_CAP_S`), `on_cap` (`--on-cap`, else the trigger's
   policy; a trial's is always abort), `docker_variant` (`--docker-variant` or the trial's `--variant`, else the
   caller's `FSG_DOCKER_VARIANT`), `force`, `trial_label`, `requester_pid`,
   `requester_lstart`, `requester_chain` (pid:lstart of the requester and each of its
   ancestors), `requester_waits` (0 with `--no-wait`, else 1) and `time`. These are
   the only per-call settings. Every other knob is
   the agent's config, so an `FSG_*` exported in the caller's shell no longer reaches
   the heal. If the file cannot be written: exit 10.
3. Run `launchctl kickstart gui/<uid>/io.github.ruslantar.fseventsd-guard` without `-k`.
   Without `-k`, kickstart never kills a running tick, and launchd never runs two
   instances of one job, so ticks are serialized for free; a tick that is already
   running picks the request up in its loop (tick step 6). While the request is
   unclaimed and no tick runs (heartbeat), the caller kicks again, at most every
   10 s. That closes the gap of a tick that was just finishing when the request
   landed.
4. Wait for `requests/<id>.result` (`exit`, `summary`, `record`), printing the new
   lines of `requests/<id>.log` (what the heal prints: drain progress, phases, the
   result line) as they arrive; then print the summary and exit with `exit`.

The caller holds nothing, so it may be killed at any point and the heal goes on;
only the requester's exemption ends (below). Ctrl-C prints how to re-attach.
`--no-wait` returns after step 3 with the id on stdout (exit 12). `heal --result
ID` re-attaches: it streams and waits as in step 4, or with `--no-wait` exits 12
while the request is queued or running (an unknown id is 64, a withdrawn one 10). A request that stays unclaimed for 2 ×
`FSG_AGENT_INTERVAL_S` while no tick runs (no running heartbeat and no live heal-lock
owner), although the agent is loaded (its ticks fail, for example on a full disk), is
withdrawn by renaming it (a tick that claimed it first wins, and the wait goes on),
and the caller exits 10. That clock starts when the caller starts waiting (also on
`heal --result`) and restarts whenever it sees a tick run, so a request queued behind
another request's heal, the emergency heal or a recovery waits however long that
drains, then is joined, run or refused. Ticks that run but never claim it (their
rename fails) keep restarting that clock, so a request still unclaimed
`FSG_REQUEST_MAX_AGE_S` after it was written, the age at which the agent would drop
it, is withdrawn the same way. A claimed request whose tick is gone without
a result (killed outright, so no trap wrote its 130) is the next tick's to end with
130; until then the caller kicks the agent at most every 10 s, and it stops waiting
with 130 and the re-attach hint when the agent is not ready (unloaded, switched off)
or no tick ran for 2 × `FSG_AGENT_INTERVAL_S`.
**The requester's exemption.** A leased workflow that asks for a heal must not wait
on its own lease, so the heal leaves out the leases and processes of the requester
and its ancestors (`requester_chain`), but only while the requester waits: its
request says it waits (`requester_waits=1`) and the requester (pid and start time)
is alive. The heal re-checks that at every drain scan. Once the requester is gone (a
`timeout`, Ctrl-C, a closed terminal) or never waited (`--no-wait`), its chain's
leases count like any other: a lease taken before the drain holds it up to the cap,
where a wave or manual heal gives up (exit 4) rather than cut it. A workflow whose
wait ended may have started its wave under that lease, and nested runs inherit the
lease without waiting (§5.2), so cutting it would stop Docker under the wave. The
heal says so in its output and log, and the requester is told as it stops waiting
(or on `--no-wait`) that its leases now hold the heal. A re-attached `heal --result`
is not the requester and exempts nothing. The exemption does not come back, and a
drain that ended under it is not undone: a requester stopped after the drain, during
the Docker step, leaves its workflow free to start against a stopped Docker
(`docs/WORKFLOW-INTEGRATION.md`: do not start the wave before a final code). An
older request without `requester_waits` exempts nothing; `FSG_REQUEST_PROTOCOL` 2
makes callers refuse an agent that would exempt for the whole request.

`heal --dry-run` stays in the caller and read-only; it also shows the queue.
`heal --trigger emergency|trial` is a usage error (64): emergency heals are the
agent's own decision, and trials go through `trial`. So is `trial --no-wait`: a trial
whose requester is gone is dropped.

**The tick.** launchd starts `fseventsd-guard tick` every `FSG_AGENT_INTERVAL_S`, at
load and on a kickstart, never twice at once. In order:

1. Take the heal lock for the whole run. A lock held by a live process (a `tick` run
   by hand) ends this tick at once: that tick serves the queue. A lock that cannot
   be created (disk full) ends it too; queued callers then end with 10 as above. Set
   the EXIT and INT/TERM/HUP traps, which cover the recovery as well as a heal (§5.5).
2. Recover the Docker intent a previous tick left (§5.5), then run the hold check
   (§6). Every heal runs in the agent, so an intent is always an earlier tick's.
3. Give each request that a previous tick claimed and never finished (that tick is
   gone) the result 130 (interrupted), naming the recovery's outcome. It is not run
   again.
4. Run the queued requests, oldest first. The tick claims one by renaming `.req` to
   `.run` and adding its own pid and start time. Each ends in one of:
   - **dropped** (13): a trial whose requester is gone (pid and start time), or any
     request older than `FSG_REQUEST_MAX_AGE_S` (2 h, longer than a whole heal; it
     was queued while the agent was unloaded or the user logged out). A heal request
     whose requester is gone still runs: the heal is about the machine, not the
     caller.
   - **invalid** (64): a field outside its allowed set; nothing in it is run.
   - **joined**: a wave or manual request without `--force`, when a heal that
     reached its Docker step ended after the request was written, in a later second
     (within one second the order is unknown, so such a request runs) and the newest
     `last-heal` is healed, restart-failed or restored-partly. Its result is that
     heal's code (0, 7 or 8) and record. A second drain right after it would hold
     every run again for nothing, or bounce Docker again after a failed restart.
   - **refused** (8) while an earlier heal's Docker intent stays unverified (§5.5).
     Nothing is held or stopped; the summary names the intent and the ways out
     (Docker verifies at a later pass, `release`, or the intent expires).
   - **run**: the heal (below), or the trial. For a trial the tick writes
     `before.txt`, runs the heal with its output going straight to `heal.out`, which
     the request log links to, then writes `after.txt`, the Docker Desktop logs and
     `summary.txt`.
     Inside the tick, heal paths return their code instead of calling `exit`.
5. The emergency check (§4), once per tick, its `top` sample tried again when it
   does not answer in time (below). It does not heal while an earlier intent
   stays unverified; it notifies instead (throttled).
6. Back to step 4 while a request is queued. Then release the lock, write the
   heartbeat, and exit with the level or the emergency heal's code (§2).

The newest 20 finished requests (`.run`, `.log`, `.result`) are kept.

**Measuring on a loaded Mac.** A runaway comes with a busy machine, and no heal runs
without a measurement, so a `top` that misses `FSG_TOP_TIMEOUT_S` (15 s) must not
blind the agent at once. Two parts:

- The plist sets `ProcessType` to `Interactive`. Without one, launchd applies "light
  resource limits" that throttle the job's CPU and I/O (launchd.plist(5)). Measured
  with temporary agents at load average 107-131 on macOS 27.0.1: unset or
  `Standard` ran the job as spawn type daemon at priority 20, and its `top` took
  10-27 s, often past 15 s; `Interactive` ran it at priority 31, and `top` took
  1.3-1.5 s. `Adaptive` (priority 4 for a job without XPC transactions) and
  `Background` (priority 4) were slower still: no `top` result in 40 s. The cost: a
  tick, and any heal it runs, competes at app priority; a tick is short and a drain
  mostly sleeps. The root helper runs under `sudo` as the tick's child, so it most
  likely gets the same priority (inferred, not checked: it needs sudo). `install`
  writes the plist, so an older install gets the key when `install` runs again;
  until then `doctor` warns.
- The agent's emergency check (step 5) and a heal's precheck, so every heal (also
  `heal --dry-run`), try a `top` that did not answer up to `FSG_MEASURE_TRIES` (3)
  times in all, `FSG_MEASURE_RETRY_S` (5 s) apart: about a minute at most. Each
  slow try is logged (`MEASURE top did not answer within 15s (try 1 of 3)`). Any
  other failure (no fseventsd, two of them, an unreadable footprint) is final at
  once. After the last try the reason gives the number of tries and the daemon's
  resident size from `ps -o rss`, a lower bound on the footprint (it leaves out
  compressed and swapped pages), for the log and the notices; no decision uses it
  (`footprint -p` as the user fails). A blind tick counts once toward
  `FSG_BLIND_NOTIFY_TICKS`, whatever its tries. `status`, the hooks, and the
  measurements inside a heal (the healthy wait, which polls anyway, the verify
  step, and the drain's emergency ceiling) try once.
- A heal whose precheck needed more than one try takes one more `top`, a single
  try, right before its Docker step: after the drain and the `--rm` volume checks,
  before the Docker intent, and only when that step acts on Docker (B, C, or A with
  containers to stop; not `none`, nor a Docker that is stopped or not local). The
  root helper takes one `top` sample of its own, bounded at 15 s and not tried
  again, and refuses (70) when it misses, after the Docker step ran; this check
  keeps that from bouncing Docker for nothing on a Mac that has just missed. When
  this `top` misses too, the heal ends with exit 3 and Docker untouched: logged
  (`HEAL busy: top missed again before the Docker step; Docker left alone`),
  recorded as `refused-cannot-measure`, a `cannot heal` notice (cannot measure)
  naming that reason, and the drain ends as after the refusals before it (exit 14).
  Like those, an emergency heal ending here counts as an attempt (the emergency
  interval), else the agent would drain again every tick while the Mac stays
  loaded; a precheck that cannot measure ends before the drain and does not count.
  When it answers, or fails another way (the helper checks for itself), the heal
  goes on unchanged; its measurement is logged only. A precheck that answered at
  once measures no more. The helper can still miss after this check answered.

Tests install with `--prefix` and the stub `launchctl`: `bootstrap` marks the agent
loaded, `bootout` unloads it (heal and trial then exit 9), and `kickstart` starts the
app copy's `tick` in the background and in a session of its own, unless the stub's
previous tick still runs, as launchd would, so a signal to the caller's process
group (`timeout -k`) does not reach it. Like launchd, it does not pass on the caller's environment: the tick
gets only the plist's `PATH` and `FSG_STATE_DIR`, the test's fake paths, and the
agent knobs the test lists for it, so a test catches a heal that depends on a
caller's `FSG_*`.

**One heal**, run by the tick under the heal lock:

```
precheck (helper would accept?) ──no──▶ 6 or 9, nothing held
   │yes      wave back-off ──▶ 11, nothing held
drain/pending phase=draining (a hold in place is saved aside, §5.5)
   │ ──▶ wait for work started before the drain:
   │          leases (up to FSG_DRAIN_CAP_S) + unleased processes and exec
   │          sessions (up to FSG_UNLEASED_CAP_S); interactive sessions never;
   │          reaping dead leases each poll (15 s)
   │          a cap reached ──▶ policy abort: saved hold back, notify, 4
   │                        └▶ policy proceed: notify which runs are cut
   │          drained with mid-drain starts ──▶ notify which runs are cut
   ▼
phase=docker-before (--rm volume checks ──▶ 14; precheck needed a second top:
   │          one more, missed ──▶ 3; nothing stopped)
   │ docker-intent written; cannot ──▶ 10, nothing stopped
   ─▶ phase=restarting (sudo -n helper) ─▶ phase=waiting-healthy
   ─▶ phase=docker-after (always, even if the restart failed) ─▶ phase=verifying
   ─▶ Docker verified: release the drain, notify, record
   └▶ Docker not verified: hold (no owner; until Docker verified, release, or FSG_FAILED_HOLD_S)
```

Held runs are released only onto a **verified** Docker: the engine answers, every
recorded container runs (healthy when it was healthy before the heal) and the
bind-mount round trip works. That holds on every path: a restart, a failed restart, helper exit 73, and a
heal stopped part way. Running the after-step is not enough.

The helper sends SIGKILL when the same genuine daemon still runs 10 s after
SIGTERM (identity checked again first), then waits up to 30 s, as launchd may
throttle the respawn after a KILL. A restart that needed it exits 72: the heal goes
on as after exit 0, and logs, records and notifies that SIGKILL was needed. Not seen
yet: on the reports so far SIGTERM was enough.

On helper exit 73 (signal sent, no new daemon within its wait) the heal keeps
waiting for a new, healthy fseventsd (`FSG_HEALTHY_TIMEOUT_S`) before the Docker
after-step. If one appears, the heal goes on as after a restart and can end healed;
if not, it ends as a failed restart (exit 7), with Docker verified or runs held.

Cap policy by trigger: `emergency` uses `FSG_CAP_POLICY_EMERGENCY=proceed`. By
then file watching is broken for everyone, and the owner leans to "stop and heal".
`wave`, `manual` and `trial` use `FSG_CAP_POLICY_MANUAL=abort`, because a person
or workflow is there to retry. `--on-cap` overrides per request.

### 5.4 Unleased work (fallback while runners are not integrated)

Treated as live work during a drain, each configurable:

- **Processes** (`FSG_DETECT_PROCESSES=1`) whose command, or the command after a
  launcher, has a base name in `FSG_DETECT_COMMANDS` (`rspec parallel_rspec
  parallel_test`). Launchers: `ruby bundle exec timeout gtimeout rtk env bash sh zsh
  nice nohup time caffeinate`. Option words, numbers and `VAR=value` words are
  skipped. So `ruby bin/rspec`, `timeout 9000 bin/parallel_rspec`, `rtk rspec`,
  `bundle exec rspec` and `env RAILS_ENV=test bundle exec rspec` match, and
  `rg -n rspec` or `vim spec/rspec_helper.rb` do not. A project's own runner
  (say `bin/parallel-specs`) matches once its name is added to
  `FSG_DETECT_COMMANDS` in the user config; better, it takes a lease (§5.2).
- **Docker CLIs** (`FSG_DETECT_DOCKER_CLI=1`): `docker run|exec`, and
  `docker compose ... run|exec` (also `docker-compose`). `docker ps`, `docker compose
  up` and friends are not live work.
- **Exec sessions** (`FSG_DETECT_DOCKER_EXECS=1`): each exec session in a running
  container (`ExecIDs`), on a local engine only (§6): an engine that is not local
  is not listed, since the heal does not touch it.
- **`--rm` and one-off containers** (`FSG_DETECT_DOCKER_CONTAINERS=1`): each running
  container with `HostConfig.AutoRemove` (Docker deletes it, and its anonymous
  volumes, when it stops) or the label `com.docker.compose.oneoff=True` (`docker
  compose run`; a heal never starts it again, §6), from the same listing as the exec
  sessions and on a local engine only. They usually end by themselves, so they are
  waited for like the other unleased work; their start comes from `State.StartedAt`.
  A container whose `docker run` or `docker compose run` CLI is attached is also
  listed as that process, so it shows twice. A long-lived one (a `docker run --rm`
  dev database, a `compose run --service-ports` dev server) holds every drain to
  `FSG_UNLEASED_CAP_S`.
- A run and its workers are one item: a match whose ancestor also matched is
  counted under the topmost match (`parallel_rspec (+10 child processes)`).
  Processes that belong to a lease holder, a run held by the drain (its `PID.held`
  marker), the tick and its descendants, and, while the requester waits (§5.3), the
  requester and its ancestors (the request's `requester_chain`) are left out.

Unleased work holds a drain on different terms than a lease, because nothing holds
new unleased runs:

- **Only work that started before the drain counts.** A process's start comes from
  `ps etime` (whole seconds, 2 s of slack); an exec session, which has no start
  time, counts when the drain's first scan whose exec listing worked (`docker ps`
  and `docker inspect` answered within 15 s) listed it, so a listing that times out
  under load cannot make the sessions running then look started mid-drain. Work
  that starts later never holds the drain; at the restart it is named as cut
  (`started mid-drain`). A lease written after the drain began is a run about to
  wait; one still there at the next scan (`FSG_RUN_ON_TIMEOUT=proceed`) is named the
  same way. So is an exec session listed since: only once the next scan lists it
  too, because a healthcheck probe (`pg_isready`, `redis-cli ping`) is an exec
  session that ends within a poll.
- **Its own cap**, `FSG_UNLEASED_CAP_S` (600 s, never more than the drain cap). Past
  it only leases hold the drain; at that point, if no lease is left, the cap policy
  applies as at `FSG_DRAIN_CAP_S`. Without this every drain on a busy machine would
  end at the 60-minute cap and cut the same runs anyway.
- **Engine work that cannot be listed is unknown, not absent.** When `docker ps` or
  `docker inspect` fails or times out (15 s each), the scan cannot tell whether exec
  sessions or `--rm` and one-off containers run, so the drain keeps waiting, as for
  unleased work: until a scan lists them, or `FSG_UNLEASED_CAP_S`. Then the cap
  policy applies, and the give-up or `cutting running work` notice says they were
  unknown (`drain_exec_unknown=1` in the heal record; `status` shows it among what
  the drain waits for). A daemon that refuses the connection (`Cannot connect to the
  Docker daemon`: Docker Desktop stopped or still starting) runs nothing and counts
  as no work. Unknown holds only while the engine answers `docker info`, asked
  (within `FSG_DOCKER_QUERY_TIMEOUT_S`) after the failed listing. An engine that
  answers nothing is wedged (§6, the silent state the Docker step detects), the
  failure the heal is for: waiting for its listing would only hold that heal to
  `FSG_UNLEASED_CAP_S`, after which a manual or wave heal would give up (exit 4). So
  its own work counts as none, and its exec sessions and `--rm` and one-off
  containers are cut; the `docker exec`/`run`/`compose` CLI processes that drive
  work in it still show in the process scan and are waited for. Such a scan seeds
  no pre-drain exec sessions, so sessions listed once the engine answers again
  still count as started before the drain.
- **Interactive sessions are never waited for**: a `docker exec` or `docker compose
  exec` CLI that has a TTY (`-t`, or compose without `-T`) and a terminal, and an
  exec session whose engine record (`GET /exec/ID/json` over the engine socket, with
  curl: the CLI cannot inspect an exec) has a TTY, in both cases only when the
  command is a shell or console: its first word after the launchers has a base name
  in `FSG_INTERACTIVE_COMMANDS` (`sh bash zsh psql rails:console rails:c irb
  redis-cli`; `prog:sub` needs that first argument) and no word is in
  `FSG_DETECT_COMMANDS`. So `docker compose exec api bundle exec rspec`, `bash -c
  "bundle exec rspec"` or `bin/rails db:migrate` with a TTY are work. An exec
  session with an open stdin and no TTY is also left alone: an exec that pipes stdin
  from a script is live work on the CLI side. If the engine API does not answer, the
  session counts as work. They are named as "left alone" in the notices and lose
  their connection at the restart.
- The `healing` notification, the cap notices and `status` (from `drain/blockers`,
  written each poll) name the items: command, pid and age.
- **Not** live work: dev servers (`rails s`, sidekiq, `next dev`). They would hold
  every drain to the cap. They reconnect after the restore. Test suites that mock
  HTTP (Vitest with MSW, for example) need no Docker.
- A long-term option, not built: count active connections to your test databases in
  `pg_stat_activity`. It would see test runs started from an IDE.

### 5.5 Interrupted heals: the Docker intent and its recovery

The heal writes `docker-intent` in the state dir before the Docker before-step:
owner (the tick's pid and start time), request id, trigger, variant, the recorded
Docker kind and state, the engine endpoint it pinned (§6), the restore set (ids and names), `action_ran` and its time,
`engine_done`, `after_done`, `fails` (`name:count:epoch`: failed passes per container and when the last counted), `hold_epoch`, `hold_s`
(the agent's `FSG_FAILED_HOLD_S`, for runners, §5.2) and the heal record. It is removed only once Docker verified, by `release`, or when it
expires. `status` (`docker_intent`), `doctor` and `heal --dry-run` show it.

**Signals.** One EXIT and INT/TERM/HUP trap covers the whole tick, so a recovery is
stopped as safely as a heal. On a signal while an intent stands unverified (a heal
past its Docker before-step, or any recovery pass), the trap first makes sure runs
are held (it puts the saved hold back, or writes a hold), so a second signal or
launchd's SIGKILL cannot release them onto a Docker nobody checked. A signal ends
the tick's wait for a bounded call at once, but not the call: launchd signals only
the tick, so a `docker desktop stop|start|restart` or the `sudo -n` helper it
interrupted goes on. The trap therefore next waits for that call to end, under its
own bound (`FSG_DOCKER_TIMEOUT_S` + 10 s, `FSG_HELPER_TIMEOUT_S`), and never kills
it: a root restart or a Docker Desktop stop is not cut in half, and no restore runs
beside it. A helper that finished is logged and stamped as a restart like one the
heal saw end; a Desktop stop that finished is followed by the start. Then the trap
runs the after-step's Docker action if that has not run, verifies, and lifts the
hold only if that passes; otherwise it notifies `heal interrupted`. The one exception is a
recovery stopped while it still waits for runs before C's Docker Desktop restart:
that restart is left to the next tick, which waits again. A heal stopped before its
Docker before-step only gets its saved hold back, or its drain ended. Either way the
running request gets result 130 (its heal's own code if that heal had already
returned) and the lock is released. The plist sets
`ExitTimeOut` to 3 × `FSG_DOCKER_TIMEOUT_S` + 180 s plus the longest single bounded
call (the larger of `FSG_HELPER_TIMEOUT_S` and `FSG_DOCKER_TIMEOUT_S` + 10 s), the
time that wait and restore can take, but launchd does not grant it: it caps a user
agent's exit timeout at 60 s. Measured on macOS 27.0.1 (26A434) with temporary
agents: 30, 59 and 60 read back as such in `launchctl print`, 61, 120 and 1390 as
60 (1390 also with `ProcessType` Interactive, Adaptive or Background), and no value
as 5 s (launchd.plist(5) says only "system-defined"). An agent with 1390 that
ignored SIGTERM was SIGKILLed exactly 60 s after `launchctl bootout`, which itself
returned at once. So a restore that outlasts that minute is cut off; the intent and
the next tick then recover Docker (below), as after any SIGKILL. `doctor` reports
the value launchd uses when it is below the plist's. `install` refuses to reload
the agent while a heal is in progress. A SIGKILL runs no trap: the intent and a
hold saved aside (`drain/pending.saved.<pid>`) stay, and the next tick puts that hold back (unless a
live drain or hold is in place) before it recovers. Until then leased runs hold
behind the intent itself (§5.2), so they do not start against the Docker the killed
tick stopped, even if no tick runs again.

**A standing hold survives a drain.** A heal's drain and a recovery's drain replace
`drain/pending`. A hold already in place (Docker not verified after an earlier heal,
or a trial's) is copied aside first and comes back when that drain ends, unless the
drain's own Docker verified; a trial's hold comes back even then, since only the
operator releases it. So a heal that gives up at the cap (4), is stopped while
draining, or cannot write its intent (10) no longer deletes the hold. A heal that
ends not verified writes its own hold, which keeps `trigger=trial` when the saved
one was a trial's.

**The recovery pass** (tick step 2, once per tick):

1. **Expiry.** An intent whose Docker action ran more than `FSG_FAILED_HOLD_S` ago is
   removed and notified once ("Docker not verified after heal ...; the guard stops
   restoring it"); the hold it set ends at about the same time. An old intent so
   never drives Docker again, for example to start a Docker Desktop the user quit
   later. An intent whose action never ran does not expire: this pass runs it.
2. **Hold.** If no hold is in place, write one, once per intent (`hold_epoch`):
   runners ignore the previous tick's drain, because its owner is dead, and the
   intent alone holds them only for its `FSG_FAILED_HOLD_S` and not before C's
   restart (§5.2).
2a. **Endpoint.** The endpoint resolved now (§6) must be the intent's `endpoint`, a
   local socket with the same physical path (Desktop's `default` and `desktop-linux`
   contexts match; a stopped Docker Desktop may have no socket yet); it is then pinned.
   Otherwise (another context, a remote one, or an intent without the field) the pass
   refuses: Docker is left alone, the intent and the hold stay, and `Docker not
   restored` (the Docker endpoint changed) is notified once per
   `FSG_WARN_RENOTIFY_MIN`, until that engine is selected again, `release`, or the
   expiry. The trap's pass checks the same. An intent whose Docker was stopped or not
   local has nothing to act on and skips the check. The hold records the endpoint too,
   and the hold check releases no hold while another endpoint is selected.
3. **The Docker action**, by the intent's state:
   - `action_ran=0`: the variant's after-step action. `action_ran=1` is written
     before the action starts, so a stop during it never repeats it. Before C's
     Docker Desktop restart the pass marks a drain of its own (the hold saved aside)
     and waits for runs leased since, with the emergency policy (proceed at
     `FSG_DRAIN_CAP_S`), naming what it cuts. A and B only start what is down and
     need no wait.
   - `action_ran=1`, `engine_done=0` (the engine has not answered since the
     action): `docker desktop start` again, where Docker Desktop is the engine. It is
     idempotent; C's restart never runs a second time for one intent.
   - `engine_done=1`: no Docker action. A Docker that stopped after it answered was
     stopped by someone else, and stays stopped.

   `engine_done=1` is written only when the engine answered after the action: in
   the heal, the trap and the recovery alike.
4. **Containers.** Each container in the restore set that is not running is started,
   by name (compose may have recreated it under the same name with a new id; the id
   is used only when no name was recorded or only the id still exists). A container
   that is not back within `FSG_CONTAINER_TIMEOUT_S` (running, and healthy when it
   was healthy before the heal) fails the verify. It counts a failure only when the engine answers
   and says it is gone (`No such container`; `docker inspect` exits 1 for a daemon
   it cannot reach too) or not running, and at most one per `FSG_AGENT_INTERVAL_S`,
   because callers kick ticks seconds apart; the heal's own after-step can count the
   first. A container that was healthy before the heal and runs but is not healthy
   yet (postgres after a Docker Desktop restart) never counts: it holds runs until
   it is healthy or the intent expires. One that was unhealthy or starting before
   the heal (a health check that fails for its own reasons) only needs to run: its
   health is not the heal's to fix, and requiring it would hold runs for the whole
   `FSG_FAILED_HOLD_S` after every heal. The record keeps each container's health
   (`health=` in `docker-before.txt`, `restore_health=` in the intent and the
   hold); an intent or hold without it, from an older guard, needs every container
   healthy when it has a check. At 2 failures the container is dropped from the set and named in the
   notification (left as it is; start it by hand), so one container that will not
   start cannot hold runs until the expiry. A pass in which it is back resets its
   count. This replaces the `gone=` list.
5. **Verify** against what is left of the set. Verified: the intent is removed, the
   hold released (not a trial's) and `Docker restored` (or `held runs released`)
   notified. Not verified: the hold stays; `heal interrupted` is notified on the
   first pass, and later passes only log.

**Removed with this model:**

- `fsg_intent_adopt`, the takeover of a dead heal's restore set and variant by the
  next heal. It carried a failing container into every later heal, re-added gone
  ones, and could start a Docker Desktop the user had quit. An unverified intent now
  refuses new heals (exit 8) until it verifies, is released or expires.
- The recovery at every heal start in the caller, `FSG_RECOVER_DONE`, and its
  deferral to the agent during the wave back-off.
- The trial's `fsg_cmd_heal ... | tee` pipeline subshell, whose lock, drain and intent
  named the trial's parent process.
- The wave back-off after a wave heal stopped by a signal while draining
  (`fsg_stale_wave_drain`, `HEAL_SIGNALLED`): a caller can no longer stop a heal, so
  exit 11 now means only "gave up at the cap".
- Every heal-lock taker other than the tick: the caller's lock attempt with exit 5
  on a busy lock, and the recovery's own lock. The lock code itself stays.

## 6. Docker step

| Variant | Before the restart | After the restart |
|---|---|---|
| A containers only | record running IDs; `docker stop -t 30` them | `docker start` the same IDs |
| B quit Docker (default until the trials) | record IDs; `docker desktop stop` (wait until it stopped, below) | `docker desktop start`; wait for the engine; start recorded IDs not already running |
| C restart Docker after | nothing | `docker desktop restart`; wait for the engine; start recorded IDs not running |
| none | nothing | nothing (the naive restart; trial step 0) |

- **B is the default** until the trials pick a winner. The owner reports Docker
  "hard fails every time" on a naive restart and "doesn't cleanly heal". Quitting
  Docker first is the variant most likely to avoid both, because no file-sharing
  process holds FSEvents streams across the restart. Change `FSG_DOCKER_VARIANT`
  after the trials.
- **B's stop check.** Docker Desktop counts as stopped when no Desktop process runs
  and its backend socket (`~/Library/Containers/com.docker.docker/Data/backend.sock`)
  and user socket are gone, or when `docker desktop status` says `stopped`. Once
  Desktop has quit, status fails only after ~16 s (it dials the missing backend
  socket), so processes and sockets are polled every second and status, bounded to
  3 s, only when they do not decide. The wait is `FSG_DESKTOP_STOP_WAIT_S` (60 s)
  counted from the stop call, which itself takes 13-18 s. The stop's exit code and
  time, every poll and the decision go to the heal record (`docker-stop.txt`,
  `docker_stop=` in `result.txt`). A backend that appears with a new pid during the
  heal was started by something else (another session's `open -a Docker`): the
  guard says so in the record and the notice instead of reporting a failed stop,
  does not stop it again, and restores as usual.
- `--rm` containers (`HostConfig.AutoRemove`) are recorded but left out of the
  restore set: Docker deletes them when they stop, so `docker start` would fail and
  every such heal would end in exit 8. The drain waits for them first, like other
  unleased work (§5.4).
- **A heal does not delete a `--rm` container's anonymous volume.** With Docker
  answering, no container or Docker Desktop is stopped unless every running
  container was listed and none has an anonymous volume; only a wedged engine is
  acted on unchecked, and that is named (the next points). When Docker
  removes a `--rm` container (stopped by A, or by B's Docker Desktop stop or C's
  restart, where the daemon removes it as it exits or when it starts again), it also
  removes the container's anonymous volumes: those its own spec gave no name (an
  image `VOLUME` such as postgres's data directory, `-v /path`, `--mount
  type=volume` without a source). Named volumes stay (`docker run` reference, "Clean
  up (--rm)"). The record reads each container's mounts and its spec
  (`HostConfig.Binds`, `HostConfig.Mounts`); a volume mount whose name the spec does
  not give is anonymous. A volume inherited with `--volumes-from` counts as
  anonymous too, so such a container is protected even when its volume would
  survive. If any running `--rm` container has one when the drain ends and the
  variant stops containers (A, B, C; not `none`, nor a stopped or non-local Docker),
  the heal stops there with exit 14, before the Docker intent, any Docker action or
  the restart: nothing is stopped, the drain ends (a hold kept aside comes back),
  and `heal refused` names each container and the mount points it would lose
  (`result=refused-anonymous-volumes`, `containers_rm_anonymous_volumes=` in the
  heal record). The `healing` notification already names such containers, from the
  precheck's record, and `heal --dry-run` does too. An emergency heal refused this
  way counts against the emergency interval (§4), so the agent does not drain again
  every tick for a container that keeps running.
- **No override (owner decision, 2026-10-23).** There is deliberately no flag that
  lets a heal delete a `--rm` container's anonymous volume: to proceed, the user
  stops that container (`docker stop NAME`) and heals again.
- Other `--rm` containers (no anonymous volume) are stopped. The `healing`
  notification names them as removed if still running at the Docker step, the
  `cutting running work` notice names them again just before the Docker step stops
  them, and the result notification and the heal record name them as not
  restorable.
- **A failed listing is not an empty one.** When the heal's record could not list
  the containers or read their settings (`docker ps` or `docker inspect` failed or
  timed out, or `docker inspect` failed for a container that `docker ps` still lists
  as running: `listed=0` in `docker-before.txt`) and the variant stops containers or
  Docker Desktop (A, B, C), the heal asks `docker info`. If Docker answers, the heal
  refuses the same way: exit 14 before the Docker intent, any Docker action or the
  restart (`result=refused-unlisted`), `heal refused` says Docker could not list its
  containers so their volumes could not be checked, `heal --dry-run` says so too,
  and an emergency refusal counts against the emergency interval. A refuses even
  when `docker ps` failed and it would stop nothing, which would make it the naive
  restart. Only a wedged engine, one that does not answer `docker info` either (the
  failure being healed), is acted on without the check: the `cutting running work`
  notice says so before the Docker step, and the log, the result notification and
  the heal record (`docker_restart_unchecked=`) name a step that stopped containers
  or Docker Desktop that way. C stops nothing before the restart and checks again
  right before it (next point).
- Variant C restarts Docker Desktop minutes after that check, so its after-step
  asks `docker info` and lists the containers again right before the restart. It
  skips the restart if a `--rm` container with an anonymous volume runs by then (one
  started meanwhile), and also when that listing fails (`docker ps` or `docker
  inspect`) while Docker answers `docker info`: a failed listing is not an empty
  one. The heal then ends 8 with runs held until the agent verifies Docker as it is,
  and its notice gives the reason. Only a wedged engine, one that does not answer
  `docker info` either (the failure C heals), is restarted without the check; it is
  not listed, so the check costs it one `docker info` timeout. The log, the result
  notification and the heal record (`docker_restart_unchecked=`) name such a
  restart. The recovery and the EXIT trap run the same after-step, and their
  notices name a restart it skipped or ran unchecked. Neither runs a before-step
  again: A's and B's after-steps only start Docker and containers.
- One-off containers (`docker compose run`, label `com.docker.compose.oneoff=True`)
  are recorded but left out of the restore set too: `docker start` would run their
  command again from the start, detached, with nobody attached (a second test run
  on the shared test database, a repeated `db:seed`). The drain waits for them first
  (§5.4); A, B and C then stop them like any other container and never start them;
  the result notification and the heal record
  (`containers_not_restored_oneoff=`) name them as not restored (one-off). One that
  is also `--rm` is named as `--rm`. When `docker inspect` cannot be read at all,
  every running container counts as restorable, as before; a container that exited
  between `docker ps` and `docker inspect` fails the inspect for itself only. When
  the inspect fails for some containers, the guard lists the running ones again
  (`docker ps -q`): if one it could not read still runs, or that listing fails, the
  listing is incomplete (`listed=0`, above).
- Restart policies matter. `docker stop` marks an `unless-stopped` container as
  stopped by hand, so after A or B the guard starts the recorded IDs explicitly.
  After a Docker Desktop restart, `unless-stopped` containers return on their own;
  the guard starts only those still down.
- Without Docker Desktop (colima, OrbStack, a Linux engine), B and C fall back to A
  and the log says so. The engine is Docker Desktop only when the pinned endpoint is
  Desktop's own socket: its physical path (symlinks resolved, so
  `/var/run/docker.sock` counts) is that of `~/.docker/run/docker.sock`. Any other
  local socket is another engine even while Docker Desktop runs, because `docker
  desktop` and Desktop's processes describe the app, not the selected engine: no
  `docker desktop` command runs, A stops and starts only that engine's recorded
  containers, Docker Desktop is left as it is (and logged), and the records name the
  engine (`engine=` in `docker-before.txt`, `docker_engine=` in `result.txt`). If
  Docker is stopped (no engine answers and, on Desktop's socket, no Docker Desktop
  process, `com.docker.backend` or the app, runs), the step is skipped and Docker
  stays off.
- **Only a local engine.** Before any Docker call the guard resolves the engine
  endpoint: `DOCKER_HOST` if set, else the current context's (`docker context
  inspect`). That is the CLI's own order, whatever its reference page says of
  `DOCKER_CONTEXT`: docker/cli's `resolveContextName` takes the `--context` flag,
  then `-H`, then `DOCKER_HOST`, and only then `DOCKER_CONTEXT` (checked against
  CLI 29.9.2). It accepts only a `unix://` socket that exists on this Mac and belongs
  to the user or root (Docker Desktop's `~/.docker/run/docker.sock`,
  `/var/run/docker.sock`, a colima or OrbStack socket), and pins it for every later
  docker call of the process (`DOCKER_HOST` exported in the guard's own process,
  `DOCKER_CONTEXT` unset): the heal, the recovery and the drain's exec listing, whose
  curl asks the same socket. Once it is pinned, a context switched mid-heal changes
  nothing. A heal that starts on an endpoint that is not local pins nothing, so a
  local context selected during its drain is the one its Docker step acts on
  (README "Known limitations"). Anything
  else (`tcp://`, `ssh://`, `npipe://`, no socket at the path, a context that cannot
  be read) is not a local engine: the step is skipped as for a stopped Docker (no
  container or Docker Desktop is stopped, started or checked, no exec session is
  listed), the fseventsd restart goes ahead, and the notification and the heal record
  (`docker_endpoint=`) say so. A Docker Desktop that runs on the Mac while another
  endpoint is selected is left as it is, unchecked, and named. Such a heal ends its
  drain without counting as verified, so a hold in place before it comes back. The
  intent and a hold record the endpoint; the recovery and the hold check act only on
  that engine, compared by the socket's physical path, so Desktop's `default`
  (`/var/run/docker.sock`) and `desktop-linux` contexts are one (§5.5). A socket that forwards to another machine (an `ssh -L` tunnel)
  looks local and is not detected.
- **Silent is not stopped.** When Docker Desktop's process runs but neither `docker
  desktop status` nor `docker info` answers within `FSG_DOCKER_QUERY_TIMEOUT_S`
  (20 s) on Desktop's socket, Docker is wedged, which is the failure being healed. The heal does not
  skip it: B and C run as configured, and A becomes C (A cannot list the containers
  it would stop). A silent non-Desktop engine (`docker info` timed out) keeps A with
  nothing to stop or start. Either way the heal reports healed only if the verify
  step passes afterwards; otherwise runs stay held. The drain cannot list a wedged
  engine's exec sessions and containers, and does not wait for them; the docker CLI
  processes that drive them are still waited for (§5.4).
- **The after-step always runs**, even when the restart failed. If Docker still is
  not back (the engine, a container, or the bind-mount check), the heal does **not**
  release held runs onto it: it leaves a **hold** (heal exit 7 or 8) that outlives
  the heal. Runs stay held until the agent sees Docker healthy again (engine,
  containers by name, bind mount), `fseventsd-guard release`, or
  `FSG_FAILED_HOLD_S` (60 min) passes. A trial's hold is released only by the
  operator (`release`), after recovering Docker by hand.
- **Verify:** every recorded container running, and healthy when it was healthy
  before the heal (§5.5). Then a bind-mount round trip: the host writes a nonce, a throwaway
  container (`--pull never --network none`, a local alpine/busybox/bash image, else a
  recorded container's image) reads it and writes a reply into the same file
  (`fsg-probe.txt`), and the host reads the reply and removes the file. The probe
  dir must be in Docker Desktop's File Sharing list (`FilesharingDirectories` in
  its `settings-store.json`, read only; absent = default sharing, which covers
  `/Users`): the state dir's `mountprobe` when shared, else a dir in the first
  shared folder under your home, or `FSG_PROBE_DIR`. A `docker run` that fails with
  "Mounts denied" / "not shared" marks the check **skipped**, not failed, and the
  notice says so: an unshared probe dir is a setup issue, not a broken Docker, and
  must not hold runs or refuse heals. Doctor warns when the probe dir is not
  shared. Watching inside a container is checked by hand in the trials (no stock
  image ships inotify tools).
- **The agent may not read that list.** The settings file sits in Docker Desktop's
  group container, which macOS app-data protection
  (`kTCCServiceSystemPolicyAppDataDetailed`) guards. The launchd agent runs in a
  background session, so its open is refused without a prompt, while a terminal
  reads the file. Seen live on 2026-10-25: the heal probed the state dir, which
  Docker Desktop did not share, and skipped the check, while `doctor` in the
  terminal picked a shared dir. A refused open (anything but "No such file or
  directory") therefore counts as unknown, not as default sharing. `install`, which
  runs in a terminal, writes the list to `desktop-shared-dirs` in the state dir
  (`#list` and the paths, or `#default`; written to a temp file, then renamed), and
  the agent uses that copy when the live file is refused. With neither, the state
  dir is probed as before, and a "Mounts denied" skip says to run install from a
  terminal or set `FSG_PROBE_DIR`. Doctor warns when the copy is missing or differs
  from the live list, and when neither can be read. The copy goes stale when the
  File Sharing list changes after install, until install runs again; a stale pick
  can only make the check skip, never fail.
- If the engine is wedged and `docker ps` cannot list the containers, the restore set
  is empty. B and C still restart Docker Desktop, and containers with an
  `unless-stopped` or `always` restart policy come back. The record
  shows `ps_ok=0`.
- Every Docker call is time-bounded (`FSG_DOCKER_TIMEOUT_S` for stop, start and the
  engine wait; `FSG_DOCKER_QUERY_TIMEOUT_S` for status and info queries). A wedged
  engine is the failure being healed, so a call must not hang the heal.

## 7. Exit codes

| Command | Codes |
|---|---|
| `status` | 0 ok, 1 warn, 2 runaway, 3 cannot measure |
| `heal` | 0 healed, 3 cannot measure (in the precheck; or after the drain, when a precheck that needed a second `top` is followed by one that misses right before the Docker step: nothing was stopped or restarted, §5.3), 4 drain cap reached (abort), 6 helper would refuse (healthy / rate limited / stalled below the floor), 7 restart failed (Docker restored), 8 restarted but Docker restore or verify failed, or refused while an earlier heal's Docker is still not verified (nothing was stopped), 9 not installed (helper, drop-in or agent missing, the agent not loaded or older than the request protocol, or `sudo -n -l` refuses the helper; checked before the drain), 10 the request, the drain marker or the Docker intent could not be written, or the request stayed unclaimed for 2 agent intervals while no tick ran or for `FSG_REQUEST_MAX_AGE_S`: disk full or state dir not writable (nothing was stopped), 11 wave back-off: a wave heal gave up at the drain cap less than `FSG_WAVE_RETRY_MIN` (60) minutes ago, so no new drain, 12 queued or still running (`--no-wait`, `--result ID --no-wait`), 13 dropped before it started (too old), 14 refused after the drain: the Docker step would stop a running `--rm` container with an anonymous volume, which Docker deletes with it, or Docker answers but did not list its containers, so none could be checked (nothing was stopped or restarted, §6), 130 the agent was stopped during the heal (§5.5), 64 usage or an invalid request. A joined request (§5.3) returns the code of the heal it joined: 0, 7 or 8 |
| `trial` | the heal's code; 13 dropped before it started (its requester was gone); 64 usage (also `--no-wait`) |
| `run` | the command's own code; 75 when it gave up waiting for a drain |
| `release` | 0 released or nothing held; 1 a running heal holds the drain (it releases it itself) |
| `doctor` | 0 all ok, 1 warnings, 2 failures; `--affected`: 0 affected, 1 not affected, 3 unknown |
| helper | 0 restarted, 64 arguments, 65 below the floor, 66 rate limited, 69 no genuine fseventsd, 70 cannot measure, 71 kill failed, 72 restarted but only after SIGKILL (SIGTERM ignored for 10 s), 73 no respawn, 75 another restart running, 77 not root |

The heal codes that callers handle (`WORKFLOW-INTEGRATION.md` §1, `DOCKER-TRIALS.md`)
keep their meaning now that the agent runs the heal:

| Code | Heal in the caller (before) | Heal in the agent (now) |
|---|---|---|
| 0, 3, 4, 6, 7 | as in the table | the same, from the agent's heal |
| 5 | another heal held the lock | not returned. A request queued behind a heal that reached its Docker step joins it and returns its 0, 7 or 8; callers' `5)` branches stay harmless |
| 8 | Docker not verified after this heal | also: refused while an earlier heal's Docker is not verified. The pause action (escalate; runs stay held) fits both |
| 9 | helper or drop-in missing | also: the agent missing, not loaded, or older than the request protocol (§13) |
| 10 | lock, drain marker or intent not written | also: request not written, or left unclaimed for 2 agent intervals while no tick ran, or for `FSG_REQUEST_MAX_AGE_S` |
| 11 | gave up at the cap, or stopped while draining | gave up at the cap only |
| 12, 13 | none | new: `--no-wait` and dropped requests |
| 14 | none | new: refused after the drain, a running `--rm` container would lose its anonymous volume, or Docker answers but did not list its containers (§6); nothing was stopped |
| 130 | the caller's heal ended by a signal | the agent's tick was stopped during the heal; the next tick restores Docker first. Also from the caller, when that tick was killed outright and no tick follows |

## 8. `status --json` schema (`fseventsd-guard.status/1`)

Stable within `/1`: fields are never removed or renamed and their types never
change. New fields may be added. A breaking change bumps the schema to `/2`.

```json
{
  "schema": "fseventsd-guard.status/1",
  "time": "2026-10-16T00:27:31Z",
  "level": "ok|warn|runaway|unknown",
  "exit": 0,
  "pid": 80074,
  "footprint_mb": 5,
  "cpu_pct": 4.2,
  "uptime_s": 8821,
  "thresholds": {"budget_mb": 30, "warn_mb": 500, "act_mb": 2048},
  "probe": {"ran": true, "result": "ok|stalled|error|unavailable|skipped", "latency_ms": 11, "timeout_s": 10, "start_ms": 0},
  "drain": {"pending": false, "phase": null, "reason": null, "live_leases": 0},
  "last_heal": null,
  "docker_intent": null,
  "requests": {"queued": 0, "running": null},
  "agent": {"installed": true, "interval_s": 300, "heartbeat_epoch": 1760574151, "age_s": 120, "result": "ok", "exit": 0, "running": false, "stale": false, "requests": true},
  "os": {"version": "27.0.1", "build": "26A434", "affected": true},
  "reasons": [],
  "error": null
}
```

- `pid`, `footprint_mb`, `cpu_pct`, `uptime_s` are `null` when level is `unknown`.
- `last_heal`, when present, is `{"epoch", "result" (healed|restart-failed|restored-partly|aborted-at-cap|refused-anonymous-volumes|refused-unlisted|refused-cannot-measure|drain-not-marked|intent-not-written), "trigger", "docker_variant", "wall_s"}`.
- `docker_intent` is `null`, or `{"owner_pid", "owner_alive", "trigger", "docker_variant", "since_epoch", "after_step_done"}` while a heal's Docker step has not verified (§5.5). `owner_alive` is true while the tick that wrote it is still in that heal; false means that heal is gone, Docker may be down and the next tick recovers it. `after_step_done` is true once the after-step ran and every container in the restore set was started.
- `requests` is the agent's queue (§5.3): `queued`, the number of requests not yet claimed, and `running`, `null` or `{"id", "trigger", "requester_pid", "requester_alive", "phase"}`.
- `agent` is the background agent's heartbeat (`heartbeat` in the state dir), which
  every tick rewrites as it starts (`result` `running`, `exit` `null`) and as it ends
  (`result` the level it found: ok|warn|runaway|unknown; `exit` the tick's exit
  code). `installed` is whether the agent plist exists. `heartbeat_epoch`, `age_s`,
  `result` and `exit` are `null` before the first tick. `running` is true while the
  tick that wrote it still runs. `stale` is true when the agent is installed and the
  heartbeat (or, with none, the newer of the newest `TICK` line in the user log and
  the plist) is older than twice `interval_s` (`FSG_AGENT_INTERVAL_S`), unless that
  tick is still running a heal. Stale means the agent is unloaded, switched off in
  Background Items or hung; `status --json` then also prints a `warning: agent
  STALE ...` line on stderr, `doctor` warns, and the Claude Code plugin's prompt
  hook warns (§14). An agent that predates heartbeats
  is judged by its `TICK` lines only, and not at all without one (§13). `requests`
  is true when the installed app copy serves heal requests (`FSG_REQUEST_PROTOCOL`
  matches the caller's).
- `probe.start_ms` is how long the probe's `FSEventStreamStart` took (§10), `null`
  when no probe ran or the probe did not report it.
- `reasons` lists why the level is not ok; `error` says why it could not measure.
- `os.affected` is `true`, `false` or `null` (unknown).

Footprint comes from `top -l 1 -pid P -stats pid,mem,cmprs,ports` (MEM is the
physical footprint, the figure Apple's budget refers to), bounded by
`FSG_TOP_TIMEOUT_S` (15 s; a slower sample counts as cannot measure; `status` tries
once, the agent's check and a heal's precheck try again, §5.3). Each tick's
`TICK` log line also carries the compressed memory (`cmprs_mb`) and Mach ports
(`ports`) from that sample and the swap in use (`swap_used_mb`, from `sysctl
vm.swapusage`); they are logged only. Ports tell many live clients apart from
internal state, and swap shows what the runaway costs the machine. The state dir's
`daily` keeps one line per day (ticks, the largest footprint and CPU share, heals
that restarted fseventsd, the event rate's median and 95th percentile), so the
thresholds can be checked against weeks of data once the log has been trimmed. CPU is
`ps -o %cpu`, a decayed average; one `top` sample cannot give CPU. The tick also
logs `cpu_avg_pct`, the share of one core since the previous tick, and
`cpu_streak` (§4). Uptime is `ps -o etime`. No root needed.

## 9. Affected versions

- The guard is suggested only on affected macOS versions (owner, 2026-10-25): from
  `FSG_AFFECTED_MIN` (15.6.1, the earliest version with a first-hand report) up to,
  not including, the first fixed version of the same major line, listed in
  `FSG_AFFECTED_FIXED` (`config.defaults`; `"26.8 27.1"` would mean 26.x is fixed
  from 26.8 and 27.x from 27.1). A major line with no entry counts as affected from
  the minimum on, newer lines included. No fix is known, so the list is empty.
- This replaces an explicit list of reported versions (owner, 2026-10-20), which
  went stale on every release: the bug looks long-standing (the same defect was
  found in fseventsd 1400.100.1 on 15.7.9 and 1413.160.2 on 26.7.1), no source
  claims a fix, and healthy readings after a few days without a file-event flood
  say nothing (27.0.1 has both). Versions in the range without a report of their
  own (26.0, 27.2) are treated as affected for the same reason.
- When Apple ships a fix, add that line's first fixed version to
  `FSG_AFFECTED_FIXED` with its evidence below, in one pull request. A report on a
  version older than 15.6.1 moves `FSG_AFFECTED_MIN` down.
- `fseventsd-guard doctor --affected` (exit 0/1/3) and the `os.affected` field in
  `status --json` expose the answer. `install` refuses outside the range unless
  `--force`. `FSG_AFFECTED=yes|no` overrides it on one machine. Versions compare
  numerically, component by component (15.10 is after 15.6.1, 27.0 equals 27.0.0).

Reports behind the range (researched 2026-10-20 and 2026-10-25; no source claims a fix):

| macOS (build) | Report |
|---|---|
| 15.6.1 (24G90) | The earliest version with a report, by mikirejf ([bun#43870](https://github.com/oven-sh/bun/issues/43870)) |
| 15.7.9 (24G830) | 2.9 GiB, back to 4.5 MB after a restart, FB25224901; the reporter hedges only on the cause ([Apple forum 849819](https://developer.apple.com/forums/thread/849819)) |
| 26.4.1 | ~62 GB resident at 193% CPU ([remotion#7207](https://github.com/remotion-dev/remotion/issues/7207)) |
| 26.5.1 (25F80) | ~19 GB in `top` (~2.5-3 GB resident), ~100% CPU, ~160 CPU-hours over 36 days ([Kiro#9742](https://github.com/kirodotdev/Kiro/issues/9742)) |
| 26.5.2 (25F84) | 27-29 GiB ([bun#43870](https://github.com/oven-sh/bun/issues/43870)); 9.4 GB with events not delivered ([kolu#2175](https://github.com/juspay/kolu/issues/2175)); 67 GB ([openclaw#156191](https://github.com/openclaw/openclaw/issues/156191)) |
| 26.6 | "exactly the same problem", screenshot only; the weakest row ([colima#1569](https://github.com/abiosoft/colima/issues/1569)) |
| 26.6.1 | 1.2 GB at 100% CPU ([claude-code#96008](https://github.com/anthropics/claude-code/issues/96008)); 5.7 GB ([plasmic#439](https://github.com/elasticpath/plasmic/issues/439)) |
| 26.6.2 (25G83) | 42 GiB ([claude-code#98769](https://github.com/anthropics/claude-code/issues/98769)); 67 GB ([agent-legion#637](https://github.com/LuciusCao/agent-legion/issues/637)); 19.8 GB ([atrium-issues#104](https://github.com/jonnyasmar/atrium-issues/issues/104)) |
| 26.7 (25G229) | 8.2 GB, and Claude Code fell back to polling: "native file watching is not delivering events" ([claude-code#98769](https://github.com/anthropics/claude-code/issues/98769)) |
| 26.7.1 (25G241) | 26.6 MB to 2.31 GB in six minutes, FB25090184 ([Apple forum 849819](https://developer.apple.com/forums/thread/849819)) |
| 27.0 (26A428) | 24 GB, FB25046068 (talkstream, in the body of [claude-code#98769](https://github.com/anthropics/claude-code/issues/98769) and in [talkstream/fseventsd-runaway](https://github.com/talkstream/fseventsd-runaway)); 0 events delivered at 2.3 GB ([gai-tools#62](https://github.com/Navibyte-Innovations-Pvt-Ltd/gai-tools/issues/62)) |
| 27.0.1 (26A434) | The owner's Mac: 17.7 GB, a fresh watcher got 0 events for 50 writes; 36-37 GiB ([codex#34376](https://github.com/openai/codex/issues/34376)); flat at 4-11 MB for a week, then 10, 52 and 558 MB within an hour after about 10k uniquely named temp files, 7.5 GB at 18 h and 14 GB at 26 h, no recovery (ww2283, 2026-10-20, [claude-code#98769](https://github.com/anthropics/claude-code/issues/98769)) |

Not listed: reports that give only a Darwin version (25.3, 25.5, 25.6, 24.6) or no
version at all, because they cannot be matched against `sw_vers`.

## 10. Delivery probe

`probe/fsprobe.swift`, built with `swiftc -O` at install (Command Line Tools). It
watches a private directory under the state dir, writes one uniquely named file
there, and times its event. It exits 0 (ok, with latency), 2 (stalled), or 3 (error).
A watchdog on a separate dispatch queue enforces the timeout even if the FSEvents
calls block inside a wedged daemon. The shell adds an outer bound of timeout + 5 s.
Measured on the owner's Mac with a healthy daemon: 3-11 ms. The probe adds one
create and one delete per check: 2 events every 5 minutes.

The probe also times `FSEventStreamStart` and appends it as `start_ms` to its ok
and stalled lines (absent when the start had not returned by the timeout; parsers
that read `latency_ms` are unaffected). A healthy daemon takes 0-1 ms; a sick one
took 13-7,735 ms in [bun#43870](https://github.com/oven-sh/bun/issues/43870). It
goes into each tick's `TICK` log line, `status --probe` and `status --json`
(`probe.start_ms`). No heal acts on it yet: a threshold needs readings from sick
daemons on more Macs first.

After the start the probe also prints `FSEventsGetCurrentEventId()` as `eid`. The
tick logs it with `ev_s`, the system-wide event rate since the previous tick (no
root needed). The rate starts over when the fseventsd pid or the boot time changes,
because event ids jump by billions after a boot. It is logged only: it records the
flood that a restart erases, and gives the thresholds data (§12, question 1). One
machine measured 50-200 events/s normally and 2,117-5,715 on flood days
([talkstream/fseventsd-runaway@78396ba](https://github.com/talkstream/fseventsd-runaway/tree/78396ba)).

## 11. Changes from the original plan

| Plan | Built | Why |
|---|---|---|
| Wave-boundary heal "while nothing is running" | Every heal drains | The machine is never free (owner, 2026-10-16) |
| Trials "when the machine is free" | Trials run through the drain (`trial` command) | Same |
| Install the helper, then trials run without prompts | Plus a time-boxed trial window | The floor and rate limit would refuse repeated restarts of a healthy daemon |
| Agent runs the repo copy (implicit) | Agent runs an installed copy | Branch switches and deleted worktrees must not break it |
| Heals run where they are called (implicit) | Only the agent heals; callers queue a request and wait | A killed caller must not strand Docker (owner, 2026-10-20) |
| Stall → heal | Stall confirmed by a second probe | Load average 100-300 |
| Footprint via `top` (and `footprint` if cheap) | `top` for the decision; `footprint` (10 s bound) only in the helper's evidence | `footprint` on a 17 GB process is slow |
| (not planned) | Emergency ceiling 8 GB cuts the drain short | Protects a machine with a nearly full disk |
| (not planned) | Helper requires ppid 1 | A root process exec'ing the binary from elsewhere is not the daemon |
| (not planned) | `doctor --affected` and the affected version range | Owner, 2026-10-16, 2026-10-20 and 2026-10-25 |

## 12. Open questions

1. Thresholds after a few days of logs (warn 500 MB, act 2 GB, floor 150 MB,
   emergency interval 3 h, ceiling 8 GB, drain cap 60 min).
2. Which Docker variant wins (trials pending). B is the default until then.
3. Recording fixes (§9): `FSG_AFFECTED_FIXED` is empty, so every version from
   15.6.1 on counts as affected until a fix is reported and added.
4. A stall with a footprint below the helper's floor: the helper refuses, and the
   guard notifies with the manual command. Should the helper accept a stall it can
   verify itself (a root-owned copy of the probe)?
5. Whether Time Machine really runs a deeper scan after a restart.
6. Which runners to integrate first (see `WORKFLOW-INTEGRATION.md`). Until then the
   fallback detector carries the drain.
7. Should a **warn** (status 1) drain at all at a wave boundary? Today the pre-wave
   call runs `heal --trigger wave` at warn, which holds every session's new leased
   runs for up to the 60-minute cap and then gives up while long runs continue.
   The wave back-off (exit 11, 60 min) stops that repeating at every wave, but one
   hour-long hold per warn remains. Proposed: at warn, run
   `heal --trigger wave --drain-cap 0` (heal only when nothing is running, as the
   original plan had it), and drain with the full cap only at
   runaway (status 2). Owner decision.
8. Cancelling a heal. A caller can no longer stop one: Ctrl-C only ends its wait. A
   later `heal --cancel ID` could be honoured while the request is queued or still
   draining, never once its Docker step began. Owner decision.
9. While an earlier heal's Docker stays unverified (at most `FSG_FAILED_HOLD_S`),
   every new heal is refused with exit 8, the emergency heal included (§5.3). The
   alternative, a heal that also restores the earlier heal's containers, is the
   takeover this model removed. Owner decision whether a runaway in that window
   should heal anyway.
10. Whether Docker Desktop started by the agent outlives the tick. launchd kills what
    is left in a job's process group when it exits (`AbandonProcessGroup` defaults to
    false), and every heal and trial now runs `docker desktop start` or `restart` from
    the tick. Checked in the first live B or C trial (`DOCKER-TRIALS.md` §2); if
    Docker shares the group, the plist needs `AbandonProcessGroup` or the agent must
    start Docker Desktop with `open -a Docker` (owner decision).
11. The root helper measures with its own `top`, bounded at 15 s and tried once: on
    a Mac loaded enough to miss that, it refuses with 70 after the drain and the
    Docker before-step ran (exit 7). A heal whose precheck needed a second `top`
    takes one more right before the Docker step and ends with 3, Docker untouched,
    when it misses (§5.3); a helper `top` that misses after that one answered, or
    after a precheck that answered at once, still ends this way. Retrying in the
    helper changes root code, so every install asks for sudo again (owner
    decision). With `ProcessType` `Interactive` it most likely runs at the agent's
    priority (§5.3, not checked).
12. A tick that cannot measure returns before its probe, so a delivery stall goes
    unseen while the agent is blind. It could still probe and notify a stall
    (it cannot heal without a measurement).

## 13. Agents from before heal requests

Only installs made from pre-release copies of the guard have such an agent. An app
copy from before heal requests writes no heartbeat, knows neither heal
requests nor the Docker intent, and heals in-process. Its plist runs `/bin/bash
<app>/fseventsd-guard tick`. The code still handles such an agent until `install`
replaces it:

- `heal` and `trial` exit 9: "the installed agent predates heal requests (no
  `FSG_REQUEST_PROTOCOL` in `<app>/lib/common.sh`): re-run fseventsd-guard
  install". They never heal in-process.
- `doctor` warns that the plist runs `/bin/bash`, that the agent predates
  heartbeats, and that the app copy differs from the checkout; each says to re-run
  `install`.
- The liveness of an agent that has no heartbeat and whose plist runs `/bin/bash`
  comes from the newest `TICK` line in the user log, never from the plist's mtime.
  So `status --json` prints the `agent STALE` warning only when those lines stop;
  with no `TICK` line at all it prints none, and `doctor` warns `agent predates
  heartbeats: re-run install`. `agent.requests` is false.

`install` replaces the app copy and the plist, and creates `requests/`. Nothing in
the state is converted. An agent under another label is not replaced: `install`
refuses while one runs the app copy (§2), and that agent goes with the uninstall of
the install that made it.

## 14. Claude Code hooks: the stopped-agent warning (`lib/hint.sh`)

The plugin's hooks only read the guard's state (what each says: `../README.md`,
"Claude Code hooks"). Once the agent's plist is installed the install nudge stops,
so an agent that did not start after a restart, was switched off in Login Items &
Extensions, was booted out or hangs left the guard looking installed while nothing
watched fseventsd. The prompt hook now warns then (owner, 2026-10-26):

- **The rule of `status` and `doctor`.** The hook calls `fsg_agent_fields` (§8,
  `agent.stale`): stale when the heartbeat, or with none the newest `TICK` line or
  the install, is older than 2 × `FSG_AGENT_INTERVAL_S` from the config, unless that
  tick is still in a heal. The three cannot disagree.
- **Cheap on every prompt.** After the config load, a heartbeat within the limit is
  read with shell builtins and ends the check: no `top`, `launchctl` or `ps`. Only
  an older one, past the stamp and the boot check below, sources `lib/measure.sh`
  and `lib/heal.sh` for the full rule. The config load writes nothing to the user
  log: a bad config line is the agent's to log, not every prompt's.
- **Not right after a boot or a wake.** launchd starts the agent at login
  (`RunAtLoad`) and runs an interval it missed asleep on wake, but a prompt can
  come first, against a heartbeat from before the restart or the sleep. So the hook
  says nothing until the later of `kern.boottime` and `kern.waketime` is more than
  two intervals ago. On the author's Mac the first tick after a 35-minute sleep came
  98 s after the wake: timed from the boot alone, a prompt in that minute and a half
  after opening the lid would warn. The boot time is not the login time, so a
  prompt in the seconds between a late login and the first tick could still warn.
- **At most every 6 hours** (`fsg_hint_every agent-stopped`), stamped in the hint
  dir before it prints, as the nudge is: every session shares the stamp, and a stamp
  that cannot be written prints nothing. `install` and `uninstall` remove it with
  the nudge's stamps.
- **What it says.** The last tick's age against the interval, that the guard is not
  watching fseventsd, the causes (unloaded, switched off, hung), and the app copy's
  `doctor` to run in a terminal, which names the cause and the fix. `FSG_HINT=0`
  and the `off` file silence it, as they do the nudge; off macOS it says nothing.
- **The hook's state dir.** It judges the state dir of its own environment, as the
  heal notice and `doctor` do. An agent installed with another `FSG_STATE_DIR`
  (the suite's knob, not a documented setting) would be judged by its plist's age.
