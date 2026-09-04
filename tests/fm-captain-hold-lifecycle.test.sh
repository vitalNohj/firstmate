#!/usr/bin/env bash
# End-to-end tests for captain-held tasks: the one primitive behind "a decision
# is simply a task waiting on the captain", its completion gate, its recorded
# answers, the record-divergence guard over its two records, and the legacy
# compatibility for pre-collapse decision identities.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-hold)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

# The Lavish review adapter, run against this suite's isolated home. The
# machine-wide process-event claim root is redirected into the fixture so arming
# a review here can never contend with a real one on this machine.
run_lavish() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent-lavish.sh" "$@"
}

run_bearings() {  # <home>
  local home=$1
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-07-14T12:00:00Z \
    "$BEARINGS" --json
}

run_teardown() {  # <home> <id>
  local home=$1 id=$2
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id"
}

tasks_in() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

run_captain() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" "$@"
}

# The retired command surface, kept for one release as a shim; in-flight
# pre-collapse work still drives the lifecycle through these spellings.
run_shim() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-decision-hold.sh" "$@"
}

write_origin_meta() {  # <home> <id> [kind]
  local home=$1 id=$2 kind=${3:-scout}
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-$id" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=$kind" \
    "mode=$kind" \
    "spawn_gen=fixture-$id"
}

# Reproduces the loss exactly with privacy-safe synthetic names: the investigation
# and visual review have ended, the only genuine unresolved captain call is report
# prose, no held backlog item or open status exists, and the authoritative
# Bearings view correctly omits it. Completion must now refuse before teardown can
# erase the source.
test_uninventoried_report_decision_refuses_completion() {
  local home id json rc
  home=$(make_home omitted-decision)
  id=sample-route-review
  mkdir -p "$home/data/$id"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] $id - Investigate sample routing (repo: sample) (kind: scout) (since 2026-07-14)

## Queued

## Done
EOF
  write_origin_meta "$home" "$id"
  printf 'done: report and visual review complete\n' > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample route review

The evidence is complete.
The captain still needs to choose route north or route south before follow-up work starts.
EOF

  json=$(run_bearings "$home") || fail "Bearings failed for unresolved-call regression"
  printf '%s' "$json" | jq -e '
    (.decisions_open | length) == 0
      and (.gates | length) == 0
      and (.reports | any(.id == "sample-route-review"))
  ' >/dev/null || fail "the pre-policy omission shape was not reproduced: $json"

  set +e
  run_teardown "$home" "$id" > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "completed investigation teardown erased a report-only unresolved captain call"
  assert_present "$home/state/$id.meta" "refused completion must preserve investigation metadata"
  assert_grep "REFUSED" "$home/teardown.err" "refusal must be explicit"
  pass "report-only unresolved captain call is reproduced and completion refuses before loss"
}

# The completion gate on the collapsed primitive: an origin with open keyed
# status decisions refuses --none, refuses an inventory naming absent tasks,
# attests a verified inventory of captain-held task ids, and transfers every
# still-open status decision to that durable inventory.
test_completion_gate_attests_and_transfers() {
  local home id json open before after
  home=$(make_home completion-gate)
  id=sample-systems-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample systems" --kind scout --repo sample --start >/dev/null \
    || fail "could not create investigation backlog fixture"
  write_origin_meta "$home" "$id"
  cat > "$home/state/$id.status" <<'EOF'
working: report drafted
needs-decision [key=route]: choose route north or route south
needs-decision [key=access]: choose open or restricted sample access
EOF
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample systems review

Two choices remain unresolved: the route and the sample access level.
A separate recommendation is already resolved and requires no captain action.
EOF

  if run_captain "$home" complete "$id" --none > "$home/none.out" 2> "$home/none.err"; then
    fail "--none attested while captain calls were still open in the status stream"
  fi
  assert_no_grep "decisions_reviewed=1" "$home/state/$id.meta" \
    "failed completion recorded a false completion attestation"
  if run_captain "$home" complete "$id" sample-route-call > "$home/absent.out" 2> "$home/absent.err"; then
    fail "completion accepted an inventory entry that names no task"
  fi

  run_captain "$home" hold sample-route-call \
    --title "Choose route: north, south" --reason "captain route and access choices pending" \
    --repo sample --origin "$id" >/dev/null \
    || fail "could not register the captain-held task"
  run_captain "$home" hold sample-route-call \
    --title "Choose route: north, south" --reason "captain route and access choices pending" \
    --repo sample >/dev/null \
    || fail "idempotent hold retry failed"
  [ "$(grep -cE "^- \[ \] sample-route-call -" "$home/data/backlog.md")" = 1 ] \
    || fail "idempotent retry duplicated the captain-held task"
  if run_captain "$home" hold sample-route-call --title "A different title" \
    --reason "captain route and access choices pending" > "$home/title.out" 2> "$home/title.err"; then
    fail "hold accepted a changed title on an existing task"
  fi

  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"
    fm_wake_status_mark_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/$id.status" \
    || fail "could not prime the announced decision baseline"
  run_captain "$home" complete "$id" sample-route-call >/dev/null \
    || fail "shared investigation completion gate failed"
  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"; fm_wake_signal_seen_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/$id.status" \
    || fail "captain-held bookkeeping closes re-woke their own home"
  assert_grep "decisions_reviewed=1" "$home/state/$id.meta" "completion attestation missing"
  assert_grep "decision_keys=sample-route-call" "$home/state/$id.meta" "inventory was not recorded as task ids"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  [ -z "$open" ] || fail "captain-held transfer did not close the live status decisions: $open"
  grep -F 'captain-held [key=route]: tracked by sample-route-call' "$home/state/$id.status" >/dev/null \
    || fail "the transfer line does not name the tracking inventory"

  before=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  json=$(run_bearings "$home") || fail "Bearings failed with a captain-held task"
  after=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "Bearings mutated the authoritative backlog"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "sample-route-call" and .verb == "captain-hold" and .owner == "(main)"))
      and (.gates | any(.id == "sample-route-call") | not)
  ' >/dev/null || fail "Bearings did not surface the captain-held task: $json"

  run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
    || fail "reviewed investigation teardown failed: $(cat "$home/teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null \
    || fail "could not archive completed investigation"
  json=$(run_bearings "$home") || fail "Bearings failed after source teardown and archival"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "sample-route-call" and .verb == "captain-hold"))
      and (.in_flight | any(.id == "sample-systems-review") | not)
  ' >/dev/null || fail "teardown or archival erased a captain-held task: $json"
  pass "the completion gate attests captain-held inventory and transfers open status decisions"
}

# The recorded-answer rule: answering closes with the captain's exact words, an
# exact retry is idempotent, a drifted retry is rejected, dependent work routed
# behind the answered task is released by the close, and the completion gate is
# satisfied only by a recorded answer.
test_answer_records_and_closes() {
  local home id json show
  home=$(make_home answer-close)
  id=sample-guard-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Guard the answer path" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the answer-guard origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Guard review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold sample-guard-call \
    --title "Choose the guard option" --reason "captain guard choice pending" --repo sample >/dev/null \
    || fail "could not register the captain-held task"
  run_captain "$home" complete "$id" sample-guard-call >/dev/null \
    || fail "completion failed for the held inventory"
  tasks_in "$home" add sample-guard-work "Apply the guard option" \
    --kind ship --repo sample --blocked-by sample-guard-call >/dev/null \
    || fail "could not route work behind the captain-held task"

  printf '' > "$home/empty.txt"
  if run_captain "$home" answer sample-guard-call --decision-file "$home/empty.txt" \
    > "$home/empty-answer.out" 2> "$home/empty-answer.err"; then
    fail "answer accepted an empty captain decision"
  fi
  if run_captain "$home" answer sample-guard-call > "$home/bare-answer.out" 2> "$home/bare-answer.err"; then
    fail "answer accepted a close with no captain decision file at all"
  fi
  printf 'An answer the captain never gave.\n' > "$home/invented.txt"
  if run_captain "$home" answer sample-absent-call --decision-file "$home/invented.txt" \
    > "$home/absent-answer.out" 2> "$home/absent-answer.err"; then
    fail "answer invented a resolution for a task that does not exist"
  fi
  if run_captain "$home" answer sample-guard-work --decision-file "$home/invented.txt" \
    > "$home/unheld-answer.out" 2> "$home/unheld-answer.err"; then
    fail "answer closed a task that is not held for the captain"
  fi
  show=$(tasks_in "$home" show sample-guard-call --full)
  assert_contains "$show" "state: queued" "a refused answer closed the captain-held task"
  assert_contains "$show" "held: yes" "a refused answer released the captain-held task"

  printf 'Captain chose the guard option.\n' > "$home/guard-decision.txt"
  run_captain "$home" answer sample-guard-call --decision-file "$home/guard-decision.txt" >/dev/null \
    || fail "answer could not close the captain-held task"
  show=$(tasks_in "$home" show sample-guard-call --full)
  assert_contains "$show" "state: done" "an answered captain-held task did not close"
  assert_contains "$show" "Resolution recorded by fm-captain-hold" "the answered task lost the decision record"
  assert_contains "$show" "Resolution mode: answered" "the answered task did not record its close path"
  assert_contains "$show" "Captain chose the guard option." \
    "the answered task did not record the captain decision text"
  run_captain "$home" answer sample-guard-call --decision-file "$home/guard-decision.txt" >/dev/null \
    || fail "identical answer retry was not idempotent"
  printf 'Captain chose something else entirely.\n' > "$home/drifted.txt"
  if run_captain "$home" answer sample-guard-call --decision-file "$home/drifted.txt" \
    > "$home/drifted-answer.out" 2> "$home/drifted-answer.err"; then
    fail "answer retry accepted a different captain decision"
  fi
  # The answered call releases the work routed behind it: a Done blocker reads
  # as resolved everywhere.
  show=$(tasks_in "$home" show sample-guard-work --full)
  assert_contains "$show" "blocked: no" "the recorded answer did not release dependent work"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "an answered captain call did not satisfy the completion gate"
  json=$(run_bearings "$home") || fail "Bearings failed after the answer"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "sample-guard-call") | not)
      and (.gates | any(.id == "sample-guard-call") | not)
      and (.landed | any(.id == "sample-guard-call") | not)
  ' >/dev/null || fail "an answered captain call still renders somewhere it should not: $json"
  pass "answer records the captain's words, closes idempotently, and releases routed work"
}

# --release lifts the hold instead of closing, preserving the work item's own
# body under the record; a re-held task later accepts a new answer.
test_release_frees_held_work() {
  local home show out
  home=$(make_home release-work)
  tasks_in "$home" add sample-widget "Ship the sample widget" --kind ship --repo sample \
    --body 'The widget plan body. Literal escape: \n. Unicode: café.' >/dev/null \
    || fail "could not create the held work item"
  run_captain "$home" hold sample-widget --reason "captain go needed before shipping" >/dev/null \
    || fail "could not hold the work item for the captain"
  printf 'Go: ship it as planned.\n' > "$home/go.txt"
  run_captain "$home" answer sample-widget --decision-file "$home/go.txt" --release >/dev/null \
    || fail "answer --release failed on the held work item"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "state: queued" "a released work item did not stay queued"
  assert_contains "$show" "held: no" "a released work item kept its hold"
  assert_contains "$show" "Resolution mode: released" "the release did not record its close path"
  assert_contains "$show" "Go: ship it as planned." "the release lost the captain's words"
  assert_contains "$show" "The widget plan body." "the release destroyed the work item body"
  assert_contains "$show" 'Literal escape: \\n. Unicode: café.' \
    "the release corrupted escaped or Unicode body text"
  run_captain "$home" answer sample-widget --decision-file "$home/go.txt" --release >/dev/null \
    || fail "identical release retry was not idempotent"
  if run_captain "$home" answer sample-widget --decision-file "$home/go.txt" \
    > "$home/wrong-mode.out" 2> "$home/wrong-mode.err"; then
    fail "a released answer replay without --release reported completion"
  fi
  assert_grep "mode released" "$home/wrong-mode.err" \
    "the mismatched replay did not name the recorded release mode"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "state: queued" "a mismatched release replay closed the work item"
  assert_contains "$show" "held: no" "a mismatched release replay re-held the work item"

  tasks_in "$home" add sample-empty-label-widget "Ship without a display label" \
    --kind ship --repo sample >/dev/null
  run_captain "$home" hold sample-empty-label-widget --reason "captain go needed" >/dev/null
  out=$(printf 'sample-empty-label-widget\tgo\t\trelease\n' \
    | run_captain "$home" answers --source "empty-label release fixture") \
    || fail "an empty answer label shifted the release close mode"
  assert_contains "$out" "closed: sample-empty-label-widget" \
    "the empty-label release was not accepted"
  show=$(tasks_in "$home" show sample-empty-label-widget --full)
  assert_contains "$show" "state: queued" "an empty-label release completed its work item"
  assert_contains "$show" "held: no" "an empty-label release did not lift the hold"
  assert_contains "$show" "Resolution mode: released" \
    "an empty-label release recorded the wrong close mode"

  # A NEW captain gate on the same task later takes a NEW answer.
  run_captain "$home" hold sample-widget --reason "captain pricing call needed" >/dev/null \
    || fail "could not re-hold the released work item"
  printf 'Price it at nine dollars.\n' > "$home/price.txt"
  run_captain "$home" answer sample-widget --decision-file "$home/price.txt" --release >/dev/null \
    || fail "a re-held task refused a new answer"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "Price it at nine dollars." "the new answer was not recorded"
  assert_contains "$show" "Go: ship it as planned." "the new answer erased the earlier record"

  tasks_in "$home" "done" sample-widget >/dev/null \
    || fail "could not complete the released work item normally"
  if run_captain "$home" answer sample-widget --decision-file "$home/price.txt" \
    > "$home/closed-wrong-mode.out" 2> "$home/closed-wrong-mode.err"; then
    fail "a completed release replay without --release reported an answer"
  fi
  assert_grep "mode released" "$home/closed-wrong-mode.err" \
    "the completed replay did not name the recorded release mode"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "state: done" "a refused completed replay changed task state"
  pass "release frees held work with the captain's words recorded and the body preserved"
}

# Deferral is a date, not a live card: hold --until keeps the task out of
# captain_actionable until due, tasks-axi's own date-gate expiry keeps the task
# answerable, and Bearings renders the wait as a dated gate.
test_deferral_leaves_captains_call_until_due() {
  local home json snap show
  home=$(make_home deferral)
  run_captain "$home" hold sample-later-call --title "Revisit the sample plan" \
    --reason "captain deferred revisit later" --repo sample --until 2026-08-01 >/dev/null \
    || fail "could not register the deferred captain call"
  run_captain "$home" hold sample-now-call --title "Decide the sample cut" \
    --reason "captain cut choice pending" --repo sample >/dev/null \
    || fail "could not register the live captain call"
  if run_captain "$home" hold sample-bad-date --title "Bad date" \
    --reason "captain choice" --until 2026-8-1 > "$home/bad-date.out" 2> "$home/bad-date.err"; then
    fail "hold accepted a malformed --until date"
  fi

  snap=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SNAPSHOT_NOW=2026-07-14T12:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "fleet snapshot failed"
  printf '%s' "$snap" | jq -e '
    ([.backlog.records[] | select(.id == "sample-later-call")][0]) as $later
    | ([.backlog.records[] | select(.id == "sample-now-call")][0]) as $now
    | $later.captain_actionable == false and $later.hold_until == "2026-08-01"
      and $now.captain_actionable == true and $now.hold_until == null
      and ($later.title | contains("hold-until") | not)
  ' >/dev/null || fail "the due gate or hold-until parsing is wrong: $snap"

  json=$(run_bearings "$home") || fail "Bearings failed with a deferred call"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "sample-now-call"))
      and (.decisions_open | any(.id == "sample-later-call") | not)
      and (.gates | any(.id == "sample-later-call" and (.reason | startswith("until 2026-08-01"))))
  ' >/dev/null || fail "the deferred call did not render as a dated gate: $json"

  # On its date the call is due again - and still answerable even though
  # tasks-axi reports the expired hold as no longer held.
  snap=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SNAPSHOT_NOW=2026-08-01T12:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "fleet snapshot failed at the due date"
  printf '%s' "$snap" | jq -e '
    [.backlog.records[] | select(.id == "sample-later-call")][0].captain_actionable == true
  ' >/dev/null || fail "a due deferral did not resurface as captain-actionable"
  show=$(tasks_in "$home" show sample-later-call --full)
  assert_contains "$show" "hold_kind: captain" "the expired deferral lost its captain-hold annotations"
  printf 'Answered on the due date.\n' > "$home/due.txt"
  run_captain "$home" answer sample-later-call --decision-file "$home/due.txt" >/dev/null \
    || fail "an expired deferral was not answerable"
  pass "a deferred captain call leaves the live Captain's Call until its date and stays answerable"
}

