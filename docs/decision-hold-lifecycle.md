# Decision hold lifecycle mechanism

The normative policy is owned by `.agents/skills/decision-hold-lifecycle/SKILL.md` and is not restated here.
This document records the deterministic mechanism, structured surfaces, and privacy-safe regression evidence.

## Mechanism

`bin/fm-decision-hold.sh` is the only lifecycle command for an investigation or visual review's unresolved captain decisions.
The command runs tasks-axi in the active `FM_HOME`, so the existing backlog remains the only durable work database and a secondmate-owned decision stays in the secondmate home.
It never reads report bodies, review artifacts, terminal output, or chat.

The `hold` subcommand maps an originating work id and stable decision key to `<origin-id>-decision-<decision-key>`.
It creates a kind `captain` backlog item when absent and invokes `tasks-axi hold <id> --reason <reason> --kind captain` on every retry.
It rejects an identity collision, a changed title, and attempts to reopen an already resolved identity.
It is archive-aware for the same reason `verify` is: it refuses an identity that already exists in the configured archive, so a decision key that was closed and pruned is permanently retired and a later decision on the same origin needs a new key.

The `complete` subcommand unions the reviewed keys into `decision_keys=` and appends `decisions_reviewed=1` while originating task metadata is live.
A post-teardown visual review can complete against the surviving report and durable holds without recreating volatile task metadata.
It accepts `--none` as an explicit semantic inventory result, not as inferred absence.
It verifies every listed identity against tasks-axi before recording completion.
For an open keyed status decision, it appends a `captain-held [key=<key>]: ...` transfer event only after the matching backlog hold is durable.
`bin/fm-classify-lib.sh` recognizes that transfer as closing the live status copy without claiming that the captain has answered it.

Scout teardown calls the script's read-only `verify` subcommand after checking for the report and before removing any source state.
The live backlog stays authoritative for mutable and open work, so an active decision must remain a structured active captain item.
`verify` also accepts a resolved captain hold from the configured tasks-axi archive after ordinary Done retention pruning, but only when that archived record is unique and retains the complete structured fm-decision-hold resolution record.
A malformed or missing archived record, or an ambiguous identity across the live backlog and the archive, fails verification.
The accepted archived record is the one every close path writes, including the `(none)` routed-identity token that `decline` and `repair` record, and the structured fields are read only from the header block so arbitrary captain decision prose can never satisfy or break them.
The archived acceptance asserts the same invariant the live path asserts - a closed kind `captain` record carrying that resolution block - rather than tasks-axi's rendering of a close, so `done --pr`, `done --report`, and an `unhold` before or after the close all keep verifying once the record is pruned.
The configured archive path is read from `[markdown] archive`, accepting the same spellings tasks-axi itself accepts, including an inner-spaced section header, a trailing inline comment, and a repeated key whose last assignment wins.
When that optional key is absent, or `.tasks.toml` itself is absent, the path falls back to tasks-axi's own derived default of `done-archive.md` beside the resolved `[markdown] path` backlog rather than a fixed `data/` location, so a home with a customized backlog path never blocks teardown.
The `--force` path remains the explicit captain-approved discard escape hatch.

The `resolve` and `decline` subcommands close active holds, while `repair` attests a hold already closed outside the script.
All three require a non-empty captain decision file and record the same resolution block in the hold body with the decision digest, routed identities, and a `Resolution mode:` naming the path.
An exact retry is idempotent, while a changed decision or, for `resolve`, a changed routed-task set is rejected.

The `resolve` subcommand is the routed path and additionally requires at least one existing dependent task whose structured `blocked-by` edge points to the hold.
It clears each dependency edge through tasks-axi and marks the hold Done only after those writes succeed.
An exact retry can finish a partial routing operation, and a failed intermediate step leaves the hold open.

The `decline` subcommand closes a hold whose captain answer routes no follow-up work, recording `(none)` as the routed identities.
It refuses while any task in the same backlog is still blocked by the hold, because releasing routed work without recording it is `resolve`'s job.
Every candidate found in the listing prefilter is confirmed against its own structured record before the refusal is reported.

The `repair` subcommand records the resolution block on a hold that was already closed outside the script, such as by a direct `tasks-axi done`, so an origin whose decision was genuinely answered stops failing `verify`.
It refuses a hold that is still actively held, never reopens a closed hold, and never clears a dependency edge, so an unanswered decision keeps blocking teardown until the captain's word closes it.
It also requires the identity to carry the captain-hold provenance that tasks-axi preserves through a close, so an ordinary captain-kind task that was never held cannot be repaired into a resolved decision.

## Structured read surfaces

`bin/fm-fleet-snapshot.sh` parses canonical tasks-axi `(hold: ...)` and `(hold-kind: captain)` metadata alongside existing backlog fields.
It resolves every repeated `blocked-by:` edge against structured Done records, keeps missing blockers unresolved, and classifies only an unblocked captain hold as actionable.
Its secondmate-home summary classifies an actionable captain hold as `captain_decision` and preserves blocked captain holds as queued work in the owning home.

`bin/fm-bearings-snapshot.sh` projects actionable captain holds into `decisions_open` and leaves blocked captain holds in ordinary queued gates.
It excludes completed kind `captain` records from Recently Landed.
The projection remains read-only and does not inspect historical prose.

## Verification record

Verification date: 2026-07-14.
Additional quoted `blocked_by` regression verification date: 2026-07-17.
Plural blocker-readiness and mixed-home projection verification date: 2026-07-22.
Unrouted close-path verification date: 2026-08-13.

The focused end-to-end regression uses only synthetic `sample` identities and decision text.
It begins with a completed investigation and visual review whose genuine unresolved choice exists only in the report.
The initial Bearings snapshot correctly has no open decision, and the new teardown gate refuses to erase the source.
A later regression covers tasks-axi's quoted multi-entry `blocked_by` output so `resolve` matches the first, middle, and last ids and rejects a genuinely absent id.
The archive-aware `verify` acceptance and its malformed, missing, and ambiguous failure cases are covered by executable public-script regressions, together with archived declined, repaired, and prose-heavy holds, archived `--pr`, `--report`, and unheld closes, an archived record that is not a captain hold, an absent optional `archive` key, and the backend-honored `archive` config spellings.

Three further regressions cover the close paths that route no work.
A declined decision closes with a recorded answer, satisfies `verify`, leaves Bearings' Captain's Call, and is refused while the hold still blocks routed work.
A hold closed by a direct `tasks-axi done` reproduces the shape that fails `verify` and blocks teardown, and `repair` with a captain decision file clears both.
An unanswered decision still blocks completion and teardown, and neither `decline` nor `repair` can close a hold that is still actively held or supply an answer with a missing or empty decision file.
`repair` also refuses a closed captain-kind task that was never held for the captain.

The live executable suites are the authoritative evidence.
Run `bash tests/fm-decision-hold-lifecycle.test.sh` and the sibling `tests/fm-fleet-snapshot-view.test.sh`, `tests/fm-bearings-snapshot.test.sh`, `tests/fm-brief.test.sh`, and `tests/fm-teardown.test.sh` scripts, followed by `bin/fm-lint.sh`, for the current pass state.
