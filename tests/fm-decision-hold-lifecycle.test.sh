#!/usr/bin/env bash
# End-to-end tests for durable captain-held decisions discovered by investigations
# and visual reviews.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-decision-hold)
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

# Reproduces the loss exactly with privacy-safe synthetic names: the investigation
# and visual review have ended, the only genuine unresolved decision is report prose,
# no held backlog item or open status exists, and the authoritative Bearings view
# correctly omits it. Completion must now refuse before teardown can erase the source.
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
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-scratch" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout"
  printf 'done: report and visual review complete\n' > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample route review

The evidence is complete.
The captain still needs to choose route north or route south before follow-up work starts.
EOF

  json=$(run_bearings "$home") || fail "Bearings failed for unresolved-decision regression"
  printf '%s' "$json" | jq -e '
    (.decisions_open | length) == 0
      and (.gates | length) == 0
      and (.reports | any(.id == "sample-route-review"))
  ' >/dev/null || fail "the pre-policy omission shape was not reproduced: $json"

  set +e
  run_teardown "$home" "$id" > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "completed investigation teardown erased a report-only unresolved decision"
  assert_present "$home/state/$id.meta" "refused completion must preserve investigation metadata"
  assert_grep "REFUSED" "$home/teardown.err" "refusal must be explicit"
  pass "report-only unresolved decision is reproduced and completion refuses before loss"
}

tasks_in() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

run_decisions() {  # <home> <command args...>
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
    "mode=$kind"
}

test_structured_holds_survive_teardown_and_route_resolution() {
  local home id route_hold access_hold before after json open show
  home=$(make_home durable-lifecycle)
  id=sample-systems-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample systems" --kind scout --repo sample --start >/dev/null \
    || fail "could not create investigation backlog fixture"
  write_origin_meta "$home" "$id"
  cat > "$home/state/$id.status" <<'EOF'
needs-decision [key=route]: choose route north or route south
needs-decision [key=access]: choose open or restricted sample access
done: report and visual review complete
EOF
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample systems review

Two choices remain unresolved: the route and the sample access level.
A separate recommendation is already resolved and requires no captain action.
EOF

  if run_decisions "$home" complete "$id" route access > "$home/early-complete.out" 2> "$home/early-complete.err"; then
    fail "completion succeeded before unresolved decisions had captain holds"
  fi
  assert_no_grep "decisions_reviewed=1" "$home/state/$id.meta" \
    "failed completion recorded a false completion attestation"

  route_hold=$(run_decisions "$home" hold "$id" route \
    --title "Choose the sample route" --reason "captain route choice pending" --repo sample) \
    || fail "could not register route hold"
  [ "$route_hold" = "$id-decision-route" ] || fail "route hold identity was not deterministic: $route_hold"
  run_decisions "$home" hold "$id" route \
    --title "Choose the sample route" --reason "captain route choice pending" --repo sample >/dev/null \
    || fail "idempotent hold retry failed"
  if run_decisions "$home" complete "$id" route access > "$home/partial-complete.out" 2> "$home/partial-complete.err"; then
    fail "completion succeeded while one of two distinct decisions lacked a hold"
  fi
  access_hold=$(run_decisions "$home" hold "$id" access \
    --title "Choose the sample access level" --reason "captain access choice pending" --repo sample) \
    || fail "could not register access hold"
  [ "$access_hold" = "$id-decision-access" ] || fail "access hold identity was not distinct: $access_hold"
  [ "$(grep -cE "^- \[ \] $route_hold -" "$home/data/backlog.md")" = 1 ] \
    || fail "idempotent retry duplicated the route hold"
  [ "$(grep -cE "^- \[ \] $access_hold -" "$home/data/backlog.md")" = 1 ] \
    || fail "second decision did not retain one distinct backlog identity"

  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"
    sig=$(fm_wake_signal_sig "$3") || exit 1
    printf "%s" "$sig" > "$(fm_wake_signal_seen_path "$2" "$3")"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/$id.status" \
    || fail "could not prime the announced decision baseline"
  run_decisions "$home" complete "$id" route access >/dev/null \
    || fail "shared investigation completion gate failed"
  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"; fm_wake_signal_seen_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/$id.status" \
    || fail "captain-held bookkeeping closes re-woke their own home"
  assert_grep "decisions_reviewed=1" "$home/state/$id.meta" "completion attestation missing"
  assert_grep "decision_keys=access,route" "$home/state/$id.meta" "decision inventory was not deterministic"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  [ -z "$open" ] || fail "captain-held transfer did not close duplicate live status decisions: $open"

  before=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  json=$(run_bearings "$home") || fail "Bearings failed with captain-held decisions"
  after=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "Bearings mutated the authoritative backlog"
  printf '%s' "$json" | jq -e --arg route "$route_hold" --arg access "$access_hold" '
    (.decisions_open | any(.id == $route and .verb == "captain-hold" and .owner == "(main)"))
      and (.decisions_open | any(.id == $access and .verb == "captain-hold" and .owner == "(main)"))
      and (.gates | any(.id == $route or .id == $access) | not)
  ' >/dev/null || fail "Bearings did not surface structured captain holds: $json"

  run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
    || fail "reviewed investigation teardown failed: $(cat "$home/teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null \
    || fail "could not archive completed investigation"
  ! grep -E "^- \[[ x]\] $id -" "$home/data/backlog.md" >/dev/null \
    || fail "origin remained in the live backlog after archival"
  grep -E "^- \[x\] $id -" "$home/data/done-archive.md" >/dev/null \
    || fail "origin was not durably archived"
  json=$(run_bearings "$home") || fail "Bearings failed after source teardown and archival"
  printf '%s' "$json" | jq -e --arg route "$route_hold" --arg access "$access_hold" '
    (.decisions_open | any(.id == $route and .verb == "captain-hold"))
      and (.decisions_open | any(.id == $access and .verb == "captain-hold"))
      and (.in_flight | any(.id == "sample-systems-review") | not)
  ' >/dev/null || fail "teardown or archival erased a captain-held decision: $json"

  tasks_in "$home" add sample-route-implementation "Apply the selected sample route" \
    --kind ship --repo sample >/dev/null \
    || fail "could not create dependent work fixture"
  printf 'Use route north for the sample system.\n' > "$home/route-decision.txt"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation > "$home/early-resolve.out" 2> "$home/early-resolve.err"; then
    fail "captain hold closed before dependent work had a durable routing edge"
  fi
  show=$(tasks_in "$home" show "$route_hold" --full)
  assert_contains "$show" "state: queued" "failed routing attempt closed the hold"
  assert_contains "$show" "held: yes" "failed routing attempt released the hold"
  tasks_in "$home" block sample-route-implementation --by "$route_hold" >/dev/null \
    || fail "could not route dependent work behind the decision hold"
  tasks_in "$home" add sample-route-followup "Check the selected sample route" \
    --kind ship --repo sample --blocked-by "$route_hold" >/dev/null \
    || fail "could not create second dependent work fixture"
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = unblock ] && [ "${2:-}" = sample-route-implementation ] \
  && [ ! -f "$FM_HOME/unblock-failed-once" ]; then
  : > "$FM_HOME/unblock-failed-once"
  exit 1
