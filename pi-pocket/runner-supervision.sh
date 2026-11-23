#!/usr/bin/env bash
# Finite, typed branch operations. Only runner-owner.sh runs these, under the exact claim mutex.
set -euo pipefail
export LC_ALL=C
STATE="$FM_HOME/state"
BIN="$FM_HOME/bin"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$BIN/fm-session-lock-lib.sh"
fm_pocket_runner_command_owned "$FM_HOME" "$STATE" || exit 2
# shellcheck source=bin/fm-wake-lib.sh
. "$BIN/fm-wake-lib.sh"

file() { [ -f "$1" ] && [ ! -L "$1" ]; }
absent() { [ ! -e "$1" ] && [ ! -L "$1" ]; }
lock="$STATE/.lock"
grant="$lock/runner-branch-grant"
owner="$STATE/.branch-eligible-owner"
rows="$STATE/.branch-eligible-rows"
window="$lock/runner-window"
op=$1; shift
outcomes() { bash "$BIN/fm-branch-outcome.sh" "$@"; }
# Gate new work, not cleanup: changing the backend does not revoke old grants.
enabled() { file "$FM_HOME/config/backend" && [ "$(head -c 32 "$FM_HOME/config/backend")" = pi-pocket ]; }
posture_lib="$FM_HOME/pi-pocket/runner-posture-lib.sh"
if file "$posture_lib"; then
  # shellcheck source=pi-pocket/runner-posture-lib.sh
  . "$posture_lib"
else
  runner_posture() { printf 'foreign\n'; }
fi
read_window() {
  fm_pocket_runner_uuid "$1" && file "$window" && IFS=$'\t' read -r token cutoff < "$window" \
    && [ "$1" = "$token" ] && [[ "$cutoff" =~ ^[1-9][0-9]{0,14}$ ]] \
    && file "$FM_WAKE_QUEUE"
}
read_grant() {
  file "$grant" && read -r granted < "$grant" && [ "$granted" = "$1" ] \
    && fm_pocket_runner_uuid "$1" && fm_wake_branch_grant_live "$rows" "$owner"
}
# Use native dispatch and only a whole bounded window. Main keeps mixed windows.
offer() {
  read_window "$1" || return 1
  absent "$lock/runner-batches/$1" || return 1
  local expected reason offered eligible scan
  scan=$(awk -F '\t' -v limit="$cutoff" '$2 + 0 <= limit + 0 { if (NF < 5 || $2 !~ /^[1-9][0-9]*$/) exit 2; if (++n > 16) exit 2; print $0 }' "$FM_WAKE_QUEUE") || return 1
  [ -n "$scan" ] || return 1
  expected=$(printf '%s\n' "$scan" | awk -F '\t' '{print $2}' | paste -sd ' ' -)
  [ "${expected##* }" = "$cutoff" ] || return 1
  reason=$(printf '%s\n' "$scan" | awk -F '\t' 'NR == 1 { print $3 ": " $4 }')
  local -a flags=()
  case "$(runner_posture)" in
    attended|quiet) ;;
    away) flags=(--afk) ;;
    *) return 1 ;;
  esac
  # Classify with the receipt's cutoff. Later rows can veto an unsafe offer but cannot enter its grant or task scope.
  offered=$(printf '%s\n' "$reason" | node "$BIN/fm-branch-dispatch.mjs" offer --through "$cutoff" "${flags[@]+${flags[@]}}") || return 1
  eligible=$(printf '%s\n' "$offered" | awk -F= '$1 == "rows" { print $2 }')
  [ "$eligible" = "$expected" ] && grep -qx 'eligible=1' <<< "$offered" && grep -qx 'corrupted=0' <<< "$offered" || return 1
  printf '%s\nreason=%s\n' "$offered" "$reason"
}

