#!/usr/bin/env bash
# Behavior tests for the captain-message continuity router (bash owner).
# Exercises the executable interface only: anchor extraction on settle, multi-ask
# verification, always-spawn model classification on submit, prompt contents
# (role + bounded redacted chat history + every session brief + the message),
# the verdict/target/explanation contract, explanation recording without
# forwarding, target validation, session briefs, pending handoffs, verdict
# logging, primary scoping, gate inertness, and
# every fail-open error path. Every model call resolves a fake `cursor-agent`
# from PATH, so unit tests exercise the production resolver and spawn boundary.
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

# spawn_probe <root> <sink>: put a fake `cursor-agent` on PATH that records the
# exact argv the router launches, then answers with a valid verdict block.
spawn_probe() {
	local root=$1 sink=$2 fakebin
	fakebin=$(fm_fakebin "$root")
	cat >"$fakebin/cursor-agent" <<EOF
#!/usr/bin/env bash
set -u
printf '%s\\n' "\$@" >"$sink"
printf 'verdict=same\\ntarget=-\\nexplanation=probe.\\n'
EOF
	chmod +x "$fakebin/cursor-agent"
	printf '%s\n' "$fakebin"
}

# run_with_probe <root> <fakebin> <mode...>: drive the router with only the fake
# harness resolvable, so no real model can ever be launched from a unit test.
run_with_probe() {
	local root=$1 fakebin=$2
	shift 2
	PATH="$fakebin:$PATH" FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$root" FM_HOME="$root" \
		FM_STATE_OVERRIDE="$root/state" FM_CONFIG_OVERRIDE="$root/config" "$ROUTER" "$@"
}

# cursor_fixture <root> <name> <verdict-block> [prompt-sink]: create the only
# model fake used by unit tests. It is resolver-approved by its cursor-agent
# basename and snapshots the private prompt file when a sink is requested.
cursor_fixture() {
	local root=$1 name=$2 body=$3 sink=${4-} fakebin
	fakebin="$root/fakebin-$name"
	mkdir -p "$fakebin"
	cat >"$fakebin/cursor-agent" <<EOF
#!/usr/bin/env bash
set -u
[ -z "$sink" ] || cat "$root/state/captain-router"/prompt.* >"$sink" 2>/dev/null || true
cat <<'VERDICT'
$body
VERDICT
EOF
	chmod +x "$fakebin/cursor-agent"
	printf '%s\n' "$fakebin"
}

# cursor_exit_fixture <root> <name> <status>: resolver-approved fake that exits
# with a selected status after the shared timeout owner launches it.
cursor_exit_fixture() {
	local root=$1 name=$2 status=$3 fakebin
	fakebin="$root/fakebin-$name"
	mkdir -p "$fakebin"
	cat >"$fakebin/cursor-agent" <<EOF
#!/usr/bin/env bash
set -u
exit $status
EOF
	chmod +x "$fakebin/cursor-agent"
	printf '%s\n' "$fakebin"
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
	# The marker that separates a live conversation from a project context brief.
	assert_grep "kind=session" "$brief" "a settled brief marks itself routable"
	assert_grep "blender export fix" "$brief" "brief topic or anchors mention the ask"
	assert_present "$root/state/captain-router/current.session" "current.session pointer written"
	assert_grep "sess-alpha" "$root/state/captain-router/current.session" "current session recorded"
	pass "router: settle writes/refreshes a per-session brief"
}

# A project brief is hand-written context, not a settled session: it carries no
# kind=session marker, so it must never become a reroute destination.
write_project_brief() { # <root> <name>
	local root=$1 name=$2 dir="$1/state/captain-router/sessions"
	mkdir -p "$dir"
	cat >"$dir/$name.brief" <<EOF
session_id=$name
updated=2026-01-01T00:00:00Z
topic=Project context for $name, background only.
---
$name
EOF
}

