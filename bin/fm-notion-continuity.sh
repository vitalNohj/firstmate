#!/usr/bin/env bash
# fm-notion-continuity.sh - Firstmate shell surface for Notion Continuity
# (Contexts + Entries). Uses a local secret; never prints the token; never
# commits it. Prefer this over ad-hoc curl with secrets in argv.
#
# Subcommands:
#   contexts-export [--out <path>]     Export Contexts as JSONL (stdout or file)
#   context-upsert --router-session <id> [--name ...] [--semantics ...]
#       [--schema ...] [--github ...] [--status ...]
#       [--herdr-session ...] [--herdr-target ...] [--herdr-workspace ...]
#   entry-add --router-session <id> --text <msg> [--title <title>]
#   sync-briefs [--out <path>]         Export Contexts then run fm-captain-notion-sync
#   --help
#
# Auth (first match wins; never echoed):
#   FM_NOTION_TOKEN, NOTION_TOKEN, or file config/notion-token (one line)
#
# DB ids / property names (optional local config, gitignored):
#   config/notion-continuity.env  (see docs/examples/notion-continuity.env.example)
#   or env FM_NOTION_CONTEXTS_DS / FM_NOTION_ENTRIES_DS / FM_NOTION_HUB_PAGE
#
# Scope: genuine firstmate PRIMARY home only. Inert outside primary / gate.
# FAIL-OPEN for missing config/token/API errors on mutating helper paths used by
# hooks (sync-briefs, entry-add): exit 0 with a short stderr note. Invalid CLI
# usage exits 2. contexts-export / context-upsert exit non-zero on hard API
# failure so agents can see the error (still never print the token).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
ROUTER_DIR="$STATE/captain-router"
NOTION_VERSION="${FM_NOTION_VERSION:-2025-09-03}"
NOTION_API="${FM_NOTION_API:-https://api.notion.com/v1}"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"

usage() {
	awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
}

# Defaults match Jonathan's Continuity hub layout (override via env/config).
CONTEXTS_DS_DEFAULT=d350f81c-d63f-43b9-b18c-2c0ded0a63d3
ENTRIES_DS_DEFAULT=7ae6f252-5f1d-43ca-8874-03c479305148
HUB_PAGE_DEFAULT=3ba92c218ab281119e54f786ee0eb0f7
CONTEXTS_DB_PAGE_DEFAULT=9e84adff39124e7394d19ccda8926053
ENTRIES_DB_PAGE_DEFAULT=e3e0893e2577471c9de67e88945c4404

# Property name defaults (Contexts).
PROP_NAME_DEFAULT=Name
PROP_ROUTER_DEFAULT="Router session"
PROP_SEMANTICS_DEFAULT=Semantics
PROP_SCHEMA_DEFAULT=Schema
PROP_GITHUB_DEFAULT=GitHub
PROP_STATUS_DEFAULT=Status
PROP_HERDR_SESSION_DEFAULT="Herdr session"
PROP_HERDR_TARGET_DEFAULT="Herdr target"
PROP_HERDR_WORKSPACE_DEFAULT="Herdr workspace"

# Property name defaults (Entries).
PROP_ENTRY_NAME_DEFAULT=Name
PROP_ENTRY_CONTEXT_DEFAULT=Context
PROP_ENTRY_BODY_DEFAULT=Body

