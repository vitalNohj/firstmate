#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EVID=/home/nohj/.no-mistakes/evidence/01M4C5DK9WC6RV03YK564SA0NY
mkdir -p "$EVID"
export PATH="$ROOT/.live-validation/bin:/usr/bin:/bin"
export HOME="$ROOT/.live-validation/user"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=Lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=Lab GIT_COMMITTER_EMAIL=lab@example.invalid
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
SOCKET="$ROOT/.s"
tmux -S "$SOCKET" new-session -d -s fm-lab-cleanup 'sleep 1200'
export TMUX="$SOCKET,$$,0"
trap 'tmux -S "$SOCKET" kill-server 2>/dev/null || true; rm -f "$SOCKET"' EXIT
for scenario in ${SCENARIOS:-attached detached squash pushed-attached pushed-detached unrelated-head custom-base force unpushed}; do
  echo "===== $scenario ====="
  CASE="$ROOT/.live-validation/$scenario"
  mkdir -p "$CASE"
  export FM_HOME="$CASE/home"
  "$ROOT/bin/fm-lab-home.sh" create "$FM_HOME" >/dev/null
  printf 'manual\n' > "$FM_HOME/config/backlog-backend"
  printf 'tmux\n' > "$FM_HOME/config/backend"
  mkdir -p "$FM_HOME/data/task-x1"
  git init -q --bare --initial-branch=main "$CASE/origin.git"
  git clone -q "$CASE/origin.git" "$CASE/project" 2>/dev/null
  PROJ="$CASE/project"
  printf 'baseline\n' > "$PROJ/base.txt"
  printf 'max_trees = 2\nroot = "%s"\n' "$CASE" > "$PROJ/treehouse.toml"
  git -C "$PROJ" add .; git -C "$PROJ" commit -qm baseline
  git -C "$PROJ" push -q origin main
  git -C "$PROJ" remote set-head origin main
  WT=$(cd "$PROJ" && treehouse get --lease)
  git -C "$WT" checkout -qb fm/task-x1
  printf 'feature\n' > "$WT/feature.txt"
  git -C "$WT" add .; git -C "$WT" commit -qm feature
  TIP=$(git -C "$WT" rev-parse HEAD)
  BRANCH=fm/task-x1
  MODE=local-only
  EXPECT=absent
  FLAGS=()
  case "$scenario" in
    attached|detached) git -C "$PROJ" merge -q --ff-only fm/task-x1; [ "$scenario" != detached ] || git -C "$WT" checkout -q --detach ;;
    squash) MODE=direct-PR; git -C "$PROJ" merge -q --squash fm/task-x1; git -C "$PROJ" commit -qm squash; git -C "$PROJ" push -q origin main; git -C "$WT" checkout -q --detach main ;;
    pushed-*) MODE=direct-PR; EXPECT=present; git -C "$WT" push -q origin HEAD:fm/task-x1; [ "$scenario" != pushed-detached ] || git -C "$WT" checkout -q --detach ;;
    unrelated-head) EXPECT=present; git -C "$WT" checkout -q --detach main ;;
    custom-base) MODE=direct-PR; git -C "$WT" push -q origin HEAD:release; git -C "$WT" checkout -q --detach main ;;
    custom-name) BRANCH=worker/custom; git -C "$WT" branch -m "$BRANCH"; git -C "$PROJ" merge -q --ff-only "$BRANCH"; git -C "$WT" checkout -q --detach ;;
    other-checkout) EXPECT=present; git -C "$PROJ" merge -q --ff-only "$BRANCH"; git -C "$WT" checkout -q --detach; git -C "$PROJ" worktree add -q "$CASE/other" "$BRANCH" ;;
    force) FLAGS=(--force) ;;
    unpushed) EXPECT=present ;;
  esac
  printf 'window=fm-lab-cleanup:fm-task-x1\nendpoint_task_id=task-x1\nworktree=%s\nproject=%s\nkind=ship\nmode=%s\nbackend=tmux\nspawn_gen=lab-task-x1\nbranch=%s\n' "$WT" "$PROJ" "$MODE" "$BRANCH" > "$FM_HOME/state/task-x1.meta"
  [ "$scenario" != custom-base ] || printf 'base_branch=release\n' >> "$FM_HOME/state/task-x1.meta"
  touch "$FM_HOME/state/.last-watcher-beat"
  echo "Before: task ref=$TIP; HEAD=$(git -C "$WT" rev-parse --abbrev-ref HEAD); mode=$MODE"
  set +e
  "${TEARDOWN_SCRIPT:-$ROOT/bin/fm-teardown.sh}" task-x1 "${FLAGS[@]}"
  RC=$?
  set -e
  AFTER=absent
  git -C "$PROJ" show-ref --verify "refs/heads/$BRANCH" && AFTER=present
  echo "After: exit=$RC task-ref=$AFTER expected=$EXPECT meta-exists=$([ -f "$FM_HOME/state/task-x1.meta" ] && echo yes || echo no)"
  (cd "$PROJ" && treehouse status)
  [ "$AFTER" = "$EXPECT" ] || exit 20
  if [ "$scenario" = unpushed ]; then [ "$RC" != 0 ]; else [ "$RC" = 0 ]; fi
  echo "SCENARIO PASSED: $scenario"
done
