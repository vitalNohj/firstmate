#!/usr/bin/env bash
# tests/fm-pi-pocket-identity.test.sh - Pi Pocket conversation identity:
# harness detection (bin/fm-harness.sh), the conversation-bound session lock
# (bin/fm-session-lock-lib.sh, bin/fm-lock.sh), and a Pi Pocket primary's worker
# defaults (crew harness pi, herdr backend, the herdr adapter's refusal to start
# a server, and bootstrap's PI_POCKET diagnostics), over the real Pi
# Pocket-shaped server process tests/pi-pocket-server-fixture.sh builds. herdr
# is a fake on PATH: no real herdr server is read, started, or stopped.
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

# shellcheck source=tests/pi-pocket-server-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/pi-pocket-server-fixture.sh"
pi_pocket_fixture_setup "$TMP_ROOT"
trap 'stop_servers; fm_test_cleanup' EXIT

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

# --- worker defaults for a Pi Pocket primary ---------------------------------

# A fake herdr whose server reports running when $FAKE_HERDR_RUNNING exists, and
# that records any attempt to start a server instead of starting one.
make_fake_herdr() {  # <dir>
  mkdir -p "$1"
  cat > "$1/herdr" <<'SH'
#!/usr/bin/env bash
case "$1" in
  status) if [ -e "$FAKE_HERDR_RUNNING" ]; then echo '{"server":{"running":true}}'; else echo '{"server":{"running":false}}'; fi ;;
  server) echo started >> "$FAKE_HERDR_STARTS" ;;
esac
exit 0
SH
  chmod +x "$1/herdr"
}

test_pi_pocket_primary_workers_default_to_pi_in_herdr() {
  local fix home fake
  fix="$TMP_ROOT/workers"
  home="$TMP_ROOT/workers-home"
  fake="$TMP_ROOT/workers-fake"
  mkdir -p "$home/config" "$home/state"
  make_fake_herdr "$fake"
  start_server "$fix"
  # Runtime markers are cleared so only the Pi Pocket identity can select herdr.
  env_cmd() { printf 'env -u TMUX -u HERDR_ENV -u HERDR_PANE_ID -u CMUX_WORKSPACE_ID PATH=%q FAKE_HERDR_RUNNING=%q FAKE_HERDR_STARTS=%q FM_HOME=%q FM_CONFIG_OVERRIDE=%q %s' \
    "$fake:$PATH" "$fake/running" "$fake/starts" "$home" "$home/config" "$1"; }

  call "$fix" conv-a self "$(env_cmd "$(printf '%q crew' "$HARNESS")")"
  [ "$CALL_OUT" = pi ] || fail "a Pi Pocket primary's default crew harness must be pi, got '$CALL_OUT'"
  call "$fix" conv-a self "$(env_cmd "$(printf '%q secondmate' "$HARNESS")")"
  [ "$CALL_OUT" = pi ] || fail "a Pi Pocket primary's default secondmate harness must be pi, got '$CALL_OUT'"
  printf 'default\n' > "$home/config/crew-harness"
  call "$fix" conv-a self "$(env_cmd "$(printf '%q crew' "$HARNESS")")"
  [ "$CALL_OUT" = pi ] || fail "crew-harness 'default' must also resolve to pi, got '$CALL_OUT'"
  printf 'codex\n' > "$home/config/crew-harness"
  call "$fix" conv-a self "$(env_cmd "$(printf '%q crew' "$HARNESS")")"
  [ "$CALL_OUT" = codex ] || fail "an explicit crew harness must still win, got '$CALL_OUT'"
  rm -f "$home/config/crew-harness"

  backend_cmd() { env_cmd "$(printf 'bash -c %q' ". $(printf '%q' "$ROOT/bin/fm-backend.sh"); fm_backend_name")"; }
  call "$fix" conv-a self "$(backend_cmd)"
  [ "$CALL_OUT" = herdr ] || fail "a Pi Pocket primary's default backend must be herdr, got '$CALL_OUT'"
  printf 'tmux\n' > "$home/config/backend"
  call "$fix" conv-a self "$(backend_cmd)"
  [ "$CALL_OUT" = tmux ] || fail "config/backend must still win over the Pi Pocket default, got '$CALL_OUT'"
  rm -f "$home/config/backend"
  # Without the marker the ordinary resolution stands.
  call "$fix" '' self "$(backend_cmd)"
  [ "$CALL_OUT" = tmux ] || fail "without a Pi Pocket identity the default backend must stay tmux, got '$CALL_OUT'"

  ensure_cmd() { env_cmd "$(printf 'bash -c %q' ". $(printf '%q' "$ROOT/bin/fm-backend.sh"); fm_backend_source herdr; fm_backend_herdr_server_ensure default")"; }
  call "$fix" conv-a self "$(ensure_cmd)"
  expect_code 1 "$CALL_RC" "a stopped herdr must refuse a Pi Pocket primary's spawn"
  assert_contains "$CALL_OUT" "a Pi Pocket primary opens workers only in an already-running herdr server"
  [ ! -e "$fake/starts" ] || fail "a Pi Pocket primary must never start a herdr server"
  : > "$fake/running"
  call "$fix" conv-a self "$(ensure_cmd)"
  expect_code 0 "$CALL_RC" "a running herdr must accept a Pi Pocket primary's spawn: $CALL_OUT"
  rm -f "$fake/running"
  call "$fix" '' self "$(ensure_cmd)"
  [ -e "$fake/starts" ] || fail "without a Pi Pocket identity the adapter must keep starting a stopped herdr"
  pass "Pi Pocket primary: workers default to pi in herdr, explicit config wins, and a stopped herdr is refused, never started"
}