fi
exec "$REAL_TASKS_AXI" "$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup \
    > "$home/partial-route.out" 2> "$home/partial-route.err"; then
    fail "resolution succeeded after a partial dependent-routing failure"
  fi
  show=$(tasks_in "$home" show "$route_hold" --full)
  assert_contains "$show" "state: queued" "partial routing failure closed the hold"
  show=$(tasks_in "$home" show sample-route-followup --full)
  assert_contains "$show" "blocked: no" "partial routing fixture did not release its first dependent"
  show=$(tasks_in "$home" show sample-route-implementation --full)
  assert_contains "$show" "blocked: yes" "partial routing fixture unexpectedly released its second dependent"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-followup > "$home/reduced-retry.out" 2> "$home/reduced-retry.err"; then
    fail "partial resolution retry accepted a reduced routed task set"
  fi
  printf 'Use route south for the sample system.\n' > "$home/changed-route-decision.txt"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/changed-route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup \
    > "$home/partial-drifted-decision.out" 2> "$home/partial-drifted-decision.err"; then
    fail "partial resolution retry accepted a different captain decision"
  fi
  tasks_in "$home" "done" sample-route-followup >/dev/null \
    || fail "could not complete already-routed dependent work"
  run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup >/dev/null \
    || fail "could not resume and complete partial decision routing"
  run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup >/dev/null \
    || fail "identical resolution retry was not idempotent"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/changed-route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup \
    > "$home/drifted-decision.out" 2> "$home/drifted-decision.err"; then
    fail "resolution retry accepted a different captain decision"
  fi
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation \
    > "$home/drifted-routes.out" 2> "$home/drifted-routes.err"; then
    fail "resolution retry accepted a different routed task set"
  fi
  show=$(tasks_in "$home" show "$route_hold" --full)
  assert_contains "$show" "state: done" "resolved hold did not close"
  assert_contains "$show" "Resolution recorded by fm-decision-hold" "resolved hold lost the decision record"
  show=$(tasks_in "$home" show sample-route-implementation --full)
  assert_contains "$show" "blocked: no" "recorded decision did not release dependent work"
  json=$(run_bearings "$home") || fail "Bearings failed after decision resolution"
  printf '%s' "$json" | jq -e --arg route "$route_hold" --arg access "$access_hold" '
    (.decisions_open | any(.id == $route) | not)
      and (.decisions_open | any(.id == $access and .verb == "captain-hold"))
      and (.gates | any(.id == "sample-route-implementation"))
      and (.decisions_open | any(.id == "sample-systems-review") | not)
  ' >/dev/null || fail "resolved or decision-like report prose produced a false hold: $json"
  pass "captain holds are idempotent, distinct, teardown-safe, Bearings-visible, and durably routed before close"
}

test_scout_teardown_always_requires_inventory_verification() {
  local home id
  home=$(make_home unconditional-teardown)
  id=sample-absent-review
  mkdir -p "$home/data/$id"
  write_origin_meta "$home" "$id"
  printf '# Sample absent review\n\nNo decision inventory was recorded.\n' > "$home/data/$id/report.md"
  if run_teardown "$home" "$id" > "$home/absent-teardown.out" 2> "$home/absent-teardown.err"; then
    fail "scout teardown skipped verification when its backlog task was absent"
  fi
  assert_present "$home/state/$id.meta" "refused absent-task teardown removed metadata"

  home=$(make_home unavailable-teardown)
  id=sample-unavailable-review
  mkdir -p "$home/data/$id"
  write_origin_meta "$home" "$id"
  printf '# Sample unavailable review\n\nNo decision inventory was recorded.\n' > "$home/data/$id/report.md"
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
  chmod +x "$home/fakebin/tasks-axi"
  if run_teardown "$home" "$id" > "$home/unavailable-teardown.out" 2> "$home/unavailable-teardown.err"; then
    fail "scout teardown skipped verification when tasks-axi was unavailable"
  fi
  assert_present "$home/state/$id.meta" "refused unavailable-task teardown removed metadata"
  pass "non-forced scout teardown always requires durable inventory verification"
}

test_origin_slug_validation_precedes_path_construction() {
  local home escaped
  home=$(make_home origin-validation)
  escaped="$home/escaped-origin.meta"
  printf 'sentinel=unchanged\n' > "$escaped"
  if run_decisions "$home" complete ../escaped-origin --none \
    > "$home/invalid-complete.out" 2> "$home/invalid-complete.err"; then
    fail "completion accepted an origin path traversal"
  fi
  if run_decisions "$home" verify ../escaped-origin \
    > "$home/invalid-verify.out" 2> "$home/invalid-verify.err"; then
    fail "verification accepted an origin path traversal"
  fi
  [ "$(cat "$escaped")" = "sentinel=unchanged" ] \
    || fail "invalid origin changed metadata outside the state directory"
  pass "completion and verification validate origins before constructing paths"
}

test_visual_review_uses_shared_completion_owner() {
  local home id hold json
  home=$(make_home visual-review)
  id=sample-board-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review the sample board" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: investigation complete\n' > "$home/state/$id.status"
  printf '# Sample board investigation\n\nThe initial findings need no captain choice.\n' > "$home/data/$id/report.md"
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "initial investigation could not pass the shared completion owner"
  run_teardown "$home" "$id" >/dev/null 2> "$home/visual-teardown.err" \
    || fail "completed investigation teardown failed: $(cat "$home/visual-teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null

  mkdir -p "$home/.lavish"
  printf '<html><body>Synthetic sample board</body></html>\n' > "$home/.lavish/sample-board.html"
  hold=$(run_decisions "$home" hold "$id" layout \
    --title "Choose the sample layout" --reason "captain layout choice pending" --repo sample) \
    || fail "post-teardown visual review could not use the shared hold owner"
  run_decisions "$home" complete "$id" layout >/dev/null \
    || fail "post-teardown visual review could not use the shared completion owner"
  [ "$hold" = "$id-decision-layout" ] || fail "visual review used a separate identity policy"
  json=$(run_bearings "$home") || fail "Bearings failed after the ended visual review"
  printf '%s' "$json" | jq -e --arg hold "$hold" '
    .decisions_open | any(.id == $hold and .verb == "captain-hold")
  ' >/dev/null || fail "ended visual review did not leave its durable Captain Call: $json"
  [ ! -e "$home/data/visual-review-decisions.json" ] \
    || fail "visual review created a second decision database"
  pass "ended visual review follows the same decision-hold completion owner"
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
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "explicit no-decision inventory failed"
  json=$(run_bearings "$home") || fail "Bearings failed for no-decision inventory"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id | startswith("sample-resolved-review")) | not)
  ' >/dev/null || fail "resolved findings or decision-like prose created a false hold: $json"
  pass "resolved findings and decision-like prose do not create false holds"
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
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "terminal single-owner stale status decision blocked empty inventory completion"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "terminal single-owner stale status decision blocked inventory verification"
  run_teardown "$home" "$id" >/dev/null 2> "$home/terminal-teardown.err" \
    || fail "terminal single-owner stale status decision blocked teardown: $(cat "$home/terminal-teardown.err")"

  secondmate=sample-secondmate
  write_origin_meta "$home" "$secondmate" secondmate
  printf 'needs-decision [key=route]: choose route A or route B\ndone: heartbeat complete\n' \
    > "$home/state/$secondmate.status"
  if run_decisions "$home" complete "$secondmate" --none \
    > "$home/secondmate-terminal.out" 2> "$home/secondmate-terminal.err"; then
    fail "secondmate terminal status decision was incorrectly cleared"
  fi
  pass "terminal single-owner stale status decisions do not block empty inventory"
}

test_secondmate_hold_stays_in_authoritative_home() {
  local parent mate origin hold json
  parent=$(make_home main-routing)
  mate="$TMP_ROOT/sample-mate-home"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  cp "$ROOT/.tasks.toml" "$mate/.tasks.toml"
  printf '# Synthetic secondmate home\n' > "$mate/AGENTS.md"
  printf 'sample-mate\n' > "$mate/.fm-secondmate-home"
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
  hold=$(run_decisions "$mate" hold "$origin" release \
    --title "Choose the sample release" --reason "captain release choice pending" --repo sample) \
    || fail "secondmate-owned hold creation failed"
  run_decisions "$mate" complete "$origin" release >/dev/null \
    || fail "secondmate-owned completion failed"
  run_teardown "$mate" "$origin" >/dev/null 2> "$mate/teardown.err" \
    || fail "secondmate investigation teardown failed: $(cat "$mate/teardown.err")"
  tasks_in "$mate" "done" "$origin" --report "data/$origin/report.md" --keep 0 >/dev/null

  printf -- '- sample-mate - synthetic scope (home: %s; scope: sample reviews; projects: sample; added 2026-07-14)\n' \
    "$mate" > "$parent/data/secondmates.md"
  fm_write_secondmate_meta "$parent/state/sample-mate.meta" "$mate" \
    "firstmate:fm-sample-mate" sample
  json=$(run_bearings "$parent") || fail "parent Bearings could not read secondmate hold"
  printf '%s' "$json" | jq -e --arg hold "$hold" '
    .decisions_open | any(.owner == "sample-mate" and .verb == "captain-hold" and (.id | endswith($hold)))
  ' >/dev/null || fail "secondmate captain hold did not surface with authoritative owner: $json"
  assert_no_grep "$hold" "$parent/data/backlog.md" "secondmate hold leaked into the main backlog"
  assert_grep "$hold" "$mate/data/backlog.md" "secondmate hold left its authoritative backlog"
  pass "main-home and secondmate-home captain holds remain correctly routed"
}

