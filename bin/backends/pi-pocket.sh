#!/usr/bin/env bash
# bin/backends/pi-pocket.sh - the Pocket worker adapter: ship and scout
# workers as Pi Pocket linked sessions of the main Firstmate conversation.
#
# Pi Pocket owns the agent session (a Pi Durable conversation the Firstmate
# Pi Pocket drop-in starts with host.linkedSessions.start in the task
# worktree) while Treehouse still owns the task worktree. Firstmate drives it
# only through the drop-in's worker bridge, a trusted durable request/result
# file queue under state/pocket-bridge/ that bin/fm-pi-pocket-bridge.mjs
# writes and the drop-in serves for the conversation holding this home's
# session lock (docs/pi-pocket-backend.md). Every primitive here is one call
# to that helper. There is no terminal: nothing is typed, a steer is an
# unfenced Durable submit, and Escape/Ctrl-C are an abort.
#
# Explicit-only: never auto-detected and never the default (bin/fm-backend.sh).
# It runs only from a command of the main Firstmate Pi Pocket session, whose
# marker the drop-in checks; anywhere else every call refuses.
#
# Target string shape: the Pi Pocket session id the drop-in started.

# Pi Pocket has no composer, but the shared submit dispatcher in
# bin/fm-backend.sh prepares and reads the composer dialog sink around every
# adapter, so this adapter loads the same library every other backend does.
# shellcheck source=bin/fm-composer-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../fm-composer-lib.sh"

FM_BACKEND_PI_POCKET_HELPER="$(cd "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/fm-pi-pocket-bridge.mjs"

# The state directory the drop-in serves: the same one bin/fm-lock.sh binds.
fm_backend_pi_pocket_state_dir() {
  printf '%s' "${FM_STATE_OVERRIDE:-$FM_HOME/state}"
}

fm_backend_pi_pocket_tool_check() {
  command -v node >/dev/null 2>&1 || { echo "error: backend=pi-pocket selected but 'node' is not installed" >&2; return 1; }
  command -v treehouse >/dev/null 2>&1 || { echo "error: backend=pi-pocket selected but 'treehouse' is not installed" >&2; return 1; }
}

# fm_backend_pi_pocket_bridge <verb> [args...] - one bridge call. It prints
# one JSON object (capture prints text) and exits as the helper's header
# says: 3 refused, 5 bridge down, 7 no answer in time. Every failure prints
# one stderr line.
fm_backend_pi_pocket_bridge() {
  command -v node >/dev/null 2>&1 || { echo "error: backend=pi-pocket selected but 'node' is not installed" >&2; return 1; }
  node "$FM_BACKEND_PI_POCKET_HELPER" "$@" --state "$(fm_backend_pi_pocket_state_dir)"
}

# fm_backend_pi_pocket_json_get <key>: one top-level scalar from the helper's
# JSON on stdin. Fails when the object is not ok or lacks the key.
fm_backend_pi_pocket_json_get() {  # <key>
  node -e '
const key = process.argv[1];
let d;
try { d = JSON.parse(require("fs").readFileSync(0, "utf8")); } catch { process.exit(1); }
if (!d || d.ok !== true) process.exit(1);
const v = d[key];
if (v === undefined || v === null || typeof v === "object") process.exit(1);
process.stdout.write(String(v));
' "$1"
}

# The bridge answers for this session, before any spawn or control mutation.
# The helper prints its own one-line reason.
fm_backend_pi_pocket_runtime_check() {
  fm_backend_pi_pocket_tool_check || return 1
  fm_backend_pi_pocket_bridge status >/dev/null
}

# fm_backend_pi_pocket_session_start <task> <cwd> <model> <effort> <prompt>
# [exclude-tools]: start the worker's linked session in <cwd> on <model> and
# <effort> (default: the first usable model on the owner's subagent list),
# with a neutral first message; the brief follows as an unfenced submit.
# Prints the session id. Exit 3 is the drop-in's refusal (a model off the
# owner's list, a spend hold, plan mode); 7 means the start may have happened.
fm_backend_pi_pocket_session_start() {  # <task> <cwd> <model> <effort> <prompt> [exclude-tools]
  local task=$1 cwd=$2 model=$3 effort=$4 prompt=$5 exclude=${6:-} prompt_file out rc=0
  prompt_file=$(mktemp "${TMPDIR:-/tmp}/fm-pi-pocket-prompt.XXXXXX") || return 1
  printf '%s' "$prompt" > "$prompt_file" || { rm -f "$prompt_file"; return 1; }
  local -a args=(spawn --task "$task" --cwd "$cwd" --title "fm-$task" --prompt-file "$prompt_file")
  [ -z "$model" ] || [ "$model" = default ] || args+=(--model "$model")
  [ -z "$effort" ] || [ "$effort" = default ] || args+=(--thinking "$effort")
  [ -z "$exclude" ] || args+=(--exclude-tools "$exclude")
  out=$(fm_backend_pi_pocket_bridge "${args[@]}") || rc=$?
  rm -f "$prompt_file"
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s' "$out" | fm_backend_pi_pocket_json_get session
}

# fm_backend_pi_pocket_configure <session> <NAME=value>...: the task
# environment every command the worker runs gets (Pi Pocket's commandEnv).
fm_backend_pi_pocket_configure() {  # <session> <NAME=value>...
  local session=$1 env_file rc=0
  shift
  env_file=$(mktemp "${TMPDIR:-/tmp}/fm-pi-pocket-env.XXXXXX") || return 1
  node -e '
const env = {};
for (const pair of process.argv.slice(1)) {
  const at = pair.indexOf("=");
  if (at > 0) env[pair.slice(0, at)] = pair.slice(at + 1);
}
process.stdout.write(JSON.stringify(env));
' "$@" > "$env_file" || { rm -f "$env_file"; return 1; }
  fm_backend_pi_pocket_bridge configure --session "$session" --env-file "$env_file" >/dev/null || rc=$?
  rm -f "$env_file"
  return "$rc"
}

