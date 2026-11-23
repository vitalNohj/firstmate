#!/usr/bin/env bash
# runner-owner.sh pi-pocket-runner-v1 claim <home> <installation-uuid> <home-uuid>
#     <conversation> <generation-uuid> [<exact previous owner line>]
# Claim the runner home's native lock slot and run its bounded startup preview.
# Print a status line followed by an owner line (held) or digest (started).
# Only pass a previous owner line for an observed archive or an explicit handoff.
#
# runner-owner.sh pi-pocket-runner-v1 <poll|verify|drain|ack|inbox-read|inbox-reply|inbox-ack|read>
#     <home> <installation-uuid> <home-uuid> <conversation> <generation-uuid> [<operation args>...]
# Verify the settled claim and delegate one finite operation while holding the claim mutex.
#
# runner-owner.sh pi-pocket-runner-v1 recover <home> <installation-uuid> <home-uuid>
#     <conversation> <generation-uuid>
# Attended recovery only: verify locally that all startup work has stopped
# before using this on the exact interrupted owner. Not a normal release path.
set -eu
umask 077

version=pi-pocket-runner-v1
[ "$#" -ge 7 ] && [ "$#" -le 10 ] && [ "$1" = "$version" ] || exit 2
operation=$2
home=$3
installation=$4
home_id=$5
conversation=$6
generation=$7
shift 7
previous=
case "$operation" in
  claim) [ "$#" -le 1 ] || exit 2; previous=${1:-} ;;
  recover) [ "$#" -eq 0 ] || exit 2 ;;
  poll|verify|drain|ack|inbox-read|inbox-reply|inbox-ack|read|branch-*) ;;
  *) exit 2 ;;
esac

refuse() {
  printf '%s\n' "$1"
  [ "$operation" != recover ] || exit 1
  exit 0
}
root=$(builtin cd -P -- "${BASH_SOURCE[0]%/*}/.." && pwd -P)
[ "$root" = "$home" ] && [ "$home" = "$(pwd -P)" ] || refuse invalid-home
[ ! -e "$home/.fm-secondmate-home" ] && [ ! -L "$home/.fm-secondmate-home" ] || refuse invalid-home
for name in .git bin config; do
  [ -d "$home/$name" ] && [ ! -L "$home/$name" ] || refuse invalid-home
done
for name in state data; do
  if [ -L "$home/$name" ] || { [ -e "$home/$name" ] && [ ! -d "$home/$name" ]; }; then
    refuse invalid-home
  fi
done
for name in bin/fm-session-lock-lib.sh bin/fm-wake-lib.sh bin/fm-session-start.sh bin/fm-bootstrap.sh config/pi-pocket-home-id; do
  [ -f "$home/$name" ] && [ ! -L "$home/$name" ] || refuse invalid-home
done
if [ "$operation" = claim ]; then
  if ! grep -Fqx "# Pocket runner startup contract: $version" "$home/bin/fm-session-start.sh" \
    || ! grep -Fqx "# Pocket runner startup contract: $version" "$home/bin/fm-bootstrap.sh"; then
    refuse invalid-home
  fi
fi

# Do not let a runner's inherited Firstmate or Git overrides select another
# home, state directory, harness, timeout, or checkout for this one operation.
unset "${!FM_@}" GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR
export FM_HOME="$home"
STATE="$home/state"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$home/bin/fm-session-lock-lib.sh"
declare -F fm_pocket_runner_lock_record >/dev/null || refuse invalid-home
fm_pocket_runner_uuid "$installation" && fm_pocket_runner_uuid "$home_id" && fm_pocket_runner_uuid "$generation" \
  && [[ "$conversation" =~ ^[A-Za-z0-9._:-]{1,128}$ ]] || exit 2
valid_marker() {
  [ -f "$home/config/pi-pocket-home-id" ] && [ ! -L "$home/config/pi-pocket-home-id" ] \
    && [ "$(head -c 65 "$home/config/pi-pocket-home-id" | tr 'A-F' 'a-f')" = "$home_id" ]
}
valid_marker || refuse invalid-home
# shellcheck source=bin/fm-wake-lib.sh
. "$home/bin/fm-wake-lib.sh"

lock="$STATE/.lock"
mutex="$STATE/.lock.acquire"
owner_line="$version"$'\t'"$installation"$'\t'"$home_id"$'\t'"$conversation"$'\t'"$generation"

