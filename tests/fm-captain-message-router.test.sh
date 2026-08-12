#!/usr/bin/env bash
# Behavior tests for the captain-message continuity router (P0+P1 owner).
# Exercises the executable interface only: anchor extraction on settle, multi-ask
# verification, same/reroute/new classification on submit, session briefs,
# mocked ephemeral router agent, pending handoffs, verdict logging, primary
# scoping, gate inertness, and fail-open error paths. No real model calls.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset NO_MISTAKES_GATE

TMP_ROOT=$(fm_test_tmproot fm-captain-message-router)
ROUTER="$ROOT/bin/fm-captain-message-router.sh"
fm_git_identity fmtest fmtest@example.invalid

make_primary() {
	local dir=$1
	mkdir -p "$dir/bin" "$dir/state" "$dir/config"
	git init -q "$dir"
	git -C "$dir" commit -q --allow-empty -m init
	: >"$dir/AGENTS.md"
}

# run <root> <mode> [extra args...]: drive the router in <root> with stdin from the caller.
run() {
	local root=$1 mode=$2
	shift 2
	FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$root" FM_HOME="$root" \
		FM_CONFIG_OVERRIDE="$root/config" "$ROUTER" "$mode" "$@"
}

anchors_file() { printf '%s/state/captain-router/anchors.current' "$1"; }
verdicts_log() { printf '%s/state/captain-router/verdicts.log' "$1"; }
failures_log() { printf '%s/state/captain-router/failures.log' "$1"; }
brief_file() { printf '%s/state/captain-router/sessions/%s.brief' "$1" "$2"; }
pending_dir() { printf '%s/state/captain-router/pending' "$1"; }

write_mock_agent() {
	local root=$1 body=$2 path
	path="$root/mock-router-agent.sh"
	cat >"$path" <<EOF
#!/usr/bin/env bash
set -u
# Discard the prompt on stdin; emit a fixed verdict for tests.
cat >/dev/null
cat <<'VERDICT'
$body
VERDICT
EOF
	chmod +x "$path"
	printf '%s\n' "$path"
}

test_settle_extracts_multiple_anchors() {
	local root="$TMP_ROOT/settle-multi" out status=0 file
	make_primary "$root"
	out=$(printf 'Should I use option A for the router agent? And do you want me to start P0 now?' |
		run "$root" --on-settle 2>&1) || status=$?
	expect_code 0 "$status" "settle exit"
	[ -z "$out" ] || fail "settle with distinct questions must be silent, got: $out"
	file=$(anchors_file "$root")
	assert_present "$file" "anchors file must be written on settle"
	local count
	count=$(awk 'NF{c++} END{print c+0}' "$file")
	[ "$count" -eq 2 ] || fail "expected 2 distinct anchors, got $count"
	assert_grep "router agent" "$file" "first question anchor recorded"
	assert_grep "start p0 now" "$file" "second question anchor recorded"
	pass "router: settle extracts one anchor per distinct question"
}

test_settle_writes_session_brief() {
	local root="$TMP_ROOT/settle-brief" brief status=0
	make_primary "$root"
	printf 'Shall I start the blender export fix now?' |
		run "$root" --on-settle --session-id sess-alpha >/dev/null || status=$?
	expect_code 0 "$status" "settle-brief exit"
	brief=$(brief_file "$root" sess-alpha)
	assert_present "$brief" "session brief must be written on settle"
	assert_grep "session_id=sess-alpha" "$brief" "brief records session id"
	assert_grep "blender export fix" "$brief" "brief topic or anchors mention the ask"
	assert_present "$root/state/captain-router/current.session" "current.session pointer written"
	assert_grep "sess-alpha" "$root/state/captain-router/current.session" "current session recorded"
	pass "router: settle writes/refreshes a per-session brief"
}

