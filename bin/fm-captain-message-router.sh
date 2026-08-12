#!/usr/bin/env bash
# fm-captain-message-router.sh - Captain-message continuity router (bash owner).
#
# NOT watcher continuity. This has nothing to do with docs/watcher-continuity.md,
# the supervision/watcher cycle, or bin/fm-continuity-*. This owner routes an
# incoming CAPTAIN CHAT MESSAGE relative to primary-session open asks and
# per-session briefs so a late or unrelated reply does not silently steer the
# wrong turn. See docs/captain-message-router.md for current P0+P1 behavior.
#
# The Firstmate PRIMARY agent never runs this. A verified harness hook (Pi first)
# calls it; bash owns the truth; the agent owns nothing. P0 was deterministic and
# model-free (same vs unknown). P1 adds per-session briefs, deterministic
# same/reroute/new, and an ephemeral Pi router agent for ambiguous cases.
#
# Modes (assistant message or captain message on stdin):
#   fm-captain-message-router.sh --on-settle [--session-id <id>]
#   fm-captain-message-router.sh --on-submit [--session-id <id>]
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
#   Deterministic layer:
#     - `same` when the message matches the current session's open anchors
#     - `reroute` when it uniquely matches exactly one other session brief
#     - `new` when no session briefs match and anchors are empty or unrelated
#   Ambiguous cases spawn an ephemeral Pi router (config roles.continuity /
#   roles.router, else built-in defaults). Spawn/parse failures fail open as
#   `same` against the current session and append failures.log. Every verdict
#   is appended to verdicts.log. Reroute/new also stage a durable pending route
#   under state/captain-router/pending/ for P2 drop-in (P1 does not compact or
#   inject across sessions).
#
# Session id (assumption, labeled): prefer --session-id, else
#   FM_CAPTAIN_ROUTER_SESSION_ID, else the prior current.session pointer, else
#   the stable home-scoped fallback `primary`. Hooks should pass the harness
#   session id when available.
#
# State (all local-only, never committed), under $STATE/captain-router/:
#   anchors.current       - one normalized open-ask anchor per line (settle)
#   current.session       - session id for the live primary this home last settled
#   sessions/<id>.brief   - per-session topic head + anchors
#   pending/<ts>-<digest>.route - staged reroute/new handoff for P2
#   pending/LATEST        - basename of the most recent pending route file
#   verdicts.log          - append-only verdict rows
#   failures.log          - append-only fail-open failure rows
#
# Router agent override (tests): FM_CAPTAIN_ROUTER_AGENT_CMD, when set, is
# executed instead of Pi. The command receives the prompt on stdin and must
# print a parseable verdict line on stdout. No real model calls in unit tests.
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
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
ROUTER_DIR="$STATE/captain-router"
ANCHORS_FILE="$ROUTER_DIR/anchors.current"
CURRENT_SESSION_FILE="$ROUTER_DIR/current.session"
SESSIONS_DIR="$ROUTER_DIR/sessions"
PENDING_DIR="$ROUTER_DIR/pending"
VERDICTS_LOG="$ROUTER_DIR/verdicts.log"
FAILURES_LOG="$ROUTER_DIR/failures.log"

# Built-in continuity role when config/crew-dispatch.json has no roles.continuity
# / roles.router. Pi accepts --thinking low|medium|high|xhigh|max (not `slow`);
# P1 uses low as the closest cheap classifier effort.
DEFAULT_ROUTER_HARNESS=pi
DEFAULT_ROUTER_MODEL=cursor/grok-4.5
DEFAULT_ROUTER_EFFORT=low

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"

