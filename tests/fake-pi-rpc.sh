#!/usr/bin/env bash
# tests/fake-pi-rpc.sh - stand-in Pi RPC child for the warm classifier tests.
#
# Speaks just enough of Pi's RPC protocol for bin/fm-captain-router-runner.mjs:
# it answers new_session, emits one assistant reply plus agent_settled per
# prompt, and records every launch and prompt. The launch count is what proves
# a warm process served several submits instead of booting per message.
#
# It also stands in for Pi's extension discovery so the classifier's
# --no-extensions guarantee is testable: real Pi auto-loads this home's primary
# extensions in any child that omits the flag, and the watcher extension then
# stamps state/.pi-watch-extension-loaded with its own pid and claims the
# watcher generation. This fake reproduces exactly that marker write, so a
# regression that drops --no-extensions makes the marker tests fail.
#
# FM_FAKE_PI_LOG          - directory for pi-launches.txt, pi-args.txt and pi-prompts.txt.
# FM_FAKE_PI_REPLY        - file holding the JSON string literal to answer with.
# FM_FAKE_PI_WATCH_MARKER - optional marker path to stamp when extensions load.
set -u

log_dir=${FM_FAKE_PI_LOG:?FM_FAKE_PI_LOG is required}
reply_file=${FM_FAKE_PI_REPLY:?FM_FAKE_PI_REPLY is required}
printf 'launch\n' >>"$log_dir/pi-launches.txt"
printf '%s\n' "$@" >>"$log_dir/pi-args.txt"

extensions_disabled=0
for arg in "$@"; do
	case "$arg" in
	--no-extensions | -ne) extensions_disabled=1 ;;
	esac
done
if [ "$extensions_disabled" -eq 0 ] && [ -n "${FM_FAKE_PI_WATCH_MARKER:-}" ]; then
	printf 'sha256:fake\n%s\n' "$$" >"$FM_FAKE_PI_WATCH_MARKER"
fi

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
