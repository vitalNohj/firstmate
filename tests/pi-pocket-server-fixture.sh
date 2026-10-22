#!/usr/bin/env bash
# tests/pi-pocket-server-fixture.sh - a real process shaped like a Pi Pocket
# server, for suites that need a trusted Pi Pocket conversation identity
# ("Pi Pocket conversation identity" in bin/fm-session-lock-lib.sh).
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
# session that is running the suite.
#
# Usage, after sourcing tests/lib.sh:
#   . "$(dirname "${BASH_SOURCE[0]}")/pi-pocket-server-fixture.sh"
#   pi_pocket_fixture_setup "$TMP_ROOT"
#   trap 'stop_servers; fm_test_cleanup' EXIT
# Setup sets FIXBIN, which also holds bash renamed pi and codex so a case can
# put a harness process between a call and its server.

PI_POCKET_FIXTURE_ROOT=
FIXBIN=
SERVER_FIXES=()

# Build the fixture binaries and server script under root $1.
pi_pocket_fixture_setup() {  # <root>
  PI_POCKET_FIXTURE_ROOT=$1
  FIXBIN="$PI_POCKET_FIXTURE_ROOT/bin"
  mkdir -p "$FIXBIN"
  ln -s "$(command -v bash)" "$FIXBIN/MainThread"
  ln -s "$(command -v bash)" "$FIXBIN/pi"
  ln -s "$(command -v bash)" "$FIXBIN/codex"
  # The fixture server. It waits to be orphaned, publishes its pid, then serves
  # numbered request files in order until told to stop. A request sets conv (the
  # conversation id, empty for no marker), server (the marker's server pid, or
  # `self`), and cmd. The marker reaches the command exactly as the extension
  # sets it: on the bash call only, never on the server itself.
  cat > "$PI_POCKET_FIXTURE_ROOT/server.sh" <<'SH'
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
  chmod +x "$PI_POCKET_FIXTURE_ROOT/server.sh"
}

# Stop every fixture server this suite started; the suite's EXIT trap calls it.
stop_servers() {
  local fix pid
  for fix in ${SERVER_FIXES[@]+"${SERVER_FIXES[@]}"}; do
    : > "$fix/stop"
    pid=$(cat "$fix/pid" 2>/dev/null || true)
    [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  done
}

# Start a fixture server in fixture dir $1 and wait for its pid.
start_server() {  # <fix-dir>
  local fix=$1 i=0
  mkdir -p "$fix"
  SERVER_FIXES+=("$fix")
  # shellcheck disable=SC2016 # the launcher child expands $$ itself
  env FIX="$fix" bash -c 'FM_FIXTURE_LAUNCHER=$$ "$0" "$1" &' "$FIXBIN/MainThread" "$PI_POCKET_FIXTURE_ROOT/server.sh"
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
# Sets CALL_OUT and CALL_RC, which the sourcing suite reads.
# shellcheck disable=SC2034
CALL_OUT=
# shellcheck disable=SC2034
CALL_RC=
# shellcheck disable=SC2034 # CALL_RC and CALL_OUT are read by the sourcing suite.
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
