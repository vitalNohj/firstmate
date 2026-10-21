#!/usr/bin/env bash
# tests/fm-pi-pocket-identity.test.sh - Pi Pocket conversation identity:
# harness detection (bin/fm-harness.sh) and the conversation-bound session lock
# (bin/fm-session-lock-lib.sh, bin/fm-lock.sh).
#
# A Pi Pocket server runs every conversation's bash calls as its own children
# and its process name identifies nothing. The fixture reproduces that shape
# with a real process: a bash renamed MainThread (the name Node reports) that
# runs each requested command as a direct child, stamping the marker pair the
# Firstmate Pi Pocket extension sets. Every call of one fixture server shares
# its pid, exactly like the conversations of one real server.
#
# The fixture server is orphaned before it serves anything, so a walk that
# climbs past it ends inside the fixture and can never reach the harness
# session that is running this suite.
# shellcheck disable=SC2016 # single quotes are deliberate: the fixture child expands them
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS \
  GEMINI_CLI ATLASSIAN_AGENT_TYPE ROVODEV_CLI FM_OMP_HARNESS CLAUDE_CODE_SESSION_ID CLAUDE_PID \
  FM_PI_POCKET_CONVERSATION FM_PI_POCKET_SERVER_PID FM_SUPERVISION_ACTOR FM_SUPERVISION_PRIMARY_HARNESS

TMP_ROOT=$(fm_test_tmproot fm-pi-pocket-identity)
HARNESS="$ROOT/bin/fm-harness.sh"
LOCK="$ROOT/bin/fm-lock.sh"

FIXBIN="$TMP_ROOT/bin"
mkdir -p "$FIXBIN"
ln -s "$(command -v bash)" "$FIXBIN/MainThread"
ln -s "$(command -v bash)" "$FIXBIN/pi"
ln -s "$(command -v bash)" "$FIXBIN/codex"

# The fixture server. It waits to be orphaned, publishes its pid, then serves
# numbered request files in order until told to stop. A request sets conv (the
# conversation id, empty for no marker), server (the marker's server pid, or
# `self`), and cmd. The marker reaches the command exactly as the extension
# sets it: on the bash call only, never on the server itself.
cat > "$TMP_ROOT/server.sh" <<'SH'
#!/usr/bin/env bash
i=0
while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" = "$FM_FIXTURE_LAUNCHER" ]; do
  sleep 0.05
  i=$((i + 1))
done
printf '%s\n' "$$" > "$FIX/pid.tmp" && mv "$FIX/pid.tmp" "$FIX/pid"
n=1
while [ ! -e "$FIX/stop" ]; do
  req="$FIX/req-$n"
  if [ -f "$req" ]; then
    conv= server=self cmd=
    # shellcheck disable=SC1090
    . "$req"
    [ "$server" != self ] || server=$$
    if [ -n "$conv" ]; then
      FM_PI_POCKET_CONVERSATION=$conv FM_PI_POCKET_SERVER_PID=$server bash -c "$cmd" > "$FIX/out-$n" 2>&1
    else
      bash -c "$cmd" > "$FIX/out-$n" 2>&1
    fi
    printf '%s\n' "$?" > "$FIX/rc-$n.tmp" && mv "$FIX/rc-$n.tmp" "$FIX/rc-$n"
    n=$((n + 1))
  fi
  sleep 0.02
done
exit 0
SH
chmod +x "$TMP_ROOT/server.sh"

