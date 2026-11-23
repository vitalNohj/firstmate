#!/usr/bin/env bash
# Internal finite operations from runner-owner.sh, under the exact claim mutex.
# poll <fresh-uuid> <last-scan-name-or-empty>, verify -> ready <cursor-or-dash> <receipt-or-dash> <partial>
# drain [receipt], ack <receipt>, inbox-{read,reply,ack} <receipt> <note> [text], read <path>
# Active window and completed receipts are private to the current lock generation.
set -euo pipefail
export LC_ALL=C FM_STATUS_PRESENTATION_LOCK_TIMEOUT=1
# shellcheck source=bin/fm-session-lock-lib.sh
. "$FM_HOME/bin/fm-session-lock-lib.sh"
STATE="$FM_HOME/state"
fm_pocket_runner_command_owned "$FM_HOME" "$STATE" || exit 2
# shellcheck source=bin/fm-wake-lib.sh
. "$FM_HOME/bin/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$FM_HOME/bin/fm-classify-lib.sh"

fail() { printf '%s\n' "$*" >&2; exit 1; }
exists() { [ -e "$1" ] || [ -L "$1" ]; }
file() { [ -f "$1" ] && [ ! -L "$1" ] && [ -r "$1" ]; }
dir() { [ -d "$1" ] && [ ! -L "$1" ]; }
valid_name() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ && "$1" != *..* ]]; }
regular_or_absent() { ! exists "$1" || file "$1"; }
private_dir() { if ! exists "$1"; then mkdir -- "$1"; fi; dir "$1"; }

