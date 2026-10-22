Mode: Pi Pocket drop-in background wake.

When this conversation owns supervision:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. The Firstmate Pi Pocket drop-in owns the watcher: it runs `bin/fm-watch-arm.sh --restart` as a durable background task of this conversation and owns every later successor launch, including the re-arm after a Pi Pocket server restart.
3. The drop-in delivers each actionable wake to this conversation as one follow-up input keyed on that wake, so a server restart redelivers it exactly once; the wake itself stays in the durable queue until the acknowledgement in step 1.
4. Ordinary work, turn completion, and ordinary signal, stale, check, heartbeat, or other wake handling: do not arm anything, because continuity is owned by the drop-in rather than by model memory.
5. Never run `bin/fm-watch-arm.sh` or `bin/fm-watch.sh` through the bash tool, never use shell `&`, and never hold a foreground wait on the watcher.
   A foreground arm or wait holds this conversation's turn open, and a backgrounded child dies with the tool call that started it.
6. Missing, failed, or unhealthy cycle only: if a notification explicitly reports one of those repair conditions, drain queued wakes, inspect the failure text, and call the drop-in's repair tool `fm_watch_arm_pocket`.
   If that tool is not available in this conversation, the drop-in is not enabled here: tell the captain that supervision needs the Firstmate Pi Pocket drop-in, and do not substitute another wait shape.
7. If the drop-in says no live session holds the lock, run `bin/fm-session-start.sh` to reclaim the session lock, then call `fm_watch_arm_pocket` again.
   When another Pi Pocket conversation holds this home's lock, that conversation owns supervision and this one stays read-only.
8. Delegate fleet work only through `bin/fm-spawn.sh`, never through Pi Pocket's own `subagent` or `session_*` tools, because work started there has no fleet record and no supervision.

The turn-end guard is passive here: when `bin/fm-turnend-guard.sh` returns 2, the drop-in continues the turn once with the guard text, and it bounds that to one forced continuation per turn.

No supervision branch runs under Pi Pocket: every actionable wake is delivered to this conversation, and the lease, outcome-store, and `fm_branch_processed` contracts of `docs/pi-supervision-branch.md` do not apply here.
Away and quiet modes are not available under Pi Pocket, because the away daemon delivers by typing into a terminal pane and a Pi Pocket conversation has none.
If the captain asks for `/afk` or `/quiet`, say that supervision cannot be handed off from Pi Pocket yet and keep supervising attended; do not run `bin/fm-afk-launch.sh`.
