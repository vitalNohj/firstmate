# Captain-message continuity router

This is **not** watcher continuity.
It does not touch `docs/watcher-continuity.md`, `bin/fm-continuity-*`, or the paused `firstmate-context-continuity-1` work.
It routes an incoming captain chat message relative to primary-session open asks so a late or unrelated reply does not silently steer the wrong turn.

## Ownership

- Bash owner: `bin/fm-captain-message-router.sh` owns truth (anchors, briefs, classification, ephemeral router spawn, verdict log, pending handoffs).
- Pi hook: `.pi/extensions/fm-primary-captain-message-router.ts` is a thin trigger only.
- The Firstmate primary agent never runs continuity.

Primary homes only (main home or a marked secondmate home).
Child crew/scout worktrees and no-mistakes gate agents are inert.

## Fail-open

Errors allow the message into the current primary and record a failure.
The captain is never locked out by a broken router.
Only invalid CLI usage exits non-zero.

## State

Local-only under `state/captain-router/` (gitignored with `state/`):

| Path | Purpose |
| --- | --- |
| `anchors.current` | Current session open-ask anchors |
| `current.session` | Session id last settled on this home |
| `sessions/<id>.brief` | Per-session topic head + optional Notion continuity headers + anchors |
| `notion-contexts.jsonl` | Mirror of buddy-exported Notion Context Router JSONL |
| `pending/<ts>-<digest>.route` | Staged reroute/new handoff for P2 |
| `pending/LATEST` | Basename of the newest pending route |
| `verdicts.log` | Append-only verdict rows |
| `explanations.log` | Append-only model rationale rows (audit only) |
| `failures.log` | Append-only fail-open failure rows |
| `last-handoff.txt` | Hook-side pointer after reroute/new |
| `hook.log` | Hook bookkeeping notes |

### Session id assumption

Prefer `--session-id` from the hook, else `FM_CAPTAIN_ROUTER_SESSION_ID`, else the prior `current.session` pointer, else the stable home-scoped fallback `primary`.
Hooks should pass the harness session id when the event exposes one.

### Brief format

```
session_id=<id>
updated=<iso8601>
topic=<single-line head summary>
semantics=<optional slash-separated Notion semantics>
notion_url=<optional>
notion_name=<optional Contexts DB name>
github=<optional>
schema=<optional>
herdr_session=<optional>
herdr_target=<optional>
herdr_workspace=<optional>
---
<normalized anchor>
...
```

Optional Notion continuity headers sit after `topic=` and before `---`.
`bin/fm-captain-notion-sync.sh` upserts them from a buddy-exported JSONL mirror.
`--on-settle` refreshes `topic` + anchors but preserves those optional headers when already present, and re-emits unique `semantics` path tokens as extra anchor lines so deterministic reroute can still match them.

Session discovery enumerates `state/captain-router/sessions/*.brief` only.
It does not scan unrelated fleet metadata.

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

**The model decides every submit.**
There is no deterministic classification shortcut: each `--on-submit` spawns the configured router agent and honors its verdict, recorded as `confidence=model`.
The deterministic layer survives only as the fail-open fallback described below, which is what `confidence=det` now means.

`reroute` and `new` also stage `pending/*.route` for P2 drop-in.
This phase does **not** auto-spawn a new primary session and does **not** compact/inject across sessions.

## Ephemeral router agent

### What the model sees

The prompt carries four framed parts:

1. Its role and the verdict semantics, including the instruction to prefer `same` for ordinary in-conversation replies that share no literal words with the last assistant turn.
2. A bounded, redacted excerpt of the recent chat history for the current session, supplied by the harness hook through `--chat-history-file`.
3. Every session brief under `sessions/*.brief`, so the model can reason about what each session is about.
4. The captain message to classify.

The hook caps the excerpt at the newest 12 user/assistant turns and 6000 characters, and the owner re-bounds it (`FM_CAPTAIN_ROUTER_HISTORY_CHARS`, default 6000) and redacts before the model sees anything.
Redaction drops any line carrying a Firstmate operational injection and masks secret-shaped tokens and `token`/`secret`/`password`/`api_key` values.
With no history file the model still gets the briefs and the message.

### What the model returns

```text
verdict=<same|reroute|new>
target=<session-id|->
explanation=<up to 3 sentences: why this verdict / what context this belongs to>
```

`verdict` and `target` drive routing.
Targets are normalized and validated by the owner, never trusted raw: `new` forces `target=-`, `same` resolves to the current session id, and `reroute` must name a session that has a brief on disk.

`explanation` is **audit-only**.
It is appended to `explanations.log` keyed by the same message digest as `verdicts.log`, and written as an `explanation=` header field in the staged `pending/*.route`.
It is never printed on the wire line, never placed in the routed message body, and never forwarded into the routed or new session's prompt or drop-in.
It exists so the captain can audit why a verdict was chosen and dial the prompt instructions over time.

### Fail-open fallback

A spawn error, a timeout (`FM_CAPTAIN_ROUTER_TIMEOUT_SECS`, default 90s when a `timeout`/`gtimeout` binary exists), an unparseable reply, or a `reroute` naming a session with no brief all fall back to `same` against the current session with `confidence=det` and a `failures.log` row.
The captain is never locked out by a broken or slow router.

