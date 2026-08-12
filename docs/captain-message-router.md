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
| `failures.log` | Append-only fail-open failure rows |
| `last-handoff.txt` | Hook-side pointer after reroute/new (P1) |
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

Deterministic layer:

1. `same` when the message matches the current session anchors.
2. `reroute` when it uniquely matches exactly one other session brief.
3. `new` when no session briefs match and anchors are empty or the message is substantial and unrelated.
4. Otherwise ambiguous (including short acknowledgements while asks remain, or multi-brief collisions): spawn the ephemeral router agent.

`reroute` and `new` also stage `pending/*.route` for P2 drop-in.
P1 does **not** auto-spawn a new primary session and does **not** compact/inject across sessions.

## Ephemeral router agent

Config-driven via optional `config/crew-dispatch.json` roles:

```json
"roles": {
  "continuity": {
    "harness": "pi",
    "model": "cursor/grok-4.5",
    "effort": "low"
  }
}
```

`roles.continuity` wins over `roles.router`.
When absent, the owner defaults to Pi / `cursor/grok-4.5` / `low`.
Pi thinking levels are `low|medium|high|xhigh|max` (no `slow`); `slow` maps to `low`.
Launch is print-mode Pi with no session, extensions, tools, or context files.
Unit tests mock the agent through `FM_CAPTAIN_ROUTER_AGENT_CMD` (prompt on stdin, verdict on stdout).
No real model calls in unit tests.

## Hook behavior (P1)

- Settle: fire-and-forget.
- Submit: synchronous so bash can stage pending routes before the primary turn proceeds.
- `same`: allow.
- `reroute` / `new`: record hook-side `last-handoff.txt`; do not inject continuity into primary context.
- Always fail-open.

## Open assumptions (P1 defaults)

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
```

The script header owns exact flags and state mechanics.
`docs/configuration.md` owns the `roles` schema for `config/crew-dispatch.json`.