case "$op" in
  branch-posture)
    [ "$#" -eq 0 ] || exit 2
    runner_posture
    ;;
  branch-posture-enter)
    [ "$#" -ge 1 ] && enabled && file "$posture_lib" || exit 2
    case "$1" in away|quiet) mode=$1 ;; *) exit 2 ;; esac
    shift
    case "$(runner_posture)" in
      attended|quiet) ;;
      away) [ "$mode" = away ] || { echo 'Finish the away return before entering quiet mode.' >&2; exit 1; } ;;
      *) echo 'An existing posture or catch-up record must be resolved first.' >&2; exit 1 ;;
    esac
    absent "$STATE/.afk-daemon-terminal" && absent "$STATE/.supervise-daemon.lock" || exit 1
    # Do not change the authority of a branch turn already using its grant.
    if ! absent "$grant" || ! absent "$rows" || ! absent "$owner"; then
      echo 'Wait for the current supervision turn before changing posture.' >&2
      exit 1
    fi
    staged=$(mktemp "$lock/runner-posture.XXXXXX")
    trap 'rm -f -- "$staged"' EXIT
    printf '%s\n' "$FM_POCKET_RUNNER_COMMAND" > "$staged"
    mv -f -- "$staged" "$lock/runner-posture"
    FM_AFK_MODE="$mode" bash "$BIN/fm-afk-contract.sh" enter "$@"
    epoch=$(bash "$BIN/fm-afk-contract.sh" field entered_epoch)
    [[ "$epoch" =~ ^[0-9]+$ ]] || exit 1
    printf '%s\n%s\n' "$mode" "$epoch" > "$staged"
    mv -f -- "$staged" "$STATE/.afk"
    ;;
  branch-posture-return)
    [ "$#" -eq 2 ] && fm_pocket_runner_uuid "$2" || exit 2
    case "$1:$(runner_posture)" in
      begin:quiet|begin:away|begin:catchup|check:catchup) ;;
      begin:attended|check:attended) exit 0 ;;
      *) exit 2 ;;
    esac
    if ! absent "$grant" || ! absent "$rows" || ! absent "$owner"; then
      echo 'The current supervision turn is not settled. Use fm_runner return-check after it finishes.' >&2
      exit 1
    fi
    FM_POCKET_RUNNER_RETURN="$2" bash "$BIN/fm-afk-return.sh" "$1"
    ;;
  branch-config)
    [ "$#" -eq 0 ] && enabled || exit 1
    for pin in supervision-branch-model supervision-branch-effort; do
      file "$FM_HOME/config/$pin" || continue
      printf '%s=%s\n' "$pin" "$(head -n 1 "$FM_HOME/config/$pin" | head -c 200)"
    done
    ;;
  branch-prompt)
    [ "$#" -eq 0 ] && enabled || exit 1
    bash "$BIN/fm-branch-prompt.sh"
    printf '\nRunner commands replace the shell commands above. Use fm_runner with action drain, record each outcome with fm_branch_report, and then call fm_runner with action ack and the exact receipt. Use fm_runner with action worker and operation send, control (interrupt or exit), or teardown for a task in the grant. The runner serializes these commands; do not run shell commands, launch or relaunch workers, approve decisions, or merge from this supervision session. Report work that needs an unavailable operation to main.\n'
    ;;
  branch-offer)
    [ "$#" -eq 1 ] && enabled || exit 1
    offer "$1"
    ;;
  branch-grant)
    [ "$#" -eq 2 ] && enabled || exit 1
    if read_grant "$1" && [ "$(paste -sd ' ' "$rows")" = "$2" ]; then exit; fi
    absent "$grant" || exit 1
    offered=$(offer "$1") || exit 1
    [ "$(awk -F= '$1 == "rows" { print $2 }' <<< "$offered")" = "$2" ] || exit 1
    read -r -a sequences <<< "$2"
    # Publish intent first. A failed publish can be released, but cannot authorize a branch drain.
    printf '%s\n' "$1" > "$grant"
    bash "$BIN/fm-wake-grant.sh" activate-runner
    bash "$BIN/fm-wake-grant.sh" publish "$FM_POCKET_RUNNER_COMMAND" "${sequences[@]}"
    ;;
  branch-release)
    [ "$#" -eq 1 ] && fm_pocket_runner_uuid "$1" || exit 2
    absent "$lock/runner-worker-command" || exit 1
    if absent "$grant"; then absent "$rows" && absent "$owner"; exit; fi
    file "$grant" && [ "$(head -c 128 "$grant")" = "$1" ] || exit 1
    bash "$BIN/fm-wake-grant.sh" deactivate-runner
    rm -- "$grant"
    absent "$rows" && absent "$owner"
    ;;
  branch-render)
    [ "$#" -eq 2 ] && read_grant "$1" && [ "${#2}" -le 20000 ] || exit 2
    read_window "$1" || exit 1
    reason=$(awk -F '\t' -v seq="$(head -n 1 "$rows")" '$2 == seq { print $3 ": " $4; exit }' "$FM_WAKE_QUEUE")
    [ -n "$reason" ] || exit 1
    mirror=$(mktemp "$lock/runner-mirror.XXXXXX")
    readback="$mirror-readback"
    trap 'rm -f -- "$mirror" "$readback"' EXIT
    printf '%s' "$2" > "$mirror"
    flags=()
    case "$(runner_posture)" in
      attended|quiet) ;;
      away)
        bash "$BIN/fm-afk-contract.sh" readback > "$readback"
        flags=(--away --readback-file "$readback")
        ;;
      *) exit 1 ;;
    esac
    printf '%s\n' "$reason" | node "$BIN/fm-branch-dispatch.mjs" wake-prompt --report fm_branch_report --mirror-file "$mirror" "${flags[@]+${flags[@]}}"
    ;;
  branch-worker-allowed)
    [ "$#" -eq 2 ] && read_grant "$1" && file "$FM_WAKE_QUEUE" || exit 2
    [[ "$2" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || exit 2
    # Only an exact wake for this task speaks for it. Unscoped wakes grant no lifecycle actions.
    awk -F '\t' -v task="$2" 'FNR == NR { granted[$1]=1; next }
      $2 in granted && (($3 == "signal" && ($4 == task ".status" || $4 == task ".turn-ended")) || ($3 == "stale" && $4 == task)) { ok=1 }
      END { exit !ok }' "$rows" "$FM_WAKE_QUEUE"
    ;;
  branch-drain|branch-ack)
    [ "$#" -eq 1 ] && read_grant "$1" && absent "$lock/runner-worker-command" || exit 2
    FM_SUPERVISION_ACTOR=branch bash "$FM_HOME/pi-pocket/runner-monitor.sh" "${op#branch-}" "$1"
    ;;
  branch-acked)
    [ "$#" -eq 1 ] && fm_pocket_runner_uuid "$1" && file "$lock/runner-branch-batches/$1/acked"
    ;;
  branch-record)
    [ "$#" -eq 3 ] && read_grant "$1" || exit 2
    # The extension validates the exact turn and task scope. This call runs only under the claim.
    case "$2" in routine|captain) ;; *) exit 2 ;; esac
    IFS=$'\t' read -r task summary < <(printf '%s\n' "$3")
    [[ "$task" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] && [ -n "$summary" ] || exit 2
    outcomes append --task "$task" --verdict "$2" --summary "$summary"
    ;;
  branch-outcomes)
    [ "$#" -eq 0 ] || exit 2
    case "$(runner_posture)" in attended|quiet) ;; *) exit 1 ;; esac
    outcomes processed-init >/dev/null
    newest=$(outcomes list --recent 1 | jq -r '.seq')
    if [ -n "$newest" ]; then outcomes mark-read --through "$newest" >&2; fi
    outcomes unprocessed
    ;;
  branch-list|branch-processed)
    [ "$#" -eq 1 ] && [[ "$1" =~ ^[1-9][0-9]{0,14}$ ]] || exit 2
    case "$(runner_posture)" in attended|quiet) ;; *) exit 1 ;; esac
    if [ "$op" = branch-list ]; then outcomes list --recent "$1"; else outcomes mark-processed --through "$1"; fi
    ;;
  *) exit 2 ;;
esac
