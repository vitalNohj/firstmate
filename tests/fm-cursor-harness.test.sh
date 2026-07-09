#!/usr/bin/env bash
# Cursor primary-session detection and lock recognition (Phase 1).
# Cursor is recognized as a primary harness for lock + supervision protocol.
# It is not yet a verified crewmate launch adapter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-cursor-harness)
HARNESS="$ROOT/bin/fm-harness.sh"
LOCK="$ROOT/bin/fm-lock.sh"
RENDER="$ROOT/bin/fm-supervision-instructions.sh"

test_detect_cursor_env_marker() {
  local got
  got=$(CURSOR_AGENT=1 CLAUDECODE= GROK_AGENT= PI_CODING_AGENT= "$HARNESS")
  [ "$got" = cursor ] || fail "CURSOR_AGENT=1 should detect cursor, got '$got'"
  pass "fm-harness detects CURSOR_AGENT=1 as cursor"
}

test_detect_cursor_env_does_not_override_claude() {
  local got
  # Claude marker wins when both are somehow set (verified-harness precedence).
  got=$(CURSOR_AGENT=1 CLAUDECODE=1 "$HARNESS")
  [ "$got" = claude ] || fail "CLAUDECODE=1 should win over CURSOR_AGENT, got '$got'"
  pass "claude env marker still outranks cursor"
}

test_detect_cursor_via_args() {
  local fakebin got
  fakebin=$(fm_fakebin "$TMP_ROOT/detect-args")
  # macOS truncates comm=; the unambiguous Cursor signal is cursor-agent in argv.
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/Users/nohj/.loc'; exit 0 ;;
  *"args="*) printf '%s\n' '/Users/nohj/.local/bin/agent --use-system-ca /Users/nohj/.local/share/cursor-agent/versions/2026.07.08/index.js'; exit 0 ;;
  *"ppid="*) printf '1\n'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  got=$(CURSOR_AGENT= CLAUDECODE= GROK_AGENT= PI_CODING_AGENT= PATH="$fakebin:$PATH" "$HARNESS")
  [ "$got" = cursor ] || fail "args with cursor-agent should detect cursor, got '$got'"
  pass "fm-harness detects cursor-agent in process args despite truncated comm"
}

test_detect_survives_dash_comm() {
  local fakebin got
  fakebin=$(fm_fakebin "$TMP_ROOT/detect-dash")
  # Regression: macOS basename -zsh fails with "illegal option -- z".
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '-zsh'; exit 0 ;;
  *"args="*) printf '%s\n' '-zsh'; exit 0 ;;
  *"ppid="*) printf '1\n'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  got=$(CURSOR_AGENT= CLAUDECODE= GROK_AGENT= PI_CODING_AGENT= PATH="$fakebin:$PATH" "$HARNESS" 2>"$TMP_ROOT/detect-dash.err")
  [ "$got" = unknown ] || fail "dash-comm ancestry should be unknown, got '$got'"
  if grep -q 'illegal option' "$TMP_ROOT/detect-dash.err" 2>/dev/null; then
    fail "basename still choked on -zsh: $(cat "$TMP_ROOT/detect-dash.err")"
  fi
  pass "fm-harness does not call basename on dash-leading comm names"
}

test_fm_lock_recognizes_cursor_holder() {
  local home fakebin out
  home="$TMP_ROOT/lock-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-fake")
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/Users/nohj/.loc'; exit 0 ;;
  *"args="*) printf '%s\n' '/Users/nohj/.local/bin/agent --use-system-ca /Users/nohj/.local/share/cursor-agent/versions/x/index.js'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$LOCK" status)
  assert_contains "$out" "lock: held by live harness pid" "fm-lock did not recognize cursor-agent as a live holder"
  pass "fm-lock recognizes cursor-agent harness processes"
}

test_fm_lock_acquire_finds_cursor() {
  local home fakebin out
  home="$TMP_ROOT/lock-acquire"
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-acquire-fake")
  mkdir -p "$home/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' 'agent'; exit 0 ;;
  *"args="*) printf '%s\n' '/Users/nohj/.local/bin/agent --use-system-ca /x/cursor-agent/y/index.js'; exit 0 ;;
  *"ppid="*) printf '1\n'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$LOCK" 2>&1) || fail "fm-lock acquire failed: $out"
  assert_contains "$out" "lock acquired: harness pid" "cursor process did not acquire the lock"
  pass "fm-lock acquire succeeds when cursor-agent is in the process tree"
}

test_supervision_cursor_snippet() {
  local out
  out=$("$RENDER" --harness cursor)
  assert_contains "$out" "SUPERVISION OPERATING INSTRUCTIONS - primary harness: cursor" "cursor heading missing"
  assert_contains "$out" "Mode: Cursor foreground checkpoint." "cursor snippet missing"
  assert_contains "$out" "bin/fm-watch-checkpoint.sh" "cursor checkpoint helper missing"
  assert_contains "$out" "not yet a verified crewmate launch adapter" "cursor snippet missing crewmate caveat"
  assert_not_contains "$out" "Mode: Unknown harness fallback." "cursor fell through to unknown"
  out=$(FM_CURSOR_WATCH_CHECKPOINT=9 "$RENDER" --harness cursor --repair-line)
  assert_contains "$out" "bin/fm-watch-checkpoint.sh --seconds 9" "cursor repair line missing checkpoint override"
  pass "cursor supervision protocol renders and repairs like a named harness"
}

test_detect_cursor_env_marker
test_detect_cursor_env_does_not_override_claude
test_detect_cursor_via_args
test_detect_survives_dash_comm
test_fm_lock_recognizes_cursor_holder
test_fm_lock_acquire_finds_cursor
test_supervision_cursor_snippet
