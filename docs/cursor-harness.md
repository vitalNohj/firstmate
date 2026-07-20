# Cursor CLI vs IDE session shapes

Cursor CLI and Cursor IDE have different intended roles.
Do not treat IDE recognition as a claim that the IDE agent is a supported full primary.

## Roles (design intent)

| Shape | Intended role |
| --- | --- |
| **Cursor CLI** (`cursor-agent` / verified bare `agent`) | Full primary and crewmate harness (as today): holds the fleet lock, runs the supervision protocol, spawns and steers crewmates. |
| **Cursor IDE** embedded agent (`extension-host (agent-exec)`) | Not a full primary. Intended end-state is **alongside** mode: the IDE agent runs side-by-side with a terminal firstmate in the same `FM_HOME`, never contends for the fleet lock, may spawn crewmates (future: tag `owner=ide` in meta) and steer its own, while the terminal firstmate sees them in the digest and acts only as a safety net. |

IDE-shape detection in `fm-lock.sh` / `fm-harness.sh` is groundwork for that policy: firstmate must recognize an IDE session before it can treat it differently.
Alongside-mode policy (skip lock contention, owner tagging, digest safety-net behavior) is future work - not implemented here.

CLI `MainThread` / broader bare-agent argv detection is deferred to upstream [kunchenguid/firstmate#705](https://github.com/kunchenguid/firstmate/pull/705); this fork's IDE recognition is complementary.

## IDE process shape (detection only)

Observed macOS ancestry (2026-07):

```text
zsh
  -> Cursor Helper (Plugin): extension-host (agent-exec) <workspace> [<id>]
  -> /Applications/Cursor.app/Contents/MacOS/Cursor
```

Both `ps -o comm=` and `ps -o args=` return the full agent-exec label.
Matchers use the literal `extension-host (agent-exec)` marker only.
Sibling hosts `(user)`, `(retrieval)`, `(always-local)` and bare `Cursor.app` must not match.

## Grok collision guard

Bare `agent` may be Grok Build.
Detect/lock must not classify basename or path `agent` alone as cursor; require a `cursor-agent` argv marker (already true on this fork) or the IDE agent-exec label.
Launch already follows the same rule via `fm_cursor_launch_bin`.

Hermetic coverage: `tests/fm-cursor-harness.test.sh` (IDE agent-exec acquire/holder, plain-IDE rejects, bare-agent-without-evidence rejects).
