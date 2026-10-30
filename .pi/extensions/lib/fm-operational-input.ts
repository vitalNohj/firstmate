import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { lstatSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const operationalInputScript =
  process.env.FM_OPERATIONAL_INPUT_SCRIPT ||
  resolve(dirname(fileURLToPath(import.meta.url)), "../../../bin/fm-operational-input.sh");

export const FIRSTMATE_CURRENT_OPERATIONAL_KINDS = [
  "session-start",
  "watcher",
  "turn-end-guard",
  "away-supervisor",
  "from-firstmate",
  "launch-brief",
  "branch-outcome",
] as const;

export type FirstmateCurrentOperationalKind =
  (typeof FIRSTMATE_CURRENT_OPERATIONAL_KINDS)[number];

type OperationalInputCommand = "encode" | "classify" | "kind";

export function firstmateShellInvocation(
  script: string,
  args: readonly string[],
): { command: string; args: string[] } {
  return process.platform === "win32"
    ? { command: "bash", args: [script, ...args] }
    : { command: script, args: [...args] };
}

// The one owner of how each command is invoked and how its exit status and
// stdout become an answer, shared by the synchronous and awaited callers
// below so the two can never drift.
function operationalInputArgs(
  command: OperationalInputCommand,
  kind?: FirstmateCurrentOperationalKind,
): string[] {
  return command === "encode" ? [command, kind ?? ""] : [command];
}

function operationalInputAnswer(
  command: OperationalInputCommand,
  status: number | null,
  stdout: string,
): string | undefined {
  if (status !== 0) return undefined;
  return command === "classify" ? stdout.replace(/\n$/, "") : stdout;
}

function runOperationalInputCommand(
  command: OperationalInputCommand,
  content: string,
  kind?: FirstmateCurrentOperationalKind,
): string | undefined {
  const invocation = firstmateShellInvocation(
    operationalInputScript,
    operationalInputArgs(command, kind),
  );
  try {
    const result = spawnSync(invocation.command, invocation.args, {
      encoding: "utf8",
      input: content,
      maxBuffer: 1024 * 1024,
    });
    return operationalInputAnswer(command, result.status, result.stdout ?? "");
  } catch {
    return undefined;
  }
}

function encodeFailure(kind: FirstmateCurrentOperationalKind): Error {
  return new Error(`could not encode Firstmate operational input kind ${kind}`);
}

export function encodeFirstmateOperationalInput(
  kind: FirstmateCurrentOperationalKind,
  content: string,
): string {
  const encoded = runOperationalInputCommand("encode", content, kind);
  if (encoded === undefined) throw encodeFailure(kind);
  return encoded;
}

// The supervision branch encodes on Pi's render thread while a captain
// outcome is being delivered, so that one caller must await the child rather
// than stop the TUI for it. It supplies the wait; everything that makes this
// an encode - the script, its argument shape, and how its exit status and
// stdout become an answer - stays owned here, so the two forms cannot drift.
// The runner is a parameter rather than an import so that every extension
// already carrying this module does not also have to carry a spawn helper it
// never calls.
export type OperationalInputRunner = (
  command: string,
  args: readonly string[],
  options: { input: string },
) => Promise<{ status: number | null; stdout: string }>;

export async function encodeFirstmateOperationalInputWith(
  run: OperationalInputRunner,
  kind: FirstmateCurrentOperationalKind,
  content: string,
): Promise<string> {
  const invocation = firstmateShellInvocation(
    operationalInputScript,
    operationalInputArgs("encode", kind),
  );
  const result = await run(invocation.command, invocation.args, { input: content });
  const encoded = operationalInputAnswer("encode", result.status, result.stdout);
  if (encoded === undefined) throw encodeFailure(kind);
  return encoded;
}

export function classifyFirstmateOperationalText(content: string): string | undefined {
  return runOperationalInputCommand("classify", content);
}

export function classifyFirstmateCurrentOperationalText(
  content: string,
): string | undefined {
  return runOperationalInputCommand("kind", content);
}

// The only legacy operational shape Calm presentation hides on top of the current
// typed kinds. The broader `classify` legacy set stays out: its bare forms are text a
// captain can type, so hiding them would hide real input.
const LEGACY_CALM_OPERATIONAL_PREFIX = "\u2063Supervisor escalate (";

// Single owner of "may Calm presentation hide this exact input?", shared by the
// transcript-row and queued-row adapters so the two can never disagree about a message.
// Text without the U+2063 marker answers here without spawning the classifier.
export function isFirstmateOperationalPresentationText(text: string): boolean {
  if (!text.includes("\u2063")) return false;
  return (
    classifyFirstmateCurrentOperationalText(text) !== undefined ||
    text.startsWith(LEGACY_CALM_OPERATIONAL_PREFIX)
  );
}

// Whether a live Pi Pocket conversation holds the lock in `stateDir`.
// bin/fm-session-lock-lib.sh owns the predicate (fm_session_lock_recorded_pi_pocket
// plus the holder still being alive). A Pi primary extension asks this before
// it treats an ancestor of its own pid as its lock: the Pi Pocket server is
// that ancestor for every process started from the session, and it is not
// this Pi process's session.
// A copied extension fixture does not carry bin/ with it. FM_ROOT_OVERRIDE
// is the real repo root those drivers already pass; otherwise the script
// sits next to this file, three directories up.
const sessionLockLib = resolve(
  process.env.FM_ROOT_OVERRIDE || resolve(dirname(fileURLToPath(import.meta.url)), "../../.."),
  "bin/fm-session-lock-lib.sh",
);
const pocketHoldSnippet = `
. "$1" || exit 2
if ! fm_session_lock_recorded_pi_pocket "$2"; then
  exit 1
fi
pid=$(head -n 1 "$2/.lock" 2>/dev/null || true)
fm_session_lock_holder_alive "$2" "$pid" || exit 3
`;

function pocketHoldArgs(stateDir: string): string[] {
  return ["-c", pocketHoldSnippet, "fm-pocket-lock", sessionLockLib, stateDir];
}

// Exit 1 means the lock is not a Pi Pocket record. That answer is reused
// only while `.lock` and `.lock-session` are byte-for-byte unchanged.
// Exit 0 and exit 3 are never reused: a recorded Pocket server can die, or
// a dead check can have raced a live one, without those files changing, and
// fm_session_lock_holder_alive is what notices. Ancestry is not part of
// this and is still walked on every ownership check. The reuse matters
// because flushMirror re-checks ownership after the branch can already see
// the delivered line, and a fresh bash in that gap publishes the mirror
// cursor too late for the observer that just saw the line.
let pocketMissCache: { key: string } | null = null;

function pocketLockSnapshot(stateDir: string): string | null {
  const parts: string[] = [];
  for (const name of [".lock", ".lock-session"]) {
    const path = `${stateDir}/${name}`;
    let info;
    try {
      info = lstatSync(path);
    } catch {
      parts.push(`${name}:absent`);
      continue;
    }
    if (info.isSymbolicLink()) return null;
    try {
      parts.push(`${name}:${readFileSync(path).toString("utf8")}`);
    } catch {
      return null;
    }
  }
  return parts.join("\0");
}

function pocketMissKey(stateDir: string, snapshot: string): string {
  return `${stateDir}\0${snapshot}`;
}

function rememberPocketMiss(stateDir: string, snapshot: string | null): void {
  if (snapshot === null) return;
  if (pocketLockSnapshot(stateDir) !== snapshot) return;
  pocketMissCache = { key: pocketMissKey(stateDir, snapshot) };
}

function pocketMissCached(stateDir: string): boolean {
  const snapshot = pocketLockSnapshot(stateDir);
  return snapshot !== null && pocketMissCache?.key === pocketMissKey(stateDir, snapshot);
}

export function piPocketHoldsLockSync(stateDir: string): boolean {
  if (pocketMissCached(stateDir)) return false;
  const snapshot = pocketLockSnapshot(stateDir);
  try {
    const status = spawnSync("bash", pocketHoldArgs(stateDir), { encoding: "utf8" }).status;
    if (status === 0) {
      pocketMissCache = null;
      return true;
    }
    if (status === 1) rememberPocketMiss(stateDir, snapshot);
    return false;
  } catch {
    return false;
  }
}

export function piPocketHoldsLock(stateDir: string): Promise<boolean> {
  if (pocketMissCached(stateDir)) return Promise.resolve(false);
  const snapshot = pocketLockSnapshot(stateDir);
  return new Promise((resolveHold) => {
    let child: ChildProcess;
    try {
      child = spawn("bash", pocketHoldArgs(stateDir), { stdio: "ignore" });
    } catch {
      resolveHold(false);
      return;
    }
    child.on("error", () => resolveHold(false));
    child.on("close", (code) => {
      if (code === 0) {
        pocketMissCache = null;
        resolveHold(true);
        return;
      }
      if (code === 1) rememberPocketMiss(stateDir, snapshot);
      resolveHold(false);
    });
  });
}
