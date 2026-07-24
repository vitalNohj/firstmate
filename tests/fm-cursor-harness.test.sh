#!/usr/bin/env bash
# Cursor harness: primary detection/lock plus crewmate spawn hooks and teardown.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-cursor-harness)
# shellcheck source=bin/fm-cursor-hook-lib.sh
. "$ROOT/bin/fm-cursor-hook-lib.sh"
HARNESS="$ROOT/bin/fm-harness.sh"
LOCK="$ROOT/bin/fm-lock.sh"
RENDER="$ROOT/bin/fm-supervision-instructions.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"

test_detect_cursor_env_marker() {
  local got
  got=$(OMPCODE='' CURSOR_AGENT=1 CLAUDECODE='' GROK_AGENT='' PI_CODING_AGENT='' "$HARNESS")
  [ "$got" = cursor ] || fail "CURSOR_AGENT=1 should detect cursor, got '$got'"
  pass "fm-harness detects CURSOR_AGENT=1 as cursor"
}

test_detect_cursor_env_does_not_override_claude() {
  local got
  # Claude marker wins when both are somehow set (verified-harness precedence).
  got=$(OMPCODE='' CURSOR_AGENT=1 CLAUDECODE=1 "$HARNESS")
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
  got=$(OMPCODE='' CURSOR_AGENT='' CLAUDECODE='' GROK_AGENT='' PI_CODING_AGENT='' PATH="$fakebin:$PATH" "$HARNESS")
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
  got=$(OMPCODE='' CURSOR_AGENT='' CLAUDECODE='' GROK_AGENT='' PI_CODING_AGENT='' PATH="$fakebin:$PATH" "$HARNESS" 2>"$TMP_ROOT/detect-dash.err")
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

test_fm_lock_skips_wrapper_argv_substring() {
  local home fakebin out holder
  home="$TMP_ROOT/lock-wrapper"
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-wrapper-fake")
  mkdir -p "$home/state"
  # Ancestry: leaf (this fm-lock process) is a shell wrapper whose argv merely
  # contains "codex" as a path substring; its parent (pid 9999) is the real
  # Cursor Agent harness. The wrapper must NOT be recorded as the lock holder.
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
pid=""; prev=""
for a in "$@"; do
  [ "$prev" = "-p" ] && pid=$a
  prev=$a
done
if [ "$pid" = 9999 ]; then
  case "$*" in
    *"comm="*) printf '%s\n' 'agent' ;;
    *"args="*) printf '%s\n' '/Users/nohj/.local/bin/agent --use-system-ca /x/cursor-agent/y/index.js' ;;
    *"ppid="*) printf '1\n' ;;
  esac
  exit 0
fi
case "$*" in
  *"comm="*) printf '%s\n' 'bash' ;;
  *"args="*) printf '%s\n' 'bash /opt/tools/codex-helper.sh --run' ;;
  *"ppid="*) printf '9999\n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$LOCK" 2>&1) || fail "fm-lock acquire failed: $out"
  holder=$(cat "$home/state/.lock")
  [ "$holder" = 9999 ] || fail "lock holder should be the real harness (9999), got '$holder' - an intermediate wrapper's argv substring was matched"
  pass "fm-lock ignores an intermediate wrapper whose argv only contains a harness substring"
}

# Observed macOS Cursor IDE agent-exec process label (2026-07): both
# ps -o comm= and ps -o args= return the full string with spaces/parentheses.
CURSOR_IDE_AGENT_COMM='Cursor Helper (Plugin): extension-host (agent-exec) fpsunity [4-60]'

