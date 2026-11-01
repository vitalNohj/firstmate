#!/usr/bin/env bash
# tests/fm-backend-pi-pocket.test.sh - fake-bridge tests for the Pocket worker
# adapter (bin/backends/pi-pocket.sh), its client bin/fm-pi-pocket-bridge.mjs,
# and the fm-spawn, fm-control, and fm-teardown paths on backend=pi-pocket.
# The fake is tests/pi-pocket-fake-bridge.mjs, which serves the drop-in's
# request/result queue from a per-case world.json and logs every request, so
# no test starts or reaches a Pi Pocket server. The drop-in's own side of the
# bridge (trust, model and spend gates, run events, the restart nudge) runs in
# a real Pi Pocket app in tests/fm-pi-pocket-dropin.test.sh.
# shellcheck disable=SC2016  # $1/$2 inside single quotes belong to the bash -c snippet pp_run forwards.
set -u

unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_PARAMETERS \
  FM_TASK_ID FM_TASK_INBOX FM_HOME FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node absent"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-backend-pi-pocket-tests)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
fm_fake_exit0 "$FAKEBIN" treehouse
export PATH="$FAKEBIN:$PATH"
FAKE="$ROOT/tests/pi-pocket-fake-bridge.mjs"
FAKE_PID=
# The identity a command of the main Pi Pocket session carries.
export FM_PI_POCKET_CONVERSATION=7 FM_PI_POCKET_SERVER_PID=4242
TASK_IDS="$TMP_ROOT/task-ids"
RUN_TAG=$(printf '%05x%04x' "$(( $$ % 1048576 ))" "$RANDOM")

cleanup() {
  fake_stop
  if [ -f "$TASK_IDS" ]; then
    while IFS= read -r id; do
      [ -z "$id" ] || rm -rf "/tmp/fm-$id"
    done < "$TASK_IDS"
  fi
  fm_test_cleanup
}
trap cleanup EXIT

uid() {  # <base> -> <base><run-tag>, recorded for cleanup
  printf '%s\n' "$1$RUN_TAG" >> "$TASK_IDS"
  printf '%s' "$1$RUN_TAG"
}

fake_stop() {
  [ -n "$FAKE_PID" ] || return 0
  kill "$FAKE_PID" 2>/dev/null || true
  wait "$FAKE_PID" 2>/dev/null || true
  FAKE_PID=
}

# pp_case <name> [world-json]: a fresh case directory with its own state,
# world, and request log, served by a fresh fake bridge.
pp_case() {
  fake_stop
  CASE_DIR="$TMP_ROOT/$1"
  STATE="$CASE_DIR/state"
  CONFIG="$CASE_DIR/config"
  WORLD="$CASE_DIR/world.json"
  LOG="$CASE_DIR/requests.jsonl"
  mkdir -p "$STATE" "$CONFIG"
  printf '%s\n' "${2:-{\}}" > "$WORLD"
  : > "$LOG"
  node "$FAKE" --state "$STATE" --world "$WORLD" --log "$LOG" --server "$FM_PI_POCKET_SERVER_PID" \
    --conversation "$FM_PI_POCKET_CONVERSATION" --parent-pid "$$" >"$CASE_DIR/fake.out" 2>&1 &
  FAKE_PID=$!
  local _
  for _ in $(seq 1 100); do
    [ -s "$STATE/pocket-bridge/heartbeat.json" ] && return 0
    sleep 0.05
  done
  fail "the fake bridge did not start: $(cat "$CASE_DIR/fake.out" 2>/dev/null)"
}

# pp_run <snippet> [args...]: run <snippet> with the pi-pocket adapter loaded.
pp_run() {
  local snippet=$1
  shift
  FM_CONFIG_OVERRIDE="$CONFIG" FM_STATE_OVERRIDE="$STATE" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source pi-pocket || exit 1; '"$snippet" "$ROOT" "$@"
}

# pp_world <js over w>: one value from the current world.
pp_world() {
  node -e '
const w = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const v = eval(process.argv[2]);
process.stdout.write(typeof v === "string" ? v : String(JSON.stringify(v)));
' "$WORLD" "$1"
}

