# Captain-message continuity router

This is **not** watcher continuity.
It routes an incoming captain chat message relative to primary-session open asks so a late or unrelated reply does not silently steer the wrong turn.

## Ownership

- Bash owner: `bin/fm-captain-message-router.sh` owns primary-home scope, state formats, classification, ephemeral router spawn, verdict normalization and logging, fail-open fallback, and pending handoffs.
- Warm runner: `bin/fm-captain-router-runner.mjs` owns the warm classifier process only - its lifetime, request framing, and per-request chat wipe. It never classifies.
- Pi hook: `.pi/extensions/fm-primary-captain-message-router.ts` owns callback-context session ids, session-lock eligibility, logical-run isolation, operational-input exclusion, bounded transcript handoff, and the warm runner's lifetime.
- The Firstmate primary agent never runs continuity.

Primary homes only (main home or a marked secondmate home).
Only the Pi session holding that home's Firstmate session lock invokes the owner.
Read-only competing sessions, child crew/scout worktrees, and no-mistakes gate agents are inert.

## Router model runner

A submit is served by the warm classifier when one is listening, and by an ephemeral Cursor spawn otherwise.

The warm classifier is one long-lived Pi RPC child owned by `bin/fm-captain-router-runner.mjs`.
It exists because a per-message vendor CLI boot dominated classification latency.
Only the Pi primary holding this home's Firstmate session lock starts one, and the hook retires it on session shutdown and on session replacement.
The runner also exits when its starter's pipe closes, so it can never outlive the primary that started it.
Each request begins with a fresh chat, so verdicts never accumulate and the Nth submit costs the same as the first.
One request is served at a time; a busy, wedged, or silent runner loses the request and recycles its child.

The ephemeral fallback uses upstream Firstmate's verified Cursor Agent CLI resolver with the account-listed `cursor-grok-4.6-low` model.
It runs non-interactively in Cursor's read-only `ask` mode and never passes `--yolo` or `--force`.
The router adds no fork-specific Cursor compatibility layer and no Pi provider extension.

## Fail-open

Errors allow the message into the current primary, and router failures are recorded where possible.
The captain is never locked out by a broken router.
Only invalid CLI usage exits non-zero.

**No verdict ever destroys a captain message.**
A `reroute` or `new` verdict may withhold the message from the current chat only when the transfer is confirmed, and it comes straight back here on any refusal or failure.
Staging records where a message belonged; it is never the reason a message was not read.

## Toggle

`config/captain-router` is the captain's kill switch (local-only; `config/` is gitignored).

```sh
printf 'off\n' > config/captain-router   # every message passes straight through
printf 'on\n'  > config/captain-router   # classification resumes
```

`off`, `0`, and `false` disable classification. Absent, `on`, or any other value means on: a router that silently disables itself is the same outage as one that silently drops messages.
`FM_CAPTAIN_ROUTER_ENABLED` overrides the file for a single invocation.

The value is read per message, so toggling takes effect on the very next send with no Pi restart.
A disabled submit still records its `same` verdict, so `verdicts.log` stays a complete audit.
`--on-settle` keeps refreshing briefs while off, so re-enabling is immediate.

## State

Local-only under `state/captain-router/` (gitignored with `state/`):

| Path | Purpose |
| --- | --- |
| `anchors.current` | Current session open-ask anchors |
| `current.session` | Session id last settled on this home |
| `sessions/<id>.brief` | Per-session topic head + anchors |
| `pending/<ts>-<digest>-<unique>.route` | Staged reroute/new handoff, consumed by `--deliver` |
| `pending/LATEST` | Basename of the newest pending route |
| `seed.<unique>` | Private seed handed to a delivered pane; swept after a day |
| `verdicts.log` | Append-only verdict rows |
| `explanations.log` | Append-only model rationale rows (audit only) |
| `failures.log` | Append-only fail-open failure rows |
| `last-handoff.txt` | Hook-side pointer after reroute/new |
| `hook.log` | Hook bookkeeping notes |

The Pi hook also writes `state/.pi-captain-router-extension-loaded` with its content-derived version and process id.
Session start accepts that marker only when its version matches the current extension and its process owns the session lock; otherwise it prints the trust-once and explicit `-e` restart paths.
Pending-route publication creates a unique candidate before atomically replacing `LATEST`.
If pointer publication fails, it removes only that candidate and preserves the previously published route and pointer before taking the fail-open path below.

### Session id assumption

