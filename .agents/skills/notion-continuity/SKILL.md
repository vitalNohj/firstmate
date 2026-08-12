---
name: notion-continuity
description: >-
  Agent-only Continuity / Notion Context Router policy for Firstmate.
  Load before reading or writing Continuity Contexts or Entries, before syncing
  captain-router session briefs from Notion, when a captain message should become
  an Entry, or when assigning Router session ids and slash semantics.
user-invocable: false
metadata:
  internal: true
---

# Notion Continuity (Contexts + Entries)

Firstmate can own Continuity itself via `bin/fm-notion-continuity.sh`.
Do **not** call the Notion API with ad-hoc `curl` that puts secrets on argv.
Do **not** invent database or data-source ids; use configured ids only.

## Surfaces

| Surface | Owner |
| --- | --- |
| Shell API | `bin/fm-notion-continuity.sh` |
| Local brief sync (no API) | `bin/fm-captain-notion-sync.sh --from-jsonl` |
| Captain-message router | `bin/fm-captain-message-router.sh` + `docs/captain-message-router.md` |
| Token / ids | gitignored `config/notion-token` or `FM_NOTION_TOKEN` / `NOTION_TOKEN`; ids in `config/notion-continuity.env` (see `docs/examples/notion-continuity.env.example`) |

## Contexts vs Entries

- **Contexts** are durable topics / workstreams. One Context per `Router session` id (maps to `state/captain-router/sessions/<id>.brief`).
- **Entries** are chronologic notes linked to a Context (captain messages, decisions, handoffs).
- Upsert a **Context** when starting or renaming a workstream, changing semantics/schema/github/herdr fields, or ensuring a Router session exists.
- Add an **Entry** when recording a captain message, decision, or notable event against an existing (or just-upserted) Context.

## Router session ids

- Safe charset only: `A-Za-z0-9._-` (same as captain-router session ids).
- Prefer short stable ids (`blender-axi`, `captain-router-p1`), not Notion page titles alone.
- The Contexts property **Router session** is the join key to local briefs.

## Slash semantics

- Store semantics as a slash path, e.g. `blender/axi/cli`.
- Local sync splits on `/` and appends unique tokens as brief anchors so deterministic reroute can match Notion semantics.
- Keep segments short, lowercase, alphanumeric; avoid spaces.

## Commands (use these)

```sh
# Export Contexts JSONL (stdout or --out PATH)
bin/fm-notion-continuity.sh contexts-export
bin/fm-notion-continuity.sh contexts-export --out /tmp/contexts.jsonl

# Create/update a Context by Router session
bin/fm-notion-continuity.sh context-upsert \
  --router-session blender-axi \
  --name blender-axi \
  --semantics blender/axi/cli \
  --schema 'Blender AXI CLI export' \
  --github https://github.com/acme/repo \
  --status 'In progress' \
  --herdr-session default \
  --herdr-target 'default:w2J:p1' \
  --herdr-workspace w2J

# Add an Entry linked to that Context
bin/fm-notion-continuity.sh entry-add \
  --router-session blender-axi \
  --text 'Captain: please resume the GLB export fix'

# Export + sync into local captain-router briefs
bin/fm-notion-continuity.sh sync-briefs
```

Buddy may still export JSONL for air-gapped sync; firstmate then runs
`bin/fm-captain-notion-sync.sh --from-jsonl <path>` (no token required on that path).

## Hook behavior (automatic when configured)

- After `--on-settle`: best-effort `sync-briefs` (fail-open).
- On submit `reroute` / `new`: stage pending as today, and best-effort `entry-add` into the matched Context or `pending`.
- Missing token/config → silent no-op. Never block the captain. Never print the token.

## Herdr fields

Optional Continuity fields `Herdr session`, `Herdr target`, `Herdr workspace` are stored when known.
Do not invent herdr targets; copy from the live Herdr session or leave empty.

## Safety

- Never commit `config/notion-token` or a filled `config/notion-continuity.env` with secrets.
- Never echo tokens into chat, logs, or argv-visible process lists when avoidable.
- Fail open: Continuity must not lock out fleet work.
