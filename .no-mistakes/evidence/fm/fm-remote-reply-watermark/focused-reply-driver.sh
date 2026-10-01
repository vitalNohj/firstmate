#!/usr/bin/env bash
# End-to-end remote reply relay through fm-on and the process-event runner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-reply)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/parent"
REMOTE="$TMP_ROOT/remote"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
CLAIMS="$TMP_ROOT/claims"
mkdir -p "$PARENT/data" "$PARENT/state" "$REMOTE/state" "$REMOTE/data/reply" "$CLAIMS"
# shellcheck source=bin/fm-remote-job-lib.sh
. "$ROOT/bin/fm-remote-job-lib.sh"
# The recorded worker pid is the serving child, not its restart supervisor, so
# stopping that pid alone leaves the supervisor to respawn - the leak
# tests/fm-remote-job-orphan-reap.test.sh pins. Stop the whole worker tree.
cleanup() {
  local worker_pid=''
  FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
    "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then
    worker_pid=$(cat "$TMP_ROOT/remote-jobs/worker.pid")
    fm_remote_job_stop_worker_tree "$worker_pid" || true
  fi
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

cat > "$PARENT/data/secondmates.md" <<EOF
- ios - iOS delivery (host: remote-mac; root: $ROOT; home: $REMOTE; scope: iOS work; projects: alpha; added 2026-08-02)
EOF
printf '# Detailed remote answer\n\nThe build is green.\n' > "$REMOTE/data/reply/report.md"
printf '# Mentioned but never offered\n' > "$REMOTE/data/reply/prose-only.md"
: > "$REMOTE/state/parent-replies.status"
SOURCE_BEFORE="$TMP_ROOT/source-before"
cp "$REMOTE/state/parent-replies.status" "$SOURCE_BEFORE"

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    --) shift; break ;;
    *) exit 90 ;;
  esac