Prefer `--session-id` from the hook, else `FM_CAPTAIN_ROUTER_SESSION_ID`, else the prior `current.session` pointer, else the stable home-scoped fallback `primary`.
The Pi hook reads the harness session id from the callback context session manager.

### Brief format

```text
session_id=<id>
kind=session
updated=<iso8601>
topic=<single-line head summary>
---
<normalized anchor>
...
```

Session discovery enumerates `state/captain-router/sessions/*.brief` only.
It does not scan unrelated fleet metadata.

`kind=session` is written by `--on-settle` and marks a **live conversation**, which is the only kind of brief a message can be routed to.

A brief without that marker is a hand-written **project brief**: background that helps the model understand what the captain is talking about.
A project describes a body of work, not a conversation, so it is never a reroute target: routing there would hand the message to something no session can ever receive.
The prompt lists the two in separate sections, and the owner rejects a reroute naming a project brief.

## Modes

### `--on-settle`

Reads the last assistant turn on stdin.
Extracts question anchors, refreshes `anchors.current`, writes/refreshes the current session brief, and records `current.session`.
Multi-ask mismatch (many `?` but too few distinct anchors) warns on stderr and never blocks.

### `--on-submit`

Reads the captain message on stdin and prints one machine-readable line:

```text
verdict=<same|reroute|new> target=<session-id|-> confidence=<det|model>
```

Conceptual form `reroute:<session-id>` is the `verdict=reroute target=<session-id>` wire line.

**The model decides every submit**, with two exceptions that cannot have an answer worth a spawn:

- the router is toggled off;
- the current session has no `kind=session` brief yet, so this is its **first message**, and there is no prior conversation to continue or route away from.

Both emit `same` against the current session with `confidence=det`, and both are still recorded in `verdicts.log`.

The first-message skip is not an optimization; it closes a starvation loop.
A model asked to classify a message in an empty session reads the missing history as "wrong session" and reroutes.
That stops the turn, so the turn never settles, so the brief is never written, and every later message hits the same empty state forever.

Otherwise each `--on-submit` spawns the configured router agent and honors its verdict, recorded as `confidence=model`.
The deterministic layer survives only as the fail-open fallback described below, which is what `confidence=det` now means.

`reroute` and `new` also stage `pending/*.route`, which `--deliver` then consumes.

## Cross-session delivery

`fm-captain-message-router.sh --deliver <route>` transfers one staged route and prints one line:

```text
delivery=<delivered|undelivered> kind=<reroute|new> target=<pane|-> reason=<token>
```

Pi compaction and message injection are **session-local**: `ctx.compact()` and `pi.sendUserMessage()` act on the session whose own extension calls them, and no API reaches a different live Pi process.
A router running in the primary therefore cannot compact-then-inject a target session from outside it.

What it can do is start the target session again in a visible pane.
`pi --session <id>` resumes that session's real prior context, and the seed asks the resumed session to `/compact` itself before answering.
The compaction stays where it has to be, inside the target, and the captain gets a tab they can see, switch to, and type in.
A `new` verdict opens the same kind of pane with no `--session`.

The compaction is a request, not a guarantee: it is an instruction to the resumed session, which may answer a short message directly instead.
That is the acceptable end of the tradeoff, because the delivery's job is that the message is answered with the right context, not that a particular slash command ran.

Live-fire verified (2026-08-14, herdr v0.7.1): a `new` route opened a visible tab that answered its seeded message, and a `reroute` route resumed a real prior session and answered from restored context that only that session held.

A reroute target must still exist in Pi's own session store, checked separately from its brief.
A brief outlives the session it describes, and `pi --session <id>` is create-if-missing, so resuming a dead id opens an empty session instead of failing.
That would report a successful delivery while stranding the message in a pane holding none of the context it was routed for, which is why a target the store cannot load is refused as `dead-session` before any pane is created.

Delivery is refused unless the whole visible path holds: the home's backend is herdr, and the launching process sits in a herdr pane whose workspace can be verified.
Placement inherits the launching process's own workspace exactly as a crewmate or scout spawn does, because a label cannot tell two workspaces apart.
The seed rides a private `600` file rather than argv, so a large captain paste never reaches the process list, and it carries the message plus a short frame but never the router's audit-only explanation.

