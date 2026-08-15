#!/usr/bin/env bash
# fm-captain-message-router.sh - Captain-message continuity router (bash owner).
#
# NOT watcher continuity. This has nothing to do with docs/watcher-continuity.md,
# the supervision/watcher cycle, or bin/fm-continuity-*. This owner routes an
# incoming CAPTAIN CHAT MESSAGE relative to primary-session open asks and
# per-session briefs so a late or unrelated reply does not silently steer the
# wrong turn. See docs/captain-message-router.md for current behavior.
#
# The Firstmate PRIMARY agent never runs this itself. The Pi hook owns eligible
# callback and session selection; this script owns router state, classification,
# verdict normalization and staging, and fail-open fallback. Submit ALWAYS spawns
# an ephemeral router agent: the model decides the verdict, and the deterministic
# layer survives only as the fail-open fallback. The built-in profile reuses
# upstream Firstmate's verified Cursor Agent CLI owner.
#
# Modes (assistant message or captain message on stdin):
#   fm-captain-message-router.sh --on-settle [--session-id <id>]
#   fm-captain-message-router.sh --on-submit [--session-id <id>] [--chat-history-file <path>]
#   fm-captain-message-router.sh --deliver <pending-route-file>
#   fm-captain-message-router.sh --help
#
# --on-settle: extract question anchors (split on `?`, normalized, deduped) and
#   overwrite the current open-ask set. Also refresh
#   state/captain-router/sessions/<session-id>.brief (topic head + anchors) and
#   record the current session id. Deterministic multi-ask verification: if two
#   or more questions were asked but fewer than two distinct anchors survive,
#   surface a one-line warning to stderr (never blocks). stdout stays empty.
#
# --on-submit: classify the message and print exactly one machine-readable
#   verdict line to stdout:
#     verdict=<same|reroute|new> target=<session-id|-> confidence=<det|model>
#   The ephemeral Cursor router agent is spawned on EVERY submit. Its prompt carries the role
#   instructions, a bounded redacted recent-chat excerpt, every session brief,
#   and the captain message. It must answer with a three-line block:
#     verdict=<same|reroute|new>
#     target=<session-id|->
#     explanation=<up to 3 sentences>
#   `explanation` is recorded (explanations.log + the staged pending route) and
#   is NEVER forwarded into the routed/new session context. A model verdict is
#   recorded with confidence=model. Spawn error, timeout, unparseable output, or
#   pending-route publication failure fails open to `same` against the current
#   session with confidence=det and a failures.log row. Every surfaced verdict is
#   appended to verdicts.log. Reroute/new also stage a durable pending route under
#   state/captain-router/pending/, which --deliver then consumes.
#
# --deliver <pending-route-file>: transfer one staged route to its destination
#   and print one machine-readable line:
#     delivery=<delivered|undelivered> kind=<reroute|new> target=<pane|-> reason=<token>
#   A `reroute` resumes the target session in a NEW visible Herdr pane
#   (`pi --session <target>`), because Pi compaction and injection are
#   session-LOCAL: no API reaches into another live Pi process (see
#   docs/captain-message-router.md "Cross-session delivery"). A `new` opens a
#   fresh visible pane with no --session. Either way the captain gets a real tab
#   they can see and type in, seeded with the message plus a small brief, and
#   compaction is requested of the target session itself through its seed.
#   Delivery is refused unless this home's backend is herdr and the launching
#   process sits in a herdr pane, so the new tab lands in the captain's own
#   visible workspace rather than an invisible background process.
#   The staged route file is consumed (removed) only after a delivery is
#   confirmed; every refusal leaves it staged so nothing is ever lost.
#   Exit status is 0 for a confirmed delivery and non-zero otherwise, so a
#   caller can fall back to delivering the message into the current session.
#
#   Two submits never reach the model at all, because neither can have an answer
#   worth a spawn:
#     - the router is toggled off (see the toggle below);
#     - the current session has no session brief yet, so this is its first
#       message and there is no prior conversation to route away from.
#   Both emit `same` against the current session with confidence=det.
#
# Toggle: config/captain-router (or FM_CAPTAIN_ROUTER_ENABLED) holding `off`,
#   `0`, or `false` disables classification. Absent or any other value means on.
#   The value is read per invocation, so a toggle takes effect on the next
#   captain message without restarting Pi. A disabled submit still records its
#   `same` verdict, so verdicts.log stays a complete audit of every message.
#   --on-settle keeps refreshing briefs while off, so re-enabling is immediate.
#
# --chat-history-file <path>: optional bounded recent-transcript excerpt for the
#   submit prompt. The harness hook writes it; this owner re-bounds it
#   (FM_CAPTAIN_ROUTER_HISTORY_CHARS, default 6000; last lines kept) and redacts
#   Firstmate operational injections and secret-shaped values before the model
#   ever sees it. Absent or empty means the model gets briefs + message only.
#
# Session id (assumption, labeled): prefer --session-id, else
#   FM_CAPTAIN_ROUTER_SESSION_ID, else the prior current.session pointer, else
#   the stable home-scoped fallback `primary`. Hooks should pass the harness
#   session id when available.
#
# State (all local-only, never committed), under $STATE/captain-router/:
#   anchors.current       - one normalized open-ask anchor per line (settle)
#   current.session       - session id for the live primary this home last settled
#   sessions/<id>.brief   - per-session topic head + anchors (kind=session), or a
#                           hand-written project context brief (no kind=session).
#                           Only a kind=session brief is a routable reroute
#                           target: a project brief describes a body of work, not
#                           a live conversation, so routing a message there would
#                           send it somewhere no session can ever receive it.
#   pending/<ts>-<digest>-<unique>.route - staged reroute/new handoff for later delivery
#   pending/LATEST        - basename of the most recent pending route file
#   verdicts.log          - append-only verdict rows
#   explanations.log      - append-only model rationale rows, keyed by the same
#                           message digest as verdicts.log (audit only, never
#                           forwarded into any session prompt)
#   failures.log          - append-only fail-open failure rows
#
# FM_CAPTAIN_ROUTER_TIMEOUT_SECS (default 90) hard-bounds the Cursor spawn
# through bin/fm-timeout-lib.sh (whole process group, exit 124 on the bound,
# dependency-free fallback included), so the bound holds on stock macOS too.
#
# Scope: a genuine firstmate PRIMARY home only (main home or a marked secondmate
# home), exactly like bin/fm-sessionstart-nudge.sh. It is inert (silent exit 0) in
# a child crew/scout worktree and for a no-mistakes gate agent.
#
# FAIL-OPEN: every error path (bad scope, missing dir, empty input, missing
# hashing tool, router spawn/parse failure) exits 0 and never blocks the captain.
# Only invalid CLI usage exits non-zero. The captain is never locked out by a
# broken router.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
ROUTER_DIR="$STATE/captain-router"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
ROUTER_TOGGLE_FILE="$CONFIG_DIR/captain-router"
ANCHORS_FILE="$ROUTER_DIR/anchors.current"
CURRENT_SESSION_FILE="$ROUTER_DIR/current.session"
SESSIONS_DIR="$ROUTER_DIR/sessions"
PENDING_DIR="$ROUTER_DIR/pending"
VERDICTS_LOG="$ROUTER_DIR/verdicts.log"
EXPLANATIONS_LOG="$ROUTER_DIR/explanations.log"
FAILURES_LOG="$ROUTER_DIR/failures.log"