lock="$STATE/.lock"
window="$lock/runner-window"
batches="$lock/runner-batches"
actor=${FM_SUPERVISION_ACTOR:-main}
if [ "$actor" = branch ]; then batches="$lock/runner-branch-batches"; fi
marker="$STATE/.watcher-down"
stage="$lock/runner-stage"
queue_held=false
presentation_held=false
presentation_lock="$STATE/.status-presentation-lock"
cleanup() {
  if [ "$queue_held" = true ]; then fm_lock_release "$FM_WAKE_QUEUE_LOCK"; fi
  if [ "$presentation_held" = true ]; then fm_lock_release "$presentation_lock"; fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

operation=${1:-}
shift
if [ "$operation" = read ]; then
  [ "$#" -eq 1 ] || exit 2
  name=${1#state/}
  # Read only this primary's task records. Other files may contain secrets,
  # unrelated projects, or internal receipts that are not tool inputs.
  if [[ "$1" != state/"$name" || "$name" != *.status ]] || ! valid_name "$name"; then
    fail 'runner read refused: use state/<task>.status'
  fi
  file "$STATE/$name" || fail 'runner read refused: record unavailable'
  tail -c 16384 "$STATE/$name"
  exit
fi

for flag in .afk .afk-contract .afk-return-catchup .watch.lock .branch-eligible-rows .supervision-handoff-pending; do
  if [ "$flag" = .branch-eligible-rows ] && [ "$actor" = branch ]; then continue; fi
  if [ "$flag" = .branch-eligible-rows ] && { [ "$operation" = poll ] || [ "$operation" = verify ]; } \
    && file "$lock/runner-branch-grant" \
    && fm_wake_branch_grant_live "$STATE/.branch-eligible-rows" "$STATE/.branch-eligible-owner"; then continue; fi
  if exists "$STATE/$flag"; then
    if [ "$operation" = poll ] || [ "$operation" = verify ]; then printf 'paused %s\n' "$flag"; exit; fi
    fail "runner operation refused: automatic handling is paused ($flag)"
  fi
done
if ! regular_or_absent "$FM_WAKE_QUEUE" || ! regular_or_absent "$marker" || ! regular_or_absent "$window" \
  || { exists "$batches" && ! dir "$batches"; }; then
  fail 'runner operation refused: unsafe queue or receipt path'
fi

get_window() {
  token='' cutoff=''
  if file "$window"; then
    IFS=$'\t' read -r token cutoff < "$window" || return 1
    fm_pocket_runner_uuid "$token" && [[ "$cutoff" =~ ^(0|[1-9][0-9]{0,14})$ ]] || return 1
  fi
}

observe() {
  local path=$1 key=${1##*/} seen sig endpoint ident captured decision rc tag payload tmp start size
  file "$path" || return 1
  seen=$(fm_wake_signal_seen_path "$STATE" "$path")
  regular_or_absent "$seen" || return 1
  sig=$(fm_wake_signal_sig "$path") || return 1
  fm_wake_signal_seen_current "$STATE" "$path" && return 0
  case "$key" in
    *.status)
      start=$(fm_wake_signal_seen_size "$STATE" "$path") || return 1
      size=$(_fm_status_file_size "$path") || return 1
      size=${size//[[:space:]]/}
      [[ "$size" =~ ^[0-9]{1,14}$ && "$start" =~ ^[0-9]{1,14}$ ]] || return 1
      [ "$start" -lt "$size" ] || start=0
      # An unusually large unread span needs manual inspection. Do not let it
      # keep the bounded command from reaching other tasks in this page.
      [ "$((size - start))" -le 65536 ] || return 1
      rc=0
      status_span_first_actionable_record "$path" "$start" captured decision || rc=$?
      [ "$rc" -le 1 ] && [ -n "${captured:-}" ] || return 1
      IFS=$'\t' read -r endpoint ident _ <<< "$captured"
      # The classifier captures its own endpoint. If it did not observe the
      # same file state, leave it for the next page pass rather than leap ahead.
      [ "$(fm_wake_signal_sig "$path")" = "$sig" ] || return 1
      if [ "$rc" -eq 1 ] && [ "$decision" -eq 0 ]; then
        fm_wake_status_seen_commit "$STATE" "$path" "$endpoint" "$ident"
        return
      fi
      ;;
  esac
  tag=" [runner-observation=$sig]"
  # Signal rows retain their native kind/key and decision-owned payload shape.
  payload="signal: $key$tag"
  if [ "${decision:-0}" -eq 1 ]; then payload="needs-decision: $key$tag"; fi
  if ! fm_wake_queued_carries_locked signal "$key" "$tag"; then
    fm_wake_append_locked signal "$key" "$payload" || return 1
  fi
  case "$key" in
    *.status) fm_wake_status_seen_commit "$STATE" "$path" "$endpoint" "$ident" ;;
    *) tmp=$(mktemp "$lock/seen.XXXXXX") && printf '%s' "$sig" > "$tmp" && mv -f -- "$tmp" "$seen" ;;
  esac
}

if [ "$operation" = verify ]; then
  [ "$#" -eq 0 ] || exit 2
  get_window || fail 'runner verification: invalid window'
  if [ -n "$token" ] && { file "$batches/$token/acked" || { ! exists "$lock/runner-branch-grant" && file "$lock/runner-branch-batches/$token/acked"; }; }; then token=; fi
  printf 'ready - %s false\n' "${token:--}"
  exit
fi

if [ "$operation" = poll ]; then
  [ "$#" -eq 2 ] && fm_pocket_runner_uuid "$1" && { [ -z "$2" ] || valid_name "$2"; } || exit 2
  # Do not hold the queue lock during Pocket I/O. A dropped exec leaves only
  # native queue rows and markers, which the next finite pass can observe.
  fm_lock_acquire_wait_bounded "$FM_WAKE_QUEUE_LOCK" 1 || fail 'runner observation: queue lock busy'
  queue_held=true
  page=- count=0 incomplete=false
  for path in "$STATE"/*; do
    key=${path##*/}
    case "$key" in *.status|*.turn-ended) ;; *) continue ;; esac
    [ "$key" \> "$2" ] || continue
    if ! valid_name "$key"; then incomplete=true; continue; fi
    if [ "$count" -eq 16 ]; then page=$last; break; fi
    count=$((count + 1)) last=$key
    observe "$path" || incomplete=true
  done
  get_window || fail 'runner observation: invalid window'
  if [ -z "$token" ] || { { file "$batches/$token/acked" || file "$lock/runner-branch-batches/$token/acked"; } && ! exists "$lock/runner-branch-grant"; }; then
    token='' cutoff=''
    if [ -s "$FM_WAKE_QUEUE" ]; then
      # Take the oldest 16 valid rows, not the tail or a number of bytes.
      # A malformed-only queue selects 0 so the existing drain can repair it.
      cutoff=$(awk -F '\t' 'NF >= 5 && $2 ~ /^[0-9]+$/ { last=$2; if (++n == 16) exit } END { print last == "" ? "0" : last }' "$FM_WAKE_QUEUE")
    elif fm_recovery_marker_read "$marker"; then
      case "$FM_RECOVERY_MARKER_TOKEN" in pending:*|announced:*) cutoff=0 ;; esac
    fi
    if [ -n "$cutoff" ]; then
      [[ "$cutoff" =~ ^(0|[1-9][0-9]{0,14})$ ]] || fail 'runner observation: invalid queue sequence'
      token=$1
      tmp=$(mktemp "$lock/window.XXXXXX")
      printf '%s\t%s\n' "$token" "$cutoff" > "$tmp"
      mv -f -- "$tmp" "$window"
    fi
  fi
  printf 'ready %s %s %s\n' "$page" "${token:--}" "$incomplete"
  exit