The delivered pane is a plain captain conversation, marked `FM_CAPTAIN_ROUTER_DELIVERED=1`, and it runs `FM_CAPTAIN_ROUTER_DELIVERY_PI` (default `pi`).
That is deliberately not the warm classifier's `FM_CAPTAIN_ROUTER_PI`: pinning a cheap classifier executable must never silently change which Pi the captain ends up talking to.
It never runs session start, arms a watcher, or contends for this home's fleet lock, and the router extension stays inert in it because it never owns the session lock.

A route is consumed only after a delivery is confirmed.
Every refusal leaves it staged and names its own reason: `backend-not-herdr`, `herdr-unavailable`, `no-visible-workspace`, `tab-create-failed`, `launch-failed`, `no-session-brief`, `dead-session`, `self-target`, `bad-target`, `empty-message`, `unknown-kind`, `no-route-file`, `seed-write-failed`.
A failed launch closes its own dead tab.
Unlike the classify modes, `--deliver` reports failure honestly with a non-zero exit, because its caller's fallback is to deliver the message into the current session and that only works if it is told the transfer did not happen.

## Ephemeral router agent

### What the model sees

The prompt carries five framed parts:

1. Its role and the verdict semantics, including the instruction to prefer `same` for ordinary in-conversation replies that share no literal words with the last assistant turn. It also carries the addressing rule: a message that addresses Firstmate directly (`Firstmate:`, `Firstmate,`, `@firstmate`, in any letter case and usually at the start) is for the current session, so the model answers `same` at once and does not reason about routing it away. Merely mentioning firstmate the project, or discussing firstmate work in the third person, is not a direct address and stays under the normal rules.
2. A bounded, redacted excerpt of the recent chat history for the current session, supplied by the harness hook through `--chat-history-file`.
3. `OTHER LIVE SESSIONS`: every other `kind=session` brief, which are the only valid reroute targets. The current session is not listed, because a message cannot be routed to where it already is. When none exist, the prompt says so and reroute is not offered at all.
4. `PROJECT CONTEXT`: every project brief, explicitly marked as background and never a destination.
5. The captain message to classify.

The hook caps the excerpt at the newest 12 user/assistant turns and 6000 characters, and the owner re-bounds it (`FM_CAPTAIN_ROUTER_HISTORY_CHARS`, default 6000) and redacts before the model sees anything.
Redaction drops any line carrying a Firstmate operational injection and masks secret-shaped tokens and `token`/`secret`/`password`/`api_key` values.
With no history file the model still gets the briefs and the message.
The hook writes the transcript handoff through a newly created private temp directory and mode-0600 file, then removes the directory once the submit child closes.

The full prompt is handed to Cursor through a private (mode 0600) temp file under `state/captain-router/`; the spawn argv carries only a short instruction naming that file.
No history, brief, or message text ever appears in the process list, and no kernel argument-size limit applies to large captain pastes.

### What the model returns

```text
verdict=<same|reroute|new>
target=<session-id|->
explanation=<up to 3 sentences: why this verdict / what context this belongs to>
```

`verdict` and `target` drive routing.
Targets are normalized and validated by the owner, never trusted raw: `new` forces `target=-`, `same` resolves to the current session id, and `reroute` must name a different session with a `kind=session` brief on disk.
A model self-reroute is recorded and normalized to deterministic `same` without publishing a pending route.
A reroute naming a project brief is rejected the same way and recorded in `failures.log`.

`explanation` is **audit-only**.
It is appended to `explanations.log` keyed by the same message digest as `verdicts.log`, and written as an `explanation=` header field in the staged `pending/*.route`.
It is never printed on the wire line, never placed in the routed message body, and never forwarded into the routed or new session's prompt or drop-in.
It exists so the captain can audit why a verdict was chosen and dial the prompt instructions over time.

### Fail-open fallback

A warm classifier that is absent, busy, wedged, or unparseable simply loses the request, and the ephemeral spawn answers instead: the warm path can never cost the captain a verdict.
Beyond that, a private prompt-file creation, permission, or write error, a spawn error, a timeout (`FM_CAPTAIN_ROUTER_TIMEOUT_SECS`, default 90s, hard-bounded through `bin/fm-timeout-lib.sh` so the whole Cursor process group dies at the bound even on hosts with no `timeout` binary), an unparseable reply, a `reroute` naming the current session or a session with no brief, or a pending-route publication failure all fall back to `same` against the current session with `confidence=det` and a `failures.log` row.
The captain is never locked out by a broken or slow router.

### Configuration