test_detect_cursor_ide_agent_exec_ancestry() {
  local fakebin got
  fakebin=$(fm_fakebin "$TMP_ROOT/detect-ide-agent-exec")
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"comm="*) printf '%s\\n' '$CURSOR_IDE_AGENT_COMM'; exit 0 ;;
  *"args="*) printf '%s\\n' '$CURSOR_IDE_AGENT_COMM'; exit 0 ;;
  *"ppid="*) printf '1\\n'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  got=$(OMPCODE='' CURSOR_AGENT='' CLAUDECODE='' GROK_AGENT='' PI_CODING_AGENT='' PATH="$fakebin:$PATH" "$HARNESS")
  [ "$got" = cursor ] || fail "IDE agent-exec ancestry should detect cursor, got '$got'"
  pass "fm-harness detects Cursor IDE extension-host (agent-exec) ancestry"
}

test_fm_lock_acquire_finds_cursor_ide_agent_exec() {
  local home fakebin out holder
  home="$TMP_ROOT/lock-ide-acquire"
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-ide-acquire-fake")
  mkdir -p "$home/state"
  # Ancestry: zsh tool shell -> agent-exec host (62891) -> Cursor.app (87685).
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
pid=""; prev=""
for a in "\$@"; do
  [ "\$prev" = "-p" ] && pid=\$a
  prev=\$a
done
if [ "\$pid" = 62891 ]; then
  case "\$*" in
    *"comm="*) printf '%s\\n' '$CURSOR_IDE_AGENT_COMM' ;;
    *"args="*) printf '%s\\n' '$CURSOR_IDE_AGENT_COMM' ;;
    *"ppid="*) printf '87685\\n' ;;
  esac
  exit 0
fi
if [ "\$pid" = 87685 ]; then
  case "\$*" in
    *"comm="*) printf '%s\\n' 'Cursor' ;;
    *"args="*) printf '%s\\n' '/Applications/Cursor.app/Contents/MacOS/Cursor' ;;
    *"ppid="*) printf '1\\n' ;;
  esac
  exit 0
fi
case "\$*" in
  *"comm="*) printf '%s\\n' '/bin/zsh' ;;
  *"args="*) printf '%s\\n' '/bin/zsh' ;;
  *"ppid="*) printf '62891\\n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$LOCK" 2>&1) || fail "fm-lock acquire failed for IDE agent-exec: $out"
  assert_contains "$out" "lock acquired: harness pid" "IDE agent-exec process did not acquire the lock"
  holder=$(cat "$home/state/.lock")
  [ "$holder" = 62891 ] || fail "lock holder should be agent-exec pid 62891, got '$holder'"
  pass "fm-lock acquire succeeds for Cursor IDE extension-host (agent-exec)"
}

test_fm_lock_recognizes_cursor_ide_agent_exec_holder() {
  local home fakebin out
  home="$TMP_ROOT/lock-ide-holder"
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-ide-holder-fake")
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"comm="*) printf '%s\\n' '$CURSOR_IDE_AGENT_COMM'; exit 0 ;;
  *"args="*) printf '%s\\n' '$CURSOR_IDE_AGENT_COMM'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$LOCK" status)
  assert_contains "$out" "lock: held by live harness pid" "fm-lock did not recognize IDE agent-exec as a live holder"
  pass "fm-lock recognizes Cursor IDE agent-exec harness holders"
}

test_fm_lock_rejects_non_agent_exec_cursor_hosts() {
  local home fakebin out label
  home="$TMP_ROOT/lock-ide-reject"
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-ide-reject-fake")
  mkdir -p "$home/state"
  for label in \
    'Cursor Helper (Plugin): extension-host (user) fpsunity [4-57]' \
    'Cursor Helper (Plugin): extension-host (retrieval) fpsunity [4-70]' \
    'Cursor Helper (Plugin): extension-host (always-local) fpsunity [4-71]' \
    '/Applications/Cursor.app/Contents/MacOS/Cursor'
  do
    cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"comm="*) printf '%s\\n' '$label'; exit 0 ;;
  *"args="*) printf '%s\\n' '$label'; exit 0 ;;
  *"ppid="*) printf '1\\n'; exit 0 ;;