test_submit_first_message_of_a_session_skips_the_model() {
	local root="$TMP_ROOT/submit-first-message" out status=0 fakebin
	make_primary "$root"
	# Another live session exists, so reroute would be available if it ran. A
	# model that answered here starved the session: it read the empty history as
	# "wrong session", rerouted, and stopped the turn that would have written
	# this session's brief, so every later message hit the same empty state.
	printf 'Shall I continue the exporter?' |
		run "$root" --on-settle --session-id sess-other >/dev/null
	fakebin=$(cursor_fixture "$root" first-message 'verdict=reroute
target=sess-other
explanation=this session has no chat history.')
	out=$(printf 'first thing I say here' |
		run_with_probe "$root" "$fakebin" --on-submit --session-id sess-fresh) || status=$?
	expect_code 0 "$status" "first-message submit exit"
	assert_contains "$out" "verdict=same target=sess-fresh confidence=det" \
		"the first message of a session continues there without asking the model"
	assert_absent "$(pending_dir "$root")/LATEST" \
		"a first message never stages a handoff"
	assert_grep "same" "$(verdicts_log "$root")" "the skipped verdict is still audited"
	# Once that session has settled once, classification resumes normally.
	status=0
	printf 'Anything else to check?' | run "$root" --on-settle --session-id sess-fresh >/dev/null
	out=$(printf 'back to the exporter' |
		run_with_probe "$root" "$fakebin" --on-submit --session-id sess-fresh) || status=$?
	expect_code 0 "$status" "settled-session submit exit"
	assert_contains "$out" "verdict=reroute target=sess-other confidence=model" \
		"a session that has settled once is classified normally"
	pass "router: the first message of a session is never classified"
}

test_submit_toggle_off_passes_every_message_through() {
	local root="$TMP_ROOT/submit-toggle" out status=0 fakebin
	make_primary "$root"
	printf 'Shall I continue?' | run "$root" --on-settle --session-id primary >/dev/null
	printf 'Shall I export?' | run "$root" --on-settle --session-id sess-other >/dev/null
	fakebin=$(cursor_fixture "$root" toggled 'verdict=reroute
target=sess-other
explanation=x')
	# Off: the message goes straight through and the model is never consulted.
	printf 'off\n' >"$root/config/captain-router"
	out=$(printf 'a message while the router is off' |
		run_with_probe "$root" "$fakebin" --on-submit --session-id primary) || status=$?
	expect_code 0 "$status" "toggle-off submit exit"
	assert_contains "$out" "verdict=same target=primary confidence=det" \
		"a disabled router passes the message into the current session"
	assert_absent "$(pending_dir "$root")/LATEST" "a disabled router stages nothing"
	assert_grep "same" "$(verdicts_log "$root")" "a disabled submit is still audited"
	# The environment override disables it without touching the config file.
	status=0
	printf 'on\n' >"$root/config/captain-router"
	out=$(FM_CAPTAIN_ROUTER_ENABLED=0 printf 'env-disabled message' |
		FM_CAPTAIN_ROUTER_ENABLED=0 run_with_probe "$root" "$fakebin" --on-submit --session-id primary) || status=$?
	expect_code 0 "$status" "env toggle-off submit exit"
	assert_contains "$out" "verdict=same target=primary confidence=det" \
		"the environment override disables classification too"
	# Back on, with no restart: the very next message is classified again.
	status=0
	out=$(printf 'a message while the router is on' |
		run_with_probe "$root" "$fakebin" --on-submit --session-id primary) || status=$?
	expect_code 0 "$status" "toggle-on submit exit"
	assert_contains "$out" "verdict=reroute target=sess-other confidence=model" \
		"re-enabling takes effect on the next message with no restart"
	# An unreadable or unknown value must mean on: a router that silently
	# disables itself is the same outage as one that silently drops messages.
	status=0
	printf 'wobble\n' >"$root/config/captain-router"
	out=$(printf 'unknown toggle value' |
		run_with_probe "$root" "$fakebin" --on-submit --session-id primary) || status=$?
	expect_code 0 "$status" "unknown toggle submit exit"
	assert_contains "$out" "confidence=model" "an unrecognized toggle value means on"
	pass "router: the captain toggle disables and re-enables classification live"
}

test_submit_project_brief_is_never_a_reroute_target() {
	local root="$TMP_ROOT/submit-project-brief" out status=0 fakebin prompt
	make_primary "$root"
	printf 'Shall I continue?' | run "$root" --on-settle --session-id primary >/dev/null
	write_project_brief "$root" blender-axi
	# A project brief describes a body of work, not a live conversation. Routing
	# there hands the message to something that can never receive it.
	fakebin=$(cursor_fixture "$root" project-target 'verdict=reroute
target=blender-axi
explanation=this is blender work.')
	out=$(printf 'record the luna cell results' |
		run_with_probe "$root" "$fakebin" --on-submit --session-id primary) || status=$?
	expect_code 0 "$status" "project-target submit exit"
	assert_contains "$out" "verdict=same target=primary confidence=det" \
		"a reroute naming a project brief fails open into the current session"
	assert_absent "$(pending_dir "$root")/LATEST" \
		"a project-brief reroute stages no handoff"
	assert_grep "project brief blender-axi" "$(failures_log "$root")" \
		"the project-brief reroute is recorded"
	# The prompt must separate the two, so the model stops offering projects.
	status=0
	prompt="$root/project-brief-prompt.txt"
	fakebin=$(cursor_fixture "$root" project-prompt 'verdict=same
target=primary
explanation=x' "$prompt")
	printf 'Shall I export?' | run "$root" --on-settle --session-id sess-other >/dev/null
	printf 'anything' | run_with_probe "$root" "$fakebin" --on-submit --session-id primary >/dev/null
	assert_grep "OTHER LIVE SESSIONS" "$prompt" "the prompt names the routable sessions"
	assert_grep "NEVER a reroute target" "$prompt" "the prompt marks project context unroutable"
	assert_grep "--- session sess-other ---" "$prompt" "a live session is listed as routable"
	assert_grep "--- project blender-axi ---" "$prompt" "a project brief is listed as context"
	pass "router: project briefs are context and never reroute targets"
}

test_submit_direct_address_stays_in_the_current_session() {
	local root="$TMP_ROOT/submit-address" out status=0 fakebin seen
	make_primary "$root"
	printf 'Do you want me to proceed?' | run "$root" --on-settle --session-id primary >/dev/null
	# A live session and a firstmate project brief both exist, so the model has
	# somewhere to route away to. A message that calls on Firstmate by name is
	# addressed to the session already talking, and once went out as verdict=new.
	printf 'Shall I export the glb?' | run "$root" --on-settle --session-id sess-other >/dev/null
	write_project_brief "$root" firstmate
	seen="$root/address-prompt.txt"
	fakebin=$(cursor_fixture "$root" address 'verdict=same
target=primary
explanation=addressed to firstmate.' "$seen")
	out=$(printf 'Firstmate: stop the exporter run' |
		run_with_probe "$root" "$fakebin" --on-submit --session-id primary) || status=$?
	expect_code 0 "$status" "direct-address submit exit"
	assert_contains "$out" "verdict=same target=primary" \
		"a message addressed to Firstmate stays in the current session"
	assert_absent "$(pending_dir "$root")/LATEST" "a message addressed to Firstmate stages no handoff"
	assert_grep "$(printf 'same\tprimary')" "$(verdicts_log "$root")" \
		"the direct-address verdict is recorded against the current session"
	# The rule the classifier acts on has to actually reach it.
	assert_grep "addresses Firstmate directly" "$seen" "the prompt carries the addressing rule"
	assert_grep 'answer "same" immediately' "$seen" "the rule names the verdict to answer"
	assert_grep "@firstmate" "$seen" "the rule covers the spellings the captain uses"
	assert_grep "third person" "$seen" "the rule excludes mere mentions of the project"
	assert_grep "Firstmate: stop the exporter run" "$seen" "the prompt carries the addressed message"
	pass "router: a message addressed to Firstmate belongs to the current session"
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

test_submit_always_spawns_the_model() {
	local root="$TMP_ROOT/submit-always-model" out status=0 seen fakebin
	make_primary "$root"
	# A realistic in-conversation reply sharing no literal tokens with the open
	# anchors. The deterministic layer used to call this `new`/`det` without ever
	# consulting the model; the model must now decide every submit.
	printf 'Do you want me to start the blender glb export pipeline fix now?' |
		run "$root" --on-settle --session-id primary >/dev/null
	seen="$root/seen-always.txt"
	fakebin=$(cursor_fixture "$root" always \
		'verdict=same
target=primary
explanation=The captain is questioning how routing works, which continues this session.' "$seen")
	out=$(printf 'I thought it was supposed to be classifying my messages to you.' |
		run_with_probe "$root" "$fakebin" --on-submit --session-id primary) || status=$?
	expect_code 0 "$status" "always-model submit exit"
	assert_present "$seen" "every submit must reach the router model"
	assert_contains "$out" "verdict=same" "the model verdict is honored"
	assert_contains "$out" "target=primary" "the model target is honored"
	assert_contains "$out" "confidence=model" "a real model verdict is confidence=model"
	pass "router: every submit consults the model, not a literal-token shortcut"
}

# serve_warm_runner <root>: start the warm classifier against tests/fake-pi-rpc.sh
# and echo the pid of the holder whose exit retires it. The runner announces
# readiness on stdout, which is the only startup signal a caller may rely on.
serve_warm_runner() {
	local root=$1 pid waited=0
	mkdir -p "$root/state/captain-router"
	printf '"verdict=same\\ntarget=primary\\nexplanation=Warm reply."' >"$root/reply.json"
	# The runner exits with its stdin, so a sleeper holds that pipe open.
	pid=$(FM_FAKE_PI_LOG="$root" FM_FAKE_PI_REPLY="$root/reply.json" \
		FM_CAPTAIN_ROUTER_PI="$ROOT/tests/fake-pi-rpc.sh" \
		sh -c "sleep 60 | node '$ROOT/bin/fm-captain-router-runner.mjs' serve --state '$root/state' \
			>'$root/runner.out' 2>'$root/runner.err' & echo \$!")
	while ! grep -q ready "$root/runner.out" 2>/dev/null && [ "$waited" -lt 100 ]; do
		sleep 0.1
		waited=$((waited + 1))
	done
	printf '%s\n' "$pid"
}

test_warm_runner_serves_every_submit_from_one_process() {
	local root="$TMP_ROOT/warm-runner" out status=0 holder launches prompts
	if ! command -v node >/dev/null 2>&1; then
		echo "skip: node not found for the warm classifier test"
		return 0
	fi
	make_primary "$root"
	# Settle once so this session has a brief: the first message of a session is
	# deliberately never classified, and this test is about the warm path.
	printf 'Shall I continue?' | run "$root" --on-settle --session-id primary >/dev/null
	holder=$(serve_warm_runner "$root")
	assert_grep ready "$root/runner.out" "the warm classifier reports itself ready"
	# No cursor-agent is reachable here, so only the warm path can answer.
	out=$(printf 'first captain message' | run "$root" --on-submit --session-id primary) || status=$?
	expect_code 0 "$status" "warm submit exit"
	assert_contains "$out" "verdict=same" "the warm classifier verdict is honored"
	assert_contains "$out" "confidence=model" "a warm verdict is a real model verdict"
	printf 'second captain message' | run "$root" --on-submit --session-id primary >/dev/null
	printf 'third captain message' | run "$root" --on-submit --session-id primary >/dev/null
	kill "$holder" 2>/dev/null || true
	launches=$(awk 'END{print NR+0}' "$root/pi-launches.txt")
	prompts=$(awk 'END{print NR+0}' "$root/pi-prompts.txt")
	[ "$launches" -eq 1 ] ||
		fail "three submits must share one warm process, saw $launches launches"
	[ "$prompts" -eq 3 ] || fail "every submit must reach the warm classifier, saw $prompts"
	pass "router: one warm classifier process serves every submit"
}

test_warm_runner_absence_falls_back_to_the_ephemeral_spawn() {
	local root="$TMP_ROOT/warm-runner-absent" out status=0 seen fakebin
	make_primary "$root"
	# Settle once: the first message of a session never reaches any model, and
	# this test is about which model runner answers.
	printf 'Shall I continue?' | run "$root" --on-settle --session-id primary >/dev/null
	seen="$root/seen-fallback.txt"
	fakebin=$(cursor_fixture "$root" fallback \
		'verdict=same
target=primary
explanation=Ephemeral reply.' "$seen")
	# No runner socket exists, so the ephemeral spawn must still answer.
	out=$(printf 'captain message with no warm runner' |
		run_with_probe "$root" "$fakebin" --on-submit --session-id primary) || status=$?
	expect_code 0 "$status" "warm-absent submit exit"
	assert_present "$seen" "the ephemeral router model still answers without a warm runner"
	assert_contains "$out" "verdict=same" "the fallback verdict is honored"
	assert_contains "$out" "confidence=model" "the fallback verdict is a real model verdict"
	pass "router: a missing warm classifier falls back to the ephemeral spawn"
}

test_submit_model_sees_briefs_history_and_message() {
	local root="$TMP_ROOT/submit-prompt" status=0 seen fakebin hist
	make_primary "$root"
	printf 'Do you want me to start the blender glb export pipeline fix now?' |
		run "$root" --on-settle --session-id primary >/dev/null
	printf 'Shall I merge the captain router PR today?' |
		run "$root" --on-settle --session-id sess-router >/dev/null
	hist="$root/history.txt"
	printf 'user: can you look at the router again\n\nassistant: sure, which part\n' >"$hist"
	seen="$root/seen-prompt.txt"
	fakebin=$(cursor_fixture "$root" prompt \
		'verdict=same
target=primary
explanation=Continues this session.' "$seen")
	printf 'the part that decides where my messages go' |
		run_with_probe "$root" "$fakebin" --on-submit \
			--session-id primary --chat-history-file "$hist" >/dev/null || status=$?
	expect_code 0 "$status" "prompt-shape submit exit"
	assert_grep "Firstmate captain-message continuity router" "$seen" "prompt states the router role"
	assert_grep "verdict=<same|reroute|new>" "$seen" "prompt states the verdict template"
	assert_grep "explanation=<up to 3 sentences" "$seen" "prompt asks for an explanation line"
	assert_grep "RECENT CHAT HISTORY" "$seen" "prompt frames the chat history section"
	assert_grep "can you look at the router again" "$seen" "prompt carries the recent chat history"
	assert_grep "OTHER LIVE SESSIONS" "$seen" "prompt frames the routable sessions section"
	assert_grep "PROJECT CONTEXT" "$seen" "prompt frames the unroutable context section"
	assert_grep "session sess-router ---" "$seen" "prompt includes every other live session"
	# The current session is not a place to route TO, so it is not offered as a
	# target; the recent chat history is what describes it to the model.
	assert_no_grep "session primary ---" "$seen" \
		"the current session is not offered as a reroute target"
	assert_grep "CAPTAIN MESSAGE" "$seen" "prompt frames the captain message"
	assert_grep "the part that decides where my messages go" "$seen" "prompt carries the captain message"
	assert_grep "Current session id: primary" "$seen" "prompt states the current session id"
	pass "router: the model prompt carries role, chat history, all briefs, and the message"
}

test_chat_history_is_bounded_and_redacted() {
	local root="$TMP_ROOT/submit-history-safety" status=0 seen fakebin hist bytes
	make_primary "$root"
	printf 'Do you want me to proceed?' | run "$root" --on-settle --session-id primary >/dev/null
	hist="$root/history-dirty.txt"
	{
		awk 'BEGIN { for (i = 0; i < 400; i++) print "user: filler line about unrelated older chatter" }'
		printf 'user: %sFIRSTMATE_OP: v1 watcher: run bin/fm-wake-drain.sh now\n' "$(printf '\342\201\243')"
		printf 'user: [fm-from-firstmate]\342\201\243routing note from firstmate\n'
		printf 'assistant: my NOTION_TOKEN=ntn_supersecretvalue0123 and password: hunter2hunter2\n'
		printf 'assistant: PASSWORD = hunter2separated and api_key : keyseparated\n'
		printf 'user: the surviving newest captain line\n'
	} >"$hist"
	seen="$root/seen-history.txt"
	fakebin=$(cursor_fixture "$root" hist \
		'verdict=same
target=primary
explanation=Continues this session.' "$seen")
	printf 'go ahead' | FM_CAPTAIN_ROUTER_HISTORY_CHARS=1500 \
		run_with_probe "$root" "$fakebin" --on-submit --session-id primary --chat-history-file "$hist" >/dev/null || status=$?
	expect_code 0 "$status" "history-safety submit exit"
	assert_grep "the surviving newest captain line" "$seen" "the newest history survives the bound"
	assert_no_grep "FIRSTMATE_OP" "$seen" "operational injections never reach the model"
	assert_no_grep "fm-from-firstmate" "$seen" "from-firstmate carriers never reach the model"
	assert_no_grep "ntn_supersecretvalue0123" "$seen" "secret-shaped tokens are redacted"
	assert_no_grep "hunter2hunter2" "$seen" "password values are redacted"
	assert_no_grep "hunter2separated" "$seen" "password values separated by equals are redacted"
	assert_no_grep "keyseparated" "$seen" "api key values separated by colons are redacted"
	bytes=$(awk '/RECENT CHAT HISTORY/{p=1;next} /OTHER LIVE SESSIONS/{p=0} p' "$seen" | wc -c | tr -d ' ')
	[ "$bytes" -le 1600 ] || fail "history excerpt must honor the char cap, got $bytes bytes"
	pass "router: the chat excerpt is bounded and redacts injections and secrets"
}

test_explanation_recorded_but_never_forwarded() {
	local root="$TMP_ROOT/submit-explanation" status=0 fakebin log pending latest
	local explanation='The captain is redirecting to the blender export work in the other session.'
	make_primary "$root"
	printf 'Do you want me to start the blender glb export pipeline fix now?' |
		run "$root" --on-settle --session-id sess-blender >/dev/null
	printf 'Shall I merge the captain router PR today?' |
		run "$root" --on-settle --session-id primary >/dev/null
	fakebin=$(cursor_fixture "$root" explain "verdict=reroute
target=sess-blender
explanation=$explanation")
	local out=
	out=$(printf 'lets get back to the exporter' |
		run_with_probe "$root" "$fakebin" --on-submit --session-id primary) || status=$?
	expect_code 0 "$status" "explanation submit exit"
	assert_contains "$out" "verdict=reroute target=sess-blender confidence=model" \
		"the wire line stays the machine-readable verdict the hook parses"
	assert_not_contains "$out" "redirecting" "the explanation never reaches stdout"
	log="$root/state/captain-router/explanations.log"
	assert_present "$log" "the explanation is persisted for audit"
	assert_grep "$explanation" "$log" "explanations.log records the model rationale"
	assert_grep "reroute" "$log" "explanations.log records the verdict"
	# Keyed by the same message digest verdicts.log uses.
	local vdigest edigest
	vdigest=$(awk -F'\t' 'END{print $5}' "$(verdicts_log "$root")")
	edigest=$(awk -F'\t' 'END{print $4}' "$log")
	[ -n "$vdigest" ] && [ "$vdigest" = "$edigest" ] ||
		fail "explanation must key on the verdicts.log digest ($vdigest vs $edigest)"
	pending=$(pending_dir "$root")
	latest=$(cat "$pending/LATEST")
	assert_grep "explanation=$explanation" "$pending/$latest" "the staged route records the rationale"
	# The routed context is the body after ---; the rationale must not be in it.
	local body
	body=$(awk 'p{print} /^---$/{p=1}' "$pending/$latest")
	case "$body" in
	*redirecting*) fail "the explanation leaked into the routed message body" ;;
	esac
	assert_contains "$body" "lets get back to the exporter" "the routed body is the captain message only"
	pass "router: the explanation is recorded for audit and never forwarded"
}

test_submit_model_spawn_failure_fail_open() {
	local root="$TMP_ROOT/submit-failopen" out status=0 log fakebin
	make_primary "$root"
	printf 'Do you want me to start P0 implementation now?' |
		run "$root" --on-settle --session-id primary >/dev/null
	fakebin=$(cursor_exit_fixture "$root" fail 1)
	out=$(printf 'ok' | run_with_probe "$root" "$fakebin" --on-submit --session-id primary) || status=$?
	expect_code 0 "$status" "fail-open still exits 0"
	assert_contains "$out" "verdict=same" "spawn failure allows into current primary"
	assert_contains "$out" "target=primary" "fail-open targets current session"
	assert_contains "$out" "confidence=det" "the fallback path stays labelled det"
	log=$(failures_log "$root")
	assert_present "$log" "failures.log records the spawn failure"
	pass "router: router spawn failure fail-opens as same and records failure"
}

test_submit_model_timeout_fail_open() {
	local root="$TMP_ROOT/submit-timeout" out status=0 fakebin marker
	make_primary "$root"
	printf 'Do you want me to proceed?' | run "$root" --on-settle --session-id primary >/dev/null
	marker="$root/timeout-started"
	fakebin=$(fm_fakebin "$root")
	cat >"$fakebin/cursor-agent" <<EOF
#!/usr/bin/env bash
set -u
: >"$marker"
sleep 300
EOF
	chmod +x "$fakebin/cursor-agent"
	out=$(printf 'anything' | FM_TIMEOUT_MECHANISM_OVERRIDE=bash FM_CAPTAIN_ROUTER_TIMEOUT_SECS=1 \
		run_with_probe "$root" "$fakebin" --on-submit --session-id primary) || status=$?
	expect_code 0 "$status" "timeout fail-open exit"
	assert_contains "$out" "verdict=same" "a timed-out router allows into current primary"
	assert_contains "$out" "confidence=det" "timeout falls back to the det label"
	assert_present "$marker" "the timed-out Cursor fake started"
	assert_grep "timed out" "$(failures_log "$root")" "failures.log names the timeout"
	pass "router: a router timeout fail-opens as same"
}

test_submit_garbage_verdict_fail_open() {
	local root="$TMP_ROOT/submit-garbage" out status=0 fakebin
	make_primary "$root"
	printf 'Do you want me to proceed?' | run "$root" --on-settle --session-id primary >/dev/null
	fakebin=$(cursor_fixture "$root" garbage 'I think it goes to blender')
	out=$(printf 'anything' | run_with_probe "$root" "$fakebin" --on-submit --session-id primary) || status=$?
	expect_code 0 "$status" "garbage fail-open exit"
	assert_contains "$out" "verdict=same" "unparseable output allows into current primary"
	assert_contains "$out" "confidence=det" "unparseable output falls back to det"
	assert_grep "unparseable" "$(failures_log "$root")" "failures.log records the parse failure"
	pass "router: unparseable model output fail-opens as same"
}

test_submit_reroute_target_is_validated() {
	local root="$TMP_ROOT/submit-target-validation" out status=0 fakebin
	make_primary "$root"
	printf 'Shall I merge the captain router PR today?' |
		run "$root" --on-settle --session-id primary >/dev/null
	printf 'Do you want me to start the blender export fix now?' |
		run "$root" --on-settle --session-id sess-blender >/dev/null
	# A reroute naming a session with no brief is not routable -> fail open.
	fakebin=$(cursor_fixture "$root" invalid-target 'verdict=reroute
target=no-such-session
explanation=x')
	out=$(printf 'back to the exporter' | run_with_probe "$root" "$fakebin" --on-submit --session-id primary) || status=$?
	expect_code 0 "$status" "invalid reroute target exit"
	assert_contains "$out" "verdict=same" "a reroute to an unknown session fails open"
	assert_contains "$out" "confidence=det" "the invalid target uses the fallback label"
	# A reroute naming the current session is not a handoff, even though its brief exists.
	status=0
	fakebin=$(cursor_fixture "$root" self-target 'verdict=reroute
target=primary
explanation=x')
	out=$(printf 'continue this conversation' | run_with_probe "$root" "$fakebin" --on-submit --session-id primary) || status=$?
	expect_code 0 "$status" "current-session reroute exit"
	assert_contains "$out" "verdict=same target=primary confidence=det" \
		"a self-reroute continues in the current session"
	assert_grep "current session as a reroute target" "$(failures_log "$root")" \
		"the invalid self-reroute is recorded"
	assert_absent "$(pending_dir "$root")/LATEST" \
		"a self-reroute does not publish pending route state"
	# A reroute naming a real different brief routes.
	status=0
	fakebin=$(cursor_fixture "$root" valid-target 'verdict=reroute
target=sess-blender
explanation=x')
	out=$(printf 'back to the exporter' | run_with_probe "$root" "$fakebin" --on-submit --session-id primary) || status=$?
	expect_code 0 "$status" "valid reroute target exit"
	assert_contains "$out" "verdict=reroute target=sess-blender confidence=model" \
		"a reroute naming a different existing brief routes"
	pass "router: reroute targets are validated as different existing sessions"
}

test_submit_new_and_same_targets_are_normalized() {
	local root="$TMP_ROOT/submit-normalize" out status=0 fakebin
	make_primary "$root"
	printf 'Do you want me to proceed?' | run "$root" --on-settle --session-id primary >/dev/null
	fakebin=$(cursor_fixture "$root" new-target 'verdict=new
target=primary
explanation=x')
	out=$(printf 'a brand new topic' | run_with_probe "$root" "$fakebin" --on-submit --session-id primary) || status=$?
	expect_code 0 "$status" "new normalization exit"
	assert_contains "$out" "verdict=new target=- confidence=model" "new always normalizes to target=-"
	status=0
	fakebin=$(cursor_fixture "$root" same-target 'verdict=same
target=-
explanation=x')
	out=$(printf 'still talking about this' | run_with_probe "$root" "$fakebin" --on-submit --session-id primary) || status=$?
	expect_code 0 "$status" "same normalization exit"
	assert_contains "$out" "verdict=same target=primary confidence=model" \
		"same with a placeholder target resolves to the current session"
	pass "router: new and same targets are normalized before routing"
}

test_model_override_keeps_cursor_cli_read_only() {
	local root="$TMP_ROOT/model-override" out status=0 argv fakebin
	make_primary "$root"
	printf 'Do you want me to proceed?' | run "$root" --on-settle --session-id primary >/dev/null
	argv="$root/probe-model.txt"
	fakebin=$(spawn_probe "$root" "$argv")
	out=$(printf 'a fresh topic' | FM_CAPTAIN_ROUTER_MODEL=cursor-grok-4.6-high \
		run_with_probe "$root" "$fakebin" --on-submit --session-id primary) || status=$?
	expect_code 0 "$status" "model override exit"
	assert_contains "$out" "confidence=model" "the model override still routes through the model"
	assert_present "$argv" "the model override reaches Cursor CLI"
	assert_grep "cursor-grok-4.6-high" "$argv" "FM_CAPTAIN_ROUTER_MODEL overrides the built-in model"
	assert_grep "--mode" "$argv" "the override still uses Cursor ask mode"
	assert_grep "ask" "$argv" "the override stays read-only"
	assert_no_grep "--yolo" "$argv" "the override cannot enable write autonomy"
	pass "router: FM_CAPTAIN_ROUTER_MODEL changes only the Cursor model"
}

test_builtin_default_uses_cursor_cli_read_only() {
	local root="$TMP_ROOT/default-model" argv fakebin
	make_primary "$root"
	printf 'Do you want me to proceed?' | run "$root" --on-settle --session-id primary >/dev/null
	argv="$root/probe-default.txt"
	fakebin=$(spawn_probe "$root" "$argv")
	printf 'some message' | run_with_probe "$root" "$fakebin" --on-submit --session-id primary >/dev/null
	assert_present "$argv" "the built-in default spawns Cursor Agent CLI"
	assert_grep "cursor-grok-4.6-low" "$argv" "the built-in default uses Cursor Grok 4.6 Low"
	assert_grep "--print" "$argv" "the router uses Cursor non-interactive mode"
	assert_grep "--output-format" "$argv" "the router requests stable text output"
	assert_grep "--mode" "$argv" "the router sets an explicit Cursor mode"
	assert_grep "ask" "$argv" "the router uses Cursor's read-only ask mode"
	assert_grep "--trust" "$argv" "the headless run skips the workspace prompt"
	assert_grep "--workspace" "$argv" "the router pins its workspace"
	assert_no_grep "--yolo" "$argv" "the read-only router never enables Cursor write autonomy"
	assert_no_grep "--force" "$argv" "the read-only router never forces tool approval"
	assert_no_grep "pi-cursor-sdk" "$argv" "the Cursor CLI route has no Pi provider extension"
	pass "router: Cursor Agent CLI with Grok 4.6 Low is the built-in continuity default"
}

test_submit_prompt_rides_the_file_not_argv() {
	local root="$TMP_ROOT/argv-privacy" out status=0 argv promptseen fakebin hist mode stdinseen
	make_primary "$root"
	printf 'Shall I continue here?' | run "$root" --on-settle --session-id primary >/dev/null
	# The sentinel lives in ANOTHER session's brief, because only other live
	# sessions are listed as routable targets in the prompt.
	printf 'Do you want me to start the SENTINEL-BRIEF-TOPIC work now?' |
		run "$root" --on-settle --session-id sess-other >/dev/null
	hist="$root/history.txt"
	printf 'user: SENTINEL-HISTORY-LINE about the exporter\n' >"$hist"
	argv="$root/probe-argv.txt"
	promptseen="$root/probe-promptfile.txt"
	mode="$root/probe-prompt-mode.txt"
	stdinseen="$root/probe-stdin.txt"
	fakebin=$(fm_fakebin "$root")
	# Like spawn_probe, but also snapshots the prompt file the argv instruction
	# points at, proving the full context rides the file rather than the argv.
	cat >"$fakebin/cursor-agent" <<EOF
#!/usr/bin/env bash
set -u
printf '%s\\n' "\$@" >"$argv"
prompt_file=\$(printf '%s\\n' "$root/state/captain-router"/prompt.* | head -n 1)
cat >"$stdinseen"
cat "\$prompt_file" >"$promptseen" 2>/dev/null || true
stat -f '%Lp' "\$prompt_file" >"$mode" 2>/dev/null || stat -c %a "\$prompt_file" >"$mode"
printf 'verdict=same\\ntarget=-\\nexplanation=probe.\\n'
EOF
	chmod +x "$fakebin/cursor-agent"
	out=$(printf 'SENTINEL-CAPTAIN-MESSAGE body' | run_with_probe "$root" "$fakebin" \
		--on-submit --session-id primary --chat-history-file "$hist") || status=$?
	expect_code 0 "$status" "argv-privacy submit exit"
	assert_contains "$out" "confidence=model" "the file-instruction spawn still routes through the model"
	assert_present "$argv" "the probe recorded the spawn argv"
	assert_no_grep "SENTINEL-CAPTAIN-MESSAGE" "$argv" "the captain message never rides the process list"
	assert_no_grep "SENTINEL-HISTORY-LINE" "$argv" "chat history never rides the process list"
	assert_no_grep "SENTINEL-BRIEF-TOPIC" "$argv" "session briefs never ride the process list"
	assert_grep "Read the prompt file at" "$argv" "argv carries only the short read-this-file instruction"
	assert_grep "state/captain-router/prompt." "$argv" "the instruction names the prompt file path"
	assert_present "$promptseen" "the prompt file exists while the agent runs"
	assert_grep "SENTINEL-CAPTAIN-MESSAGE" "$promptseen" "the prompt file carries the captain message"
	assert_grep "SENTINEL-HISTORY-LINE" "$promptseen" "the prompt file carries the redacted history"
	assert_grep "SENTINEL-BRIEF-TOPIC" "$promptseen" "the prompt file carries the session briefs"
	local prompt_mode
	prompt_mode=$(tr -d '[:space:]' <"$mode")
	[ "$prompt_mode" = 600 ] || fail "the prompt file mode must be 0600, got: $prompt_mode"
	[ ! -s "$stdinseen" ] || fail "the full prompt must not be duplicated onto Cursor stdin"
	pass "router: the full prompt rides the temp file, argv only the short instruction"
}

test_submit_prompt_handoff_failures_fail_open() {
	local kind root fakebin out status expected wrapper count_file
	local real_mktemp real_chmod real_cat
	real_mktemp=$(command -v mktemp)
	real_chmod=$(command -v chmod)
	real_cat=$(command -v cat)
	for kind in create mode write; do
		root="$TMP_ROOT/prompt-handoff-$kind"
		make_primary "$root"
		# Settle once so the submit reaches the prompt handoff at all: a session's
		# first message is answered without building a prompt.
		printf 'Shall I continue?' | run "$root" --on-settle --session-id primary >/dev/null
		fakebin=$(cursor_fixture "$root" "prompt-handoff-$kind" 'verdict=same
target=-
explanation=unused')
		case "$kind" in
		create)
			wrapper="$fakebin/mktemp"
			cat >"$wrapper" <<EOF
#!/usr/bin/env bash
case "\${1-}" in
*/prompt.XXXXXX) exit 1 ;;
esac
exec "$real_mktemp" "\$@"
EOF
			expected="could not create private router prompt file"
			;;
		mode)
			wrapper="$fakebin/chmod"
			cat >"$wrapper" <<EOF
#!/usr/bin/env bash
case "\${2-}" in
*/prompt.*) exit 1 ;;
esac
exec "$real_chmod" "\$@"
EOF
			expected="could not set private router prompt file mode"
			;;
		write)
			wrapper="$fakebin/cat"
			count_file="$root/cat-count"
			cat >"$wrapper" <<EOF
#!/usr/bin/env bash
count=0
if [ "\$#" -eq 0 ]; then
	[ ! -s "$count_file" ] || IFS= read -r count <"$count_file"
	count=\$((count + 1))
	printf '%s\n' "\$count" >"$count_file"
	if [ "\$count" -eq 2 ]; then
		"$real_cat" >/dev/null
		exit 1
	fi
fi
exec "$real_cat" "\$@"
EOF
			expected="could not write private router prompt file"
			;;
		esac
		chmod +x "$wrapper"
		status=0
		out=$(printf 'continue safely' |
			run_with_probe "$root" "$fakebin" --on-submit --session-id primary) || status=$?
		expect_code 0 "$status" "$kind prompt handoff failure exit"
		assert_contains "$out" "verdict=same target=primary confidence=det" \
			"$kind prompt handoff failure allows the captain message through"
		assert_grep "$expected" "$(failures_log "$root")" \
			"$kind prompt handoff failure is recorded"
		assert_no_grep "router agent exited" "$(failures_log "$root")" \
			"$kind prompt handoff failure records no duplicate agent exit"
	done
	pass "router: every private prompt handoff failure is recorded and fails open"
}

test_submit_dependency_free_timeout_terminates_hung_spawn() {
	local root="$TMP_ROOT/submit-bash-timeout" out status=0 fakebin marker
	make_primary "$root"
	printf 'Do you want me to proceed?' | run "$root" --on-settle --session-id primary >/dev/null
	marker="$root/hang-started.txt"
	fakebin=$(fm_fakebin "$root")
	# A hung model on a host with no timeout/gtimeout/perl: the fm-timeout-lib
	# dependency-free fallback must still kill the whole spawn group at the bound.
	cat >"$fakebin/cursor-agent" <<EOF
#!/usr/bin/env bash
set -u
: >"$marker"
sleep 300
EOF
	chmod +x "$fakebin/cursor-agent"
	out=$(printf 'anything' | FM_TIMEOUT_MECHANISM_OVERRIDE=bash FM_CAPTAIN_ROUTER_TIMEOUT_SECS=1 \
		run_with_probe "$root" "$fakebin" --on-submit --session-id primary) || status=$?
	expect_code 0 "$status" "forced dependency-free timeout exit"
	assert_present "$marker" "the hanging fake agent actually started"
	assert_contains "$out" "verdict=same" "a hung model fails open into the current primary"
	assert_contains "$out" "confidence=det" "the timeout path stays labelled det"
	assert_grep "timed out after 1s" "$(failures_log "$root")" "failures.log names the timeout"
	pass "router: the dependency-free timeout bound terminates a hung spawn"
}

test_submit_large_timeout_override_reaches_shared_owner() {
	local root="$TMP_ROOT/submit-large-timeout" out status=0 fakebin timeout_args
	make_primary "$root"
	printf 'Do you want me to proceed?' | run "$root" --on-settle --session-id primary >/dev/null
	fakebin=$(fm_fakebin "$root")
	timeout_args="$root/timeout-args.txt"
	cat >"$fakebin/timeout" <<EOF
#!/usr/bin/env bash
set -u
printf '%s\n' "\$@" >"$timeout_args"
shift 3
exec "\$@"
EOF
	cat >"$fakebin/cursor-agent" <<'SH'
#!/usr/bin/env bash
set -u
printf 'verdict=same\ntarget=-\nexplanation=probe.\n'
SH
	chmod +x "$fakebin/timeout" "$fakebin/cursor-agent"
	out=$(printf 'anything' | PATH="$fakebin:$PATH" FM_CAPTAIN_ROUTER_TIMEOUT_SECS=180 \
		run "$root" --on-submit --session-id primary) || status=$?
	expect_code 0 "$status" "large timeout override exit"
	assert_contains "$out" "verdict=same target=primary confidence=model" \
		"a large bound still completes through the shared owner"
	assert_present "$timeout_args" "the shared timeout owner was invoked"
	assert_grep "180" "$timeout_args" "the 180-second override reaches the shared timeout owner"
	pass "router: large timeout overrides remain owned by the shared shell bound"
}

test_new_route_publication_failure_falls_back_to_same() {
	local root="$TMP_ROOT/new-publication-failure" out status=0 pending log fakebin
	make_primary "$root"
	printf 'Do you want me to start the blender export fix?' |
		run "$root" --on-settle --session-id primary >/dev/null
	pending=$(pending_dir "$root")
	printf 'not a directory\n' >"$pending"
	fakebin=$(cursor_fixture "$root" new-publication-fail 'verdict=new
target=-
explanation=new topic')
	out=$(printf 'a new unrelated topic' |
		run_with_probe "$root" "$fakebin" --on-submit --session-id primary) || status=$?
	expect_code 0 "$status" "new publication failure exit"
	assert_contains "$out" "verdict=same target=primary confidence=det" \
		"a new route that cannot be published fails open to the current session"
	log=$(failures_log "$root")
	assert_grep "pending route publication failed" "$log" \
		"the new-route staging failure is recorded"
	assert_grep $'same\tprimary\tdet' "$(verdicts_log "$root")" \
		"the verdict log records only the surfaced deterministic fallback"
	assert_absent "$pending/LATEST" "a failed new-route publication does not claim a latest route"
	pass "router: failed new-route publication never surfaces an unstaged handoff"
}

test_reroute_publication_failure_falls_back_to_same() {
	local root="$TMP_ROOT/reroute-publication-failure" out status=0 pending log fakebin
	make_primary "$root"
	printf 'Do you want me to start the blender export fix?' |
		run "$root" --on-settle --session-id primary >/dev/null
	printf 'Should I continue the existing shader review?' |
		run "$root" --on-settle --session-id sess-shader >/dev/null
	pending=$(pending_dir "$root")
	printf 'not a directory\n' >"$pending"
	fakebin=$(cursor_fixture "$root" reroute-publication-fail 'verdict=reroute
target=sess-shader
explanation=continue the existing shader review')
	out=$(printf 'continue the shader review' |
		run_with_probe "$root" "$fakebin" --on-submit --session-id primary) || status=$?
	expect_code 0 "$status" "reroute publication failure exit"
	assert_contains "$out" "verdict=same target=primary confidence=det" \
		"a reroute that cannot be published fails open to the current session"
	log=$(failures_log "$root")
	assert_grep "pending route publication failed" "$log" \
		"the reroute staging failure is recorded"
	assert_grep $'same\tprimary\tdet' "$(verdicts_log "$root")" \
		"the verdict log records only the surfaced deterministic fallback"
	assert_absent "$pending/LATEST" "a failed reroute publication does not claim a latest route"
	pass "router: failed reroute publication never surfaces an unstaged handoff"
}

test_repeated_route_staging_preserves_published_latest() {
	local root="$TMP_ROOT/repeated-route-staging" out status=0 pending fakebin
	local first_latest latest_after first_route route_count real_mv
	make_primary "$root"
	# Both sessions must have settled: the submitting session needs a brief to be
	# classified at all, and the target needs one to be routable.
	printf 'Shall I continue here?' | run "$root" --on-settle --session-id primary >/dev/null
	printf 'Should I continue the existing shader review?' |
		run "$root" --on-settle --session-id sess-shader >/dev/null
	fakebin=$(cursor_fixture "$root" repeated-route 'verdict=reroute
target=sess-shader
explanation=continue the existing shader review')
	cat >"$fakebin/date" <<'SH'
#!/usr/bin/env bash
printf '2026-08-13T12:00:00Z\n'
SH
	chmod +x "$fakebin/date"
	out=$(printf 'continue the shader review' |
		run_with_probe "$root" "$fakebin" --on-submit --session-id primary) || status=$?
	expect_code 0 "$status" "initial repeated-route staging exit"
	assert_contains "$out" "verdict=reroute target=sess-shader confidence=model" \
		"the initial route is published"
	pending=$(pending_dir "$root")
	first_latest=$(cat "$pending/LATEST")
	first_route="$pending/$first_latest"
	assert_present "$first_route" "the initial latest route exists"
	real_mv=$(command -v mv)
	cat >"$fakebin/mv" <<EOF
#!/usr/bin/env bash
destination=
for argument in "\$@"; do
	destination=\$argument
done
case "\$destination" in
*/LATEST) exit 1 ;;
esac
exec "$real_mv" "\$@"
EOF
	chmod +x "$fakebin/mv"
	status=0
	out=$(printf 'continue the shader review' |
		run_with_probe "$root" "$fakebin" --on-submit --session-id primary) || status=$?
	expect_code 0 "$status" "repeated-route latest failure exit"
	assert_contains "$out" "verdict=same target=primary confidence=det" \
		"the failed replacement publication allows the captain message through"
	latest_after=$(cat "$pending/LATEST")
	[ "$latest_after" = "$first_latest" ] ||
		fail "LATEST changed after failed repeated staging ($first_latest vs $latest_after)"
	assert_present "$first_route" "failed repeated staging preserves the published route"
	assert_grep "continue the shader review" "$first_route" \
		"the preserved latest route retains its captain message"
	route_count=$(find "$pending" -type f -name '*.route' | wc -l | tr -d ' ')
	[ "$route_count" -eq 1 ] || fail "expected one published route after rollback, got $route_count"
	pass "router: repeated staging cannot destroy the route named by LATEST"
}

test_pi_hook_uses_context_session_ids_without_outer_timeout() {
	local fixture out status=0
	if ! command -v node >/dev/null 2>&1; then
		echo "skip: node not found for the Pi hook context test"
		return 0
	fi
	fixture="$TMP_ROOT/hook-context"
	mkdir -p "$fixture/state"
	out=$(
		FM_STATE_OVERRIDE="$fixture/state" FM_OPERATIONAL_INPUT_SCRIPT=/probe/fm-operational-input.sh \
			FM_HOOK_HARNESS="$ROOT/tests/pi-hook-harness.mjs" \
			node --experimental-test-module-mocks --experimental-strip-types --no-warnings \
			--input-type=module 2>&1 <<'JS'
const harness = await import(process.env.FM_HOOK_HARNESS);
const ownerCalls = [];
let lockOwned = true;
harness.installChildProcess({
  real: { spawnSync: () => ({ status: 1, stdout: "", stderr: "" }), spawn: () => harness.fakeChild("") },
  lockOwned: () => lockOwned,
  operational: () => false,
  onSpawnSync(command, args, options) {
    ownerCalls.push({ kind: "settle", command, args, options });
    return { status: 0, stdout: "", stderr: "" };
  },
  onSpawn(command, args) {
    const call = { kind: "submit", command, args, input: undefined };
    ownerCalls.push(call);
    return harness.fakeChild(`verdict=same target=${args[2]} confidence=model\n`, {
      onInput: (text) => { call.input = text; },
    });
  },
});
const extension = await import(`./.pi/extensions/fm-primary-captain-message-router.ts?context-test=${Date.now()}`);
const handlers = new Map();
const injected = [];
extension.default({
  on: (event, handler) => handlers.set(event, handler),
  sendUserMessage: (content) => injected.push(content),
});
const context = (id) => ({ sessionManager: { getSessionId: () => id } });
await handlers.get("input")(
  { type: "input", text: "first captain message", source: "interactive" },
  context("session-alpha"),
);
await handlers.get("before_agent_start")(
  { type: "before_agent_start", prompt: "first captain message", sessionId: "wrong-event-id" },
  context("session-alpha"),
);
await handlers.get("agent_end")(
  {
    type: "agent_end",
    messages: [{ role: "assistant", content: [{ type: "text", text: "alpha ready" }] }],
  },
  context("session-alpha"),
);
await handlers.get("agent_settled")(
  { type: "agent_settled", sessionId: "wrong-event-id" },
  context("session-alpha"),
);
await handlers.get("before_agent_start")(
  { type: "before_agent_start", prompt: "stranded alpha prompt" },
  context("session-alpha"),
);
await handlers.get("agent_end")(
  {
    type: "agent_end",
    messages: [{ role: "assistant", content: [{ type: "text", text: "stranded alpha" }] }],
  },
  context("session-alpha"),
);
await handlers.get("agent_settled")(
  { type: "agent_settled" },
  context("session-beta"),
);
await handlers.get("session_start")(
  { type: "session_start", reason: "resume" },
  context("session-beta"),
);
await handlers.get("before_agent_start")(
  { type: "before_agent_start", prompt: "beta captain message" },
  context("session-beta"),
);
await handlers.get("agent_end")(
  {
    type: "agent_end",
    messages: [{ role: "assistant", content: [{ type: "text", text: "beta ready" }] }],
  },
  context("session-beta"),
);
await handlers.get("agent_settled")(
  { type: "agent_settled" },
  context("session-beta"),
);
await handlers.get("before_agent_start")(
  { type: "before_agent_start", prompt: "second beta captain message" },
  context("session-beta"),
);
lockOwned = false;
await handlers.get("agent_end")(
  {
    type: "agent_end",
    messages: [{ role: "assistant", content: [{ type: "text", text: "must not settle after lock loss" }] }],
  },
  context("session-beta"),
);
await handlers.get("agent_settled")(
  { type: "agent_settled" },
  context("session-beta"),
);
await handlers.get("before_agent_start")(
  { type: "before_agent_start", prompt: "unowned captain message" },
  context("session-beta"),
);
// Submits resolve off the input path, so wait for the queue to drain: the
// four eligible captain prompts, and the unowned one that must never spawn.
await harness.waitFor(
  () => ownerCalls.filter((call) => call.kind === "submit" && call.input !== undefined).length === 4,
  "every queued classification to reach the router",
);
const calls = ownerCalls.map(({ kind, args, options, input }) => ({
  kind,
  args,
  input: input ?? options?.input,
  timeout: options?.timeout,
}));
console.log(JSON.stringify(calls));
JS
	) || status=$?
	expect_code 0 "$status" "hook context session test exit ($out)"
	assert_contains "$out" '"args":["--on-submit","--session-id","session-alpha"]' \
		"the first context session id reaches the submit owner call"
	assert_contains "$out" '"args":["--on-settle","--session-id","session-alpha"]' \
		"the first context session id reaches the settle owner call"
	assert_contains "$out" '"args":["--on-settle","--session-id","session-beta"]' \
		"the second context session id reaches its own settle owner call"
	assert_not_contains "$out" '"kind":"settle","args":["--on-settle","--session-id","session-beta"],"input":"stranded alpha"' \
		"assistant text captured for one session is not settled as another session"
	assert_contains "$out" '"args":["--on-submit","--session-id","session-beta","--chat-history-file"' \
		"distinct context session ids remain distinct across submit calls"
	assert_not_contains "$out" "must not settle after lock loss" \
		"a session that loses lock ownership does not call the settle owner"
	assert_not_contains "$out" "unowned captain message" \
		"a session without lock ownership does not call the submit owner"
	assert_not_contains "$out" "wrong-event-id" "event payload session ids are ignored"
	assert_not_contains "$out" '"timeout":' \
		"the hook has no outer timeout that can preempt the shared shell owner"
	pass "router: the Pi hook uses context session ids and requires lock ownership"
}

test_pi_hook_classifies_queued_input_and_rejects_mixed_runs() {
	local fixture out status=0
	if ! command -v node >/dev/null 2>&1; then
		echo "skip: node not found for the Pi hook queued-input test"
		return 0
	fi
	fixture="$TMP_ROOT/hook-queued-input"
	mkdir -p "$fixture/state"
	out=$(
		FM_STATE_OVERRIDE="$fixture/state" FM_OPERATIONAL_INPUT_SCRIPT=/probe/fm-operational-input.sh \
			FM_HOOK_HARNESS="$ROOT/tests/pi-hook-harness.mjs" \
			node --experimental-test-module-mocks --experimental-strip-types --no-warnings \
			--input-type=module 2>&1 <<'JS'
import { readFileSync } from "node:fs";
const harness = await import(process.env.FM_HOOK_HARNESS);
const calls = [];
let lockOwned = true;
harness.installChildProcess({
  real: { spawnSync: () => ({ status: 1, stdout: "", stderr: "" }), spawn: () => harness.fakeChild("") },
  lockOwned: () => lockOwned,
  operational: (text) => text.includes("FIRSTMATE_OP:"),
  onSpawnSync(_command, args, options) {
    calls.push({ mode: args[0], args, input: options?.input, history: "" });
    return { status: 0, stdout: "", stderr: "" };
  },
  onSpawn(_command, args) {
    const historyIndex = args.indexOf("--chat-history-file");
    const history = historyIndex >= 0 ? readFileSync(args[historyIndex + 1], "utf8") : "";
    const call = { mode: args[0], args, input: undefined, history };
    calls.push(call);
    return harness.fakeChild(`verdict=same target=${args[2]} confidence=model\n`, {
      onInput: (text) => { call.input = text; },
    });
  },
});
const extension = await import(`./.pi/extensions/fm-primary-captain-message-router.ts?queued-test=${Date.now()}`);
const handlers = new Map();
const injected = [];
extension.default({
  on: (event, handler) => handlers.set(event, handler),
  sendUserMessage: (content) => injected.push(content),
});
const context = (id) => ({ sessionManager: { getSessionId: () => id } });
const end = (text) => handlers.get("agent_end")({
  type: "agent_end",
  messages: [{ role: "assistant", content: [{ type: "text", text }] }],
}, context("session-alpha"));

await handlers.get("input")(
  { type: "input", text: "idle captain", source: "interactive" },
  context("session-alpha"),
);
await handlers.get("before_agent_start")(
  { type: "before_agent_start", prompt: "idle captain" },
  context("session-alpha"),
);
await end("idle response");
await handlers.get("agent_settled")({}, context("session-alpha"));

await handlers.get("input")(
  { type: "input", text: "queued captain", source: "rpc", streamingBehavior: "followUp" },
  context("session-alpha"),
);
await end("queued response");
await handlers.get("input")(
  { type: "input", text: "late queued follow-up", source: "rpc", streamingBehavior: "followUp" },
  context("session-alpha"),
);
await handlers.get("input")(
  { type: "input", text: "late queued steer", source: "rpc", streamingBehavior: "steer" },
  context("session-alpha"),
);
await handlers.get("agent_settled")({}, context("session-alpha"));

await handlers.get("input")(
  { type: "input", text: "extension captain", source: "extension", streamingBehavior: "steer" },
  context("session-alpha"),
);
await end("extension response");
await handlers.get("agent_settled")({}, context("session-alpha"));

await handlers.get("input")(
  { type: "input", text: "captain before watcher", source: "interactive" },
  context("session-alpha"),
);
await end("candidate before watcher");
await handlers.get("input")(
  { type: "input", text: "\u2063FIRSTMATE_OP: v1 watcher", source: "extension", streamingBehavior: "followUp" },
  context("session-alpha"),
);
await handlers.get("agent_settled")({}, context("session-alpha"));

await handlers.get("input")(
  { type: "input", text: "\u2063FIRSTMATE_OP: v1 turn-end", source: "extension" },
  context("session-alpha"),
);
await end("operational response");
await handlers.get("agent_settled")({}, context("session-alpha"));

await handlers.get("input")(
  { type: "input", text: "replacement captain", source: "interactive" },
  context("session-alpha"),
);
await end("replacement candidate");
await handlers.get("session_start")({}, context("session-beta"));
await handlers.get("agent_settled")({}, context("session-alpha"));

await handlers.get("input")(
  { type: "input", text: "lock-loss captain", source: "interactive" },
  context("session-beta"),
);
await handlers.get("agent_end")({
  type: "agent_end",
  messages: [{ role: "assistant", content: [{ type: "text", text: "lock-loss candidate" }] }],
}, context("session-beta"));
lockOwned = false;
await handlers.get("agent_settled")({}, context("session-beta"));

await harness.waitFor(
  () => calls.filter((call) => call.mode === "--on-submit" && call.input !== undefined).length === 8,
  "every queued classification to reach the router",
);
console.log(JSON.stringify(calls));
JS
	) || status=$?
	expect_code 0 "$status" "hook queued-input test exit ($out)"
	local submits settles
	submits=$(printf '%s\n' "$out" | grep -o '"mode":"--on-submit"' | wc -l | tr -d ' ')
	settles=$(printf '%s\n' "$out" | grep -o '"mode":"--on-settle"' | wc -l | tr -d ' ')
	[ "$submits" -eq 8 ] || fail "expected exactly 8 captain classifications, got $submits ($out)"
	[ "$settles" -eq 3 ] || fail "expected idle, queued, and extension captain settlement, got $settles ($out)"
	assert_contains "$out" '"input":"queued captain"' "queued captain input is classified"
	assert_contains "$out" '"input":"late queued follow-up","history":"assistant: queued response"' \
		"a late follow-up is classified against the agent-end candidate history"
	assert_contains "$out" '"input":"late queued steer","history":"assistant: queued response"' \
		"a late steer is classified against the agent-end candidate history"
	assert_contains "$out" '"input":"extension captain"' "extension-delivered captain input is classified"
	assert_not_contains "$out" 'candidate before watcher' "late operational input invalidates an earlier candidate"
	assert_not_contains "$out" 'operational response' "operational-only runs do not settle"
	assert_not_contains "$out" 'replacement candidate' "session replacement drops the old candidate"
	assert_not_contains "$out" 'lock-loss candidate' "lock ownership loss drops the candidate"
	pass "router: Pi input records classify queued captain messages and isolate mixed runs"
}

test_pi_hook_holds_the_send_without_blocking_the_input_path() {
	local fixture out status=0
	if ! command -v node >/dev/null 2>&1; then
		echo "skip: node not found for the Pi hook unfreeze test"
		return 0
	fi
	fixture="$TMP_ROOT/hook-unfreeze"
	mkdir -p "$fixture/state"
	out=$(
		FM_STATE_OVERRIDE="$fixture/state" FM_OPERATIONAL_INPUT_SCRIPT=/probe/fm-operational-input.sh \
			FM_HOOK_HARNESS="$ROOT/tests/pi-hook-harness.mjs" \
			node --experimental-test-module-mocks --experimental-strip-types --no-warnings \
			--input-type=module 2>&1 <<'JS'
const harness = await import(process.env.FM_HOOK_HARNESS);
const events = [];
const submits = [];
// A deliberately slow router: every classification answers well after the
// `input` handler must already have returned.
const ROUTER_MS = 250;
const verdicts = new Map([
  ["captain reply", "verdict=same target=session-alpha confidence=model\n"],
  ["/bearings", "verdict=same target=session-alpha confidence=model\n"],
  ["picture please", "verdict=same target=session-alpha confidence=model\n"],
  ["unrelated blender work", "verdict=new target=- confidence=model\n"],
  ["broken router message", "not a verdict at all\n"],
]);
harness.installChildProcess({
  real: { spawnSync: () => ({ status: 1, stdout: "", stderr: "" }), spawn: () => harness.fakeChild("") },
  lockOwned: () => true,
  operational: (text) => text.includes("FIRSTMATE_OP:"),
  onSpawnSync: () => ({ status: 0, stdout: "", stderr: "" }),
  onSpawn(_command, args) {
    const call = { args, input: undefined, stdout: "" };
    // Answer for the message actually classified, not for call order.
    return harness.fakeChild(() => call.stdout, {
      delayMs: ROUTER_MS,
      onInput: (text) => {
        call.input = text;
        call.stdout = verdicts.get(text) ?? "";
        submits.push(call);
      },
    });
  },
});
const extension = await import(`./.pi/extensions/fm-primary-captain-message-router.ts?unfreeze-test=${Date.now()}`);
const handlers = new Map();
const injected = [];
extension.default({
  on: (event, handler) => handlers.set(event, handler),
  sendUserMessage: (content, options) => injected.push({ content, options }),
});
const context = { sessionManager: { getSessionId: () => "session-alpha" } };
const send = async (event) => {
  const startedAt = Date.now();
  const result = await handlers.get("input")({ type: "input", source: "interactive", ...event }, context);
  events.push({ text: event.text, action: result?.action, elapsed: Date.now() - startedAt });
  return result;
};

await send({ text: "captain reply" });
// The editor is still live here: a second Enter press lands while the first
// classification is in flight, and must be accepted the same way.
await send({ text: "unrelated blender work" });
await send({ text: "/bearings" });
await send({
  text: "picture please",
  images: [{ type: "image", source: { type: "base64", mediaType: "image/png", data: "AAAA" } }],
});
await send({ text: "broken router message" });
await send({ text: "\u2063FIRSTMATE_OP: v1 watcher", source: "extension" });

// Four of the five submits are held and delivered; the slash send passed
// through. The `new` verdict lands here too: no route was staged for this
// fixture, so its transfer is refused and the message comes back.
await harness.waitFor(() => injected.length >= 4, "the held sends to be injected");
// The injected copies come back through `input` as extension-sourced traffic
// and must not be classified a second time.
for (const entry of injected) {
  const text = typeof entry.content === "string" ? entry.content : entry.content[0].text;
  await send({ text, source: "extension", images: undefined });
}
await new Promise((resolve) => setTimeout(resolve, ROUTER_MS * 2));

console.log(JSON.stringify({
  routerMs: ROUTER_MS,
  events,
  submits: submits.map((call) => call.input),
  injected: injected.map((entry) => ({
    text: typeof entry.content === "string" ? entry.content : entry.content[0].text,
    images: typeof entry.content === "string" ? 0 : entry.content.filter((part) => part.type === "image").length,
  })),
}));
JS
	) || status=$?
	expect_code 0 "$status" "hook unfreeze test exit ($out)"
	local router_ms slowest
	router_ms=$(printf '%s\n' "$out" | sed -n 's/.*"routerMs":\([0-9]*\).*/\1/p')
	[ -n "$router_ms" ] || fail "unfreeze test did not report the router delay ($out)"
	# The proof that the editor is free: no `input` handler call waited anywhere
	# near the router child, which every classification needed to finish.
	slowest=$(printf '%s\n' "$out" | grep -o '"elapsed":[0-9]*' | cut -d: -f2 | sort -n | tail -1)
	[ -n "$slowest" ] || fail "unfreeze test recorded no input-handler timings ($out)"
	[ "$slowest" -lt "$router_ms" ] ||
		fail "an input handler waited ${slowest}ms on a ${router_ms}ms router child ($out)"
	assert_contains "$out" '"text":"captain reply","action":"handled"' \
		"an ordinary captain send is held instead of proceeding into the live turn"
	assert_contains "$out" '"text":"unrelated blender work","action":"handled"' \
		"a later Enter press while a classification is in flight is held too"
	assert_contains "$out" '"text":"/bearings","action":"continue"' \
		"slash traffic passes through so Pi still expands it"
	# Every captain submit still reaches the router, exactly once each.
	# The list is exhaustive, so it also proves the operational injection and
	# every re-injected copy stayed out of the router.
	assert_contains "$out" '"submits":["captain reply","unrelated blender work","/bearings","picture please","broken router message"]' \
		"every captain submit reaches the router exactly once, in submit order"
	assert_contains "$out" 'FIRSTMATE_OP: v1 watcher","action":"continue"' \
		"an operational injection is passed through without a hold"
	assert_contains "$out" '"text":"captain reply","action":"continue"' \
		"the re-injected copy passes through instead of being held again"
	assert_contains "$out" '{"text":"captain reply","images":0}' \
		"a same verdict injects the held message into the current session"
	assert_contains "$out" '{"text":"picture please","images":1}' \
		"the held send keeps its images"
	assert_contains "$out" '{"text":"broken router message","images":0}' \
		"an unparseable verdict fails open and still delivers the message"
	# A verdict records where a message belonged; without a confirmed transfer it
	# is never a reason to destroy it, which would lose a captain message with no
	# turn, no error, and no echo anywhere.
	assert_contains "$out" '{"text":"unrelated blender work","images":0}' \
		"a non-same verdict whose transfer did not happen is still delivered"
	pass "router: the Pi input handler holds the send and never waits on the router child"
}

test_pi_hook_rejects_typed_session_start_context() {
	local fixture out status=0
	if ! command -v node >/dev/null 2>&1; then
		echo "skip: node not found for the Pi hook session-start context test"
		return 0
	fi
	fixture="$TMP_ROOT/hook-session-start-context"
	mkdir -p "$fixture/state"
	out=$(
		FM_STATE_OVERRIDE="$fixture/state" FM_OPERATIONAL_INPUT_SCRIPT=/probe/fm-operational-input.sh \
			FM_HOOK_HARNESS="$ROOT/tests/pi-hook-harness.mjs" \
			node --experimental-test-module-mocks --experimental-strip-types --no-warnings \
			--input-type=module 2>&1 <<'JS'
const harness = await import(process.env.FM_HOOK_HARNESS);
const calls = [];
harness.installChildProcess({
  real: { spawnSync: () => ({ status: 1, stdout: "", stderr: "" }), spawn: () => harness.fakeChild("") },
  lockOwned: () => true,
  operational: () => false,
  onSpawnSync(_command, args, options) {
    calls.push({ mode: args[0], input: options?.input });
    return { status: 0, stdout: "", stderr: "" };
  },
  onSpawn(_command, args) {
    const call = { mode: args[0], input: undefined };
    calls.push(call);
    return harness.fakeChild(`verdict=same target=${args[2]} confidence=model\n`, {
      onInput: (text) => { call.input = text; },
    });
  },
});
const extension = await import(`./.pi/extensions/fm-primary-captain-message-router.ts?session-start-context-test=${Date.now()}`);
const handlers = new Map();
const accumulatedMessages = [];
const injected = [];
const pi = {
  on: (event, handler) => handlers.set(event, handler),
  sendUserMessage: (content) => injected.push(content),
  sendMessage(message) {
    accumulatedMessages.push({
      role: "custom",
      ...message,
      timestamp: 1723500000000,
    });
  },
};
extension.default(pi);
const context = { sessionManager: { getSessionId: () => "session-alpha" } };
const finish = async (assistantText) => {
  await handlers.get("agent_end")({
    type: "agent_end",
    messages: [{ role: "assistant", content: [{ type: "text", text: assistantText }] }],
  }, context);
  await handlers.get("agent_settled")({ type: "agent_settled" }, context);
};

await handlers.get("session_start")({ type: "session_start", reason: "startup" }, context);
pi.sendMessage({
  customType: "firstmate-sessionstart-nudge",
  content: "SENSITIVE STARTUP DIGEST",
  display: false,
  details: { kind: "session-start" },
});
await handlers.get("input")({
  type: "input",
  text: "captain input after startup",
  source: "interactive",
}, context);
await handlers.get("before_agent_start")({
  type: "before_agent_start",
  prompt: "captain input after startup",
}, context);
accumulatedMessages.push({
  role: "user",
  content: [{ type: "text", text: "captain input after startup" }],
  timestamp: 1723500000001,
});
await handlers.get("context")({
  type: "context",
  messages: structuredClone(accumulatedMessages),
}, context);
await handlers.get("context")({
  type: "context",
  messages: structuredClone(accumulatedMessages),
}, context);
await finish("mixed startup response");
accumulatedMessages.push({
  role: "assistant",
  content: [{ type: "text", text: "mixed startup response" }],
  timestamp: 1723500000002,
});

await handlers.get("input")({
  type: "input",
  text: "ordinary captain input",
  source: "interactive",
}, context);
await handlers.get("before_agent_start")({
  type: "before_agent_start",
  prompt: "ordinary captain input",
}, context);
accumulatedMessages.push({
  role: "user",
  content: [{ type: "text", text: "ordinary captain input" }],
  timestamp: 1723500000003,
});
await handlers.get("context")({
  type: "context",
  messages: structuredClone(accumulatedMessages),
}, context);
await finish("ordinary captain response");

await harness.waitFor(
  () => calls.filter((call) => call.mode === "--on-submit" && call.input !== undefined).length === 2,
  "every queued classification to reach the router",
);
console.log(JSON.stringify(calls));
JS
	) || status=$?
	expect_code 0 "$status" "hook session-start context test exit ($out)"
	local submits settles
	submits=$(printf '%s\n' "$out" | grep -o '"mode":"--on-submit"' | wc -l | tr -d ' ')
	settles=$(printf '%s\n' "$out" | grep -o '"mode":"--on-settle"' | wc -l | tr -d ' ')
	[ "$submits" -eq 2 ] || fail "expected both captain inputs to classify exactly once, got $submits ($out)"
	[ "$settles" -eq 1 ] || fail "expected only the captain-only run to settle, got $settles ($out)"
	assert_not_contains "$out" "SENSITIVE STARTUP DIGEST" "the startup digest never reaches the router owner"
	assert_not_contains "$out" "mixed startup response" "the typed startup run cannot publish continuity"
	assert_contains "$out" '"mode":"--on-settle","input":"ordinary captain response"' \
		"an ordinary captain-only run still publishes continuity"
	pass "router: accumulated session-start context invalidates mixed captain continuity"
}

test_verdict_is_logged() {
	local root="$TMP_ROOT/verdict-log" log fakebin
	make_primary "$root"
	printf 'Do you want me to start P0 now?' | run "$root" --on-settle >/dev/null
	fakebin=$(cursor_fixture "$root" log-same 'verdict=same
target=-
explanation=x')
	printf 'yes start P0 now' | run_with_probe "$root" "$fakebin" --on-submit >/dev/null
	fakebin=$(cursor_fixture "$root" log-new 'verdict=new
target=-
explanation=y')
	printf 'unrelated blender thing' | run_with_probe "$root" "$fakebin" --on-submit >/dev/null
	log=$(verdicts_log "$root")
	assert_present "$log" "verdict log must exist after submits"
	local lines
	lines=$(awk 'END{print NR}' "$log")
	[ "$lines" -eq 2 ] || fail "expected 2 verdict rows, got $lines"
	assert_grep "same" "$log" "same verdict recorded"
	assert_grep "new" "$log" "new verdict recorded"
	pass "router: every submit verdict is appended to the log"
}

# The /captain-router slash command is a control surface over the same kill
# switch the bash owner reads. This drives the registered handler for real, so a
# command that silently fails to register fails this test.
test_pi_hook_captain_router_command_reports_and_toggles() {
	local fixture out status=0
	if ! command -v node >/dev/null 2>&1; then
		echo "skip: node not found for the /captain-router command test"
		return 0
	fi
	fixture="$TMP_ROOT/hook-captain-router-command"
	mkdir -p "$fixture/state"
	out=$(
		FM_HOME="$fixture" FM_STATE_OVERRIDE="$fixture/state" \
			FM_CONFIG_OVERRIDE="$fixture/config" \
			FM_OPERATIONAL_INPUT_SCRIPT=/probe/fm-operational-input.sh \
			FM_HOOK_HARNESS="$ROOT/tests/pi-hook-harness.mjs" \
			node --experimental-test-module-mocks --experimental-strip-types --no-warnings \
			--input-type=module 2>&1 <<'JS'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
const harness = await import(process.env.FM_HOOK_HARNESS);
harness.installChildProcess({
  real: { spawnSync: () => ({ status: 1, stdout: "", stderr: "" }), spawn: () => harness.fakeChild("") },
  lockOwned: () => true,
  operational: () => false,
});
const extension = await import(`./.pi/extensions/fm-primary-captain-message-router.ts?router-command-test=${Date.now()}`);
const commands = new Map();
extension.default({
  on: () => {},
  registerCommand: (name, options) => commands.set(name, options),
  sendUserMessage: () => {},
});
if (!commands.has("captain-router")) throw new Error("captain-router command did not register");
const toggleFile = `${process.env.FM_CONFIG_OVERRIDE}/captain-router`;
const notices = [];
const ctx = { ui: { notify: (message, level) => notices.push({ message, level }) } };
const run = async (args) => {
  notices.length = 0;
  await commands.get("captain-router").handler(args, ctx);
  return notices[notices.length - 1];
};
const results = {};
results.description = commands.get("captain-router").description;
results.absent = await run("");
results.turnedOff = await run("off");
results.offFileBytes = JSON.stringify(readFileSync(toggleFile, "utf8"));
results.reportOff = await run("");
results.turnedOn = await run(" ON ");
results.onFileBytes = JSON.stringify(readFileSync(toggleFile, "utf8"));
results.bogus = await run("maybe");
results.fileAfterBogus = JSON.stringify(readFileSync(toggleFile, "utf8"));
// The owner treats an unrecognized file value as on; the report must agree.
writeFileSync(toggleFile, "banana\n");
results.reportUnknownValue = await run("");
writeFileSync(toggleFile, "FALSE\n");
results.reportUppercaseFalse = await run("");
process.env.FM_CAPTAIN_ROUTER_ENABLED = "off";
writeFileSync(toggleFile, "on\n");
results.reportWithEnvOverride = await run("");
results.toggleWithEnvOverride = await run("on");
delete process.env.FM_CAPTAIN_ROUTER_ENABLED;
results.noTempLeft = !existsSync(`${toggleFile}.tmp.${process.pid}`);
console.log(JSON.stringify(results));
JS
	) || status=$?
	expect_code 0 "$status" "/captain-router command test exit ($out)"
	assert_contains "$out" "/captain-router [on|off]" "the command advertises its arguments"
	assert_contains "$out" "absent, and absent means on" \
		"a missing toggle file reports on and says why"
	assert_contains "$out" '"offFileBytes":"\"off\\n\""' \
		"off writes exactly the documented printf form"
	assert_contains "$out" '"onFileBytes":"\"on\\n\""' \
		"on writes exactly the documented printf form"
	assert_contains "$out" "captain-router: off" "turning it off confirms the new state"
	assert_contains "$out" "next captain message, with no restart" \
		"the confirmation states the no-restart semantics"
	assert_contains "$out" "unrecognized argument" "a bogus argument fails loudly"
	assert_contains "$out" "captain-router on, /captain-router off" \
		"the failure names every valid option"
	assert_contains "$out" '"fileAfterBogus":"\"on\\n\""' \
		"a bogus argument never changes the toggle"
	assert_contains "$out" '"reportUnknownValue":{"message":"captain-router: on' \
		"an unrecognized file value reports on, matching the owner"
	assert_contains "$out" '"reportUppercaseFalse":{"message":"captain-router: off' \
		"FALSE disables, matching the owner"
	assert_contains "$out" "FM_CAPTAIN_ROUTER_ENABLED is set" \
		"the report discloses an environment override"
	assert_contains "$out" "until that variable is unset" \
		"a write under an environment override warns that the file is not effective"
	assert_contains "$out" '"noTempLeft":true' "the atomic write leaves no temp file"
	pass "router: /captain-router reports and toggles the kill switch"
}

test_pi_hook_threads_bounded_redacted_history() {
	local fixture out status=0
	if ! command -v node >/dev/null 2>&1; then
		echo "skip: node not found for the Pi hook wiring test"
		return 0
	fi
	fixture="$TMP_ROOT/hook-history"
	mkdir -p "$fixture/bin" "$fixture/state" "$fixture/.pi/extensions/lib"
	# The extension resolves its owner relative to its own file, so mirror the
	# real extension (and its canonical operational-input adapter) into a fixture
	# tree whose bin/ holds a recording stub instead of the real owner.
	cp "$ROOT/.pi/extensions/fm-primary-captain-message-router.ts" "$fixture/.pi/extensions/"
	cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$fixture/.pi/extensions/lib/"
	# A stub router owner: record the argv and the history file it was handed.
	cat >"$fixture/bin/fm-captain-message-router.sh" <<'SH'
#!/usr/bin/env bash
set -u
input=$(cat)
printf '%s\n' "$@" >>"$FM_STATE_OVERRIDE/hook-argv.txt"
if [ "${1-}" = --on-settle ]; then
	printf '%s\n' "$input" >>"$FM_STATE_OVERRIDE/hook-settle-log.txt"
fi
while [ "$#" -gt 0 ]; do
	if [ "$1" = --chat-history-file ]; then
		{
			printf '%s\n' '--- history ---'
			cat "$2"
		} >>"$FM_STATE_OVERRIDE/hook-history-log.txt"
		cat "$2" >"$FM_STATE_OVERRIDE/hook-history.txt"
		break
	fi
	shift
done
printf 'verdict=same target=primary confidence=model\n'
SH
	chmod +x "$fixture/bin/fm-captain-message-router.sh"
	out=$(
		EXT="$fixture/.pi/extensions/fm-primary-captain-message-router.ts" \
			FM_HOME="$fixture" FM_STATE_OVERRIDE="$fixture/state" \
			FM_ROOT_OVERRIDE="$fixture" \
			FM_OPERATIONAL_INPUT_SCRIPT="$ROOT/bin/fm-operational-input.sh" \
			FM_HOOK_HARNESS="$ROOT/tests/pi-hook-harness.mjs" \
			node --experimental-test-module-mocks --experimental-strip-types --no-warnings \
			--input-type=module 2>&1 <<'JS'
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const harness = await import(process.env.FM_HOOK_HARNESS);
// Everything but the lock probe runs the real stub owner through a real spawn,
// so this case still crosses the production child-process boundary.
harness.installChildProcess({
  real: await import("node:child_process"),
  lockOwned: () => true,
});
const extensionUrl = pathToFileURL(process.env.EXT);
extensionUrl.search = `history-test=${Date.now()}`;
const extension = await import(extensionUrl.href);
const handlers = new Map();
const injected = [];
extension.default({
  on: (event, handler) => handlers.set(event, handler),
  sendUserMessage: (content) => injected.push(content),
});
const argvPath = `${process.env.FM_STATE_OVERRIDE}/hook-argv.txt`;
const submitCount = () => {
  try {
    return readFileSync(argvPath, "utf8").split("\n").filter((line) => line === "--on-submit").length;
  } catch {
    return 0;
  }
};
const say = (role, text) => ({ role, content: [{ type: "text", text }] });
const context = (id) => ({ sessionManager: { getSessionId: () => id } });
await handlers.get("input")(
  { type: "input", text: "session alpha captain turn", source: "interactive" },
  context("session-alpha"),
);
await handlers.get("before_agent_start")(
  {
    type: "before_agent_start",
    prompt: "session alpha captain turn",
  },
  context("session-alpha"),
);
await handlers.get("agent_end")(
  {
    type: "agent_end",
    messages: [
      say("user", "session alpha captain history"),
      say("assistant", "session alpha assistant history"),
    ],
  },
  context("session-alpha"),
);
await handlers.get("session_start")(
  { type: "session_start", reason: "resume" },
  context("session-beta"),
);
await handlers.get("input")(
  { type: "input", text: "first session beta captain turn", source: "interactive" },
  context("session-beta"),
);
await handlers.get("before_agent_start")(
  {
    type: "before_agent_start",
    prompt: "first session beta captain turn",
  },
  context("session-beta"),
);
await handlers.get("agent_end")(
  {
    type: "agent_end",
    messages: [
      say("user", "initial session beta captain turn"),
      say("assistant", "initial session beta assistant reply"),
    ],
  },
  context("session-beta"),
);
await handlers.get("agent_settled")({}, context("session-beta"));
await handlers.get("input")(
  {
    type: "input",
    text: "\u2063FIRSTMATE_OP: v1 watcher: run bin/fm-wake-drain.sh now",
    source: "extension",
  },
  context("session-beta"),
);
await handlers.get("before_agent_start")(
  {
    type: "before_agent_start",
    prompt: "\u2063FIRSTMATE_OP: v1 watcher: run bin/fm-wake-drain.sh now",
  },
  context("session-beta"),
);
await handlers.get("agent_end")(
  {
    type: "agent_end",
    messages: [
      say("user", "\u2063FIRSTMATE_OP: v1 watcher: run bin/fm-wake-drain.sh now"),
      say("assistant", "operational response must not become history"),
    ],
  },
  context("session-beta"),
);
await handlers.get("agent_settled")({}, context("session-beta"));
await handlers.get("input")(
  { type: "input", text: "first eligible session beta turn", source: "interactive" },
  context("session-beta"),
);
await handlers.get("before_agent_start")(
  {
    type: "before_agent_start",
    prompt: "first eligible session beta turn",
  },
  context("session-beta"),
);
await handlers.get("agent_end")(
  {
    type: "agent_end",
    messages: [
      say("user", "older captain turn about the exporter"),
      say("assistant", "assistant reply about the exporter"),
    ],
  },
  context("session-beta"),
);
await handlers.get("agent_settled")({}, context("session-beta"));
await handlers.get("input")(
  { type: "input", text: "second session beta captain turn", source: "interactive" },
  context("session-beta"),
);
await handlers.get("before_agent_start")(
  {
    type: "before_agent_start",
    prompt: "second session beta captain turn",
  },
  context("session-beta"),
);
await harness.waitFor(() => submitCount() >= 4, "all four captain submits to reach the owner");
console.log("hook-ok");
JS
	) || status=$?
	expect_code 0 "$status" "hook wiring exit ($out)"
	assert_contains "$out" "hook-ok" "the hook ran both handlers"
	assert_grep "chat-history-file" "$fixture/state/hook-argv.txt" \
		"the hook passes a chat-history file to the bash owner on submit"
	assert_present "$fixture/state/hook-history.txt" "the hook wrote a transcript excerpt"
	assert_grep "older captain turn about the exporter" "$fixture/state/hook-history.txt" \
		"the excerpt carries the recent captain turns"
	assert_grep "assistant reply about the exporter" "$fixture/state/hook-history.txt" \
		"the excerpt carries the recent assistant turns"
	assert_no_grep "session alpha" "$fixture/state/hook-history.txt" \
		"a replacement session never receives the previous session transcript"
	assert_no_grep "session alpha" "$fixture/state/hook-history-log.txt" \
		"no owner call for a replacement session receives the previous transcript"
	assert_no_grep "FIRSTMATE_OP" "$fixture/state/hook-history.txt" \
		"the hook drops Firstmate operational injections from the excerpt"
	assert_no_grep "operational response must not become history" "$fixture/state/hook-history-log.txt" \
		"an operational run cannot replace the captain conversation history"
	assert_no_grep "operational response must not become history" "$fixture/state/hook-settle-log.txt" \
		"an operational run cannot replace the session anchors"
	assert_grep "assistant reply about the exporter" "$fixture/state/hook-settle-log.txt" \
		"the next eligible captain run still refreshes the session brief"
	assert_present "$fixture/state/.pi-captain-router-extension-loaded" \
		"the router extension writes its versioned loaded marker"
	assert_grep "sha256:" "$fixture/state/.pi-captain-router-extension-loaded" \
		"the router loaded marker carries the extension version"
	pass "router: the Pi hook keeps bounded history within its context session"
}

# --- delivery (--deliver) ---------------------------------------------------

# herdr_delivery_fake <root>: a fake `herdr` on PATH satisfying the whole
# visible-pane path a delivery uses (protocol check, socket identity, launcher
# pane/tab/workspace resolution, tab create, pane run), recording every call so
# a test can assert what was actually launched. FM_FAKE_HERDR_FAIL selects one
# subcommand to fail, so each refusal branch needs no second fixture.
herdr_delivery_fake() { # <root>
	local root=$1 fakebin
	fakebin="$root/fakebin-herdr"
	mkdir -p "$fakebin"
	cat >"$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"${FM_HERDR_LOG:?}"
cmd=${1:-}
sub=${2:-}
case "${FM_FAKE_HERDR_FAIL:-}" in
"$cmd $sub") exit 1 ;;
esac
ws=
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
	case "${args[$i]}" in
	--workspace) ws=${args[$((i + 1))]:-} ;;
	esac
done
case "$cmd $sub" in
"status --json") printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n' ;;
"session list") printf '{"sessions":[{"name":"%s","running":true,"socket_path":"%s"}]}\n' "${HERDR_SESSION:-default}" "${FM_FAKE_HERDR_SOCKET:?}" ;;
"pane get") printf '{"result":{"pane":{"pane_id":"%s","tab_id":"w9:t1","workspace_id":"w9"}}}\n' "${3:-}" ;;
"tab get") printf '{"result":{"tab":{"tab_id":"%s","workspace_id":"w9"}}}\n' "${3:-}" ;;
"workspace list") printf '{"result":{"workspaces":[{"workspace_id":"w9","label":"home"}]}}\n' ;;
"tab create") printf '{"result":{"tab":{"tab_id":"%s:t7"},"root_pane":{"pane_id":"%s:p7"}}}\n' "$ws" "$ws" ;;
"pane run" | "pane close") : ;;
*) exit 1 ;;
esac
exit 0
SH
	chmod +x "$fakebin/herdr"
	printf '%s\n' "$fakebin"
}

# stage_route <root> <verdict> <target> <message>: stage one route through the
# production classify path, so a delivery test consumes a real staged route
# rather than a hand-written imitation of one.
stage_route() {
	local root=$1 verdict=$2 target=$3 message=$4 fakebin
	fakebin=$(cursor_fixture "$root" "stage-$verdict" "verdict=$verdict
target=$target
explanation=router private reasoning about the captain")
	printf '%s' "$message" |
		run_with_probe "$root" "$fakebin" --on-submit --session-id primary >/dev/null
}

# deliver <root> <fakebin> <route> [env...]: run --deliver with only the fake
# herdr resolvable and a verifiable launcher pane identity in the environment.
deliver() {
	local root=$1 fakebin=$2 route=$3
	shift 3
	env PATH="$fakebin:$PATH" FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$root" \
		FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" FM_CONFIG_OVERRIDE="$root/config" \
		FM_HERDR_LOG="$root/herdr.log" FM_FAKE_HERDR_SOCKET="$root/herdr.sock" \
		FM_CAPTAIN_ROUTER_SESSION_STORE="$root/pi-sessions" \
		HERDR_ENV=1 HERDR_PANE_ID=w9:p1 HERDR_SESSION=default \
		HERDR_SOCKET_PATH="$root/herdr.sock" "$@" \
		"$ROUTER" --deliver "$route"
}

# make_delivery_home <root>: a herdr-backed primary with a settled submitting
# session and a settled, routable reroute destination.
make_delivery_home() {
	local root=$1
	make_primary "$root"
	printf 'herdr\n' >"$root/config/backend"
	: >"$root/herdr.sock"
	printf 'Should I continue the shader review?' |
		run "$root" --on-settle --session-id sess-shader >/dev/null
	# The submitting session settles last, so it is the current one.
	printf 'Shall I continue here?' | run "$root" --on-settle --session-id primary >/dev/null
	# Pi's own session store, which is what makes a reroute target resumable. A
	# brief outlives its session, so the store is the separate fact.
	mkdir -p "$root/pi-sessions"
	: >"$root/pi-sessions/2026-08-14T00-00-00-000Z_sess-shader.jsonl"
}

latest_route() {
	local pending
	pending=$(pending_dir "$1")
	printf '%s/%s' "$pending" "$(cat "$pending/LATEST")"
}

seed_file() {
	find "$1/state/captain-router" -maxdepth 1 -name 'seed.*' -type f 2>/dev/null | head -1
}

test_deliver_reroute_resumes_the_target_in_a_visible_pane() {
	local root="$TMP_ROOT/deliver-reroute" fakebin route out status=0 log seed
	make_delivery_home "$root"
	stage_route "$root" reroute sess-shader 'the shader normals still look inverted'
	route=$(latest_route "$root")
	fakebin=$(herdr_delivery_fake "$root")
	out=$(deliver "$root" "$fakebin" "$route") || status=$?
	expect_code 0 "$status" "a satisfied delivery path exits 0"
	assert_contains "$out" "delivery=delivered kind=reroute" "delivery reports itself machine-readably"
	assert_contains "$out" "reason=ok" "a confirmed delivery carries no failure reason"
	log="$root/herdr.log"
	assert_grep "tab create" "$log" "a reroute opens a real tab"
	assert_grep "captain-reroute-sess-shader" "$log" "the tab is labeled for its destination"
	assert_grep "no-focus" "$log" "delivery never steals the captain's focus"
	# What makes a reroute a reroute rather than a fresh chat: the target session
	# is resumed, so its own prior context is what answers the message.
	assert_grep "pi --session sess-shader" "$log" "the pane resumes the routed target session"
	# The seed rides a file, so a large captain paste never enters the process list.
	assert_grep " @$root/state/captain-router/seed." "$log" "the launch seeds from a file, not argv"
	seed=$(seed_file "$root")
	[ -n "$seed" ] || fail "delivery wrote no seed file"
	assert_grep "the shader normals still look inverted" "$seed" "the seed carries the captain message verbatim"
	assert_grep "/compact" "$seed" "a resumed session is told to compact itself first"
	# The router's private reasoning about the captain is audit-only.
	assert_no_grep "router private reasoning" "$seed" "the explanation never reaches the captain's own conversation"
	assert_absent "$route" "a confirmed delivery consumes its staged route"
	assert_absent "$(pending_dir "$root")/LATEST" "the consumed route is no longer the published latest"
	pass "router: a delivered reroute resumes the target session in a visible pane"
}

test_deliver_new_opens_a_fresh_visible_pane() {
	local root="$TMP_ROOT/deliver-new" fakebin route out status=0 log seed
	make_delivery_home "$root"
	stage_route "$root" new - 'unrelated: can you look at the blender exporter'
	route=$(latest_route "$root")
	fakebin=$(herdr_delivery_fake "$root")
	out=$(deliver "$root" "$fakebin" "$route") || status=$?
	expect_code 0 "$status" "a new-session delivery exits 0"
	assert_contains "$out" "delivery=delivered kind=new" "the new delivery reports itself"
	log="$root/herdr.log"
	assert_grep "captain-new-" "$log" "a new session gets its own labeled tab"
	# Every herdr call carries its own --session, so the resume marker to look for
	# is the one on the launched Pi itself.
	assert_no_grep "pi --session" "$log" "a new session never resumes an existing one"
	seed=$(seed_file "$root")
	[ -n "$seed" ] || fail "delivery wrote no seed file"
	assert_grep "blender exporter" "$seed" "the seed carries the captain message"
	assert_no_grep "/compact" "$seed" "a fresh session has nothing to compact"
	pass "router: a delivered new verdict opens a fresh visible pane"
}

test_delivered_pane_is_not_a_second_firstmate() {
	local root="$TMP_ROOT/deliver-inert" fakebin route log
	make_delivery_home "$root"
	stage_route "$root" reroute sess-shader 'back to the shader work'
	route=$(latest_route "$root")
	fakebin=$(herdr_delivery_fake "$root")
	deliver "$root" "$fakebin" "$route" >/dev/null
	log="$root/herdr.log"
	# A delivered pane is an ordinary captain conversation: it must never take
	# this home's fleet lock, arm a watcher, or run the session-start digest.
	assert_grep "FM_CAPTAIN_ROUTER_DELIVERED=1" "$log" "a delivered pane marks itself as one"
	assert_no_grep "fm-session-start" "$log" "a delivered pane never runs session start"
	assert_no_grep "fm-watch-arm" "$log" "a delivered pane never arms a watcher"
	pass "router: a delivered pane is a plain conversation, not a second Firstmate"
}

test_every_delivery_refusal_keeps_the_message_staged() {
	local root="$TMP_ROOT/deliver-refuse" fakebin route out status
	make_delivery_home "$root"
	stage_route "$root" reroute sess-shader 'the message that must never be lost'
	route=$(latest_route "$root")
	fakebin=$(herdr_delivery_fake "$root")
	# Every refusal runs against the SAME staged route, so each one also proves
	# the message survived the refusal before it.
	status=0
	out=$(deliver "$root" "$fakebin" "$route" FM_BACKEND=tmux) || status=$?
	expect_code 1 "$status" "a non-herdr backend refuses"
	assert_contains "$out" "delivery=undelivered" "a refusal says so"
	assert_contains "$out" "reason=backend-not-herdr" "the refusal names the missing half of the path"
	assert_present "$route" "a refused delivery leaves the message staged"
	# No verifiable launcher pane: nothing identifies which visible workspace the
	# captain is looking at, and guessing one is worse than refusing.
	status=0
	out=$(deliver "$root" "$fakebin" "$route" HERDR_PANE_ID=) || status=$?
	expect_code 1 "$status" "an unverifiable launcher identity refuses"
	assert_contains "$out" "reason=no-visible-workspace" "the refusal names the missing workspace"
	assert_present "$route" "the message survived the placement refusal"
	# The pane exists but the launch never went in: the captain must not be left
	# staring at a dead tab, and the message must stay staged.
	status=0
	out=$(deliver "$root" "$fakebin" "$route" FM_FAKE_HERDR_FAIL='pane run') || status=$?
	expect_code 1 "$status" "a failed launch refuses"
	assert_contains "$out" "reason=launch-failed" "the refusal names the failed launch"
	assert_grep "pane close" "$root/herdr.log" "a failed launch closes its own dead tab"
	assert_present "$route" "the message survived the launch failure"
	# The destination's conversation is gone from Pi's session store while its
	# brief survives. `pi --session <id>` is create-if-missing, so delivering here
	# would open an EMPTY session: it would report success while stranding the
	# message in a pane holding none of the context it was routed for.
	status=0
	rm -f "$root/pi-sessions/"*_sess-shader.jsonl
	: >"$root/herdr.log"
	out=$(deliver "$root" "$fakebin" "$route") || status=$?
	expect_code 1 "$status" "a target whose session no longer exists refuses"
	assert_contains "$out" "reason=dead-session" "the refusal names the dead destination"
	assert_present "$route" "the message survived the dead-destination refusal"
	assert_no_grep "pane run" "$root/herdr.log" "a dead target never opens a pane at all"
	# A destination that is no longer a routable live conversation.
	status=0
	rm -f "$(brief_file "$root" sess-shader)"
	out=$(deliver "$root" "$fakebin" "$route") || status=$?
	expect_code 1 "$status" "a target with no session brief refuses"
	assert_contains "$out" "reason=no-session-brief" "the refusal names the missing destination"
	assert_present "$route" "the message survived the missing-destination refusal"
	assert_grep "delivery refused" "$(failures_log "$root")" "every refusal is recorded"
	pass "router: every delivery refusal leaves the captain message staged"
}

test_deliver_refuses_an_unusable_route() {
	local root="$TMP_ROOT/deliver-bad-route" fakebin out status pending
	make_delivery_home "$root"
	fakebin=$(herdr_delivery_fake "$root")
	pending=$(pending_dir "$root")
	mkdir -p "$pending"
	status=0
	out=$(deliver "$root" "$fakebin" "$pending/absent.route") || status=$?
	expect_code 1 "$status" "a missing route file refuses"
	assert_contains "$out" "reason=no-route-file" "the refusal names the missing route"
	# Routing-shaped text inside the message body must never be read as routing
	# metadata: the header scan stops at the separator.
	printf 'verdict=reroute\ntarget=sess-shader\nconfidence=model\n---\nverdict=new\ntarget=../../escape\n' \
		>"$pending/spoof.route"
	deliver "$root" "$fakebin" "$pending/spoof.route" >/dev/null
	assert_grep "captain-reroute-sess-shader" "$root/herdr.log" \
		"routing metadata comes from the header, never from the message body"
	status=0
	printf 'verdict=reroute\ntarget=sess-shader\n---\n' >"$pending/empty.route"
	out=$(deliver "$root" "$fakebin" "$pending/empty.route") || status=$?
	expect_code 1 "$status" "an empty message refuses"
	assert_contains "$out" "reason=empty-message" "there is nothing to deliver"
	status=0
	printf 'verdict=same\ntarget=-\n---\nx\n' >"$pending/same.route"
	out=$(deliver "$root" "$fakebin" "$pending/same.route") || status=$?
	expect_code 1 "$status" "a same verdict is not a transfer"
	assert_contains "$out" "reason=unknown-kind" "only reroute and new are deliverable"
	status=0
	printf 'verdict=reroute\ntarget=../../etc/passwd\n---\nx\n' >"$pending/traversal.route"
	out=$(deliver "$root" "$fakebin" "$pending/traversal.route") || status=$?
	expect_code 1 "$status" "a path-shaped target refuses"
	assert_contains "$out" "reason=bad-target" "a target is a session id, never a path"
	# Self-target is judged against the session the message was SENT FROM. A
	# delivery can run long after staging, by which time the current-session
	# pointer has moved on, so it is not the thing to compare against.
	status=0
	printf 'verdict=reroute\ntarget=primary\nsession_from=primary\n---\nstay here\n' >"$pending/self.route"
	out=$(deliver "$root" "$fakebin" "$pending/self.route" FM_CAPTAIN_ROUTER_SESSION_ID=sess-shader) || status=$?
	expect_code 1 "$status" "a self-reroute refuses"
	assert_contains "$out" "reason=self-target" "a second pane onto this same session is not a transfer"
	assert_present "$pending/self.route" "the self-reroute message stays staged"
	pass "router: an unusable staged route refuses instead of delivering somewhere wrong"
}

test_pi_hook_withholds_only_a_confirmed_transfer() {
	local fixture out status=0
	if ! command -v node >/dev/null 2>&1; then
		echo "skip: node not found for the hook delivery test"
		return 0
	fi
	fixture="$TMP_ROOT/hook-delivery"
	mkdir -p "$fixture/state/captain-router/pending"
	printf 'staged.route\n' >"$fixture/state/captain-router/pending/LATEST"
	: >"$fixture/state/captain-router/pending/staged.route"
	out=$(
		FM_STATE_OVERRIDE="$fixture/state" FM_OPERATIONAL_INPUT_SCRIPT=/probe/fm-operational-input.sh \
			FM_HOOK_HARNESS="$ROOT/tests/pi-hook-harness.mjs" \
			node --experimental-test-module-mocks --experimental-strip-types --no-warnings \
			--input-type=module 2>&1 <<'JS'
const harness = await import(process.env.FM_HOOK_HARNESS);
const injected = [];
const delivers = [];
// Two non-same verdicts that differ only in whether their transfer lands.
const verdicts = new Map([
  ["moves away", "verdict=reroute target=sess-shader confidence=model\n"],
  ["cannot move", "verdict=new target=- confidence=model\n"],
]);
harness.installChildProcess({
  real: { spawnSync: () => ({ status: 1, stdout: "", stderr: "" }), spawn: () => harness.fakeChild("") },
  lockOwned: () => true,
  operational: (text) => text.includes("FIRSTMATE_OP:"),
  onSpawnSync: () => ({ status: 0, stdout: "", stderr: "" }),
  onSpawn(_command, args) {
    if (args?.[0] === "--deliver") {
      delivers.push(args[1]);
      return delivers.length === 1
        ? harness.fakeChild("delivery=delivered kind=reroute target=default:w9:p7 reason=ok\n")
        : harness.fakeChild("delivery=undelivered kind=new target=- reason=backend-not-herdr\n");
    }
    const call = { stdout: "" };
    return harness.fakeChild(() => call.stdout, {
      onInput: (text) => { call.stdout = verdicts.get(text) ?? ""; },
    });
  },
});
const extension = await import(`./.pi/extensions/fm-primary-captain-message-router.ts?delivery-test=${Date.now()}`);
const handlers = new Map();
extension.default({
  on: (event, handler) => handlers.set(event, handler),
  sendUserMessage: (content) => injected.push(typeof content === "string" ? content : content[0].text),
});
const context = { sessionManager: { getSessionId: () => "session-alpha" } };
const send = (text) => handlers.get("input")({ type: "input", text, source: "interactive" }, context);
await send("moves away");
await harness.waitFor(() => delivers.length >= 1, "the first transfer to be attempted");
await send("cannot move");
await harness.waitFor(() => delivers.length >= 2, "the second transfer to be attempted");
await harness.waitFor(() => injected.length >= 1, "the refused message to come back");
await new Promise((resolve) => setTimeout(resolve, 100));
console.log(JSON.stringify({ injected, deliverCalls: delivers.length }));
JS
	) || status=$?
	expect_code 0 "$status" "hook delivery test exit ($out)"
	# The point of a verdict: a confirmed transfer means the captain reads the
	# answer in the session it belonged to, so answering here too would duplicate it.
	assert_contains "$out" '"deliverCalls":2' "every non-same verdict attempts a real transfer"
	assert_not_contains "$out" '"moves away"' "a confirmed transfer is not also answered here"
	# The invariant that outranks it: a refused transfer is never a lost message.
	assert_contains "$out" '"cannot move"' "a refused transfer comes back to the current session"
	assert_grep "delivered=no" "$fixture/state/captain-router/last-handoff.txt" \
		"the handoff record never claims a transfer that did not happen"
	pass "router: a verdict withholds the message only when the transfer is confirmed"
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
	local base="$TMP_ROOT/sm-base" root="$TMP_ROOT/sm-home" out status=0 fakebin
	fm_git_worktree "$base" "$root" fm/captain-router-sm
	mkdir -p "$root/bin" "$root/state"
	: >"$root/AGENTS.md"
	printf 'captain-router-sm\n' >"$root/.fm-secondmate-home"
	printf 'Do you want me to proceed now?' | run "$root" --on-settle >/dev/null
	fakebin=$(cursor_fixture "$root" secondmate 'verdict=same
target=-
explanation=x')
	out=$(printf 'yes proceed now' |
		run_with_probe "$root" "$fakebin" --on-submit) || status=$?
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
test_submit_direct_address_stays_in_the_current_session
test_submit_always_spawns_the_model
test_warm_runner_serves_every_submit_from_one_process
test_warm_runner_absence_falls_back_to_the_ephemeral_spawn
test_submit_model_sees_briefs_history_and_message
test_chat_history_is_bounded_and_redacted
test_explanation_recorded_but_never_forwarded
test_submit_model_spawn_failure_fail_open
test_submit_model_timeout_fail_open
test_submit_garbage_verdict_fail_open
test_submit_reroute_target_is_validated
test_submit_project_brief_is_never_a_reroute_target
test_submit_first_message_of_a_session_skips_the_model
test_submit_toggle_off_passes_every_message_through
test_submit_new_and_same_targets_are_normalized
test_model_override_keeps_cursor_cli_read_only
test_builtin_default_uses_cursor_cli_read_only
test_submit_prompt_rides_the_file_not_argv
test_submit_prompt_handoff_failures_fail_open
test_submit_dependency_free_timeout_terminates_hung_spawn
test_submit_large_timeout_override_reaches_shared_owner
test_new_route_publication_failure_falls_back_to_same
test_reroute_publication_failure_falls_back_to_same
test_repeated_route_staging_preserves_published_latest
test_pi_hook_uses_context_session_ids_without_outer_timeout
test_pi_hook_classifies_queued_input_and_rejects_mixed_runs
test_pi_hook_holds_the_send_without_blocking_the_input_path
test_pi_hook_rejects_typed_session_start_context
test_pi_hook_captain_router_command_reports_and_toggles
test_verdict_is_logged
test_pi_hook_threads_bounded_redacted_history
test_deliver_reroute_resumes_the_target_in_a_visible_pane
test_deliver_new_opens_a_fresh_visible_pane
test_delivered_pane_is_not_a_second_firstmate
test_every_delivery_refusal_keeps_the_message_staged
test_deliver_refuses_an_unusable_route
test_pi_hook_withholds_only_a_confirmed_transfer
test_inert_in_child_worktree
test_marked_secondmate_home_is_active
test_gate_agent_is_inert
test_bad_usage_exits_two
test_help_prints_usage
