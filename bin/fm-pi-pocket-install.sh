#!/usr/bin/env bash
# Install the Firstmate Pi Pocket drop-in (pi-pocket/firstmate.ts) into a Pi
# Pocket data directory's extensions folder.
#
# The drop-in is COPIED, never symlinked: Node resolves a module's imports from
# its real path, and only the extensions folder links Pi Pocket's own packages.
# The copy is atomic and idempotent: an identical installed copy is left alone.
# Without a Pi Pocket checkout the script skips cleanly and changes nothing.
#
# It never restarts Pi Pocket. A new drop-in shows up in Menu -> Extensions,
# off until the owner turns it on; a changed one reloads on its own, and a
# server restart is only needed if the reload reports a problem.
#
# Usage: fm-pi-pocket-install.sh [--if-installed]
#   --if-installed  refresh an existing install only; with no installed copy it
#                   skips and changes nothing. bin/fm-update.sh runs this after
#                   every update, so an installed drop-in follows the code.
#
# Environment:
#   PI_POCKET_DIR          Pi Pocket's data directory (default ~/.pi-pocket),
#                          the same variable Pi Pocket itself reads.
#   FM_PI_POCKET_CHECKOUT  the Pi Pocket checkout whose presence enables the
#                          install (default ~/pi-pocket).
#
# Exit 0 when installed, already up to date, or skipped; 1 on a copy failure.
set -u

case "${1:-}" in
  -h|--help)
    sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  --if-installed) IF_INSTALLED=1 ;;
  '') ;;
  *)
    echo "error: unknown argument: $1 (see --help)" >&2
    exit 1
    ;;
esac

[ $# -le 1 ] || {
  echo "error: unexpected argument: $2 (see --help)" >&2
  exit 1
}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$SCRIPT_DIR/../pi-pocket/firstmate.ts"
CHECKOUT=${FM_PI_POCKET_CHECKOUT:-$HOME/pi-pocket}
DATA_DIR=${PI_POCKET_DIR:-$HOME/.pi-pocket}
TARGET_DIR="$DATA_DIR/extensions"
TARGET="$TARGET_DIR/firstmate.ts"

if [ "${IF_INSTALLED:-0}" = 1 ] && [ ! -e "$TARGET" ] && [ ! -L "$TARGET" ]; then
  echo "pi-pocket: skipped - no installed drop-in at $TARGET"
  exit 0
fi
if [ ! -d "$CHECKOUT" ]; then
  echo "pi-pocket: skipped - no Pi Pocket checkout at $CHECKOUT"
  exit 0
fi
if [ ! -f "$SOURCE" ]; then
  echo "error: the drop-in is missing at $SOURCE" >&2
  exit 1
fi

if [ -f "$TARGET" ] && [ ! -L "$TARGET" ] && cmp -s "$SOURCE" "$TARGET"; then
  echo "pi-pocket: up to date - $TARGET"
  exit 0
fi

existed=0
[ -e "$TARGET" ] || [ -L "$TARGET" ] && existed=1
mkdir -p "$TARGET_DIR" || {
  echo "error: cannot create $TARGET_DIR" >&2
  exit 1
}
tmp=$(mktemp "$TARGET_DIR/.firstmate.ts.XXXXXX") || {
  echo "error: cannot write in $TARGET_DIR" >&2
  exit 1
}
if ! cp "$SOURCE" "$tmp" || ! chmod 0644 "$tmp" || ! mv -f "$tmp" "$TARGET"; then
  rm -f "$tmp"
  echo "error: cannot install $TARGET" >&2
  exit 1
fi

if [ "$existed" -eq 1 ]; then
  echo "pi-pocket: updated - $TARGET; Pi Pocket reloads it on its own; restart Pi Pocket only if the reload reports a problem"
else
  echo "pi-pocket: installed - $TARGET; turn on Firstmate in Pi Pocket's Menu -> Extensions"
fi
