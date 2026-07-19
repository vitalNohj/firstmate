# Cursor IDE session lock

This note covers the Cursor IDE-embedded agent shape for session lock and harness detect.
CLI `MainThread` / bare-agent argv detection is deferred to upstream [kunchenguid/firstmate#705](https://github.com/kunchenguid/firstmate/pull/705); this work is complementary.

## IDE shape (this PR)

Observed macOS ancestry (2026-07):

```text
zsh
  -> Cursor Helper (Plugin): extension-host (agent-exec) <workspace> [<id>]
  -> /Applications/Cursor.app/Contents/MacOS/Cursor
```

Both `ps -o comm=` and `ps -o args=` return the full agent-exec label.
`fm-lock.sh` and `fm-harness.sh` match the literal `extension-host (agent-exec)` marker only.
Sibling hosts `(user)`, `(retrieval)`, `(always-local)` and bare `Cursor.app` must not match.

## Grok collision guard

Bare `agent` may be Grok Build.
Detect/lock must not classify basename or path `agent` alone as cursor; require a `cursor-agent` argv marker (already true on this fork) or the IDE agent-exec label.
Launch already follows the same rule via `fm_cursor_launch_bin`.

Hermetic coverage: `tests/fm-cursor-harness.test.sh` (IDE agent-exec acquire/holder, plain-IDE rejects, bare-agent-without-evidence rejects).
