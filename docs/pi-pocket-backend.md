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

Secondmates are not supported: a secondmate needs a top-level session, and Pi Pocket does not start one for an extension.

## The worker bridge

The drop-in serves the bridge as a durable background task in the main conversation, started when that conversation takes the home's session lock and after every server restart.
Its files live under `state/pocket-bridge/`, owner-only:

| Path | Meaning |
| --- | --- |
| `heartbeat.json` | The serving server process, conversation, Pi Pocket version, and whether linked-session stop and archive exist; the client treats a stale one as "not running". |
| `requests/<id>.json` | One request the client wrote; the drop-in answers it once and removes it. |
| `results/<id>.json` | The answer, which the client reads and removes. |
| `workers/<task>.json` | The worker registry: one durable record per task, which a restarted server re-attaches from. |

The drop-in answers a request only when all of the following hold, the same trust check as the main session's own marker (`fm_pi_pocket_trusted_server_pid` in [`bin/fm-session-lock-lib.sh`](../bin/fm-session-lock-lib.sh)):

- The request is a private regular file of the server's user.
- It names this server process and the conversation that holds the home's lock.
- It carries a bridge secret from this server process, `FM_PI_POCKET_BRIDGE_TOKEN`.
  The drop-in generates separate secrets for main and supervision commands and never writes them to disk or gives them to a worker.
  Main's secret permits every verb.
  The supervision secret permits only `status`, `state`, `capture`, `send`, `interrupt`, `configure`, and `kill`, never `spawn`.
- Its writer is alive and its parent chain reaches this server.
  Where `/proc` shows the writer's environment, that environment must also carry the main conversation's Pi Pocket marker and, for the supervision secret, `FM_SUPERVISION_ACTOR=branch`.

A worker's own commands carry `FM_HOME` for its recorded Firstmate home, but an empty conversation marker, server pid, and bridge secret, so a worker cannot drive the bridge, even on a platform where another process's environment cannot be read.

| Verb | What the drop-in does |
| --- | --- |
| `status` | Reports the serving Pi Pocket version and stop-and-archive capability. |
| `spawn` | Main only: starts a linked session with `linkedSessions.start` in the task worktree, on the dispatch model and effort, with a neutral first message, and records the worker; a repeat for a live task returns the same session. |
| `configure` | Records the task environment the worker's commands get. |
| `send` | Submits text into the worker's Durable conversation with a request id: a follow-up while it is busy, or a steer when asked. |
| `interrupt` | Aborts the worker's run. |
| `capture` | Returns the last lines of the worker's transcript as text. |
| `state` | `alive` with `busy`/`idle`, `missing` (archived, retired, or gone), or `dead` (its last run failed, when Pi Pocket reports that). |
| `kill` | Tears the worker down; see [Teardown](#teardown). |

## Spawn

`fm-spawn --backend pi-pocket` runs these steps in order:

1. It checks that the bridge answers, before any lease.
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
- **Blocked tools.** The supervisor tools `fm_watch_arm_pocket`, `fm_branch_report`, `fm_branch_outcomes`, and `fm_branch_processed` are omitted from a worker's model tool declarations, instructions, codemode prompt, and sandbox inventory (`ALL_TOOLS` and callable bindings), with the tool-call guard still refusing forced calls.
  Main and supervision sessions keep their existing tool declarations.
  Pi Pocket's delegation tools (`subagent`, `team`, `schedule`, `watch_pr`, and every `session_*` tool) are blocked in a worker, and so is every tool in `config/crew-exclude-tools`.

## Steering and control

`fm-send` works as for every worker: the message lands in the task inbox, and the doorbell is a submit.
`fm-control.sh` maps the lifecycle verbs as follows:

| Action | Pocket worker |
| --- | --- |
| Escape, Ctrl-C | Abort the running turn. |
| Enter | No-op: there is no composer. |
| Ctrl-U, shell typing | Unsupported. |
| `interrupt` | Abort, confirmed from the worker's busy state. |
| `exit` | The [teardown](#teardown) below, proven by the session reading `missing`. |
| `relaunch` | Main only: a new linked session in the same worktree after tearing down the old one; a supervision-session request refuses before stopping the old worker. |

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

When Pi Pocket has `linkedSessions.stop` and `archive`, a kill stops the run, archives the session, and succeeds only when the list reads it back archived and not busy.
The transcript stays visible in Pi Pocket.

Without them, a kill aborts the run and marks the worker retired in the registry.
The session stays listed in Pi Pocket, but the drop-in refuses every later Firstmate send, interrupt, and environment change to it, and `state` reads it `missing`.

`fm-teardown.sh` runs the kill before it returns the worktree.

## Version detection

The drop-in detects each capability by the presence of its API on `host` rather than by version:

- `linkedSessions.stop` and `archive` select the stop-and-archive teardown.
- A `run.ended` `outcome` of `failed`, or a `failed` field on a listed session, marks the worker `dead` until its next run starts.
- Without that signal, a failed run reads idle.

The `status` verb and the heartbeat report `host.pocketVersion`.
Stop, archive, and the run-failed signal are proposed upstream in TannerMidd/pi-pocket pull requests 247 and 248.

## Active limits

- Experimental; no dedicated real-backend CI lane.
- Ship and scout workers only; no secondmates.
- Only the `pi` harness, on models from the owner's subagent list.
- A request waiting for a person's approval inside the worker is not reported to Firstmate.
- Teardown without stop and archive leaves the session listed in Pi Pocket.

## Regression entry points

```sh
bin/fm-test-run.sh tests/fm-backend-pi-pocket.test.sh tests/fm-pi-pocket-dropin.test.sh
```

[`tests/fm-backend-pi-pocket.test.sh`](../tests/fm-backend-pi-pocket.test.sh) covers the adapter, the bridge client, and the `fm-spawn`, `fm-control`, and `fm-teardown` paths against a [fake bridge](../tests/pi-pocket-fake-bridge.mjs) and fake Treehouse.
[`tests/fm-pi-pocket-dropin.test.sh`](../tests/fm-pi-pocket-dropin.test.sh) runs the drop-in's side of the bridge in a real Pi Pocket app on temporary data directories with a scripted model.
It covers the unfenced brief, the task environment with `FM_HOME` but no supervisor identity, hidden supervisor tools and refused forced calls without changing main or supervision sessions, supervision commands and their restricted bridge access, the seatbelts, trust, the model-list and spend refusals, the run events and their reconcile, interrupt, both teardowns, and the restart nudge.
[`verification/runtime-backends.md`](verification/runtime-backends.md#pi-pocket-workers) records the dated results.
