#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness (agent) process PID found by walking the shell's ancestry,
# which lives as long as the firstmate session - unlike the transient subshell
# PID of any one tool call, which is dead moments after it is written.
# Usage: fm-lock.sh           acquire; exit 1 if another live session holds it
#        fm-lock.sh status    print holder and liveness; always exits 0
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
mkdir -p "$STATE"

# Known harness command names / argv markers; extend when a new adapter is verified.
# cursor-agent matches Cursor Agent argv (the binary is often bare "agent", which
# is too ambiguous alone). Do not use basename(1): macOS basename treats a
# leading dash in the operand as options (basename -zsh -> illegal -z).
HARNESS_RE='claude|codex|opencode|grok|^pi$|cursor-agent|^cursor$'

comm_base() {
  local c=$1
  c=${c##*/}
  printf '%s\n' "$c"
}

looks_like_harness() {  # <comm> <args>
  local base
  base=$(comm_base "$1")
  # 1. comm names the harness binary directly (claude, codex, opencode, grok, pi, cursor).
  printf '%s' "$base" | grep -qE "$HARNESS_RE" && return 0
  # 2. Bare interpreter running a harness script (e.g. node .../claude/cli.js):
  #    match the harness name in argv. Gated to interpreters so an intermediate
  #    wrapper whose argv merely contains a harness substring is never mistaken
  #    for the harness itself.
  case "$base" in
    node|node[0-9]*|nodejs|nodejs[0-9]*|python|python[0-9]*|deno|bun)
      printf '%s' "$2" | grep -qE "$HARNESS_RE" && return 0 ;;
  esac
  # 3. Cursor Agent: the binary is the generic "agent" and macOS truncates comm,
  #    so the only reliable, unambiguous signal is the cursor-agent argv marker.
  printf '%s' "$2" | grep -qE 'cursor-agent'
}

harness_pid() {
  local pid=$$ comm args
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if looks_like_harness "$comm" "$args"; then
      echo "$pid"; return 0
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

holder_alive() {  # true if $1 is a live process that looks like a harness
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  looks_like_harness "$comm" "$args"
}

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK")
  if holder_alive "$old"; then echo "lock: held by live harness pid $old"; else echo "lock: stale (pid $old dead or not a harness)"; fi
  exit 0
fi

me=$(harness_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }
if [ -f "$LOCK" ]; then
  old=$(cat "$LOCK")
  if [ "$old" != "$me" ] && holder_alive "$old"; then
    echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
    exit 1
  fi
fi
echo "$me" > "$LOCK"
echo "lock acquired: harness pid $me"