esac
exit 1
SH
    chmod +x "$fakebin/ps"
    out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$LOCK" 2>&1) && fail "fm-lock should refuse non-agent-exec Cursor host: $label (got: $out)"
    assert_contains "$out" "cannot locate harness process in ancestry" "unexpected error for non-agent-exec host ($label): $out"
  done
  pass "fm-lock rejects non-agent-exec Cursor extension hosts and Cursor.app"
}

test_fm_lock_rejects_bare_agent_without_cursor_evidence() {
  local home fakebin out
  home="$TMP_ROOT/lock-bare-agent-reject"
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-bare-agent-reject-fake")
  mkdir -p "$home/state"
  # Grok collision: basename agent + argv with no cursor-agent marker must not
  # acquire the lock.
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' 'agent'; exit 0 ;;
  *"args="*) printf '%s\n' '/usr/local/bin/agent --yolo'; exit 0 ;;
  *"ppid="*) printf '1\n'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$LOCK" 2>&1) && fail "fm-lock should refuse bare agent without cursor-agent evidence (got: $out)"
  assert_contains "$out" "cannot locate harness process in ancestry" "unexpected error for bare agent: $out"
  pass "fm-lock rejects bare agent without cursor-agent argv evidence"
}

test_fm_harness_rejects_bare_agent_without_cursor_evidence() {
  local fakebin got
  fakebin=$(fm_fakebin "$TMP_ROOT/detect-bare-agent-reject")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' 'agent'; exit 0 ;;
  *"args="*) printf '%s\n' '/usr/local/bin/agent --yolo'; exit 0 ;;
  *"ppid="*) printf '1\n'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  got=$(OMPCODE='' CURSOR_AGENT='' CLAUDECODE='' GROK_AGENT='' PI_CODING_AGENT='' PATH="$fakebin:$PATH" "$HARNESS")
  [ "$got" = unknown ] || fail "bare agent without cursor-agent evidence should be unknown, got '$got'"
  pass "fm-harness rejects bare agent without cursor-agent argv evidence"
}

test_supervision_cursor_snippet() {
  local out
  out=$("$RENDER" --harness cursor)
  assert_contains "$out" "SUPERVISION OPERATING INSTRUCTIONS - primary harness: cursor" "cursor heading missing"
  assert_contains "$out" "Mode: Cursor foreground checkpoint." "cursor snippet missing"
  assert_contains "$out" "bin/fm-watch-checkpoint.sh" "cursor checkpoint helper missing"
  assert_contains "$out" "Workspace Trust dialog" "cursor snippet missing trust guidance"
  assert_not_contains "$out" "Mode: Unknown harness fallback." "cursor fell through to unknown"
  out=$("$RENDER" --harness cursor)
  # shellcheck disable=SC2016 # Single quotes are deliberate: the snippet carries the literal fallback chain for the reading agent to expand.
  assert_contains "$out" '${FM_CURSOR_WATCH_CHECKPOINT:-${FM_CODEX_WATCH_CHECKPOINT:-180}}' "cursor snippet missing the documented checkpoint fallback chain"
  out=$(FM_CURSOR_WATCH_CHECKPOINT=9 "$RENDER" --harness cursor --repair-line)
  assert_contains "$out" "bin/fm-watch-checkpoint.sh --seconds 9" "cursor repair line missing checkpoint override"
  out=$(FM_CURSOR_WATCH_CHECKPOINT='' FM_CODEX_WATCH_CHECKPOINT=13 "$RENDER" --harness cursor --repair-line)
  assert_contains "$out" "bin/fm-watch-checkpoint.sh --seconds 13" "cursor repair line did not fall back to FM_CODEX_WATCH_CHECKPOINT"
  pass "cursor supervision protocol renders and repairs like a named harness"
}

