# fseventsd-guard: workflow and runner integration

Two integration points:

1. **Scripts and workflows** call `status` before a long test run (a workflow that
   runs in waves: before each wave) and `heal` when it is not ok (the preferred
   tier).
2. **Runners** of Docker-dependent work take a **lease**, so a heal waits for them
   and they wait for a heal. Until a runner is integrated, the fallback detector
   (`DESIGN.md` §5.4) still sees it as a process if its name is in
   `FSG_DETECT_COMMANDS`. Integration makes the drain exact and shows the held-run
   message.

The lease snippet (§2) is a no-op, and the `run` example runs the bare command,
where the guard is not installed (no app copy in its state directory, as after
`uninstall`) or not on macOS. The call in §1 skips itself without the app
copy too. With the app copy but no loaded agent it does not: `status` still
measures, and at runaway `heal` exits 9, which pauses the run (exit table below).

## 1. The call before a long test run

Run this before a long or parallel test run starts; in a workflow that runs in
waves, at each wave boundary. It needs no root.
It calls the installed app copy, so the project needs no clone of the guard.

```sh
G="$HOME/Library/Application Support/fseventsd-guard/app/fseventsd-guard"
if [ "$(uname -s)" = Darwin ] && [ -x "$G" ]; then
  "$G" status --json > "$WAVE_DIR/fseventsd-status.json"; rc=$?
  case $rc in
    0|3) ;;                                   # ok, or cannot measure: start the wave
    1|2)
      "$G" heal --trigger wave; hrc=$?
      case $hrc in
        0|6) ;;                               # healed / nothing to do
        *) [ $rc -eq 2 ] && fsg_wave_pause "$hrc" ;;   # runaway and the heal failed
      esac ;;
  esac
fi
```

Why it is shaped like this:

- `heal --trigger wave` does not heal in the workflow's process. It queues a heal
  request for the background agent, kicks the agent, and waits for the result,
  printing the heal's progress on stderr and its summary on stdout. The agent's
  heal drains first. Runs from other sessions that started before the drain
  finish: leased runs up to the 60-minute cap, unleased runs (found by process
  name, exec session, or as a running `--rm` or `docker compose run` container) up
  to `FSG_UNLEASED_CAP_S`, 10 min. If they do not, a wave heal gives up
  (exit 4) instead of cutting them. Only leased runs (§2) are held while the heal
  runs; an unleased run started meanwhile meets a stopped Docker. Leases of the
  workflow itself and its ancestors are not waited for while the call waits for
  the result, so a leased workflow can ask for a heal.
- **Killing the call is harmless.** A `timeout`, `timeout -k`, Ctrl-C or a
  tool-call limit around `heal` ends only the wait, also when it signals the
  caller's whole process group: the agent's tick is launchd's, outside that group.
  The agent finishes the drain,
  the Docker step, the restart, the restore and the verify (usually minutes; up to
  the 60-minute drain cap plus about 45 minutes at worst with the default
  timeouts), and releases held runs only onto a verified Docker. Re-attach with
  `heal --result ID` (the id is printed when the request is queued). A caller with
  a hard bound can also queue with `heal --trigger wave --no-wait` (prints the id,
  exit 12) and poll `heal --result ID --no-wait` (12 while it runs, then the heal's
  code). A wave heal whose caller was killed does not start the wave back-off.
