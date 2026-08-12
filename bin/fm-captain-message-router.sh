#!/usr/bin/env bash
# fm-captain-message-router.sh - Captain-message continuity router (P0 owner).
#
# NOT watcher continuity. This has nothing to do with docs/watcher-continuity.md,
# the supervision/watcher cycle, or bin/fm-continuity-*. This owner routes an
# incoming CAPTAIN CHAT MESSAGE relative to the primary session's open asks so a
# late or unrelated reply does not silently steer the wrong turn. See
# data/firstmate-captain-continuity/spec.md for the full design.
#
# The Firstmate PRIMARY agent never runs this. A verified harness hook (Pi first)
# calls it; bash owns the truth; the agent owns nothing. This P0 owner is
# deterministic and model-free: it extracts and persists the current session's
# open-ask anchors on settle, and classifies a submitted captain message against
# them (same vs. unknown) on submit. Reroute/new verdicts and the spawned router
# agent are later phases (spec sections 8, 14); an ambiguous message is `unknown`
# and always allowed here.
#
# Modes (assistant message or captain message on stdin):
#   fm-captain-message-router.sh --on-settle   # last assistant turn text on stdin
#   fm-captain-message-router.sh --on-submit   # captain message text on stdin
#   fm-captain-message-router.sh --help
#
# --on-settle: extract question anchors (split on `?`, normalized, deduped) and
#   overwrite the current open-ask set. Deterministic multi-ask verification: if
#   two or more questions were asked but fewer than two distinct anchors survive,
#   surface a one-line warning to stderr (never blocks). stdout stays empty.
#
# --on-submit: classify the message against the current anchors and print exactly
#   one machine-readable verdict line to stdout:
#     verdict=<same|unknown> target=<-|session-id> confidence=det
#   `same` means the message shares salient tokens with an open anchor; anything
#   else is `unknown` (deferred to a later model phase). Every verdict is appended
#   to the verdict log. The hook, not this owner, decides how to inject the line.
#
# State (all local-only, never committed), under $STATE/captain-router/:
#   anchors.current  - one normalized open-ask anchor per line (settle output)
#   verdicts.log     - append-only: <iso8601>\t<verdict>\t<target>\t<conf>\t<digest>
#
# Scope: a genuine firstmate PRIMARY home only (main home or a marked secondmate
# home), exactly like bin/fm-sessionstart-nudge.sh. It is inert (silent exit 0) in
# a child crew/scout worktree and for a no-mistakes gate agent.
#
# FAIL-OPEN: every error path (bad scope, missing dir, empty input, missing
# hashing tool) exits 0 and never blocks the captain. Only invalid CLI usage
# exits non-zero. The captain is never locked out by a broken router.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
ROUTER_DIR="$STATE/captain-router"
ANCHORS_FILE="$ROUTER_DIR/anchors.current"
VERDICTS_LOG="$ROUTER_DIR/verdicts.log"

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

record_verdict() { # <verdict> <target> <confidence>; message on stdin
	local verdict=$1 target=$2 conf=$3 ts digest
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || ts=unknown
	digest=$({ shasum -a 256 2>/dev/null || sha256sum 2>/dev/null; } | awk '{print substr($1,1,12)}')
	[ -n "$digest" ] || digest=nodigest
	printf '%s\t%s\t%s\t%s\t%s\n' "$ts" "$verdict" "$target" "$conf" "$digest" >>"$VERDICTS_LOG"
}

mode=${1-}
case "$mode" in
--help | -h)
	usage
	exit 0
	;;
--on-settle | --on-submit) ;;
*)
	usage >&2
	exit 2
	;;
esac

# Inert for a gate agent or outside a genuine primary. Fail-open: silent exit 0.
fm_is_gate_agent "$FM_ROOT" && exit 0
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
mkdir -p "$ROUTER_DIR" 2>/dev/null || exit 0

if [ "$mode" = --on-settle ]; then
	msg=$(cat)
	raw_anchors=$(printf '%s' "$msg" | extract_anchors)
	uniq_anchors=$(printf '%s\n' "$raw_anchors" | awk 'NF && !seen[$0]++')
	raw_count=$(printf '%s\n' "$raw_anchors" | awk 'NF{c++} END{print c+0}')
	uniq_count=$(printf '%s\n' "$uniq_anchors" | awk 'NF{c++} END{print c+0}')
	printf '%s\n' "$uniq_anchors" | awk 'NF' >"$ANCHORS_FILE" 2>/dev/null || exit 0
	if [ "$raw_count" -ge 2 ] && [ "$uniq_count" -lt 2 ]; then
		printf 'captain-router: multi-ask verification - %s question(s) asked but %s distinct anchor(s) recorded\n' \
			"$raw_count" "$uniq_count" >&2
	fi
	exit 0
fi

# --on-submit
msg=$(cat)
verdict=unknown
target=-
if [ -s "$ANCHORS_FILE" ] && printf '%s' "$msg" | message_matches_anchor "$ANCHORS_FILE"; then
	verdict=same
fi
printf '%s' "$msg" | record_verdict "$verdict" "$target" det
printf 'verdict=%s target=%s confidence=det\n' "$verdict" "$target"
exit 0