The ephemeral fallback always uses upstream Firstmate's Cursor Agent CLI resolver and defaults to `cursor-grok-4.6-low`.
Set `FM_CAPTAIN_ROUTER_MODEL` to another model id exposed by the current Cursor account.
The warm classifier hosts a Pi model id, which is a different catalog, so it takes its own `FM_CAPTAIN_ROUTER_RUNNER_MODEL` and otherwise uses Pi's configured model.
`FM_CAPTAIN_ROUTER_PI` overrides the Pi executable the warm child runs, and `FM_CAPTAIN_ROUTER_RUNNER` overrides the runner script the hook starts.
The Cursor model id carries the reasoning level because Cursor exposes no separate effort flag.

Both defaults are deliberately unchanged.
The warm runner can host a faster or free model later by pinning `FM_CAPTAIN_ROUTER_RUNNER_MODEL`, and that is the only change such a swap needs.
The free ids available here were measured and none was usable: `opencode-zen/mimo-v2.5-free` refuses the classifier role or answers without a target, `opencode-zen/north-mini-code-free` returns an upstream-unavailable error, `oc/deepseek-v4-flash-free` and `oc/big-pickle` returned no text, and the OpenRouter `cohere/north-mini-code:free` id has no API key in this Pi.
Re-measure before pinning one; a model that cannot return a parseable verdict costs a fail-open on every submit.
Launch is non-interactive Cursor `--print --mode ask`, pinned to the Firstmate home as its workspace.
Shell submit-path fixtures put a recording fake `cursor-agent` executable on `PATH`, so those regressions cross the verified resolver, shared timeout owner, private prompt-file handoff, and read-only Cursor argv boundary.
No real model calls in unit tests; `tests/fm-captain-router-live-e2e.test.sh` is the opt-in live proof.

## Hook behavior

- Settle: synchronous at `agent_settled`, so session replacement cannot overtake publication.
- Submit: never on Pi's input path. The `input` handler holds the captain's send with `handled` and returns immediately, so the editor keeps accepting input while classification runs. Held sends classify one at a time, in submit order.
- A `same` verdict, and every fail-open fallback, re-injects the held send with `pi.sendUserMessage`, so the delivered copy arrives as `source=extension` and is not classified again.
- A send starting with `/` passes through instead of being held, because a re-injected copy would skip Pi's skill and template expansion. It is still classified.
- A held send keeps its images: the injected copy carries the original text block plus every image block.
- Both paths run only while this Pi process owns the Firstmate session lock.
- Every accepted Pi `input` is bound to its callback-context session and logical run before classification, including queued steering, follow-up, RPC, interactive, and extension-delivered input.
- A queued follow-up or steer arriving after `agent_end` but before `agent_settled` is classified against that run's candidate transcript when present, rather than stale settled history.
- `before_agent_start` is only a deduplicated fallback for an accepted prompt path that emitted no `input` event.
- `agent_end` retains only a candidate response and bounded transcript; `agent_settled` publishes them only when that same session and run saw captain input and no Firstmate operational input.
- A mixed captain and operational run publishes no anchors or recent history, including when operational input arrives after an earlier `agent_end`.
- `same`: allow.
- `reroute` / `new`: hand the newest staged route to `--deliver`, then record hook-side `last-handoff.txt` with whether the transfer happened; normalized self-reroutes and publication failures continue as `same` without claiming a handoff.
- Withholding the held send from this chat is conditional on a confirmed transfer, never the default. Any refusal, failure, or unexpected delivery output injects it here.
- Always fail-open: a held send is never dropped, whatever the verdict.

## Current limits

- Multi-ask mismatch warns and never blocks.
- Delivery needs the herdr backend and a herdr-hosted launching process; every other runtime refuses and keeps answering in the current session.
- The primary hook is available for Pi only.
- No free classifier model is pinned; the warm child uses Pi's configured model until a measured free id can return a parseable verdict.

## Verification

```sh
bin/fm-test-run.sh tests/fm-captain-message-router.test.sh
bin/fm-lint.sh bin/fm-captain-message-router.sh bin/fm-captain-router-runner.mjs

# Opt-in live proof that submit really reaches a model (pin a model you are authenticated for).
FM_CAPTAIN_ROUTER_LIVE_E2E=1 FM_CAPTAIN_ROUTER_MODEL=<cursor-model-id> bash tests/fm-captain-router-live-e2e.test.sh
```

The script header owns exact flags, environment overrides, and state mechanics.