usage() {
	awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
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

# message_matches_anchor: return 0 when the message on stdin shares salient tokens
# with any single open anchor in the anchors file. Salient = alphanumeric, length
# >= 3, not a common stopword. A match needs two shared salient tokens, or at
# least half of a short anchor's salient tokens.
message_matches_anchor() {
	local file=$1
	awk -v anchorfile="$file" '
    function norm(s) { s = tolower(s); gsub(/[^a-z0-9]+/, " ", s); return s }
    BEGIN {
      split("the a an and or is are was were be been being do does did done have has had you your yours i me my we us our it its to of in on at for with from by as this that these those be will would should could can may might must not no yes please let lets go get got so if then than too very just about into out up down over under how what when where why which who whom whose", swords, " ")
      for (k in swords) stop[swords[k]] = 1
      na = 0
      while ((getline line < anchorfile) > 0) {
        line = norm(line)
        m = split(line, t, " ")
        s = ""
        for (j = 1; j <= m; j++) {
          if (length(t[j]) >= 3 && !stop[t[j]]) s = s " " t[j]
        }
        if (s != "") { na++; atokens[na] = s }
      }
    }
    { body = body " " $0 }
    END {
      body = norm(body)
      m = split(body, bt, " ")
      for (j = 1; j <= m; j++) {
        if (length(bt[j]) >= 3 && !stop[bt[j]]) msg_has[bt[j]] = 1
      }
      found = 0
      for (a = 1; a <= na; a++) {
        c = split(atokens[a], t, " ")
        total = 0; overlap = 0
        for (j = 1; j <= c; j++) {
          if (t[j] == "") continue
          total++
          if (msg_has[t[j]]) overlap++
        }
        if (total > 0 && (overlap >= 2 || overlap * 2 >= total)) found = 1
      }
      exit found ? 0 : 1
    }
  '
}

# Return 0 when the message looks like a short acknowledgement that should not
# deterministically become `new` while the current session still has open asks.
message_looks_short_reply() {
	awk '
    function norm(s) { s = tolower(s); gsub(/[^a-z0-9]+/, " ", s); return s }
    BEGIN {
      split("the a an and or is are was were be been being do does did done have has had you your yours i me my we us our it its to of in on at for with from by as this that these those will would should could can may might must not no yes please let lets go get got so if then than too very just about into out up down over under ok okay sure yeah yep yup thanks thank right correct proceed continue", swords, " ")
      for (k in swords) stop[swords[k]] = 1
      split("yes ok okay sure yeah yep yup thanks thank right correct proceed continue please", acks, " ")
      for (k in acks) ack[acks[k]] = 1
    }
    { body = body " " $0 }
    END {
      body = norm(body)
      m = split(body, bt, " ")
      words = 0
      salient = 0
      has_ack = 0
      for (j = 1; j <= m; j++) {
        if (bt[j] == "") continue
        words++
        if (ack[bt[j]]) has_ack = 1
        if (length(bt[j]) >= 3 && !stop[bt[j]]) salient++
      }
      # Acknowledgements and tiny replies stay ambiguous for the model.
      # Short but contentful topic phrases (e.g. "blender export broken") are not.
      if (has_ack && salient < 4) exit 0
      if (words <= 3 && salient <= 1) exit 0
      exit 1
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

brief_anchors_file() { # <brief-path> -> writes temp anchors path on stdout
	local brief=$1 tmp
	tmp=$(mktemp "$ROUTER_DIR/anchors.XXXXXX" 2>/dev/null) || return 1
	awk 'BEGIN{p=0} /^---$/{p=1; next} p && NF{print}' "$brief" >"$tmp" 2>/dev/null || {
		rm -f "$tmp" 2>/dev/null || true
		return 1
	}
	printf '%s\n' "$tmp"
}

list_other_session_ids() { # <current-id>
	local cur=$1 f base
	[ -d "$SESSIONS_DIR" ] || return 0
	for f in "$SESSIONS_DIR"/*.brief; do
		[ -f "$f" ] || continue
		base=$(basename "$f" .brief)
		[ "$base" = "$cur" ] && continue
		printf '%s\n' "$base"
	done
}

stage_pending_route() { # <verdict> <target> <confidence> ; message on stdin
	local verdict=$1 target=$2 conf=$3 ts digest path rel msg
	msg=$(cat)
	ts=$(iso_now | tr -d ':-')
	digest=$(printf '%s' "$msg" | digest_message)
	[ -n "$digest" ] || digest=nodigest
	mkdir -p "$PENDING_DIR" 2>/dev/null || return 0
	rel="${ts}-${digest}.route"
	path="$PENDING_DIR/$rel"
	{
		printf 'verdict=%s\n' "$verdict"
		printf 'target=%s\n' "$target"
		printf 'confidence=%s\n' "$conf"
		printf 'session_from=%s\n' "$(resolve_session_id)"
		printf 'created=%s\n' "$(iso_now)"
		printf 'message_digest=%s\n' "$digest"
		printf -- '---\n'
		printf '%s\n' "$msg"
	} >"$path" 2>/dev/null || return 0
	printf '%s\n' "$rel" >"$PENDING_DIR/LATEST" 2>/dev/null || true
}

# Resolve continuity/router role from config/crew-dispatch.json.
# Prints: harness<TAB>model<TAB>effort
resolve_continuity_profile() {
	local file="$CONFIG/crew-dispatch.json" harness model effort
	harness=$DEFAULT_ROUTER_HARNESS
	model=$DEFAULT_ROUTER_MODEL
	effort=$DEFAULT_ROUTER_EFFORT
	if [ -f "$file" ] && command -v jq >/dev/null 2>&1; then
		# Prefer roles.continuity, then roles.router. First profile object wins
		# when an array is configured.
		local parsed
		parsed=$(jq -r '
      def first_profile($v):
        if ($v | type) == "array" then $v[0]
        elif ($v | type) == "object" then $v
        else null end;
      (.roles.continuity // .roles.router // null) as $role
      | first_profile($role) as $p
      | if $p == null then empty
        else
          (($p.harness // "pi") | tostring) + "\t" +
          (($p.model // "cursor/grok-4.5") | tostring) + "\t" +
          (($p.effort // "low") | tostring)
        end
    ' "$file" 2>/dev/null || true)
		if [ -n "$parsed" ]; then
			IFS=$'\t' read -r harness model effort <<<"$parsed" || true
		fi
	fi
	# Pi has no `slow` thinking level; map it to low.
	case "$effort" in
	slow) effort=low ;;
	esac
	printf '%s\t%s\t%s\n' "$harness" "$model" "$effort"
}

build_router_prompt() { # <current-id> <message-file>
	local cur=$1 msgfile=$2 sid brief
	printf 'You are the Firstmate captain-message continuity router.\n'
	printf 'Classify the captain message relative to the session briefs.\n'
	printf 'Reply with EXACTLY one line and nothing else:\n'
	printf 'verdict=<same|reroute|new> target=<session-id|-> confidence=model\n'
	printf 'Use target=- for verdict=new. For reroute, target must be an existing session id.\n'
	printf 'Current session id: %s\n\n' "$cur"
	printf '=== CAPTAIN MESSAGE ===\n'
	cat "$msgfile"
	printf '\n=== SESSION BRIEFS ===\n'
	if [ -d "$SESSIONS_DIR" ]; then
		for brief in "$SESSIONS_DIR"/*.brief; do
			[ -f "$brief" ] || continue
			sid=$(basename "$brief" .brief)
			printf -- '--- session %s ---\n' "$sid"
			cat "$brief"
			printf '\n'
		done
	else
		printf '(none)\n'
	fi
}

# Spawn the ephemeral router agent. Prompt on stdin of the agent command.
# Prints agent stdout. Returns 0 on spawn success (even if verdict is bad).
spawn_router_agent() { # prompt on stdin
	local harness model effort prompt_file out status=0 cmd
	prompt_file=$(mktemp "$ROUTER_DIR/prompt.XXXXXX" 2>/dev/null) || return 1
	cat >"$prompt_file" || {
		rm -f "$prompt_file"
		return 1
	}
	IFS=$'\t' read -r harness model effort < <(resolve_continuity_profile) || true
	if [ -n "${FM_CAPTAIN_ROUTER_AGENT_CMD-}" ]; then
		# shellcheck disable=SC2086 # intentional word-split of override command
		out=$(cat "$prompt_file" | eval "$FM_CAPTAIN_ROUTER_AGENT_CMD" 2>/dev/null) || status=$?
	else
		cmd=$(command -v "$harness" 2>/dev/null || true)
		if [ -z "$cmd" ]; then
			rm -f "$prompt_file"
			record_failure "router harness not found: $harness"
			return 1
		fi
		# Ephemeral print-mode Pi: no session, no extensions, no tools, no context files.
		out=$("$cmd" -p --no-session --no-extensions --no-context-files --no-tools \
			--model "$model" --thinking "$effort" \
			"$(cat "$prompt_file")" 2>/dev/null) || status=$?
	fi
	rm -f "$prompt_file"
	if [ "$status" -ne 0 ]; then
		record_failure "router agent exited $status"
		return 1
	fi
	printf '%s\n' "$out"
	return 0
}

parse_verdict_line() { # <blob> -> sets PARSE_VERDICT PARSE_TARGET PARSE_CONF; return 0 if ok
	local blob=$1 line
	PARSE_VERDICT=
	PARSE_TARGET=
	PARSE_CONF=
	line=$(printf '%s\n' "$blob" | awk '
    /^verdict=(same|reroute|new)[ \t]+target=[^ \t]+[ \t]+confidence=(det|model)[ \t]*$/ { print; exit }
    /^verdict=(same|reroute|new) target=[^ ]+ confidence=(det|model)$/ { print; exit }
  ')
	[ -n "$line" ] || return 1
	PARSE_VERDICT=$(printf '%s\n' "$line" | sed -n 's/^verdict=\([^ ]*\).*/\1/p')
	PARSE_TARGET=$(printf '%s\n' "$line" | sed -n 's/.*target=\([^ ]*\).*/\1/p')
	PARSE_CONF=$(printf '%s\n' "$line" | sed -n 's/.*confidence=\([^ ]*\).*/\1/p')
	case "$PARSE_VERDICT" in
	same | reroute | new) ;;
	*) return 1 ;;
	esac
	case "$PARSE_CONF" in
	det | model) ;;
	*) return 1 ;;
	esac
	[ -n "$PARSE_TARGET" ] || return 1
	if [ "$PARSE_VERDICT" = new ]; then
		PARSE_TARGET=-
	fi
	if [ "$PARSE_VERDICT" = same ] && [ "$PARSE_TARGET" = - ]; then
		PARSE_TARGET=$(resolve_session_id)
	fi
	if [ "$PARSE_VERDICT" = reroute ]; then
		[ "$PARSE_TARGET" != - ] || return 1
		[ -f "$SESSIONS_DIR/$PARSE_TARGET.brief" ] || return 1
	fi
	return 0
}