test_cursor_install_turnend_idempotent() {
  local case_dir wt turnend count
  command -v jq >/dev/null 2>&1 || { pass "cursor turn-end install idempotence (skipped: jq unavailable)"; return; }
  case_dir="$TMP_ROOT/install-idem"
  wt="$case_dir/wt"
  turnend="$case_dir/turn-ended"
  fm_git_init_commit "$wt"
  # Respawn into a reused worktree re-installs over the firstmate-created
  # manifest; the stop entry must not be appended a second time.
  fm_cursor_install_turnend "$wt" "$turnend" >/dev/null
  fm_cursor_install_turnend "$wt" "$turnend" >/dev/null
  count=$(jq --arg cmd "$FM_CURSOR_HOOK_COMMAND" \
    '[.hooks.stop[] | select(type == "object" and .command == $cmd)] | length' \
    "$wt/.cursor/hooks.json")
  [ "$count" = 1 ] || fail "re-install duplicated the firstmate stop hook ($count entries)"
  # Same over a dev-local untracked manifest: the project's own hook is kept
  # and the firstmate entry appears exactly once across repeated installs.
  printf '{"version":1,"hooks":{"stop":[{"command":"./dev-local.sh"}]}}\n' > "$wt/.cursor/hooks.json"
  fm_cursor_install_turnend "$wt" "$turnend" >/dev/null
  fm_cursor_install_turnend "$wt" "$turnend" >/dev/null
  assert_grep 'dev-local.sh' "$wt/.cursor/hooks.json" "re-install dropped the project's own hook"
  count=$(jq --arg cmd "$FM_CURSOR_HOOK_COMMAND" \
    '[.hooks.stop[] | select(type == "object" and .command == $cmd)] | length' \
    "$wt/.cursor/hooks.json")
  [ "$count" = 1 ] || fail "re-install duplicated the firstmate stop hook in a merged manifest ($count entries)"
  pass "cursor turn-end install is idempotent across respawns"
}

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  send-keys)
    # Log the literal launch payload so tests can assert the resolved binary.
    [ -n "${FM_FAKE_SENDLOG:-}" ] && printf '%s\n' "$*" >> "$FM_FAKE_SENDLOG"
    exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  # A real cursor-agent so the spawn's launch-binary resolution succeeds
  # hermetically instead of depending on the host having Cursor installed.
  fm_fake_exit0 "$fakebin" cursor-agent
  printf '%s\n' "$fakebin"
}

test_cursor_spawn_installs_stop_hook() {
  local case_dir home proj wt fakebin id out status hook
  case_dir="$TMP_ROOT/spawn-hook"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="cursor-spawn-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"

  out=$(
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
      PATH="$fakebin:$PATH" \
      "$SPAWN" "$id" "$proj" cursor 2>&1
  )
  status=$?
  expect_code 0 "$status" "cursor spawn should succeed"
  assert_contains "$out" "spawned $id harness=cursor" "cursor spawn did not report success"
  assert_present "$wt/.cursor/hooks.json" "cursor hooks.json was not installed"
  hook="$wt/.cursor/hooks/fm-turn-end.sh"
  assert_present "$hook" "cursor turn-end hook script was not installed"
  assert_grep 'fm-turn-end.sh' "$wt/.cursor/hooks.json" "hooks.json did not point at fm-turn-end.sh"
  assert_grep '.cursor/' "$(git -C "$wt" rev-parse --git-path info/exclude)" "cursor hook path was not gitignored"

  # Hook should touch the task turn-end marker when Cursor fires stop.
  printf '%s\n' '{"hook_event_name":"stop","status":"completed","loop_count":0}' | bash "$hook" >/dev/null
  assert_present "$home/state/$id.turn-ended" "cursor stop hook did not touch turn-ended"

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    PATH="$fakebin:$PATH" \
    "$TEARDOWN" "$id" --force >/dev/null 2>&1 \
    || fail "cursor teardown failed"
  assert_absent "$wt/.cursor/hooks.json" "cursor hooks survived teardown"
  assert_absent "$wt/.cursor/hooks/fm-turn-end.sh" "cursor hook script survived teardown"
  local excl_file
  excl_file=$(git -C "$wt" rev-parse --git-path info/exclude)
  assert_grep '.cursor/hooks.json' "$excl_file" "firstmate hooks.json not scoped in info/exclude"
  assert_grep '.cursor/hooks/fm-turn-end.sh' "$excl_file" "firstmate hook script not scoped in info/exclude"
  ! grep -qxF '.cursor/' "$excl_file" || fail "info/exclude still blanket-excludes the whole .cursor/ tree"
  pass "cursor spawn installs stop hook and teardown removes it"
}