### Configuration

Config-driven via optional `config/crew-dispatch.json` roles:

```json
"roles": {
  "continuity": {
    "harness": "pi",
    "model": "cursor/grok-4.6",
    "effort": "low"
  }
}
```

`roles.continuity` wins over `roles.router`.
When absent, the owner defaults to Pi / `cursor/grok-4.6` / `low`.
Each field falls back independently, so a partial profile still inherits the built-in defaults.
Pi thinking levels are `low|medium|high|xhigh|max` (no `slow`); `slow` maps to `low`.
Launch is print-mode Pi with no session, extensions, tools, or context files.
Unit tests mock the agent through `FM_CAPTAIN_ROUTER_AGENT_CMD` (prompt on stdin, verdict block on stdout), or put a recording fake harness on `PATH` to assert the real spawn argv.
No real model calls in unit tests; `tests/fm-captain-router-live-e2e.test.sh` is the opt-in live proof.

## Hook behavior

- Settle: fire-and-forget.
- Submit: synchronous so bash can stage pending routes before the primary turn proceeds.
- The hook captures a bounded transcript excerpt on `agent_end` and hands it to the owner on the next submit through `--chat-history-file`, dropping Firstmate's own operational injections first.
- `same`: allow.
- `reroute` / `new`: record hook-side `last-handoff.txt`; do not inject continuity into primary context.
- Always fail-open.

## Open assumptions (current defaults)

- Multi-ask mismatch: surface/warn only (not block).
- `new`: stage under `pending/` for captain/next activation; do not auto-spawn a full new primary unless a safe Firstmate API exists later.
- Cross-session compaction and drop-in: deferred to P2.
- Script name remains `fm-captain-message-router.sh`.

## P2 (not in this phase)

- Full cross-session compact + inject / drop-in into the target session.
- Auto-spawn of a new primary session for `new` when a safe API exists.
- Broader harness hook coverage beyond Pi.

## Notion continuity

Firstmate can own Continuity directly via `bin/fm-notion-continuity.sh` when a local token and data-source ids are configured.
Buddy JSONL export remains an optional air-gap path.

### Firstmate-owned (Notion API)

```sh
# Token: FM_NOTION_TOKEN / NOTION_TOKEN, or gitignored config/notion-token
# Ids: config/notion-continuity.env (see docs/examples/notion-continuity.env.example)

bin/fm-notion-continuity.sh contexts-export
bin/fm-notion-continuity.sh context-upsert --router-session blender-axi --semantics blender/axi/cli
bin/fm-notion-continuity.sh entry-add --router-session blender-axi --text 'captain message...'
bin/fm-notion-continuity.sh sync-briefs   # export + local brief sync
```

- Never print or commit the token. Never invent DB/data-source ids.
- Skill `notion-continuity` owns agent policy (Contexts vs Entries, slash semantics, Router session ids).
- When configured, `--on-settle` best-effort runs `sync-briefs`, and submit `reroute`/`new` best-effort `entry-add` (always fail-open).

### Buddy / air-gap JSONL

```sh
bin/fm-captain-notion-sync.sh --from-jsonl /path/to/contexts.jsonl
```

- Contexts DB field **Router session** maps to the brief id (`sessions/<router_session>.brief`).
- Notion remains the continuity index; firstmate briefs are the local routing cache.
- Optional `herdr_session` / `herdr_target` / `herdr_workspace` fields are stored when present.
- Sync preserves prior settle anchors, updates Notion headers, sets `topic` from `schema` (else `name`), appends unique `semantics` tokens (split on `/`) as anchors, and mirrors the input to `state/captain-router/notion-contexts.jsonl`.
- Primary-scope and fail-open match the captain-message router (inert outside a genuine primary).

See `bin/fm-captain-notion-sync.sh --help` and `bin/fm-notion-continuity.sh --help` for flags.

## Verification

```sh
bin/fm-test-run.sh tests/fm-captain-message-router.test.sh tests/fm-captain-notion-sync.test.sh tests/fm-notion-continuity.test.sh
bin/fm-lint.sh bin/fm-captain-message-router.sh bin/fm-captain-notion-sync.sh bin/fm-notion-continuity.sh

# Opt-in live proof that submit really reaches a model (pin a model you are authenticated for).
FM_CAPTAIN_ROUTER_LIVE_E2E=1 FM_CAPTAIN_ROUTER_MODEL=<provider/model> bash tests/fm-captain-router-live-e2e.test.sh
```

Live run on 2026-08-13 with `FM_CAPTAIN_ROUTER_MODEL=codex-lb/free-low`, feeding the real captain message `I thought it was supposed to be classifying my messages to you.` (digest `69be34d349e4`), which the previous deterministic layer classified `new`/`det`:

```text
live verdict line: verdict=same target=sess-router confidence=model
explanations.log:
2026-08-13T01:09:56Z same sess-router 69be34d349e4 The user is responding to the assistant's question about rewriting the captain-message router, clarifying their understanding of its classification role - this continues the current conversation about the router.
```

The script header owns exact flags and state mechanics.
`docs/configuration.md` owns the `roles` schema for `config/crew-dispatch.json`.
