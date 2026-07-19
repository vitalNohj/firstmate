#!/usr/bin/env bash
# OMP 17.0.5 crewmate/scout adapter behavior.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-omp-harness)
FM_BACKEND_LIB_DIR="$ROOT/bin"
export FM_BACKEND_LIB_DIR
# shellcheck source=bin/backends/tmux.sh
. "$ROOT/bin/backends/tmux.sh"

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
    [ -n "${FM_FAKE_SENDLOG:-}" ] && printf '%s\n' "$*" >> "$FM_FAKE_SENDLOG"
    exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="omp-$name-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$id"
}

run_omp_spawn() {
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5 sendlog=$6
  shift 6
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" FM_FAKE_SENDLOG="$sendlog" \
    TMUX="fake,1,0" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --harness omp "$@" 2>&1
}

test_omp_marker_precedes_claude_marker() {
  local fakebin got
  fakebin=$(fm_fakebin "$TMP_ROOT/detect")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/ps"
  got=$(OMPCODE=1 CLAUDECODE=1 PI_CODING_AGENT='' GROK_AGENT='' CURSOR_AGENT='' \
    PATH="$fakebin:$PATH" "$HARNESS")
  [ "$got" = omp ] || fail "OMPCODE=1 should win over inherited CLAUDECODE=1, got '$got'"
  got=$(OMPCODE='' CLAUDECODE=1 PI_CODING_AGENT='' GROK_AGENT='' CURSOR_AGENT='' \
    PATH="$fakebin:$PATH" "$HARNESS")
  [ "$got" = claude ] || fail "CLAUDECODE=1 without OMPCODE should remain claude, got '$got'"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/opt/homebrew/bin/omp'; exit 0 ;;
  *"args="*) printf '%s\n' '/opt/homebrew/bin/omp --auto-approve'; exit 0 ;;
  *"ppid="*) printf '1\n'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  got=$(OMPCODE='' CLAUDECODE='' PI_CODING_AGENT='' GROK_AGENT='' CURSOR_AGENT='' \
    PATH="$fakebin:$PATH" "$HARNESS")
  [ "$got" = omp ] || fail "exact omp process ancestry should detect OMP, got '$got'"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/opt/homebrew/bin/node'; exit 0 ;;
  *"args="*) printf '%s\n' 'node wrapper.js omp --auto-approve'; exit 0 ;;
  *"ppid="*) printf '1\n'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  got=$(OMPCODE='' CLAUDECODE='' PI_CODING_AGENT='' GROK_AGENT='' CURSOR_AGENT='' \
    PATH="$fakebin:$PATH" "$HARNESS")
  [ "$got" = unknown ] || fail "non-omp interpreter ancestry should remain unknown, got '$got'"
  pass "fm-harness detects OMPCODE precedence and exact omp ancestry"
}

