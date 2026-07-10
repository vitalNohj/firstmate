# shellcheck shell=bash
# Firstmate-owned Cursor turn-end hook lifecycle.
# Usage: . bin/fm-cursor-hook-lib.sh
#
# Scoped to only the files firstmate creates, so a project's own .cursor/ tree
# (commonly .cursor/rules/, and sometimes a committed .cursor/hooks.json) is
# never clobbered on install or destroyed on teardown. This mirrors how every
# other harness adapter touches only its own specific hook files rather than a
# whole directory.

# Worktree-relative paths of the firstmate turn-end hook script and the Cursor
# hooks manifest, plus the command string firstmate registers in the manifest.
FM_CURSOR_HOOK_SCRIPT_REL='.cursor/hooks/fm-turn-end.sh'
FM_CURSOR_HOOKS_JSON_REL='.cursor/hooks.json'
FM_CURSOR_HOOK_COMMAND='.cursor/hooks/fm-turn-end.sh'

# fm_cursor_realpath <path>
# Best-effort resolution of a possibly-symlinked binary path, portable to macOS
# where readlink -f is absent. Follows a bounded number of symlink hops and
# prints the resolved path (the input unchanged when it is not a symlink).
fm_cursor_realpath() {
  local p=$1 target i=0
  while [ -L "$p" ] && [ "$i" -lt 10 ]; do
    target=$(readlink "$p") || break
    case "$target" in
      /*) p=$target ;;
      *) p="$(dirname "$p")/$target" ;;
    esac
    i=$((i + 1))
  done
  printf '%s\n' "$p"
}

# fm_cursor_agent_is_cursor
# Return 0 when the bare `agent` binary currently on PATH is Cursor Agent rather
# than a name collision (Grok also installs an `agent`). Checks, cheapest first:
# the Cursor launcher env marker CURSOR_INVOKED_AS; the resolved binary path
# mentioning cursor-agent (the common install symlinks agent -> a cursor-agent
# path); and finally a --version fingerprint that names cursor. This mirrors the
# cursor-agent signal that primary detection keys on (bin/fm-harness.sh).
fm_cursor_agent_is_cursor() {
  local bin resolved
  bin=$(command -v agent 2>/dev/null) || return 1
  [ -n "${CURSOR_INVOKED_AS:-}" ] && return 0
  resolved=$(fm_cursor_realpath "$bin")
  case "$resolved" in *cursor-agent*) return 0 ;; esac
  case "$bin" in *cursor-agent*) return 0 ;; esac
  "$bin" --version 2>/dev/null | grep -qi cursor && return 0
  return 1
}

# fm_cursor_launch_bin
# Print the binary firstmate should launch a Cursor crewmate with, matching the
# robustness of primary Cursor detection. ALWAYS prefer cursor-agent when it is
# on PATH, so a colliding bare `agent` (Grok, or anything else that owns the
# ambiguous name) can never be chosen ahead of the unambiguous cursor-agent.
# Fall back to bare `agent` only when cursor-agent is absent AND `agent` is
# verified to be Cursor. Returns non-zero, printing nothing, when neither is
# resolvable so the caller can abort the spawn rather than launch the wrong CLI.
fm_cursor_launch_bin() {
  if command -v cursor-agent >/dev/null 2>&1; then
    printf '%s\n' cursor-agent
    return 0
  fi
  if command -v agent >/dev/null 2>&1 && fm_cursor_agent_is_cursor; then
    printf '%s\n' agent
    return 0
  fi
  return 1
}

# fm_cursor_write_fresh_hooks_json <hooks.json path>
# Writes a minimal firstmate-only hooks.json registering the turn-end stop hook.
fm_cursor_write_fresh_hooks_json() {
  cat > "$1" <<EOF
{
  "version": 1,
  "hooks": {
    "stop": [
      {
        "command": "$FM_CURSOR_HOOK_COMMAND"
      }
    ]
  }
}
EOF
}

# fm_cursor_install_turnend <worktree> <turnend-path>
# Writes the firstmate turn-end script and registers a stop hook that touches
# <turnend-path> at every Cursor turn boundary. Creates hooks.json fresh when
# the project has none. When the project provides an UNTRACKED hooks.json, the
# firstmate stop entry is merged in (jq) so the project's own hooks are kept;
# without jq the untracked file is replaced with the firstmate-only manifest.
# A TRACKED project hooks.json is left untouched, because firstmate must never
# dirty or leak a committed project file; turn-end then falls back to
# pane-staleness supervision for that rare task. Prints, one per line, the
# worktree-relative paths the caller should add to git info/exclude.
fm_cursor_install_turnend() {
  local wt=$1 turnend=$2 json tmp
  json="$wt/$FM_CURSOR_HOOKS_JSON_REL"
  mkdir -p "$wt/.cursor/hooks"
  cat > "$wt/$FM_CURSOR_HOOK_SCRIPT_REL" <<EOF
#!/usr/bin/env bash
set -u
# Drain stdin JSON from Cursor's stop hook; only the touch matters for firstmate.
cat >/dev/null
touch '$turnend' 2>/dev/null || true
printf '%s\n' '{}'
exit 0
EOF
  chmod +x "$wt/$FM_CURSOR_HOOK_SCRIPT_REL"
  printf '%s\n' "$FM_CURSOR_HOOK_SCRIPT_REL"

  if [ ! -e "$json" ]; then
    fm_cursor_write_fresh_hooks_json "$json"
    printf '%s\n' "$FM_CURSOR_HOOKS_JSON_REL"
    return 0
  fi

  if git -C "$wt" ls-files --error-unmatch "$FM_CURSOR_HOOKS_JSON_REL" >/dev/null 2>&1; then
    printf 'fm-cursor: %s is tracked by the project; leaving it untouched, cursor turn-end relies on pane-staleness supervision for this task\n' \
      "$FM_CURSOR_HOOKS_JSON_REL" >&2
    return 0
  fi

  if command -v jq >/dev/null 2>&1; then
    tmp="$json.fm-tmp.$$"
    if jq --arg cmd "$FM_CURSOR_HOOK_COMMAND" '
          .version = (.version // 1)
          | .hooks = (.hooks // {})
          | .hooks.stop = ((.hooks.stop // []) + [{"command": $cmd}])
        ' "$json" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$json"
    else
      rm -f "$tmp"
      fm_cursor_write_fresh_hooks_json "$json"
    fi
  else
    fm_cursor_write_fresh_hooks_json "$json"
  fi
  printf '%s\n' "$FM_CURSOR_HOOKS_JSON_REL"
  return 0
}

# fm_cursor_teardown <worktree>
# Removes only firstmate-owned Cursor hook files, never the project's .cursor/
# tree. The turn-end script is always firstmate's, so it is removed. hooks.json
# is removed only when it is not tracked by the project (firstmate created it,
# or merged into a dev-local untracked copy); a tracked project hooks.json is
# left in place. Empty .cursor/hooks and .cursor directories firstmate created
# are pruned with rmdir, which no-ops when the project has other content there.
fm_cursor_teardown() {
  local wt=$1
  [ -n "$wt" ] || return 0
  rm -f "$wt/$FM_CURSOR_HOOK_SCRIPT_REL"
  if [ -e "$wt/$FM_CURSOR_HOOKS_JSON_REL" ] \
     && ! git -C "$wt" ls-files --error-unmatch "$FM_CURSOR_HOOKS_JSON_REL" >/dev/null 2>&1; then
    rm -f "$wt/$FM_CURSOR_HOOKS_JSON_REL"
  fi
  rmdir "$wt/.cursor/hooks" "$wt/.cursor" 2>/dev/null || true
  return 0
}