emit_verdict() { # <verdict> <target> <confidence> ; message on stdin for logging/staging
	local verdict=$1 target=$2 conf=$3 msg
	msg=$(cat)
	printf '%s' "$msg" | record_verdict "$verdict" "$target" "$conf"
	case "$verdict" in
	reroute | new)
		printf '%s' "$msg" | stage_pending_route "$verdict" "$target" "$conf"
		;;
	esac
	printf 'verdict=%s target=%s confidence=%s\n' "$verdict" "$target" "$conf"
}

# --- CLI -------------------------------------------------------------------

SESSION_ID_ARG=
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

# --on-submit
msg=$(cat)
verdict=
target=
conf=det

# 1) Cheap same against current anchors.
if [ -s "$ANCHORS_FILE" ] && printf '%s' "$msg" | message_matches_anchor "$ANCHORS_FILE"; then
	printf '%s' "$msg" | emit_verdict same "$session_id" det
	exit 0
fi

# 2) Unique deterministic reroute against other session briefs.
reroute_hits=
reroute_count=0
while IFS= read -r other; do
	[ -n "$other" ] || continue
	brief="$SESSIONS_DIR/$other.brief"
	[ -f "$brief" ] || continue
	af=
	af=$(brief_anchors_file "$brief") || continue
	if [ -s "$af" ] && printf '%s' "$msg" | message_matches_anchor "$af"; then
		reroute_hits="$reroute_hits$other"$'\n'
		reroute_count=$((reroute_count + 1))
	fi
	rm -f "$af" 2>/dev/null || true
