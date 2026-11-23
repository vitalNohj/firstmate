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
  offered=$(printf '%s\n' "$reason" | node "$BIN/fm-branch-dispatch.mjs" offer) || return 1
  eligible=$(printf '%s\n' "$offered" | awk -F= '$1 == "rows" { print $2 }')
  [ "$eligible" = "$expected" ] && grep -qx 'eligible=1' <<< "$offered" && grep -qx 'corrupted=0' <<< "$offered" || return 1
  printf '%s\nreason=%s\n' "$offered" "$reason"
}

case "$op" in
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
    printf '\nRunner commands: use fm_runner with action drain instead of running fm-wake-drain.sh. Record each outcome with fm_branch_report before you call fm_runner with action ack and the exact receipt. Do not call a shell or launch a worker from the supervision session.\n'
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
    trap 'rm -f -- "$mirror"' EXIT
    printf '%s' "$2" > "$mirror"
    printf '%s\n' "$reason" | node "$BIN/fm-branch-dispatch.mjs" wake-prompt --report fm_branch_report --mirror-file "$mirror"
    ;;
  branch-drain|branch-ack)
    [ "$#" -eq 1 ] && read_grant "$1" || exit 2
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
    outcomes processed-init >/dev/null
    newest=$(outcomes list --recent 1 | jq -r '.seq')
    if [ -n "$newest" ]; then outcomes mark-read --through "$newest" >&2; fi
    outcomes unprocessed
    ;;
  branch-list|branch-processed)
    [ "$#" -eq 1 ] && [[ "$1" =~ ^[1-9][0-9]{0,14}$ ]] || exit 2
    if [ "$op" = branch-list ]; then outcomes list --recent "$1"; else outcomes mark-processed --through "$1"; fi
    ;;
  *) exit 2 ;;
esac
