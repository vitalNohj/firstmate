# Captain-hold lifecycle mechanism

The normative policy is owned by `.agents/skills/captain-hold-lifecycle/SKILL.md` and is not restated here.
This document records the deterministic mechanism, structured surfaces, compatibility contract, and privacy-safe regression evidence.

## Mechanism

A decision is not a separate thing in this system: it is an ordinary backlog task held for the captain, and the task id is the identity every surface and channel uses.
`bin/fm-captain-hold.sh` is the only lifecycle command layered on that primitive.
The command runs tasks-axi in the active `FM_HOME`, so the existing backlog remains the only durable work database and a secondmate-owned captain call stays in the secondmate home.
It never reads report bodies, review artifacts, terminal output, or chat.

The `hold` subcommand places an existing task under an active captain hold, or creates the task when nothing exists to hold, then verifies the hold through `tasks-axi hold <id> --reason <reason> --kind captain`.
Repeats are idempotent, a closed task is refused rather than reopened, and `--until` stores the captain's own deferral date through tasks-axi's date gate.

The `answer` subcommand records the captain's exact words and closes the call in the same act.
It requires a non-empty captain decision file of at most 8192 bytes, writes a resolution block carrying the decision digest and a `Resolution mode:` at the top of the task body (the previous body is preserved below the block and archived through tasks-axi `--archive-body`), then runs `tasks-axi done` - or `tasks-axi unhold` under `--release`, so a captain-gated work item resumes instead of closing.
An exact retry is idempotent only when the requested close mode matches the newest record; a drifted answer or mode mismatch is rejected, while a re-held task accepts a new answer as a new record on top.
On a task closed outside the script, `answer` records the missing block only when the captain-hold annotations tasks-axi preserves through a close prove the captain owned it, and it verifies the task stays closed.
A hold whose `--until` date has passed keeps those annotations while tasks-axi reports it no longer held, so an expired deferral remains answerable.

The `complete` subcommand unions the reviewed captain-held task ids into `decision_keys=` and appends `decisions_reviewed=1` while originating task metadata is live.
A post-teardown visual review can complete against the surviving report and durable tasks without recreating volatile task metadata.
It accepts `--none` as an explicit semantic inventory result, refused while the origin still has a lifecycle-open keyed status decision, and verifies every listed task against tasks-axi before recording completion.
With a non-empty inventory it appends a `captain-held [key=<key>]: tracked by <inventory>` transfer event for every still-open keyed status decision, which `bin/fm-classify-lib.sh` recognizes as closing the live status copy without claiming that the captain has answered it.

Scout teardown calls the read-only `verify` subcommand after checking for the report and before removing any source state.
`verify` requires the recorded attestation, requires every recorded inventory entry to still be durable (actively captain-held, or carrying a recorded answer), and fails on any keyed status decision that opened after the last `complete`, which makes re-running `complete` the repair.
The `--force` path remains the explicit captain-approved discard escape hatch.

The live backlog stays authoritative, so the configured tasks-axi archive is consulted only for an entry that has actually left it through ordinary Done retention pruning.
There `verify` accepts an entry when some archived record for that identity retains the complete structured resolution record, so pruning a genuinely answered call never blocks teardown.
The archive is append-only history, not a uniqueness index: because a non-conforming archived identity is deliberately re-holdable, one identity legitimately accumulates several archived cycles, and any durably resolved cycle independently attests that the captain answered, so duplicates must never fail.
A live record that satisfies the durable invariant wins over any archived copy of an earlier cycle, and a live record that satisfies nothing still fails on its own merits.
An identity with no archived record at all, or whose every archived record is malformed, still fails verification.
The archived acceptance asserts the same invariant the live path asserts - a closed record carrying that resolution block - rather than tasks-axi's rendering of a close, so `done --pr`, `done --report`, and an `unhold` after the close all keep verifying once the record is pruned.
Captain-hold provenance is enforced where the record is written, since `answer` refuses a task that never carried the hold, so the archived read never re-checks it.
The structured fields are read only from the header block, so arbitrary captain decision prose can never satisfy or break them.
Records written by the retired `bin/fm-decision-hold.sh` are accepted there on the same terms.
`hold` reads that archive against the same predicate when it would create a new task, so a resolved-and-pruned identity is permanently retired and a new captain call needs its own task, while an identity pruned without a resolution record stays re-holdable because no command can rewrite an archived body.
Both paths are resolved exactly as the tasks-axi backend itself resolves them, so this gate never reads a file the backend did not, and every guard below is asserted against the file tasks-axi actually opened.
The backlog is `TASKS_AXI_FILE` when that variable is set, then `[markdown] path` from the home's `.tasks.toml`, then `[markdown] path` from `~/.tasks-axi/config.toml`, and with no key set the first existing of `backlog.md` and `data/backlog.md` under the home, falling back to `backlog.md`.
The archive is `[markdown] archive` from `.tasks.toml`, then from `~/.tasks-axi/config.toml`, and otherwise tasks-axi's own derived default of `done-archive.md` beside the resolved backlog, so an absent optional key or an absent `.tasks.toml` never blocks teardown; `TASKS_AXI_FILE` names no archive but moves the backlog that default is derived beside.
Relative values resolve against the home, both files accept the same spellings tasks-axi itself accepts, and the home-level file is located the way node's `os.homedir()` locates it - the process `HOME` when it is set, this user's passwd entry when it is unset, and, for an empty `HOME`, the relative `.tasks-axi/config.toml` the backend then reads from the home it runs in.
Only a proven absence may reach the archive at all: a read or configuration failure is never absence, so tasks-axi's `NOT_FOUND` counts as proof that a recorded identity departed only once the resolved backlog file is itself readable, since a backlog file that does not exist reads as an empty backlog and answers `NOT_FOUND` for every id.
A missing or unreachable backlog, and an archive that exists but cannot be opened - including one behind a directory this process cannot search - each fail loudly naming the resolved path, while a genuinely absent archive still counts zero archived records.
`hold` asks the opposite question of the live backlog before creating a task - whether the identity is already carried there - which a backlog file that has not been written yet answers correctly, so the first captain call in a fresh home creates that file rather than refusing; a backlog that exists and cannot be read is still never mistaken for a free identity, and the archive retirement guard above is a separate read that still applies.

