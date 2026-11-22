# Pi Pocket worker backend

`pi-pocket` is an experimental, explicit-only backend that runs ship and scout workers as Pi Pocket sessions instead of terminal panes.
Each worker is a linked session of the main Firstmate Pi Pocket conversation, so it shows up in the Pi Pocket app under that conversation, while Treehouse keeps owning the task worktree.
Nothing is typed into a terminal: the [Firstmate Pi Pocket drop-in](../pi-pocket/firstmate.ts) starts and steers the session through Pi Pocket's extension API, and Firstmate's scripts reach the drop-in through a file-based worker bridge.
[`bin/backends/pi-pocket.sh`](../bin/backends/pi-pocket.sh) owns the backend primitives, [`bin/fm-pi-pocket-bridge.mjs`](../bin/fm-pi-pocket-bridge.mjs) owns the bridge client, and [`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns shared selection and metadata semantics.

Terminal workers stay the default.
A Pi Pocket primary that has not opted in keeps opening its workers in herdr ([`configuration.md`](configuration.md#backend-selection-order)).

## Selection

Select Pocket workers with local `config/backend` containing `pi-pocket`, `FM_BACKEND=pi-pocket` for one launch, or `--backend pi-pocket` for one task.
The backend is never auto-detected and never the default: [`bin/fm-backend.sh`](../bin/fm-backend.sh) lists it as spawn-capable, but no runtime marker selects it.

It works only from marked commands of the main Firstmate Pi Pocket conversation, which holds this home's session lock, and its supervision session.
Only the main session can start or relaunch workers.
A spawn from anywhere else, or while the drop-in's bridge is not running, refuses with a reason and never falls back to another backend.

## Requirements

- A Pi Pocket server running the Firstmate drop-in ([`bin/fm-pi-pocket-install.sh`](../bin/fm-pi-pocket-install.sh)) with linked sessions (`host.linkedSessions`) and `host.commandEnv`, and the main Firstmate session started there, so it holds the home's session lock.
- At least one model on the owner's list of models for subagents and linked sessions in Pi Pocket's settings.
  A worker can only run on a listed model; with an empty list every spawn refuses.
- `node` and `treehouse`.
- The `pi` harness.
  The worker is Pi Pocket's own agent, so `fm-spawn` refuses every other harness, a raw launch command, `config/launch-env-allowlist`, and a worker account pin: Pi Pocket runs the worker with its own environment and the owner's accounts.

Secondmates are not supported: Pi Pocket can start top-level sessions, but Firstmate has not implemented their isolated home, lock, parent-channel, and lifecycle integration.

## Runner home pilot

Install the drop-in on the Pi Pocket server, not on the linked computer.
Use a matching Firstmate checkout on the runner, with `pi-pocket/runner-owner.sh`, `pi-pocket/runner-monitor.sh`, and the runner support in `bin/`.
This pilot is for a trusted, private home: use a runner you control and do not share the Firstmate conversation.
To opt in, the owner manually creates a gitignored `config/pi-pocket-home-id` in the Firstmate home on the runner.
Sending `ok` in chat does not create it.
It must be a regular file with one random UUID v4.
Generate a new ID for each home on each computer; do not share, link, or copy the file between homes.
From the runner home's root, create it once with Node:

```sh
mkdir -p config
node -e 'require("node:fs").writeFileSync("config/pi-pocket-home-id", require("node:crypto").randomUUID() + "\n", { flag: "wx", mode: 0o600 })'
```

Open a new top-level Pi Pocket session on the runner in the home folder and send a message as the owner.
Only a direct owner turn in a known top-level session can claim the home.
Forks, linked children, worktrees, and secondmate homes cannot claim it.
A session opened before the add-on saw its creation can detect the home but needs a new top-level session to claim it.

The add-on uses the session's runner environment to take the existing `state/.lock` slot on that computer.
A native Firstmate or another Pi Pocket conversation cannot take the same slot while it is held.
On an ordinary claim, the helper moves a legacy PID lock aside only if the runner can verify that the recorded process is gone.
It retains the file as a dated `.lock.legacy-dead-…` sibling and reports the name; a live or uncertain owner stays untouched.
On the first claim, `bin/fm-session-start.sh` runs the home-local bootstrap and prints a digest, capped at 48 KiB.
Startup does not run network checks or drain wakes.
Only after startup completes does the add-on start one durable timer for that owner generation.
It scans a bounded page of local status updates and turn-end records and notifies this conversation of queued work, including inbox notes.
It does not start a native watcher, write a native heartbeat, run GitHub or Relay checks, or start a supervision session or workers.
No work is monitored while the runner is offline or asleep.
It checks again after the runner reconnects, without a new message and without rerunning startup.
After the server restarts or the extension reloads, send a direct owner message in the same conversation to verify the binding and resume monitoring.
A lost link, elapsed time, server restart, or removal of the opt-in does not clear the lock.
The add-on never falls back to server files, even if two computers use the same path.

To hand off, archive the owning conversation and send a message in a new top-level session on the same runner home.
An archive that the add-on observed clears the old generation on that next eligible turn, not at archive or reconnect time.
Unarchive before the next turn keeps the old owner.
After a server restart or extension reload, the add-on cannot confirm earlier archive events with the current public Pi Pocket API.
For an active or unconfirmed owner, the refusal gives an exact `take over <generation>` message.
Send that message yourself in the new session to take over that specific lock.
Deletion alone does not authorize a handoff.

If startup was interrupted and the helper cannot confirm that it stopped, the lock remains held even after archive or takeover.
For that case only, verify on the runner that startup and its children have stopped, then run `bash pi-pocket/runner-owner.sh pi-pocket-runner-v1 recover <home> <installation-uuid> <home-uuid> <conversation> <generation-uuid>` from the canonical home directory.
The IDs are in order after the version in `state/.lock/owner`.
Do not delete the lock or its retired records by hand.

Pocket shows monitoring health and the most recent successful check; `fm-inbox.sh ready` does not infer live readiness from the lock.
Existing away, quiet, catch-up, or native watcher state pauses automatic handling and is not changed by the pilot.
The runner owner's tool profile supports scoped reads, context tools, and `fm_runner`; it has no shell, write, or lifecycle tools.
Local server sessions do not need this marker and still use the existing supervision and worker backend.

### Runner wake handling

On an automatic runner wake, call `fm_runner` with `action: "drain"` and handle the returned batch, including open decisions and unread status.
Then call `ack` with that batch's exact receipt.
A submission, model answer, or incomplete drain does not acknowledge queued work.
For an inbox note in the batch, use `inbox-read`, `inbox-reply` when a durable reply is due, and `inbox-ack` after handling it.
Do not use a wake acknowledgement to mark a note handled.
Use `status` to check the monitor and `repair` to restore its task if it failed while the current owner and runner are available.

## Pocket Calm

Calm folds Firstmate operational inputs in Pi Pocket where the app supports entry presentation.
The model still reads the full text.
Calm defaults to on; the owner can toggle it with `/firstmate-calm` from a server or runner session.
The drop-in stores one setting in the Pi Pocket server's data directory and does not read or write either home's `config/calm`.

## The worker bridge

The drop-in serves the bridge as a durable background task in the main conversation, started when that conversation takes the home's session lock and after every server restart.
Its files live under `state/pocket-bridge/`, owner-only:

| Path | Meaning |
| --- | --- |
| `heartbeat.json` | The serving server process, conversation, Pi Pocket version, and whether linked-session stop and archive exist; refreshed independently while the invocation owns the home, so slow requests do not cause a false "not running" result. |
| `requests/<id>.json` | One request the client wrote; the drop-in answers it once and removes it. |
| `results/<id>.json` | The answer, which the client reads and removes. |
| `workers/<task>.json` | The worker registry: one durable record per task, which a restarted server re-attaches from. |

The drop-in answers a request only when all of the following hold, the same trust check as the main session's own marker (`fm_pi_pocket_trusted_server_pid` in [`bin/fm-session-lock-lib.sh`](../bin/fm-session-lock-lib.sh)):

- The request is a private regular file of the server's user.
- It names this server process and the conversation that holds the home's lock.
- It carries a bridge secret from this server process, `FM_PI_POCKET_BRIDGE_TOKEN`.
  The drop-in generates separate secrets for main and supervision commands and never writes them to disk or gives them to a worker.
  Main's secret permits every verb.
  The supervision secret permits only `status`, `preflight`, `state`, `capture`, `send`, `interrupt`, `configure`, and `kill`, never `spawn`.
- Its writer is alive and its parent chain reaches this server.
  Where `/proc` shows the writer's environment, that environment must also carry the main conversation's Pi Pocket marker and, for the supervision secret, `FM_SUPERVISION_ACTOR=branch`.

A worker's own commands carry `FM_HOME` for its recorded Firstmate home, but an empty conversation marker, server pid, and bridge secret, so a worker cannot drive the bridge, even on a platform where another process's environment cannot be read.

| Verb | What the drop-in does |
| --- | --- |
| `status` | Reports the serving Pi Pocket version and stop-and-archive capability. |
| `preflight` | Read-only launch eligibility for main or supervision: returns the selected model and any explicit effort without starting or changing a worker; see [Launch preflight](#launch-preflight). |
| `spawn` | Main only: starts a linked session with `linkedSessions.start` in the task worktree, on the dispatch model and effort, with a neutral first message, and records the worker; a repeat for a live task returns the same session. |
| `configure` | Records the task environment the worker's commands get. |
| `send` | Submits text into the worker's Durable conversation with a request id: a follow-up while it is busy, or a steer when asked. |
| `interrupt` | Aborts the worker's run. |
| `capture` | Returns the last lines of the worker's transcript as text. |
| `state` | `alive` with `busy`/`idle`, `missing` (archived, retired, or gone), or `dead` (its last run failed, when Pi Pocket reports that). |
| `kill` | Tears the worker down; see [Teardown](#teardown). |

## Launch preflight

Before leasing a worktree for a new task, or recording a relaunch note and stopping an existing worker, Firstmate checks the resolved launch against Pocket's rules.
It refuses a harness other than `pi`, a raw launch command, `config/launch-env-allowlist`, or a worker account pin, without consulting a native agent's catalog or login.
The bridge's read-only `preflight` then checks linked-session support, the main session's spend hold, the model against the owner's current allowed and usable models, and any explicit effort against that model's supported levels.
With no model named, it selects the first usable listed model.
A missing or nonresponsive bridge also refuses.
A refused relaunch leaves the original worker running and unarchived, with its instructions and task binding unchanged.
The actual start repeats its admission checks because eligibility can change after preflight; a later refusal still preserves the worktree and progress note but cannot restore a stopped conversation.

## Spawn

`fm-spawn --backend pi-pocket` runs these steps in order:

1. It runs [launch preflight](#launch-preflight), before any lease.
2. It leases the Treehouse worktree.
3. It starts the linked session through the drop-in.
4. It gives the session its task environment.
5. It arms the busy record idle.
6. It submits the launch brief.

The task records `pocket_session=<session id>`, with `window=fm-<id>` as the shared alias.

Pi Pocket fences a linked session's first message and every `linkedSessions.send` as another agent's request ("a request, not an order"), so neither carries the task.
The brief and every later steer go through Durable `conversation.submit`, which is not fenced.
The first message only says that the task follows.

A submit bypasses Pi Pocket's own model-list and spend checks, so the drop-in checks both before every submit into a worker.
It refuses when:

- the worker's model is no longer on the owner's subagent list,
- the main session's spend is held, or
- the worker's own spend is held.

`spawn` also refuses an unlisted model and a held main session; with no model named, the worker takes the first usable listed model.
Each refusal reaches `fm-spawn` or `fm-send` as a blocker naming the reason; a refused start hands the lease back.
A start Pi Pocket refuses (for example main in plan mode) is reported the same way.

The drop-in gives a worker:

- **Task environment.** Its commands get `FM_HOME`, `FM_TASK_ID`, `FM_TASK_INBOX`, `GOTMPDIR`, the Git hook path, and the other launch facts a pane worker exports, through `host.commandEnv`.
  `FM_HOME` always names the worker's recorded Firstmate home, including after a restart with an older registry, and a supplied task environment cannot replace it.
- **System-prompt section.** The task-worker channel statement, plus the worker's limits.
- **Blocked tools.** The supervisor tools `fm_watch_arm_pocket`, `fm_branch_report`, `fm_branch_outcomes`, `fm_branch_processed`, and `fm_posture_pocket` are omitted from a worker's model tool declarations, instructions, codemode prompt, and sandbox inventory (`ALL_TOOLS` and callable bindings), with the tool-call guard still refusing forced calls.
  Main and supervision sessions keep their existing tool declarations.
  The same inventory filters and forced-call guard also apply to Pi Pocket's delegation tools and every tool in `config/crew-exclude-tools` (the delegation list is maintained in [`subagent-guard.md`](subagent-guard.md#pi-pocket-wired-in-the-drop-in)).

## Steering and control

`fm-send` works as for every worker: the message lands in the task inbox, and the doorbell is a submit.
Pocket doorbell retries use the inbox record identity, so a lost bridge reply does not enqueue a second copy.
`fm-control.sh` maps the lifecycle verbs as follows:

| Action | Pocket worker |
| --- | --- |
| Escape, Ctrl-C | Abort the running turn. |
| Enter | No-op: there is no composer. |
| Ctrl-U, shell typing | Unsupported. |
| `interrupt` | Abort, confirmed from the worker's busy state. |
| `exit` | The [teardown](#teardown) below, proven by the session reading `missing`. |
| `relaunch` | Main only: [launch preflight](#launch-preflight), then a new linked session in the same worktree after tearing down the old one; a supervision-session request refuses before stopping the old worker. |

## Busy state and restarts

Pi Pocket's `run.started` and `run.ended` events feed the busy record through [`bin/fm-busy-event.sh`](../bin/fm-busy-event.sh), and each idle transition writes `state/<id>.turn-ended`.
These events are not exactly-once: a hard close loses them, and a reload can double them.
The drop-in therefore acts only on a change of the registry's busy flag, and it reconciles the flag against `linkedSessions.list()` busy every 15 seconds (`FM_POCKET_BRIDGE_RECONCILE_MS`).
Restart Pi Pocket once when upgrading from a drop-in without reload-safe bridge authentication; later drop-in hot reloads need no restart.

A Pi Pocket restart interrupts a worker's in-flight tool call; its turn ends by itself and the worker then waits.
After a restart, the drop-in sends each worker the restart cut one short nudge to continue.
A worker counts as cut when it was busy under the previous server process.
The nudge is recorded in the registry so it is sent once, and it goes through the same model and spend checks as any other submit.

## Teardown

When Pi Pocket has `linkedSessions.stop` and `archive`, a kill stops the run, archives the session, and succeeds only when the list reads it back archived and not busy and archive reports no surviving repeating schedules.
If repeating schedules remain, the kill refuses success and requires their cancellation in Pi Pocket before retrying exit or relaunch.
Each later kill rechecks instead of reusing the earlier archive result.
The transcript stays visible in Pi Pocket.

Without them, a kill aborts the run and marks the worker retired in the registry.
The session stays listed in Pi Pocket, but the drop-in refuses every later Firstmate send, interrupt, and environment change to it, and `state` reads it `missing`.

`fm-teardown.sh` runs the kill before it returns the worktree.

Neither agent stop nor archive proves that independent background commands have stopped.
Pi Pocket 0.28.0 has no public session-job list/stop/quiesce API, and its `host.background` and `host.schedules` services are internal-only.
Firstmate cannot yet verify complete job shutdown before replacement; an old build or dev server can overlap a replacement in the same folder.
Until a public capability exists, stop those jobs in Pi Pocket before relaunching; the existing cwd-based process cleanup in full teardown remains a partial protection, not proof of session-wide quiescence.

## Version detection

The drop-in detects each capability by the presence of its API on `host` rather than by version:

- `linkedSessions.stop` and `archive` select the stop-and-archive teardown.
- A `run.ended` `outcome` of `failed`, or a `failed` field on a listed session, marks the worker `dead` until its next run starts.
- Without that signal, a failed run reads idle.

The `status` verb and the heartbeat report `host.pocketVersion`.
Stop, archive, and the run-failed signal shipped in Pi Pocket 0.28.0.

## Active limits

- Experimental; no dedicated real-backend CI lane.
- Ship and scout workers only; no secondmates.
- Only the `pi` harness, on models from the owner's subagent list.
- A request waiting for a person's approval inside the worker is not reported to Firstmate.
- Teardown without stop and archive leaves the session listed in Pi Pocket.
- Independent background-command and schedule cancellation needs a public upstream session-job API; see [Teardown](#teardown).

## Regression entry points

```sh
bin/fm-test-run.sh tests/fm-backend-pi-pocket.test.sh tests/fm-pi-pocket-dropin.test.sh
```

[`tests/fm-backend-pi-pocket.test.sh`](../tests/fm-backend-pi-pocket.test.sh) covers the adapter, the bridge client, and the `fm-spawn`, `fm-control`, and `fm-teardown` paths against a [fake bridge](../tests/pi-pocket-fake-bridge.mjs) and fake Treehouse.
[`tests/fm-pi-pocket-dropin.test.sh`](../tests/fm-pi-pocket-dropin.test.sh) runs the drop-in's side of the bridge in a real Pi Pocket app on temporary data directories with a scripted model.
On a runner-capable checkout it links a separate temporary runner process.
It checks local and runner homes, identical paths on separate filesystems, claim and startup, runner monitor delivery and acknowledgement, reconnect, archive and owner takeover, and the absence of a native watcher, supervision branch, and workers on the runner.
It also verifies the shared Calm setting across a server restart.
It covers wake-delivery faults on both sides of an arm close, resumed-grant refusal, parallel reports, concurrent home discovery, slow-request heartbeats, surviving-schedule refusal, the unfenced brief, the task environment with `FM_HOME` but no supervisor identity, worker tool inventories and forced-call refusals without changing main or supervision sessions, supervision commands and their restricted bridge access, read-only launch preflight, the seatbelts, trust, the model-list and spend refusals, the run events and their reconcile, interrupt, both teardowns, and the restart nudge.
[`verification/runtime-backends.md`](verification/runtime-backends.md#pi-pocket-workers) records the dated results.