# tasks-axi quotes multi-entry blocked_by values as "a,b,c". resolve must strip
# those surrounding quotes before comma-boundary membership so the first and last
# list elements match, not only middle elements.
test_resolve_matches_quoted_blocked_by_edges() {
  local home origin hold_first hold_mid hold_last hold_absent show
  home=$(make_home quoted-blocked-by-edges)
  origin=sample-quote-review
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Quoted blocked_by edge review" --kind scout --repo sample --start >/dev/null \
    || fail "could not create quote-edge origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Quote edge review\n\nThree edge decisions and one absent control.\n' > "$home/data/$origin/report.md"

  hold_first=$(run_decisions "$home" hold "$origin" edge-first \
    --title "First edge decision" --reason "captain first pending" --repo sample) \
    || fail "could not register first-edge hold"
  hold_mid=$(run_decisions "$home" hold "$origin" edge-mid \
    --title "Middle edge decision" --reason "captain mid pending" --repo sample) \
    || fail "could not register mid-edge hold"
  hold_last=$(run_decisions "$home" hold "$origin" edge-last \
    --title "Last edge decision" --reason "captain last pending" --repo sample) \
    || fail "could not register last-edge hold"
  hold_absent=$(run_decisions "$home" hold "$origin" edge-absent \
    --title "Absent edge decision" --reason "captain absent pending" --repo sample) \
    || fail "could not register absent-edge hold"

  tasks_in "$home" add pad-a "Pad A" --kind ship --repo sample >/dev/null \
    || fail "could not create pad-a blocker"
  tasks_in "$home" add pad-b "Pad B" --kind ship --repo sample >/dev/null \
    || fail "could not create pad-b blocker"

  tasks_in "$home" add dep-first "Dep first position" --kind ship --repo sample >/dev/null \
    || fail "could not create first-position dependent"
  tasks_in "$home" block dep-first --by "$hold_first" >/dev/null || fail "could not block dep-first by first hold"
  tasks_in "$home" block dep-first --by pad-a >/dev/null || fail "could not block dep-first by pad-a"
  tasks_in "$home" block dep-first --by pad-b >/dev/null || fail "could not block dep-first by pad-b"
  show=$(tasks_in "$home" show dep-first --full)
  assert_contains "$show" "blocked_by: \"$hold_first,pad-a,pad-b\"" \
    "first-position fixture must quote multi-entry blocked_by"
  printf 'Decide first edge.\n' > "$home/d-first.txt"
  if ! run_decisions "$home" resolve "$origin" edge-first --decision-file "$home/d-first.txt" \
    --routed-to dep-first > "$home/first.out" 2> "$home/first.err"; then
    fail "resolve failed when hold id is FIRST in quoted blocked_by: $(cat "$home/first.err")"
  fi

  tasks_in "$home" add dep-mid "Dep mid position" --kind ship --repo sample >/dev/null \
    || fail "could not create mid-position dependent"
  tasks_in "$home" block dep-mid --by pad-a >/dev/null || fail "could not block dep-mid by pad-a"
  tasks_in "$home" block dep-mid --by "$hold_mid" >/dev/null || fail "could not block dep-mid by mid hold"
  tasks_in "$home" block dep-mid --by pad-b >/dev/null || fail "could not block dep-mid by pad-b"
  show=$(tasks_in "$home" show dep-mid --full)
  assert_contains "$show" "blocked_by: \"pad-a,$hold_mid,pad-b\"" \
    "middle-position fixture must quote multi-entry blocked_by"
  printf 'Decide mid edge.\n' > "$home/d-mid.txt"
  if ! run_decisions "$home" resolve "$origin" edge-mid --decision-file "$home/d-mid.txt" \
    --routed-to dep-mid > "$home/mid.out" 2> "$home/mid.err"; then
    fail "resolve failed when hold id is MIDDLE in quoted blocked_by: $(cat "$home/mid.err")"
  fi

  tasks_in "$home" add dep-last "Dep last position" --kind ship --repo sample >/dev/null \
    || fail "could not create last-position dependent"
  tasks_in "$home" block dep-last --by pad-a >/dev/null || fail "could not block dep-last by pad-a"
  tasks_in "$home" block dep-last --by pad-b >/dev/null || fail "could not block dep-last by pad-b"
  tasks_in "$home" block dep-last --by "$hold_last" >/dev/null || fail "could not block dep-last by last hold"
  show=$(tasks_in "$home" show dep-last --full)
  assert_contains "$show" "blocked_by: \"pad-a,pad-b,$hold_last\"" \
    "last-position fixture must quote multi-entry blocked_by"
  printf 'Decide last edge.\n' > "$home/d-last.txt"
  if ! run_decisions "$home" resolve "$origin" edge-last --decision-file "$home/d-last.txt" \
    --routed-to dep-last > "$home/last.out" 2> "$home/last.err"; then
    fail "resolve failed when hold id is LAST in quoted blocked_by: $(cat "$home/last.err")"
  fi

  tasks_in "$home" add dep-absent "Dep absent control" --kind ship --repo sample >/dev/null \
    || fail "could not create absent-control dependent"
  tasks_in "$home" block dep-absent --by pad-a >/dev/null || fail "could not block dep-absent by pad-a"
  tasks_in "$home" block dep-absent --by pad-b >/dev/null || fail "could not block dep-absent by pad-b"
  show=$(tasks_in "$home" show dep-absent --full)
  assert_contains "$show" "blocked_by: \"pad-a,pad-b\"" \
    "absent-control fixture must quote multi-entry blocked_by without the hold id"
  printf 'Decide absent edge.\n' > "$home/d-absent.txt"
  if run_decisions "$home" resolve "$origin" edge-absent --decision-file "$home/d-absent.txt" \
    --routed-to dep-absent > "$home/absent.out" 2> "$home/absent.err"; then
    fail "resolve succeeded when hold id is genuinely absent from blocked_by"
  fi
  assert_grep "not durably blocked by" "$home/absent.err" \
    "absent id must fail with durable-block error"
  show=$(tasks_in "$home" show "$hold_absent" --full)
  assert_contains "$show" "state: queued" "failed absent resolve must leave the hold open"
  assert_contains "$show" "held: yes" "failed absent resolve must leave the hold held"

  pass "resolve matches first/middle/last in quoted blocked_by and rejects a genuinely absent id"
}