load_config() {
	# Optional key=value file. Never print contents.
	local envfile="$CONFIG/notion-continuity.env" key val
	if [ -f "$envfile" ]; then
		while IFS= read -r line || [ -n "$line" ]; do
			case "$line" in
			'' | \#*) continue ;;
			*=*)
				key=${line%%=*}
				val=${line#*=}
				key=${key%%[[:space:]]*}
				key=${key##[[:space:]]*}
				# Strip optional surrounding quotes
				case "$val" in
				\"*\") val=${val#\"}; val=${val%\"} ;;
				\'*\') val=${val#\'}; val=${val%\'} ;;
				esac
				case "$key" in
				FM_NOTION_* | NOTION_TOKEN)
					if [ -z "${!key:-}" ]; then
						printf -v "$key" '%s' "$val"
						export "${key?}"
					fi
					;;
				esac
				;;
			esac
		done <"$envfile"
	fi

	CONTEXTS_DS=${FM_NOTION_CONTEXTS_DS:-$CONTEXTS_DS_DEFAULT}
	ENTRIES_DS=${FM_NOTION_ENTRIES_DS:-$ENTRIES_DS_DEFAULT}
	HUB_PAGE=${FM_NOTION_HUB_PAGE:-$HUB_PAGE_DEFAULT}
	CONTEXTS_DB_PAGE=${FM_NOTION_CONTEXTS_DB_PAGE:-$CONTEXTS_DB_PAGE_DEFAULT}
	ENTRIES_DB_PAGE=${FM_NOTION_ENTRIES_DB_PAGE:-$ENTRIES_DB_PAGE_DEFAULT}

	PROP_NAME=${FM_NOTION_PROP_NAME:-$PROP_NAME_DEFAULT}
	PROP_ROUTER=${FM_NOTION_PROP_ROUTER_SESSION:-$PROP_ROUTER_DEFAULT}
	PROP_SEMANTICS=${FM_NOTION_PROP_SEMANTICS:-$PROP_SEMANTICS_DEFAULT}
	PROP_SCHEMA=${FM_NOTION_PROP_SCHEMA:-$PROP_SCHEMA_DEFAULT}
	PROP_GITHUB=${FM_NOTION_PROP_GITHUB:-$PROP_GITHUB_DEFAULT}
	PROP_STATUS=${FM_NOTION_PROP_STATUS:-$PROP_STATUS_DEFAULT}
	PROP_HERDR_SESSION=${FM_NOTION_PROP_HERDR_SESSION:-$PROP_HERDR_SESSION_DEFAULT}
	PROP_HERDR_TARGET=${FM_NOTION_PROP_HERDR_TARGET:-$PROP_HERDR_TARGET_DEFAULT}
	PROP_HERDR_WORKSPACE=${FM_NOTION_PROP_HERDR_WORKSPACE:-$PROP_HERDR_WORKSPACE_DEFAULT}

	PROP_ENTRY_NAME=${FM_NOTION_PROP_ENTRY_NAME:-$PROP_ENTRY_NAME_DEFAULT}
	PROP_ENTRY_CONTEXT=${FM_NOTION_PROP_ENTRY_CONTEXT:-$PROP_ENTRY_CONTEXT_DEFAULT}
	PROP_ENTRY_BODY=${FM_NOTION_PROP_ENTRY_BODY:-$PROP_ENTRY_BODY_DEFAULT}

	# Retained for docs/operators (db page ids); data_source ids are what the API uses.
	: "$CONTEXTS_DB_PAGE" "$ENTRIES_DB_PAGE" "$HUB_PAGE"
}

resolve_token() {
	# Print token to stdout for capture into a local var only. Callers must not log it.
	local tok file
	tok=${FM_NOTION_TOKEN:-${NOTION_TOKEN:-}}
	if [ -z "$tok" ]; then
		file="$CONFIG/notion-token"
		if [ -f "$file" ]; then
			IFS= read -r tok <"$file" || tok=
			tok=${tok//$'\r'/}
		fi
	fi
	printf '%s' "$tok"
}

notion_curl() {
	# notion_curl TOKEN METHOD PATH [curl --data-raw ...]
	# Prints response body on stdout. Returns curl/HTTP failure via exit status.
	local token=$1 method=$2 path=$3
	shift 3
	local url="$NOTION_API$path"
	local http body tmp
	tmp=$(mktemp "${TMPDIR:-/tmp}/fm-notion.XXXXXX") || return 1
	http=$(curl -sS -o "$tmp" -w '%{http_code}' \
		-X "$method" "$url" \
		-H "Authorization: Bearer ${token}" \
		-H "Notion-Version: ${NOTION_VERSION}" \
		-H "Content-Type: application/json" \
		"$@" 2>/dev/null) || {
		rm -f "$tmp"
		return 1
	}
	body=$(cat "$tmp" 2>/dev/null || true)
	rm -f "$tmp"
	case "$http" in
	2*)
		printf '%s' "$body"
		return 0
		;;
	*)
		# Redact anything that looks like a token if Notion echoed it (rare).
		printf '%s\n' "$body" | sed -E 's/secret_[A-Za-z0-9]+/[redacted]/g; s/ntn_[A-Za-z0-9]+/[redacted]/g' >&2
		printf 'notion-continuity: HTTP %s for %s %s\n' "$http" "$method" "$path" >&2
		return 1
		;;
	esac
}


