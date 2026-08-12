#!/usr/bin/env bash
# Behavior tests for captain Notion Continuity JSONL sync into session briefs.
# Exercises header upsert, anchor preservation across re-sync, and settle
# preserving notion_* headers. No Notion API calls.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset NO_MISTAKES_GATE

TMP_ROOT=$(fm_test_tmproot fm-captain-notion-sync)
SYNC="$ROOT/bin/fm-captain-notion-sync.sh"
ROUTER="$ROOT/bin/fm-captain-message-router.sh"
fm_git_identity fmtest fmtest@example.invalid

make_primary() {
	local dir=$1
	mkdir -p "$dir/bin" "$dir/state" "$dir/config"
	git init -q "$dir"
	git -C "$dir" commit -q --allow-empty -m init
	: >"$dir/AGENTS.md"
}

run_sync() {
	local root=$1
	shift
	FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$root" FM_HOME="$root" \
		FM_STATE_OVERRIDE="$root/state" FM_CONFIG_OVERRIDE="$root/config" "$SYNC" "$@"
}

run_router() {
	local root=$1 mode=$2
	shift 2
	FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$root" FM_HOME="$root" \
		FM_STATE_OVERRIDE="$root/state" FM_CONFIG_OVERRIDE="$root/config" "$ROUTER" "$mode" "$@"
}

brief_file() { printf '%s/state/captain-router/sessions/%s.brief' "$1" "$2"; }

anchors_have() { # <brief> <token>
	awk -v t="$2" 'BEGIN{p=0} /^---$/{p=1; next} p && $0==t { found=1 } END{ exit found?0:1 }' "$1"
}

test_sync_creates_brief_with_headers() {
	local root="$TMP_ROOT/sync-create" out status=0 brief jsonl
	make_primary "$root"
	jsonl="$root/contexts.jsonl"
	cat >"$jsonl" <<'JSON'
{"router_session":"blender-axi","name":"blender-axi","semantics":"blender/axi/cli","schema":"blender axi export","notion_url":"https://www.notion.so/example","github":"https://github.com/acme/blender","herdr_session":"default","herdr_target":"default:w2J:p1","herdr_workspace":"w2J","status":"In progress"}
JSON
	out=$(run_sync "$root" --from-jsonl "$jsonl") || status=$?
	expect_code 0 "$status" "sync-create exit"
	assert_contains "$out" "synced=1" "one row synced"
	assert_contains "$out" "skipped=0" "no skips"
	brief=$(brief_file "$root" blender-axi)
	assert_present "$brief" "brief created"
	assert_grep "session_id=blender-axi" "$brief" "session id header"
	assert_grep "semantics=blender/axi/cli" "$brief" "semantics header"
	assert_grep "notion_url=https://www.notion.so/example" "$brief" "notion_url header"
	assert_grep "notion_name=blender-axi" "$brief" "notion_name from name"
	assert_grep "github=https://github.com/acme/blender" "$brief" "github header"
	assert_grep "schema=blender axi export" "$brief" "schema header"
	assert_grep "topic=blender axi export" "$brief" "topic from schema"
	assert_grep "herdr_session=default" "$brief" "herdr_session"
	assert_grep "herdr_target=default:w2J:p1" "$brief" "herdr_target"
	assert_grep "herdr_workspace=w2J" "$brief" "herdr_workspace"
	anchors_have "$brief" blender || fail "semantics token blender as anchor"
	anchors_have "$brief" axi || fail "semantics token axi as anchor"
	anchors_have "$brief" cli || fail "semantics token cli as anchor"
	assert_present "$root/state/captain-router/notion-contexts.jsonl" "mirror written"
	pass "notion-sync: creates brief with Notion continuity headers and semantics anchors"
}

test_second_sync_preserves_anchors_updates_semantics() {
	local root="$TMP_ROOT/sync-preserve" brief status=0 jsonl
	make_primary "$root"
	# Seed a settle brief with anchors.
	printf 'Shall I fix the blender glb export pipeline now?' |
		run_router "$root" --on-settle --session-id blender-axi >/dev/null
	brief=$(brief_file "$root" blender-axi)
	assert_present "$brief" "settle brief exists"
	assert_grep "blender glb export" "$brief" "settle anchor present"

	jsonl="$root/contexts.jsonl"
	cat >"$jsonl" <<'JSON'
{"router_session":"blender-axi","name":"blender-axi","semantics":"blender/axi/cli","schema":"blender axi","notion_url":"https://www.notion.so/a"}
JSON
	run_sync "$root" --from-jsonl "$jsonl" >/dev/null || status=$?
	expect_code 0 "$status" "first sync exit"
	assert_grep "semantics=blender/axi/cli" "$brief" "semantics set"
	assert_grep "blender glb export" "$brief" "prior settle anchor preserved"
	anchors_have "$brief" cli || fail "new semantics token appended"

	# Second sync updates semantics; must keep prior settle anchors.
	cat >"$jsonl" <<'JSON'
{"router_session":"blender-axi","name":"blender-axi","semantics":"blender/axi/export","schema":"blender axi export v2","notion_url":"https://www.notion.so/b"}
JSON
	run_sync "$root" --from-jsonl "$jsonl" >/dev/null || status=$?
	expect_code 0 "$status" "second sync exit"
	assert_grep "semantics=blender/axi/export" "$brief" "semantics updated"
	assert_grep "notion_url=https://www.notion.so/b" "$brief" "notion_url updated"
	assert_grep "topic=blender axi export v2" "$brief" "topic refreshed from schema"
	assert_grep "blender glb export" "$brief" "settle anchor still preserved after second sync"
	anchors_have "$brief" export || fail "new semantics token export present"
	pass "notion-sync: re-sync updates headers/semantics and preserves prior anchors"
}