cursor_spawn_task() {
  # cursor_spawn_task <home> <proj> <wt> <id> <fakebin>: run a cursor crewmate
  # spawn for an already-created worktree, echoing combined output.
  local home=$1 proj=$2 wt=$3 id=$4 fakebin=$5
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" cursor 2>&1
}

cursor_teardown_task() {
  local home=$1 fakebin=$2 id=$3
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    PATH="$fakebin:$PATH" \
    "$TEARDOWN" "$id" --force >/dev/null 2>&1
}

test_cursor_spawn_preserves_tracked_cursor_dir() {
  local case_dir home proj wt fakebin id excl
  case_dir="$TMP_ROOT/spawn-preserve"
  home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="cursor-preserve-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief\n' > "$home/data/$id/brief.md"
  # Project commits its own .cursor/rules and its own .cursor/hooks.json.
  fm_git_init_commit "$proj"
  mkdir -p "$proj/.cursor/rules"
  printf 'keep me\n' > "$proj/.cursor/rules/keep.md"
  printf '{"version":1,"hooks":{"stop":[{"command":"./project-own.sh"}]}}\n' > "$proj/.cursor/hooks.json"
  git -C "$proj" add .cursor >/dev/null
  git -C "$proj" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm cursor
  git -C "$proj" worktree add --quiet -b "fm/$id" "$wt"
  touch "$home/state/.last-watcher-beat"

  cursor_spawn_task "$home" "$proj" "$wt" "$id" "$fakebin" >/dev/null 2>&1 \
    || fail "cursor spawn with tracked .cursor should succeed"
  assert_present "$wt/.cursor/hooks/fm-turn-end.sh" "firstmate hook script not installed"
  # A tracked project hooks.json is left untouched: firstmate never dirties it.
  assert_grep 'project-own.sh' "$wt/.cursor/hooks.json" "project hooks.json was clobbered"
  assert_no_grep 'fm-turn-end.sh' "$wt/.cursor/hooks.json" "firstmate merged into a tracked project hooks.json"
  excl=$(git -C "$wt" rev-parse --git-path info/exclude)
  assert_no_grep '.cursor/hooks.json' "$excl" "firstmate excluded a tracked project hooks.json"

  cursor_teardown_task "$home" "$fakebin" "$id" || fail "cursor teardown failed"
  assert_present "$wt/.cursor/rules/keep.md" "teardown destroyed the project's .cursor/rules"
  assert_present "$wt/.cursor/hooks.json" "teardown deleted the project's tracked hooks.json"
  assert_grep 'project-own.sh' "$wt/.cursor/hooks.json" "teardown corrupted the project's tracked hooks.json"
  assert_absent "$wt/.cursor/hooks/fm-turn-end.sh" "firstmate hook script survived teardown"
  pass "cursor spawn/teardown preserves a project's tracked .cursor/ content"
}