page_to_context_json() {
	# stdin: Notion page JSON -> one JSONL context object
	jq -c --arg name_p "$PROP_NAME" --arg router_p "$PROP_ROUTER" \
		--arg sem_p "$PROP_SEMANTICS" --arg schema_p "$PROP_SCHEMA" \
		--arg gh_p "$PROP_GITHUB" --arg status_p "$PROP_STATUS" \
		--arg hs_p "$PROP_HERDR_SESSION" --arg ht_p "$PROP_HERDR_TARGET" \
		--arg hw_p "$PROP_HERDR_WORKSPACE" '
		def plain($prop):
			if $prop == null then ""
			elif $prop.type == "title" then ([ $prop.title[]?.plain_text ] | join(""))
			elif $prop.type == "rich_text" then ([ $prop.rich_text[]?.plain_text ] | join(""))
			elif $prop.type == "url" then ($prop.url // "")
			elif $prop.type == "status" then ($prop.status.name // "")
			elif $prop.type == "select" then ($prop.select.name // "")
			else "" end;
		. as $page |
		($page.properties[$name_p] | plain(.)) as $name |
		($page.properties[$router_p] | plain(.)) as $router |
		($page.properties[$sem_p] | plain(.)) as $sem |
		($page.properties[$schema_p] | plain(.)) as $schema |
		($page.properties[$gh_p] | plain(.)) as $gh |
		($page.properties[$status_p] | plain(.)) as $status |
		($page.properties[$hs_p] | plain(.)) as $hs |
		($page.properties[$ht_p] | plain(.)) as $ht |
		($page.properties[$hw_p] | plain(.)) as $hw |
		{
			router_session: (if $router != "" then $router else $name end),
			name: $name,
			semantics: $sem,
			schema: $schema,
			notion_url: ($page.url // ""),
			github: $gh,
			herdr_session: $hs,
			herdr_target: $ht,
			herdr_workspace: $hw,
			status: $status,
			notion_page_id: $page.id
		}
	' 2>/dev/null
}





cmd_contexts_export() {
	local token out_path="" cursor="" has_more=true tmp page_json row count=0
	out_path=
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--out)
			shift
			out_path=${1-}
			[ -n "$out_path" ] || {
				usage >&2
				return 2
			}
			shift
			;;
		--out=*)
			out_path=${1#--out=}
			shift
			;;
		*)
			usage >&2
			return 2
			;;
		esac
	done

	token=$(resolve_token)
	if [ -z "$token" ]; then
		printf 'notion-continuity: no token (set FM_NOTION_TOKEN / NOTION_TOKEN or config/notion-token)\n' >&2
		return 1
	fi
	if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
		printf 'notion-continuity: jq and curl are required\n' >&2
		return 1
	fi

	tmp=$(mktemp "${TMPDIR:-/tmp}/fm-notion-export.XXXXXX") || return 1
	: >"$tmp"
	has_more=true
	cursor=
	while [ "$has_more" = true ]; do
		local body resp
		if [ -n "$cursor" ]; then
			body=$(jq -n --arg c "$cursor" '{start_cursor:$c,page_size:100}')
		else
			body='{"page_size":100}'
		fi
		resp=$(notion_curl "$token" POST "/data_sources/${CONTEXTS_DS}/query" --data-raw "$body") || {
			rm -f "$tmp"
			return 1
		}
		printf '%s' "$resp" | jq -c '.results[]?' 2>/dev/null | while IFS= read -r page_json; do
			[ -n "$page_json" ] || continue
			row=$(printf '%s' "$page_json" | page_to_context_json) || continue
			[ -n "$row" ] || continue
			# Require a non-empty router_session after mapping.
			printf '%s\n' "$row" | jq -e -r 'select((.router_session // "") != "")' >>"$tmp" 2>/dev/null || true
		done
		has_more=$(printf '%s' "$resp" | jq -r '.has_more // false')
		cursor=$(printf '%s' "$resp" | jq -r '.next_cursor // empty')
		[ "$has_more" = true ] || break
		[ -n "$cursor" ] || break
	done

	count=$(awk 'NF{c++} END{print c+0}' "$tmp")
	if [ -n "$out_path" ]; then
		mkdir -p "$(dirname "$out_path")" 2>/dev/null || true
		cp -f "$tmp" "$out_path" || {
			rm -f "$tmp"
			return 1
		}
		printf 'exported=%s out=%s\n' "$count" "$out_path"
	else
		cat "$tmp"
	fi
	rm -f "$tmp"
	return 0
}

find_context_page_id() {
	# Echo page id for router_session, or empty.
	local token=$1 router=$2 body resp
	body=$(jq -n --arg p "$PROP_ROUTER" --arg v "$router" \
		'{page_size:5, filter:{property:$p, rich_text:{equals:$v}}}')
	resp=$(notion_curl "$token" POST "/data_sources/${CONTEXTS_DS}/query" --data-raw "$body") || return 1
	# Prefer rich_text match; also try title-equals on Name when Router session empty.
	local id
	id=$(printf '%s' "$resp" | jq -r '.results[0].id // empty')
	if [ -z "$id" ]; then
		body=$(jq -n --arg p "$PROP_NAME" --arg v "$router" \
			'{page_size:5, filter:{property:$p, title:{equals:$v}}}')
		resp=$(notion_curl "$token" POST "/data_sources/${CONTEXTS_DS}/query" --data-raw "$body") || return 1
		id=$(printf '%s' "$resp" | jq -r '.results[0].id // empty')
	fi
	printf '%s' "$id"
}

build_context_properties() {
	# Args: name semantics schema github status herdr_session herdr_target herdr_workspace router
	local name=$1 semantics=$2 schema=$3 github=$4 status=$5
	local hs=$6 ht=$7 hw=$8 router=$9
	jq -n \
		--arg name_p "$PROP_NAME" --arg router_p "$PROP_ROUTER" \
		--arg sem_p "$PROP_SEMANTICS" --arg schema_p "$PROP_SCHEMA" \
		--arg gh_p "$PROP_GITHUB" --arg status_p "$PROP_STATUS" \
		--arg hs_p "$PROP_HERDR_SESSION" --arg ht_p "$PROP_HERDR_TARGET" \
		--arg hw_p "$PROP_HERDR_WORKSPACE" \
		--arg name "$name" --arg router "$router" --arg sem "$semantics" \
		--arg schema "$schema" --arg gh "$github" --arg status "$status" \
		--arg hs "$hs" --arg ht "$ht" --arg hw "$hw" '
		def title($t): {title:[{type:"text",text:{content:$t}}]};
		def rich($t): {rich_text:[{type:"text",text:{content:$t}}]};
		def url($u): {url:$u};
		def status($n): {status:{name:$n}};
		{}
		| if $name != "" then .[$name_p] = title($name) else . end
		| if $router != "" then .[$router_p] = rich($router) else . end
		| if $sem != "" then .[$sem_p] = rich($sem) else . end
		| if $schema != "" then .[$schema_p] = rich($schema) else . end
		| if $gh != "" then .[$gh_p] = url($gh) else . end
		| if $status != "" then .[$status_p] = status($status) else . end
		| if $hs != "" then .[$hs_p] = rich($hs) else . end
		| if $ht != "" then .[$ht_p] = rich($ht) else . end
		| if $hw != "" then .[$hw_p] = rich($hw) else . end
	'
}

cmd_context_upsert() {
	local router="" name="" semantics="" schema="" github="" status="" hs="" ht="" hw=""
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--router-session)
			shift
			router=${1-}
			shift
			;;
		--router-session=*)
			router=${1#--router-session=}
			shift
			;;
		--name)
			shift
			name=${1-}
			shift
			;;
		--name=*)
			name=${1#--name=}
			shift
			;;
		--semantics)
			shift
			semantics=${1-}
			shift
			;;
		--semantics=*)
			semantics=${1#--semantics=}
			shift
			;;
		--schema)
			shift
			schema=${1-}
			shift
			;;
		--schema=*)
			schema=${1#--schema=}
			shift
			;;
		--github)
			shift
			github=${1-}
			shift
			;;
		--github=*)
			github=${1#--github=}
			shift
			;;
		--status)
			shift
			status=${1-}
			shift
			;;
		--status=*)
			status=${1#--status=}
			shift
			;;
		--herdr-session)
			shift
			hs=${1-}
			shift
			;;
		--herdr-session=*)
			hs=${1#--herdr-session=}
			shift
			;;
		--herdr-target)
			shift
			ht=${1-}
			shift
			;;
		--herdr-target=*)
			ht=${1#--herdr-target=}
			shift
			;;
		--herdr-workspace)
			shift
			hw=${1-}
			shift
			;;
		--herdr-workspace=*)
			hw=${1#--herdr-workspace=}
			shift
			;;
		*)
			usage >&2
			return 2
			;;
		esac
	done
	[ -n "$router" ] || {
		printf 'notion-continuity: --router-session required\n' >&2
		return 2
	}
	case "$router" in
	*[!A-Za-z0-9._-]*)
		printf 'notion-continuity: unsafe router_session\n' >&2
		return 2
		;;
	esac
	[ -n "$name" ] || name=$router

	local token page_id props body resp
	token=$(resolve_token)
	if [ -z "$token" ]; then
		printf 'notion-continuity: no token\n' >&2
		return 1
	fi
	props=$(build_context_properties "$name" "$semantics" "$schema" "$github" "$status" "$hs" "$ht" "$hw" "$router")
	page_id=$(find_context_page_id "$token" "$router" || true)
	if [ -n "$page_id" ]; then
		body=$(jq -n --argjson props "$props" '{properties:$props}')
		resp=$(notion_curl "$token" PATCH "/pages/${page_id}" --data-raw "$body") || return 1
		printf 'upserted=update page=%s router_session=%s\n' \
			"$(printf '%s' "$resp" | jq -r '.id // empty')" "$router"
	else
		body=$(jq -n --arg ds "$CONTEXTS_DS" --argjson props "$props" \
			'{parent:{type:"data_source_id",data_source_id:$ds},properties:$props}')
		resp=$(notion_curl "$token" POST "/pages" --data-raw "$body") || return 1
		printf 'upserted=create page=%s router_session=%s\n' \
			"$(printf '%s' "$resp" | jq -r '.id // empty')" "$router"
	fi
	return 0
}

