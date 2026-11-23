# shellcheck shell=bash
# Source only after runner-owner.sh has verified the lock and fm-wake-lib.sh is loaded.
# Reuse the native record owner. The marker distinguishes this runner generation
# from records left by another supervisor, which a runner must not take over.
runner_posture() {
  local flag="$STATE/.afk" contract="$STATE/.afk-contract" gate="$STATE/.afk-return-catchup" marker="$STATE/.lock/runner-posture"
  if [ ! -e "$flag" ] && [ ! -L "$flag" ] && [ ! -e "$contract" ] && [ ! -L "$contract" ] \
    && [ ! -e "$gate" ] && [ ! -L "$gate" ]; then
    printf 'attended\n'; return
  fi
  if [ ! -f "$marker" ] || [ -L "$marker" ] || [ "$(head -c 128 "$marker")" != "$FM_POCKET_RUNNER_COMMAND" ] \
    || [ -L "$flag" ] || [ -L "$contract" ] || [ -L "$gate" ] \
    || { [ -e "$flag" ] && [ ! -f "$flag" ]; } || { [ -e "$contract" ] && [ ! -f "$contract" ]; }; then
    printf 'foreign\n'; return
  fi
  if [ -e "$gate" ]; then
    if [ -f "$gate" ]; then printf 'catchup\n'; else printf 'foreign\n'; fi
  elif [ -f "$contract" ]; then
    bash "$FM_HOME/bin/fm-afk-contract.sh" mode || printf 'foreign\n'
  else
    printf 'foreign\n'
  fi
}