# The shared mutex uses a symlink to an adjacent private owner directory. Do
# not send the library into a foreign or malformed target during stale cleanup.
valid_mutex_path() {
  local path=$1 target suffix
  if [ -L "$path" ]; then
    target=$(readlink "$path") || return 1
    suffix=${target#"$path.owner."}
    [ "$target" != "$suffix" ] && [[ "$suffix" =~ ^[A-Za-z0-9._-]+$ ]] \
      && [ -d "$target" ] && [ ! -L "$target" ] \
      && [ ! -L "$target/pid" ] && { [ ! -e "$target/pid" ] || [ -f "$target/pid" ]; } \
      && [ ! -L "$target/pid-start" ] && { [ ! -e "$target/pid-start" ] || [ -f "$target/pid-start" ]; }
  else
    [ ! -e "$path" ]
  fi
}
if ! valid_mutex_path "$mutex" || ! valid_mutex_path "$mutex.steal"; then
  refuse busy
fi
case "$operation" in
  recover|poll) fm_lock_try_acquire "$mutex" || refuse busy ;;
  # Let a finite poll finish before claiming or comparing a predecessor.
  *) fm_lock_acquire_wait_bounded "$mutex" 2 || refuse busy ;;
esac
stage_dir=
cleanup() {
  if [ -n "$stage_dir" ]; then
    rm -f "$stage_dir/owner"
    rmdir "$stage_dir" 2>/dev/null || true
  fi
  fm_lock_release "$mutex"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

retire() {
  local old=$1 old_generation=${1##*$'\t'}
  local retired="$STATE/.lock.runner-retired-$old_generation"
  [ "$(fm_pocket_runner_lock_record "$STATE")" = "$old" ] || refuse changed
  [ ! -e "$retired" ] && [ ! -L "$retired" ] || refuse changed
  mv "$lock" "$retired" || refuse unavailable
}

settled() {
  [ -f "$lock/settled" ] && [ ! -L "$lock/settled" ] \
    && cmp -s "$lock/settled" <(printf '%s\n' "$1")
}

valid_marker || refuse invalid-home
if [ "$operation" != claim ] && [ "$operation" != recover ]; then
  [ "$(fm_pocket_runner_lock_record "$STATE")" = "$owner_line" ] || refuse changed
  settled "$generation" && [ -f "$lock/digest" ] && [ ! -L "$lock/digest" ] || refuse incomplete
  monitor="$home/pi-pocket/runner-monitor.sh"
  case "$operation" in
    branch-*) monitor="$home/pi-pocket/runner-supervision.sh" ;;
  esac
  [ -f "$monitor" ] && [ ! -L "$monitor" ] || refuse unavailable
  export FM_POCKET_RUNNER_COMMAND="$generation" FM_POCKET_RUNNER_HELPER_PID="$$"
  # Keep the holder in the child's ancestry until the operation finishes.
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$home/bin/fm-timeout-lib.sh"
  fm_run_timed 8 bash "$monitor" "$operation" "$@"
  exit "$?"
fi

retire_dead_legacy() {
  command -v node >/dev/null 2>&1 || return 1
  node - "$lock" <<'JS'
const fs = require('node:fs');
const { randomUUID } = require('node:crypto');
const path = process.argv[2];
if (!['linux', 'darwin'].includes(process.platform)) process.exit(1);
const { O_RDONLY, O_NOFOLLOW, O_NONBLOCK } = fs.constants;
function snapshot() {
  const fd = fs.openSync(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
  try {
    const stat = fs.fstatSync(fd, { bigint: true });
    if (!stat.isFile() || stat.size < 2n || stat.size > 11n) throw Error('not a native PID file');
    const bytes = Buffer.alloc(12);
    const n = fs.readSync(fd, bytes, 0, bytes.length, 0);
    return { stat, bytes: bytes.subarray(0, n) };
  } finally { fs.closeSync(fd); }
}
function gone(pid) {
  try { process.kill(pid, 0); return false; } catch (error) { return error.code === 'ESRCH'; }
}
try {
  const before = snapshot();
  const pidText = before.bytes.toString('latin1');
  if (!/^[1-9][0-9]{0,9}\n$/.test(pidText)) process.exit(1);
  const pid = Number(pidText);
  if (pid > 2147483647 || !gone(pid)) process.exit(1);
  const after = snapshot();
  if (!before.bytes.equals(after.bytes) || !['dev', 'ino', 'ctimeNs', 'mtimeNs', 'size'].every(k => before.stat[k] === after.stat[k]) || !gone(pid)) process.exit(1);
  const stamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d{3}Z$/, 'Z');
  const suffix = `.legacy-dead-${stamp}.${randomUUID()}`;
  // Reserve a unique sibling without replacing any existing entry.
  fs.closeSync(fs.openSync(path + suffix, 'wx', 0o600));
  try { fs.renameSync(path, path + suffix); } catch (error) { fs.unlinkSync(path + suffix); throw error; }
  process.stdout.write(`.lock${suffix}`);
} catch { process.exit(1); }
JS
}
legacy=
if [ "$operation" = claim ] && [ -z "$previous" ] && [ -f "$lock" ] && [ ! -L "$lock" ]; then
  [ ! -e "$STATE/.lock.runner-retired-$generation" ] && [ ! -L "$STATE/.lock.runner-retired-$generation" ] || refuse retired
  legacy=$(retire_dead_legacy) || refuse foreign
fi

if [ -e "$lock" ] || [ -L "$lock" ]; then
  owner=$(fm_pocket_runner_lock_record "$STATE") || refuse foreign
  if [ "$operation" = recover ]; then
    [ "$owner" = "$owner_line" ] || refuse changed
    settled "$generation" && refuse changed
    retire "$owner"
    printf 'recovered\n'
    exit 0
  fi
  if [ "$owner" = "$owner_line" ]; then
    settled "$generation" && [ -f "$lock/digest" ] && [ ! -L "$lock/digest" ] || refuse incomplete
    printf 'started\n'
    head -c 49152 "$lock/digest"
    exit 0
  fi
  if [ "$owner" != "$previous" ]; then
    printf 'held\n%s\n' "$owner"
    exit 0
  fi
  # Never retire another installation's lock, even with a supplied old record.
  case "$owner" in "$version"$'\t'"$installation"$'\t'"$home_id"$'\t'*) ;; *) refuse foreign ;; esac
  settled "${owner##*$'\t'}" || refuse incomplete