# Cursor encodes the classifier effort in the model id and has no separate
# effort flag. The model remains overridable without adding a fork-specific
# harness configuration schema.
ROUTER_MODEL=${FM_CAPTAIN_ROUTER_MODEL:-cursor-grok-4.6-low}

# The Pi executable a delivered pane runs. Deliberately NOT the warm
# classifier's FM_CAPTAIN_ROUTER_PI: that one hosts a headless RPC child, while
# this is the captain's own visible conversation, so pinning a cheap classifier
# executable must never silently change which Pi the captain ends up talking to.
DELIVERY_PI=${FM_CAPTAIN_ROUTER_DELIVERY_PI:-pi}

# Bounds for the recent-chat excerpt handed to the router model.
HISTORY_CHAR_CAP=${FM_CAPTAIN_ROUTER_HISTORY_CHARS:-6000}
case "$HISTORY_CHAR_CAP" in
'' | *[!0-9]*) HISTORY_CHAR_CAP=6000 ;;
esac
ROUTER_TIMEOUT_SECS=${FM_CAPTAIN_ROUTER_TIMEOUT_SECS:-90}
case "$ROUTER_TIMEOUT_SECS" in
'' | *[!0-9]*) ROUTER_TIMEOUT_SECS=90 ;;
esac
# A zero bound is not a bound (fm-timeout-lib.sh contract): never pass it on.
[ "$ROUTER_TIMEOUT_SECS" -gt 0 ] || ROUTER_TIMEOUT_SECS=90

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-cursor-lib.sh
. "$SCRIPT_DIR/fm-cursor-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# Delivery opens a real visible pane through the home's runtime backend.
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

usage() {
	awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
}

# router_enabled: the captain's kill switch. Read per invocation so toggling
# takes effect on the next message with no restart. Anything unreadable or
# unrecognized means on, because a router that silently disables itself is the
# same outage as a router that silently drops messages.
router_enabled() {
	local stored=${FM_CAPTAIN_ROUTER_ENABLED-}
	if [ -z "$stored" ] && [ -s "$ROUTER_TOGGLE_FILE" ]; then
		IFS= read -r stored <"$ROUTER_TOGGLE_FILE" 2>/dev/null || stored=
	fi
	stored=${stored//[[:space:]]/}
	case "$stored" in
	off | 0 | false | OFF | FALSE) return 1 ;;
	*) return 0 ;;
	esac
}

# brief_is_session: true only for a live-conversation brief written by
# --on-settle, which marks itself `kind=session`. A hand-written project brief
# carries no such marker: it is context for the model and never a route target.
brief_is_session() { # <brief-path>
	[ -f "$1" ] || return 1
	awk -F= '
    /^---$/ { exit }
    $1 == "kind" && $2 == "session" { found = 1; exit }
    END { exit(found ? 0 : 1) }
  ' "$1" 2>/dev/null
}

# extract_anchors: read text on stdin, print one normalized question anchor per
# line. Newlines fold to spaces, the text splits on `?`, and each question keeps
# only the clause after its last sentence terminator, lowercased and reduced to
# space-separated alphanumeric words. Not deduped here (the caller dedupes so it
# can also see the raw pre-dedup count for multi-ask verification).
extract_anchors() {
	tr '\n' ' ' | awk '
    {
      n = split($0, parts, "?")
      for (i = 1; i < n; i++) {
        q = parts[i]
        gsub(/.*[.!]/, "", q)
        q = tolower(q)
        gsub(/[^a-z0-9]+/, " ", q)
        gsub(/^ +| +$/, "", q)
        if (q ~ /[a-z0-9]/) print q
      }
    }
  '
}