# pp_set <js over w>: change the world in place.
pp_set() {
  node -e '
const fs = require("fs");
const file = process.argv[1];
const w = JSON.parse(fs.readFileSync(file, "utf8"));
eval(process.argv[2]);
fs.writeFileSync(file + ".tmp", JSON.stringify(w));
fs.renameSync(file + ".tmp", file);
' "$WORLD" "$1"
}

pp_verbs() {  # the mutating verbs the fake took, in order (reads omitted)
  node -e '
const lines = require("fs").readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean);
const reads = new Set(["status", "state", "capture"]);
process.stdout.write(lines.map((l) => JSON.parse(l).verb).filter((v) => !reads.has(v)).join(" "));
' "$LOG"
}

# --- adapter primitives -----------------------------------------------------

test_registered_explicit_only() {
  local out
  out=$(bash -c '. "$1/bin/fm-backend.sh"; printf "%s|%s" "$FM_BACKEND_KNOWN" "$FM_BACKEND_SPAWN"' _ "$ROOT")
  assert_contains "${out%%|*}" pi-pocket "pi-pocket must be a known backend"
  assert_contains "${out#*|}" pi-pocket "pi-pocket must be spawn-capable"
  out=$(env -u FM_PI_POCKET_CONVERSATION -u FM_PI_POCKET_SERVER_PID FM_CONFIG_OVERRIDE="$TMP_ROOT/no-config" \
    bash -c '. "$1/bin/fm-backend.sh"; fm_backend_detect 2>/dev/null || true' _ "$ROOT")
  [ "$out" != pi-pocket ] || fail "pi-pocket must never be auto-detected"
  pass "registry: pi-pocket is known and spawn-capable, never auto-detected"
}