test_settle_after_sync_preserves_notion_headers() {
	local root="$TMP_ROOT/settle-preserve" brief status=0 jsonl
	make_primary "$root"
	jsonl="$root/contexts.jsonl"
	cat >"$jsonl" <<'JSON'
{"router_session":"sess-notion","name":"Notion Sess","semantics":"foo/bar","schema":"schema topic","notion_url":"https://www.notion.so/keep-me","github":"https://github.com/acme/x","herdr_workspace":"w9"}
JSON
	run_sync "$root" --from-jsonl "$jsonl" >/dev/null
	brief=$(brief_file "$root" sess-notion)
	printf 'Do you want me to continue the schema topic work now?' |
		run_router "$root" --on-settle --session-id sess-notion >/dev/null || status=$?
	expect_code 0 "$status" "settle after sync exit"
	assert_grep "notion_url=https://www.notion.so/keep-me" "$brief" "settle preserves notion_url"
	assert_grep "notion_name=Notion Sess" "$brief" "settle preserves notion_name"
	assert_grep "semantics=foo/bar" "$brief" "settle preserves semantics"
	assert_grep "github=https://github.com/acme/x" "$brief" "settle preserves github"
	assert_grep "herdr_workspace=w9" "$brief" "settle preserves herdr_workspace"
	assert_grep "schema=schema topic" "$brief" "settle preserves schema header"
	# topic refreshes from settle text, not wiped notion headers
	assert_grep "continue the schema topic" "$brief" "settle refreshed topic or anchors"
	anchors_have "$brief" foo || fail "semantics tokens re-emitted as anchors after settle"
	anchors_have "$brief" bar || fail "semantics token bar present after settle"
	pass "notion-sync: settle after sync preserves notion_* headers"
}

test_unsafe_router_session_skipped() {
	local root="$TMP_ROOT/sync-skip" out status=0 jsonl
	make_primary "$root"
	jsonl="$root/bad.jsonl"
	printf '%s\n' '{"router_session":"bad/id","name":"x"}' \
		'{"router_session":"good-id","name":"ok","semantics":"a/b"}' >"$jsonl"
	out=$(run_sync "$root" --from-jsonl "$jsonl" 2>&1) || status=$?
	expect_code 0 "$status" "skip path exits 0"
	assert_contains "$out" "synced=1" "good row synced"
	assert_contains "$out" "skipped=1" "bad row skipped"
	assert_contains "$out" "skip unsafe router_session" "stderr warning for unsafe id"
	assert_present "$(brief_file "$root" good-id)" "good brief exists"
	assert_absent "$(brief_file "$root" bad/id)" "unsafe id must not create a path"
	pass "notion-sync: unsafe router_session ids are skipped fail-open"
}

test_help_and_bad_usage() {
	local out status=0
	out=$("$SYNC" --help 2>&1) || status=$?
	expect_code 0 "$status" "help exit"
	assert_contains "$out" "fm-captain-notion-sync" "help names the script"
	assert_contains "$out" "--from-jsonl" "help mentions flag"
	status=0
	"$SYNC" >/dev/null 2>&1 || status=$?
	expect_code 2 "$status" "missing flag is usage error"
	pass "notion-sync: help and usage errors"
}

test_inert_outside_primary() {
	local base="$TMP_ROOT/child-base" root="$TMP_ROOT/child-wt" out status=0 jsonl
	fm_git_worktree "$base" "$root" fm/notion-sync-child
	mkdir -p "$root/bin" "$root/state"
	: >"$root/AGENTS.md"
	jsonl="$root/c.jsonl"
	printf '%s\n' '{"router_session":"x","name":"x"}' >"$jsonl"
	out=$(run_sync "$root" --from-jsonl "$jsonl" 2>&1) || status=$?
	expect_code 0 "$status" "child exit"
	[ -z "$out" ] || fail "child worktree must be silent, got: $out"
	assert_absent "$root/state/captain-router" "child must not create router state"
	pass "notion-sync: inert outside primary"
}

test_sync_creates_brief_with_headers
test_second_sync_preserves_anchors_updates_semantics
test_settle_after_sync_preserves_notion_headers
test_unsafe_router_session_skipped
test_help_and_bad_usage
test_inert_outside_primary