digest_message() {
	{ shasum -a 256 2>/dev/null || sha256sum 2>/dev/null; } | awk '{print substr($1,1,12)}'
}

iso_now() {
	date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown\n'
}

record_verdict() { # <verdict> <target> <confidence>; message on stdin
	local verdict=$1 target=$2 conf=$3 ts digest
	ts=$(iso_now)
	digest=$(digest_message)
	[ -n "$digest" ] || digest=nodigest
	printf '%s\t%s\t%s\t%s\t%s\n' "$ts" "$verdict" "$target" "$conf" "$digest" >>"$VERDICTS_LOG"
}

# record_explanation: audit-only rationale row, keyed by the same message digest
# as verdicts.log. This file is never read back into any session prompt.
record_explanation() { # <verdict> <target> <digest> <explanation>
	local verdict=$1 target=$2 digest=$3 text=$4 ts
	[ -n "$text" ] || return 0
	ts=$(iso_now)
	text=$(printf '%s' "$text" | tr '\n\t' '  ')
	printf '%s\t%s\t%s\t%s\t%s\n' "$ts" "$verdict" "$target" "$digest" "$text" \
		>>"$EXPLANATIONS_LOG" 2>/dev/null || true
}

record_failure() { # <note>
	local ts
	ts=$(iso_now)
	printf '%s\t%s\n' "$ts" "$1" >>"$FAILURES_LOG" 2>/dev/null || true
}

# Resolve the session id for this invocation.
resolve_session_id() {
	local sid=${SESSION_ID_ARG-}
	if [ -z "$sid" ]; then
		sid=${FM_CAPTAIN_ROUTER_SESSION_ID-}
	fi
	if [ -z "$sid" ] && [ -s "$CURRENT_SESSION_FILE" ]; then
		IFS= read -r sid <"$CURRENT_SESSION_FILE" || sid=
		sid=${sid//[[:space:]]/}
	fi
	if [ -z "$sid" ]; then
		sid=primary
	fi
	# Keep filenames safe.
	case "$sid" in
	*[!A-Za-z0-9._-]*) sid=primary ;;
	esac
	printf '%s\n' "$sid"
}

topic_head() {
	# Single-line topic from settle text: collapse whitespace, truncate.
	tr '\n' ' ' | awk '{
      gsub(/[ \t]+/, " ")
      gsub(/^ +| +$/, "")
      if (length($0) > 160) $0 = substr($0, 1, 157) "..."
      print
    }'
}

write_session_brief() { # <session-id> <topic> ; anchors on stdin (or empty)
	local sid=$1 topic=$2 brief tmp
	brief="$SESSIONS_DIR/$sid.brief"
	tmp="$brief.tmp.$$"
	mkdir -p "$SESSIONS_DIR" 2>/dev/null || return 0
	{
		printf 'session_id=%s\n' "$sid"
		# The marker that makes this a routable target. Project briefs lack it.
		printf 'kind=session\n'
		printf 'updated=%s\n' "$(iso_now)"
		printf 'topic=%s\n' "$topic"
		printf -- '---\n'
		awk 'NF'
	} >"$tmp" 2>/dev/null || {
		rm -f "$tmp" 2>/dev/null || true
		return 0
	}
	mv -f "$tmp" "$brief" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
}

