#!/usr/bin/env bash
# fm-captain-notion-sync.sh - Sync buddy-exported Notion Context Router rows into
# local captain-router session briefs (no Notion API; no token).
#
# Buddy owns the Notion export. Firstmate only upserts local continuity state
# under state/captain-router/ so session briefs carry Notion metadata and
# semantics tokens participate in deterministic reroute matching.
#
# Usage:
#   fm-captain-notion-sync.sh --from-jsonl <path>
#   fm-captain-notion-sync.sh --help
#
# JSONL: one object per line. Flexible keys; recognized:
#   router_session (required, non-empty; sanitized like resolve_session_id —
#     only A-Za-z0-9._- else skip with stderr warning)
#   name, semantics, schema, notion_url, github,
#   herdr_session, herdr_target, herdr_workspace, status (status ignored locally)
#
# For each valid row:
#   - Upsert state/captain-router/sessions/<router_session>.brief
#   - Set/update header fields from JSON
#   - topic := schema (truncated) if schema non-empty else name
#   - Preserve existing anchors after --- (do not wipe settle anchors)
#   - Append unique semantics tokens (split on /) as extra anchor lines when
#     not already present, so deterministic reroute can match Notion semantics
#   - Write a mirror copy of the input to state/captain-router/notion-contexts.jsonl
#
# Prints one summary line: synced=<n> skipped=<n>
#
# Scope: a genuine firstmate PRIMARY home only (main home or a marked secondmate
# home), exactly like bin/fm-captain-message-router.sh. Inert (silent exit 0)
# in a child crew/scout worktree and for a no-mistakes gate agent.
#
# FAIL-OPEN: every error path (bad scope, missing jq, unreadable input, bad rows)
# exits 0 and never blocks the captain. Only invalid CLI usage exits non-zero.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
ROUTER_DIR="$STATE/captain-router"
SESSIONS_DIR="$ROUTER_DIR/sessions"
MIRROR_FILE="$ROUTER_DIR/notion-contexts.jsonl"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"

usage() {
	awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
}

iso_now() {
	date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown\n'
}

topic_truncate() {
	# Collapse whitespace and truncate like the router's topic_head.
	tr '\n' ' ' | awk '{
      gsub(/[ \t]+/, " ")
      gsub(/^ +| +$/, "")
      if (length($0) > 160) $0 = substr($0, 1, 157) "..."
      print
    }'
}

sanitize_session_id() {
	# Echo sanitized id, or empty if unsafe (caller skips). Unlike the router's
	# resolve_session_id fallback to `primary`, invalid sync ids are skipped.
	local sid=$1
	sid=${sid//[[:space:]]/}
	[ -n "$sid" ] || {
		printf '\n'
		return 0
	}
	case "$sid" in
	*[!A-Za-z0-9._-]*)
		printf '\n'
		return 0
		;;
	esac
	printf '%s\n' "$sid"
}


upsert_brief_from_row() {
	# Args via env-ish locals set by caller through named params is awkward in
	# bash; pass as: sid name semantics schema notion_url github herdr_session
	# herdr_target herdr_workspace
	local sid=$1 name=$2 semantics=$3 schema=$4 notion_url=$5 github=$6
	local herdr_session=$7 herdr_target=$8 herdr_workspace=$9
	local brief tmp topic anchors_tmp tok
	brief="$SESSIONS_DIR/$sid.brief"
	tmp="$brief.tmp.$$"
	mkdir -p "$SESSIONS_DIR" 2>/dev/null || return 1

	if [ -n "$schema" ]; then
		topic=$(printf '%s' "$schema" | topic_truncate)
	else
		topic=$(printf '%s' "$name" | topic_truncate)
	fi

	# Preserve prior settle anchors (body after ---).
	anchors_tmp=$(mktemp "$ROUTER_DIR/anchors.XXXXXX" 2>/dev/null) || anchors_tmp=
	if [ -n "$anchors_tmp" ] && [ -f "$brief" ]; then
		awk 'BEGIN{p=0} /^---$/{p=1; next} p && NF{print}' "$brief" >"$anchors_tmp" 2>/dev/null || true
	elif [ -n "$anchors_tmp" ]; then
		: >"$anchors_tmp"
	fi

	# Append unique semantics tokens (split on /) as extra anchors.
	if [ -n "$semantics" ] && [ -n "$anchors_tmp" ]; then
		while IFS= read -r tok || [ -n "$tok" ]; do
			[ -n "$tok" ] || continue
			# Skip if already present as an exact anchor line.
			if grep -qxF -- "$tok" "$anchors_tmp" 2>/dev/null; then
				continue
			fi
			printf '%s\n' "$tok" >>"$anchors_tmp"
		done < <(printf '%s\n' "$semantics" | tr '/' '\n' | awk 'NF')
	fi

	{
		printf 'session_id=%s\n' "$sid"
		printf 'updated=%s\n' "$(iso_now)"
		printf 'topic=%s\n' "$topic"
		[ -n "$semantics" ] && printf 'semantics=%s\n' "$semantics"
		[ -n "$notion_url" ] && printf 'notion_url=%s\n' "$notion_url"
		# notion_name mirrors the Contexts DB name field when provided.
		[ -n "$name" ] && printf 'notion_name=%s\n' "$name"
		[ -n "$github" ] && printf 'github=%s\n' "$github"
		[ -n "$schema" ] && printf 'schema=%s\n' "$schema"
		[ -n "$herdr_session" ] && printf 'herdr_session=%s\n' "$herdr_session"
		[ -n "$herdr_target" ] && printf 'herdr_target=%s\n' "$herdr_target"
		[ -n "$herdr_workspace" ] && printf 'herdr_workspace=%s\n' "$herdr_workspace"
		printf -- '---\n'
		if [ -n "$anchors_tmp" ] && [ -f "$anchors_tmp" ]; then
			awk 'NF' "$anchors_tmp"
		fi
	} >"$tmp" 2>/dev/null || {
		rm -f "$tmp" "$anchors_tmp" 2>/dev/null || true
		return 1
	}
	mv -f "$tmp" "$brief" 2>/dev/null || {
		rm -f "$tmp" "$anchors_tmp" 2>/dev/null || true
		return 1
	}
	rm -f "$anchors_tmp" 2>/dev/null || true
	return 0
}