## Answer-time closure

"A keyed answer closes its matching captain-held task" is one capability with one owner.
`answers` is its channel-agnostic entry point: it reads `<task-id>\t<answer>\t<label>[\t<mode>]` lines and closes each named task through the same `answer` path, so every guard applies identically no matter which channel the answer arrived on.
The optional mode column carries a card-declared close: `done` (default) completes the task and `release` lifts the hold so held work resumes; any other value is skipped.
A key that names no task, names a task that is not captain-held, or names a task already closed is reported as `skipped:` and feeds nothing; a replay whose answer and requested close mode match the newest record is an idempotent `closed:`, while a mode mismatch is skipped; and the command exits nonzero when any key was skipped.
`--source` is provenance text recorded in the durable decision, never a behavior switch, and the command carries no per-channel branch.

`bind`, `unbind`, and `binding` record that a captured-answer source feeds this intake, as a private record under `state/decision-bindings/`; an unbound source feeds nothing, so the path is opt-in per source, and `bind` deliberately does not require the source to exist yet.

Two channels feed that one intake today, and both are ordinary callers rather than special cases.
`bin/fm-send.sh --resolve-key` is the chat channel: its status-log close is unchanged for a key the status log still owns, and a key the status log no longer owns is resolved to a still-open captain-held task - the key as a task id, then the legacy derived identity - and fed as one keyed line.
`bin/fm-procevent.sh` is the captured-result channel: after capture, a bound source has its result passed to `bin/fm-procevent-<adapter>.sh answers <result-file>` and whatever that prints is piped into the intake, so any adapter with an `answers` command works and the runner names no adapter, parses no result, and carries no decision rule.
`bin/fm-procevent-lavish.sh answers` is one such adapter command; it reads only rows tagged `choice`, relays a card's declared close mode, and can never let freeform captain prose forge a task id or a mode.

## Structured read surfaces

`bin/fm-fleet-snapshot.sh` parses canonical tasks-axi `(hold: ...)`, `(hold-kind: ...)`, and `(hold-until: ...)` metadata alongside existing backlog fields.
It resolves every repeated `blocked-by:` edge against structured Done records, keeps missing blockers unresolved, and classifies a captain hold as `captain_actionable` - waiting on the captain now - only when it is queued, unblocked, and due, whatever kind its row carries.
It also emits a presentation-only `deferred_marker` when a hold's reason or body carries an explicit SUPERSEDED / NOT REQUIRED / DEFERRED marker.
Its secondmate-home summary classifies an actionable captain hold as `captain_decision` and preserves blocked or deferred captain holds as queued work in the owning home.

`bin/fm-bearings-snapshot.sh` projects actionable captain holds into `decisions_open` and leaves blocked captain holds in ordinary queued gates.
A date-deferred captain hold renders as a gate with its `until <date>:` reason; a prose-deferred one leaves the default views with an `omitted[]` disclosure, revealed by `--all-decisions` / `--all-queued`.
Recently Landed excludes a record that closed while still held for the captain (surviving `hold-kind: captain` on a Done row), so answered questions do not masquerade as shipped work; a work item released before completion keeps no hold annotations and lands normally.
The projection remains read-only and does not inspect historical prose beyond the canonical snapshot's marker.

## Record divergence

A captain call can have two records, and closing one does not close the other.
A `resolved [key=...]` line closes the status-log fold; the structured captain-held task closes only through `answer`.
Until this guard existed, closing on the status side alone left no trace of the disagreement: the fold went quiet, the durable record kept saying the captain owed an answer, and nothing warned.