stage_pending_route() { # <verdict> <target> <confidence> <explanation> ; message on stdin
	local verdict=$1 target=$2 conf=$3 explanation=${4-} ts digest path rel msg tmp unique latest_tmp
	msg=$(cat)
	ts=$(iso_now | tr -d ':-')
	digest=$(printf '%s' "$msg" | digest_message)
	[ -n "$digest" ] || digest=nodigest
	mkdir -p "$PENDING_DIR" 2>/dev/null || return 1
	tmp=$(mktemp "$PENDING_DIR/.route.XXXXXX" 2>/dev/null) || return 1
	{
		printf 'verdict=%s\n' "$verdict"
		printf 'target=%s\n' "$target"
		printf 'confidence=%s\n' "$conf"
		printf 'session_from=%s\n' "$(resolve_session_id)"
		printf 'created=%s\n' "$(iso_now)"
		printf 'message_digest=%s\n' "$digest"
		# Audit-only rationale. Header side of the file, never the message body
		# that a later cross-session delivery would carry into the target session.
		[ -n "$explanation" ] &&
			printf 'explanation=%s\n' "$(printf '%s' "$explanation" | tr '\n' ' ')"
		printf -- '---\n'
		printf '%s\n' "$msg"
	} >"$tmp" 2>/dev/null || {
		rm -f "$tmp" 2>/dev/null || true
		return 1
	}
	unique=${tmp##*/}
	unique=${unique#.route.}
	rel="${ts}-${digest}-${unique}.route"
	path="$PENDING_DIR/$rel"
	ln "$tmp" "$path" 2>/dev/null || {
		rm -f "$tmp" 2>/dev/null || true
		return 1
	}
	rm -f "$tmp" 2>/dev/null || true
	latest_tmp=$(mktemp "$PENDING_DIR/.latest.XXXXXX" 2>/dev/null) || {
		rm -f "$path" 2>/dev/null || true
		return 1
	}
	if ! printf '%s\n' "$rel" >"$latest_tmp" 2>/dev/null ||
		! mv -f "$latest_tmp" "$PENDING_DIR/LATEST" 2>/dev/null; then
		rm -f "$latest_tmp" "$path" 2>/dev/null || true
		return 1
	fi
	return 0
}

# redact_history: read a raw transcript excerpt on stdin, print a bounded,
# privacy-safe version. Drops any line carrying a Firstmate operational
# injection (the FIRSTMATE_OP carrier, the from-firstmate label, or a legacy
# wake/turn-end payload) and masks secret-shaped tokens before the excerpt
# reaches the model.
redact_history() {
	awk '
    index($0, "FIRSTMATE_OP:") { next }
    index($0, "[fm-from-firstmate]") { next }
    index($0, "FIRSTMATE WATCHER WAKE:") { next }
    index($0, "TURN WOULD END BLIND") { next }
    {
      n = split($0, w, / /)
      out = ""
      pending_secret = 0
      for (i = 1; i <= n; i++) {
        t = tolower(w[i])
        if (t ~ /(token|secret|password|passwd|api_?key|access_?key|authorization)[^a-z0-9]*[:=]/) {
          sub(/[:=].*/, "=[redacted]", w[i])
        } else if (t ~ /^(sk|pk|ghp|gho|ghu|ghs|ghr|github_pat|ntn)[-_]/ || t ~ /^xox[abposr]-/) {
          w[i] = "[redacted]"
          pending_secret = 0
        } else if (pending_secret && t !~ /^[:=]+$/) {
          w[i] = "[redacted]"
          pending_secret = 0
        }
        key = t
        gsub(/[^a-z0-9_]/, "", key)
        if (key ~ /^(bearer|token|secret|password|passwd|api_?key|access_?key|authorization)$/) {
          pending_secret = 1
        }
        out = (i == 1 ? w[i] : out " " w[i])
      }
      print out
    }
  ' | tail -c "$HISTORY_CHAR_CAP"
}

build_router_prompt() { # <current-id> <message-file> [history-file]
	local cur=$1 msgfile=$2 histfile=${3-} sid brief history='' found=''
	printf 'You are the Firstmate captain-message continuity router.\n'
	printf 'Firstmate runs several long-lived work sessions for one captain, and each\n'
	printf 'session has a brief describing what it is about. Your job is to decide where\n'
	printf 'THIS captain message belongs, using the live conversation and every brief.\n\n'
	printf 'Verdicts:\n'
	printf '  same    - the message continues the current session conversation\n'
	printf '  reroute - the message belongs to a different LIVE SESSION listed below\n'
	printf '  new     - the message starts work that fits no existing session\n\n'
	printf 'Prefer "same" for ordinary in-conversation replies, follow-ups, corrections,\n'
	printf 'objections, and acknowledgements, even when they share no literal words with\n'
	printf 'the last assistant turn. Choose "reroute" ONLY when the message clearly\n'
	printf 'belongs to another live session listed under OTHER LIVE SESSIONS. Choose\n'
	printf '"new" only when it starts work that fits no live session.\n\n'
	printf 'A message about a project is NOT by itself a reason to reroute. Project\n'
	printf 'context is background for understanding the message, never a destination.\n'
	printf 'If no other live session is listed, reroute is impossible: answer "same" or\n'
	printf '"new". An empty recent chat history means this session is only starting, so\n'
	printf 'it is still a valid "same" target and not a reason to route the message away.\n\n'
	printf 'Reply with EXACTLY these three lines and nothing else:\n'
	printf 'verdict=<same|reroute|new>\n'
	printf 'target=<session-id|->\n'
	printf 'explanation=<up to 3 sentences on one line: why this verdict, what context this belongs to>\n\n'
	printf 'Use target=- for verdict=new. For verdict=same use the current session id.\n'
	printf 'For verdict=reroute, target must be a session id listed under OTHER LIVE\n'
	printf 'SESSIONS. A project name from PROJECT CONTEXT is never a valid target.\n'
	printf 'Current session id: %s\n' "$cur"
	if [ -n "$histfile" ] && [ -s "$histfile" ]; then
		history=$(redact_history <"$histfile" 2>/dev/null || true)
	fi
	printf '\n=== RECENT CHAT HISTORY (current session, bounded and redacted) ===\n'
	if [ -n "$history" ]; then
		printf '%s\n' "$history"
	else
		printf '(none available)\n'
	fi
	# Two separate sections, because they answer different questions. Live
	# sessions are the only places a message can actually be delivered; project
	# briefs only help the model understand what the captain is talking about.
	printf '\n=== OTHER LIVE SESSIONS (the ONLY valid reroute targets) ===\n'
	found=
	if [ -d "$SESSIONS_DIR" ]; then
		for brief in "$SESSIONS_DIR"/*.brief; do
			[ -f "$brief" ] || continue
			brief_is_session "$brief" || continue
			sid=$(basename "$brief" .brief)
			[ "$sid" != "$cur" ] || continue
			found=1
			printf -- '--- session %s ---\n' "$sid"
			cat "$brief"
			printf '\n'
		done
	fi
	[ -n "$found" ] ||
		printf '(none - no other live session exists, so reroute is not available)\n'
	printf '\n=== PROJECT CONTEXT (background only - NEVER a reroute target) ===\n'
	found=
	if [ -d "$SESSIONS_DIR" ]; then
		for brief in "$SESSIONS_DIR"/*.brief; do
			[ -f "$brief" ] || continue
			brief_is_session "$brief" && continue
			sid=$(basename "$brief" .brief)
			found=1
			printf -- '--- project %s ---\n' "$sid"
			cat "$brief"
			printf '\n'
		done
	fi
	[ -n "$found" ] || printf '(none)\n'
	printf '\n=== CAPTAIN MESSAGE (classify this) ===\n'
	cat "$msgfile"
	printf '\n'
}

# Run one classification. The assembled prompt enters this function on stdin
# and is handed to the model only through the private prompt file: first to the
# warm classifier (bin/fm-captain-router-runner.mjs) when one is listening, and
# otherwise to an ephemeral Cursor spawn.
# Prints agent stdout. Returns 0 on spawn success (even if verdict is bad).
# The Cursor spawn is hard-bounded by FM_CAPTAIN_ROUTER_TIMEOUT_SECS through
# fm_run_timed (whole process group, exit 124 on the bound), so a hung model
# cannot stall the captain's turn; a timeout is a fail-open failure. The full
# prompt stays in the mode-0600 temp file: argv carries only a short instruction
# naming that file, so no history, brief, or message text ever rides the process
# list and no kernel argument-size limit applies.
spawn_router_agent() { # prompt on stdin
	local prompt_file out status=0 cmd
	prompt_file=$(mktemp "$ROUTER_DIR/prompt.XXXXXX" 2>/dev/null) || {
		record_failure "could not create private router prompt file"
		return 1
	}
	chmod 600 "$prompt_file" 2>/dev/null || {
		rm -f "$prompt_file"
		record_failure "could not set private router prompt file mode"
		return 1
	}
	cat >"$prompt_file" || {
		rm -f "$prompt_file"
		record_failure "could not write private router prompt file"
		return 1
	}
	# Prefer the warm classifier when the lock-holding primary has one running:
	# it skips the vendor CLI cold start entirely. A runner that is absent,
	# busy, wedged, or wrong loses the request and the ephemeral spawn below
	# still answers, so the warm path can never cost the captain a verdict.
	if out=$(fm_run_timed "$ROUTER_TIMEOUT_SECS" node "$SCRIPT_DIR/fm-captain-router-runner.mjs" \
		classify --state "$STATE" --prompt-file "$prompt_file" 2>/dev/null); then
		rm -f "$prompt_file"
		printf '%s\n' "$out"
		return 0
	fi
	# Reuse upstream's verified resolver instead of carrying another Cursor
	# executable rule in the fork. Ask mode is read-only; --trust only skips
	# the headless workspace prompt and grants no write-capable mode.
	cmd=$(fm_cursor_resolve_binary 2>/dev/null || true)
	if [ -z "$cmd" ]; then
		rm -f "$prompt_file"
		record_failure "Cursor Agent CLI not found"
		return 1
	fi
	out=$(fm_run_timed "$ROUTER_TIMEOUT_SECS" env \
		-u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u CURSOR_INVOKED_AS \
		"$cmd" --print --output-format text --mode ask --trust \
		--workspace "$FM_HOME" --model "$ROUTER_MODEL" \
		"Read the prompt file at $prompt_file and follow its instructions exactly. It carries your role, the conversation context, and the captain message to classify. Reply with ONLY the three-line verdict block it specifies (verdict=/target=/explanation=) and nothing else." 2>/dev/null) || status=$?
	rm -f "$prompt_file"
	if [ "$status" -ne 0 ]; then
		if [ "$status" -eq 124 ]; then
			record_failure "router agent timed out after ${ROUTER_TIMEOUT_SECS}s"
		else
			record_failure "router agent exited $status"
		fi
		return 1
	fi
	printf '%s\n' "$out"
	return 0
}

# parse_verdict_block: read the model's reply and set PARSE_VERDICT,
# PARSE_TARGET, PARSE_EXPLANATION, PARSE_CONFIDENCE. Accepts the three-line block
# and, for resilience, a single `verdict=... target=...` line. Returns 0 when a
# valid, validated verdict was recovered; every other case is a fail-open failure.
parse_verdict_block() { # <blob>
	local blob=$1
	PARSE_VERDICT=
	PARSE_TARGET=
	PARSE_EXPLANATION=
	PARSE_CONFIDENCE=model
	PARSE_VERDICT=$(printf '%s\n' "$blob" |
		sed -n 's/^[[:space:]]*verdict=\([A-Za-z]*\).*/\1/p' | head -n 1)
	PARSE_TARGET=$(printf '%s\n' "$blob" |
		sed -n 's/^[[:space:]]*verdict=[A-Za-z]*[[:space:]][[:space:]]*target=\([^[:space:]]*\).*/\1/p' | head -n 1)
	if [ -z "$PARSE_TARGET" ]; then
		PARSE_TARGET=$(printf '%s\n' "$blob" |
			sed -n 's/^[[:space:]]*target=\([^[:space:]]*\).*/\1/p' | head -n 1)
	fi
	PARSE_EXPLANATION=$(printf '%s\n' "$blob" |
		sed -n 's/^[[:space:]]*explanation=//p' | head -n 3 | tr '\n' ' ')
	PARSE_EXPLANATION=${PARSE_EXPLANATION%"${PARSE_EXPLANATION##*[![:space:]]}"}
	case "$PARSE_VERDICT" in
	same | reroute | new) ;;
	*) return 1 ;;
	esac
	[ -n "$PARSE_TARGET" ] || return 1
	case "$PARSE_TARGET" in
	*[!A-Za-z0-9._-]*) [ "$PARSE_TARGET" = - ] || return 1 ;;
	esac
	if [ "$PARSE_VERDICT" = new ]; then
		PARSE_TARGET=-
	fi
	if [ "$PARSE_VERDICT" = same ]; then
		PARSE_TARGET=$(resolve_session_id)
	fi
	if [ "$PARSE_VERDICT" = reroute ]; then
		[ "$PARSE_TARGET" != - ] || return 1
		if [ "$PARSE_TARGET" = "$(resolve_session_id)" ]; then
			record_failure "router returned the current session as a reroute target; continuing in the current session"
			PARSE_VERDICT=same
			PARSE_TARGET=$(resolve_session_id)
			PARSE_EXPLANATION="router returned the current session as a reroute target; continuing in the current session"
			PARSE_CONFIDENCE=det
		else
			# A project brief is context, not a destination: routing there would
			# hand the message to something that can never receive it.
			if ! brief_is_session "$SESSIONS_DIR/$PARSE_TARGET.brief"; then
				if [ -f "$SESSIONS_DIR/$PARSE_TARGET.brief" ]; then
					record_failure "router targeted project brief $PARSE_TARGET, which is context and not a live session"
				fi
				return 1
			fi
		fi
	fi
	return 0
}

