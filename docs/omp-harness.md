# OMP harness verification

Date: 2026-07-19.
Installed version: OMP 17.0.5 from Homebrew.
Scope: Firstmate crewmate and scout launches on the tmux backend.
Primary and secondmate operation were not verified and remain unsupported.

## Version and launch

The installed version command returned:

```text
$ omp --version
omp/17.0.5
```

A disposable interactive session launched successfully with this shape:

```sh
omp \
  --cwd "$WORKTREE" \
  --session-dir "$SESSION_DIR" \
  --auto-approve \
  --model openai-codex/gpt-5.6-sol \
  --thinking minimal \
  -e "$TURN_END_EXTENSION" \
  "Reply exactly READY, then remain idle. Do not use tools."
```

The positional prompt submitted automatically without an additional Enter.
No trust, onboarding, approval, or shell-confirmation dialog blocked the launch.
Configured MCP integrations attempted to connect at startup, but unavailable integrations only emitted diagnostics and did not block prompt processing.
The machine was already authenticated, so first-ever provider authentication was not exercised.

`--auto-approve` was verified by having the session create, read, remove, and verify removal of a disposable file without an approval prompt.
The tool output contained `OMP_OK`, and the session returned `AUTONOMY_DONE`.

The session launched without `--model` displayed this model card:

```text
GPT-5.6-Sol
openai-codex
```

No key, token, cookie, account identifier, or credential value was printed.

Installed help and live launches verified `--model <value>` and `--thinking <value>`.
OMP accepts `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`, and `auto` thinking levels.
Firstmate maps its shared `low|medium|high|xhigh|max` effort axis directly and leaves the OMP-only values outside the shared schema.

## Detection

Inside an OMP tool process, the environment marker checks returned:

```text
$ printenv OMPCODE
1
$ printenv CLAUDECODE
1
$ printenv PI_CODING_AGENT

```

`OMPCODE=1` is the OMP-specific marker.
It must be checked before `CLAUDECODE=1` because OMP deliberately exports both.
The process ancestry fallback matches the exact native command basename `omp`.
Interpreter argv containing the token `omp` does not qualify as OMP ancestry.

## Busy, idle, and submission

The generic busy line rendered as:

```text
⠋ Working… ⟦esc⟧
```

A model-selected intent replaced the working text while preserving the suffix:

```text
⠧ Probing live autonomy ⟦esc⟧
```

OMP's shipped themes use `⟦esc⟧`, `⟨esc⟩`, or `[esc]`.
The stable busy ERE is:

```text
(\[|⟦|⟨)esc(\]|⟧|⟩)[[:space:]]*$
```

The idle composer cursor row rendered as:

```text
╰─                            ─╯
```

Firstmate strips only the leading and trailing OMP border glyphs.
An empty row classifies as empty, while text between those borders remains pending.
The shared tmux submit primitive types the message once and retries only Enter while the composer remains pending.
A regression fixture simulates OMP swallowing the first Enter and verifies that the second Enter submits without retyping.

## Interrupt, exit, and resume

A supervisor sent one Escape during an active turn.
The turn stopped immediately and OMP returned to the idle composer without exiting the session.

`/exit` cleanly exited with status 0 and printed:

```text
Resume this session with omp --resume 019f7b0a-c47b-7000-b385-5564cb00b3f1
```

Resuming that exact identifier with the original `--cwd` and non-default `--session-dir` succeeded.
Firstmate stores OMP sessions under `/tmp/fm-<id>/omp-sessions`, so recovery must reuse that task session directory until teardown.

## Turn-end lifecycle

OMP loaded this Pi-compatible extension through `-e <absolute-path>`:

```ts
import { execFile } from "node:child_process";

export default function (pi: any) {
  pi.on("turn_end", () => execFile("touch", [TURN_ENDED_MARKER]));
}
```

The disposable session appended multiple `turn_end` observations after completed turns.
`turn_end` is the required event because it fires at each completed turn, while `agent_end` is session-scoped.
Firstmate reuses its existing state-resident Pi marker extension and teardown cleanup path.

## Support boundary

OMP is selectable for crewmate and scout dispatch on the tmux backend only.
Firstmate rejects OMP with herdr, zellij, Orca, or cmux before creating a task workspace because those backend combinations have not been verified.
OMP is not selectable for secondmate launch because Firstmate's primary watcher and turn-end guard extensions have not been smoke-tested inside an OMP secondmate.
OMP is not documented as a supported primary harness for the same reason.
A follow-up may enable those roles only after an end-to-end watcher, actionable wake, guarded turn end, exit, and exact-ID resume smoke.