# A captain who declines a held decision leaves no follow-up work to route, so the
# routed close path cannot express the answer. The unrouted close path must record
# that answer durably while still refusing to release work the hold blocks.
test_declined_decision_closes_without_routed_work() {
  local home id hold routed_hold json show
  home=$(make_home declined-decision)
  id=sample-benchmark-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample benchmarks" --kind scout --repo sample --start >/dev/null \
    || fail "could not create declined-decision origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample benchmark review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  hold=$(run_decisions "$home" hold "$id" half-run \
    --title "Choose the sample half run" --reason "captain half-run choice pending" --repo sample) \
    || fail "could not register the declinable hold"
  run_decisions "$home" complete "$id" half-run >/dev/null \
    || fail "completion failed for the declinable hold"

  printf '' > "$home/empty-decision.txt"
  if run_decisions "$home" decline "$id" half-run --decision-file "$home/empty-decision.txt" \
    > "$home/empty-decline.out" 2> "$home/empty-decline.err"; then
    fail "decline accepted an empty captain decision"
  fi
  if run_decisions "$home" decline "$id" half-run > "$home/bare-decline.out" 2> "$home/bare-decline.err"; then
    fail "decline accepted a close with no captain decision file at all"
  fi
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" "a refused decline closed the hold"
  assert_contains "$show" "held: yes" "a refused decline released the hold"

  printf 'Declined: do not run the sample half benchmark.\n' > "$home/half-run-decision.txt"
  run_decisions "$home" decline "$id" half-run --decision-file "$home/half-run-decision.txt" >/dev/null \
    || fail "decline could not close a hold that routes no work"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "declined hold did not close"
  assert_contains "$show" "Resolution recorded by fm-decision-hold" "declined hold lost the decision record"
  assert_contains "$show" "Resolution mode: declined" "declined hold did not record its close path"
  assert_contains "$show" "Declined: do not run the sample half benchmark." \
    "declined hold did not record the captain decision text"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "a declined decision did not satisfy the completion gate"
  run_decisions "$home" decline "$id" half-run --decision-file "$home/half-run-decision.txt" >/dev/null \
    || fail "identical decline retry was not idempotent"
  printf 'Declined for a different reason.\n' > "$home/drifted-decision.txt"
  if run_decisions "$home" decline "$id" half-run --decision-file "$home/drifted-decision.txt" \
    > "$home/drifted-decline.out" 2> "$home/drifted-decline.err"; then
    fail "decline retry accepted a different captain decision"
  fi
  json=$(run_bearings "$home") || fail "Bearings failed after a declined decision"
  printf '%s' "$json" | jq -e --arg hold "$hold" '
    (.decisions_open | any(.id == $hold) | not)
  ' >/dev/null || fail "a declined decision remained an open Captain's Call: $json"

  routed_hold=$(run_decisions "$home" hold "$id" upstream \
    --title "Choose the sample upstream target" --reason "captain upstream choice pending" --repo sample) \
    || fail "could not register the routed-work hold"
  tasks_in "$home" add sample-upstream-work "Apply the sample upstream choice" \
    --kind ship --repo sample --blocked-by "$routed_hold" >/dev/null \
    || fail "could not route work behind the second hold"
  if run_decisions "$home" decline "$id" upstream --decision-file "$home/half-run-decision.txt" \
    > "$home/routed-decline.out" 2> "$home/routed-decline.err"; then
    fail "decline released work that was still routed behind the hold"
  fi
  assert_grep "still blocks routed work" "$home/routed-decline.err" \
    "decline must name the routed work it refuses to release"
  show=$(tasks_in "$home" show "$routed_hold" --full)
  assert_contains "$show" "state: queued" "refused routed decline closed the hold"
  show=$(tasks_in "$home" show sample-upstream-work --full)
  assert_contains "$show" "blocked: yes" "refused routed decline released dependent work"
  if run_decisions "$home" resolve "$id" upstream --decision-file "$home/half-run-decision.txt" \
    > "$home/unrouted-resolve.out" 2> "$home/unrouted-resolve.err"; then
    fail "the routed close path accepted a resolution with no routed work"
  fi
  pass "a declined decision closes with a recorded answer and no routed work"
}

# The exact incident: two declined captain decisions were closed with a direct
# tasks-axi done, so the durable resolution attestation this gate reads was never
# written and the investigation could no longer be cleaned up.
test_out_of_band_close_is_repairable_before_teardown() {
  local home id hold show
  home=$(make_home out-of-band-close)
  id=sample-fullrun-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate the sample full run" --kind scout --repo sample --start >/dev/null \
    || fail "could not create out-of-band-close origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample full run review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  hold=$(run_decisions "$home" hold "$id" submission \
    --title "Choose the sample submission" --reason "captain submission choice pending" --repo sample) \
    || fail "could not register the out-of-band hold"
  run_decisions "$home" complete "$id" submission >/dev/null \
    || fail "completion failed before the out-of-band close"

  tasks_in "$home" "done" "$hold" >/dev/null || fail "could not reproduce the direct out-of-band close"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "the out-of-band close shape was not reproduced"
  assert_no_grep "Resolution recorded by fm-decision-hold" "$home/data/backlog.md" \
    "the out-of-band close must leave no durable resolution record"
  if run_decisions "$home" verify "$id" > "$home/broken-verify.out" 2> "$home/broken-verify.err"; then
    fail "verification passed a captain decision closed with no recorded answer"
  fi
  if run_teardown "$home" "$id" > "$home/broken-teardown.out" 2> "$home/broken-teardown.err"; then
    fail "teardown proceeded while a captain decision had no recorded answer"
  fi
  assert_present "$home/state/$id.meta" "refused teardown removed investigation metadata"

  if run_decisions "$home" repair "$id" submission > "$home/bare-repair.out" 2> "$home/bare-repair.err"; then
    fail "repair recorded a resolution with no captain decision file"
  fi
  printf '' > "$home/empty-repair.txt"
  if run_decisions "$home" repair "$id" submission --decision-file "$home/empty-repair.txt" \
    > "$home/empty-repair.out" 2> "$home/empty-repair.err"; then
    fail "repair recorded a resolution from an empty captain decision file"
  fi
  if run_decisions "$home" verify "$id" > "$home/still-broken.out" 2> "$home/still-broken.err"; then
    fail "a refused repair still satisfied the completion gate"
  fi

  printf 'Declined: do not submit the sample full run upstream.\n' > "$home/submission-decision.txt"
  run_decisions "$home" repair "$id" submission --decision-file "$home/submission-decision.txt" >/dev/null \
    || fail "repair could not record the missing durable resolution"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "repair reopened a closed captain decision"
  assert_contains "$show" "Resolution mode: repaired" "repair did not record its close path"
  assert_contains "$show" "Declined: do not submit the sample full run upstream." \
    "repair did not record the captain decision text"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "the repaired decision did not satisfy the completion gate"
  run_decisions "$home" repair "$id" submission --decision-file "$home/submission-decision.txt" >/dev/null \
    || fail "identical repair retry was not idempotent"
  printf 'A different answer entirely.\n' > "$home/drifted-repair.txt"
  if run_decisions "$home" repair "$id" submission --decision-file "$home/drifted-repair.txt" \
    > "$home/drifted-repair.out" 2> "$home/drifted-repair.err"; then
    fail "repair retry overwrote the recorded captain decision"
  fi
  run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
    || fail "teardown still refused after the decision was repaired: $(cat "$home/teardown.err")"
  pass "a decision closed outside the script is repairable and then clears teardown"
}