# emit_verdict: record, stage, and print one verdict. The optional explanation is
# audit-only: it lands in explanations.log and the pending route header, and is
# never printed on the wire line or forwarded into any routed session context.
emit_verdict() { # <verdict> <target> <confidence> [explanation] ; message on stdin
	local verdict=$1 target=$2 conf=$3 explanation=${4-} msg digest
	msg=$(cat)
	case "$verdict" in
	reroute | new)
		if ! printf '%s' "$msg" |
			stage_pending_route "$verdict" "$target" "$conf" "$explanation"; then
			record_failure "pending route publication failed for verdict=$verdict target=$target"
			verdict=same
			target=$(resolve_session_id)
			conf=det
			explanation=
		fi
		;;
	esac
	printf '%s' "$msg" | record_verdict "$verdict" "$target" "$conf"
	if [ -n "$explanation" ]; then
		digest=$(printf '%s' "$msg" | digest_message)
		[ -n "$digest" ] || digest=nodigest
		record_explanation "$verdict" "$target" "$digest" "$explanation"
	fi
	printf 'verdict=%s target=%s confidence=%s\n' "$verdict" "$target" "$conf"
}

# --- cross-session delivery ------------------------------------------------
#
# Pi compaction and message injection are session-LOCAL: ctx.compact() and
# pi.sendUserMessage() act on the session their own extension is loaded into,
# and no API reaches a different live Pi process. So a router running in the
# primary cannot compact-then-inject a target session from outside it.
# What it CAN do is start the target session again in a visible pane
# (`pi --session <id>` resumes that session's real prior context, verified) and
# hand it the captain message plus an instruction to compact itself first. The
# compaction stays where it has to be - inside the target - and the captain
# gets a tab they can see and type in. docs/captain-message-router.md owns the
# decision and its reasoning.