elif [ "$operation" = recover ] || [ -n "$previous" ]; then
  refuse changed
fi

[ ! -e "$STATE/.lock.runner-retired-$generation" ] && [ ! -L "$STATE/.lock.runner-retired-$generation" ] || refuse retired
stage_dir=$(mktemp -d "$STATE/.lock.runner-stage.XXXXXX") || refuse unavailable
printf '%s\n' "$owner_line" > "$stage_dir/owner" || refuse unavailable
[ -z "$previous" ] || retire "$previous"
# The claim mutex serializes this rename with native PID-lock publication and
# every other runner claimant. Publishing the owner also records the attempt.
mv "$stage_dir" "$lock" || refuse unavailable
stage_dir=
export FM_POCKET_RUNNER_START="$generation" FM_POCKET_RUNNER_HELPER_PID="$$" FM_SESSION_START_TIMEOUT=80
# Consume the entire stream even after reaching the storage limit. Closing the
# pipe early would turn a partial digest into a spurious startup failure.
"$home/bin/fm-session-start.sh" --source pi-pocket-runner 2>&1 | {
  # Keep the backup name in the startup receipt even if the link drops.
  report=
  if [ -n "$legacy" ]; then
    report="Saved dead legacy lock: $legacy"
    printf '%s\n' "$report"
  fi
  head -c "$((49152 - ${#report} - (${#report} > 0)))"
  cat >/dev/null
} > "$lock/digest.pending" || refuse incomplete
# A pipe's success is not the startup's success. Record quiescence separately
# from its receipt; missing proof remains incomplete even if its PID is gone.
startup_status=${PIPESTATUS[0]}
case "$startup_status" in
  0|73) printf '%s\n' "$generation" > "$lock/settled" || refuse incomplete ;;
  *) refuse incomplete ;;
esac
[ "$startup_status" -eq 0 ] || refuse incomplete
mv "$lock/digest.pending" "$lock/digest" || refuse incomplete
printf 'started\n'
head -c 49152 "$lock/digest"