`bin/fm-captain-hold.sh diverged` is the read-only report of that state, and `bin/fm-wake-drain.sh` prints it as a bounded `RECORD DIVERGENCE` section beside OPEN DECISIONS on every drain.
It flags exactly one condition: a task still open and still carrying the captain-hold annotations, whose key was closed on the status side by the resolve verb, resolved through the collapsed identity (the key is the task id) or the legacy derived one.
It closes nothing, ever - a captain call closed wrongly leaves review entirely, so both reconciliation directions stay human-owned and the printed hint names both.

Three states are deliberately not divergence.
A `captain-held [key=...]` close is the verified transfer `complete` writes, so the structured row staying open behind it is correct; `bin/fm-classify-lib.sh`'s `status_key_closing_verb` is what keeps the two closing verbs distinguishable.
A still-open keyed status decision belongs to the OPEN DECISIONS fold.
And the absence of a routed work item is legitimate rather than incomplete - when the decision is the deliverable there is nothing to route - so routed work is no part of the test.

Cost stays flat: one `tasks-axi list`, one key scan per status log, and the precise per-key fold only for a key that already names a still-open task.
The comparison is refused unless the status directory is the active home's own, since tasks-axi reads that home's backlog and a mismatch would report one home's logs against another's tasks.
If tasks-axi is unavailable or its listing cannot be parsed, the guard cannot read the structured record and prints nothing.

## Compatibility with pre-collapse installs

Older installs created derived `<origin>-decision-<key>` identities through the retired `bin/fm-decision-hold.sh`.
Those rows are already plain task ids, so they render, answer, verify, and close through the collapsed surfaces with no data migration.
Three legacy inputs are resolved in place: a `decision_keys=` metadata entry that names no task resolves through `<origin>-decision-<entry>`; a channel key that names no task resolves the same way when the source's binding carries a concrete legacy origin; and resolution records written by the old script are recognized wherever a record is read.
The shim recognizes an exact replay of a pre-collapse routed resolution by its historical answer digest and routed ids, then finishes any still-recorded dependency-edge cleanup without rewriting the old decision text.
`bin/fm-decision-hold.sh` itself remains for one release as a thin command-mapping shim over `bin/fm-captain-hold.sh`, so in-flight work briefed before the collapse keeps working; its header owns the exact mapping.

## Verification record

Verification date: 2026-08-21.

The focused end-to-end regression suite is `tests/fm-captain-hold-lifecycle.test.sh`, using only synthetic `sample` identities and decision text.
It proves: the reconstructed silent-divergence case is signalled - a status resolution over a still-open captain-held task reaches both `diverged` and the drain's `RECORD DIVERGENCE` section, under the collapsed and the legacy identity alike, while the backlog task, its hold, and the status log all survive the report unchanged and the printed hint names both reconciliation directions; the false-signal boundary holds - a captain call with no routed work item, a verified `captain-held` transfer, a still-open status decision, an already answered call, and an ordinary task whose keyed question was answered all stay silent; a report-only unresolved captain call refuses `--none` completion before teardown can erase the source; non-forced scout teardown always requires the durable inventory verification; the recorded-answer guard (a bare `tasks-axi done` close fails `verify` until `answer` records the captain's word, and an ordinary finished task cannot be dressed up as an answered call); answer-time closure through a bound channel with task-id keys, including the `release` close mode, mode-matched replay idempotence, and the refusal of drifted, mode-mismatched, absent, unheld, and already-closed keys; the chat channel reaching the same intake; deferral through `--until` leaving `captain_actionable` false until due; and every legacy path (composed identities through the shim, pre-collapse `decision_keys=` metadata, routed-resolution replay, and a concrete-origin binding).

The same suite pins the archive-aware `verify` acceptance and its malformed and missing failure cases, a repeated archived identity whose durably resolved cycle is accepted beside a non-conforming one, a re-used identity whose satisfied live record outranks its archived earlier cycle, archived `--pr`, `--report`, and unheld closes, a prose-heavy decision whose text mimics every structured marker, an absent optional `archive` key, an absent `.tasks.toml`, the backend-honored `archive` config spellings, and both sides of `hold`'s retirement boundary.

`tests/fm-classify-decision-key.test.sh` pins `status_key_closing_verb` itself: it separates a resolution from the durable-transfer close and from a still-open key, reports the last real transition across re-openings and both key positions, and treats a prose mention as no transition.

Projection regressions live in `tests/fm-fleet-snapshot-view.test.sh` (hold-until parsing, the due gate, kind-independent captain actionability, deferred_marker, title stripping) and `tests/fm-bearings-snapshot.test.sh` (Captain's Call membership, the dated-gate rendering, prose-deferral suppression with disclosure, and the landed exclusion by surviving captain-hold annotations).
The exact commands and their summarized outputs are recorded in the shipping PR's evidence; run the four suites above plus `tests/fm-send-resolve-key.test.sh`, `tests/fm-bearings-board.test.sh`, and `bin/fm-lint.sh` to refresh this record.