SERVER_FIXES=()
stop_servers() {
  local fix pid
  for fix in ${SERVER_FIXES[@]+"${SERVER_FIXES[@]}"}; do
    : > "$fix/stop"
    pid=$(cat "$fix/pid" 2>/dev/null || true)
    [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  done
}
trap 'stop_servers; fm_test_cleanup' EXIT

# Start a fixture server in fixture dir $1 and wait for its pid.
start_server() {  # <fix-dir>
  local fix=$1 i=0
  mkdir -p "$fix"
  SERVER_FIXES+=("$fix")
  env FIX="$fix" bash -c 'FM_FIXTURE_LAUNCHER=$$ "$0" "$1" &' "$FIXBIN/MainThread" "$TMP_ROOT/server.sh"
  while [ "$i" -lt 400 ] && [ ! -s "$fix/pid" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$fix/pid" ] || fail "fixture server in $fix never started"
}

server_pid() {  # <fix-dir>
  tr -d '[:space:]' < "$1/pid"
}

# Stop the server in fixture dir $1 and wait until its pid is gone.
stop_server() {  # <fix-dir>
  local fix=$1 pid i=0
  pid=$(server_pid "$fix")
  : > "$fix/stop"
  while [ "$i" -lt 400 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.05
    i=$((i + 1))
  done
  ! kill -0 "$pid" 2>/dev/null || fail "fixture server $pid never stopped"
}

# Run cmd $4 as a bash call of the server in fixture dir $1, with conversation
# $2 (empty: no marker) and marker server pid $3 (`self`: the server's own).
# Sets CALL_OUT and CALL_RC.
CALL_OUT=
CALL_RC=
call() {  # <fix-dir> <conv> <server> <cmd>
  local fix=$1 n i=0
  n=$(( $(find "$fix" -maxdepth 1 -name 'req-*' | wc -l) + 1 ))
  printf 'conv=%q\nserver=%q\ncmd=%q\n' "$2" "$3" "$4" > "$fix/req.tmp"
  mv "$fix/req.tmp" "$fix/req-$n"
  while [ "$i" -lt 600 ] && [ ! -s "$fix/rc-$n" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$fix/rc-$n" ] || fail "fixture server never answered request $n: $4"
  CALL_RC=$(tr -d '[:space:]' < "$fix/rc-$n")
  CALL_OUT=$(cat "$fix/out-$n")
}

detect_cmd() {
  printf '%q' "$HARNESS"
}

lock_cmd() {  # <home> [status]
  printf 'FM_HOME=%q %q %s' "$1" "$LOCK" "${2:-}"
}

# --- detection ---------------------------------------------------------------

test_detection_trusts_only_a_live_ancestor_server() {
  local fix pid dead other
  fix="$TMP_ROOT/detect"
  start_server "$fix"
  pid=$(server_pid "$fix")

  call "$fix" '' self "$(detect_cmd)"
  [ "$CALL_OUT" = unknown ] \
    || fail "absent marker: the fixture must detect nothing of its own, got '$CALL_OUT'"

  call "$fix" 42 self "$(detect_cmd)"
  [ "$CALL_OUT" = pi-pocket ] \
    || fail "valid marker under its live server $pid must detect pi-pocket, got '$CALL_OUT'"

  sleep 0 &
  dead=$!
  wait "$dead"
  call "$fix" 42 "$dead" "$(detect_cmd)"
  [ "$CALL_OUT" = unknown ] \
    || fail "stale marker naming dead pid $dead must be ignored, got '$CALL_OUT'"

  sleep 30 &
  other=$!
  call "$fix" 42 "$other" "$(detect_cmd)"
  kill "$other" 2>/dev/null
  wait "$other" 2>/dev/null
  [ "$CALL_OUT" = unknown ] \
    || fail "marker naming live non-ancestor pid $other must be ignored, got '$CALL_OUT'"

  call "$fix" 42 1 "$(detect_cmd)"
  [ "$CALL_OUT" = unknown ] \
    || fail "marker naming pid 1, every process's ancestor, must be ignored, got '$CALL_OUT'"

  call "$fix" 'conv 42' self "$(detect_cmd)"
  [ "$CALL_OUT" = unknown ] \
    || fail "a conversation id outside the token charset must be ignored, got '$CALL_OUT'"

  # A worker hand-started from a Pi Pocket bash call inherits the pair, but its
  # own harness process now sits between it and the server.
  call "$fix" 42 self "$(printf '%q' "$FIXBIN/pi") -c 'r=\$($(detect_cmd)); printf %s \"\$r\"'"
  [ "$CALL_OUT" = pi ] \
    || fail "a pi worker below a Pi Pocket bash call must detect as pi, got '$CALL_OUT'"
  pass "detection: pi-pocket only for a live ancestor server; stale, non-ancestor, pid 1, malformed, and nested markers are ignored"
}

# --- session lock ------------------------------------------------------------

test_lock_is_bound_to_one_conversation() {
  local fix home pid
  fix="$TMP_ROOT/lock-server-1"
  home="$TMP_ROOT/lock-home"
  mkdir -p "$home/state"
  start_server "$fix"
  pid=$(server_pid "$fix")

  call "$fix" conv-a self "$(lock_cmd "$home")"
  expect_code 0 "$CALL_RC" "conversation A must acquire a free home: $CALL_OUT"
  [ "$(cat "$home/state/.lock")" = "$pid" ] \
    || fail "the lock must anchor on the server pid $pid, got '$(cat "$home/state/.lock")'"
  [ "$(cat "$home/state/.lock-session")" = pi-pocket:conv-a ] \
    || fail "the sidecar must name conversation A, got '$(cat "$home/state/.lock-session")'"

  call "$fix" conv-b self "$(lock_cmd "$home")"
  expect_code 1 "$CALL_RC" "conversation B of the same server must be refused"
  assert_contains "$CALL_OUT" "another live firstmate session holds the lock (pid $pid, session pi-pocket:conv-a)" \
    "the refusal must name the holding conversation"
  [ "$(cat "$home/state/.lock-session")" = pi-pocket:conv-a ] \
    || fail "a refused sibling must leave the sidecar naming A"

  call "$fix" conv-a self "$(lock_cmd "$home")"
  expect_code 0 "$CALL_RC" "conversation A must re-acquire its own lock: $CALL_OUT"
  assert_contains "$CALL_OUT" "lock acquired: harness pid $pid" "re-acquire must confirm the server pid"

  call "$fix" conv-a self "$(lock_cmd "$home" status)"
  assert_contains "$CALL_OUT" "lock: held by live harness pid $pid" \
    "status must report a live Pi Pocket server as the holder"

  # A herdr-style harness session cannot take the home while the conversation's
  # server lives, even though the server has no harness shape.
  call "$fix" '' self "$(printf '%q' "$FIXBIN/codex") -c 'r=\$($(lock_cmd "$home") 2>&1); rc=\$?; printf %s \"\$r\"; exit \$rc'"
  expect_code 1 "$CALL_RC" "a harness session must not take a home a live Pi Pocket conversation holds"
  assert_contains "$CALL_OUT" "another live firstmate session holds the lock (pid $pid" \
    "the harness session's refusal must name the Pi Pocket server"
  pass "session lock: one conversation holds the home; a sibling conversation and another harness are refused; the same conversation re-acquires"
}

test_lock_survives_a_server_restart() {
  local first second home old new
  first="$TMP_ROOT/restart-server-1"
  second="$TMP_ROOT/restart-server-2"
  home="$TMP_ROOT/restart-home"
  mkdir -p "$home/state"
  start_server "$first"
  old=$(server_pid "$first")
  call "$first" conv-a self "$(lock_cmd "$home")"
  expect_code 0 "$CALL_RC" "conversation A must acquire before the restart: $CALL_OUT"
  stop_server "$first"

  start_server "$second"
  new=$(server_pid "$second")
  # A marker still naming the dead server is ignored, so nothing proves an
  # identity and the call stays read-only.
  call "$second" conv-a "$old" "$(lock_cmd "$home")"
  expect_code 1 "$CALL_RC" "a marker naming the dead server must not acquire"
  [ "$(cat "$home/state/.lock")" = "$old" ] || fail "a refused stale marker must not rewrite the lock"

  call "$second" conv-a self "$(lock_cmd "$home")"
  expect_code 0 "$CALL_RC" "conversation A must re-acquire after the server restarts: $CALL_OUT"
  [ "$(cat "$home/state/.lock")" = "$new" ] \
    || fail "the reclaimed lock must anchor on the new server pid $new, got '$(cat "$home/state/.lock")'"
  [ "$(cat "$home/state/.lock-session")" = pi-pocket:conv-a ] \
    || fail "the reclaimed sidecar must name conversation A"

  call "$second" conv-b self "$(lock_cmd "$home")"
  expect_code 1 "$CALL_RC" "after the restart a sibling conversation must still be refused"
  pass "session lock: a restarted server's conversation reclaims the home; a stale marker and a sibling do not"
}

test_detection_trusts_only_a_live_ancestor_server
test_lock_is_bound_to_one_conversation
test_lock_survives_a_server_restart