# The unrouted close paths must not become a way past the gate. An unanswered
# decision keeps blocking cleanup, and neither new path can manufacture an answer.
test_unanswered_decision_still_blocks_completion_and_teardown() {
  local home id hold show
  home=$(make_home unanswered-decision)
  id=sample-open-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate an open sample choice" --kind scout --repo sample --start >/dev/null \
    || fail "could not create unanswered-decision origin"
  write_origin_meta "$home" "$id"
  printf 'needs-decision [key=open-choice]: choose sample option A or option B\n' \
    > "$home/state/$id.status"
  printf '# Sample open review\n\nThe captain has not chosen yet.\n' > "$home/data/$id/report.md"
  printf 'An answer the captain never gave.\n' > "$home/invented-decision.txt"

  if run_decisions "$home" complete "$id" open-choice > "$home/open-complete.out" 2> "$home/open-complete.err"; then
    fail "completion accepted an unresolved decision with no captain hold"
  fi
  if run_decisions "$home" verify "$id" > "$home/open-verify.out" 2> "$home/open-verify.err"; then
    fail "verification accepted an unresolved decision with no captain hold"
  fi
  if run_teardown "$home" "$id" > "$home/open-teardown.out" 2> "$home/open-teardown.err"; then
    fail "teardown erased an investigation whose decision was never inventoried"
  fi
  assert_grep "REFUSED" "$home/open-teardown.err" "teardown refusal must be explicit"
  if run_decisions "$home" decline "$id" open-choice --decision-file "$home/invented-decision.txt" \
    > "$home/absent-decline.out" 2> "$home/absent-decline.err"; then
    fail "decline invented a resolution for a decision that has no hold"
  fi
  if run_decisions "$home" repair "$id" open-choice --decision-file "$home/invented-decision.txt" \
    > "$home/absent-repair.out" 2> "$home/absent-repair.err"; then
    fail "repair invented a resolution for a decision that has no hold"
  fi

  tasks_in "$home" add "$id-decision-never-held" "An ordinary captain-kind task" \
    --kind captain --repo sample >/dev/null \
    || fail "could not create the never-held captain-kind fixture"
  tasks_in "$home" "done" "$id-decision-never-held" >/dev/null \
    || fail "could not close the never-held captain-kind fixture"
  if run_decisions "$home" repair "$id" never-held --decision-file "$home/invented-decision.txt" \
    > "$home/never-held-repair.out" 2> "$home/never-held-repair.err"; then
    fail "repair turned an ordinary captain-kind task into a resolved captain decision"
  fi
  assert_grep "never held for the captain" "$home/never-held-repair.err" \
    "repair must say the identity carries no captain-hold provenance"
  show=$(tasks_in "$home" show "$id-decision-never-held" --full)
  assert_not_contains "$show" "Resolution recorded by fm-decision-hold" \
    "a refused never-held repair wrote a resolution record"

  hold=$(run_decisions "$home" hold "$id" open-choice \
    --title "Choose the sample option" --reason "captain option choice pending" --repo sample) \
    || fail "could not register the unanswered hold"
  if run_decisions "$home" repair "$id" open-choice --decision-file "$home/invented-decision.txt" \
    > "$home/held-repair.out" 2> "$home/held-repair.err"; then
    fail "repair closed a decision that is still actively held and unanswered"
  fi
  assert_grep "still open" "$home/held-repair.err" "repair must say the hold is still open"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" "a refused repair closed the live hold"
  assert_contains "$show" "held: yes" "a refused repair released the live hold"
  assert_no_grep "Resolution recorded by fm-decision-hold" "$home/data/backlog.md" \
    "a refused repair wrote a resolution record"
  run_decisions "$home" complete "$id" open-choice >/dev/null \
    || fail "an inventoried unanswered decision could not complete its review"
  pass "an unanswered decision still blocks completion and resists both unrouted close paths"
}

test_resolved_archived_hold_verification_is_strict() {
  local home origin hold archive pristine record
  home=$(make_home archived-resolved-hold)
  origin=sample-archived-review
  archive="$home/data/decisions/archive.md"
  mkdir -p "$home/data/$origin" "$(dirname "$archive")"
  sed 's#archive = "data/done-archive.md"#archive = "data/decisions/archive.md"#' \
    "$ROOT/.tasks.toml" > "$home/.tasks.toml"
  tasks_in "$home" add "$origin" "Review archived decision verification" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create archived decision origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Archived decision review\n' > "$home/data/$origin/report.md"
  hold=$(run_decisions "$home" hold "$origin" route \
    --title "Choose archived route" --reason "captain route pending" --repo sample) \
    || fail "could not create hold for archive verification"
  run_decisions "$home" complete "$origin" route >/dev/null \
    || fail "could not record archived decision inventory"
  tasks_in "$home" add sample-archived-route "Apply archived route" \
    --kind ship --repo sample --blocked-by "$hold" >/dev/null \
    || fail "could not create archived route dependency"
  printf 'Use archived route north.\n' > "$home/archived-decision.txt"
  run_decisions "$home" resolve "$origin" route \
    --decision-file "$home/archived-decision.txt" --routed-to sample-archived-route >/dev/null \
    || fail "could not resolve hold before archive pruning"
  tasks_in "$home" prune --state "done" --keep 0 >/dev/null \
    || fail "could not prune resolved hold to configured archive"
  assert_no_grep "- [x] $hold -" "$home/data/backlog.md" \
    "resolved hold remained in the live backlog after pruning"
  assert_grep "- [x] $hold -" "$archive" \
    "resolved hold did not use the configured archive path"
  run_decisions "$home" verify "$origin" >/dev/null \
    || fail "configured archived resolved hold did not pass verification"
  cp "$archive" "$home/archive.pristine"
  pristine="$home/archive.pristine"

  rm "$archive"
  if run_decisions "$home" verify "$origin" > "$home/missing.out" 2> "$home/missing.err"; then
    fail "verification accepted a missing archived hold"
  fi
  assert_grep "absent from the live backlog and configured archive" "$home/missing.err" \
    "missing archive failure did not identify both authoritative locations"
  cp "$pristine" "$archive"

  sed "/^  Decision digest:/d" "$pristine" > "$archive"
  if run_decisions "$home" verify "$origin" > "$home/malformed.out" 2> "$home/malformed.err"; then
    fail "verification accepted a malformed archived resolution record"
  fi
  assert_grep "invalid decision digest" "$home/malformed.err" \
    "malformed archive failure did not identify the invalid structured field"
  cp "$pristine" "$archive"

  # The archive is append-only history, not a uniqueness index: an earlier
  # non-conforming cycle of the same key sits beside the durably resolved one, and
  # the resolved cycle still attests that the decision was answered.
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
  run_decisions "$home" verify "$origin" > "$home/archive-duplicate.out" 2> "$home/archive-duplicate.err" \
    || fail "an earlier non-conforming archived cycle blocked a durably resolved one: $(cat "$home/archive-duplicate.err")"

  {
    printf '## Archived 2026-07-15\n'
    printf '%s\n' "$record" | sed '/^  Decision digest:/d'
    printf '\n'
    sed '/^  Decision digest:/d' "$pristine"
  } > "$archive"
  if run_decisions "$home" verify "$origin" > "$home/archive-all-malformed.out" 2> "$home/archive-all-malformed.err"; then
    fail "verification accepted a duplicated identity whose every archived record is malformed"
  fi
  assert_grep "invalid decision digest" "$home/archive-all-malformed.err" \
    "an all-malformed duplicated identity did not fail on the invalid structured field"
  assert_no_grep "absent from the live backlog and configured archive" "$home/archive-all-malformed.err" \
    "a present-but-malformed archived identity must not also claim the record is absent"
  [ "$(grep -c '^fm-decision-hold:' "$home/archive-all-malformed.err")" = 1 ] \
    || fail "an all-malformed duplicated identity must emit exactly one accurate error: $(cat "$home/archive-all-malformed.err")"
  cp "$pristine" "$archive"

  # A home that re-used a decision key after retention pruning carries the identity
  # in both places. The live backlog is authoritative for open work, so a satisfied
  # live record must still verify - refusing it stranded such homes with no recovery
  # short of --force - while a live record that satisfies nothing still fails.
  tasks_in "$home" add "$hold" "Conflicting live archived route" --kind captain --repo sample >/dev/null \
    || fail "could not create live/archive reuse fixture"
  tasks_in "$home" hold "$hold" --reason "captain conflicting route pending" --kind captain >/dev/null \
    || fail "could not activate live/archive reuse fixture"
  run_decisions "$home" verify "$origin" > "$home/live-reuse.out" 2> "$home/live-reuse.err" \
    || fail "an archived earlier cycle blocked a satisfied live hold: $(cat "$home/live-reuse.err")"

  tasks_in "$home" unhold "$hold" >/dev/null \
    || fail "could not release the live/archive reuse fixture"
  if run_decisions "$home" verify "$origin" > "$home/live-unsatisfied.out" 2> "$home/live-unsatisfied.err"; then
    fail "an archived earlier cycle rescued a live record that satisfies nothing"
  fi
  assert_grep "neither actively held nor durably resolved" "$home/live-unsatisfied.err" \
    "an unsatisfied live record must fail on its own merits"

  pass "resolved archived holds verify on any complete structured archived cycle"
}