# route_field: read one header field from a staged pending route. Header only:
# the scan stops at the `---` separator so a message body line that happens to
# look like `target=x` can never be read as routing metadata.
route_field() { # <route-file> <key>
	awk -F= -v key="$2" '
    /^---$/ { exit }
    $1 == key { sub(/^[^=]*=/, ""); print; exit }
  ' "$1" 2>/dev/null
}

route_body() { # <route-file>
	awk '/^---$/ { body = 1; next } body' "$1" 2>/dev/null
}

# delivery_result: the one machine-readable delivery line, so every caller reads
# the same contract instead of interpreting exit codes plus prose.
delivery_result() { # <delivered|undelivered> <kind> <target> <reason>
	printf 'delivery=%s kind=%s target=%s reason=%s\n' "$1" "$2" "${3:--}" "$4"
}

# deliver_seed_text: what the freshly opened session is handed. It carries the
# captain message verbatim, framed so the target knows the message arrived by
# routing rather than by the captain typing into that window. The audit-only
# explanation is deliberately NOT included: it is the router's reasoning about
# the captain, and forwarding it would put a model's guess into the captain's
# own conversation.
deliver_seed_text() { # <kind> <route-file>
	local kind=$1 route=$2
	if [ "$kind" = reroute ]; then
		printf 'You are resuming this session because the captain sent a message that belongs here rather than in the session they typed it into.\n\n'
		printf 'Before answering, compact this conversation with /compact so the resumed context is small and current.\n'
		printf 'Then answer the captain message below as the next turn of THIS conversation.\n\n'
	else
		printf 'This is a fresh session opened for a captain message that fit no existing conversation.\n\n'
		printf 'Answer the captain message below as the first turn of this new conversation.\n\n'
	fi
	printf -- '--- CAPTAIN MESSAGE ---\n'
	route_body "$route"
}