# --- CLI -------------------------------------------------------------------

jsonl_path=
while [ "$#" -gt 0 ]; do
	case "$1" in
	--help | -h)
		usage
		exit 0
		;;
	--from-jsonl)
		shift
		jsonl_path=${1-}
		[ -n "$jsonl_path" ] || {
			usage >&2
			exit 2
		}
		shift
		;;
	--from-jsonl=*)
		jsonl_path=${1#--from-jsonl=}
		[ -n "$jsonl_path" ] || {
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

[ -n "$jsonl_path" ] || {
	usage >&2
	exit 2
}

# Inert for a gate agent or outside a genuine primary. Fail-open: silent exit 0.
fm_is_gate_agent "$FM_ROOT" && exit 0
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
mkdir -p "$ROUTER_DIR" 2>/dev/null || exit 0

if ! command -v jq >/dev/null 2>&1; then
	printf 'captain-notion-sync: jq not found; skipping\n' >&2
	printf 'synced=0 skipped=0\n'
	exit 0
fi

if [ ! -f "$jsonl_path" ] || [ ! -r "$jsonl_path" ]; then
	printf 'captain-notion-sync: cannot read %s\n' "$jsonl_path" >&2
	printf 'synced=0 skipped=0\n'
	exit 0
fi

# Mirror the input JSONL locally (exact copy of what buddy exported).
cp -f "$jsonl_path" "$MIRROR_FILE" 2>/dev/null || true

synced=0
skipped=0

while IFS= read -r line || [ -n "$line" ]; do
	# Skip blank / whitespace-only lines.
	[ -n "${line//[[:space:]]/}" ] || continue

	# Flexible key extraction; missing keys become empty strings.
	# Use RS-separated fields (not TSV) so empty values do not shift columns.
	parsed=$(printf '%s\n' "$line" | jq -r '
		def s($k): ((.[$k] // "") | tostring | gsub("\u001e"; ""));
		[
			s("router_session"),
			s("name"),
			s("semantics"),
			s("schema"),
			s("notion_url"),
			s("github"),
			s("herdr_session"),
			s("herdr_target"),
			s("herdr_workspace")
		] | join("\u001e")
	' 2>/dev/null) || {
		printf 'captain-notion-sync: skip unparseable JSONL row\n' >&2
		skipped=$((skipped + 1))
		continue
	}

	IFS=$'\036' read -r router_session name semantics schema notion_url github \
		herdr_session herdr_target herdr_workspace <<<"$parsed" || true

	if [ -z "${router_session//[[:space:]]/}" ]; then
		skipped=$((skipped + 1))
		continue
	fi

	sid=$(sanitize_session_id "$router_session")
	if [ -z "$sid" ]; then
		printf 'captain-notion-sync: skip unsafe router_session=%s\n' "$router_session" >&2
		skipped=$((skipped + 1))
		continue
	fi

	if upsert_brief_from_row "$sid" "$name" "$semantics" "$schema" "$notion_url" \
		"$github" "$herdr_session" "$herdr_target" "$herdr_workspace"; then
		synced=$((synced + 1))
	else
		printf 'captain-notion-sync: failed upsert for %s\n' "$sid" >&2
		skipped=$((skipped + 1))
	fi
done <"$jsonl_path"

printf 'synced=%s skipped=%s\n' "$synced" "$skipped"
exit 0