fi

get_window || fail 'runner operation refused: invalid window'
receipt=${1:-$token}
fm_pocket_runner_uuid "$receipt" || fail 'runner operation refused: no matching receipt'
if [ "$actor" != branch ] && file "$lock/runner-branch-batches/$receipt/acked"; then
  fail 'runner operation refused: the supervision session already acknowledged this batch'
fi
batch="$batches/$receipt"
reader="$FM_HOME/bin/fm-wake-drain.sh"

case "$operation" in
  drain)
    [ "$#" -le 1 ] && [ "$token" = "$receipt" ] || fail 'runner drain refused: batch is not current'
    if ! private_dir "$batches" || { exists "$batch" && ! dir "$batch"; }; then
      fail 'runner drain refused: unsafe receipt path'
    fi
    if ! dir "$batch"; then
      # The shared drain can retire every row in a cutoff-0 batch. Give that
      # presentation a normal recovery generation so it can still be acked.
      if [ "$cutoff" = 0 ]; then
        fm_lock_acquire_wait_bounded "$FM_WAKE_QUEUE_LOCK" 1 || fail 'runner drain refused: queue lock busy'
        queue_held=true
        if ! fm_recovery_marker_read "$marker" && exists "$marker"; then
          fail 'runner drain refused: invalid recovery state'
        fi
        case "$FM_RECOVERY_MARKER_TOKEN" in
          ''|acked:*)
            fm_recovery_transition "$marker" publish downtime '' 1 \
              || fail 'runner drain refused: could not open a recovery generation'
            ;;
        esac
        fm_lock_release "$FM_WAKE_QUEUE_LOCK"
        queue_held=false
      fi
      if exists "$stage"; then
        # Preserve an interrupted or oversized rendering; none of it authorizes ack.
        dir "$stage" || fail 'runner drain refused: invalid staging directory'
        saved=$(mktemp -d "$lock/runner-incomplete.XXXXXX")
        mv -- "$stage" "$saved/presentation"
      fi
      mkdir -- "$stage"
      if ! bash "$reader" --runner-through "$cutoff" 2> "$stage/diagnostic" | head -c 32769 > "$stage/body"; then
        fail 'runner drain refused: presentation incomplete; queued work was not acknowledged'
      fi
      [ "$(( $(wc -c < "$stage/body") + $(wc -c < "$stage/diagnostic") ))" -le 32768 ] \
        || fail 'runner drain refused: presentation exceeds 32 KiB; queued work was not acknowledged'
      ack=$(awk '/^WAKE_ACK_REQUIRED: / {print $(NF-2), $NF}' "$stage/diagnostic")
      [[ "$ack" =~ ^${cutoff}\ [A-Za-z0-9._-]+$ ]] || fail 'runner drain refused: exact recovery receipt unavailable'
      printf '%s\n' "$ack" > "$stage/ack"
      mv -- "$stage" "$batch"
    fi
    if ! file "$batch/body" || ! file "$batch/ack" || exists "$batch/acked"; then
      fail 'runner drain refused: no open presentation'
    fi
    printf 'RUNNER_RECEIPT: %s\nWAKE_ACK_REQUIRED: after handling, call fm_runner with action ack and this receipt.\n' "$receipt"
    awk '!/^WAKE_ACK_REQUIRED: /' "$batch/diagnostic"
    cat -- "$batch/body"
    ;;
  ack)
    if [ "$#" -ne 1 ] || ! dir "$batch" || ! file "$batch/ack"; then
      fail 'runner ack refused: no complete presentation for that receipt'
    fi
    if file "$batch/acked"; then printf 'already acknowledged\n'; exit; fi
    [ "$token" = "$receipt" ] || fail 'runner ack refused: batch is not current'
    read -r through generation < "$batch/ack"
    [ "$through" = "$cutoff" ] && [[ "$generation" =~ ^[A-Za-z0-9._-]+$ ]] || fail 'runner ack refused: invalid receipt'
    replay=false
    if file "$batch/ack-started"; then replay=true; fi
    : > "$batch/ack-started"
    if ! bash "$reader" --ack-through "$through" --recovery-generation "$generation"; then
      # A successful ack may open a new recovery episode before its reply.
      # Confirm a replay against the queue lock, never by absence of a file.
      if [ "$replay" != true ] || ! fm_lock_acquire_wait_bounded "$FM_WAKE_QUEUE_LOCK" 1; then
        fail 'runner ack refused: recovery state changed or unavailable'
      fi
      queue_held=true
      if ! file "$FM_WAKE_QUEUE" || ! fm_recovery_marker_read "$marker" || [ "${FM_RECOVERY_MARKER_TOKEN##*:}" = "$generation" ] \
        || ! awk -F '\t' -v cutoff="$through" 'NF >= 5 && $2 ~ /^[0-9]+$/ && $2 + 0 <= cutoff + 0 { exit 1 }' "$FM_WAKE_QUEUE"; then
        fail 'runner ack refused: previous acknowledgement cannot be confirmed'
      fi
      fm_lock_release "$FM_WAKE_QUEUE_LOCK"
      queue_held=false
    fi
    if file "$batch/cursor" && fm_lock_acquire_wait_bounded "$presentation_lock" 1; then
      presentation_held=true
      status_commit_presentation_snapshot "$STATE" "$(cat -- "$batch/cursor")" || printf 'Status changed since presentation; its cursor did not advance.\n'
    fi
    : > "$batch/acked"
    printf 'acknowledged runner wake\n'
    ;;
  inbox-read|inbox-reply|inbox-ack)
    note=${2:-}
    if ! valid_name "$note" || ! dir "$batch" || ! file "$batch/notes" || ! grep -qxF "$note" "$batch/notes"; then
      fail 'runner inbox refused: note not in this presentation'
    fi
    inbox="$STATE/inbox"
    if ! dir "$inbox" || { exists "$inbox/handled" && ! dir "$inbox/handled"; } \
      || { exists "$inbox/.replies" && ! dir "$inbox/.replies"; }; then
      fail 'runner inbox refused: unsafe folder'
    fi
    pending="$inbox/$note.note" handled="$inbox/handled/$note.note"
    if ! regular_or_absent "$pending" || ! regular_or_absent "$handled" || ! regular_or_absent "$inbox/.replies/$note"; then
      fail 'runner inbox refused: unsafe note path'
    fi
    case "$operation" in
      inbox-read)
        [ "$#" -eq 2 ] || exit 2
        file "$pending" || pending=$handled
        file "$pending" && [ "$(wc -c < "$pending")" -le 32768 ] || fail 'runner inbox read refused: note missing or too large'
        awk 'body {print} /^--$/ {body=1}' "$pending"
        ;;
      inbox-reply)
        [ "$#" -eq 3 ] && [ "$3" != - ] && [ "${#3}" -le 8192 ] || exit 2
        bash "$FM_HOME/bin/fm-inbox.sh" reply "$note" "$3"
        ;;
      inbox-ack)
        [ "$#" -eq 2 ] || exit 2
        bash "$FM_HOME/bin/fm-inbox.sh" drain --ack "$note"
        ;;
    esac
    ;;
  *) exit 2 ;;
esac