# deliver_route: open ONE visible herdr pane for a staged route and seed it.
# Refuses (leaving the route staged) unless the whole visible path is available,
# because an invisible background agent is not the product: the captain must be
# able to see the tab appear, switch to it, and type in it.
deliver_route() { # <route-file>
	local route=$1 kind target origin session workspace label cwd seed tab_out tab_id pane_id cmd
	kind=$(route_field "$route" verdict)
	target=$(route_field "$route" target)
	case "$kind" in
	reroute | new) ;;
	*)
		delivery_result undelivered "${kind:--}" - unknown-kind
		return 1
		;;
	esac
	if [ -z "$(route_body "$route")" ]; then
		delivery_result undelivered "$kind" - empty-message
		return 1
	fi
	# A reroute names a session; it must still be a routable live-conversation
	# brief at delivery time, not just at classification time.
	if [ "$kind" = reroute ]; then
		case "$target" in
		'' | - | *[!A-Za-z0-9._-]*)
			delivery_result undelivered "$kind" - bad-target
			return 1
			;;
		esac
		if ! brief_is_session "$SESSIONS_DIR/$target.brief"; then
			delivery_result undelivered "$kind" "$target" no-session-brief
			return 1
		fi
		# Self-target is judged against the session the message was SENT FROM, not
		# against whichever session settled most recently: a delivery can run well
		# after its route was staged, and the pointer moves in between.
		origin=$(route_field "$route" session_from)
		[ -n "$origin" ] || origin=$(resolve_session_id)
		if [ "$target" = "$origin" ]; then
			delivery_result undelivered "$kind" "$target" self-target
			return 1
		fi
	fi
	# Visible-pane preconditions. Each refusal is a distinct reason token so a
	# failure says which half of the path was missing.
	if [ "$(fm_backend_name)" != herdr ]; then
		delivery_result undelivered "$kind" "$target" backend-not-herdr
		return 1
	fi
	fm_backend_source herdr 2>/dev/null || {
		delivery_result undelivered "$kind" "$target" herdr-unavailable
		return 1
	}
	fm_backend_herdr_version_check 2>/dev/null || {
		delivery_result undelivered "$kind" "$target" herdr-unavailable
		return 1
	}
	session=$(fm_backend_herdr_session)
	# Placement: inherit the launching process's OWN workspace, exactly like a
	# herdr crewmate or scout (bin/fm-spawn.sh). A label cannot tell two
	# workspaces apart, so an unverifiable parent identity refuses rather than
	# guessing a destination workspace.
	fm_backend_herdr_launcher_identity "$session" >/dev/null 2>&1 || {
		delivery_result undelivered "$kind" "$target" no-visible-workspace
		return 1
	}
	workspace=$FM_BACKEND_HERDR_LAUNCHER_WORKSPACE_ID
	[ -n "$workspace" ] || {
		delivery_result undelivered "$kind" "$target" no-visible-workspace
		return 1
	}
	# The seed rides a private file, never argv: a captain paste can be large and
	# must not appear in the process list. The pane reads it asynchronously, so a
	# delivered seed cannot be removed inline; sweep stale ones instead, because
	# each one holds captain message text and would otherwise accumulate forever.
	find "$ROUTER_DIR" -maxdepth 1 -name 'seed.*' -type f -mtime +1 -delete 2>/dev/null || true
	seed=$(mktemp "$ROUTER_DIR/seed.XXXXXX" 2>/dev/null) || {
		delivery_result undelivered "$kind" "$target" seed-write-failed
		return 1
	}
	chmod 600 "$seed" 2>/dev/null || true
	deliver_seed_text "$kind" "$route" >"$seed" 2>/dev/null || {
		rm -f "$seed"
		delivery_result undelivered "$kind" "$target" seed-write-failed
		return 1
	}
	if [ "$kind" = reroute ]; then
		label="captain-reroute-${target}"
	else
		label="captain-new-$(route_field "$route" message_digest)"
	fi
	cwd=$FM_HOME
	tab_out=$(fm_backend_herdr_cli "$session" tab create --workspace "$workspace" \
		--cwd "$cwd" --label "$label" --no-focus 2>/dev/null) || {
		rm -f "$seed"
		delivery_result undelivered "$kind" "$target" tab-create-failed
		return 1
	}
	tab_id=$(printf '%s' "$tab_out" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
	pane_id=$(printf '%s' "$tab_out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
	if [ -z "$tab_id" ] || [ -z "$pane_id" ]; then
		rm -f "$seed"
		delivery_result undelivered "$kind" "$target" tab-create-failed
		return 1
	fi
	# The delivered pane is a plain visible conversation, NOT a second Firstmate:
	# it must never take this home's fleet lock, arm a watcher, or run the
	# session-start digest. FM_CAPTAIN_ROUTER_DELIVERED marks it as one, and the
	# router extension stays inert in it because it never owns the session lock.
	cmd=$(printf 'FM_CAPTAIN_ROUTER_DELIVERED=1 %s' "$DELIVERY_PI")
	if [ "$kind" = reroute ]; then
		cmd=$(printf '%s --session %s' "$cmd" "$target")
	fi
	cmd=$(printf '%s @%s' "$cmd" "$seed")
	if ! fm_backend_herdr_send_text_line "$session:$pane_id" "$cmd"; then
		# The pane exists but the launch never went in: close it rather than
		# leaving the captain a dead tab, and keep the route staged.
		fm_backend_herdr_cli "$session" pane close "$pane_id" >/dev/null 2>&1 || true
		rm -f "$seed"
		delivery_result undelivered "$kind" "$target" launch-failed
		return 1
	fi
	delivery_result delivered "$kind" "$session:$pane_id" ok
	return 0
}

# --- CLI -------------------------------------------------------------------

SESSION_ID_ARG=
CHAT_HISTORY_FILE=
DELIVER_ROUTE_FILE=
mode=
while [ "$#" -gt 0 ]; do
	case "$1" in
	--help | -h)
		usage
		exit 0
		;;
	--on-settle | --on-submit)
		mode=$1
		shift
		;;
	--deliver)
		mode=$1
		shift
		DELIVER_ROUTE_FILE=${1-}
		[ -n "$DELIVER_ROUTE_FILE" ] || {
			usage >&2
			exit 2
		}
		shift
		;;
	--deliver=*)
		mode=--deliver
		DELIVER_ROUTE_FILE=${1#--deliver=}
		[ -n "$DELIVER_ROUTE_FILE" ] || {
			usage >&2
			exit 2
		}
		shift
		;;
	--session-id)
		shift
		SESSION_ID_ARG=${1-}
		[ -n "$SESSION_ID_ARG" ] || {
			usage >&2
			exit 2
		}
		shift
		;;
	--session-id=*)
		SESSION_ID_ARG=${1#--session-id=}
		[ -n "$SESSION_ID_ARG" ] || {
			usage >&2
			exit 2
		}
		shift
		;;
	--chat-history-file)
		shift
		CHAT_HISTORY_FILE=${1-}
		[ -n "$CHAT_HISTORY_FILE" ] || {
			usage >&2
			exit 2
		}
		shift
		;;
	--chat-history-file=*)
		CHAT_HISTORY_FILE=${1#--chat-history-file=}
		[ -n "$CHAT_HISTORY_FILE" ] || {
			usage >&2
			exit 2
		}
		shift
		;;
	*)
		usage >&2
		exit 2
		;;
	esac
