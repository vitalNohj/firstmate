#!/usr/bin/env bash
# tests/fake-pi-rpc.sh - stand-in Pi RPC child for the warm classifier tests.
#
# Speaks just enough of Pi's RPC protocol for bin/fm-captain-router-runner.mjs:
# it answers new_session, emits one assistant reply plus agent_settled per
# prompt, and records every launch and prompt. The launch count is what proves
# a warm process served several submits instead of booting per message.
#
# FM_FAKE_PI_LOG   - directory for pi-launches.txt and pi-prompts.txt.
# FM_FAKE_PI_REPLY - file holding the JSON string literal to answer with.
set -u

log_dir=${FM_FAKE_PI_LOG:?FM_FAKE_PI_LOG is required}
reply_file=${FM_FAKE_PI_REPLY:?FM_FAKE_PI_REPLY is required}
printf 'launch\n' >>"$log_dir/pi-launches.txt"

while IFS= read -r line; do
	case "$line" in
	*'"new_session"'*)
		id=${line#*\"id\":\"}
		id=${id%%\"*}
		printf '{"type":"response","command":"new_session","id":"%s","success":true}\n' "$id"
		;;
	*'"prompt"'*)
		printf 'prompt\n' >>"$log_dir/pi-prompts.txt"
		printf '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":%s}]}}\n' \
			"$(cat "$reply_file")"
		printf '{"type":"agent_settled"}\n'
		;;
	esac
done