test_runtime_check_needs_bridge_and_identity() {
  local out rc
  pp_case runtime
  pp_run 'fm_backend_runtime_check pi-pocket' >/dev/null 2>&1 || fail "runtime check must pass while the bridge answers"
  out=$(env -u FM_PI_POCKET_CONVERSATION FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$CONFIG" \
    bash -c '. "$1/bin/fm-backend.sh"; fm_backend_runtime_check pi-pocket' _ "$ROOT" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "runtime check must refuse a command without a Pi Pocket identity"
  assert_contains "$out" "carries no Pi Pocket identity" "the refusal must say why"
  pp_set 'w.down = true'
  sleep 0.1
  node -e 'const fs=require("fs");const p=process.argv[1];const h=JSON.parse(fs.readFileSync(p,"utf8"));h.at=0;fs.writeFileSync(p,JSON.stringify(h))' \
    "$STATE/pocket-bridge/heartbeat.json"
  out=$(pp_run 'fm_backend_runtime_check pi-pocket' 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "runtime check must refuse when the drop-in's bridge is not running"
  assert_contains "$out" "worker bridge is not running" "the refusal must name the missing bridge"
  pass "runtime check: needs the main session's identity and a live drop-in bridge"
}

test_worker_lifecycle_without_stop() {
  local session out
  pp_case lifecycle '{"models":["faux/faux-1","faux/faux-2"]}'
  mkdir -p "$CASE_DIR/wt"
  session=$(pp_run 'fm_backend_pi_pocket_session_start "$1" "$2" faux/faux-2 high "channel statement" "web_fetch,team"' ppx "$CASE_DIR/wt") \
    || fail "session start must succeed"
  [ "$session" = 100 ] || fail "session start must print the session id, got '$session'"
  [ "$(pp_world 'w.workers["100"].model')" = faux/faux-2 ] || fail "the start must carry the dispatch model"
  [ "$(pp_world 'w.workers["100"].thinking')" = high ] || fail "the start must carry the effort"
  [ "$(pp_world 'w.workers["100"].cwd')" = "$CASE_DIR/wt" ] || fail "the start must run in the worktree"
  [ "$(pp_world 'w.workers["100"].excludeTools.join(",")')" = web_fetch,team ] || fail "the start must carry the excluded tools"
  [ "$(pp_world 'w.workers["100"].prompt')" = "channel statement" ] || fail "the start must carry the channel statement"
  pp_run 'fm_backend_pi_pocket_configure 100 FM_TASK_ID=ppx "FM_TASK_INBOX=/s/ppx.inbox"' || fail "configure must succeed"
  [ "$(pp_world 'w.workers["100"].env.FM_TASK_INBOX')" = /s/ppx.inbox ] || fail "configure must give the worker its task env"

  [ "$(pp_run 'fm_backend_send_text_submit pi-pocket 100 "hello worker" 1 0 0')" = empty ] || fail "a send must be accepted"
  [ "$(pp_world 'w.workers["100"].submissions[0].text')" = "hello worker" ] || fail "the send must be submitted"
  [ "$(pp_world 'w.workers["100"].submissions[0].whenBusy')" = followUp ] || fail "a steer queues as a follow-up while busy"
  out=$(pp_run 'fm_backend_capture pi-pocket 100 5')
  assert_contains "$out" "user: hello worker" "capture must print the transcript tail"

  [ "$(pp_run 'fm_backend_busy_state pi-pocket 100')" = idle ] || fail "an idle worker reads idle"
  pp_set 'w.workers["100"].busy = true'
  [ "$(pp_run 'fm_backend_busy_state pi-pocket 100')" = busy ] || fail "a running worker reads busy"
  [ "$(pp_run 'fm_backend_agent_state pi-pocket 100')" = alive ] || fail "a running worker is alive"
  [ "$(pp_run 'fm_backend_pi_pocket_native_interrupt 100')" = confirmed ] || fail "an interrupt of a running worker is confirmed"
  [ "$(pp_world 'w.workers["100"].aborts')" = 1 ] || fail "the interrupt must abort the run"
  pp_run 'fm_backend_send_key pi-pocket 100 Escape' || fail "Escape must be an abort"
  [ "$(pp_world 'w.workers["100"].aborts')" = 2 ] || fail "Escape must abort"
  pp_run 'fm_backend_send_key pi-pocket 100 Enter' || fail "Enter must be a no-op"
  [ "$(pp_world 'w.workers["100"].aborts')" = 2 ] || fail "Enter must not abort"
  pp_run 'fm_backend_send_key pi-pocket 100 C-u' 2>/dev/null && fail "Ctrl-U has no meaning here and must refuse"

  pp_set 'w.workers["100"].failed = "the provider refused"'
  [ "$(pp_run 'fm_backend_agent_state pi-pocket 100')" = dead ] || fail "a failed run reads dead"
  pp_set 'delete w.workers["100"].failed'

  pp_run 'fm_backend_kill pi-pocket 100' || fail "kill must succeed without stop/archive"
  [ "$(pp_world 'w.workers["100"].retired')" = true ] || fail "kill without stop/archive must retire the worker"
  [ "$(pp_world 'w.workers["100"].aborts')" = 3 ] || fail "kill without stop/archive must abort its run"
  [ "$(pp_run 'fm_backend_agent_state pi-pocket 100')" = missing ] || fail "a retired worker reads missing"
  out=$(pp_run 'fm_backend_send_text_submit pi-pocket 100 "after teardown" 1 0 0' 2>&1)
  assert_contains "$out" "send-failed" "a send to a retired worker must fail"
  assert_contains "$out" "retired" "the refusal must say the worker was torn down"
  [ "$(pp_world 'w.workers["100"].submissions.length')" = 1 ] || fail "nothing reaches a retired worker"
  pp_run 'fm_backend_kill pi-pocket 100' || fail "a repeated kill is idempotent"
  pp_run 'fm_backend_kill pi-pocket 999' || fail "killing an unknown session is already the end state"
  pass "adapter: start, configure, send, capture, state, interrupt, keys, failed run, and kill-as-retire with send refusal"
}

test_kill_with_stop_archives() {
  pp_case kill-archive '{"stop":true}'
  mkdir -p "$CASE_DIR/wt"
  pp_run 'fm_backend_pi_pocket_session_start ppa "$1" "" "" "" ""' "$CASE_DIR/wt" >/dev/null || fail "start must succeed"
  [ "$(pp_world 'w.workers["100"].model')" = faux/faux-1 ] || fail "a start without a model takes the first listed one"
  pp_run 'fm_backend_kill pi-pocket 100' || fail "kill must succeed"
  [ "$(pp_world 'w.workers["100"].archived')" = true ] || fail "kill with stop/archive must archive"
  [ "$(pp_world 'w.workers["100"].retired')" = undefined ] || fail "an archived worker is not merely retired"
  pass "adapter: kill stops and archives when Pi Pocket has linked-session stop and archive"
}

test_model_and_spend_refusals() {
  local out rc
  pp_case refusals '{"models":["faux/faux-1"]}'
  mkdir -p "$CASE_DIR/wt"
  out=$(pp_run 'fm_backend_pi_pocket_session_start ppr "$1" other/model "" "" ""' "$CASE_DIR/wt" 2>&1); rc=$?
  expect_code 3 "$rc" "a start on an unlisted model must be the drop-in's refusal"
  assert_contains "$out" "not on the owner's subagent model list" "the refusal must name the model list"
  pp_run 'fm_backend_pi_pocket_session_start ppr "$1" faux/faux-1 "" "" ""' "$CASE_DIR/wt" >/dev/null || fail "a listed model must start"
  pp_set 'w.models = ["faux/faux-2"]'
  out=$(pp_run 'fm_backend_send_text_submit pi-pocket 100 steer 1 0 0' 2>&1)
  assert_contains "$out" "send-failed" "a submit after the model left the list must fail"
  assert_contains "$out" "model:" "the refusal must carry the model code"
  pp_set 'w.models = ["faux/faux-1"]; w.held = "the daily budget is spent"'
  out=$(pp_run 'fm_backend_send_text_submit pi-pocket 100 steer 1 0 0' 2>&1)
  assert_contains "$out" "send-failed" "a submit while spend is held must fail"
  assert_contains "$out" "held: Pi Pocket holds this work back: the daily budget is spent" "the refusal must name the hold"
  [ "$(pp_world 'w.workers["100"].submissions.length')" = 0 ] || fail "a refused submit sends nothing"
  pass "adapter: an unlisted model and a spend hold are refused as blockers, before any submit"
}

test_unanswered_send_is_unconfirmed_and_retry_safe() {
  local out rc
  pp_case unanswered
  mkdir -p "$CASE_DIR/wt"
  pp_run 'fm_backend_pi_pocket_session_start ppu "$1" "" "" "" ""' "$CASE_DIR/wt" >/dev/null || fail "start must succeed"
  pp_set 'w.silent = true'
  out=$(node "$ROOT/bin/fm-pi-pocket-bridge.mjs" send --state "$STATE" --session 100 --text x --request-id r1 --timeout-ms 300 2>&1); rc=$?
  expect_code 7 "$rc" "an unanswered send must exit 7"
  assert_contains "$out" "did not answer send" "the timeout must say so"
  pp_set 'w.silent = false'
  node "$ROOT/bin/fm-pi-pocket-bridge.mjs" send --state "$STATE" --session 100 --text x --request-id r1 >/dev/null || fail "retry must succeed"
  node "$ROOT/bin/fm-pi-pocket-bridge.mjs" send --state "$STATE" --session 100 --text x --request-id r1 >/dev/null || fail "a repeat must succeed"
  [ "$(pp_world 'w.workers["100"].submissions.length')" = 1 ] || fail "the same request id submits once"
  pass "client: an unanswered send exits 7, and a retry with the same request id submits once"
}

# --- fm-spawn, fm-control, fm-teardown ----------------------------------------

make_treehouse_fakebin() {  # <dir> -> fakebin that leases $FM_PP_WT and logs
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_PP_TREEHOUSE_LOG:?}"
case "${1:-}" in get) printf '%s\n' "${FM_PP_WT:?}" ;; esac
exit 0
SH
  chmod +x "$fb/treehouse"
  printf '%s\n' "$fb"
}