cmd_entry_add() {
	local router="" text="" title=""
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--router-session)
			shift
			router=${1-}
			shift
			;;
		--router-session=*)
			router=${1#--router-session=}
			shift
			;;
		--text)
			shift
			text=${1-}
			shift
			;;
		--text=*)
			text=${1#--text=}
			shift
			;;
		--title)
			shift
			title=${1-}
			shift
			;;
		--title=*)
			title=${1#--title=}
			shift
			;;
		*)
			usage >&2
			return 2
			;;
		esac
	done
	[ -n "$router" ] || {
		printf 'notion-continuity: --router-session required\n' >&2
		return 2
	}
	[ -n "$text" ] || {
		printf 'notion-continuity: --text required\n' >&2
		return 2
	}
	[ -n "$title" ] || title=$(printf '%s' "$text" | tr '\n' ' ' | awk '{
		gsub(/[ \t]+/," "); gsub(/^ +| +$/,"");
		if (length($0)>80) $0=substr($0,1,77)"..."; print
	}')

	local token page_id props body resp
	token=$(resolve_token)
	if [ -z "$token" ]; then
		# Fail-open for hooks: missing token is not fatal.
		printf 'notion-continuity: no token; entry-add skipped\n' >&2
		return 0
	fi

	page_id=$(find_context_page_id "$token" "$router" || true)
	if [ -z "$page_id" ]; then
		# Best-effort: create a minimal Context so the Entry can link.
		cmd_context_upsert --router-session "$router" --name "$router" >/dev/null || true
		page_id=$(find_context_page_id "$token" "$router" || true)
	fi
	if [ -z "$page_id" ]; then
		printf 'notion-continuity: could not resolve Context for %s; entry-add skipped\n' "$router" >&2
		return 0
	fi

	# Truncate body to Notion rich_text limit (~2000).
	local body_text
	body_text=$(printf '%s' "$text" | awk '{
		s=$0
	}
	END {
		if (length(s)>1900) s=substr(s,1,1897)"..."
		print s
	}')

	props=$(jq -n \
		--arg name_p "$PROP_ENTRY_NAME" --arg ctx_p "$PROP_ENTRY_CONTEXT" \
		--arg body_p "$PROP_ENTRY_BODY" \
		--arg title "$title" --arg body "$body_text" --arg ctx "$page_id" '
		def title($t): {title:[{type:"text",text:{content:$t}}]};
		def rich($t): {rich_text:[{type:"text",text:{content:$t}}]};
		{
			($name_p): title($title),
			($ctx_p): {relation:[{id:$ctx}]},
			($body_p): rich($body)
		}
	')
	body=$(jq -n --arg ds "$ENTRIES_DS" --argjson props "$props" \
		'{parent:{type:"data_source_id",data_source_id:$ds},properties:$props}')
	resp=$(notion_curl "$token" POST "/pages" --data-raw "$body") || {
		printf 'notion-continuity: entry-add API failed; skipped\n' >&2
		return 0
	}
	printf 'entry_added=1 page=%s router_session=%s\n' \
		"$(printf '%s' "$resp" | jq -r '.id // empty')" "$router"
	return 0
}

