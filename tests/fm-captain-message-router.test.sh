#!/usr/bin/env bash
# Behavior tests for the captain-message continuity router (P0 owner).
# Exercises the executable interface only: anchor extraction on settle, multi-ask
# verification, same/unknown classification on submit, verdict logging, primary
# scoping, gate inertness, and fail-open error paths.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset NO_MISTAKES_GATE

TMP_ROOT=$(fm_test_tmproot fm-captain-message-router)
ROUTER="$ROOT/bin/fm-captain-message-router.sh"
fm_git_identity fmtest fmtest@example.invalid

make_primary() {
	local dir=$1
	mkdir -p "$dir/bin" "$dir/state"
	git init -q "$dir"
	git -C "$dir" commit -q --allow-empty -m init
	: >"$dir/AGENTS.md"
}

# run <root> <mode>: drive the router in <root> with stdin from the caller.
run() {
	local root=$1 mode=$2
	FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$ROUTER" "$mode"
}

anchors_file() { printf '%s/state/captain-router/anchors.current' "$1"; }
verdicts_log() { printf '%s/state/captain-router/verdicts.log' "$1"; }

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
	printf 'Do you want me to start P0 implementation now?' | run "$root" --on-settle >/dev/null
	out=$(printf 'yes start the P0 implementation now please' | run "$root" --on-submit) || status=$?
	expect_code 0 "$status" "submit-same exit"
	assert_contains "$out" "verdict=same" "matching reply classifies as same"
	assert_contains "$out" "confidence=det" "P0 verdict is deterministic"
	pass "router: a reply sharing salient tokens with an open anchor is same"
}

test_submit_unrelated_message_is_unknown() {
	local root="$TMP_ROOT/submit-unknown" out status=0
	make_primary "$root"
	printf 'Do you want me to start P0 implementation now?' | run "$root" --on-settle >/dev/null
	out=$(printf 'the blender glb export pipeline is broken again' | run "$root" --on-submit) || status=$?
	expect_code 0 "$status" "submit-unknown exit"
	assert_contains "$out" "verdict=unknown" "unrelated message classifies as unknown"
	pass "router: an unrelated message is unknown (deferred to a later phase)"
}

test_submit_without_anchors_is_unknown() {
	local root="$TMP_ROOT/submit-no-anchors" out status=0
	make_primary "$root"
	out=$(printf 'anything at all' | run "$root" --on-submit) || status=$?
	expect_code 0 "$status" "submit-no-anchors exit"
	assert_contains "$out" "verdict=unknown" "no anchors yet means unknown, never a crash"
	pass "router: submit before any settle is unknown and fail-open"
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
	assert_grep "unknown" "$log" "unknown verdict recorded"
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
	pass "router: --help prints the script header"
}

test_settle_extracts_multiple_anchors
test_settle_multi_ask_verification_surfaces
test_settle_single_ask_is_silent
test_submit_matching_message_is_same
test_submit_unrelated_message_is_unknown
test_submit_without_anchors_is_unknown
test_verdict_is_logged
test_inert_in_child_worktree
test_marked_secondmate_home_is_active
test_gate_agent_is_inert
test_bad_usage_exits_two
test_help_prints_usage