- **Once the call stops waiting, the workflow's own leases hold the heal.** After a
  killed wait (124 from `timeout`, 130 from the call's own signal) or with
  `--no-wait`, the heal no longer leaves out the leases of the workflow and its
  ancestors, and the call says so. While it drains, a lease the workflow took before
  holds it like any other run, so a wave heal gives up at its cap (exit 4) rather
  than cut the workflow. Past the drain (Docker stopped) nothing holds the workflow:
  runs nested under its lease do not wait. So do not start the wave on 12, 124 or
  130: poll `heal --result ID --no-wait` until it returns a final code, then decide
  as below. A leased workflow that queues with `--no-wait` holds its own heal to the
  cap; queue from outside the lease, or wait.
- **The agent must be installed and loaded.** Without it, or with an installed copy
  older than the checkout, `heal` exits 9 with the fix (`launchctl bootstrap ...`,
  switching the agent back on in Login Items, or `install`). If no tick runs to
  take the request for two agent intervals (its ticks fail, for example on a full
  disk), or it stays unclaimed for `FSG_REQUEST_MAX_AGE_S` (2 h), `heal` withdraws
  it and exits 10. Nothing was stopped in either case. A
  request queued while the agent's tick is busy (the agent's emergency heal,
  another session's heal) waits for that heal however long it drains, then joins
  it.
- When the background agent has not ticked for more than twice its interval,
  `status --json` prints `fseventsd-guard: warning: agent STALE ...` on stderr (the
  JSON on stdout stays valid; `agent.stale` is true). Keep stderr in the wave's log:
  it is how an agent switched off or unloaded gets noticed. It does not change the
  exit code.
- A wave request queued behind a heal (another session's, or the agent's own) that
  reached its Docker step joins it: it returns that heal's 0, 7 or 8 without a
  second drain. Exit 5 is no longer returned.
- Exit 6 means the root helper would refuse (healthy, or rate limited). Proceed.
- At **warn** (status 1), a failed heal does not stop the wave. File watching is
  degraded, not broken, and the developer was notified.
- After a wave heal gives up at the cap (exit 4), wave heals from every session
  return 11 for `FSG_WAVE_RETRY_MIN` (60) minutes without draining, so a busy
  machine does not get an hour-long hold at every wave boundary. Whether warn should drain at all is an open owner question
  (`DESIGN.md` §12 item 7).

### How a workflow pauses when status is 2 and heal fails

`fsg_wave_pause` is the workflow's own routine. Required behaviour:

1. **Do not start the wave.** With fseventsd runaway, watchers inside the wave
   (dev servers, Jest/Vitest watch, IDE-driven checks, Claude Code itself) miss
   changes, and results cannot be trusted.
2. **Record it**: the status JSON, the heal exit code and its meaning (table
   below), and the heal record path
   (`~/Library/Application Support/fseventsd-guard/last-heal-dir`).
3. **Wait and retry, bounded.** Poll `status` every 5 minutes for up to 60 minutes.
   The background agent may heal in the meantime (emergency tier). When status
   returns 0 or 1, resume the wave. Run `heal --trigger wave` again only after a
   heal exit 4 (drain cap); for exit 7 or 8 a retry needs a person.
4. **Escalate** if still 2 after the bound: stop the run in whatever state your
   workflow uses for "a person must act", with the reason
   `fseventsd runaway, heal failed (exit N: meaning)` and the manual fix
   `sudo kill -TERM $(pgrep -x fseventsd)`.

| heal exit | Meaning | Pause action |
|---|---|---|
| 3 | cannot measure | treat as unknown: proceed, log it |
| 4 | drain cap reached (other sessions' runs still going) | wait and retry |
| 11 | wave back-off: a wave heal gave up at the cap less than 60 min ago, no new drain | at warn: proceed; at runaway: wait and retry (the agent's emergency tier still acts) |
| 7 | restart failed (the helper refused or failed); Docker restored. If Docker did not verify, leased runs stay held as for 8 | escalate after the bound; `fseventsd-guard doctor` |
| 8 | restarted, but Docker or a container did not fully come back; or refused because an earlier heal's Docker is still not verified (nothing was stopped) | escalate at once: tests would fail for Docker reasons. Leased runs stay held until Docker is healthy again, `fseventsd-guard release`, or 60 min |
| 9 | guard not installed, or its agent not loaded or older than the checkout | escalate: install it, or load it (the message names the fix; README "Install") |
| 10 | the request, the drain marker or the Docker intent could not be written, or the request stayed unclaimed for two agent intervals while no tick ran (disk full) or for `FSG_REQUEST_MAX_AGE_S` (2 h); nothing was stopped | escalate: `fseventsd-guard doctor` |
| 13 | the agent dropped the request before it started (older than 2 h when it was taken) | wait and retry |
| 14 | refused after the drain: the Docker step would stop a running `--rm` container with an anonymous volume, which Docker deletes with it, or Docker answers but did not list its containers, so none could be checked; nothing was stopped | escalate: a person stops that container or restarts it with a named volume, or gets `docker ps` working again (the notification says which); until then a retry drains and refuses again |
| 130 | the agent was stopped during the heal (logout, `launchctl bootout`, `install`; or killed outright, and no tick followed within two agent intervals); its trap or next tick restores Docker. Also the call's own wait stopped by a signal, with the heal still running (the call says `stopped waiting`) | wait and retry: poll `status` as above; after `stopped waiting`, poll `heal --result ID --no-wait` first |

### Wiring it into an orchestrator

Put the call where the orchestrator starts a wave, as a rule its agents follow, for
example:

> **fseventsd pre-wave check (macOS).** Before spawning each wave, run the pre-wave
> call (fseventsd-guard `docs/WORKFLOW-INTEGRATION.md` §1). Status 0/3: spawn.
> Status 1/2: `heal --trigger wave` first. If status was 2 and heal exited 4, 7, 8
> or 9, do not spawn. Poll `status` every 5 min for up to 60 min, then stop the run
> for a person with the heal exit meaning.

## 2. Runner leases

Two ways, both described in `DESIGN.md` §5.2:

```sh
# a) Wrap the command (preferred when you control the call site):
G="$HOME/Library/Application Support/fseventsd-guard/app/fseventsd-guard"
if [ -x "$G" ]; then "$G" run --label "parallel specs" -- bin/parallel-specs spec/models
else bin/parallel-specs spec/models; fi

# b) Source the lease library at the top of a runner script that cannot be wrapped
#    (works in sh, bash -euo pipefail and zsh):
fsg_lease="$HOME/Library/Application Support/fseventsd-guard/app/lib/lease.sh"
if [ "$(uname -s)" = Darwin ] && [ -r "$fsg_lease" ]; then
  . "$fsg_lease"
  fsg_lease_acquire "<runner label>" || exit $?
fi
```

- The lease belongs to the script's process. A script that ends in `exec CMD` keeps
  it for CMD's whole run. A script that does not exec keeps it until the script
  ends. `fsg_lease_release` ends it early.
- Nested leased scripts inherit the outer lease, so they never deadlock.
- Exit 75 means the run gave up waiting for a drain (only with `FSG_RUN_MAX_WAIT_S`
  set). Treat it like a transient infrastructure failure: retry later.

### 2.1 Which runners to lease

List every command in your project that needs Docker's containers while it runs,
then pick a row for each:

| Runner kind | Example | Integration |
|---|---|---|
| A spec runner script that ends in `exec` | `bin/parallel-specs` ending in `exec bundle exec parallel_rspec` | the snippet below; the lease covers the whole run, workers included |
| Other scripts that run specs against the containers | `scripts/run-specs.sh` | the snippet below, or wrap the call with `run` |
| Setup scripts that start or stop the stack | `docker compose up` / `down` in a bootstrap script | `fsg_lease_acquire` before the compose calls: a `compose down` in the middle of a heal would undo the restore |
| Short `docker exec` helpers | a `psql` one-liner | none needed: short, and the detector sees `docker exec` |
| Dev servers and workers | `bin/rails s`, sidekiq, `next dev` | **must not lease**: long-lived, they would hold every drain to the cap; they reconnect after the restore |
| Hooks that call a runner | a pre-commit hook that runs `bin/parallel-specs` | covered once the runner leases |
| Test commands run directly | `bundle exec rspec`, a Ruby binstub such as `bin/rspec` | wrap with `fseventsd-guard run --` (a binstub cannot hold a shell snippet); the detector sees `rspec` |
| Workflow waves | an orchestrator that spawns parallel agents | the call in §1, before each wave |
| Tests that do not use Docker | `npm test` with mocked requests | none |

A runner the detector does not know by name (`FSG_DETECT_COMMANDS`, default
`rspec parallel_rspec parallel_test`) is not waited for until it leases. You can
add its name to `FSG_DETECT_COMMANDS` in
`~/Library/Application Support/fseventsd-guard/config`, but a lease is exact and
also holds the run during a heal.

The snippet, for a runner such as `bin/parallel-specs`. Put it near the top, after
any `cd`:

```bash
# fseventsd-guard lease (macOS): a heal of fseventsd waits for this run, and this run
# waits while a heal is in progress. No-op unless the guard is installed.
fsg_lease="$HOME/Library/Application Support/fseventsd-guard/app/lib/lease.sh"
if [ "$(uname -s)" = Darwin ] && [ -r "$fsg_lease" ]; then
  # shellcheck disable=SC1090
  . "$fsg_lease"
  fsg_lease_acquire "bin/parallel-specs" || exit $?
fi
```

## 3. Reading status from scripts

`status --json` is stable within schema `fseventsd-guard.status/1` (`DESIGN.md`
§8). Use `level` and `exit`, not the thresholds. Example with stock tools:

```sh
G="$HOME/Library/Application Support/fseventsd-guard/app/fseventsd-guard"
level=$("$G" status --json | plutil -extract level raw -)
```