test_bootstrap_reports_a_pi_pocket_primary() {
  local fix home fake data
  fix="$TMP_ROOT/bootstrap"
  home="$TMP_ROOT/bootstrap-home"
  fake="$TMP_ROOT/bootstrap-fake"
  data="$TMP_ROOT/bootstrap-pocket"
  mkdir -p "$home/config" "$home/state"
  make_fake_herdr "$fake"
  start_server "$fix"
  # Runs bootstrap's own pi_pocket_primary_check, extracted from bin/fm-bootstrap.sh, with the
  # globals bootstrap gives it: the full bootstrap also sweeps tools, network, and the fleet.
  check_cmd() {
    printf 'env -u TMUX -u HERDR_ENV -u HERDR_PANE_ID -u CMUX_WORKSPACE_ID PATH=%q FAKE_HERDR_RUNNING=%q FAKE_HERDR_STARTS=%q PI_POCKET_DIR=%q FM_HOME=%q FM_CONFIG_OVERRIDE=%q SCRIPT_DIR=%q FM_ROOT=%q bash -c %q' \
      "$fake:$PATH" "$fake/running" "$fake/starts" "$data" "$home" "$home/config" "$ROOT/bin" "$ROOT" \
      ". $(printf '%q' "$ROOT/bin/fm-backend.sh"); BACKEND=\$(fm_backend_name); $(sed -n '/^pi_pocket_primary_check() {/,/^}/p' "$ROOT/bin/fm-bootstrap.sh"); pi_pocket_primary_check"
  }

  call "$fix" conv-a self "$(check_cmd)"
  assert_contains "$CALL_OUT" "BOOTSTRAP_INFO: Pi Pocket primary: workers launch on pi in the herdr backend"
  assert_contains "$CALL_OUT" "PI_POCKET: no Firstmate Pi Pocket plugin"
  assert_contains "$CALL_OUT" "PI_POCKET: herdr session 'default' is not running"
  mkdir -p "$data/extensions"
  printf 'stale\n' > "$data/extensions/firstmate.ts"
  : > "$fake/running"
  call "$fix" conv-a self "$(check_cmd)"
  assert_contains "$CALL_OUT" "differs from this checkout"
  case "$CALL_OUT" in *"is not running"*) fail "a running herdr must not be reported stopped: $CALL_OUT" ;; esac
  cp "$ROOT/pi-pocket/firstmate.ts" "$data/extensions/firstmate.ts"
  call "$fix" conv-a self "$(check_cmd)"
  assert_contains "$CALL_OUT" "differs from this checkout" "a drop-in without its browser module is not current"
  cp "$ROOT/pi-pocket/firstmate.js" "$data/extensions/firstmate.js"
  call "$fix" conv-a self "$(check_cmd)"
  case "$CALL_OUT" in *PI_POCKET:*) fail "a current plugin and a running herdr must raise nothing: $CALL_OUT" ;; esac
  call "$fix" '' self "$(check_cmd)"
  [ -z "$CALL_OUT" ] || fail "bootstrap must stay silent for a primary that is not Pi Pocket, got: $CALL_OUT"
  [ ! -e "$fake/starts" ] || fail "bootstrap must never start herdr"
  pass "bootstrap: a Pi Pocket primary's worker launch, plugin currency, and stopped herdr are reported; other primaries stay silent"
}

test_detection_trusts_only_a_live_ancestor_server
test_lock_is_bound_to_one_conversation
test_lock_survives_a_server_restart
test_pi_pocket_primary_workers_default_to_pi_in_herdr
test_bootstrap_reports_a_pi_pocket_primary