done
host=$1
entry=$2
shift 2
[ "$host" = remote-mac ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$FAKEBIN/fake-ssh"

remote_env() {
  FM_HOME="$PARENT" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_REMOTE_ENTRYPOINT="$ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  FM_REMOTE_REPLY_WAIT_SECONDS=10 \
  "$@"
}

wait_for() {
  local path=$1
  for _ in $(seq 1 100); do
    [ -e "$path" ] && return 0
    sleep 0.05
  done
  return 1
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

ADAPTER="$ROOT/bin/fm-procevent-remote-reply.sh"
SID=$(remote_env "$ADAPTER" source-id ios)
out=$(remote_env "$ADAPTER" arm ios)
assert_contains "$out" "armed: $SID offset=0" "remote reply source was not armed at the empty cursor"

. "$ROOT/bin/fm-pending-reply-lib.sh"
mkdir -p "$PARENT/state/remote-replies"
rm -f "$PARENT/state/remote-replies/ios.cursor"
rm -f -- "$PARENT/state/remote-replies/ios.caught-up"
remote_env "$ADAPTER" source ios > "$TMP_ROOT/preempted-source.out" 2>&1 &
PREEMPTED_SOURCE=$!
running_poll=''
for _ in $(seq 1 100); do
  for job in "$TMP_ROOT"/remote-jobs/jobs/job-*; do
    [ -d "$job" ] || continue
    if [ "$(fm_remote_job_read_state "$job" 2>/dev/null || true)" = running ]; then
      running_poll=$job
      break 2
    fi
  done
  sleep 0.05
done
[ -n "$running_poll" ] || fail "the reply poll did not begin running before preemption"
remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-file.sh get data/reply/report.md 262144 >/dev/null
set +e
wait "$PREEMPTED_SOURCE"
preempted_rc=$?
set -e
[ "$preempted_rc" -eq "$FM_REMOTE_JOB_PREEMPTED_EXIT" ] \
  || fail "the reply poll did not expose remote-job preemption: $preempted_rc"
assert_absent "$PARENT/state/remote-replies/ios.caught-up" \
  "a preempted reply poll published a caught-up watermark"
pass "a preempted reply poll cannot publish channel freshness"

# A quiet window is the one moment this channel can prove it is NOT behind, and
# the parent's pending-reply guard needs that proof: a remote report that exists
# but has not been mirrored yet must never be mistaken for a report the mate
# never wrote. The window opened with the log matching the committed cursor, so
# the published watermark is the window's start.
watermark_before=$(date +%s)
set +e
FM_REMOTE_REPLY_WAIT_SECONDS=1 remote_env "$ADAPTER" source ios >/dev/null 2>&1
quiet_rc=$?
set -e
[ "$quiet_rc" -eq 75 ] || fail "a quiet reply window exited with an unexpected status: $quiet_rc"
watermark_after=$(date +%s)
caught_up=$(FM_STATE_OVERRIDE="$PARENT/state" bash -c '
  . "$1/bin/fm-pending-reply-lib.sh"
  fm_pending_reply_remote_channel_epoch "$2/state" ios
' _ "$ROOT" "$PARENT")
[ -n "$caught_up" ] || fail "a quiet reply window published no caught-up watermark"
[ "$caught_up" -ge "$watermark_before" ] && [ "$caught_up" -le "$watermark_after" ] \
  || fail "the caught-up watermark ($caught_up) is outside the quiet window"
pass "a quiet reply window publishes the caught-up watermark the reply guard reads"

# Exercise repeated supervision ticks against the real queued remote reader.
# Only SSH is local: fm-on, the worker, delta reader and watermark writer run.
fm_write_meta "$PARENT/state/ios.meta" \
  'kind=secondmate' 'mode=secondmate' 'harness=claude' \
  'remote_host=remote-mac' "remote_root=$ROOT" 'remote_backend=herdr'
CADENCE_CORR=$(fm_pending_reply_create "$PARENT" "$PARENT/state" ios 'cadence probe')
fm_pending_reply_mark_delivered "$PARENT/state" "$CADENCE_CORR"
OBSERVE_LOG="$TMP_ROOT/observe.log"
: > "$OBSERVE_LOG"
cat > "$TMP_ROOT/observe" <<'SH'
#!/usr/bin/env bash
printf 'observe\n' >> "$FM_OBSERVE_LOG"
exec "$FM_OBSERVE_ROOT/bin/fm-on.sh" "$@"
SH
chmod +x "$TMP_ROOT/observe"
export FM_OBSERVE_LOG="$OBSERVE_LOG" FM_OBSERVE_ROOT="$ROOT"
export FM_PENDING_REPLY_REMOTE_OBSERVE_BIN="$TMP_ROOT/observe"
export FM_PENDING_REPLY_REMOTE_OBSERVE=1
cadence_epoch=$(date +%s)
# shellcheck disable=SC2016 # Positional parameters expand in the inner shell.
FM_PENDING_REPLY_NOW="$cadence_epoch" remote_env bash -c '. "$1/bin/fm-pending-reply-lib.sh"; fm_pending_reply_tick "$2/state"' _ "$ROOT" "$PARENT"
rm -f "$PARENT/state/remote-replies/ios.caught-up"
# Earlier legs leave finished jobs in this directory. Only a job created by
# the reader below counts, or a leftover running record would skip the wait.
prior_jobs=' '
for job in "$TMP_ROOT"/remote-jobs/jobs/job-*; do
  [ -d "$job" ] || continue
  prior_jobs="$prior_jobs$job "
done
remote_env "$ADAPTER" source ios > "$TMP_ROOT/cadence-source.out" 2>&1 &
CADENCE_SOURCE=$!
# Logical ticks finish in milliseconds. Wait until this reader is running, the
# same way the preemption leg does, or a slow start lets every tick land first.
running_reader=''
for _ in $(seq 1 100); do
  for job in "$TMP_ROOT"/remote-jobs/jobs/job-*; do
    [ -d "$job" ] || continue
    case "$prior_jobs" in
      *" $job "*) continue ;;
    esac
    if [ "$(fm_remote_job_read_state "$job" 2>/dev/null || true)" = running ]; then
      running_reader=$job
      break 2
    fi
  done
  sleep 0.05
done
[ -n "$running_reader" ] || fail "the quiet reply reader did not begin running before supervision ticks"
# Ten-second reader, eleven-second observe gap: advance only the supervision
# clock so slow ticks on constrained hosts cannot become eligible check-ins.
# The queued reader and its quiet-window timeout still use real time.
for cadence_offset in 1 2 10; do
  # shellcheck disable=SC2016 # Positional parameters expand in the inner shell.
  FM_PENDING_REPLY_NOW=$((cadence_epoch + cadence_offset)) remote_env bash -c '. "$1/bin/fm-pending-reply-lib.sh"; fm_pending_reply_tick "$2/state"' _ "$ROOT" "$PARENT"
done
set +e
wait "$CADENCE_SOURCE"
cadence_rc=$?
set -e
[ "$cadence_rc" -eq 75 ] || fail "supervision interrupted the quiet reader: $cadence_rc"
[ "$(wc -l < "$OBSERVE_LOG" | tr -d ' ')" = 1 ] \
  || fail "repeated supervision ticks occupied the remote lane"
assert_present "$PARENT/state/remote-replies/ios.caught-up" \
  "supervision left the caught-up watermark frozen"
if [ -n "${FM_REPLY_EVIDENCE_DIR:-}" ]; then
  mkdir -p "$FM_REPLY_EVIDENCE_DIR"
  {
    printf 'Isolated local SSH transport; real fm-on remote queue, worker and reply reader.\n'
    printf 'Interactive file read interrupted active reply reader: exit=%s\n' "$preempted_rc"
    printf 'Interrupted reader published no caught-up watermark (asserted before quiet read).\n'
    printf 'Quiet reader exit=%s; initial caught_up_epoch=%s\n' "$quiet_rc" "$caught_up"
    printf 'One initial remote observe plus opted-in ticks at logical offsets 1, 2, and 10 seconds; reader uses real time.\n'
    printf 'Actual observe calls=%s; reader exit=%s\n' "$(wc -l < "$OBSERVE_LOG" | tr -d ' ')" "$cadence_rc"
    printf 'Persisted watermark after repeated supervision ticks:\n'
    cat "$PARENT/state/remote-replies/ios.caught-up"
  } > "$FM_REPLY_EVIDENCE_DIR/remote-reply-transcript.txt"
fi
# Once the quiet reader has finished, the exact gap boundary must allow a
# check-in again; pinning the clock must not make this a never-observe test.
# shellcheck disable=SC2016 # Positional parameters expand in the inner shell.
FM_PENDING_REPLY_NOW=$((cadence_epoch + 11)) remote_env bash -c '. "$1/bin/fm-pending-reply-lib.sh"; fm_pending_reply_tick "$2/state"' _ "$ROOT" "$PARENT"
[ "$(wc -l < "$OBSERVE_LOG" | tr -d ' ')" = 2 ] \
  || fail "supervision did not resume remote observes at the quiet-window boundary"
printf 'done [corr=%s]: cadence probe complete\n' "$CADENCE_CORR" > "$TMP_ROOT/cadence-done.status"
fm_pending_reply_try_resolve "$PARENT/state" "$CADENCE_CORR" "$TMP_ROOT/cadence-done.status"
unset FM_PENDING_REPLY_REMOTE_OBSERVE FM_PENDING_REPLY_REMOTE_OBSERVE_BIN
unset FM_OBSERVE_LOG FM_OBSERVE_ROOT
pass "repeated supervision ticks leave the real remote reader time to publish freshness"


# Late answers close five still-open requests via the actual remote relay.
correlations=()
for n in 1 2 3 4 5; do
  corr=$(fm_pending_reply_create "$PARENT" "$PARENT/state" ios "already handled $n")
  fm_pending_reply_mark_delivered "$PARENT/state" "$corr"
  correlations+=("$corr")
  printf 'done [corr=%s]: already handled, no resend needed\n' "$corr" >> "$REMOTE/state/parent-replies.status"
done
remote_env "$ADAPTER" arm ios >/dev/null
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" > "$FM_REPLY_EVIDENCE_DIR/late-replies-relay.log" 2>&1 || fail 'late replies did not relay'
for corr in "${correlations[@]}"; do
  phase=$(fm_pending_reply_get "$PARENT/state/pending-replies/$corr" phase)
  [ "$phase" = resolved ] || fail "late answer left $corr in $phase"
  printf '%s phase=%s\n' "$corr" "$phase" >> "$FM_REPLY_EVIDENCE_DIR/late-replies-relay.log"
done
cp "$PARENT/state/ios.status" "$FM_REPLY_EVIDENCE_DIR/late-replies-status.txt"
pass 'five late remote answers settle their open records without asking the mate again'
