#!/usr/bin/env bash
# tests/fm-pi-pocket-dropin.test.sh - the Firstmate Pi Pocket drop-in
# (pi-pocket/firstmate.ts) inside a real Pi Pocket app on temporary data
# directories, through tests/fm-pi-pocket-dropin.ts, plus the install script
# bin/fm-pi-pocket-install.sh and the browser module's ordering test
# tests/fm-pi-pocket-browser.mjs.
#
# The browser-module test always runs and needs Node on PATH. The app tests
# need a Pi Pocket checkout with its dependencies installed
# (FM_PI_POCKET_CHECKOUT, default ~/pi-pocket) and a Node.js that strips
# TypeScript types (FM_PI_POCKET_NODE, else the first of the checkout's
# service Node, ~/.local/opt/node/bin/node, and node on PATH that does).
# Without that checkout or that Node, the app tests skip. It never touches
# a live Pi Pocket data directory.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS \
  GEMINI_CLI ATLASSIAN_AGENT_TYPE ROVODEV_CLI FM_OMP_HARNESS CLAUDE_CODE_SESSION_ID CLAUDE_PID \
  FM_PI_POCKET_CONVERSATION FM_PI_POCKET_SERVER_PID FM_SUPERVISION_ACTOR FM_SUPERVISION_PRIMARY_HARNESS \
  FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_TASK_ID FM_TASK_INBOX PI_POCKET_DIR
export NODE_NO_WARNINGS=1

CHECKOUT=${FM_PI_POCKET_CHECKOUT:-$HOME/pi-pocket}
INSTALL="$ROOT/bin/fm-pi-pocket-install.sh"
DROPIN="$ROOT/pi-pocket/firstmate.ts"
CLIENT="$ROOT/pi-pocket/firstmate.js"
BROWSER="$ROOT/tests/fm-pi-pocket-browser.mjs"

typescript_node() {
  local candidate
  for candidate in "${FM_PI_POCKET_NODE:-}" "$HOME/.local/opt/node/bin/node" "$(command -v node 2>/dev/null)"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    if [ "$("$candidate" -p 'process.features.typescript' 2>/dev/null)" = strip ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

# --- browser module ----------------------------------------------------------

test_browser_keeps_the_active_calm_state_when_an_older_read_resolves_last() {
  command -v node >/dev/null 2>&1 || fail "node is required to prove a stale Calm read cannot override the active conversation"
  local out
  out=$(node --test --test-concurrency=1 --test-reporter=tap "$BROWSER" 2>&1) || {
    printf '%s\n' "$out" >&2
    fail "the browser module applied a stale Calm read"
  }
  local needle
  for needle in \
    "ok 1 - an older calm read that resolves last does not change the active conversation" \
    "ok 2 - an older calm read that resolves before the active one does not present it" \
    "ok 3 - a calm toggle is kept when the earlier settings response resolves last" \
    "ok 4 - a calm event for another conversation rereads the shown conversation" \
    "# fail 0"
  do
    case "$out" in
      *"$needle"*) ;;
      *)
        printf '%s\n' "$out" >&2
        fail "the browser module test did not keep the active Calm state, missing: $needle"
        ;;
    esac
  done
  pass "browser module: a slower Calm read cannot override the active conversation or a newer toggle, and another conversation's toggle rereads the shown home"
}

test_browser_keeps_the_active_calm_state_when_an_older_read_resolves_last

if [ ! -f "$CHECKOUT/test/helpers.ts" ] || [ ! -d "$CHECKOUT/node_modules/@earendil-works/pi-durable" ]; then
  echo "skip: no Pi Pocket checkout with installed dependencies at $CHECKOUT"
  exit 0
fi
if ! NODE=$(typescript_node); then
  echo "skip: no Node.js that strips TypeScript types for the Pi Pocket drop-in test"
  exit 0
fi

TMP_ROOT=$(fm_test_tmproot fm-pi-pocket-dropin)

# --- install -----------------------------------------------------------------