test_settle_multi_ask_verification_surfaces() {
	local root="$TMP_ROOT/settle-mismatch" out status=0
	make_primary "$root"
	# Two questions, but identical -> only one distinct anchor survives dedup.
	out=$(printf 'Ready to go? Ready to go?' | run "$root" --on-settle 2>&1) || status=$?
	expect_code 0 "$status" "settle mismatch still exits 0 (never blocks)"
	assert_contains "$out" "multi-ask verification" "mismatch must surface a warning"
	assert_contains "$out" "2 question(s) asked but 1 distinct anchor(s)" "warning states the counts"
	pass "router: many asks with too few distinct anchors surfaces, never blocks"
}

test_settle_single_ask_is_silent() {
	local root="$TMP_ROOT/settle-single" out status=0
	make_primary "$root"
	out=$(printf 'Shall I start now?' | run "$root" --on-settle 2>&1) || status=$?
	expect_code 0 "$status" "single-ask settle exit"
	[ -z "$out" ] || fail "single-ask settle must be silent, got: $out"
	pass "router: a single question does not trigger multi-ask surfacing"
}

test_submit_matching_message_is_same() {
	local root="$TMP_ROOT/submit-same" out status=0
	make_primary "$root"
	printf 'Do you want me to start P0 implementation now?' |
		run "$root" --on-settle --session-id primary >/dev/null
	out=$(printf 'yes start the P0 implementation now please' |
		run "$root" --on-submit --session-id primary) || status=$?
	expect_code 0 "$status" "submit-same exit"
	assert_contains "$out" "verdict=same" "matching reply classifies as same"
	assert_contains "$out" "target=primary" "same targets the current session"
	assert_contains "$out" "confidence=det" "matching reply is deterministic"
	pass "router: a reply sharing salient tokens with an open anchor is same"
}

test_submit_unrelated_message_is_new() {
	local root="$TMP_ROOT/submit-new" out status=0 pending
	make_primary "$root"
	printf 'Do you want me to start P0 implementation now?' |
		run "$root" --on-settle --session-id primary >/dev/null
	out=$(printf 'the blender glb export pipeline is broken again' |
		run "$root" --on-submit --session-id primary) || status=$?
	expect_code 0 "$status" "submit-new exit"
	assert_contains "$out" "verdict=new" "unrelated message classifies as new"
	assert_contains "$out" "target=-" "new has no session target"
	assert_contains "$out" "confidence=det" "clear new is deterministic"
	pending=$(pending_dir "$root")
	assert_present "$pending/LATEST" "new stages a pending handoff pointer"
	local latest
	latest=$(cat "$pending/LATEST")
	assert_present "$pending/$latest" "pending route file exists"
	assert_grep "verdict=new" "$pending/$latest" "pending route records new"
	pass "router: an unrelated message is deterministic new and stages pending"
}

test_submit_without_anchors_is_new() {
	local root="$TMP_ROOT/submit-no-anchors" out status=0
	make_primary "$root"
	out=$(printf 'anything at all' | run "$root" --on-submit) || status=$?
	expect_code 0 "$status" "submit-no-anchors exit"
	assert_contains "$out" "verdict=new" "no anchors yet means new, never a crash"
	pass "router: submit before any settle is new and fail-open"
}

test_submit_unique_other_brief_is_reroute() {
	local root="$TMP_ROOT/submit-reroute" out status=0 pending latest
	make_primary "$root"
	printf 'Do you want me to start the blender glb export pipeline fix now?' |
		run "$root" --on-settle --session-id sess-blender >/dev/null
	printf 'Shall I merge the captain router PR today?' |
		run "$root" --on-settle --session-id sess-router >/dev/null
	out=$(printf 'please start the blender glb export pipeline fix now' |
		run "$root" --on-submit --session-id sess-router) || status=$?
	expect_code 0 "$status" "submit-reroute exit"
	assert_contains "$out" "verdict=reroute" "unique other-brief match is reroute"
	assert_contains "$out" "target=sess-blender" "reroute targets the matching session"
	assert_contains "$out" "confidence=det" "unique reroute is deterministic"
	pending=$(pending_dir "$root")
	latest=$(cat "$pending/LATEST")
	assert_grep "verdict=reroute" "$pending/$latest" "pending route records reroute"
	assert_grep "target=sess-blender" "$pending/$latest" "pending route records target"
	pass "router: unique other-session brief match is deterministic reroute"
}

