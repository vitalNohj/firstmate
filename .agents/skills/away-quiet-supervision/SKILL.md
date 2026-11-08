---
name: away-quiet-supervision
description: Load whenever /afk or /quiet is invoked, an away or quiet record exists, or a marked away-supervisor message arrives.
user-invocable: false
metadata:
  internal: true
---

# Away and quiet supervision safety

The `/afk` and `/quiet` skills own their respective entry procedures and share the same supervision owner; [architecture](../../../docs/architecture.md) owns the captain-held recheck difference between their postures.
These safety facts apply to both:

- Every current daemon injection uses the `away-supervisor` kind from `bin/fm-operational-input.sh` after `FM_OPERATIONAL_PREFIX` (U+2063 INVISIBLE SEPARATOR followed by `FIRSTMATE_OP: `), except that a Claude Code primary, which strips U+2063, receives that owner's record-backed doorbell and it counts as marked only when `bin/fm-operational-input.sh open <path>` verifies its record; the `/afk` skill owns legacy bare-marker compatibility.
- `state/.afk-contract` is the away posture, written in the same turn as `/afk` before any other work, because `/afk` is itself the go: no read-back gates entry or waits for a go; entry announces hold-for-return only, and the away session acts on those words by its own judgment through the guarded scripts under standing authority, holding for the return on doubt.
  A record carrying quiet mode (`bin/fm-afk-contract.sh mode`) is quiet mode's instead: the captain is present, it holds nothing for a return, and requested actions proceed under ordinary attended authority.
- While `state/.afk` exists, its existing supervision owner continues; do not arm a separate watcher.
  On Pi Pocket, both modes use the existing visible supervision session and its drop-in-owned watcher; never run `bin/fm-afk-launch.sh` or launch a terminal daemon.
  Away wakes carry the away flag and the full mandate, main stays parked, and captain outcomes remain stored for the return brief.
  Quiet wakes carry no away authority, ordinary human chat continues, and captain outcomes reach main as usual.
  On Pi the daemon is also never launched; the ordinary supervision session continues under the away record with main parked: the branch takes every safe actionable wake it can, and only a declined wake (including a broken branch or unsafe scan) or a watcher failure wakes main.
  Away mode on a non-Pi home that runs the supervision host (by default on Claude; `docs/configuration.md` "Supervision host") works the same way with the supervision host as the branch; a wake it hands back arrives through that harness's own wake path and is never the captain's return.
- A marked message while away or quiet mode is active is internal escalation and does not exit that mode.
  Pi Pocket's `[via linked session`, `FIRSTMATE_OP`, `[scheduled]`, and `[background]` inputs are automatic as well (after an optional `[from: Name]` prefix), never a human return.
  Do not relay linked-session completion reports as captain outcomes while main is parked; the durable outcome store owns those outcomes.
  The Pi Pocket drop-in runs the return owner only for real human input in main (or a real human `/quiet off`), supplies the return brief, and preserves either posture across server restarts.
- A message beginning `/afk` refreshes away mode; a message beginning `/quiet` refreshes quiet mode.
- Any other unmarked message means the captain returned in away mode (load `/afk`, run the return owner, and do not process that message as ordinary work until its durable catch-up gate clears), or, in quiet mode, is simply answered as ordinary work with the flag and daemon left untouched until an explicit `/quiet off`.
- Away and quiet mode never expand approval authority for merges, ask-user findings, destructive actions, irreversible actions, or security-sensitive choices.
- Bias ambiguous input toward exit because a present captain takes precedence.