# tasks-axi treats [markdown] archive as optional and derives its own default from
# the resolved backlog path - done-archive.md beside that file, not a fixed data/
# location - so an absent key must not block teardown on a home whose backlog lives
# anywhere else. The backlog path here is deliberately outside data/, so a hardcoded
# default cannot pass. A key that is present but unparseable is a real
# misconfiguration and must still abort `verify` nonzero. markdown_config_value
# reports through a command substitution, so before the propagation fix a live
# active captain hold made `verify` print the config error yet exit 0, silently
# disabling the archive ambiguity and dedupe guards.
test_archive_config_absent_defaults_and_malformed_fails() {
  local home id
  home=$(make_home malformed-archive-config)
  id=sample-malformed-config-review
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
    || fail "could not create malformed-config origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Malformed archive config review\n' > "$home/data/$id/report.md"
  run_decisions "$home" hold "$id" route \
    --title "Choose malformed-config route" --reason "captain route pending" --repo sample >/dev/null \
    || fail "could not create live hold for malformed-config regression"
  run_decisions "$home" complete "$id" route >/dev/null \
    || fail "could not record inventory for malformed-config regression"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "live captain hold did not verify under valid archive config"

  # The absent-key fallback is only exercised once the record actually leaves the
  # live backlog, so close and prune the hold before dropping the key: verify now
  # passes only if the fallback resolves to the same file tasks-axi archived to.
  printf 'No follow-up work is needed.\n' > "$home/config-decision.txt"
  run_decisions "$home" decline "$id" route \
    --decision-file "$home/config-decision.txt" >/dev/null \
    || fail "could not close the hold before archive-config pruning"
  tasks_in "$home" prune --state "done" --keep 0 >/dev/null \
    || fail "could not prune the closed hold to the default archive"
  assert_no_grep "- [x] $id-decision-route -" "$home/notes/backlog.md" \
    "the closed hold remained in the live backlog after pruning"
  assert_grep "- [x] $id-decision-route -" "$home/notes/done-archive.md" \
    "tasks-axi did not archive the closed hold beside its configured backlog"
  assert_absent "$home/data/done-archive.md" \
    "tasks-axi archived to a fixed data/ path rather than beside its backlog"

  grep -v '^archive = ' "$home/.tasks.toml" > "$home/.tasks.toml.tmp"
  mv "$home/.tasks.toml.tmp" "$home/.tasks.toml"
  run_decisions "$home" verify "$id" > "$home/absent-config.out" 2> "$home/absent-config.err" \
    || fail "an absent optional archive key blocked verify on an archived hold: $(cat "$home/absent-config.err")"

  printf 'archive = notes/done-archive.md\n' >> "$home/.tasks.toml"
  if run_decisions "$home" verify "$id" > "$home/malformed-config.out" 2> "$home/malformed-config.err"; then
    fail "verify passed with a malformed markdown.archive config, silently disabling the archive guards"
  fi
  assert_grep "markdown.archive must be one unescaped quoted path" "$home/malformed-config.err" \
    "malformed archive config must fail verify with the config error"
  pass "an absent archive key derives the backend default while a malformed one fails verify"
}

# tasks-axi reads a home with no .tasks.toml at all, resolving its backlog to the
# first existing of backlog.md and data/backlog.md and archiving beside it. This
# gate must do the same rather than failing before any archive lookup is needed,
# because a hard failure here permanently blocks scout teardown on a home the
# backend itself accepts - for a live hold that never reads the archive as well as
# for one that has already been pruned into it.
test_absent_tasks_toml_falls_back_to_backend_defaults() {
  local home id
  home=$(make_home absent-tasks-toml)
  id=sample-absent-config-review
  rm -f "$home/.tasks.toml"
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review absent tasks config" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create absent-config origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Absent tasks config review\n' > "$home/data/$id/report.md"
  run_decisions "$home" hold "$id" route \
    --title "Choose absent-config route" --reason "captain route pending" --repo sample >/dev/null \
    || fail "an absent .tasks.toml blocked hold creation"
  run_decisions "$home" complete "$id" route >/dev/null \
    || fail "could not record inventory without a .tasks.toml"
  run_decisions "$home" verify "$id" > "$home/live-absent.out" 2> "$home/live-absent.err" \
    || fail "an absent .tasks.toml blocked verify on a live active hold: $(cat "$home/live-absent.err")"

  printf 'No follow-up work is needed.\n' > "$home/absent-config-decision.txt"
  run_decisions "$home" decline "$id" route \
    --decision-file "$home/absent-config-decision.txt" >/dev/null \
    || fail "could not close the hold without a .tasks.toml"
  tasks_in "$home" prune --state "done" --keep 0 >/dev/null \
    || fail "could not prune the closed hold without a .tasks.toml"
  assert_grep "- [x] $id-decision-route -" "$home/data/done-archive.md" \
    "tasks-axi did not archive beside the backlog it resolved without a config"
  run_decisions "$home" verify "$id" > "$home/archived-absent.out" 2> "$home/archived-absent.err" \
    || fail "an absent .tasks.toml blocked verify on an archived hold: $(cat "$home/archived-absent.err")"
  pass "an absent .tasks.toml falls back to the backend's own resolved defaults"
}

# tasks-axi's own TOML reader honors an inner-spaced section header, a trailing
# inline comment after the quoted value, and a repeated key whose last assignment
# wins, so this gate must resolve the same file the backend actually archived to
# rather than rejecting the config or silently falling back to a default archive
# that holds nothing.
test_archive_config_matches_backend_toml_spellings() {
  local home origin archive
  home=$(make_home archive-config-spellings)
  origin=sample-config-spelling-review
  archive="$home/data/decisions/spelled-archive.md"
  mkdir -p "$home/data/$origin" "$(dirname "$archive")"
  cat > "$home/.tasks.toml" <<'TOMLEOF'
backend = "markdown"

[ markdown ]
path = "data/backlog.md"
archive = "data/decisions/overridden-archive.md"
archive = "data/decisions/spelled-archive.md" # decisions stay out of the main archive
done_keep = 10
TOMLEOF
  tasks_in "$home" add "$origin" "Review archive config spellings" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create config-spelling origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Config spelling review\n' > "$home/data/$origin/report.md"
  run_decisions "$home" hold "$origin" route \
    --title "Choose config-spelling route" --reason "captain route pending" --repo sample >/dev/null \
    || fail "an inner-spaced section or trailing comment blocked hold creation"
  run_decisions "$home" complete "$origin" route >/dev/null \
    || fail "could not record the config-spelling inventory"
  printf 'No follow-up work is needed.\n' > "$home/spelling-config-decision.txt"
  run_decisions "$home" decline "$origin" route \
    --decision-file "$home/spelling-config-decision.txt" >/dev/null \
    || fail "could not close the config-spelling hold"
  tasks_in "$home" prune --state "done" --keep 0 >/dev/null \
    || fail "could not prune the config-spelling hold"
  assert_grep "- [x] $origin-decision-route -" "$archive" \
    "tasks-axi did not honor the inner-spaced, trailing-comment, last-wins archive path"
  assert_absent "$home/data/decisions/overridden-archive.md" \
    "tasks-axi did not take the last assignment of a repeated archive key"
  assert_absent "$home/data/done-archive.md" \
    "the configured archive path was ignored in favor of the default"
  run_decisions "$home" verify "$origin" > "$home/spelled-config.out" 2> "$home/spelled-config.err" \
    || fail "a backend-honored archive config spelling blocked verify: $(cat "$home/spelled-config.err")"
  pass "archive config spellings the backend honors also resolve for verify"
}

