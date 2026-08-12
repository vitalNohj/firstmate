#!/usr/bin/env bash
# Offline behavior tests for bin/fm-notion-continuity.sh (no live Notion calls).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset NO_MISTAKES_GATE
unset FM_NOTION_TOKEN NOTION_TOKEN

TMP_ROOT=$(fm_test_tmproot fm-notion-continuity)
CONT="$ROOT/bin/fm-notion-continuity.sh"
fm_git_identity fmtest fmtest@example.invalid

make_primary() {
	local dir=$1
	mkdir -p "$dir/bin" "$dir/state" "$dir/config"
	git init -q "$dir"
	git -C "$dir" commit -q --allow-empty -m init
	: >"$dir/AGENTS.md"
}

run_cont() {
	local root=$1
	shift
	FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$root" FM_HOME="$root" \
		FM_STATE_OVERRIDE="$root/state" FM_CONFIG_OVERRIDE="$root/config" "$CONT" "$@"
}

test_help() {
	local out status=0
	out=$("$CONT" --help 2>&1) || status=$?
	expect_code 0 "$status" "help exit"
	assert_contains "$out" "fm-notion-continuity" "help names script"
	assert_contains "$out" "contexts-export" "help lists export"
	assert_contains "$out" "sync-briefs" "help lists sync-briefs"
	assert_contains "$out" "never prints the token" "help mentions token safety"
	pass "notion-continuity: --help"
}

test_bad_usage() {
	local root="$TMP_ROOT/bad" status=0
	make_primary "$root"
	run_cont "$root" >/dev/null 2>&1 || status=$?
	expect_code 2 "$status" "missing subcommand is usage error"
	pass "notion-continuity: bad usage exits 2"
}

test_inert_outside_primary() {
	local base="$TMP_ROOT/base" root="$TMP_ROOT/child" out status=0
	fm_git_worktree "$base" "$root" fm/notion-cont-child
	mkdir -p "$root/bin" "$root/state" "$root/config"
	: >"$root/AGENTS.md"
	out=$(run_cont "$root" sync-briefs 2>&1) || status=$?
	expect_code 0 "$status" "child exit"
	[ -z "$out" ] || fail "child must be silent, got: $out"
	pass "notion-continuity: inert outside primary"
}

test_sync_briefs_without_token_fail_open() {
	local root="$TMP_ROOT/no-token" out status=0
	make_primary "$root"
	out=$(run_cont "$root" sync-briefs 2>&1) || status=$?
	expect_code 0 "$status" "no-token still exits 0"
	assert_contains "$out" "synced=0" "summary printed"
	assert_contains "$out" "no token" "stderr explains skip"
	pass "notion-continuity: sync-briefs without token fails open"
}

test_entry_add_without_token_fail_open() {
	local root="$TMP_ROOT/entry-no-token" out status=0
	make_primary "$root"
	out=$(run_cont "$root" entry-add --router-session pending --text 'hi' 2>&1) || status=$?
	expect_code 0 "$status" "entry-add no-token exits 0"
	assert_contains "$out" "no token" "explains skip"
	pass "notion-continuity: entry-add without token fails open"
}

test_token_not_echoed_on_help_or_errors() {
	local root="$TMP_ROOT/redact" out status=0
	make_primary "$root"
	printf 'ntn_supersecrettokenvalue999\n' >"$root/config/notion-token"
	out=$(FM_NOTION_TOKEN='ntn_supersecrettokenvalue999' run_cont "$root" sync-briefs 2>&1) || status=$?
	# May fail export (no network / bad token) but must not echo the secret.
	assert_not_contains "$out" "ntn_supersecrettokenvalue999" "token must never appear in output"
	pass "notion-continuity: token never printed"
}

test_example_env_documents_live_ids() {
	local ex="$ROOT/docs/examples/notion-continuity.env.example"
	assert_present "$ex" "example env exists"
	assert_grep "d350f81c-d63f-43b9-b18c-2c0ded0a63d3" "$ex" "Contexts DS id documented"
	assert_grep "7ae6f252-5f1d-43ca-8874-03c479305148" "$ex" "Entries DS id documented"
	assert_grep "3ba92c218ab281119e54f786ee0eb0f7" "$ex" "hub page id documented"
	pass "notion-continuity: example env lists Continuity ids"
}

test_skill_present() {
	local skill="$ROOT/.agents/skills/notion-continuity/SKILL.md"
	assert_present "$skill" "skill file exists"
	assert_grep "fm-notion-continuity.sh" "$skill" "skill points at shell surface"
	assert_grep "Router session" "$skill" "skill mentions Router session"
	assert_grep "slash" "$skill" "skill mentions slash semantics"
	pass "notion-continuity: skill teaches Continuity rules"
}

test_help
test_bad_usage
test_inert_outside_primary
test_sync_briefs_without_token_fail_open
test_entry_add_without_token_fail_open
test_token_not_echoed_on_help_or_errors
test_example_env_documents_live_ids
test_skill_present
