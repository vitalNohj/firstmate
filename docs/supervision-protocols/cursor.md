Mode: Cursor foreground checkpoint.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Source `__FM_X_MODE_ENV__` first when X mode is active.
3. Run one foreground watcher checkpoint with `bin/fm-watch-checkpoint.sh --seconds "${FM_CURSOR_WATCH_CHECKPOINT:-180}"`.
4. If the command prints `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes, handle that wake, then start the next checkpoint.
5. If the command prints `checkpoint:` or exits 124 with no wake, drain queued wakes anyway, process any queued user message now visible to Cursor, then start the next checkpoint.
6. Never use shell `&` for firstmate watcher supervision.
7. Do not treat Cursor background Shell tasks as a verified watcher wake adapter yet.
   Prefer the bounded foreground checkpoint until a tracked background-arm path is empirically verified for Cursor Agent.

Cursor Agent is a verified primary and crewmate harness (`cursor-agent --force`, resolved by `fm_cursor_launch_bin` so a colliding bare `agent` is never launched).
After spawning a Cursor crewmate, peek within about 20 seconds for the Workspace Trust dialog and accept with `a` then Enter if shown.