# The decline and repair close paths record the ROUTED_NONE `(none)` token rather
# than a routed-slug list, and tasks-axi stores the arbitrary captain decision text
# two-space-indented inside the same archived record. Ordinary Done retention
# pruning must not turn either into a permanently failing verify, which would block
# scout teardown with no way to rewrite the archived body.
test_unrouted_and_prose_heavy_archived_holds_verify() {
  local home origin archive declined repaired
  home=$(make_home archived-unrouted-hold)
  origin=sample-unrouted-archive-review
  archive="$home/data/done-archive.md"
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Review unrouted archived decisions" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create unrouted archive origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Unrouted archived decision review\n' > "$home/data/$origin/report.md"
  declined=$(run_decisions "$home" hold "$origin" declinedkey \
    --title "Choose declined route" --reason "captain declined route pending" --repo sample) \
    || fail "could not create the declined hold"
  repaired=$(run_decisions "$home" hold "$origin" repairedkey \
    --title "Choose repaired route" --reason "captain repaired route pending" --repo sample) \
    || fail "could not create the repaired hold"
  run_decisions "$home" hold "$origin" prosekey \
    --title "Choose prose route" --reason "captain prose route pending" --repo sample >/dev/null \
    || fail "could not create the prose hold"
  run_decisions "$home" complete "$origin" declinedkey repairedkey prosekey >/dev/null \
    || fail "could not record the unrouted decision inventory"

  printf 'No follow-up work is needed.\n' > "$home/declined-decision.txt"
  run_decisions "$home" decline "$origin" declinedkey \
    --decision-file "$home/declined-decision.txt" >/dev/null \
    || fail "could not decline the hold before pruning"

  tasks_in "$home" "done" "$repaired" >/dev/null \
    || fail "could not close the repaired hold outside the script"
  printf 'The captain already answered this out of band.\n' > "$home/repaired-decision.txt"
  run_decisions "$home" repair "$origin" repairedkey \
    --decision-file "$home/repaired-decision.txt" >/dev/null \
    || fail "could not repair the out-of-band close before pruning"

  # A decision about this very lifecycle: every structured marker also appears as
  # ordinary captain prose, so a whole-record uniqueness check would reject it.
  cat > "$home/prose-decision.txt" <<'EOF'
The archived record starts with the line
Resolution recorded by fm-decision-hold.
followed by
Decision digest: 0000000000000000000000000000000000000000000000000000000000000000
and
Routed identities: sample-not-a-real-route
and then
Captain decision:
and finally
Routed work:
Keep that grammar and take the northern route.
EOF
  run_decisions "$home" decline "$origin" prosekey \
    --decision-file "$home/prose-decision.txt" >/dev/null \
    || fail "could not decline the prose-heavy hold before pruning"

  run_decisions "$home" verify "$origin" >/dev/null \
    || fail "unrouted closed holds did not verify while still in the live backlog"

  tasks_in "$home" prune --state "done" --keep 0 >/dev/null \
    || fail "could not prune the closed holds to the default archive"
  assert_no_grep "- [x] $declined -" "$home/data/backlog.md" \
    "the declined hold remained in the live backlog after pruning"
  assert_grep "- [x] $declined -" "$archive" \
    "the declined hold did not reach the default archive"
  assert_grep "- [x] $repaired -" "$archive" \
    "the repaired hold did not reach the default archive"
  assert_grep "Routed identities: (none)" "$archive" \
    "the unrouted close paths did not record the (none) routed-identity token"

  run_decisions "$home" verify "$origin" > "$home/unrouted-verify.out" 2> "$home/unrouted-verify.err" \
    || fail "archived unrouted or prose-heavy holds failed verification: $(cat "$home/unrouted-verify.err")"
  pass "archived declined, repaired, and prose-heavy holds keep verifying after pruning"
}

# tasks-axi owns how a close is rendered: `done --pr` writes `(merged <date>)`,
# `done --report` writes `(reported <date>)`, and an `unhold` before or after the
# close drops the `(hold: ...)` and `(hold-kind: captain)` markers entirely. All
# three are documented out-of-band closes that `verify` accepts while the record
# is live, so ordinary Done retention pruning must not turn any of them into a
# permanently failing gate that no `repair` can rewrite.
test_out_of_band_close_spellings_survive_archiving() {
  local home origin archive merged reported unheld unheld_line
  home=$(make_home archived-close-spellings)
  origin=sample-close-spelling-review
  archive="$home/data/done-archive.md"
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Review out-of-band close spellings" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create close-spelling origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Close spelling review\n' > "$home/data/$origin/report.md"
  merged=$(run_decisions "$home" hold "$origin" mergedkey \
    --title "Choose merged route" --reason "captain merged route pending" --repo sample) \
    || fail "could not create the pr-closed hold"
  reported=$(run_decisions "$home" hold "$origin" reportedkey \
    --title "Choose reported route" --reason "captain reported route pending" --repo sample) \
    || fail "could not create the report-closed hold"
  unheld=$(run_decisions "$home" hold "$origin" unheldkey \
    --title "Choose unheld route" --reason "captain unheld route pending" --repo sample) \
    || fail "could not create the unheld hold"
  run_decisions "$home" complete "$origin" mergedkey reportedkey unheldkey >/dev/null \
    || fail "could not record the close-spelling decision inventory"
  printf 'The captain answered this out of band.\n' > "$home/spelling-decision.txt"

  tasks_in "$home" "done" "$merged" --pr https://github.com/sample/sample/pull/7 >/dev/null \
    || fail "could not close the hold with a pr link"
  run_decisions "$home" repair "$origin" mergedkey \
    --decision-file "$home/spelling-decision.txt" >/dev/null \
    || fail "could not repair the pr-closed hold"

  mkdir -p "$home/data/$reported"
  printf '# Reported route\n' > "$home/data/$reported/report.md"
  tasks_in "$home" "done" "$reported" --report "data/$reported/report.md" >/dev/null \
    || fail "could not close the hold with a report link"
  run_decisions "$home" repair "$origin" reportedkey \
    --decision-file "$home/spelling-decision.txt" >/dev/null \
    || fail "could not repair the report-closed hold"

  run_decisions "$home" decline "$origin" unheldkey \
    --decision-file "$home/spelling-decision.txt" >/dev/null \
    || fail "could not decline the hold before clearing its hold markers"
  tasks_in "$home" unhold "$unheld" >/dev/null \
    || fail "could not clear the hold markers on the closed decision"

  run_decisions "$home" verify "$origin" >/dev/null \
    || fail "out-of-band closed holds did not verify while still in the live backlog"

  tasks_in "$home" prune --state "done" --keep 0 >/dev/null \
    || fail "could not prune the out-of-band closed holds to the default archive"
  assert_grep "- [x] $merged -" "$archive" "the pr-closed hold did not reach the archive"
  assert_grep "(merged " "$archive" "tasks-axi did not render the pr close as merged"
  assert_grep "(reported " "$archive" "tasks-axi did not render the report close as reported"
  unheld_line=$(grep -F -- "- [x] $unheld -" "$archive") \
    || fail "the unheld closed hold did not reach the archive"
  case "$unheld_line" in
    *'hold-kind'*) fail "unhold did not clear the archived hold markers: $unheld_line" ;;
  esac

  run_decisions "$home" verify "$origin" > "$home/spelling-verify.out" 2> "$home/spelling-verify.err" \
    || fail "archived out-of-band closes failed verification: $(cat "$home/spelling-verify.err")"
  pass "archived pr, report, and unheld closes keep verifying after pruning"
}