# The recorded-answer guard survives an out-of-band close: a bare tasks-axi done
# fails verify until answer records the captain's word, and an ordinary finished
# task can never be dressed up as an answered captain call.
test_out_of_band_close_is_recordable() {
  local home id show
  home=$(make_home out-of-band)
  id=sample-fullrun-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate the sample full run" --kind scout --repo sample --start >/dev/null \
    || fail "could not create out-of-band origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample full run review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold sample-submission-call --title "Choose the sample submission" \
    --reason "captain submission choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "could not register the captain-held task"
  run_captain "$home" complete "$id" sample-submission-call >/dev/null \
    || fail "completion failed before the out-of-band close"

  tasks_in "$home" "done" sample-submission-call >/dev/null \
    || fail "could not reproduce the direct out-of-band close"
  if run_captain "$home" verify "$id" > "$home/broken-verify.out" 2> "$home/broken-verify.err"; then
    fail "verification passed a captain call closed with no recorded answer"
  fi
  if run_teardown "$home" "$id" > "$home/broken-teardown.out" 2> "$home/broken-teardown.err"; then
    fail "teardown proceeded while a captain call had no recorded answer"
  fi
  assert_present "$home/state/$id.meta" "refused teardown removed investigation metadata"

  printf 'Declined: do not submit the sample full run upstream.\n' > "$home/submission.txt"
  run_captain "$home" answer sample-submission-call --decision-file "$home/submission.txt" >/dev/null \
    || fail "answer could not record the missing captain decision on the closed task"
  show=$(tasks_in "$home" show sample-submission-call --full)
  assert_contains "$show" "state: done" "recording the answer reopened the closed task"
  assert_contains "$show" "Resolution mode: repaired" "the retroactive record did not name its path"
  assert_contains "$show" "Declined: do not submit the sample full run upstream." \
    "the retroactive record lost the captain decision text"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "the recorded answer did not satisfy the completion gate"
  run_captain "$home" answer sample-submission-call --decision-file "$home/submission.txt" >/dev/null \
    || fail "identical retroactive retry was not idempotent"
  printf 'A different answer entirely.\n' > "$home/drifted.txt"
  if run_captain "$home" answer sample-submission-call --decision-file "$home/drifted.txt" \
    > "$home/drifted.out" 2> "$home/drifted.err"; then
    fail "a drifted retry overwrote the recorded captain decision"
  fi
  run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
    || fail "teardown still refused after the answer was recorded: $(cat "$home/teardown.err")"

  # An ordinary finished task was never the captain's item; recording an
  # invented answer on it must be refused.
  tasks_in "$home" add sample-ordinary-work "Ordinary finished work" --kind ship --repo sample >/dev/null
  tasks_in "$home" "done" sample-ordinary-work >/dev/null
  printf 'An answer the captain never gave.\n' > "$home/invented.txt"
  if run_captain "$home" answer sample-ordinary-work --decision-file "$home/invented.txt" \
    > "$home/never-held.out" 2> "$home/never-held.err"; then
    fail "an ordinary finished task was dressed up as an answered captain call"
  fi
  assert_grep "never held for the captain" "$home/never-held.err" \
    "the refusal must say the task carries no captain-hold provenance"
  pass "an out-of-band close is recordable with the captain's word and nothing else"
}

# A post-teardown visual review completes against the surviving report and
# durable tasks, with no volatile task metadata and no second decision database.
test_visual_review_uses_shared_completion_owner() {
  local home id json
  home=$(make_home visual-review)
  id=sample-board-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review the sample board" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: investigation complete\n' > "$home/state/$id.status"
  printf '# Sample board investigation\n\nThe initial findings need no captain choice.\n' > "$home/data/$id/report.md"
  run_captain "$home" complete "$id" --none >/dev/null \
    || fail "initial investigation could not pass the shared completion owner"
  run_teardown "$home" "$id" >/dev/null 2> "$home/visual-teardown.err" \
    || fail "completed investigation teardown failed: $(cat "$home/visual-teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null

  mkdir -p "$home/.lavish"
  printf '<html><body>Synthetic sample board</body></html>\n' > "$home/.lavish/sample-board.html"
  run_captain "$home" hold sample-layout-call --title "Choose the sample layout" \
    --reason "captain layout choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "post-teardown visual review could not use the shared hold owner"
  run_captain "$home" complete "$id" sample-layout-call >/dev/null \
    || fail "post-teardown visual review could not use the shared completion owner"
  json=$(run_bearings "$home") || fail "Bearings failed after the ended visual review"
  printf '%s' "$json" | jq -e '
    .decisions_open | any(.id == "sample-layout-call" and .verb == "captain-hold")
  ' >/dev/null || fail "ended visual review did not leave its durable Captain Call: $json"
  [ ! -e "$home/data/visual-review-decisions.json" ] \
    || fail "visual review created a second decision database"
  pass "ended visual review follows the same captain-hold completion owner"
}

test_none_inventory_and_resolved_prose_do_not_create_holds() {
  local home id json
  home=$(make_home no-false-holds)
  id=sample-resolved-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a resolved sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'resolved [key=old-choice]: the sample choice was already recorded\ndone: report complete\n' \
    > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Resolved sample finding

Decision record: the earlier choice is resolved.
The recommendation is informational and needs no captain action.
EOF
  run_captain "$home" complete "$id" --none >/dev/null \
    || fail "explicit no-call inventory failed"
  json=$(run_bearings "$home") || fail "Bearings failed for no-call inventory"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id | startswith("sample-resolved-review")) | not)
  ' >/dev/null || fail "resolved findings or decision-like prose created a false captain call: $json"
  pass "resolved findings and decision-like prose do not create captain-held tasks"
}

test_terminal_single_owner_status_decision_does_not_block_empty_inventory() {
  local home id open secondmate
  home=$(make_home stale-terminal-decision)
  id=sample-terminal-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a terminal sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'needs-decision [key=default]: choose route A or route B\ndone: report complete\n' \
    > "$home/state/$id.status"
  printf '# Terminal sample review\n\nNo unresolved captain choice remains.\n' > "$home/data/$id/report.md"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  assert_contains "$open" "default" "fixture must retain the raw stale status decision"
  run_captain "$home" complete "$id" --none >/dev/null \
    || fail "terminal single-owner stale status decision blocked empty inventory completion"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "terminal single-owner stale status decision blocked inventory verification"
  run_teardown "$home" "$id" >/dev/null 2> "$home/terminal-teardown.err" \
    || fail "terminal single-owner stale status decision blocked teardown: $(cat "$home/terminal-teardown.err")"

  secondmate=sample-secondmate
  write_origin_meta "$home" "$secondmate" secondmate
  printf 'needs-decision [key=route]: choose route A or route B\ndone: heartbeat complete\n' \
    > "$home/state/$secondmate.status"
  if run_captain "$home" complete "$secondmate" --none \
    > "$home/secondmate-terminal.out" 2> "$home/secondmate-terminal.err"; then
    fail "secondmate terminal status decision was incorrectly cleared"
  fi
  pass "terminal single-owner stale status decisions do not block empty inventory"
}

test_secondmate_hold_stays_in_authoritative_home() {
  local parent mate fakebin origin json
  parent=$(make_home main-routing)
  mate="$TMP_ROOT/sample-mate-home"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  cp "$ROOT/.tasks.toml" "$mate/.tasks.toml"
  printf '# Synthetic secondmate home\n' > "$mate/AGENTS.md"
  printf 'sample-mate\n' > "$mate/.fm-secondmate-home"
  # A seeded home always carries its parent binding; teardown delivers the
  # scout's final line through it before removing the record.
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
    > "$mate/.fm-secondmate-parent"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$mate")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  origin=sample-mate-review
  mkdir -p "$mate/data/$origin"
  tasks_in "$mate" add "$origin" "Investigate secondmate sample" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$mate" "$origin"
  printf 'done: report and visual review complete\n' > "$mate/state/$origin.status"
  printf '# Sample secondmate review\n\nOne captain choice remains.\n' > "$mate/data/$origin/report.md"
  run_captain "$mate" hold sample-release-call --title "Choose the sample release" \
    --reason "captain release choice pending" --repo sample --origin "$origin" >/dev/null \
    || fail "secondmate-owned hold creation failed"
  run_captain "$mate" complete "$origin" sample-release-call >/dev/null \
    || fail "secondmate-owned completion failed"
  # The parent registers the mate before its children are ever torn down;
  # teardown resolves that registration to deliver the scout's final line.
  printf -- '- sample-mate - synthetic scope (home: %s; scope: sample reviews; projects: sample; added 2026-07-14)\n' \
    "$mate" > "$parent/data/secondmates.md"
  fm_write_secondmate_meta "$parent/state/sample-mate.meta" "$mate" \
    "firstmate:fm-sample-mate" sample
  run_teardown "$mate" "$origin" >/dev/null 2> "$mate/teardown.err" \
    || fail "secondmate investigation teardown failed: $(cat "$mate/teardown.err")"
  tasks_in "$mate" "done" "$origin" --report "data/$origin/report.md" --keep 0 >/dev/null
  grep -Eq "^done \\[key=child-outcome-$origin-done-[0-9a-f]{8}\\]: child $origin done: report and visual review complete mode=scout report=data/$origin/report.md$" \
    "$parent/state/sample-mate.status" \
    || fail "the scout's final line did not reach the parent at teardown"

  json=$(run_bearings "$parent") || fail "parent Bearings could not read the secondmate captain call"
  printf '%s' "$json" | jq -e '
    .decisions_open | any(.owner == "sample-mate" and .verb == "captain-hold"
      and (.id | endswith("sample-release-call")))
  ' >/dev/null || fail "secondmate captain call did not surface with authoritative owner: $json"
  assert_no_grep "sample-release-call" "$parent/data/backlog.md" "secondmate call leaked into the main backlog"
  assert_grep "sample-release-call" "$mate/data/backlog.md" "secondmate call left its authoritative backlog"
  pass "main-home and secondmate-home captain calls remain correctly routed"
}

# Inside a secondmate home a hold and its answer reach the parent channel from
# the script itself, keyed per hold occurrence, so a re-held task opens and
# closes a distinct parent decision and a retry never duplicates a line. A main
# home publishes nothing anywhere.
test_secondmate_home_publishes_holds_and_answers() {
  local parent mate fakebin channel decision out
  parent=$(make_home parent-channel)
  mate="$TMP_ROOT/channel-mate-home"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects"
  cp "$ROOT/.tasks.toml" "$mate/.tasks.toml"
  printf '# Synthetic secondmate home\n' > "$mate/AGENTS.md"
  printf 'channel-mate\n' > "$mate/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
    > "$mate/.fm-secondmate-parent"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$mate")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  channel="$parent/state/channel-mate.status"
  decision="$mate/decision.txt"

  tasks_in "$mate" add quoted-record-call "Choose quoted record handling" --kind ship --repo sample \
    --body 'Documentation quote: Resolution recorded by fm-captain-hold.' >/dev/null \
    || fail "could not create quoted-record captain call"
  run_captain "$mate" hold quoted-record-call --reason "quoted record choice pending" \
    --origin quoted-origin >/dev/null || fail "quoted-record hold failed"
  assert_grep 'needs-decision [key=captain-hold-quoted-record-call-1]: captain hold quoted-record-call: quoted record choice pending' \
    "$channel" "body prose was incorrectly counted as a resolution record"

  run_captain "$mate" hold mate-call --title "Choose the mate release" \
    --reason "release choice pending" --repo sample >/dev/null \
    || fail "mate hold failed"
  assert_grep 'needs-decision [key=captain-hold-mate-call-1]: captain hold mate-call: release choice pending' \
    "$channel" "the mate's hold did not reach the parent channel"
  run_captain "$mate" hold mate-call --reason "release choice pending" >/dev/null \
    || fail "repeated mate hold failed"
  [ "$(grep -c 'captain-hold-mate-call-1' "$channel")" = 1 ] \
    || fail "a repeated hold duplicated the parent decision: $(cat "$channel")"

  printf 'ship it later\n' > "$decision"
  run_captain "$mate" answer mate-call --decision-file "$decision" --release >/dev/null \
    || fail "mate release answer failed"
  assert_grep 'resolved [key=captain-hold-mate-call-1]: captain hold mate-call: released' \
    "$channel" "the released answer did not close the parent decision"

  run_captain "$mate" hold mate-call --reason "second release choice" >/dev/null \
    || fail "re-hold after release failed"
  assert_grep 'needs-decision [key=captain-hold-mate-call-2]: captain hold mate-call: second release choice' \
    "$channel" "a re-held task did not open a distinct parent decision"
  printf 'ship it\n' > "$decision"
  run_captain "$mate" answer mate-call --decision-file "$decision" >/dev/null \
    || fail "mate close answer failed"
  assert_grep 'resolved [key=captain-hold-mate-call-2]: captain hold mate-call: answered' \
    "$channel" "the closing answer did not close the second parent decision"
  run_captain "$mate" answer mate-call --decision-file "$decision" >/dev/null \
    || fail "idempotent answer retry failed"
  [ "$(grep -c 'captain-hold-mate-call-2' "$channel")" = 2 ] \
    || fail "an answer retry duplicated a parent line: $(cat "$channel")"
  [ "$(grep -c 'captain-hold-mate-call' "$channel")" = 4 ] \
    || fail "unexpected parent channel contents: $(cat "$channel")"

  run_captain "$mate" hold batch-call --title "Choose the batch release" \
    --reason "batch choice pending" --repo sample >/dev/null \
    || fail "batch hold failed"
  mv "$channel" "$channel.saved"
  mkdir "$channel"
  out=$(printf 'batch-call\tship now\t\n' \
    | run_captain "$mate" answers --source "batch retry fixture" 2>&1) \
    || fail "batch answer did not preserve its durable close: $out"
  printf '%s\n' "$out" | grep -Fq 'actionable:' \
    || fail "failed batch parent delivery was not actionable: $out"
  rmdir "$channel"
  mv "$channel.saved" "$channel"
  printf 'batch-call\tship now\t\n' \
    | run_captain "$mate" answers --source "batch retry fixture" >/dev/null \
    || fail "idempotent batch answer retry failed"
  [ "$(grep -c 'resolved \[key=captain-hold-batch-call-1\]' "$channel")" = 1 ] \
    || fail "batch retry did not restore exactly one parent resolution: $(cat "$channel")"

  run_captain "$parent" hold main-call --title "Choose the main release" \
    --reason "main choice pending" --repo sample >/dev/null || fail "main hold failed"
  [ ! -e "$parent/state/parent-replies.status" ] || fail "a main home wrote a parent reply"
  assert_no_grep 'captain-hold-main-call' "$channel" "a main home's hold leaked onto a mate channel"
  pass "a secondmate home publishes each hold occurrence and its answer on the parent channel"
}