# fm_backend_pi_pocket_probe: one word naming the session's row in the status
# table: busy, idle, dead (its last run failed, from Pi Pocket's run-failed
# signal), missing (archived, retired, or gone), or unreadable.
fm_backend_pi_pocket_probe() {  # <session>
  local out
  out=$(fm_backend_pi_pocket_bridge state --session "$1" 2>/dev/null) || { printf 'unreadable'; return 0; }
  case "$(printf '%s' "$out" | fm_backend_pi_pocket_json_get state 2>/dev/null)" in
    alive)
      case "$(printf '%s' "$out" | fm_backend_pi_pocket_json_get busy 2>/dev/null)" in
        busy) printf 'busy' ;;
        idle) printf 'idle' ;;
        *) printf 'unreadable' ;;
      esac
      ;;
    dead) printf 'dead' ;;
    missing) printf 'missing' ;;
    *) printf 'unreadable' ;;
  esac
}

# The one status table: "<busy_state> <agent_state>" per probe row.
fm_backend_pi_pocket_state_row() {  # <probe-row>
  case "$1" in
    busy) printf 'busy alive' ;;
    idle) printf 'idle alive' ;;
    dead) printf 'unknown dead' ;;
    missing) printf 'unknown missing' ;;
    *) printf 'unknown unreadable' ;;
  esac
}

fm_backend_pi_pocket_busy_state() {  # <session>
  local row
  row=$(fm_backend_pi_pocket_state_row "$(fm_backend_pi_pocket_probe "$1")")
  printf '%s' "${row%% *}"
}

fm_backend_pi_pocket_agent_state() {  # <session>
  local row
  row=$(fm_backend_pi_pocket_state_row "$(fm_backend_pi_pocket_probe "$1")")
  printf '%s' "${row#* }"
}

fm_backend_pi_pocket_target_exists() {  # <session>
  case "$(fm_backend_pi_pocket_agent_state "$1")" in
    alive|dead) return 0 ;;
  esac
  return 1
}

# Pi Pocket has no composer to clear, so a live session is always ready.
fm_backend_pi_pocket_composer_state() {  # <session> [expected-label] -> empty|unknown
  case "$(fm_backend_pi_pocket_probe "$1")" in
    busy|idle|dead) printf 'empty' ;;
    *) printf 'unknown' ;;
  esac
}

fm_backend_pi_pocket_capture() {  # <session> <lines>
  fm_backend_pi_pocket_bridge capture --session "$1" --lines "${2:-40}"
}

# fm_backend_pi_pocket_submit <session> <text> [request-id]: one unfenced
# submit (a follow-up while a run is going). The drop-in refuses a worker
# whose model left the owner's subagent list, a held spend, and a torn-down
# worker; each refusal is a blocker, never retried here.
fm_backend_pi_pocket_submit() {  # <session> <text> [request-id]
  local -a args=(send --session "$1" --text "$2")
  [ -z "${3:-}" ] || args+=(--request-id "$3")
  fm_backend_pi_pocket_bridge "${args[@]}" >/dev/null
}

# empty: Pi Pocket accepted the message; unconfirmed: it may have landed (no
# answer in time; a retry with the same request id is deduplicated);
# send-failed: refused or proven not delivered.
fm_backend_pi_pocket_send_text_submit() {  # <session> <text> <retries> <enter-sleep> <settle>
  local rc=0
  fm_backend_pi_pocket_submit "$1" "$2" || rc=$?
  case "$rc" in
    0) printf 'empty' ;;
    7) printf 'unconfirmed' ;;
    *) printf 'send-failed' ;;
  esac
}

# fm_backend_pi_pocket_native_interrupt <session>: abort the running turn and
# print the drop-in's claim: confirmed or not-running.
fm_backend_pi_pocket_native_interrupt() {  # <session>
  fm_backend_pi_pocket_bridge interrupt --session "$1" | fm_backend_pi_pocket_json_get cancel
}

fm_backend_pi_pocket_send_key() {  # <session> <key>
  local session=$1 key=$2
  case "$key" in
    Escape|escape|Esc|esc|C-c|ctrl+c|Ctrl-c|Ctrl-C)
      fm_backend_pi_pocket_native_interrupt "$session" >/dev/null
      ;;
    Enter|enter) return 0 ;;
    *)
      echo "error: unsupported Pi Pocket key '$key'" >&2
      return 1
      ;;
  esac
}

# Stop the session's run and archive it, and succeed only on Pi Pocket's
# read-back of archived with no run, when this Pi Pocket has
# linkedSessions.stop and archive; otherwise abort its run and retire it in
# the drop-in's registry, which then refuses every later Firstmate send to it.
# Archiving keeps the transcript visible in Pi Pocket. Idempotent: an
# archived, retired, or unknown session is already the end state.
fm_backend_pi_pocket_kill() {  # <session>
  local out
  out=$(fm_backend_pi_pocket_bridge kill --session "$1") || return 1
  [ "$(printf '%s' "$out" | fm_backend_pi_pocket_json_get ok)" = true ]
}

fm_backend_pi_pocket_validate_harness() {  # <harness>
  case "$1" in
    pi) return 0 ;;
    *) echo "error: backend=pi-pocket runs only Pi Pocket's own agent (harness pi), not '$1'" >&2; return 1 ;;
  esac
}

# There is no pane: bin/fm-spawn.sh's launch-time typing helpers land here.
fm_backend_pi_pocket_send_literal() {
  echo "error: backend=pi-pocket has no pane to type into" >&2
  return 1
}