write_spawn_brief() {  # <data-dir> <id>
  mkdir -p "$1/$2"
  cat > "$1/$2/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise Pocket dispatch.

## Firstmate spec
Verify the Pocket lifecycle under test.
EOF
}

pp_spawn_setup() {  # <id> -> sets PROJ WT DATA FB
  PROJ="$CASE_DIR/project"
  WT="$CASE_DIR/wt"
  DATA="$CASE_DIR/data"
  fm_git_worktree "$PROJ" "$WT" "fm/$1"
  mkdir -p "$CASE_DIR/home/state"
  write_spawn_brief "$DATA" "$1"
  touch "$STATE/.last-watcher-beat"
  FB=$(make_treehouse_fakebin "$CASE_DIR")
}

pp_spawn() {  # <id> [fm-spawn args...]
  local id=$1
  shift
  HOME="$CASE_DIR/user-home" PATH="$FB:$PATH" FM_PP_TREEHOUSE_LOG="$CASE_DIR/treehouse.log" FM_PP_WT="$WT" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CASE_DIR/home" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    FM_CONFIG_OVERRIDE="$CONFIG" FM_PROJECTS_OVERRIDE="$CASE_DIR/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$PROJ" pi "$@" 2>&1
}

test_spawn_starts_session_and_submits_brief() {
  local id out rc
  id=$(uid ppspawn)
  pp_case spawn '{"models":["faux/faux-1"]}'
  pp_spawn_setup "$id"
  out=$(pp_spawn "$id" --scout --model faux/faux-1 --effort low --backend pi-pocket); rc=$?
  expect_code 0 "$rc" "fm-spawn --backend pi-pocket must succeed against the fake bridge"$'\n'"$out"
  assert_grep "backend=pi-pocket" "$STATE/$id.meta" "meta must record the backend"
  assert_grep "pocket_session=100" "$STATE/$id.meta" "meta must record the Pocket session"
  assert_grep "window=fm-$id" "$STATE/$id.meta" "meta must record the stable label"
  assert_grep "worktree=$WT" "$STATE/$id.meta" "meta must record the leased worktree"
  assert_grep "get --lease --lease-holder $id" "$CASE_DIR/treehouse.log" "spawn must lease the worktree"
  [ "$(pp_world 'w.workers["100"].cwd')" = "$WT" ] || fail "the session must start in the worktree"
  [ "$(pp_world 'w.workers["100"].model')" = faux/faux-1 ] || fail "the session must run on the dispatch model"
  [ "$(pp_world 'w.workers["100"].thinking')" = low ] || fail "the session must run on the dispatch effort"
  assert_contains "$(pp_world 'w.workers["100"].prompt')" "task worker launched by Firstmate" "the session prompt must carry the channel statement"
  [ "$(pp_world 'w.workers["100"].env.FM_TASK_ID')" = "$id" ] || fail "the worker's commands must carry FM_TASK_ID"
  [ "$(pp_world 'w.workers["100"].env.FM_TASK_INBOX')" = "$STATE/$id.inbox" ] || fail "the worker's commands must carry the task inbox"
  [ "$(pp_world 'w.workers["100"].env.GOTMPDIR')" = "/tmp/fm-$id/gotmp" ] || fail "the worker's commands must carry GOTMPDIR"
  [ "$(pp_world 'w.workers["100"].submissions.length')" = 1 ] || fail "spawn must submit exactly the launch brief"
  assert_contains "$(pp_world 'w.workers["100"].submissions[0].text')" "FIRSTMATE_OP: v1 launch-brief:" "the brief must be the encoded launch brief"
  assert_contains "$(pp_world 'w.workers["100"].submissions[0].text')" "Verify the Pocket lifecycle under test." "the brief must carry its body"
  case "$(pp_world 'w.workers["100"].submissions[0].requestId')" in "fm-launch-$id-"*) ;; *) fail "the brief must carry a launch request id" ;; esac
  [ "$(head -1 "$LOG" | node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(0,"utf8")).verb)')" = status ] \
    || fail "spawn must check the bridge before anything else"
  [ "$(pp_verbs)" = "spawn configure send" ] || fail "spawn must start, configure, then submit, got '$(pp_verbs)'"
  [ -e "$STATE/$id.busy-gen" ] || fail "spawn must arm the busy contract"

  # fm-control: an interrupt is an abort.
  pp_set 'w.workers["100"].busy = true'
  out=$(FM_HOME="$CASE_DIR/home" FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$CONFIG" FM_DATA_OVERRIDE="$DATA" \
    "$ROOT/bin/fm-control.sh" "$id" interrupt 2>&1) || fail "fm-control interrupt must succeed"$'\n'"$out"
  [ "$(pp_world 'w.workers["100"].aborts')" = 1 ] || fail "fm-control interrupt must abort the run"$'\n'"$out"

  # fm-teardown: the session is torn down through the adapter.
  printf 'report\n' > "$DATA/$id/report.md"
  printf 'decisions_reviewed=1\ndecision_keys=\n' >> "$STATE/$id.meta"
  out=$(HOME="$CASE_DIR/user-home" PATH="$FB:$PATH" FM_PP_TREEHOUSE_LOG="$CASE_DIR/treehouse.log" FM_PP_WT="$WT" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CASE_DIR/home" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" FM_CONFIG_OVERRIDE="$CONFIG" \
    FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-teardown.sh" "$id" 2>&1); rc=$?
  expect_code 0 "$rc" "teardown must succeed"$'\n'"$out"
  [ "$(pp_world 'w.workers["100"].retired')" = true ] || fail "teardown must retire the session without stop/archive"$'\n'"$out"
  pass "fm-spawn/fm-control/fm-teardown --backend pi-pocket: lease, neutral start, task env, brief submit, abort, retire"
}

test_spawn_refuses_without_bridge_and_never_falls_back() {
  local id out rc
  id=$(uid ppdown)
  pp_case spawn-down
  fake_stop
  rm -f "$STATE/pocket-bridge/heartbeat.json"
  pp_spawn_setup "$id"
  out=$(pp_spawn "$id" --scout --model faux/faux-1 --backend pi-pocket); rc=$?
  [ "$rc" -ne 0 ] || fail "a spawn without the drop-in's bridge must refuse"$'\n'"$out"
  assert_contains "$out" "worker bridge is not running" "the refusal must name the missing bridge"
  assert_absent "$STATE/$id.meta" "a refused spawn records nothing"
  [ ! -s "$CASE_DIR/treehouse.log" ] || fail "a refused spawn must not lease a worktree"
  pass "fm-spawn --backend pi-pocket: no bridge is a blocker before any lease, never a fallback"
}

test_spawn_refused_start_returns_lease() {
  local id out rc
  id=$(uid ppheld)
  pp_case spawn-held '{"held":"the session budget is spent"}'
  pp_spawn_setup "$id"
  out=$(pp_spawn "$id" --scout --model faux/faux-1 --backend pi-pocket); rc=$?
  [ "$rc" -ne 0 ] || fail "a held spawn must refuse"$'\n'"$out"
  assert_contains "$out" "Pi Pocket holds this session back: the session budget is spent" "the refusal must name the hold"
  assert_contains "$out" "never falls back" "the refusal must say there is no fallback"
  assert_absent "$STATE/$id.meta" "a refused spawn records nothing"
  assert_grep "return --force $WT" "$CASE_DIR/treehouse.log" "a refused start must hand the lease back"
  [ "$(pp_world 'Object.keys(w.workers || {}).length')" = 0 ] || fail "no session may exist"
  pass "fm-spawn --backend pi-pocket: a refused start (spend hold) is a blocker and returns the lease"
}

test_spawn_refuses_secondmate_and_other_harness() {
  local id out rc
  id=$(uid ppharn)
  pp_case spawn-harness
  pp_spawn_setup "$id"
  out=$(HOME="$CASE_DIR/user-home" PATH="$FB:$PATH" FM_PP_TREEHOUSE_LOG="$CASE_DIR/treehouse.log" FM_PP_WT="$WT" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CASE_DIR/home" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    FM_CONFIG_OVERRIDE="$CONFIG" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$PROJ" claude --scout --model claude-sonnet-5 --backend pi-pocket 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a non-pi harness must refuse on pi-pocket"
  assert_contains "$out" "runs only Pi Pocket's own agent" "the refusal must name the harness rule"
  assert_absent "$STATE/$id.meta" "a refused spawn records nothing"
  pass "fm-spawn --backend pi-pocket: refuses a harness other than pi"
}

test_registered_explicit_only
test_runtime_check_needs_bridge_and_identity
test_worker_lifecycle_without_stop
test_kill_with_stop_archives
test_model_and_spend_refusals
test_unanswered_send_is_unconfirmed_and_retry_safe
test_spawn_starts_session_and_submits_brief
test_spawn_refuses_without_bridge_and_never_falls_back
test_spawn_refused_start_returns_lease
test_spawn_refuses_secondmate_and_other_harness
