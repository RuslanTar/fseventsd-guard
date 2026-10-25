# Docker trials runbook

**Goal:** find the Docker step that leaves Docker Desktop and its
containers working after an fseventsd restart, with the fewest workarounds and the
shortest wall time. Pick healed first, then wall time.

Run this once per Mac, or once for the project. The machine never needs to be free:
**every trial runs through the drain**. It waits for running test runs to finish
(up to 60 minutes), holds new leased runs while it acts, and releases them after.
Plan about 15 minutes of hands-on time plus the drain waits.

**The background agent runs each trial.** `trial` queues a request for it, kicks
it, prints the heal's progress as it happens and waits for the result, so the
agent must be installed and loaded (`$G doctor`; `trial` exits 9 otherwise). Keep
the terminal open until the trial starts: a trial whose requester is gone when the
agent takes it is dropped (exit 13). Once it runs, closing the terminal or Ctrl-C
no longer stops it; the agent finishes the trial and Docker, and the folder below
has everything.

Throughout:

```sh
cd ~/fseventsd-guard/plugins/fseventsd-guard    # your clone
G=./fseventsd-guard
```

## 0. Preconditions (once)

1. Install the guard with a **trial window** (one sudo prompt). The window lets the
   helper restart a healthy fseventsd (floor 0 MB, at most once per 120 s) for 6
   hours (24 at most), then closes by itself:

   ```sh
   $G install --trial-hours 6
   $G doctor                 # expect: WARN "trial window open until ..." and no FAIL
   ```

   `install` runs only code that matches `origin/main`. To try a branch that is not on
   main yet, read `lib/root-steps.sh` and `lib/restart-helper.sh` on the branch and add
   `--allow-unreviewed`; check the commit, hashes and trial end time it prints
   before you answer `y` and type the password.