test_submit_ambiguous_uses_mocked_model() {
	local root="$TMP_ROOT/submit-model" out status=0 mock
	make_primary "$root"
	printf 'Do you want me to start P0 implementation now?' |
		run "$root" --on-settle --session-id primary >/dev/null
	mock=$(write_mock_agent "$root" 'verdict=same target=primary confidence=model')
	# Short acknowledgement with open asks is ambiguous -> model path.
	out=$(printf 'yes' | FM_CAPTAIN_ROUTER_AGENT_CMD="$mock" run "$root" --on-submit --session-id primary) || status=$?
	expect_code 0 "$status" "submit-model exit"
	assert_contains "$out" "verdict=same" "mocked model verdict is consumed"
	assert_contains "$out" "confidence=model" "model confidence is preserved"
	pass "router: ambiguous short reply consumes a mocked model verdict"
}

test_submit_model_spawn_failure_fail_open() {
	local root="$TMP_ROOT/submit-failopen" out status=0 log
	make_primary "$root"
	printf 'Do you want me to start P0 implementation now?' |
		run "$root" --on-settle --session-id primary >/dev/null
	# Ambiguous short reply forces model path; override command fails.
	out=$(printf 'ok' | FM_CAPTAIN_ROUTER_AGENT_CMD='false' run "$root" --on-submit --session-id primary) || status=$?
	expect_code 0 "$status" "fail-open still exits 0"
	assert_contains "$out" "verdict=same" "spawn failure allows into current primary"
	assert_contains "$out" "target=primary" "fail-open targets current session"
	log=$(failures_log "$root")
	assert_present "$log" "failures.log records the spawn failure"
	pass "router: router spawn failure fail-opens as same and records failure"
}

test_continuity_role_from_crew_dispatch() {
	local root="$TMP_ROOT/role-config" out status=0 mock seen
	make_primary "$root"
	printf '%s\n' '{
  "roles": {
    "continuity": { "harness": "pi", "model": "cursor/grok-4.5", "effort": "low" }
  }
}' >"$root/config/crew-dispatch.json"
	printf 'Do you want me to start P0 implementation now?' |
		run "$root" --on-settle --session-id primary >/dev/null
	seen="$root/mock-seen-prompt.txt"
	mock="$root/mock-echo-agent.sh"
	cat >"$mock" <<EOF
#!/usr/bin/env bash
set -u
cat >"$seen"
printf 'verdict=new target=- confidence=model\n'
EOF
	chmod +x "$mock"
	out=$(printf 'yep' | FM_CAPTAIN_ROUTER_AGENT_CMD="$mock" run "$root" --on-submit --session-id primary) || status=$?
	expect_code 0 "$status" "role-config exit"
	assert_contains "$out" "verdict=new" "mocked agent under continuity role works"
	assert_present "$seen" "mock agent received a prompt"
	assert_grep "Current session id: primary" "$seen" "prompt includes current session"
	pass "router: continuity role path is exercised through the mockable agent command"
}

test_verdict_is_logged() {
	local root="$TMP_ROOT/verdict-log" log
	make_primary "$root"
	printf 'Do you want me to start P0 now?' | run "$root" --on-settle >/dev/null
	printf 'yes start P0 now' | run "$root" --on-submit >/dev/null
	printf 'unrelated blender thing' | run "$root" --on-submit >/dev/null
	log=$(verdicts_log "$root")
	assert_present "$log" "verdict log must exist after submits"
	local lines
	lines=$(awk 'END{print NR}' "$log")
	[ "$lines" -eq 2 ] || fail "expected 2 verdict rows, got $lines"
	assert_grep "same" "$log" "same verdict recorded"
	assert_grep "new" "$log" "new verdict recorded"
	pass "router: every submit verdict is appended to the log"
}