# The one keyed-answer intake, fed through the real process-event runner by a
# fixture channel that knows nothing about captain holds: task-id keys close at
# answer time, a card-declared release mode frees held work, freeform prose can
# forge nothing, and a replayed capture is idempotent.
test_bound_channel_answers_close_at_answer_time() {
  local home id sid artifact result out show rc
  home=$(make_home channel-answer-closure)
  id=sample-eval-proposal
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Propose sample eval changes" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the review origin"
  write_origin_meta "$home" "$id"
  printf 'done: proposal deck ready for the captain\n' > "$home/state/$id.status"
  printf '# Sample eval proposal\n\nThree captain choices remain.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold sample-membership-call --title "Captain call: membership" \
    --reason "captain membership choice pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-headline-call --title "Captain call: headline" \
    --reason "captain headline choice pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-forged-call --title "Captain call: forged" \
    --reason "captain forged choice pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-invalid-close-call --title "Captain call: invalid close" \
    --reason "captain close mode validation pending" --repo sample --origin "$id" >/dev/null
  tasks_in "$home" add sample-gated-work "Gated sample work" --kind ship --repo sample \
    --body 'Gated work plan.' >/dev/null
  run_captain "$home" hold sample-gated-work --reason "captain go needed" >/dev/null
  run_captain "$home" complete "$id" \
    sample-membership-call sample-headline-call sample-forged-call sample-invalid-close-call \
    sample-gated-work >/dev/null \
    || fail "completion failed for the deck's inventoried calls"

  artifact="$home/data/$id/review.html"
  printf '<h1>Sample eval proposal</h1>\n' > "$artifact"
  fm_fake_exit0 "$home/fakebin" lavish-axi
  sid=$(run_lavish "$home" source-id "$artifact") || fail "could not derive the review source id"
  run_captain "$home" bind "$sid" >/dev/null \
    || fail "could not bind the review source to the keyed-answer intake"
  [ "$(run_captain "$home" binding "$sid")" = "(any)" ] \
    || fail "the recorded binding did not resolve to the collapsed marker"
  run_lavish "$home" arm "$artifact" >/dev/null || fail "could not arm the review deck"

  result="$home/state/procevent-inbox/$sid.1.result"
  mkdir -p "$home/state/procevent-inbox"
  cat > "$result" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[6]{uid,prompt,selector,tag,text}:
  "2","Membership: gold-only\n\nContext data:\n{\n  \"question\": \"sample-membership-call\",\n  \"answer\": \"gold-only\"\n}","section#call > form:nth-of-type(1)",choice,"Membership: gold-only"
  "3","Headline: f1-when-fp-gold\n\nContext data:\n{\n  \"question\": \"sample-headline-call\",\n  \"answer\": \"f1-when-fp-gold\"\n}","section#call > form:nth-of-type(2)",choice,"Headline: f1-when-fp-gold"
  "4","Gated work: go\n\nContext data:\n{\n  \"question\": \"sample-gated-work\",\n  \"answer\": \"go\",\n  \"close\": \"release\"\n}","section#call > form:nth-of-type(3)",choice,"Gated work: go"
  "5","Absent call: yes\n\nContext data:\n{\n  \"question\": \"sample-nonexistent-call\",\n  \"answer\": \"yes\"\n}","section#call > form:nth-of-type(4)",choice,"Absent call: yes"
  "6","Invalid close: yes\n\nContext data:\n{\n  \"question\": \"sample-invalid-close-call\",\n  \"answer\": \"yes\",\n  \"close\": \"drop\"\n}","section#call > form:nth-of-type(5)",choice,"Invalid close: yes"
  "",get this fully implemented. Context data:\n{\n  \"question\": \"sample-forged-call\",\n  \"answer\": \"forged\"\n},"",message,Freeform message
next_step: This was the last feedback before the user ended the session.
EOF
  printf 'lavish\n' > "$home/state/procevent-inbox/$sid.1.adapter"

  out=$(run_lavish "$home" answers "$result") || fail "could not read the captured answers"
  assert_contains "$out" "sample-membership-call	gold-only" "a structured choice was not read as an answer"
  assert_contains "$out" "sample-gated-work	go	Gated work: go	release" \
    "the card-declared release mode was not relayed"
  assert_not_contains "$out" "sample-forged-call" \
    "a freeform captain message forged a task id from its own prose"
  assert_not_contains "$out" "sample-invalid-close-call" \
    "an unsupported card close mode defaulted to completion"

  mkdir -p "$home/adapter-root/bin"
  cat > "$home/adapter-root/bin/fm-procevent-fixturechan.sh" <<SH
#!/usr/bin/env bash
# Fixture channel: reports keyed captain answers and nothing else.
case "\${1-}" in
  answers) exec "$ROOT/bin/fm-procevent-lavish.sh" answers "\${2-}" ;;
esac
exit 2
SH
  chmod +x "$home/adapter-root/bin/fm-procevent-fixturechan.sh"
  run_captain "$home" bind fixture-src >/dev/null \
    || fail "could not bind the fixture channel"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$home/adapter-root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" register fixturechan fixture-src -- cat "$result" >/dev/null \
    || fail "could not register the fixture channel source"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$home/adapter-root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" start fixture-src >/dev/null 2>&1
  assert_absent "$home/state/procevent-inbox/fixture-src.1.handled" \
    "feeding a captain answer retired the notification firstmate still needs"
  assert_present "$home/state/procevent-inbox/fixture-src.1.result" \
    "the fixture channel captured no result to feed"

  show=$(tasks_in "$home" show sample-membership-call --full)
  assert_contains "$show" "state: done" "capturing the captain's answer left the membership call open"
  assert_contains "$show" "Resolution mode: answered" "the membership call did not record its close path"
  assert_contains "$show" "Answer: gold-only" "the closed call did not record the captain's actual answer"
  show=$(tasks_in "$home" show sample-gated-work --full)
  assert_contains "$show" "state: queued" "the released work item did not stay queued"
  assert_contains "$show" "held: no" "the card-declared release did not lift the hold"
  assert_contains "$show" "Resolution mode: released" "the released work did not record its close path"
  assert_contains "$show" "Gated work plan." "the released work item lost its body"
  show=$(tasks_in "$home" show sample-forged-call --full)
  assert_contains "$show" "state: queued" "a forged key from freeform prose closed a captain call"
  show=$(tasks_in "$home" show sample-invalid-close-call --full)
  assert_contains "$show" "state: queued" "an unsupported card close mode closed a captain call"
  assert_contains "$show" "held: yes" "an unsupported card close mode released a captain call"

  # Replaying the same capture is a no-op, not a rejected different decision. A
  # run that could not close every answered key still reports nonzero.
  set +e
  out=$(run_lavish "$home" answers "$result" \
    | run_captain "$home" answers --source "the captured result fixture-src sequence 1" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a run that skipped a key reported success"
  assert_contains "$out" "closed: sample-membership-call" \
    "replaying an identical capture was not idempotent: $out"
  assert_contains "$out" "closed: sample-gated-work" \
    "replaying an identical released answer was not idempotent: $out"
  assert_contains "$out" "skipped: sample-nonexistent-call" \
    "a key naming no task was not reported as skipped: $out"

  printf 'Captain answered the forged call directly.\n' > "$home/forged.txt"
  run_captain "$home" answer sample-forged-call --decision-file "$home/forged.txt" >/dev/null \
    || fail "could not close the untouched call through the answer path"
  printf 'Captain answered the invalid-close call directly.\n' > "$home/invalid-close.txt"
  run_captain "$home" answer sample-invalid-close-call --decision-file "$home/invalid-close.txt" >/dev/null \
    || fail "could not close the invalid-close call through the answer path"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "answered calls did not satisfy the completion gate"
  pass "a bound channel's captured answers close their captain-held tasks at answer time"
}

# Answer-time closure is opt-in per source. A channel with no binding must behave
# exactly as it always did: capture, announce, close nothing.
test_unbound_source_closes_no_hold() {
  local home id sid artifact result out show rc
  home=$(make_home lavish-unbound)
  id=sample-unbound-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review sample without binding" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the unbound origin"
  write_origin_meta "$home" "$id"
  printf 'done: deck ready\n' > "$home/state/$id.status"
  printf '# Unbound review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold sample-only-call --title "Captain call: only choice" \
    --reason "captain only choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "could not register the unbound call"

  artifact="$home/data/$id/review.html"
  printf '<h1>Unbound</h1>\n' > "$artifact"
  fm_fake_exit0 "$home/fakebin" lavish-axi
  sid=$(run_lavish "$home" source-id "$artifact") || fail "could not derive the unbound source id"
  run_lavish "$home" arm "$artifact" >/dev/null || fail "could not arm the unbound review"

  result="$home/state/procevent-inbox/$sid.1.result"
  mkdir -p "$home/state/procevent-inbox"
  cat > "$result" <<'EOF'
session:
  file: /review.html
  status: feedback
prompts[1]{uid,prompt,selector,tag,text}:
  "2","Only choice: yes\n\nContext data:\n{\n  \"question\": \"sample-only-call\",\n  \"answer\": \"yes\"\n}","form",choice,"Only choice: yes"
EOF
  set +e
  out=$(run_captain "$home" binding "$sid" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an unbound source reported a binding"
  [ -z "$out" ] || fail "an unbound source printed a binding: $out"
  show=$(tasks_in "$home" show sample-only-call --full)
  assert_contains "$show" "state: queued" "an unbound review closed a captain call"
  assert_contains "$show" "held: yes" "an unbound review released a captain call"
  pass "a channel source with no decision binding closes nothing"
}

# Everything a pre-collapse install already has keeps working: composed
# identities through the shim, short decision keys in recorded metadata, a
# concrete-origin binding, and the chat fallback for old rows.
test_legacy_identities_keep_working() {
  local home id hold out show legacy_text legacy_digest old_hold
  home=$(make_home legacy-compat)
  id=sample-legacy-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Legacy-shaped review" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Legacy review\n\nTwo captain choices remain.\n' > "$home/data/$id/report.md"

  hold=$(run_shim "$home" id "$id" pick-one)
  [ "$hold" = "$id-decision-pick-one" ] || fail "the shim identity was not deterministic: $hold"
  out=$(run_shim "$home" hold "$id" pick-one \
    --title "Pick one" --reason "captain choice pending" --repo sample) \
    || fail "the shim hold path failed"
  [ "$out" = "$hold" ] || fail "the shim hold did not print the composed identity: $out"
  run_shim "$home" hold "$id" keep-two \
    --title "Keep two" --reason "captain second choice pending" --repo sample >/dev/null \
    || fail "the shim second hold failed"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "hold_kind: captain" "the shim-created row is not a plain captain-held task"

  # A pre-collapse metadata attestation records SHORT keys; verify must resolve
  # them through the legacy composed identity.
  printf 'decisions_reviewed=1\ndecision_keys=keep-two,pick-one\n' >> "$home/state/$id.meta"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "legacy short-key metadata did not verify against composed identities"

  # The shim's routed close records the routed work inside the captain decision
  # and clears the recorded edge.
  tasks_in "$home" add sample-legacy-work "Apply the legacy choice" \
    --kind ship --repo sample --blocked-by "$hold" >/dev/null
  tasks_in "$home" add sample-unrouted-work "Unrouted legacy work" \
    --kind ship --repo sample >/dev/null
  printf 'Use route north.\n' > "$home/route.txt"
  if run_shim "$home" resolve "$id" pick-one --decision-file "$home/route.txt" \
    --routed-to sample-missing-work > "$home/missing-route.out" 2> "$home/missing-route.err"; then
    fail "the shim resolve accepted a missing routed task"
  fi
  if run_shim "$home" resolve "$id" pick-one --decision-file "$home/route.txt" \
    --routed-to sample-unrouted-work > "$home/unrouted.out" 2> "$home/unrouted.err"; then
    fail "the shim resolve accepted work not blocked by the legacy decision"
  fi
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" "invalid shim routing closed the legacy decision"
  assert_not_contains "$show" "Resolution recorded" "invalid shim routing recorded an answer"
  run_shim "$home" resolve "$id" pick-one --decision-file "$home/route.txt" \
    --routed-to sample-legacy-work >/dev/null \
    || fail "the shim resolve path failed"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "the shim resolve did not close the row"
  assert_contains "$show" "Use route north." "the shim resolve lost the captain decision"
  assert_contains "$show" "- sample-legacy-work" "the shim resolve lost the routed identities"
  show=$(tasks_in "$home" show sample-legacy-work --full)
  assert_contains "$show" "blocked: no" "the shim resolve did not release the routed work"

  old_hold=$(run_shim "$home" hold "$id" old-route \
    --title "Old routed choice" --reason "captain old route pending" --repo sample)
  tasks_in "$home" add sample-old-routed-work "Apply the old routed choice" \
    --kind ship --repo sample --blocked-by "$old_hold" >/dev/null
  printf 'Use the historical route.\n' > "$home/old-route.txt"
  legacy_text=$(cat "$home/old-route.txt")
  if command -v shasum >/dev/null 2>&1; then
    legacy_digest=$(printf '%s' "$legacy_text" | shasum -a 256 | awk '{print $1}')
  else
    legacy_digest=$(printf '%s' "$legacy_text" | sha256sum | awk '{print $1}')
  fi
  printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: sample-old-routed-work\nResolution mode: routed\n\nCaptain decision:\n%s\n\nRouted work:\n- sample-old-routed-work\n' \
    "$legacy_digest" "$legacy_text" > "$home/old-route-body.txt"
  tasks_in "$home" update "$old_hold" --body-file "$home/old-route-body.txt" --archive-body >/dev/null
  run_shim "$home" resolve "$id" old-route --decision-file "$home/old-route.txt" \
    --routed-to sample-old-routed-work >/dev/null \
    || fail "the shim did not replay a matching pre-collapse routed record"
  show=$(tasks_in "$home" show "$old_hold" --full)
  assert_contains "$show" "state: done" "the replayed legacy resolve did not close its hold"
  show=$(tasks_in "$home" show sample-old-routed-work --full)
  assert_contains "$show" "blocked_by: none" "the replayed legacy resolve did not clear its recorded edge"

  # The shim decline path maps onto the same recorded answer.
  printf 'Declined: keep the current shape.\n' > "$home/decline.txt"
  run_shim "$home" decline "$id" keep-two --decision-file "$home/decline.txt" >/dev/null \
    || fail "the shim decline path failed"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "shim-closed rows did not satisfy the completion gate"

  # A concrete-origin binding (a pre-collapse record) makes short channel keys
  # resolve through the composed identity.
  run_shim "$home" hold "$id" third-choice \
    --title "Third choice" --reason "captain third choice pending" --repo sample >/dev/null
  run_shim "$home" bind legacy-src "$id" >/dev/null || fail "the shim bind path failed"
  [ "$(run_captain "$home" binding legacy-src)" = "$id" ] \
    || fail "the concrete-origin binding was not preserved"
  printf 'third-choice\toption b\t\n' \
    | run_captain "$home" answers "$(run_captain "$home" binding legacy-src)" \
        --source "legacy channel" >/dev/null \
    || fail "a short key did not resolve through the concrete-origin binding"
  show=$(tasks_in "$home" show "$id-decision-third-choice" --full)
  assert_contains "$show" "state: done" "the legacy-keyed answer did not close its row"

  run_shim "$home" hold "$id" fourth-choice \
    --title "Fourth choice" --reason "captain fourth choice pending" --repo sample >/dev/null
  legacy_text=$(printf 'Captain answered this decision through legacy replay.\nDecision key: fourth-choice\nAnswer: option c\n')
  if command -v shasum >/dev/null 2>&1; then
    legacy_digest=$(printf '%s' "$legacy_text" | shasum -a 256 | awk '{print $1}')
  else
    legacy_digest=$(printf '%s' "$legacy_text" | sha256sum | awk '{print $1}')
  fi
  printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: none\nResolution mode: answered\n\nCaptain decision:\n%s\n' \
    "$legacy_digest" "$legacy_text" > "$home/legacy-body.txt"
  tasks_in "$home" update "$id-decision-fourth-choice" --body-file "$home/legacy-body.txt" --archive-body >/dev/null
  tasks_in "$home" "done" "$id-decision-fourth-choice" >/dev/null
  out=$(printf 'fourth-choice\toption c\t\n' \
    | run_captain "$home" answers "$id" --source "legacy replay") \
    || fail "an identical pre-collapse keyed answer was not idempotent"
  assert_contains "$out" "closed: $id-decision-fourth-choice" \
    "the pre-collapse keyed answer digest was treated as drift"
  out=$(printf '%s-decision-fourth-choice\toption c\t\n' "$id" \
    | run_captain "$home" answers --source "legacy replay") \
    || fail "a full legacy task-id replay without an origin was not idempotent"
  assert_contains "$out" "closed: $id-decision-fourth-choice" \
    "the origin-free legacy replay digest was treated as drift"
  pass "legacy identities, metadata, bindings, and the shim keep working"
}

# The intake is channel-agnostic, so chat must reach it the same way a captured
# review does - for a task-id key, and for a legacy composed identity.
test_chat_channel_feeds_the_same_keyed_answer_intake() {
  local home id fb show
  home=$(make_home chat-channel)
  id=sample-chat-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review sample chat routing" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the chat-channel origin"
  write_origin_meta "$home" "$id" ship
  printf 'needs-decision [key=chat-choice]: pick option A or option B\n' > "$home/state/$id.status"
  printf '# Chat review\n\nTwo captain choices remain.\n' > "$home/data/$id/report.md"
  run_shim "$home" hold "$id" chat-choice \
    --title "Choose the sample chat option" --reason "captain chat choice pending" --repo sample >/dev/null \
    || fail "could not register the legacy chat row"
  run_captain "$home" hold sample-chat-followup --title "Choose the chat follow-up" \
    --reason "captain follow-up choice pending" --repo sample >/dev/null \
    || fail "could not register the task-id chat call"
  run_captain "$home" complete "$id" "$id-decision-chat-choice" sample-chat-followup >/dev/null \
    || fail "completion failed for the chat calls"
  grep -F 'captain-held [key=chat-choice]' "$home/state/$id.status" >/dev/null \
    || fail "precondition: completion did not transfer the decision to its durable owner"

  fb="$home/fakebin"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "${1:-}" >> "$FM_SEND_LOG"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"

  : > "$home/send.log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "$id" --resolve-key chat-choice "go with option A" >/dev/null 2>&1 \
    || fail "an answer to a transferred legacy decision was refused by the chat channel"
  # The answer rides fm-send's durable inbox plane: the record carries the
  # text while the typed channel carries only the doorbell.
  grep -qF "go with option A" "$home/state/$id.inbox/001.msg" \
    || fail "the answer text never reached the worker's durable inbox record"
  show=$(tasks_in "$home" show "$id-decision-chat-choice" --full)
  assert_contains "$show" "state: done" "a chat answer left the legacy row open"
  assert_contains "$show" "Answer: go with option A" "the chat-answered row lost the captain answer"

  : > "$home/send.log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "$id" --resolve-key sample-chat-followup "take the second option" >/dev/null 2>&1 \
    || fail "an answer keyed by a task id was refused by the chat channel"
  show=$(tasks_in "$home" show sample-chat-followup --full)
  assert_contains "$show" "state: done" "a chat answer left the task-id call open"
  assert_contains "$show" "Resolution mode: answered" "the chat-answered call did not record its close path"
  assert_contains "$show" "Answer: take the second option" "the chat-answered call lost the captain answer"
  assert_contains "$show" "answer sent to $id" "the chat-answered call lost its channel provenance"

  if env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "$id" --resolve-key sample-chat-followup "again" \
    > "$home/closed-key.out" 2> "$home/closed-key.err"; then
    fail "a key already closed in both ledgers was accepted"
  fi
  run_captain "$home" verify "$id" >/dev/null \
    || fail "chat-answered calls did not satisfy the completion gate"
  pass "the chat channel feeds the same keyed-answer intake a captured review does"
}

test_origin_slug_validation_precedes_path_construction() {
  local home
  home=$(make_home slug-validation)
  if run_captain "$home" complete "../escape" --none > "$home/escape.out" 2> "$home/escape.err"; then
    fail "complete accepted a path-escaping origin id"
  fi
  assert_grep "privacy-safe slug" "$home/escape.err" "the refusal must name the slug contract"
  if run_captain "$home" verify "../escape" > "$home/escape-verify.out" 2> "$home/escape-verify.err"; then
    fail "verify accepted a path-escaping origin id"
  fi
  if run_captain "$home" hold "bad id" --title "x" --reason "y" > "$home/bad-hold.out" 2> "$home/bad-hold.err"; then
    fail "hold accepted an invalid task id"
  fi
  pass "completion and verification validate origins before constructing paths"
}

# --- record divergence ------------------------------------------------------

run_drain() {  # <home>
  local home=$1
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null
}

# Reconstructs the 2026-08-06 loss with synthetic names: the answer was posted
# as a `resolved [key=...]` line and nothing else, so the status fold went quiet
# while the durable captain-held task stayed open and kept reading as if the
# captain had never spoken. Both identities that can carry a captain call must
# be caught - the collapsed one (the key IS the task id) and the legacy derived
# one a pre-collapse origin minted - and the report must reach the drain, which
# is where firstmate actually looks.
test_status_resolution_over_an_open_hold_is_signalled() {
  local home id out drain
  home=$(make_home divergence-signalled)
  id=sample-route-review
  tasks_in "$home" add "$id" "Investigate sample routing" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the investigation fixture"
  write_origin_meta "$home" "$id"
  run_captain "$home" hold sample-route-call \
    --title "Choose route: north or south" --reason "captain route choice pending" \
    --repo sample --origin "$id" >/dev/null \
    || fail "could not register the collapsed-identity captain call"
  run_captain "$home" hold "$id-decision-access" \
    --title "Open or restricted sample access" --reason "captain access choice pending" \
    --repo sample --origin "$id" >/dev/null \
    || fail "could not register the legacy-identity captain call"
  cat > "$home/state/$id.status" <<'EOF'
working: report drafted
needs-decision [key=sample-route-call]: north or south
resolved [key=sample-route-call]: answered: north
needs-decision [key=access]: open or restricted sample access
resolved [key=access]: answered: restricted
done: report complete
EOF

  out=$(run_captain "$home" diverged) || fail "diverged failed on the reconstructed loss"
  printf '%s\n' "$out" | grep -F "sample-route-call	$id	sample-route-call" >/dev/null \
    || fail "the collapsed-identity divergence was not signalled: $out"
  printf '%s\n' "$out" | grep -F "$id-decision-access	$id	access" >/dev/null \
    || fail "the legacy-identity divergence was not signalled: $out"

  drain=$(run_drain "$home") || fail "the drain failed while reporting divergence"
  printf '%s\n' "$drain" | grep -F 'RECORD DIVERGENCE' >/dev/null \
    || fail "the divergence never reached the drain: $drain"
  printf '%s\n' "$drain" | grep -F 'sample-route-call [key=sample-route-call]' >/dev/null \
    || fail "the drain section omitted the collapsed-identity divergence: $drain"
  printf '%s\n' "$drain" | grep -F "$id-decision-access [key=access]" >/dev/null \
    || fail "the drain section omitted the legacy-identity divergence: $drain"

  # It signals; it never closes. Both records must survive the report unchanged,
  # because closing a captain call wrongly removes it from review entirely.
  assert_grep "sample-route-call" "$home/data/backlog.md" "the report must not remove the captain-held task"
  tasks_in "$home" show sample-route-call --full | grep -E '^  held: yes' >/dev/null \
    || fail "the report released or closed the captain-held task"
  [ "$(grep -c '^resolved \[key=sample-route-call\]' "$home/state/$id.status")" = 1 ] \
    || fail "the report rewrote the status log"

  # And it names BOTH reconciliation directions. A status resolution is not proof
  # the captain ruled: one of the real cases dissolved because its premise was
  # false and another was a question of fact whose first reading was wrong, so
  # the only safe instruction is "reconcile with what actually happened".
  printf '%s\n' "$drain" | grep -F 'fm-captain-hold.sh answer' >/dev/null \
    || fail "the drain section does not say how to record the captain's answer: $drain"
  printf '%s\n' "$drain" | grep -F 're-open the status decision' >/dev/null \
    || fail "the drain section does not offer the re-open direction: $drain"
  pass "a status resolution over a still-open captain-held task is signalled, not closed"
}

# The false-signal boundary, driven by the shapes that are genuinely fine. A
# captain call whose deliverable IS the decision has no routed work item at all,
# and that is legitimate: routed work must never be part of the test. Nor may a
# verified `captain-held` transfer, a still-open status decision, an already
# answered call, or an ordinary task that merely had a keyed question answered.
test_legitimate_holds_produce_no_divergence_signal() {
  local home id out drain answer
  home=$(make_home divergence-no-false-signal)
  id=sample-systems-review
  tasks_in "$home" add "$id" "Investigate sample systems" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the investigation fixture"
  write_origin_meta "$home" "$id"

  # (1) The decision IS the deliverable: held for the captain, nothing routed,
  # no status line anywhere naming it.
  run_captain "$home" hold sample-standalone-call \
    --title "Adopt the sample naming convention" --reason "captain call with no routed work" \
    --repo sample >/dev/null || fail "could not register the deliverable-is-the-decision call"
  # (2) The verified transfer: still open structurally, closed on the status side
  # by the captain-held verb command_complete writes.
  run_captain "$home" hold sample-transfer-call \
    --title "Choose the sample retention window" --reason "captain retention choice pending" \
    --repo sample >/dev/null || fail "could not register the transferred call"
  # (4) An already answered call whose status line reads resolved.
  run_captain "$home" hold sample-answered-call \
    --title "Choose the sample export format" --reason "captain export choice pending" \
    --repo sample >/dev/null || fail "could not register the answered call"
  answer="$home/answer.txt"
  printf 'Export as CSV.\n' > "$answer"
  run_captain "$home" answer sample-answered-call --decision-file "$answer" >/dev/null \
    || fail "could not record the captain answer fixture"
  # (5) An ordinary in-flight work item that is not held for the captain.
  tasks_in "$home" add sample-plain-work "Ordinary sample work" --kind ship --repo sample --start >/dev/null \
    || fail "could not create the ordinary work fixture"

  cat > "$home/state/$id.status" <<'EOF'
working: report drafted
needs-decision [key=sample-transfer-call]: choose the retention window
captain-held [key=sample-transfer-call]: tracked by sample-transfer-call
needs-decision [key=sample-open-call]: still open on both sides
needs-decision [key=sample-answered-call]: choose the export format
resolved [key=sample-answered-call]: answered: CSV
needs-decision [key=sample-plain-work]: worker question about the sample fixture
resolved [key=sample-plain-work]: answered: go ahead
EOF
  # (3) A still-open status decision whose structured twin is also still open.
  run_captain "$home" hold sample-open-call \
    --title "Choose the sample refresh cadence" --reason "captain cadence choice pending" \
    --repo sample >/dev/null || fail "could not register the still-open call"

  out=$(run_captain "$home" diverged) || fail "diverged failed on the legitimate shapes"
  [ -z "$out" ] || fail "legitimate captain holds produced a false divergence signal: $out"

  drain=$(run_drain "$home") || fail "the drain failed on the legitimate shapes"
  if printf '%s\n' "$drain" | grep -F 'RECORD DIVERGENCE' >/dev/null; then
    fail "the drain printed a divergence section with nothing diverging: $drain"
  fi
  printf '%s\n' "$drain" | grep -F 'sample-open-call' >/dev/null \
    || fail "setup error: the still-open decision should still reach OPEN DECISIONS: $drain"
  pass "a captain call with no routed work, a verified transfer, an open decision, and an answered call all stay silent"
}

# Ordinary Done retention pruning moves an answered captain call out of the live
# backlog into the configured tasks-axi archive. The completion gate must keep
# accepting it there, or teardown blocks forever on work the captain did answer.
test_resolved_archived_hold_verification_is_strict() {
  local home origin hold archive pristine record
  home=$(make_home archived-resolved-hold)
  origin=sample-archived-review
  archive="$home/data/calls/archive.md"
  mkdir -p "$home/data/$origin" "$(dirname "$archive")"
  sed 's#archive = "data/done-archive.md"#archive = "data/calls/archive.md"#' \
    "$ROOT/.tasks.toml" > "$home/.tasks.toml"
  tasks_in "$home" add "$origin" "Review archived call verification" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create archived-call origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Archived call review\n' > "$home/data/$origin/report.md"
  hold=sample-archived-route-call
  run_captain "$home" hold "$hold" \
    --title "Choose archived route" --reason "captain route pending" --repo sample >/dev/null \
    || fail "could not create hold for archive verification"
  run_captain "$home" complete "$origin" "$hold" >/dev/null \
    || fail "could not record archived-call inventory"
  printf 'Use archived route north.\n' > "$home/archived-decision.txt"
  run_captain "$home" answer "$hold" --decision-file "$home/archived-decision.txt" >/dev/null \
    || fail "could not answer the call before archive pruning"
  tasks_in "$home" prune --state "done" --keep 0 >/dev/null \
    || fail "could not prune the answered call to the configured archive"
  assert_no_grep "- [x] $hold -" "$home/data/backlog.md" \
    "the answered call remained in the live backlog after pruning"
  assert_grep "- [x] $hold -" "$archive" \
    "the answered call did not use the configured archive path"
  run_captain "$home" verify "$origin" >/dev/null \
    || fail "a configured archived answered call did not pass verification"
  cp "$archive" "$home/archive.pristine"
  pristine="$home/archive.pristine"

  rm "$archive"
  if run_captain "$home" verify "$origin" > "$home/missing.out" 2> "$home/missing.err"; then
    fail "verification accepted a missing archived call"
  fi
  assert_grep "absent from the live backlog and configured archive" "$home/missing.err" \
    "the missing-archive failure did not identify both authoritative locations"
  cp "$pristine" "$archive"

  sed "/^  Decision digest:/d" "$pristine" > "$archive"
  if run_captain "$home" verify "$origin" > "$home/malformed.out" 2> "$home/malformed.err"; then
    fail "verification accepted a malformed archived resolution record"
  fi
  assert_grep "invalid decision digest" "$home/malformed.err" \
    "the malformed-archive failure did not identify the invalid structured field"
  cp "$pristine" "$archive"

  # The archive is append-only history, not a uniqueness index: an earlier
  # non-conforming cycle of the same identity sits beside the durably resolved
  # one, and the resolved cycle still attests that the captain answered.
  record=$(awk -v id="$hold" '
    index($0, "- [x] " id " - ") == 1 { capture=1 }
    capture && /^## / { exit }
    capture { print }
  ' "$pristine")
  {
    printf '## Archived 2026-07-15\n'
    printf '%s\n' "$record" | sed '/^  Decision digest:/d'
    printf '\n'
    cat "$pristine"
  } > "$archive"
  run_captain "$home" verify "$origin" > "$home/archive-duplicate.out" 2> "$home/archive-duplicate.err" \
    || fail "an earlier non-conforming archived cycle blocked a durably resolved one: $(cat "$home/archive-duplicate.err")"

  {
    printf '## Archived 2026-07-15\n'
    printf '%s\n' "$record" | sed '/^  Decision digest:/d'
    printf '\n'
    sed '/^  Decision digest:/d' "$pristine"
  } > "$archive"
  if run_captain "$home" verify "$origin" > "$home/all-malformed.out" 2> "$home/all-malformed.err"; then
    fail "verification accepted an identity whose every archived record is malformed"
  fi
  assert_grep "invalid decision digest" "$home/all-malformed.err" \
    "an all-malformed duplicated identity did not fail on the invalid structured field"
  assert_no_grep "absent from the live backlog and configured archive" "$home/all-malformed.err" \
    "a present-but-malformed archived identity must not also claim the record is absent"
  [ "$(grep -c '^fm-captain-hold:' "$home/all-malformed.err")" = 1 ] \
    || fail "an all-malformed duplicated identity must emit exactly one accurate error: $(cat "$home/all-malformed.err")"
  cp "$pristine" "$archive"

  # A home that re-used an identity after retention pruning carries it in both
  # places. The live backlog is authoritative for open work, so a satisfied live
  # record must still verify - refusing it stranded such homes with no recovery
  # short of --force - while a live record that satisfies nothing still fails.
  tasks_in "$home" add "$hold" "Conflicting live archived route" --kind ship --repo sample >/dev/null \
    || fail "could not create the live/archive reuse fixture"
  tasks_in "$home" hold "$hold" --reason "captain conflicting route pending" --kind captain >/dev/null \
    || fail "could not activate the live/archive reuse fixture"
  run_captain "$home" verify "$origin" > "$home/live-reuse.out" 2> "$home/live-reuse.err" \
    || fail "an archived earlier cycle blocked a satisfied live hold: $(cat "$home/live-reuse.err")"

  tasks_in "$home" unhold "$hold" >/dev/null \
    || fail "could not release the live/archive reuse fixture"
  if run_captain "$home" verify "$origin" > "$home/live-unsatisfied.out" 2> "$home/live-unsatisfied.err"; then
    fail "an archived earlier cycle rescued a live record that satisfies nothing"
  fi
  assert_grep "neither held for the captain nor closed with a recorded captain answer" \
    "$home/live-unsatisfied.err" "an unsatisfied live record must fail on its own merits"
  pass "archived answered calls verify on any complete structured archived cycle"
}

# The archive fallback exists for an identity that ordinary Done retention
# pruning moved out of the live backlog. `tasks-axi show` exits non-zero for a
# missing task and for a backend read failure alike, so keying the fallback on
# exit status alone would read "the backlog is unreadable" as "this was pruned"
# and judge the call from a stale earlier archived cycle. That fails open: the
# gate would report a genuinely open captain call as verified, and teardown
# would then erase the origin's work.
test_unreadable_live_backlog_never_falls_back_to_archive() {
  local home origin hold archive rc
  home=$(make_home unreadable-backlog-archive)
  origin=sample-unreadable-review
  archive="$home/data/done-archive.md"
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Review unreadable backlog fallback" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create the unreadable-backlog origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Unreadable backlog review\n' > "$home/data/$origin/report.md"
  hold=sample-unreadable-route-call
  run_captain "$home" hold "$hold" \
    --title "Choose unreadable route" --reason "captain route pending" --repo sample >/dev/null \
    || fail "could not create the hold"
  run_captain "$home" complete "$origin" "$hold" >/dev/null \
    || fail "could not record the call inventory"
  printf 'Use route north.\n' > "$home/decision.txt"
  run_captain "$home" answer "$hold" --decision-file "$home/decision.txt" >/dev/null \
    || fail "could not answer the call before pruning"
  tasks_in "$home" prune --state "done" --keep 0 >/dev/null \
    || fail "could not prune the answered call into the archive"
  assert_grep "- [x] $hold -" "$archive" \
    "the answered call did not reach the configured archive"
  run_captain "$home" verify "$origin" >/dev/null \
    || fail "a durably resolved archived call did not verify from a readable backlog"

  # Re-open the same identity live, so the archive now holds a STALE resolved
  # cycle while the real call is open. This is the reuse case the archive
  # fallback is explicitly designed to support.
  tasks_in "$home" add "$hold" "Reopened route call" --kind ship --repo sample >/dev/null \
    || fail "could not re-open the identity"
  tasks_in "$home" hold "$hold" --reason "captain route still pending" --kind captain >/dev/null \
    || fail "could not re-activate the captain hold"

  # With the live backlog readable, the open live hold is authoritative and
  # verification passes on the live record, never on the stale archived one.
  run_captain "$home" verify "$origin" >/dev/null \
    || fail "a satisfied live hold did not verify while an archived cycle existed"

  chmod 000 "$home/data/backlog.md"
  set +e
  run_captain "$home" verify "$origin" > "$home/unreadable.out" 2> "$home/unreadable.err"
  rc=$?
  set -e
  # Restore before any assertion can abort the case and leave the fixture
  # undeletable by the suite's cleanup.
  chmod 600 "$home/data/backlog.md"
  [ "$rc" -ne 0 ] \
    || fail "verification passed while the live backlog could not be read, trusting a stale archived cycle"
  assert_grep "cannot read the live backlog" "$home/unreadable.err" \
    "an unreadable backlog did not report itself as a read failure"
  assert_no_grep "absent from the live backlog" "$home/unreadable.err" \
    "an unreadable backlog must not be reported as a missing identity"
  pass "an unreadable live backlog fails loudly instead of falling back to a stale archived cycle"
}

# The inverse guard: the fallback must still work. A genuinely pruned identity
# reports NOT_FOUND, which is proof of absence rather than a backend failure,
# so the archive remains authoritative for it.
test_pruned_identity_still_resolves_from_archive() {
  local home origin hold archive
  home=$(make_home pruned-archive-fallback)
  origin=sample-pruned-review
  archive="$home/data/done-archive.md"
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Review pruned fallback" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create the pruned-fallback origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Pruned fallback review\n' > "$home/data/$origin/report.md"
  hold=sample-pruned-route-call
  run_captain "$home" hold "$hold" \
    --title "Choose pruned route" --reason "captain route pending" --repo sample >/dev/null \
    || fail "could not create the hold"
  run_captain "$home" complete "$origin" "$hold" >/dev/null \
    || fail "could not record the call inventory"
  printf 'Use route south.\n' > "$home/decision.txt"
  run_captain "$home" answer "$hold" --decision-file "$home/decision.txt" >/dev/null \
    || fail "could not answer the call before pruning"
  tasks_in "$home" prune --state "done" --keep 0 >/dev/null \
    || fail "could not prune the answered call into the archive"
  assert_no_grep "- [x] $hold -" "$home/data/backlog.md" \
    "the answered call remained live after pruning"
  assert_grep "- [x] $hold -" "$archive" \
    "the answered call did not reach the archive"
  run_captain "$home" verify "$origin" > "$home/pruned.out" 2> "$home/pruned.err" \
    || fail "a proven-absent identity did not fall back to the archive: $(cat "$home/pruned.err")"
  pass "a proven-absent identity still verifies from the configured archive"
}

# Only NOT_FOUND proves absence. tasks-axi raises VALIDATION_ERROR for ANY
# rejected key, including keys this gate never inspects, so accepting that code
# as "pruned" reopens the fail-open on an ordinary .tasks.toml typo: a genuinely
# open live captain hold plus any stale archived cycle would verify, and
# teardown would then erase the origin's work.
test_unrelated_config_error_never_proves_absence() {
  local home origin hold archive rc
  home=$(make_home config-error-absence)
  origin=sample-config-error-review
  archive="$home/data/done-archive.md"
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Review config-error absence" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create the config-error origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Config error review\n' > "$home/data/$origin/report.md"
  hold=sample-config-error-call
  run_captain "$home" hold "$hold" \
    --title "Choose config-error route" --reason "captain route pending" --repo sample >/dev/null \
    || fail "could not create the hold"
  run_captain "$home" complete "$origin" "$hold" >/dev/null \
    || fail "could not record the call inventory"
  printf 'Use route north.\n' > "$home/decision.txt"
  run_captain "$home" answer "$hold" --decision-file "$home/decision.txt" >/dev/null \
    || fail "could not answer the call before pruning"
  tasks_in "$home" prune --state "done" --keep 0 >/dev/null \
    || fail "could not prune the answered call into the archive"
  assert_grep "- [x] $hold -" "$archive" \
    "the answered call did not reach the configured archive"

  # Re-open the same identity, so the call is genuinely OPEN while a stale
  # resolved cycle sits in the archive.
  tasks_in "$home" add "$hold" "Reopened config-error call" --kind ship --repo sample >/dev/null \
    || fail "could not re-open the identity"
  tasks_in "$home" hold "$hold" --reason "captain route still pending" --kind captain >/dev/null \
    || fail "could not re-activate the captain hold"
  run_captain "$home" verify "$origin" >/dev/null \
    || fail "a satisfied live hold did not verify under a healthy config"

  # An unrelated key the archive gate never inspects. tasks-axi rejects the
  # whole config, so no task can be read at all.
  sed 's/done_keep = 10/done_keep = "abc"/' "$home/.tasks.toml" > "$home/.tasks.toml.tmp"
  mv "$home/.tasks.toml.tmp" "$home/.tasks.toml"
  set +e
  run_captain "$home" verify "$origin" > "$home/config-error.out" 2> "$home/config-error.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] \
    || fail "verification passed on an open captain call because an unrelated config key was malformed"
  assert_no_grep "^verified:" "$home/config-error.out" \
    "an open captain call was reported verified under a rejected config"
  pass "a rejected config never proves an identity absent from the live backlog"
}

# The live-backlog read is not the only place absence is inferred. An archive
# that exists but cannot be read yielded an empty count, which callers compared
# with -gt and treated as "no archived record", letting hold re-create an
# identity the retirement guard must refuse permanently.
test_unreadable_archive_never_retires_or_re_mints() {
  local home origin hold archive rc
  home=$(make_home unreadable-archive-guard)
  origin=sample-unreadable-archive-review
  archive="$home/data/done-archive.md"
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Review unreadable archive" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create the unreadable-archive origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Unreadable archive review\n' > "$home/data/$origin/report.md"
  hold=sample-unreadable-archive-call
  run_captain "$home" hold "$hold" \
    --title "Choose archive route" --reason "captain route pending" --repo sample >/dev/null \
    || fail "could not create the hold"
  run_captain "$home" complete "$origin" "$hold" >/dev/null \
    || fail "could not record the call inventory"
  printf 'Use route east.\n' > "$home/decision.txt"
  run_captain "$home" answer "$hold" --decision-file "$home/decision.txt" >/dev/null \
    || fail "could not answer the call before pruning"
  tasks_in "$home" prune --state "done" --keep 0 >/dev/null \
    || fail "could not prune the answered call into the archive"

  # Readable archive: the retirement guard refuses to re-mint the answered call.
  if run_captain "$home" hold "$hold" \
    --title "Re-minted call" --reason "should refuse" --repo sample > "$home/retire.out" 2> "$home/retire.err"; then
    fail "hold re-created an identity already durably resolved in the archive"
  fi
  assert_grep "already durably resolved" "$home/retire.err" \
    "the retirement guard did not name the durable archived resolution"

  chmod 000 "$archive"
  set +e
  run_captain "$home" hold "$hold" \
    --title "Re-minted call" --reason "should refuse" --repo sample > "$home/unreadable-archive.out" 2> "$home/unreadable-archive.err"
  rc=$?
  set -e
  chmod 600 "$archive"
  [ "$rc" -ne 0 ] \
    || fail "hold re-minted an already-answered captain call while the archive could not be read"
  assert_grep "cannot read the configured tasks-axi archive" "$home/unreadable-archive.err" \
    "an unreadable archive did not report itself as a read failure"
  pass "an unreadable archive fails loudly instead of reading as no archived record"
}

# NOT_FOUND proves absence only when the backlog it was read from actually
# exists. tasks-axi reads a missing backlog file as an empty backlog and answers
# NOT_FOUND for EVERY id, so a mistyped [markdown] path or a backlog moved aside
# would prove every open captain call "pruned" and let a stale archived cycle
# verify it - the identical fail-open, reached through the path key.
test_missing_backlog_file_never_proves_absence() {
  local home origin hold archive rc
  home=$(make_home missing-backlog-absence)
  origin=sample-missing-backlog-review
  archive="$home/data/done-archive.md"
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Review missing backlog absence" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create the missing-backlog origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Missing backlog review\n' > "$home/data/$origin/report.md"
  hold=sample-missing-backlog-call
  run_captain "$home" hold "$hold" \
    --title "Choose missing-backlog route" --reason "captain route pending" --repo sample >/dev/null \
    || fail "could not create the hold"
  run_captain "$home" complete "$origin" "$hold" >/dev/null \
    || fail "could not record the call inventory"
  printf 'Use route west.\n' > "$home/decision.txt"
  run_captain "$home" answer "$hold" --decision-file "$home/decision.txt" >/dev/null \
    || fail "could not answer the call before pruning"
  tasks_in "$home" prune --state "done" --keep 0 >/dev/null \
    || fail "could not prune the answered call into the archive"
  assert_grep "- [x] $hold -" "$archive" \
    "the answered call did not reach the configured archive"

  # Re-open the identity, so the captain call is genuinely OPEN while the
  # archive still holds the stale resolved cycle from the earlier round.
  tasks_in "$home" add "$hold" "Reopened missing-backlog call" --kind ship --repo sample >/dev/null \
    || fail "could not re-open the identity"
  tasks_in "$home" hold "$hold" --reason "captain route still pending" --kind captain >/dev/null \
    || fail "could not re-activate the captain hold"
  run_captain "$home" verify "$origin" >/dev/null \
    || fail "a satisfied live hold did not verify under a healthy config"

  # The backlog file the config resolves to is gone; the real record of the open
  # call still exists on disk beside it.
  mv "$home/data/backlog.md" "$home/data/backlog.md.moved"
  set +e
  run_captain "$home" verify "$origin" > "$home/missing-backlog.out" 2> "$home/missing-backlog.err"
  rc=$?
  set -e
  mv "$home/data/backlog.md.moved" "$home/data/backlog.md"
  [ "$rc" -ne 0 ] \
    || fail "verification passed on an open captain call because the resolved backlog file was missing"
  assert_no_grep "^verified:" "$home/missing-backlog.out" \
    "an open captain call was reported verified with no backlog to read it from"
  assert_grep "data/backlog.md" "$home/missing-backlog.err" \
    "the failure did not name the resolved backlog path that is missing"

  # The same hole through the config key rather than the file: a well-formed but
  # wrong path resolves to a file that does not exist.
  sed 's|^path = "data/backlog.md"|path = "data/backlogg.md"|' "$home/.tasks.toml" > "$home/.tasks.toml.tmp"
  mv "$home/.tasks.toml.tmp" "$home/.tasks.toml"
  set +e
  run_captain "$home" verify "$origin" > "$home/wrong-path.out" 2> "$home/wrong-path.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] \
    || fail "verification passed on an open captain call because [markdown] path named a nonexistent file"
  assert_no_grep "^verified:" "$home/wrong-path.out" \
    "an open captain call was reported verified from a mistyped backlog path"
  assert_grep "data/backlogg.md" "$home/wrong-path.err" \
    "the failure did not name the mistyped backlog path it resolved"
  pass "a missing resolved backlog file never proves a captain call absent"
}

# "A backlog file that does not exist proves nothing" is a rule about DEPARTURE:
# a recorded identity reported NOT_FOUND against a file that was never written
# may not be judged from a stale archived cycle. `hold` asks the opposite
# question before creating a task - is this identity already carried live - and a
# home whose backlog has not been written yet answers that correctly, because
# `tasks-axi add` creates the file. Nothing under bin/ writes data/backlog.md for
# a main home and data/ is gitignored, so refusing there strands a fresh clone or
# a freshly seeded secondmate home: it cannot mint its first captain call at all.
test_first_call_in_a_home_with_no_backlog_file() {
  local home hold archive rc
  home=$(make_home first-call-no-backlog)
  hold=sample-first-call
  archive="$home/data/done-archive.md"
  rm -f "$home/data/backlog.md"
  assert_absent "$home/data/backlog.md" \
    "the fixture must start with no backlog file at all"

  run_captain "$home" hold "$hold" \
    --title "Choose the first route" --reason "captain route pending" --repo sample \
    > "$home/first-call.out" 2> "$home/first-call.err" \
    || fail "the first captain call in a home with no backlog file was refused: $(cat "$home/first-call.err")"
  assert_grep "$hold" "$home/first-call.out" \
    "hold did not print the id of the captain call it created"
  assert_present "$home/data/backlog.md" \
    "the first captain call did not create the configured backlog file"
  assert_grep "- [ ] $hold -" "$home/data/backlog.md" \
    "the created captain call is not carried by the live backlog"
  tasks_in "$home" show "$hold" --full > "$home/first-call-show.txt" \
    || fail "the created captain call is not readable through tasks-axi"
  assert_grep "hold_kind: captain" "$home/first-call-show.txt" \
    "the created task did not retain its captain hold"

  # The same fresh-home path must still refuse an identity already durably
  # resolved in a reachable archive: that guard is a separate read, and an
  # unwritten backlog must not disable it.
  printf 'Use the first route.\n' > "$home/decision.txt"
  run_captain "$home" answer "$hold" --decision-file "$home/decision.txt" >/dev/null \
    || fail "could not answer the first captain call"
  tasks_in "$home" prune --state "done" --keep 0 >/dev/null \
    || fail "could not prune the answered first call into the archive"
  assert_grep "- [x] $hold -" "$archive" \
    "the answered first call did not reach the configured archive"
  mv "$home/data/backlog.md" "$home/data/backlog.md.moved"
  set +e
  run_captain "$home" hold "$hold" \
    --title "Re-minted first call" --reason "should refuse" --repo sample \
    > "$home/first-remint.out" 2> "$home/first-remint.err"
  rc=$?
  set -e
  mv "$home/data/backlog.md.moved" "$home/data/backlog.md"
  [ "$rc" -ne 0 ] \
    || fail "hold re-minted an identity durably resolved in the archive because the backlog file was missing"
  assert_grep "already durably resolved" "$home/first-remint.err" \
    "the retirement guard did not refuse the archived resolution from a home with no backlog file"

  # And a backlog that EXISTS but cannot be read is still never a free identity.
  chmod 000 "$home/data/backlog.md"
  set +e
  run_captain "$home" hold sample-unreadable-first-call \
    --title "Unreadable first call" --reason "should refuse" --repo sample \
    > "$home/first-unreadable.out" 2> "$home/first-unreadable.err"
  rc=$?
  set -e
  chmod 600 "$home/data/backlog.md"
  [ "$rc" -ne 0 ] \
    || fail "hold treated an unreadable backlog as a free identity"
  assert_grep "cannot read the live backlog" "$home/first-unreadable.err" \
    "an unreadable backlog was not reported as a read failure by hold"
  pass "a home with no backlog file mints its first captain call and still refuses a retired one"
}

# The archive-readability guard must see a file it cannot reach because of its
# PARENT directory, not only one whose own mode denies the read: `[ -f ]` and
# `[ -r ]` both answer false under an unsearchable directory, which reads as
# "absent, count 0" and lets hold re-mint an already-answered captain call.
test_unreachable_archive_directory_never_re_mints() {
  local home origin hold archive_dir rc
  home=$(make_home unreachable-archive-dir)
  origin=sample-archive-dir-review
  archive_dir="$home/arch"
  mkdir -p "$home/data/$origin" "$archive_dir"
  cat > "$home/.tasks.toml" <<'TOMLEOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "arch/done-archive.md"
done_keep = 10
TOMLEOF
  tasks_in "$home" add "$origin" "Review unreachable archive directory" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create the unreachable-archive-dir origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Unreachable archive directory review\n' > "$home/data/$origin/report.md"
  hold=sample-archive-dir-call
  run_captain "$home" hold "$hold" \
    --title "Choose archive-dir route" --reason "captain route pending" --repo sample >/dev/null \
    || fail "could not create the hold"
  run_captain "$home" complete "$origin" "$hold" >/dev/null \
    || fail "could not record the call inventory"
  printf 'Use route up.\n' > "$home/decision.txt"
  run_captain "$home" answer "$hold" --decision-file "$home/decision.txt" >/dev/null \
    || fail "could not answer the call before pruning"
  tasks_in "$home" prune --state "done" --keep 0 >/dev/null \
    || fail "could not prune the answered call into the configured archive"
  assert_grep "- [x] $hold -" "$archive_dir/done-archive.md" \
    "the answered call did not reach the configured archive"

  # Readable: the retirement guard refuses to re-mint the answered identity.
  if run_captain "$home" hold "$hold" \
    --title "Re-minted call" --reason "should refuse" --repo sample \
    > "$home/dir-retire.out" 2> "$home/dir-retire.err"; then
    fail "hold re-created an identity already durably resolved in the archive"
  fi
  assert_grep "already durably resolved" "$home/dir-retire.err" \
    "the retirement guard did not name the durable archived resolution"

  chmod 000 "$archive_dir"
  set +e
  run_captain "$home" hold "$hold" \
    --title "Re-minted call" --reason "should refuse" --repo sample \
    > "$home/dir-unreachable.out" 2> "$home/dir-unreachable.err"
  rc=$?
  set -e
  chmod 700 "$archive_dir"
  [ "$rc" -ne 0 ] \
    || fail "hold re-minted an already-answered captain call while the archive directory was unreachable"
  assert_grep "cannot read the configured tasks-axi archive" "$home/dir-unreachable.err" \
    "an archive behind an unsearchable directory was not reported as a read failure"

  chmod 000 "$archive_dir"
  set +e
  run_captain "$home" verify "$origin" > "$home/dir-verify.out" 2> "$home/dir-verify.err"
  rc=$?
  set -e
  chmod 700 "$archive_dir"
  [ "$rc" -ne 0 ] \
    || fail "verify passed while the configured archive could not be reached"
  assert_no_grep "absent from the live backlog and configured archive" "$home/dir-verify.err" \
    "an unreachable archive was reported as a missing identity"
  pass "an archive unreachable through its parent directory fails loudly instead of counting zero"
}

# tasks-axi resolves its backlog from TASKS_AXI_FILE first, then the project
# .tasks.toml, then ~/.tasks-axi/config.toml. A gate that resolves from the
# project file alone proves a file the backend never read: the backend answers
# NOT_FOUND for every id against the backlog it actually opened, the gate finds
# its own unrelated file healthy, accepts that as proof of absence, and lets a
# stale archived cycle verify a genuinely open captain call.
test_backend_path_precedence_governs_absence_proof() {
  local home origin hold rc
  home=$(make_home backend-path-precedence)
  origin=sample-precedence-review
  hold=sample-precedence-call
  mkdir -p "$home/data/$origin" "$home/fakehome/.tasks-axi" "$home/elsewhere"
  tasks_in "$home" add "$origin" "Review backend path precedence" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create the precedence origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Precedence review\n' > "$home/data/$origin/report.md"
  run_captain "$home" hold "$hold" \
    --title "Choose precedence route" --reason "captain route pending" --repo sample >/dev/null \
    || fail "could not create the hold"
  run_captain "$home" complete "$origin" "$hold" >/dev/null \
    || fail "could not record the call inventory"
  printf 'Use route south.\n' > "$home/decision.txt"
  run_captain "$home" answer "$hold" --decision-file "$home/decision.txt" >/dev/null \
    || fail "could not answer the call before pruning"
  tasks_in "$home" prune --state "done" --keep 0 >/dev/null \
    || fail "could not prune the answered call into the archive"
  assert_grep "- [x] $hold -" "$home/data/done-archive.md" \
    "the answered call did not reach the configured archive"

  # The identity is genuinely OPEN again while the archive still carries the
  # stale resolved cycle from the earlier round.
  tasks_in "$home" add "$hold" "Reopened precedence call" --kind ship --repo sample >/dev/null \
    || fail "could not re-open the identity"
  tasks_in "$home" hold "$hold" --reason "captain route still pending" --kind captain >/dev/null \
    || fail "could not re-activate the captain hold"
  run_captain "$home" verify "$origin" >/dev/null \
    || fail "a satisfied live hold did not verify under a healthy config"

  # TASKS_AXI_FILE outranks both config files, so the backend reads that file and
  # answers NOT_FOUND for every id when it does not exist. Proving the project
  # backlog readable instead would accept that as "pruned" and let the stale
  # archived cycle verify the still-open call.
  set +e
  TASKS_AXI_FILE="$home/elsewhere/absent-backlog.md" \
    run_captain "$home" verify "$origin" > "$home/env-file.out" 2> "$home/env-file.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] \
    || fail "verification passed on an open captain call because TASKS_AXI_FILE named a backlog that does not exist"
  assert_no_grep "^verified:" "$home/env-file.out" \
    "an open captain call was reported verified from a backlog the backend could not read"
  assert_grep "elsewhere/absent-backlog.md" "$home/env-file.err" \
    "the failure did not name the backlog path TASKS_AXI_FILE resolved"
  assert_grep "- [ ] $hold -" "$home/data/backlog.md" \
    "the open captain call left the live backlog during the precedence check"

  # The inverse, so the fix cannot be satisfied by refusing every override: an
  # override naming a real backlog is authoritative, and an identity genuinely
  # absent from THAT file still resolves from the archive.
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/elsewhere/backlog.md"
  TASKS_AXI_FILE="$home/elsewhere/backlog.md" \
    run_captain "$home" verify "$origin" > "$home/env-real.out" 2> "$home/env-real.err" \
    || fail "a readable TASKS_AXI_FILE backlog blocked archive resolution: $(cat "$home/env-real.err")"

  # The same hole through the home-level config the backend consults when the
  # project config sets no path. HOME is redirected into the fixture so this
  # never reads the developer's real ~/.tasks-axi/config.toml.
  cat > "$home/.tasks.toml" <<'TOMLEOF'
backend = "markdown"

[markdown]
done_keep = 10
TOMLEOF
  cat > "$home/fakehome/.tasks-axi/config.toml" <<'TOMLEOF'
[markdown]
path = "data/missing-backlog.md"
TOMLEOF
  set +e
  HOME="$home/fakehome" \
    run_captain "$home" verify "$origin" > "$home/home-toml.out" 2> "$home/home-toml.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] \
    || fail "verification passed on an open captain call because the home-level tasks-axi path was ignored"
  assert_no_grep "^verified:" "$home/home-toml.out" \
    "an open captain call was reported verified from a home-config backlog that does not exist"
  assert_grep "data/missing-backlog.md" "$home/home-toml.err" \
    "the failure did not name the backlog path the home-level config resolved"
  pass "absence is proved only against the backlog tasks-axi itself resolved"
}

# The archive side of the same precedence: tasks-axi prunes into the archive its
# own config resolution names, so a gate deriving a different path counts zero
# archived records and re-mints an identity the retirement guard must refuse
# permanently.
test_backend_archive_precedence_governs_retirement() {
  local home origin hold
  home=$(make_home backend-archive-precedence)
  origin=sample-archive-precedence-review
  hold=sample-archive-precedence-call
  mkdir -p "$home/data/$origin" "$home/fakehome/.tasks-axi"
  cat > "$home/.tasks.toml" <<'TOMLEOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
done_keep = 10
TOMLEOF
  cat > "$home/fakehome/.tasks-axi/config.toml" <<'TOMLEOF'
[markdown]
archive = "data/calls-archive.md"
TOMLEOF
  HOME="$home/fakehome" tasks_in "$home" add "$origin" "Review archive precedence" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create the archive-precedence origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Archive precedence review\n' > "$home/data/$origin/report.md"
  HOME="$home/fakehome" run_captain "$home" hold "$hold" \
    --title "Choose archive-precedence route" --reason "captain route pending" --repo sample >/dev/null \
    || fail "could not create the hold"
  HOME="$home/fakehome" run_captain "$home" complete "$origin" "$hold" >/dev/null \
    || fail "could not record the call inventory"
  printf 'Use route north.\n' > "$home/decision.txt"
  HOME="$home/fakehome" run_captain "$home" answer "$hold" --decision-file "$home/decision.txt" >/dev/null \
    || fail "could not answer the call before pruning"
  HOME="$home/fakehome" tasks_in "$home" prune --state "done" --keep 0 >/dev/null \
    || fail "could not prune the answered call into the home-configured archive"
  assert_grep "- [x] $hold -" "$home/data/calls-archive.md" \
    "tasks-axi did not archive into the path its home-level config names"
  assert_absent "$home/data/done-archive.md" \
    "tasks-axi archived to the derived default rather than the home-configured archive"

  if HOME="$home/fakehome" run_captain "$home" hold "$hold" \
    --title "Re-minted call" --reason "should refuse" --repo sample \
    > "$home/archive-remint.out" 2> "$home/archive-remint.err"; then
    fail "hold re-minted an identity durably resolved in the home-configured archive"
  fi
  assert_grep "already durably resolved" "$home/archive-remint.err" \
    "the retirement guard did not read the archive tasks-axi actually pruned into"
  HOME="$home/fakehome" run_captain "$home" verify "$origin" \
    > "$home/archive-verify.out" 2> "$home/archive-verify.err" \
    || fail "verify could not resolve the archived call from the home-configured archive: $(cat "$home/archive-verify.err")"
  pass "the retirement guard reads the archive tasks-axi itself resolved"
}

# A read failure must never be reported as a nonexistent task: answers would
# otherwise drop the captain's recorded words under a reason that is wrong.
test_answers_reports_read_failure_not_absence() {
  local home origin hold rc
  home=$(make_home answers-read-failure)
  origin=sample-answers-read-review
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Review answers read failure" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create the answers origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Answers read failure review\n' > "$home/data/$origin/report.md"
  hold=sample-answers-read-call
  run_captain "$home" hold "$hold" \
    --title "Choose answers route" --reason "captain route pending" --repo sample >/dev/null \
    || fail "could not create the hold"
  run_captain "$home" complete "$origin" "$hold" >/dev/null \
    || fail "could not record the call inventory"
  printf '%s\tUse north\tNorth\n' "$hold" > "$home/rows.tsv"

  chmod 000 "$home/data/backlog.md"
  set +e
  run_captain "$home" answers "$origin" --source chat < "$home/rows.tsv" \
    > "$home/answers.out" 2> "$home/answers.err"
  rc=$?
  set -e
  chmod 600 "$home/data/backlog.md"
  [ "$rc" -eq 0 ] \
    && fail "answers reported success while the live backlog could not be read"
  assert_grep "cannot read the live backlog" "$home/answers.out" \
    "answers did not surface the real read-failure reason"
  assert_no_grep "no captain-held task with that id" "$home/answers.out" \
    "answers reported a read failure as a nonexistent task, dropping the captain's answer"
  pass "answers reports an unreadable backlog as a read failure rather than a missing task"
}

# tasks-axi locates its home-level config through node's os.homedir(), which is
# NOT "$HOME or nothing": an unset HOME falls back to this user's passwd entry,
# and an EMPTY HOME makes join("", ".tasks-axi", "config.toml") the RELATIVE path
# the backend then reads from the directory it runs in - the home itself. A gate
# that skips the file in either case proves a config the backend never read, the
# same fail-open the path-precedence guards close: the backend answers NOT_FOUND
# for every id against the backlog its home config named, the gate finds its own
# derived backlog healthy, and a stale archived cycle verifies an open call.
test_home_config_resolution_matches_backend() {
  local home origin hold rc
  home=$(make_home home-config-resolution)
  origin=sample-home-config-review
  hold=sample-home-config-call
  mkdir -p "$home/data/$origin" "$home/.tasks-axi" "$home/emptyhome"
  tasks_in "$home" add "$origin" "Review home config resolution" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create the home-config origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Home config review\n' > "$home/data/$origin/report.md"
  run_captain "$home" hold "$hold" \
    --title "Choose home-config route" --reason "captain route pending" --repo sample >/dev/null \
    || fail "could not create the hold"
  run_captain "$home" complete "$origin" "$hold" >/dev/null \
    || fail "could not record the call inventory"
  printf 'Use route east.\n' > "$home/decision.txt"
  run_captain "$home" answer "$hold" --decision-file "$home/decision.txt" >/dev/null \
    || fail "could not answer the call before pruning"
  tasks_in "$home" prune --state "done" --keep 0 >/dev/null \
    || fail "could not prune the answered call into the archive"
  assert_grep "- [x] $hold -" "$home/data/done-archive.md" \
    "the answered call did not reach the configured archive"

  # The identity is genuinely OPEN again while the archive keeps the stale
  # resolved cycle from the earlier round.
  tasks_in "$home" add "$hold" "Reopened home-config call" --kind ship --repo sample >/dev/null \
    || fail "could not re-open the identity"
  tasks_in "$home" hold "$hold" --reason "captain route still pending" --kind captain >/dev/null \
    || fail "could not re-activate the captain hold"

  # Only the home-level config names a backlog path, so it alone decides which
  # file the backend reads.
  cat > "$home/.tasks.toml" <<'TOMLEOF'
backend = "markdown"

[markdown]
done_keep = 10
TOMLEOF
  cat > "$home/.tasks-axi/config.toml" <<'TOMLEOF'
[markdown]
path = "data/missing-home-backlog.md"
TOMLEOF

  # An EMPTY HOME: the backend reads the relative .tasks-axi/config.toml from the
  # home it runs in, so it resolves a backlog that does not exist and reports
  # NOT_FOUND for the still-open call.
  HOME='' tasks_in "$home" show "$hold" --full > "$home/empty-home-show.out" 2>&1 \
    && fail "the backend did not read the relative home config under an empty HOME"
  assert_grep "code: NOT_FOUND" "$home/empty-home-show.out" \
    "the backend did not resolve the empty-HOME config to a backlog without the call"
  set +e
  HOME='' run_captain "$home" verify "$origin" > "$home/empty-home.out" 2> "$home/empty-home.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] \
    || fail "verification passed on an open captain call because the empty-HOME config was skipped"
  assert_no_grep "^verified:" "$home/empty-home.out" \
    "an open captain call was reported verified from a config the backend never read"
  assert_grep "data/missing-home-backlog.md" "$home/empty-home.err" \
    "the failure did not name the backlog path the empty-HOME config resolved"
  assert_grep "- [ ] $hold -" "$home/data/backlog.md" \
    "the open captain call left the live backlog during the empty-HOME check"

  # An UNSET HOME resolves against this user's passwd entry instead, so the very
  # same relative file must NOT be read. The gate must reach whatever conclusion
  # the backend itself reaches from that resolution, so the backend is asked
  # first and its answer decides what verify must do - which keeps this leg
  # correct on a machine that does happen to carry a real ~/.tasks-axi config,
  # without ever writing to the developer's home.
  (unset HOME; tasks_in "$home" show "$hold" --full) > "$home/unset-home-show.out" 2>&1
  set +e
  (unset HOME; run_captain "$home" verify "$origin") \
    > "$home/unset-home.out" 2> "$home/unset-home.err"
  rc=$?
  set -e
  if grep -F -- "hold_kind: captain" "$home/unset-home-show.out" >/dev/null; then
    [ "$rc" -eq 0 ] \
      || fail "verify refused a call the backend reads as open under an unset HOME: $(cat "$home/unset-home.err")"
    assert_grep "verified:" "$home/unset-home.out" \
      "a satisfied live hold did not verify under an unset HOME"
  else
    [ "$rc" -ne 0 ] \
      || fail "verify passed on an open captain call the backend could not read under an unset HOME"
  fi
  assert_no_grep "data/missing-home-backlog.md" "$home/unset-home.err" \
    "an unset HOME read the fixture's relative .tasks-axi config the backend resolved elsewhere"

  # A RELATIVE HOME is the same fail-open as the empty one: node's join keeps it
  # relative, the backend resolves it against the FM_HOME it runs in, and this
  # gate must not resolve it against its own caller's cwd instead. Running from a
  # cwd that is NOT the home is what separates the two resolutions, so the check
  # below would pass vacuously from inside $home.
  mkdir -p "$home/relhome/.tasks-axi"
  cat > "$home/relhome/.tasks-axi/config.toml" <<'TOMLEOF'
[markdown]
path = "data/missing-rel-backlog.md"
TOMLEOF
  HOME=relhome tasks_in "$home" show "$hold" --full > "$home/rel-home-show.out" 2>&1 \
    && fail "the backend did not read the relative home config under a relative HOME"
  assert_grep "code: NOT_FOUND" "$home/rel-home-show.out" \
    "the backend did not resolve the relative-HOME config to a backlog without the call"
  set +e
  (cd / && PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" HOME=relhome \
    "$ROOT/bin/fm-captain-hold.sh" verify "$origin") \
    > "$home/rel-home.out" 2> "$home/rel-home.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] \
    || fail "verification passed on an open captain call because a relative HOME resolved against the caller's cwd"
  assert_no_grep "verified:" "$home/rel-home.out" \
    "an open captain call was reported verified from a config the backend never read"
  assert_grep "data/missing-rel-backlog.md" "$home/rel-home.err" \
    "the failure did not name the backlog path the relative-HOME config resolved"
  assert_grep "- [ ] $hold -" "$home/data/backlog.md" \
    "the open captain call left the live backlog during the relative-HOME check"

  # And a HOME pointing at a disposable directory with no config of its own is
  # the ordinary case: neither file names a path, so the derived default governs.
  HOME="$home/emptyhome" run_captain "$home" verify "$origin" \
    > "$home/set-home.out" 2> "$home/set-home.err" \
    || fail "a satisfied live hold did not verify under a config-free HOME: $(cat "$home/set-home.err")"
  pass "the home-level tasks-axi config is resolved exactly as the backend resolves it"
}

# tasks-axi treats [markdown] archive as optional and derives its own default
# from the resolved backlog path - done-archive.md beside that file, not a fixed
# data/ location. The gate must derive the same path, and must never silently
# accept a malformed key, which would disable the archive guards entirely.
test_archive_config_absent_defaults_and_malformed_fails() {
  local home id hold
  home=$(make_home malformed-archive-config)
  id=sample-malformed-config-review
  hold=sample-malformed-config-call
  mkdir -p "$home/data/$id" "$home/notes"
  cat > "$home/.tasks.toml" <<'TOMLEOF'
backend = "markdown"

[markdown]
path = "notes/backlog.md"
archive = "notes/done-archive.md"
done_keep = 10
TOMLEOF
  tasks_in "$home" add "$id" "Review malformed archive config" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create the malformed-config origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Malformed archive config review\n' > "$home/data/$id/report.md"
  run_captain "$home" hold "$hold" \
    --title "Choose malformed-config route" --reason "captain route pending" --repo sample >/dev/null \
    || fail "could not create the live hold for the malformed-config regression"
  run_captain "$home" complete "$id" "$hold" >/dev/null \
    || fail "could not record the malformed-config inventory"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "a live captain hold did not verify under a valid archive config"

  # The absent-key fallback is only exercised once the record actually leaves the
  # live backlog, so answer and prune before dropping the key: verify now passes
  # only if the fallback resolves to the same file tasks-axi archived to.
  printf 'No follow-up work is needed.\n' > "$home/config-decision.txt"
  run_captain "$home" answer "$hold" --decision-file "$home/config-decision.txt" >/dev/null \
    || fail "could not close the call before archive-config pruning"
  tasks_in "$home" prune --state "done" --keep 0 >/dev/null \
    || fail "could not prune the closed call to the default archive"
  assert_no_grep "- [x] $hold -" "$home/notes/backlog.md" \
    "the closed call remained in the live backlog after pruning"
  assert_grep "- [x] $hold -" "$home/notes/done-archive.md" \
    "tasks-axi did not archive the closed call beside its configured backlog"
  assert_absent "$home/data/done-archive.md" \
    "tasks-axi archived to a fixed data/ path rather than beside its backlog"

  grep -v '^archive = ' "$home/.tasks.toml" > "$home/.tasks.toml.tmp"
  mv "$home/.tasks.toml.tmp" "$home/.tasks.toml"
  run_captain "$home" verify "$id" > "$home/absent-config.out" 2> "$home/absent-config.err" \
    || fail "an absent optional archive key blocked verify on an archived call: $(cat "$home/absent-config.err")"

  printf 'archive = notes/done-archive.md\n' >> "$home/.tasks.toml"
  if run_captain "$home" verify "$id" > "$home/malformed-config.out" 2> "$home/malformed-config.err"; then
    fail "verify passed with a malformed markdown.archive config, silently disabling the archive guards"
  fi
  assert_grep "markdown.archive must be one unescaped quoted path" "$home/malformed-config.err" \
    "a malformed archive config must fail verify with the config error"
  pass "an absent archive key derives the backend default while a malformed one fails verify"
}

# A home with no .tasks.toml at all is one tasks-axi reads as every key
# defaulted, so the gate must resolve the same defaults rather than refuse.
test_absent_tasks_toml_falls_back_to_backend_defaults() {
  local home id hold
  home=$(make_home absent-tasks-toml)
  id=sample-absent-config-review
  hold=sample-absent-config-call
  rm -f "$home/.tasks.toml"
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review absent tasks config" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create the absent-config origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Absent tasks config review\n' > "$home/data/$id/report.md"
  run_captain "$home" hold "$hold" \
    --title "Choose absent-config route" --reason "captain route pending" --repo sample >/dev/null \
    || fail "an absent .tasks.toml blocked hold creation"
  run_captain "$home" complete "$id" "$hold" >/dev/null \
    || fail "could not record the inventory without a .tasks.toml"
  run_captain "$home" verify "$id" > "$home/live-absent.out" 2> "$home/live-absent.err" \
    || fail "an absent .tasks.toml blocked verify on a live active hold: $(cat "$home/live-absent.err")"

  printf 'No follow-up work is needed.\n' > "$home/absent-config-decision.txt"
  run_captain "$home" answer "$hold" --decision-file "$home/absent-config-decision.txt" >/dev/null \
    || fail "could not close the call without a .tasks.toml"
  tasks_in "$home" prune --state "done" --keep 0 >/dev/null \
    || fail "could not prune the closed call without a .tasks.toml"
  assert_grep "- [x] $hold -" "$home/data/done-archive.md" \
    "tasks-axi did not archive beside the backlog it resolved without a config"
  run_captain "$home" verify "$id" > "$home/archived-absent.out" 2> "$home/archived-absent.err" \
    || fail "an absent .tasks.toml blocked verify on an archived call: $(cat "$home/archived-absent.err")"
  pass "an absent .tasks.toml falls back to the backend's own resolved defaults"
}

# The config reader must accept exactly what the backend accepts, or a home the
# backend archives correctly would fail this gate.
test_archive_config_matches_backend_toml_spellings() {
  local home origin archive hold
  home=$(make_home archive-config-spellings)
  origin=sample-config-spelling-review
  hold=sample-config-spelling-call
  archive="$home/data/calls/spelled-archive.md"
  mkdir -p "$home/data/$origin" "$(dirname "$archive")"
  cat > "$home/.tasks.toml" <<'TOMLEOF'
backend = "markdown"

[ markdown ]
path = "data/backlog.md"
archive = "data/calls/overridden-archive.md"
archive = "data/calls/spelled-archive.md" # captain calls stay out of the main archive
done_keep = 10
TOMLEOF
  tasks_in "$home" add "$origin" "Review archive config spellings" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create the config-spelling origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Config spelling review\n' > "$home/data/$origin/report.md"
  run_captain "$home" hold "$hold" \
    --title "Choose config-spelling route" --reason "captain route pending" --repo sample >/dev/null \
    || fail "an inner-spaced section or trailing comment blocked hold creation"
  run_captain "$home" complete "$origin" "$hold" >/dev/null \
    || fail "could not record the config-spelling inventory"
  printf 'No follow-up work is needed.\n' > "$home/spelling-config-decision.txt"
  run_captain "$home" answer "$hold" --decision-file "$home/spelling-config-decision.txt" >/dev/null \
    || fail "could not close the config-spelling call"
  tasks_in "$home" prune --state "done" --keep 0 >/dev/null \
    || fail "could not prune the config-spelling call"
  assert_grep "- [x] $hold -" "$archive" \
    "tasks-axi did not honor the inner-spaced, trailing-comment, last-wins archive path"
  assert_absent "$home/data/calls/overridden-archive.md" \
    "tasks-axi did not take the last assignment of a repeated archive key"
  assert_absent "$home/data/done-archive.md" \
    "the configured archive path was ignored in favor of the default"
  run_captain "$home" verify "$origin" > "$home/spelled-config.out" 2> "$home/spelled-config.err" \
    || fail "a backend-honored archive config spelling blocked verify: $(cat "$home/spelled-config.err")"
  pass "archive config spellings the backend honors also resolve for verify"
}

# tasks-axi owns how a close is spelled, and a captain decision is arbitrary
# prose. Neither may change the archived verdict: every close spelling still
# verifies, and prose that mimics every structured marker satisfies nothing.
test_prose_heavy_and_out_of_band_archived_closes_verify() {
  local home origin archive prose merged reported unheld unheld_line
  home=$(make_home archived-close-spellings)
  origin=sample-close-spelling-review
  archive="$home/data/done-archive.md"
  prose=sample-prose-call
  merged=sample-merged-call
  reported=sample-reported-call
  unheld=sample-unheld-call
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Review out-of-band close spellings" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create the close-spelling origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Close spelling review\n' > "$home/data/$origin/report.md"
  run_captain "$home" hold "$prose" \
    --title "Choose prose route" --reason "captain prose route pending" --repo sample >/dev/null \
    || fail "could not create the prose call"
  run_captain "$home" hold "$merged" \
    --title "Choose merged route" --reason "captain merged route pending" --repo sample >/dev/null \
    || fail "could not create the pr-closed call"
  run_captain "$home" hold "$reported" \
    --title "Choose reported route" --reason "captain reported route pending" --repo sample >/dev/null \
    || fail "could not create the report-closed call"
  run_captain "$home" hold "$unheld" \
    --title "Choose unheld route" --reason "captain unheld route pending" --repo sample >/dev/null \
    || fail "could not create the unheld call"
  run_captain "$home" complete "$origin" "$prose" "$merged" "$reported" "$unheld" >/dev/null \
    || fail "could not record the close-spelling inventory"

  # A decision about this very lifecycle: every structured marker also appears as
  # ordinary captain prose, so a whole-record field check would reject it.
  cat > "$home/prose-decision.txt" <<'EOF'
The archived record starts with the line
Resolution recorded by fm-captain-hold.
followed by
Decision digest: 0000000000000000000000000000000000000000000000000000000000000000
and
Resolution mode: answered
and then
Captain decision:
Keep that grammar and take the northern route.
EOF
  run_captain "$home" answer "$prose" --decision-file "$home/prose-decision.txt" >/dev/null \
    || fail "could not answer the prose-heavy call before pruning"

  printf 'The captain answered this out of band.\n' > "$home/spelling-decision.txt"
  tasks_in "$home" "done" "$merged" --pr https://github.com/sample/sample/pull/7 >/dev/null \
    || fail "could not close the call with a pr link"
  run_captain "$home" answer "$merged" --decision-file "$home/spelling-decision.txt" >/dev/null \
    || fail "could not record the answer on the pr-closed call"

  mkdir -p "$home/data/$reported"
  printf '# Reported route\n' > "$home/data/$reported/report.md"
  tasks_in "$home" "done" "$reported" --report "data/$reported/report.md" >/dev/null \
    || fail "could not close the call with a report link"
  run_captain "$home" answer "$reported" --decision-file "$home/spelling-decision.txt" >/dev/null \
    || fail "could not record the answer on the report-closed call"

  run_captain "$home" answer "$unheld" --decision-file "$home/spelling-decision.txt" >/dev/null \
    || fail "could not answer the call before clearing its hold markers"
  tasks_in "$home" unhold "$unheld" >/dev/null \
    || fail "could not clear the hold markers on the closed call"

  run_captain "$home" verify "$origin" >/dev/null \
    || fail "out-of-band closed calls did not verify while still in the live backlog"

  tasks_in "$home" prune --state "done" --keep 0 >/dev/null \
    || fail "could not prune the out-of-band closed calls to the default archive"
  assert_grep "- [x] $merged -" "$archive" "the pr-closed call did not reach the archive"
  assert_grep "(merged " "$archive" "tasks-axi did not render the pr close as merged"
  assert_grep "(reported " "$archive" "tasks-axi did not render the report close as reported"
  unheld_line=$(grep -F -- "- [x] $unheld -" "$archive") \
    || fail "the unheld closed call did not reach the archive"
  case "$unheld_line" in
    *'hold-kind'*) fail "unhold did not clear the archived hold markers: $unheld_line" ;;
  esac

  run_captain "$home" verify "$origin" > "$home/spelling-verify.out" 2> "$home/spelling-verify.err" \
    || fail "archived out-of-band or prose-heavy closes failed verification: $(cat "$home/spelling-verify.err")"
  pass "archived pr, report, unheld, and prose-heavy closes keep verifying after pruning"
}

# The retirement boundary has two sides, and getting either wrong is costly: a
# genuinely answered-and-pruned identity must never be reopened, while one pruned
# without a recorded answer must stay recoverable, because no command can rewrite
# an archived body.
test_hold_retires_only_durably_resolved_archived_ids() {
  local home origin archive resolved stranded
  home=$(make_home archived-hold-retirement)
  origin=sample-retirement-review
  archive="$home/data/done-archive.md"
  resolved=sample-resolved-call
  stranded=sample-stranded-call
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Review archived hold retirement" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create the retirement origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Retirement review\n' > "$home/data/$origin/report.md"
  run_captain "$home" hold "$resolved" \
    --title "Choose resolved route" --reason "captain resolved route pending" --repo sample >/dev/null \
    || fail "could not create the resolved call"
  run_captain "$home" hold "$stranded" \
    --title "Choose stranded route" --reason "captain stranded route pending" --repo sample >/dev/null \
    || fail "could not create the stranded call"
  run_captain "$home" complete "$origin" "$resolved" "$stranded" >/dev/null \
    || fail "could not record the retirement inventory"

  printf 'No follow-up work is needed.\n' > "$home/retirement-decision.txt"
  run_captain "$home" answer "$resolved" --decision-file "$home/retirement-decision.txt" >/dev/null \
    || fail "could not answer the resolved call"
  tasks_in "$home" "done" "$stranded" >/dev/null \
    || fail "could not reproduce the out-of-band close"
  tasks_in "$home" prune --state "done" --keep 0 >/dev/null \
    || fail "could not prune both closed calls to the archive"
  assert_grep "- [x] $resolved -" "$archive" "the answered call did not reach the archive"
  assert_grep "- [x] $stranded -" "$archive" "the out-of-band close did not reach the archive"

  if run_captain "$home" verify "$origin" > "$home/stranded-verify.out" 2> "$home/stranded-verify.err"; then
    fail "verification accepted an archived close that recorded no captain answer"
  fi
  assert_grep "no unique resolution marker" "$home/stranded-verify.err" \
    "the archived unanswered close did not fail on its missing resolution record"
  if run_captain "$home" answer "$stranded" --decision-file "$home/retirement-decision.txt" \
    > "$home/stranded-answer.out" 2> "$home/stranded-answer.err"; then
    fail "answer rewrote a record that has already left the live backlog"
  fi
  assert_grep "absent from" "$home/stranded-answer.err" \
    "answer did not report the archived record as absent from the live backlog"

  if run_captain "$home" hold "$resolved" \
    --title "Choose resolved route" --reason "captain resolved route again" --repo sample \
    > "$home/retired-hold.out" 2> "$home/retired-hold.err"; then
    fail "hold reopened an identity whose archived record is durably resolved"
  fi
  assert_grep "already durably resolved in the configured tasks-axi archive" "$home/retired-hold.err" \
    "a resolved-and-pruned identity was not refused as retired"

  run_captain "$home" hold "$stranded" \
    --title "Choose stranded route" --reason "captain stranded route pending" --repo sample >/dev/null \
    || fail "an archived record that fails verify could not be re-held for recovery"
  run_captain "$home" answer "$stranded" --decision-file "$home/retirement-decision.txt" >/dev/null \
    || fail "could not record the captain answer on the recovered hold"
  run_captain "$home" verify "$origin" > "$home/recovered-verify.out" 2> "$home/recovered-verify.err" \
    || fail "the recovered call still failed verification: $(cat "$home/recovered-verify.err")"

  # Ordinary retention pruning then archives the recovered cycle beside the
  # unresolved one, so the archive legitimately holds two records of one
  # identity. The resolved cycle must keep attesting the answer.
  tasks_in "$home" prune --state "done" --keep 0 >/dev/null \
    || fail "could not prune the recovered hold to the archive"
  [ "$(grep -c "^- \[x\] $stranded - " "$archive")" = 2 ] \
    || fail "expected two archived cycles of the recovered identity, got $(grep -c "^- \[x\] $stranded - " "$archive")"
  run_captain "$home" verify "$origin" > "$home/recovered-pruned.out" 2> "$home/recovered-pruned.err" \
    || fail "a second archived cycle of one identity blocked verification: $(cat "$home/recovered-pruned.err")"
  if run_captain "$home" hold "$stranded" \
    --title "Choose stranded route" --reason "captain stranded route pending" --repo sample \
    > "$home/recovered-rehold.out" 2> "$home/recovered-rehold.err"; then
    fail "hold reopened an identity whose archive now carries a durably resolved cycle"
  fi
  assert_grep "already durably resolved in the configured tasks-axi archive" "$home/recovered-rehold.err" \
    "a recovered-and-pruned identity was not retired by the same predicate verify accepts"
  run_teardown "$home" "$origin" >/dev/null 2> "$home/retirement-teardown.err" \
    || fail "teardown still refused after the stranded call was recovered: $(cat "$home/retirement-teardown.err")"
  pass "hold retires only durably resolved archived ids and leaves the rest recoverable"
}

# The originating work item is itself the captain call, which is what the policy
# prefers ("hold the work item the question gates"). Cleanup of that finished
# work must never be the act that closes the captain's own row: the deliverable
# is recorded on the still-held row, the call keeps reading as open on the
# board, and only a recorded answer closes it. An ordinary finished task in the
# same home must still close exactly as before, and discard authority covers
# unlanded work, never the captain's question.
test_teardown_never_closes_a_captain_held_task() {
  local home id plain forced json show
  home=$(make_home teardown-held)
  id=sample-attach-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample attachment evidence" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the investigation fixture"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample attachment evidence\n\nThe captain must choose inline or by-reference attachments.\n' \
    > "$home/data/$id/report.md"
  run_captain "$home" hold "$id" \
    --reason "captain must choose inline or by-reference attachments" >/dev/null \
    || fail "could not hold the originating work item for the captain"
  run_captain "$home" complete "$id" "$id" >/dev/null \
    || fail "completion gate failed with the origin as its own captain call"

  run_teardown "$home" "$id" > "$home/teardown.out" 2> "$home/teardown.err" \
    || fail "cleanup of a captain-held investigation failed: $(cat "$home/teardown.err")"
  show=$(tasks_in "$home" show "$id" --full) || fail "the captain-held row is gone after cleanup"
  assert_not_contains "$show" "state: done" \
    "cleanup closed the captain call with no recorded answer"
  assert_contains "$show" "state: queued" "the finished work's row still reads as worked on"
  assert_contains "$show" "held: yes" "cleanup lifted the captain hold"
  assert_contains "$show" "hold_kind: captain" "cleanup dropped the captain hold"
  assert_contains "$show" "Deliverable of the finished work: report data/$id/report.md" \
    "the deliverable was not recorded on the still-open row"
  assert_absent "$home/state/$id.meta" "cleanup did not release the finished worker record"
  assert_absent "$home/state/$id.backlog-close" \
    "successful cleanup left its pending transition record behind"
  assert_grep "still held for the captain" "$home/teardown.out" \
    "cleanup did not say the row stays open for the captain"
  json=$(run_bearings "$home") || fail "Bearings failed after cleanup of a captain-held task"
  printf '%s' "$json" | jq -e --arg id "$id" '
    (.decisions_open | any(.id == $id and .verb == "captain-hold"))
  ' >/dev/null || fail "the board no longer surfaces the captain call: $json"

  # The ordinary path is untouched: a finished task with no captain call closes.
  plain=sample-plain-review
  mkdir -p "$home/data/$plain"
  tasks_in "$home" add "$plain" "Investigate the sample cache" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the ordinary fixture"
  write_origin_meta "$home" "$plain"
  printf 'done: report complete\n' > "$home/state/$plain.status"
  printf '# Sample cache\n\nNothing waits on the captain.\n' > "$home/data/$plain/report.md"
  run_captain "$home" complete "$plain" --none >/dev/null \
    || fail "completion gate failed for the ordinary investigation"
  run_teardown "$home" "$plain" > "$home/plain.out" 2> "$home/plain.err" \
    || fail "ordinary cleanup failed: $(cat "$home/plain.err")"
  show=$(tasks_in "$home" show "$plain" --full) || fail "the ordinary row vanished"
  assert_contains "$show" "state: done" "ordinary cleanup no longer closes its backlog item"
  assert_contains "$show" "data/$plain/report.md" "ordinary cleanup lost the report link"
  assert_absent "$home/state/$plain.backlog-close" "ordinary cleanup left its pending close behind"

  # Discard authority covers unlanded work, never the captain's question.
  forced=sample-forced-review
  mkdir -p "$home/data/$forced"
  tasks_in "$home" add "$forced" "Investigate the sample forced path" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the forced fixture"
  write_origin_meta "$home" "$forced"
  printf 'done: report complete\n' > "$home/state/$forced.status"
  printf '# Sample forced path\n\nOne captain choice remains.\n' > "$home/data/$forced/report.md"
  run_captain "$home" hold "$forced" --reason "captain must choose the sample forced path" >/dev/null \
    || fail "could not hold the forced fixture for the captain"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$forced" --force \
    > "$home/forced.out" 2> "$home/forced.err" \
    || fail "forced cleanup failed: $(cat "$home/forced.err")"
  show=$(tasks_in "$home" show "$forced" --full) || fail "forced cleanup erased the captain-held row"
  assert_not_contains "$show" "state: done" \
    "discard authority closed a captain call with no recorded answer"
  assert_contains "$show" "state: queued" "forced cleanup left the captain call reading as worked on"
  assert_contains "$show" "hold_kind: captain" "forced cleanup dropped the captain hold"

  # Only a recorded answer closes the captain call, and the deliverable survives it.
  printf 'Ship attachments by reference.\n' > "$home/answer.txt"
  run_captain "$home" answer "$id" --decision-file "$home/answer.txt" >/dev/null \
    || fail "the surviving captain call could not be answered"
  show=$(tasks_in "$home" show "$id" --full) || fail "the answered row is gone"
  assert_contains "$show" "state: done" "the recorded answer did not close the captain call"
  assert_contains "$show" "Ship attachments by reference." "the captain's words were not recorded"
  assert_contains "$show" "Deliverable of the finished work: report data/$id/report.md" \
    "the answer lost the recorded deliverable"
  pass "cleanup leaves a captain-held work item open with its deliverable, and only an answer closes it"
}

# Retention happens after destructive cleanup, through the same pending record
# an ordinary close stages first. A cleanup that fails part-way therefore leaves
# the row exactly as it was, and the next session start finishes the retention
# instead of closing the captain's question.
test_interrupted_cleanup_keeps_the_captain_call_recoverable() {
  local home id wt show rc bootstrap
  home=$(make_home teardown-held-interrupted)
  id=sample-held-cleanup-failure
  wt="$home/projects/$id"
  mkdir -p "$home/data/$id" "$wt" "$home/projects/sample"
  tasks_in "$home" add "$id" "Investigate failed sample cleanup" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the cleanup-failure fixture"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$wt" "project=$home/projects/sample" \
    "harness=codex" "kind=scout" "mode=scout" "spawn_gen=fixture-$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Failed cleanup\n\nThe captain call remains open.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold "$id" --reason "captain must choose after cleanup retry" >/dev/null \
    || fail "could not hold the cleanup-failure fixture"
  run_captain "$home" complete "$id" "$id" >/dev/null \
    || fail "completion gate failed for the cleanup-failure fixture"
  cat > "$home/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$home/fakebin/treehouse"

  set +e
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" --force \
    > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "cleanup succeeded despite the failed worktree return"
  assert_present "$home/state/$id.meta" "a failed cleanup removed the task record"
  assert_present "$home/state/$id.backlog-close" \
    "a failed cleanup lost the pending record that replays the retention"
  show=$(tasks_in "$home" show "$id" --full) || fail "a failed cleanup erased the captain call"
  assert_contains "$show" "state: in_flight" "a failed cleanup changed the row before cleanup succeeded"
  assert_contains "$show" "hold_kind: captain" "a failed cleanup dropped the captain hold"
  assert_not_contains "$show" "Deliverable of the finished work" \
    "the deliverable was recorded before destructive cleanup succeeded"

  fm_fake_exit0 "$home/fakebin" treehouse
  bootstrap=$(PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_BOOTSTRAP_NETWORK=skip \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1) \
    || fail "session start could not replay the interrupted retention: $bootstrap"
  assert_contains "$bootstrap" "kept the captain call for $id open" \
    "session start did not report the retained captain call"
  assert_absent "$home/state/$id.meta" "session start left the interrupted task record behind"
  assert_absent "$home/state/$id.backlog-close" "session start left the pending record behind"
  show=$(tasks_in "$home" show "$id" --full) || fail "session start erased the captain call"
  assert_not_contains "$show" "state: done" "session start closed the captain call with no recorded answer"
  assert_contains "$show" "state: queued" "session start did not return the captain call to the queue"
  assert_contains "$show" "hold_kind: captain" "session start dropped the captain hold"
  assert_contains "$show" "Deliverable of the finished work: report data/$id/report.md" \
    "session start did not record the finished work's deliverable"
  pass "an interrupted cleanup keeps the captain call recoverable and session start retains it"
}

# A home whose data directory is relocated keeps one backlog; the predicate and
# the retention must address it the way teardown does, not FM_HOME/data.
test_teardown_retains_captain_calls_in_a_relocated_backlog() {
  local home data id show
  home=$(make_home teardown-relocated-hold)
  data="$home/records"
  mv "$home/data" "$data"
  id=sample-relocated-hold
  mkdir -p "$home/data" "$data/$id"
  # A backlog at the default location stays empty, so a wrongly addressed read
  # would find no row at all.
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  (cd "$home" && tasks-axi add "$id" "Investigate relocated sample hold" --kind scout \
    --repo sample --start --file "$data/backlog.md" >/dev/null) \
    || fail "could not create the relocated captain-hold fixture"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Relocated hold\n\nThe captain call remains open.\n' > "$data/$id/report.md"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" hold "$id" \
    --reason "captain must choose the relocated sample outcome" >/dev/null \
    || fail "could not hold the relocated work item"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" complete "$id" "$id" >/dev/null \
    || fail "completion gate failed for the relocated captain hold"

  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" \
    > "$home/teardown.out" 2> "$home/teardown.err" \
    || fail "cleanup of the relocated captain hold failed: $(cat "$home/teardown.err")"
  show=$(cd "$home" && tasks-axi show "$id" --full --file "$data/backlog.md") \
    || fail "the relocated captain-held row disappeared"
  assert_not_contains "$show" "state: done" "cleanup closed the relocated captain call"
  assert_contains "$show" "state: queued" "cleanup left the relocated captain call reading as worked on"
  assert_contains "$show" "hold_kind: captain" "cleanup dropped the relocated captain hold"
  assert_contains "$show" "Deliverable of the finished work: report records/$id/report.md" \
    "cleanup did not record the deliverable in the relocated backlog"
  assert_absent "$home/state/$id.meta" "cleanup left the relocated task record behind"
  assert_absent "$home/state/$id.backlog-close" "cleanup left its pending record behind"
  assert_no_grep "$id" "$home/data/backlog.md" "cleanup wrote to the empty default-location backlog"
  pass "cleanup retains captain calls in the configured backlog"
}

# Archive verification and retirement must follow the same root and explicit
# --file as a relocated live backlog, even when the home has a conflicting row
# and TASKS_AXI_FILE names an unrelated file.
test_relocated_backlog_archive_uses_the_backend_addressing_root() {
  local home root data id origin show
  home=$(make_home relocated-archive)
  root="$home/elsewhere"
  data="$root/records"
  id=sample-relocated-archive-call
  origin=sample-relocated-archive-review
  mkdir -p "$data"
  cat > "$root/.tasks.toml" <<'EOF'
backend = "markdown"
[markdown]
path = "unrelated-backlog.md"
archive = "records/answered-calls.md"
done_keep = 10
EOF
  tasks_in "$home" add "$id" "Unrelated home task" --kind ship --repo sample >/dev/null \
    || fail "could not create the conflicting home row"
  write_origin_meta "$home" "$origin"

  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$data" \
    TASKS_AXI_FILE="$home/missing-env-backlog.md" \
    "$ROOT/bin/fm-captain-hold.sh" hold "$id" \
    --title "Choose relocated archive route" --reason "captain route pending" --repo sample >/dev/null \
    || fail "could not create a call in the relocated backlog"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$data" \
    "$ROOT/bin/fm-captain-hold.sh" complete "$origin" "$id" >/dev/null \
    || fail "could not attest the relocated call"
  printf 'Use the relocated route.\n' > "$home/answer.txt"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$data" \
    "$ROOT/bin/fm-captain-hold.sh" answer "$id" --decision-file "$home/answer.txt" >/dev/null \
    || fail "could not answer the relocated call"
  (cd "$root" && tasks-axi prune --state "done" --keep 0 --file "$data/backlog.md" >/dev/null) \
    || fail "could not archive the relocated call"
  assert_grep "- [x] $id -" "$data/answered-calls.md" \
    "the backend did not archive into the relocated root's configured archive"

  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$data" \
    TASKS_AXI_FILE="$home/missing-env-backlog.md" \
    "$ROOT/bin/fm-captain-hold.sh" verify "$origin" > "$home/verify.out" 2> "$home/verify.err" \
    || fail "the relocated archived answer did not verify: $(cat "$home/verify.err")"
  if PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$data" \
    "$ROOT/bin/fm-captain-hold.sh" hold "$id" \
    --title "Re-mint relocated call" --reason "should refuse" --repo sample \
    > "$home/remint.out" 2> "$home/remint.err"; then
    fail "the relocated archive allowed a resolved identity to be re-minted"
  fi
  assert_grep "already durably resolved" "$home/remint.err" \
    "retirement did not use the relocated archive"
  show=$(tasks_in "$home" show "$id" --full) || fail "the unrelated home row disappeared"
  assert_contains "$show" "Unrelated home task" "the relocated call overwrote the home row"
  assert_not_contains "$show" "hold_kind: captain" "the relocated call held the home row"
  assert_absent "$root/unrelated-backlog.md" "the relocated call ignored its explicit file"
  assert_absent "$home/missing-env-backlog.md" "the env override displaced the relocated file"
  assert_absent "$home/data/done-archive.md" "the relocated call used the home's archive"
  pass "relocated calls verify and retire from the same archive the backend writes"
}

# "Cannot tell" is not permission to close. A ship row has no separate
# inventory gate ahead of the close, so the predicate itself must refuse before
# any destructive step when the hold cannot be read.
test_teardown_refuses_a_ship_when_the_captain_hold_cannot_be_read() {
  local home id rc show
  home=$(make_home teardown-ship-hold-read-error)
  id=sample-unreadable-ship-hold
  tasks_in "$home" add "$id" "Ship the sample change" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the unreadable-hold fixture"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$home/projects/missing-$id" \
    "project=$home/projects/sample" "harness=codex" "kind=ship" "mode=direct-PR" \
    "spawn_gen=fixture-$id"
  printf 'done: PR https://github.com/sample/sample/pull/7\n' > "$home/state/$id.status"
  run_captain "$home" hold "$id" --reason "captain must approve the sample change" >/dev/null \
    || fail "could not hold the ship fixture for the captain"
  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = show ] && [ "${2:-}" = "${TASKS_AXI_FAIL_SHOW_ID:-}" ]; then
  printf 'error: temporary backlog read failure\n' >&2
  exit 75
fi
exec "${REAL_TASKS_AXI:?}" "$@"
SH
  chmod +x "$home/fakebin/tasks-axi"

  set +e
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    TASKS_AXI_FAIL_SHOW_ID="$id" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" --force \
    > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "cleanup treated an unreadable captain hold as permission to close"
  assert_present "$home/state/$id.meta" "read uncertainty must refuse before removing the task record"
  assert_absent "$home/state/$id.backlog-close" "read uncertainty staged a pending transition anyway"
  show=$(tasks_in "$home" show "$id" --full) || fail "the unreadable captain-held row disappeared"
  assert_contains "$show" "state: in_flight" "read uncertainty allowed cleanup to move the row"
  assert_contains "$show" "hold_kind: captain" "read uncertainty dropped the captain hold"
  assert_grep "could not be read" "$home/teardown.err" "cleanup did not explain the refusal"
  assert_grep "temporary backlog read failure" "$home/teardown.err" \
    "the underlying captain-hold read failure was hidden"
  pass "cleanup refuses a ship row when its captain hold cannot be read"
}

test_uninventoried_report_decision_refuses_completion
test_completion_gate_attests_and_transfers
test_resolved_archived_hold_verification_is_strict
test_unreadable_live_backlog_never_falls_back_to_archive
test_pruned_identity_still_resolves_from_archive
test_unrelated_config_error_never_proves_absence
test_unreadable_archive_never_retires_or_re_mints
test_missing_backlog_file_never_proves_absence
test_unreachable_archive_directory_never_re_mints
test_backend_path_precedence_governs_absence_proof
test_backend_archive_precedence_governs_retirement
test_answers_reports_read_failure_not_absence
test_first_call_in_a_home_with_no_backlog_file
test_home_config_resolution_matches_backend
test_archive_config_absent_defaults_and_malformed_fails
test_absent_tasks_toml_falls_back_to_backend_defaults
test_archive_config_matches_backend_toml_spellings
test_prose_heavy_and_out_of_band_archived_closes_verify
test_hold_retires_only_durably_resolved_archived_ids
test_answer_records_and_closes
test_release_frees_held_work
test_deferral_leaves_captains_call_until_due
test_out_of_band_close_is_recordable
test_visual_review_uses_shared_completion_owner
test_none_inventory_and_resolved_prose_do_not_create_holds
test_terminal_single_owner_status_decision_does_not_block_empty_inventory
test_secondmate_hold_stays_in_authoritative_home
test_secondmate_home_publishes_holds_and_answers
test_bound_channel_answers_close_at_answer_time
test_unbound_source_closes_no_hold
test_legacy_identities_keep_working
test_chat_channel_feeds_the_same_keyed_answer_intake
test_origin_slug_validation_precedes_path_construction
test_status_resolution_over_an_open_hold_is_signalled
test_legitimate_holds_produce_no_divergence_signal
test_teardown_never_closes_a_captain_held_task
test_interrupted_cleanup_keeps_the_captain_call_recoverable
test_teardown_retains_captain_calls_in_a_relocated_backlog
test_relocated_backlog_archive_uses_the_backend_addressing_root
test_teardown_refuses_a_ship_when_the_captain_hold_cannot_be_read