2. Docker Desktop running with the usual containers up (`docker compose up -d` from
   your project's root if needed). Check: `docker desktop status`, `docker ps`. A trial
   waits for running `--rm` and `docker compose run` containers like other work (up
   to 10 minutes). While Docker answers, a trial stops no container and no Docker
   Desktop unless every running container was listed and none is a `--rm`
   container with an anonymous volume: it refuses (exit 14) while one still runs,
   or while Docker answers `docker info` but does not list its containers. Only a
   wedged Docker is acted on unchecked, and the result names it.
   `$G heal --dry-run` lists such containers and says when Docker does not list
   them.
3. Optional: lower the drain cap for the trials only. Each trial then gives up
   instead of waiting the full hour:
   `export FSG_DRAIN_CAP_S=1800` (the request carries it to the agent; other
   settings are the agent's config).
4. Note the current values for the record: macOS version (`sw_vers`), Docker
   Desktop version (`docker version --format '{{.Server.Version}}'`), and
   `$G status`.

Every trial writes a folder under
`~/Library/Application Support/fseventsd-guard/trials/<time>-<variant>-<label>/`:

| File | Holds |
|---|---|
| `before.txt` / `after.txt` | `docker desktop status`, `docker ps -a`, Docker processes with their uptimes, fseventsd status with a probe (`after.txt` adds `docker info`) |
| `heal.out` | the heal's own output: drain progress, result line |
| `result.txt` | phase timings (`drain_s`, `docker_before_s`, `restart_s`, `healthy_s`, `docker_after_s`, `containers_s`, `verify_s`, `heal_s_after_drain`), helper exit code, containers not back, bind-mount result, B's stop (`docker_stop=`: exit code, time, decision) and `docker_started_by_other=` when something else started Docker Desktop during the heal |
| `desktop-logs-warn.txt` | `docker desktop logs` at warning level and above since the trial started |
| `summary.txt` | the variant, the heal exit code and `result.txt` |

## 1. Step 0: capture today's failure (the naive restart)

```sh
$G trial --variant none --label step0
```

This restarts fseventsd without touching Docker, which is what a manual restart
does. The heal reports `8` (restarted, Docker not fully back) if Docker breaks the
usual way. Then record:

1. Did Docker Desktop stay `running` (`after.txt`)? Did the backend restart?
   Compare the `com.docker.backend` uptime in `before.txt` and `after.txt`.
2. Which part failed:
   - **The VM / engine**: `docker info` errors in `after.txt`.
   - **File sharing / bind mounts**: `bind_mount=failed` in `result.txt`
     (`bind_mount=skipped ... not shared` means the probe dir is not in Docker
     Desktop's File Sharing list: set `FSG_PROBE_DIR`, see `doctor`). Or check by
     hand: `docker run --rm -v "$PWD:/w" alpine:3 ls /w` (use any local image that
     has `/bin/sh`).
   - **Containers**: `containers_failed=` in `result.txt`, `docker ps -a`.
   - **The Docker processes**: `desktop-logs-warn.txt`.
3. `docker desktop diagnose`. It writes a local bundle and uploads nothing without
   `-u`. Note the bundle path it prints.
4. Recover by hand if Docker is broken: `docker desktop restart`, then
   `docker compose up -d`. Note how long it took and whether anything else was
   needed. This is the baseline that the variants must beat.
5. A trial that leaves Docker broken keeps other sessions' new test runs **held**
   (the trial prints this). Once Docker works again (`docker ps`, a bind mount),
   run `$G release`. The hold also ends by itself after 60 minutes.

## 2. The variants, twice each

Interleave the runs (A, B, C, then A, B, C again), so machine-load drift does not
favour one variant. Leave at least 2 minutes between trials (the helper's trial
interval):

```sh
$G trial --variant A --label run1
$G trial --variant B --label run1
$G trial --variant C --label run1
$G trial --variant A --label run2
$G trial --variant B --label run2
$G trial --variant C --label run2
```

| Variant | Before the restart | After the restart |
|---|---|---|
| A containers only | `docker stop` the running containers | `docker start` the same IDs (not `--rm` or one-off ones) |
| B quit Docker | `docker desktop stop` | `docker desktop start`; start the same IDs not running (not `--rm` or one-off ones) |
| C restart Docker after | nothing | `docker desktop restart`; start the same IDs not running (not `--rm` or one-off ones) |

A trial's exit code is the heal's: `0` healed, `4` the drain hit the cap (nothing
was restarted; re-run it later), `7` the restart failed, `8` restarted but Docker
was not fully back, or variant C skipped its Docker Desktop restart (a `--rm`
container with an anonymous volume ran by then, or Docker answered but did not
list its containers), or refused because an earlier trial's Docker is still not
verified (recover it and run `$G release` first), `14` refused: a running `--rm`
container has an anonymous volume that the variant's Docker step would delete, or
Docker answered but did not list its containers, so none could be checked
(nothing was stopped; stop that container or give it a named volume, or get
`docker ps` working again, then run the trial again), `130` the agent was stopped during the trial. After each trial, before the next one, check:

1. **Healed?** `summary.txt` says `result=healed` and `heal_exit=0`. That means
   Docker is running, every container the heal restores (not `--rm` or one-off ones) is running (and healthy where it
   has a health check), and the bind-mount round trip worked both ways.
2. **Wall time.** `heal_s_after_drain` is the figure to compare. The drain time
   depends on other sessions' runs, not on the variant.
3. **Workarounds.** Anything you had to do by hand to get Docker or a container
   back. Write it down, even if small.
4. **File watching inside a container**, if any dev container relies on it
   (databases, caches and search engines usually need none). Check that a host
   change reaches a watcher inside it.
5. **Test runs held and released.** If test runs were going, their output shows
   `fseventsd-guard: holding ...` once integrated (see `WORKFLOW-INTEGRATION.md`),
   and they continue after the trial.

If a trial leaves Docker broken, recover as in step 0 item 4, then `$G release`,
before the next trial, and record that as a manual step for that variant.

**After the first B or C trial: does Docker outlive the agent's tick?** When a
launchd job exits, launchd kills what is left in its process group
(`AbandonProcessGroup` is false by default). Every trial and every heal now runs
`docker desktop start` or `restart` from the agent's tick, and nobody has checked
yet whether that leaves Docker Desktop or `com.docker.backend` in the tick's group.
A minute after that trial ended:

```sh
R="$HOME/Library/Application Support/fseventsd-guard/requests"
tick=$(sed -n 's/^claimed_pid=//p' "$(ls -1 "$R"/*.run | tail -n 1)")
echo "tick pid (its process group): $tick"
ps -axo pid=,pgid=,ppid=,command= | grep -iE '[c]om\.docker|[D]ocker Desktop' | cut -c1-160
docker desktop status
```

Fine: no Docker process has the tick's pid as its pgid (second column), and
`docker desktop status` still says `running`. If one does, or Docker Desktop is gone
although the trial verified it, stop the trials and note it here: the agent then
needs `AbandonProcessGroup` in its plist or to start Docker Desktop with
`open -a Docker` (an owner decision).

Result: _not checked yet._

**During one trial: do running sessions see file changes after the heal?** One
report saw file watchers not recover after fseventsd restarted, so the heal
notices say to restart a session that stops seeing file changes. That is a guess
until checked. Check it once, with any variant:

1. Before the trial, make a scratch dir and a file:
   `D=$(mktemp -d); echo one > "$D/a.txt"; echo "$D"`. Start a Claude Code
   session in `$D`, ask it to read `a.txt`, and leave it open. Optional: open `$D`
   in your IDE too.
2. Control, still before the trial: from another terminal, `echo two >> "$D/a.txt"`,
   then send the session a short prompt that does not name the file ("ok?"). Note
   whether it mentions that `a.txt` changed and whether the IDE shows the new line
   without a manual refresh. A watcher that misses this change now tells you nothing
   below.
3. Run the trial. After it ends, `echo three >> "$D/a.txt"` and repeat step 2's
   prompt and IDE check.
4. If the old session misses it, start a new session in `$D`, have it read
   `a.txt`, append a fourth line and ask again. New sees it, old does not: the old
   session's watcher did not come back.
5. Record the Claude Code version, the variant, and seen or missed for each
   watcher. If running sessions do see the change, remove the line from
   `lib/heal.sh` (`FSG_COSTS`), `lib/hint.sh` and the README.

Result: _not checked yet._

## 3. Results

Print every recorded trial as a table and paste it below:

```sh
$G trial --summary
```

Optional: after the first heal, watch the next Time Machine backup. If
it takes clearly longer than usual or logs a deep scan
(`log show --last 3h --predicate 'subsystem == "com.apple.TimeMachine"' | grep -iE 'deep|fsevents|full'`),
the restart cost noted in the README is confirmed.

### Recorded results

_Not run yet. Paste the `trial --summary` table and the notes here._

| Variant | Healed (runs) | Median heal time after drain | Workarounds | Manual steps | Notes |
|---|---|---|---|---|---|
| none (step 0) | | | | | |
| A | | | | | |
| B | | | | | |
| C | | | | | |

## 4. After the trials

1. Pick the winner: healed in both runs first, then the shortest heal time after
   the drain, then the fewest workarounds.
2. Set it as the default: change `FSG_DOCKER_VARIANT` in
   `plugins/fseventsd-guard/config.defaults`. Fill in the results above, and the
   wall time in `docs/DESIGN.md` §6 and the README "What a restart costs". Commit.
3. Close the trial window early by re-running `$G install` without
   `--trial-hours` (one sudo prompt), or let it expire. `$G doctor` shows its state.
4. Every machine picks up the new default on its next `$G install` (doctor warns
   while the installed copy is stale).