test_cursor_spawn_merges_untracked_hooks_json() {
  local case_dir home proj wt fakebin id hook
  command -v jq >/dev/null 2>&1 || { pass "cursor untracked-hooks.json merge (skipped: jq unavailable)"; return; }
  case_dir="$TMP_ROOT/spawn-merge"
  home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="cursor-merge-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_init_commit "$proj"
  mkdir -p "$proj/.cursor/rules"
  printf 'keep me\n' > "$proj/.cursor/rules/keep.md"
  git -C "$proj" add .cursor >/dev/null
  git -C "$proj" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm rules
  git -C "$proj" worktree add --quiet -b "fm/$id" "$wt"
  # A dev-local, UNTRACKED hooks.json already present in the worktree.
  printf '{"version":1,"hooks":{"stop":[{"command":"./dev-local.sh"}]}}\n' > "$wt/.cursor/hooks.json"
  touch "$home/state/.last-watcher-beat"

  cursor_spawn_task "$home" "$proj" "$wt" "$id" "$fakebin" >/dev/null 2>&1 \
    || fail "cursor spawn with untracked hooks.json should succeed"
  hook="$wt/.cursor/hooks/fm-turn-end.sh"
  assert_present "$hook" "firstmate hook script not installed"
  # Merge keeps the project's own hook and adds firstmate's.
  assert_grep 'dev-local.sh' "$wt/.cursor/hooks.json" "merge dropped the project's own hook"
  assert_grep 'fm-turn-end.sh' "$wt/.cursor/hooks.json" "merge did not add firstmate's stop hook"
  printf '%s\n' '{"hook_event_name":"stop"}' | bash "$hook" >/dev/null
  assert_present "$home/state/$id.turn-ended" "merged cursor stop hook did not fire"

  cursor_teardown_task "$home" "$fakebin" "$id" || fail "cursor teardown failed"
  assert_present "$wt/.cursor/rules/keep.md" "teardown destroyed the project's .cursor/rules"
  assert_absent "$wt/.cursor/hooks/fm-turn-end.sh" "firstmate hook script survived teardown"
  pass "cursor spawn merges into an untracked hooks.json and teardown spares tracked content"
}

# fake_cursor_agent <fakebin>: a cursor-agent stub whose name alone is the
# unambiguous Cursor signal. fake_grok_agent <fakebin>: a bare `agent` that is
# NOT Cursor (its --version fingerprints as grok), the PATH-collision case.
fake_cursor_agent() {
  fm_fake_exit0 "$1" cursor-agent
}
fake_grok_agent() {
  cat > "$1/agent" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf 'grok agent 1.2.3\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$1/agent"
}

test_cursor_launch_bin_prefers_cursor_agent() {
  local fakebin got
  fakebin=$(fm_fakebin "$TMP_ROOT/launch-prefer")
  # A non-Cursor `agent` (Grok collision) AND cursor-agent both on PATH: the
  # unambiguous cursor-agent must win, never the bare agent.
  fake_grok_agent "$fakebin"
  fake_cursor_agent "$fakebin"
  got=$(CURSOR_INVOKED_AS='' CURSOR_AGENT='' PATH="$fakebin:/usr/bin:/bin" bash -c '. "'"$ROOT"'/bin/fm-cursor-hook-lib.sh"; fm_cursor_launch_bin') \
    || fail "resolver failed when cursor-agent is present"
  [ "$got" = cursor-agent ] || fail "resolver should prefer cursor-agent, got '$got'"
  pass "cursor launch resolver prefers cursor-agent over a colliding bare agent"
}

test_cursor_launch_bin_falls_back_to_verified_agent() {
  local fakebin got
  fakebin=$(fm_fakebin "$TMP_ROOT/launch-fallback")
  # No cursor-agent; a bare `agent` verified as Cursor via --version fingerprint.
  cat > "$fakebin/agent" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf 'cursor-agent 2026.07.08-0c04a8a\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/agent"
  got=$(CURSOR_INVOKED_AS='' CURSOR_AGENT='' PATH="$fakebin:/usr/bin:/bin" bash -c '. "'"$ROOT"'/bin/fm-cursor-hook-lib.sh"; fm_cursor_launch_bin') \
    || fail "resolver failed when a verified Cursor agent is the only option"
  [ "$got" = agent ] || fail "resolver should fall back to verified bare agent, got '$got'"
  pass "cursor launch resolver falls back to a verified bare agent when cursor-agent is absent"
}