test_install_copies_idempotently_and_skips_without_pi_pocket() {
  local dir="$TMP_ROOT/install" out
  mkdir -p "$dir/checkout"
  out=$(PI_POCKET_DIR="$dir/data" FM_PI_POCKET_CHECKOUT="$dir/absent" "$INSTALL" 2>&1) \
    || fail "install without a Pi Pocket checkout must exit 0, got: $out"
  case "$out" in *"skipped"*) ;; *) fail "install without a checkout must say it skipped, got: $out" ;; esac
  [ ! -e "$dir/data" ] || fail "install without a checkout must not create the data directory"

  out=$(PI_POCKET_DIR="$dir/data" FM_PI_POCKET_CHECKOUT="$dir/checkout" "$INSTALL" 2>&1) \
    || fail "install must succeed, got: $out"
  [ -f "$dir/data/extensions/firstmate.ts" ] && [ ! -L "$dir/data/extensions/firstmate.ts" ] \
    || fail "install must copy the drop-in as a regular file"
  [ -f "$dir/data/extensions/firstmate.js" ] && [ ! -L "$dir/data/extensions/firstmate.js" ] \
    || fail "install must copy the browser module as a regular file"
  cmp -s "$DROPIN" "$dir/data/extensions/firstmate.ts" || fail "the installed copy must equal the drop-in"
  cmp -s "$CLIENT" "$dir/data/extensions/firstmate.js" || fail "the installed browser module must equal the drop-in"
  case "$out" in *"installed"*) ;; *) fail "a first install must say it installed, got: $out" ;; esac

  out=$(PI_POCKET_DIR="$dir/data" FM_PI_POCKET_CHECKOUT="$dir/checkout" "$INSTALL" 2>&1) \
    || fail "a repeated install must succeed, got: $out"
  case "$out" in *"up to date"*) ;; *) fail "a repeated install must report it up to date, got: $out" ;; esac

  printf 'stale\n' > "$dir/data/extensions/firstmate.ts"
  out=$(PI_POCKET_DIR="$dir/data" FM_PI_POCKET_CHECKOUT="$dir/checkout" "$INSTALL" 2>&1) \
    || fail "an update install must succeed, got: $out"
  cmp -s "$DROPIN" "$dir/data/extensions/firstmate.ts" || fail "an update install must refresh a stale copy"
  printf 'stale\n' > "$dir/data/extensions/firstmate.js"
  out=$(PI_POCKET_DIR="$dir/data" FM_PI_POCKET_CHECKOUT="$dir/checkout" "$INSTALL" 2>&1) \
    || fail "an update of a stale browser module must succeed, got: $out"
  cmp -s "$CLIENT" "$dir/data/extensions/firstmate.js" || fail "an update install must refresh a stale browser module"
  case "$out" in *"restart Pi Pocket"*) ;; *) fail "an update install must say a running server needs a restart, got: $out" ;; esac
  pass "install: copies the drop-in, is idempotent, refreshes a stale copy, and skips without a Pi Pocket checkout"
}

test_install_if_installed_refreshes_only_an_existing_copy() {
  local dir="$TMP_ROOT/if-installed" out
  mkdir -p "$dir/checkout"
  out=$(PI_POCKET_DIR="$dir/data" FM_PI_POCKET_CHECKOUT="$dir/checkout" "$INSTALL" --if-installed 2>&1) \
    || fail "--if-installed without a copy must exit 0, got: $out"
  case "$out" in *"skipped - no installed drop-in"*) ;; *) fail "--if-installed without a copy must say it skipped, got: $out" ;; esac
  [ ! -e "$dir/data" ] || fail "--if-installed must not create a first install"

  mkdir -p "$dir/data/extensions"
  printf 'stale\n' > "$dir/data/extensions/firstmate.ts"
  out=$(PI_POCKET_DIR="$dir/data" FM_PI_POCKET_CHECKOUT="$dir/checkout" "$INSTALL" --if-installed 2>&1) \
    || fail "--if-installed with a stale copy must succeed, got: $out"
  cmp -s "$DROPIN" "$dir/data/extensions/firstmate.ts" || fail "--if-installed must refresh a stale copy"
  cmp -s "$CLIENT" "$dir/data/extensions/firstmate.js" || fail "--if-installed must install the browser module beside an existing drop-in"
  out=$(PI_POCKET_DIR="$dir/data" FM_PI_POCKET_CHECKOUT="$dir/checkout" "$INSTALL" --if-installed 2>&1) \
    || fail "a repeated --if-installed must succeed, got: $out"
  case "$out" in *"up to date"*) ;; *) fail "a repeated --if-installed must report it up to date, got: $out" ;; esac
  out=$(PI_POCKET_DIR="$dir/data" FM_PI_POCKET_CHECKOUT="$dir/checkout" "$INSTALL" --if-installed extra 2>&1) \
    && fail "an extra argument must be refused, got: $out"
  pass "install --if-installed: refreshes an existing copy, is idempotent, and never creates a first install"
}

# --- the drop-in in a Pi Pocket app ------------------------------------------

test_dropin_in_pi_pocket() {
  local dir="$TMP_ROOT/app" out rc
  mkdir -p "$dir/run"
  ln -s "$CHECKOUT/node_modules" "$dir/run/node_modules"
  printf '{"type":"module"}\n' > "$dir/run/package.json"
  cp "$ROOT/tests/fm-pi-pocket-dropin.ts" "$dir/run/dropin.test.ts"
  mkdir -p "$dir/tmp"
  out=$(cd "$dir/run" && TMPDIR="$dir/tmp" FM_PI_POCKET_CHECKOUT="$CHECKOUT" FM_PI_POCKET_BIN="$ROOT/bin" \
    FM_PI_POCKET_DROPIN="$DROPIN" "$NODE" --test --test-concurrency=1 dropin.test.ts 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out" >&2
    fail "the drop-in's Pi Pocket tests failed (exit $rc)"
  fi
  pass "drop-in: first-request session start with the whole digest, lock binding, wake delivery, marker scope, seatbelts, held-back delivery, retry limit, turn-end guard, crash restart, and the supervision branch (one visible linked session, wake routing, outcomes on main, fallback to main incl. a past-deadline turn, restart without a duplicate) in a real Pi Pocket app"
}

test_install_copies_idempotently_and_skips_without_pi_pocket
test_install_if_installed_refreshes_only_an_existing_copy
test_dropin_in_pi_pocket