cmd_sync_briefs() {
	local out_path="$ROUTER_DIR/notion-contexts.jsonl" status=0 sync_out
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--out)
			shift
			out_path=${1-}
			shift
			;;
		--out=*)
			out_path=${1#--out=}
			shift
			;;
		*)
			usage >&2
			return 2
			;;
		esac
	done

	local token
	token=$(resolve_token)
	if [ -z "$token" ]; then
		printf 'notion-continuity: no token; sync-briefs skipped\n' >&2
		printf 'synced=0 skipped=0\n'
		return 0
	fi

	mkdir -p "$ROUTER_DIR" 2>/dev/null || true
	if ! cmd_contexts_export --out "$out_path"; then
		printf 'notion-continuity: contexts-export failed; sync-briefs skipped\n' >&2
		printf 'synced=0 skipped=0\n'
		return 0
	fi
	sync_out=$("$SCRIPT_DIR/fm-captain-notion-sync.sh" --from-jsonl "$out_path" 2>/dev/null) || status=$?
	if [ "$status" -ne 0 ]; then
		printf 'notion-continuity: local brief sync failed; skipped\n' >&2
		printf 'synced=0 skipped=0\n'
		return 0
	fi
	printf '%s\n' "$sync_out"
	return 0
}

# --- CLI -------------------------------------------------------------------

cmd=
case "${1-}" in
--help | -h)
	usage
	exit 0
	;;
contexts-export | context-upsert | entry-add | sync-briefs)
	cmd=$1
	shift
	;;
*)
	usage >&2
	exit 2
	;;
esac

fm_is_gate_agent "$FM_ROOT" && exit 0
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

load_config

case "$cmd" in
contexts-export) cmd_contexts_export "$@" ;;
context-upsert) cmd_context_upsert "$@" ;;
entry-add) cmd_entry_add "$@" ;;
sync-briefs) cmd_sync_briefs "$@" ;;
esac
exit $?