# An archived record that is not a closed captain hold must still be refused, so
# the invariant-shaped header check cannot be satisfied by any archived task.
test_archived_non_captain_record_is_refused() {
  local home origin archive hold
  home=$(make_home archived-non-captain)
  origin=sample-non-captain-archive-review
  archive="$home/data/done-archive.md"
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Review non-captain archived record" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create non-captain archive origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Non-captain archive review\n' > "$home/data/$origin/report.md"
  hold=$(run_decisions "$home" hold "$origin" route \
    --title "Choose non-captain route" --reason "captain route pending" --repo sample) \
    || fail "could not create the hold for the non-captain archive fixture"
  run_decisions "$home" complete "$origin" route >/dev/null \
    || fail "could not record the non-captain archive inventory"
  printf 'No follow-up work is needed.\n' > "$home/non-captain-decision.txt"
  run_decisions "$home" decline "$origin" route \
    --decision-file "$home/non-captain-decision.txt" >/dev/null \
    || fail "could not close the hold before pruning"
  tasks_in "$home" prune --state "done" --keep 0 >/dev/null \
    || fail "could not prune the closed hold to the default archive"

  sed "s#^- \\[x\\] $hold - \\(.*\\)(kind: captain)#- [x] $hold - \\1(kind: ship)#" "$archive" \
    > "$archive.tmp"
  mv "$archive.tmp" "$archive"
  assert_no_grep "(kind: captain)" "$archive" "the non-captain archive fixture was not applied"
  if run_decisions "$home" verify "$origin" > "$home/non-captain.out" 2> "$home/non-captain.err"; then
    fail "verification accepted an archived record that is not a captain hold"
  fi
  assert_grep "is not a closed kind=captain hold" "$home/non-captain.err" \
    "archived non-captain record must fail with the kind error"
  pass "an archived record that is not a closed captain hold is refused"
}

# `hold` retires a decision key against the same invariant `verify` accepts, not
# against mere presence in the archive. A record that was pruned without a
# resolution block - an out-of-band close archived before `repair` ran, which
# `done_keep = 0` does on the very same close - fails `verify` forever, and no
# command can rewrite an archived body, so re-holding it is the only recovery.
# Refusing every archived identity stranded that origin with no way past teardown.
test_hold_retires_only_durably_resolved_archived_keys() {
  local home origin archive resolved stranded
  home=$(make_home archived-hold-retirement)
  origin=sample-retirement-review
  archive="$home/data/done-archive.md"
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Review archived hold retirement" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create retirement origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Retirement review\n' > "$home/data/$origin/report.md"
  resolved=$(run_decisions "$home" hold "$origin" resolvedkey \
    --title "Choose resolved route" --reason "captain resolved route pending" --repo sample) \
    || fail "could not create the resolved hold"
  stranded=$(run_decisions "$home" hold "$origin" strandedkey \
    --title "Choose stranded route" --reason "captain stranded route pending" --repo sample) \
    || fail "could not create the stranded hold"
  run_decisions "$home" complete "$origin" resolvedkey strandedkey >/dev/null \
    || fail "could not record the retirement decision inventory"

  printf 'No follow-up work is needed.\n' > "$home/retirement-decision.txt"
  run_decisions "$home" decline "$origin" resolvedkey \
    --decision-file "$home/retirement-decision.txt" >/dev/null \
    || fail "could not close the resolved hold"
  tasks_in "$home" "done" "$stranded" >/dev/null \
    || fail "could not reproduce the out-of-band close"
  tasks_in "$home" prune --state "done" --keep 0 >/dev/null \
    || fail "could not prune both closed holds to the archive"
  assert_grep "- [x] $resolved -" "$archive" "the resolved hold did not reach the archive"
  assert_grep "- [x] $stranded -" "$archive" "the out-of-band close did not reach the archive"

  if run_decisions "$home" verify "$origin" > "$home/stranded-verify.out" 2> "$home/stranded-verify.err"; then
    fail "verification accepted an archived close that recorded no captain decision"
  fi
  assert_grep "no unique fm-decision-hold resolution marker" "$home/stranded-verify.err" \
    "the archived unresolved close did not fail on its missing resolution record"
  if run_decisions "$home" repair "$origin" strandedkey \
    --decision-file "$home/retirement-decision.txt" \
    > "$home/stranded-repair.out" 2> "$home/stranded-repair.err"; then
    fail "repair rewrote a record that has already left the live backlog"
  fi
  assert_grep "is absent from" "$home/stranded-repair.err" \
    "repair did not report the archived record as absent from the live backlog"

  if run_decisions "$home" hold "$origin" resolvedkey \
    --title "Choose resolved route" --reason "captain resolved route again" --repo sample \
    > "$home/retired-hold.out" 2> "$home/retired-hold.err"; then
    fail "hold reopened a decision key whose archived record is durably resolved"
  fi
  assert_grep "already durably resolved in the configured tasks-axi archive" "$home/retired-hold.err" \
    "a resolved-and-pruned key was not refused as retired"

  run_decisions "$home" hold "$origin" strandedkey \
    --title "Choose stranded route" --reason "captain stranded route pending" --repo sample >/dev/null \
    || fail "an archived record that fails verify could not be re-held for recovery"
  run_decisions "$home" decline "$origin" strandedkey \
    --decision-file "$home/retirement-decision.txt" >/dev/null \
    || fail "could not record the captain decision on the recovered hold"
  run_decisions "$home" verify "$origin" > "$home/recovered-verify.out" 2> "$home/recovered-verify.err" \
    || fail "the recovered decision still failed verification: $(cat "$home/recovered-verify.err")"

  # Ordinary retention pruning then archives the recovered cycle beside the
  # unresolved one, so the archive legitimately holds two records of one identity.
  # The resolved cycle must keep attesting the answer.
  tasks_in "$home" prune --state "done" --keep 0 >/dev/null \
    || fail "could not prune the recovered hold to the archive"
  [ "$(grep -c "^- \[x\] $stranded - " "$archive")" = 2 ] \
    || fail "expected two archived cycles of the recovered identity, got $(grep -c "^- \[x\] $stranded - " "$archive")"
  run_decisions "$home" verify "$origin" > "$home/recovered-pruned.out" 2> "$home/recovered-pruned.err" \
    || fail "a second archived cycle of one decision key blocked verification: $(cat "$home/recovered-pruned.err")"
  if run_decisions "$home" hold "$origin" strandedkey \
    --title "Choose stranded route" --reason "captain stranded route pending" --repo sample \
    > "$home/recovered-rehold.out" 2> "$home/recovered-rehold.err"; then
    fail "hold reopened a key whose archive now carries a durably resolved cycle"
  fi
  assert_grep "already durably resolved in the configured tasks-axi archive" "$home/recovered-rehold.err" \
    "a recovered-and-pruned key was not retired by the same predicate verify accepts"
  run_teardown "$home" "$origin" >/dev/null 2> "$home/retirement-teardown.err" \
    || fail "teardown still refused after the stranded decision was recovered: $(cat "$home/retirement-teardown.err")"
  pass "hold retires only durably resolved archived keys and leaves the rest recoverable"
}

test_uninventoried_report_decision_refuses_completion

test_scout_teardown_always_requires_inventory_verification
test_declined_decision_closes_without_routed_work
test_out_of_band_close_is_repairable_before_teardown
test_unanswered_decision_still_blocks_completion_and_teardown
test_resolved_archived_hold_verification_is_strict
test_archive_config_absent_defaults_and_malformed_fails
test_absent_tasks_toml_falls_back_to_backend_defaults
test_archive_config_matches_backend_toml_spellings
test_unrouted_and_prose_heavy_archived_holds_verify
test_out_of_band_close_spellings_survive_archiving
test_archived_non_captain_record_is_refused
test_hold_retires_only_durably_resolved_archived_keys
test_structured_holds_survive_teardown_and_route_resolution
test_origin_slug_validation_precedes_path_construction
test_visual_review_uses_shared_completion_owner
test_none_inventory_and_resolved_prose_do_not_create_holds
test_terminal_single_owner_status_decision_does_not_block_empty_inventory
test_secondmate_hold_stays_in_authoritative_home
test_resolve_matches_quoted_blocked_by_edges