test_cursor_launch_bin_rejects_non_cursor_agent() {
  local fakebin rc
  fakebin=$(fm_fakebin "$TMP_ROOT/launch-reject")
  # No cursor-agent; only a non-Cursor `agent` (Grok). Resolver must refuse.
  fake_grok_agent "$fakebin"
  CURSOR_INVOKED_AS='' CURSOR_AGENT='' PATH="$fakebin:/usr/bin:/bin" bash -c '. "'"$ROOT"'/bin/fm-cursor-hook-lib.sh"; fm_cursor_launch_bin' >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "resolver should refuse a non-Cursor bare agent with no cursor-agent present"
  pass "cursor launch resolver refuses a non-Cursor bare agent"
}

test_cursor_spawn_uses_cursor_agent_not_bare_agent() {
  local case_dir home proj wt fakebin id sendlog
  case_dir="$TMP_ROOT/spawn-launchbin"
  home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  # A non-Cursor `agent` sits on PATH too (Grok collision); cursor-agent from
  # make_spawn_fakebin must still be the one that gets launched.
  fake_grok_agent "$fakebin"
  id="cursor-launchbin-x1"
  sendlog="$case_dir/sendlog"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"

  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_SENDLOG="$sendlog" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" cursor --model cursor-test-model --effort high >/dev/null 2>&1 \
    || fail "cursor spawn with a colliding agent should succeed"
  assert_grep 'cursor-agent --force --workspace' "$sendlog" "spawn did not launch via cursor-agent"
  assert_no_grep ' -l agent --force' "$sendlog" "spawn launched the bare colliding agent"
  assert_contains "$(cat "$sendlog")" "--model 'cursor-test-model'" "cursor spawn omitted its verified model flag"
  assert_not_contains "$(cat "$sendlog")" "--effort" "cursor spawn passed an unverified standalone effort flag"
  assert_not_contains "$(cat "$sendlog")" "--thinking" "cursor spawn reused Pi's effort flag"
  assert_not_contains "$(cat "$sendlog")" "--reasoning-effort" "cursor spawn reused Grok's effort flag"
  assert_grep 'model=cursor-test-model' "$home/state/$id.meta" "cursor spawn did not record the requested model axis"
  assert_grep 'effort=high' "$home/state/$id.meta" "cursor spawn did not record the requested effort axis"

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    PATH="$fakebin:$PATH" \
    "$TEARDOWN" "$id" --force >/dev/null 2>&1 || fail "cursor teardown failed"
  pass "cursor spawn launches cursor-agent, passes model, and records-but-omits standalone effort"
}

test_busy_regex_matches_cursor_footer() {
  local line
  line='  → Add a follow-up                                             ctrl+c to stop'
  printf '%s\n' "$line" | grep -qiE 'esc (to )?interrupt|Working\.\.\.|Ctrl\+c:cancel|ctrl\+c to stop' \
    || fail "default busy regex should match cursor ctrl+c to stop footer"
  pass "busy regex matches cursor mid-turn footer"
}

test_detect_cursor_env_marker
test_detect_cursor_env_does_not_override_claude
test_detect_cursor_via_args
test_detect_survives_dash_comm
test_fm_lock_recognizes_cursor_holder
test_fm_lock_acquire_finds_cursor
test_fm_lock_skips_wrapper_argv_substring
test_detect_cursor_ide_agent_exec_ancestry
test_fm_lock_acquire_finds_cursor_ide_agent_exec
test_fm_lock_recognizes_cursor_ide_agent_exec_holder
test_fm_lock_rejects_non_agent_exec_cursor_hosts
test_fm_lock_rejects_bare_agent_without_cursor_evidence
test_fm_harness_rejects_bare_agent_without_cursor_evidence
test_supervision_cursor_snippet
test_cursor_install_turnend_idempotent
test_cursor_launch_bin_prefers_cursor_agent
test_cursor_launch_bin_falls_back_to_verified_agent
test_cursor_launch_bin_rejects_non_cursor_agent
test_cursor_spawn_installs_stop_hook
test_cursor_spawn_preserves_tracked_cursor_dir
test_cursor_spawn_merges_untracked_hooks_json
test_cursor_spawn_uses_cursor_agent_not_bare_agent
test_busy_regex_matches_cursor_footer