done

[ -n "$mode" ] || {
	usage >&2
	exit 2
}

# Inert for a gate agent or outside a genuine primary. Fail-open: silent exit 0.
fm_is_gate_agent "$FM_ROOT" && exit 0
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
mkdir -p "$ROUTER_DIR" 2>/dev/null || exit 0

session_id=$(resolve_session_id)

# --deliver: transfer one staged route to a real visible destination. Unlike the
# classify modes this one reports failure honestly (non-zero) instead of failing
# open, because its caller's fallback is to deliver the message into the current
# session - which only works if it is told the transfer did not happen.
if [ "$mode" = --deliver ]; then
	if [ ! -f "$DELIVER_ROUTE_FILE" ]; then
		delivery_result undelivered - - no-route-file
		exit 1
	fi
	if deliver_route "$DELIVER_ROUTE_FILE"; then
		# Consume the route only now: a staged route is the message's only other
		# copy, so it is removed strictly after a delivery is confirmed.
		rm -f "$DELIVER_ROUTE_FILE" 2>/dev/null || true
		if [ "$(cat "$PENDING_DIR/LATEST" 2>/dev/null)" = "${DELIVER_ROUTE_FILE##*/}" ]; then
			rm -f "$PENDING_DIR/LATEST" 2>/dev/null || true
		fi
		exit 0
	fi
	record_failure "delivery refused for ${DELIVER_ROUTE_FILE##*/}"
	exit 1
fi

if [ "$mode" = --on-settle ]; then
	msg=$(cat)
	raw_anchors=$(printf '%s' "$msg" | extract_anchors)
	uniq_anchors=$(printf '%s\n' "$raw_anchors" | awk 'NF && !seen[$0]++')
	raw_count=$(printf '%s\n' "$raw_anchors" | awk 'NF{c++} END{print c+0}')
	uniq_count=$(printf '%s\n' "$uniq_anchors" | awk 'NF{c++} END{print c+0}')
	printf '%s\n' "$uniq_anchors" | awk 'NF' >"$ANCHORS_FILE" 2>/dev/null || exit 0
	printf '%s\n' "$session_id" >"$CURRENT_SESSION_FILE" 2>/dev/null || true
	topic=$(printf '%s' "$msg" | topic_head)
	printf '%s\n' "$uniq_anchors" | write_session_brief "$session_id" "$topic"
	if [ "$raw_count" -ge 2 ] && [ "$uniq_count" -lt 2 ]; then
		printf 'captain-router: multi-ask verification - %s question(s) asked but %s distinct anchor(s) recorded\n' \
			"$raw_count" "$uniq_count" >&2
	fi
	exit 0
fi

# --on-submit: the model always decides. The deterministic layer below survives
# only as the fail-open fallback when the spawn errors, times out, or returns
# something unparseable, so a broken router never locks the captain out.
msg=$(cat)

# The captain's kill switch. Off means every message goes straight through, so a
# router bug can never cost a message while it is being fixed.
if ! router_enabled; then
	printf '%s' "$msg" | emit_verdict same "$session_id" det
	exit 0
fi

# First message of this session: no brief means no conversation has settled here
# yet, so there is nothing to continue and nothing to route away from. Spawning
# the model here is what starved this session in the first place - it read the
# empty history as "wrong session" and rerouted, which stopped the turn, which
# stopped the brief from ever being written.
if ! brief_is_session "$SESSIONS_DIR/$session_id.brief"; then
	printf '%s' "$msg" | emit_verdict same "$session_id" det
	exit 0
fi

tmpmsg=$(mktemp "$ROUTER_DIR/msg.XXXXXX" 2>/dev/null) || {
	record_failure "could not create temp message file"
	printf '%s' "$msg" | emit_verdict same "$session_id" det
	exit 0
}
printf '%s' "$msg" >"$tmpmsg" 2>/dev/null || {
	rm -f "$tmpmsg"
	record_failure "could not write temp message file"
	printf '%s' "$msg" | emit_verdict same "$session_id" det
	exit 0
}

agent_out=
if agent_out=$(build_router_prompt "$session_id" "$tmpmsg" "$CHAT_HISTORY_FILE" | spawn_router_agent); then
	rm -f "$tmpmsg"
	if parse_verdict_block "$agent_out"; then
		printf '%s' "$msg" |
			emit_verdict "$PARSE_VERDICT" "$PARSE_TARGET" "$PARSE_CONFIDENCE" "$PARSE_EXPLANATION"
		exit 0
	fi
	record_failure "router agent returned unparseable verdict"
else
	rm -f "$tmpmsg"
	# spawn_router_agent already recorded the failure when it could.
fi

# Fail-open: allow into the current primary.
printf '%s' "$msg" | emit_verdict same "$session_id" det
exit 0