test_inert_in_child_worktree() {
	local base="$TMP_ROOT/child-base" root="$TMP_ROOT/child-worktree" out status=0
	fm_git_worktree "$base" "$root" fm/captain-router-child
	mkdir -p "$root/bin" "$root/state"
	: >"$root/AGENTS.md"
	out=$(printf 'anything' | run "$root" --on-submit 2>&1) || status=$?
	expect_code 0 "$status" "child worktree exit"
	[ -z "$out" ] || fail "unmarked child worktree must be silent, got: $out"
	assert_absent "$root/state/captain-router" "child worktree must not create router state"
	pass "router: inert in a child crew/scout worktree"
}

test_marked_secondmate_home_is_active() {
	local base="$TMP_ROOT/sm-base" root="$TMP_ROOT/sm-home" out status=0
	fm_git_worktree "$base" "$root" fm/captain-router-sm
	mkdir -p "$root/bin" "$root/state"
	: >"$root/AGENTS.md"
	printf 'captain-router-sm\n' >"$root/.fm-secondmate-home"
	printf 'Do you want me to proceed now?' | run "$root" --on-settle >/dev/null
	out=$(printf 'yes proceed now' | run "$root" --on-submit) || status=$?
	expect_code 0 "$status" "secondmate home exit"
	assert_contains "$out" "verdict=same" "a marked secondmate home is an active primary"
	pass "router: a marked secondmate home is treated as a primary"
}

test_gate_agent_is_inert() {
	local root="$TMP_ROOT/gate-env" out status=0
	make_primary "$root"
	out=$(printf 'anything' | env NO_MISTAKES_GATE=1 FM_GATE_REFUSE_BYPASS=0 \
		FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$ROUTER" --on-submit 2>&1) || status=$?
	expect_code 0 "$status" "gate agent exit"
	[ -z "$out" ] || fail "a no-mistakes gate agent must be silent, got: $out"
	assert_absent "$root/state/captain-router" "gate agent must not create router state"
	pass "router: a no-mistakes gate agent is inert"
}

test_bad_usage_exits_two() {
	local root="$TMP_ROOT/bad-usage" status=0
	make_primary "$root"
	printf '' | run "$root" --bogus >/dev/null 2>&1 || status=$?
	expect_code 2 "$status" "invalid mode is a usage error"
	status=0
	printf '' | FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$root" FM_HOME="$root" \
		"$ROUTER" >/dev/null 2>&1 || status=$?
	expect_code 2 "$status" "missing mode is a usage error"
	pass "router: invalid CLI usage exits 2 (only non-fail-open path)"
}

test_help_prints_usage() {
	local out status=0
	out=$("$ROUTER" --help 2>&1) || status=$?
	expect_code 0 "$status" "help exit"
	assert_contains "$out" "Captain-message continuity router" "help prints the header"
	assert_contains "$out" "NOT watcher continuity" "help disambiguates from watcher continuity"
	assert_contains "$out" "reroute" "help mentions reroute verdicts"
	pass "router: --help prints the script header"
}

test_settle_extracts_multiple_anchors
test_settle_writes_session_brief
test_settle_multi_ask_verification_surfaces
test_settle_single_ask_is_silent
test_submit_matching_message_is_same
test_submit_unrelated_message_is_new
test_submit_without_anchors_is_new
test_submit_unique_other_brief_is_reroute
test_submit_ambiguous_uses_mocked_model
test_submit_model_spawn_failure_fail_open
test_continuity_role_from_crew_dispatch
test_verdict_is_logged
test_inert_in_child_worktree
test_marked_secondmate_home_is_active
test_gate_agent_is_inert
test_bad_usage_exits_two
test_help_prints_usage