test_omp_spawn_maps_profile_and_extension() {
  local rec case_dir home proj wt fakebin id sendlog out status
  rec=$(make_spawn_case profile)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  sendlog="$case_dir/send.log"
  : > "$sendlog"
  out=$(run_omp_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$sendlog" \
    --model openai/gpt-5.6-sol --effort high)
  status=$?
  expect_code 0 "$status" "OMP spawn should succeed"
  assert_contains "$out" "spawned $id harness=omp" "OMP spawn did not report success"
  # shellcheck disable=SC2016  # asserting literal shell expressions in the launch payload
  grep -F -- 'omp --cwd "$(pwd)"' "$sendlog" >/dev/null || fail "OMP launch did not pin cwd"
  # shellcheck disable=SC2016  # asserting literal shell expressions in the launch payload
  grep -F -- '--session-dir "$GOTMPDIR/../omp-sessions"' "$sendlog" >/dev/null || fail "OMP launch did not isolate session state"
  grep -F -- '--auto-approve' "$sendlog" >/dev/null || fail "OMP launch omitted unattended approval"
  grep -F -- "--model 'openai/gpt-5.6-sol'" "$sendlog" >/dev/null || fail "OMP model mapping missing"
  grep -F -- "--thinking 'high'" "$sendlog" >/dev/null || fail "OMP thinking mapping missing"
  grep -F -- "-e '$home/state/$id.pi-ext.ts'" "$sendlog" >/dev/null || fail "OMP turn-end extension was not loaded"
  assert_grep 'pi.on("turn_end"' "$home/state/$id.pi-ext.ts" "OMP extension does not listen for turn_end"
  assert_grep 'harness=omp' "$home/state/$id.meta" "OMP harness was not recorded"
  assert_grep 'model=openai/gpt-5.6-sol' "$home/state/$id.meta" "OMP model was not recorded"
  assert_grep 'effort=high' "$home/state/$id.meta" "OMP effort was not recorded"
  rm -rf "/tmp/fm-$id"
  pass "OMP spawn maps cwd, session, approval, model, thinking, and turn_end extension"
}

test_omp_max_effort_is_mapped() {
  local rec case_dir home proj wt fakebin id sendlog out status
  rec=$(make_spawn_case max-effort)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  sendlog="$case_dir/send.log"
  : > "$sendlog"
  out=$(run_omp_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$sendlog" --effort max --scout)
  status=$?
  expect_code 0 "$status" "OMP spawn with max effort should succeed"
  grep -F -- "--thinking 'max'" "$sendlog" >/dev/null || fail "OMP max effort did not emit --thinking"
  assert_grep 'effort=max' "$home/state/$id.meta" "requested OMP max effort was not recorded"
  assert_grep 'kind=scout' "$home/state/$id.meta" "OMP scout kind was not recorded"
  rm -rf "/tmp/fm-$id"
  pass "OMP scout launch maps the shared max effort to native max thinking"
}

test_omp_secondmate_stays_rejected() {
  local home out status
  home="$TMP_ROOT/secondmate-home"
  mkdir -p "$home/config" "$home/state" "$home/data" "$home/projects"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 "$SPAWN" omp-secondmate-x1 --secondmate --harness omp 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "OMP secondmate launch should remain rejected"
  assert_contains "$out" "OMP is verified for crewmate and scout launches only" "OMP secondmate rejection was unclear"
  printf 'omp\n' > "$home/config/secondmate-harness"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 "$SPAWN" omp-secondmate-x2 --secondmate 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "config/secondmate-harness=omp should remain rejected"
  assert_contains "$out" "OMP is verified for crewmate and scout launches only" "configured OMP secondmate rejection was unclear"
  pass "OMP remains unavailable for secondmate launches"
}

test_omp_non_tmux_backends_are_rejected_before_workspace_creation() {
  local backend rec case_dir home proj wt fakebin id sendlog out status
  for backend in herdr zellij orca cmux; do
    rec=$(make_spawn_case "backend-$backend")
    IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
    sendlog="$case_dir/send.log"
    : > "$sendlog"
    out=$(run_omp_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$sendlog" --backend "$backend")
    status=$?
    [ "$status" -ne 0 ] || fail "OMP launch on backend=$backend should be rejected"
    assert_contains "$out" "verified on backend=tmux only" "OMP backend=$backend rejection was unclear"
    [ ! -s "$sendlog" ] || fail "OMP backend=$backend rejection sent workspace commands"
    [ ! -e "$home/state/$id.meta" ] || fail "OMP backend=$backend rejection created task metadata"
  done
  pass "OMP rejects every non-tmux backend before task workspace creation"
}

test_omp_busy_and_liveness_signatures() {
  local line got
  for line in '⠋ Working… ⟦esc⟧' '⠧ Probing live autonomy ⟨esc⟩' 'Probing [esc]'; do
    printf '%s\n' "$line" | grep -qE "$FM_TMUX_BUSY_REGEX_DEFAULT" \
      || fail "OMP busy line was not recognized: $line"
  done
  printf '%s\n' '╰─                            ─╯' | grep -qE "$FM_TMUX_BUSY_REGEX_DEFAULT" \
    && fail "idle OMP composer matched busy regex"
  fm_backend_tmux_current_command() { printf '%s\n' "$FM_FAKE_COMM"; }
  got=$(FM_FAKE_COMM=omp fm_backend_tmux_agent_alive fake)
  [ "$got" = alive ] || fail "exact omp foreground process should be alive, got '$got'"
  got=$(FM_FAKE_COMM=zsh fm_backend_tmux_agent_alive fake)
  [ "$got" = dead ] || fail "returned shell should be dead, got '$got'"
  pass "OMP bracketed-Escape busy suffix and exact process liveness are recognized"
}

test_omp_swallowed_first_enter_retries_without_retyping() {
  local dir fakebin composer log swallow verdict
  dir="$TMP_ROOT/composer"
  fakebin="$dir/fakebin"
  composer="$dir/composer"
  log="$dir/send.log"
  swallow="$dir/swallow-once"
  mkdir -p "$fakebin"
  printf '╰─                            ─╯\n' > "$composer"
  : > "$log"
  touch "$swallow"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    for arg in "$@"; do case "$arg" in *cursor_y*) printf '0\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) cat "$FM_FAKE_COMPOSER"; exit 0 ;;
  send-keys)
    shift
    text=''; literal=0; enter=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -t) shift ;;
        -l) literal=1 ;;
        Enter) enter=1 ;;
        *) [ "$literal" = 1 ] && text=$1 ;;
      esac
      shift
    done
    if [ "$enter" = 1 ]; then
      printf '[ENTER]\n' >> "$FM_FAKE_SENDLOG"
      if [ -f "$FM_FAKE_SWALLOW" ]; then
        rm -f "$FM_FAKE_SWALLOW"
      else
        printf '╰─                            ─╯\n' > "$FM_FAKE_COMPOSER"
      fi
    elif [ "$literal" = 1 ]; then
      printf '[TEXT]%s\n' "$text" >> "$FM_FAKE_SENDLOG"
      printf '╰─ %s ─╯\n' "$text" > "$FM_FAKE_COMPOSER"
    fi
    exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  verdict=$(PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENDLOG="$log" \
    FM_FAKE_SWALLOW="$swallow" fm_tmux_submit_core fake 'route this work' 3 0 0)
  [ "$verdict" = empty ] || fail "OMP submit did not confirm after Enter retry: $verdict"
  [ "$(grep -c '^\[TEXT\]' "$log")" -eq 1 ] || fail "OMP submit retyped the prompt"
  [ "$(grep -c '^\[ENTER\]' "$log")" -eq 2 ] || fail "OMP submit did not retry Enter exactly once"
  pass "OMP swallowed first Enter retries Enter only and recognizes the empty composer"
}

test_omp_marker_precedes_claude_marker
test_omp_spawn_maps_profile_and_extension
test_omp_max_effort_is_mapped
test_omp_secondmate_stays_rejected
test_omp_non_tmux_backends_are_rejected_before_workspace_creation
test_omp_busy_and_liveness_signatures
test_omp_swallowed_first_enter_retries_without_retyping