done < <(list_other_session_ids "$session_id")

if [ "$reroute_count" -eq 1 ]; then
	target=$(printf '%s' "$reroute_hits" | awk 'NF{print; exit}')
	printf '%s' "$msg" | emit_verdict reroute "$target" det
	exit 0
fi

if [ "$reroute_count" -gt 1 ]; then
	# Ambiguous multi-match -> model.
	:
elif ! [ -s "$ANCHORS_FILE" ]; then
	# No current anchors and no other unique match -> clear new.
	printf '%s' "$msg" | emit_verdict new - det
	exit 0
elif printf '%s' "$msg" | message_looks_short_reply; then
	# Open asks remain, message looks like a short answer -> model.
	:
else
	# Substantial unrelated message with no brief matches -> clear new.
	printf '%s' "$msg" | emit_verdict new - det
	exit 0
fi

# 3) Ambiguous: ephemeral router agent.
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
if agent_out=$(build_router_prompt "$session_id" "$tmpmsg" | spawn_router_agent); then
	rm -f "$tmpmsg"
	if parse_verdict_line "$agent_out"; then
		# Force model confidence label even if the agent echoed det.
		printf '%s' "$msg" | emit_verdict "$PARSE_VERDICT" "$PARSE_TARGET" model
		exit 0
	fi
	record_failure "router agent returned unparseable verdict"
else
	rm -f "$tmpmsg"
	# spawn_router_agent already recorded failure when possible
fi

# Fail-open: allow into the current primary.
printf '%s' "$msg" | emit_verdict same "$session_id" det
exit 0
