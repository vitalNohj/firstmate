/**
 * Firstmate: runs a Firstmate primary's main chat inside Pi Pocket. In a session whose folder is a Firstmate home it
 * marks every bash call with the session's Pi Pocket identity, keeps the watcher running as a durable background task
 * once the session holds the home's lock, delivers each watcher wake as a follow-up, guards turn ends and tool calls
 * the way Firstmate's Pi extensions do, and offers the fm_watch_arm_pocket repair tool. Once the session holds the
 * lock it also starts the supervision branch: one linked Pi Pocket session per home, titled "Firstmate supervision",
 * that takes the routine wakes it may handle and records their outcomes in the durable store, which reach the main
 * session as processing requests (docs/pi-supervision-branch.md "Pi Pocket"). Every other session is untouched.
 * Install it with Firstmate's bin/fm-pi-pocket-install.sh, then turn it on in Menu → Extensions.
 * Where Pi Pocket can present an extension's own inputs, /calm folds this session's operational inputs; the model still
 * reads each one in full, and the supervision session's own prompts stay ordinary messages.
 */
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { mkdir, readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { Type } from "@earendil-works/pi-ai";
import {
    AgentDoc,
    defineExtension,
    defineTask,
    defineTool,
    GenerationTask,
    hook,
    section,
    ToolTask,
    wrapSection,
    wrapTool,
} from "@earendil-works/pi-durable";
import type { Context } from "@earendil-works/chord";
import type { ConversationHandle, ConversationId, HookApi, ToolExecutionApi, TaskRuntime, Tx } from "@earendil-works/pi-durable";
import { createBashTool } from "@earendil-works/pi-durable/tools";
import type { Host } from "./_pocket.d.ts";

// Tools return `output`: version 2 of Pi Pocket's extension API.
export const pocketApi = 2;

/** The Pi Pocket server process: the lock anchor of every session it serves (part 1's marker contract). */
const SERVER_PID = String(process.pid);
/** One server process: a watcher task created under another one was re-driven by a restart. */
const BOOT = `${process.pid}-${Math.round(performance.timeOrigin)}`;
const WATCH_KIND = "x.firstmate.watch";
const REPAIR_TOOL = "fm_watch_arm_pocket";
const SESSION_PREFIX = "pi-pocket:";
const OPERATIONAL_PREFIX = "\u2063FIRSTMATE_OP: v1 ";
const COMPACTED = "The conversation history before this point was compacted into the following summary:";
const DIGEST_LIMIT = 512 * 1024;
const DIGEST_TRUNCATED =
    "\n\nPI POCKET SESSION-START DELIVERY TRUNCATED - the digest exceeded 512 KiB. Treat omitted context as unread and inspect the named files directly before acting on it.";
const MANUAL_START = "Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.";
/** The entry a fresh conversation's session-start digest is placed as, ahead of the model's first answer. */
const START_KIND = "x.firstmate.session-start";
/** Main-conversation submits, when Pi Pocket can present an extension's own inputs. Stored kinds are forever. */
const OPERATIONAL_KIND = "x.firstmate.operational";
const PRESENTATION_LABEL = "Firstmate";
/** The shell model, stated because models trained on a persistent shell otherwise prefix a defensive cd. */
const SHELL_MODEL = "Every bash call starts a new shell in this conversation's working directory; a cd never carries over to the next call.";
const GUARD_HEADER =
    "TURN WOULD END BLIND - supervision is off. The watcher cycle is missing, failed, or unhealthy. Follow the harness recovery instruction below before ending the turn.\n\n";

/** Pi Pocket's own tools that start or steer work outside the fleet (protocol step 8: delegate only via bin/fm-spawn.sh). */
const POCKET_DELEGATION = new Set([
    "subagent",
    "team",
    "schedule",
    "session_start",
    "session_send",
    "session_schedule",
    "session_watch_pr",
    "watch_pr",
    "repo_watch",
]);
/** Coding tools the delegation script never matches: no script run for them. */
const CODING_TOOLS = new Set(["read", "write", "edit", "bash"]);

/** The supervision branch: its title in Pi Pocket's session list, its tools, and the tools main uses for its outcomes. */
const BRANCH_TITLE = "Firstmate supervision";
const REPORT_TOOL = "fm_branch_report";
const OUTCOMES_TOOL = "fm_branch_outcomes";
const PROCESSED_TOOL = "fm_branch_processed";
/**
 * Context tools from the billion-context Pi Pocket extension. They only manage this session's own context and never
 * touch fleet state, so the branch may use them; every other tool stays blocked.
 */
const CONTEXT_TOOLS = ["compress", "decompress", "search_context", "acp_status", "acp_cache"] as const;
const BRANCH_TOOLS = new Set(["read", "bash", REPORT_TOOL, ...CONTEXT_TOOLS]);
/** The branch's first message, before any wake: it only has to wait, and it may manage its own context. */
const BRANCH_INTRO =
    "This is the Firstmate supervision session for this home. The Firstmate drop-in sends it each routine fleet wake the main Firstmate session hands over. Nothing to do until the first wake: reply only with \"ready\". You may use read, bash, fm_branch_report, and the context tools compress, decompress, search_context, acp_status, and acp_cache, which only manage this session's own context.";
/** State files the drop-in owns, under the home's state directory (operational-home-layout). */
const BRANCH_RECORD = ".pocket-branch";
const BRANCH_TURN = ".pocket-branch-turn";
const BRANCH_PROCESSING = ".pocket-branch-processing";
const MIRROR_CURSOR = ".pocket-branch-mirror";
const MIRROR_FEED = ".pocket-branch-mirror-feed";
/** The dialog mirror's bounds: per entry, per wake, and for a branch that has seen nothing of this main session yet. */
const MIRROR_ENTRY_CHARS = 4000;
const MIRROR_ITEMS = 40;
const MIRROR_FRESH_ITEMS = 12;
/** Consecutive branch failures that latch it off, and the cooling-off period, which doubles up to its maximum. */
const LATCH_THRESHOLD = 2;
const LATCH_BASE_MS = 5 * 60 * 1000;
const LATCH_MAX_MS = 60 * 60 * 1000;
/** Pi thinking levels, used when the host does not list them. The branch extension owns the same vocabulary. */
const THINKING_LEVELS = ["off", "minimal", "low", "medium", "high", "xhigh", "max"] as const;
/**
 * No listed model can be used. The notice names the fix: Pi Pocket's list for subagents and linked sessions.
 */
const MODEL_LIST_NOTICE =
    "Firstmate could not start its supervision session, so wakes go to this session until it can: add a model to Pi Pocket's list for subagents and linked sessions.";
// The Pi branch's processing request, word for word (.pi/extensions/fm-branch-supervision.ts), so main processes
// a Pi Pocket branch's outcomes under the same contract.
const PROCESSING_INSTRUCTION =
    "This is a supervision processing request delivered automatically by the supervision branch. " +
    "It was not typed by the captain. " +
    "The outcomes below are stored durably, and each was recorded earlier, possibly before a restart or a switch of primary, so the captain may already have seen it and it may already have been handled; each fleet event is already handled, so do not re-drain, re-run, or acknowledge the wake. " +
    "Each outcome says what was true when it was recorded and how long ago, so check the task's current state first. " +
    "An abbreviated line is incomplete: read the full outcome before acting on, relaying, or acknowledging it, using that line's lookup --seqs command. " +
    "First sort the outcomes by that current state into still open and already settled, such as a decision since answered, a PR since merged, or a task since finished. " +
    "Your reply to the captain covers only the still-open outcomes: give the captain a visible response where one is due, answer or escalate a decision, or act on a blocker or failure. " +
    "Write that reply as if the settled outcomes had never been listed: leave them out entirely, without naming them, summarizing them, or saying they are settled, because checking them is all the processing they need. " +
    "When every outcome below is processed, call fm_branch_processed with through={N} exactly once. " +
    "Until that call the outcomes stay open and are presented again; an answer that does not make that call never counts as processing.";

function positive(name: string, fallback: number): number {
    const value = Number(process.env[name]);
    return Number.isFinite(value) && value > 0 ? value : fallback;
}

const RETRY_BASE_MS = positive("FM_WATCH_REARM_RETRY_BASE_MS", 250);
const RETRY_MAX_MS = positive("FM_WATCH_REARM_RETRY_MAX_MS", 4000);
const RETRY_LIMIT = positive("FM_WATCH_REARM_RETRY_LIMIT", 5);
const READY_TIMEOUT_MS = positive("FM_WATCH_ARM_READY_TIMEOUT_MS", 12000);
const RETIRE_TIMEOUT_MS = 1000;
/** How long a held-back delivery waits before it asks again, when no limit change wakes it first. */
const HELD_RECHECK_MS = positive("FM_POCKET_HELD_RECHECK_MS", 30000);
/** How long one branch turn may run before its wake goes to main instead. */
const BRANCH_TURN_TIMEOUT_MS = positive("FM_POCKET_BRANCH_TURN_TIMEOUT_MS", 20 * 60 * 1000);

// ---------------------------------------------------------------------------------------------------------------
// Processes

type Ran = { code: number | null; signal: NodeJS.Signals | null; stdout: string; stderr: string };

/** Run a command to its end without blocking the server; a failure to start is code null. */
function run(
    command: string,
    args: readonly string[],
    options: { cwd: string; env?: Record<string, string>; input?: string; limit?: number },
): Promise<Ran> {
    const limit = options.limit ?? 1024 * 1024;

    return new Promise((resolve) => {
        let stdout = "";
        let stderr = "";
        const child = spawn(command, args, {
            cwd: options.cwd,
            env: { ...process.env, ...options.env },
            stdio: ["pipe", "pipe", "pipe"],
        });
        child.stdout.on("data", (chunk: Buffer) => {
            if (stdout.length <= limit) stdout += chunk.toString();
        });
        child.stderr.on("data", (chunk: Buffer) => {
            if (stderr.length <= limit) stderr += chunk.toString();
        });
        child.on("error", (error) => resolve({ code: null, signal: null, stdout, stderr: `${stderr}${error.message}` }));
        child.on("close", (code, signal) => resolve({ code, signal, stdout, stderr }));
        child.stdin.on("error", () => {});
        child.stdin.end(options.input ?? "");
    });
}

/** The marker of part 1: this conversation, served by this server, so bin/fm-lock.sh can bind the lock to it. */
function markerEnv(home: string, conversationId: ConversationId): Record<string, string> {
    return { FM_HOME: home, FM_PI_POCKET_CONVERSATION: String(conversationId), FM_PI_POCKET_SERVER_PID: SERVER_PID };
}

function signalsOf(...signals: (AbortSignal | undefined)[]): AbortSignal {
    return AbortSignal.any(signals.filter((signal): signal is AbortSignal => signal !== undefined));
}

function pause(ms: number, signal: AbortSignal): Promise<void> {
    signal.throwIfAborted();

    return new Promise((resolve, reject) => {
        const stop = () => {
            clearTimeout(timer);
            reject(signal.reason);
        };
        const timer = setTimeout(() => {
            signal.removeEventListener("abort", stop);
            resolve();
        }, ms);
        signal.addEventListener("abort", stop, { once: true });
    });
}

// ---------------------------------------------------------------------------------------------------------------
// Firstmate homes and the session lock

async function isFile(path: string): Promise<boolean> {
    return (await stat(path).catch(() => undefined))?.isFile() === true;
}

/**
 * The Firstmate home a session works in, or undefined: a primary checkout (its own .git directory, not a linked
 * worktree) or a secondmate home, with Firstmate's AGENTS.md and session start. Firstmate's scripts check the full
 * primary scope themselves.
 */
async function homeOf(cwd: string | undefined): Promise<string | undefined> {
    if (cwd === undefined || cwd === "") return undefined;
    if (!(await isFile(join(cwd, "AGENTS.md"))) || !(await isFile(join(cwd, "bin", "fm-session-start.sh")))) {
        return undefined;
    }
    const git = await stat(join(cwd, ".git")).catch(() => undefined);

    return git?.isDirectory() === true || (await isFile(join(cwd, ".fm-secondmate-home"))) ? cwd : undefined;
}

type Ownership = "owned" | "other" | "missing";

function alive(pid: number): boolean {
    try {
        process.kill(pid, 0);
        return true;
    } catch (error) {
        return (error as NodeJS.ErrnoException).code === "EPERM";
    }
}

async function firstLine(path: string): Promise<string> {
    return ((await readFile(path, "utf8").catch(() => "")).split("\n")[0] ?? "").trim();
}

/** The same state directory bin/fm-lock.sh binds, which the scripts the drop-in runs inherit from the server. */
function stateOf(home: string): string {
    return process.env.FM_STATE_OVERRIDE || join(home, "state");
}

/** Owned when the lock names this server and its sidecar this conversation, as fm_session_lock_owned_by_self decides. */
async function ownership(home: string, conversationId: ConversationId): Promise<Ownership> {
    const state = stateOf(home);
    const pid = Number(await firstLine(join(state, ".lock")));
    if (!Number.isInteger(pid) || pid <= 1 || !alive(pid)) return "missing";
    const session = await firstLine(join(state, ".lock-session"));

    return String(pid) === SERVER_PID && session === `${SESSION_PREFIX}${String(conversationId)}` ? "owned" : "other";
}

// ---------------------------------------------------------------------------------------------------------------
// Firstmate text

/** The wire form of an operational input, by its one owner bin/fm-operational-input.sh; plain text if that fails. */
async function encode(home: string, kind: string, body: string): Promise<string> {
    const ran = await run(join(home, "bin", "fm-operational-input.sh"), ["encode", kind], {
        cwd: home,
        env: { FM_HOME: home },
        input: body,
    });

    return ran.code === 0 && ran.stdout !== "" ? ran.stdout : body;
}

function wakeText(message: string): string {
    return `FIRSTMATE WATCHER WAKE: ${message}\n\nRun bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is owned by the Firstmate Pi Pocket drop-in.`;
}

/** Run the session start for `source` as this conversation, and shape its digest as a session-start input. */
async function sessionStart(home: string, conversationId: ConversationId, source: "startup" | "compact"): Promise<string> {
    const ran = await run(join(home, "bin", "fm-sessionstart-run.sh"), ["--source", source], {
        cwd: home,
        env: markerEnv(home, conversationId),
        limit: DIGEST_LIMIT + 1,
    });
    let digest = ran.code === 0 ? ran.stdout : "";
    if (digest.trim() === "") return encode(home, "session-start", MANUAL_START);
    if (digest.length > DIGEST_LIMIT) digest = `${digest.slice(0, DIGEST_LIMIT)}${DIGEST_TRUNCATED}`;

    return digest.startsWith(OPERATIONAL_PREFIX) ? digest : encode(home, "session-start", digest);
}

/**
 * The submit entry for a main-conversation operational input. Absent when this Pi Pocket cannot present one: passing
 * `entry` there stores a kind the transcript drops, which would hide the wake.
 */
function mainEntry(presented: boolean, summary: string): { entry?: { kind: string; data: { summary: string } } } {
    if (!presented) return {};

    return { entry: { kind: OPERATIONAL_KIND, data: { summary } } };
}

function pendingSummary(pending: Pending): string {
    if (pending.kind === "digest") return "session-start";
    if (pending.kind === "outcomes") return "branch-outcome";

    return "watcher";
}

/** The chip's summary for a watcher failure: the failure line's first words, not the envelope. */
function failureSummary(failure: string): string {
    const line = failure.split("\n")[0]?.replace(/\s+/g, " ").trim() ?? "";

    return line === "" ? "watcher" : line;
}

/** `config/calm`, or `FM_CONFIG_OVERRIDE` when a test points the config directory elsewhere. */
function calmPath(home: string): string {
    return join(process.env.FM_CONFIG_OVERRIDE || join(home, "config"), "calm");
}

/** `on` and the legacy `max` are on. Anything else, including a missing file, is off. */
async function calmOn(home: string): Promise<boolean> {
    try {
        const stored = (await readFile(calmPath(home), "utf8")).trim();

        return stored === "on" || stored === "max";
    } catch {
        return false;
    }
}

/** The same temp-file rename and mode the Pi Calm extension uses, so a failed write leaves the file as it was. */
async function writeCalm(home: string, active: boolean): Promise<void> {
    const path = calmPath(home);
    await mkdir(dirname(path), { recursive: true });
    const temporary = `${path}.${process.pid}.${randomUUID()}.tmp`;
    try {
        await writeFile(temporary, active ? "on\n" : "off\n", { encoding: "utf8", flag: "wx", mode: 0o600 });
        await rename(temporary, path);
    } finally {
        await rm(temporary, { force: true });
    }
}

/** A PreToolUse seatbelt's deny reason: the Claude-shaped JSON's systemMessage, else its stderr. */
function denyReason(stderr: string, fallback: string): string {
    const text = stderr.trim();
    for (const line of text.split("\n")) {
        try {
            const parsed = JSON.parse(line) as { systemMessage?: unknown };
            if (typeof parsed.systemMessage === "string" && parsed.systemMessage !== "") return parsed.systemMessage;
        } catch {
            // Not JSON: the raw text below.
        }
    }

    return text === "" ? fallback : text;
}

async function seatbelt(home: string, script: string, args: string[], fallback: string): Promise<string | undefined> {
    const ran = await run(join(home, "bin", script), args, { cwd: home, env: { FM_HOME: home } });

    return ran.code === 2 ? denyReason(ran.stderr, fallback) : undefined;
}

function userText(message: { role: string; content: unknown } | undefined): string {
    if (message?.role !== "user") return "";
    if (typeof message.content === "string") return message.content;
    if (!Array.isArray(message.content)) return "";

    return (message.content as { type?: string; text?: string }[])
        .map((part) => (part.type === "text" ? (part.text ?? "") : ""))
        .join("");
}

// ---------------------------------------------------------------------------------------------------------------
// Durable records

async function readJson<T>(path: string): Promise<T | undefined> {
    try {
        return JSON.parse(await readFile(path, "utf8")) as T;
    } catch {
        return undefined;
    }
}

/** Replace `path` whole, owner-only: a write that fails or is interrupted leaves the old record. */
async function writeJson(path: string, value: unknown): Promise<void> {
    const staged = `${path}.tmp-${SERVER_PID}`;
    await writeFile(staged, `${JSON.stringify(value)}\n`, { mode: 0o600 });
    await rename(staged, path);
}

function jsonLines(text: string): Record<string, unknown>[] | undefined {
    const rows: Record<string, unknown>[] = [];
    for (const line of text.split("\n")) {
        if (line.trim() === "") continue;
        try {
            const row = JSON.parse(line) as unknown;
            if (row === null || typeof row !== "object") return undefined;
            rows.push(row as Record<string, unknown>);
        } catch {
            return undefined;
        }
    }

    return rows;
}

const say = (text: string, isError = false) => ({ output: [{ type: "text" as const, text }], ...(isError ? { isError } : {}) });

// ---------------------------------------------------------------------------------------------------------------
// The supervision branch

/**
 * The pairing of this home's main session with its supervision branch, in state/.pocket-branch. `start` numbers the
 * branch starts for this main session, which keys Pi Pocket's idempotent start: a retried start returns the same
 * session, and a branch the captain deleted is replaced by a new one.
 */
type BranchRecord = {
    main: number;
    branch: number;
    start: number;
    /**
     * Set while a start is under way, before Pi Pocket names the new session: every session in the home but main is
     * then treated as the branch, so the new session's first turn never runs under main's supervisor contract.
     */
    starting?: boolean;
};

/** The branch turn handling one wake, in state/.pocket-branch-turn, so a restart resumes it instead of starting another. */
type BranchTurn = {
    /** The wake's own request id, which names the turn. */
    wake: string;
    branch: number;
    /** The branch input's request id: a resumed turn finds the submission it made. */
    request: string;
    /** The queue rows granted to the branch, and the tasks it may report on unless the claim is unscoped. */
    rows: string[];
    tasks: string[];
    unscoped: boolean;
    prompt: string;
    /** Where main's dialog mirror stands once this turn records an outcome. */
    mirror: MirrorCursor;
    started: number;
    /** The outcome sequences fm_branch_report recorded for this turn. */
    reports: number[];
};

/** The newest main-session transcript entry the branch has been shown, in state/.pocket-branch-mirror. */
type MirrorCursor = { main: number; entry: number };

/** The captain outcomes main was last asked to process, in state/.pocket-branch-processing. */
type Processing = { main: number; through: number };

async function branchRecord(home: string): Promise<BranchRecord | undefined> {
    const record = await readJson<BranchRecord>(join(stateOf(home), BRANCH_RECORD));

    return Number.isSafeInteger(record?.main) && Number.isSafeInteger(record?.branch) ? record : undefined;
}

const branchPrompts = new Map<string, Promise<string>>();

/** The branch's system prompt, byte-stable per Firstmate version, from its one owner bin/fm-branch-prompt.sh. */
function branchPrompt(home: string): Promise<string> {
    let prompt = branchPrompts.get(home);
    if (prompt === undefined) {
        prompt = run("bash", [join(home, "bin", "fm-branch-prompt.sh")], { cwd: home, env: { FM_HOME: home }, limit: 4 * 1024 * 1024 }).then((ran) => {
            if (ran.code === 0 && ran.stdout.length >= 1024) return ran.stdout;
            branchPrompts.delete(home);

            return "FIRSTMATE SUPERVISION SESSION: bin/fm-branch-prompt.sh could not produce the supervision prompt, so take no fleet action and run no command: answer each wake only with one line saying it could not be handled here, and the wake goes back to the main Firstmate session.";
        });
        branchPrompts.set(home, prompt);
    }

    return prompt;
}

/** The branch's bash identity: main's Pi Pocket marker, as the Pi branch shares main's process, and the branch actor. */
function branchEnv(home: string, main: ConversationId): Record<string, string> {
    return {
        ...markerEnv(home, main),
        FM_SUPERVISION_ACTOR: "branch",
        FM_LEASE_HOLDER_PID: SERVER_PID,
        FM_SUPERVISION_PRIMARY_HARNESS: "pi-pocket",
    };
}

const TYPE_FLAGS = process.execArgv.filter((arg) => /^--(?:experimental-)?(?:strip|transform)-types$/.test(arg));

/** bin/fm-branch-dispatch.mjs, the one command-line owner of which rows the branch may claim and of its wake text. */
function dispatch(home: string, args: string[], input: string): Promise<Ran> {
    return run(process.execPath, [...TYPE_FLAGS, join(home, "bin", "fm-branch-dispatch.mjs"), ...args], { cwd: home, env: { FM_HOME: home }, input });
}

function script(home: string, name: string, args: string[], env: Record<string, string> = {}): Promise<Ran> {
    return run(join(home, "bin", name), args, { cwd: home, env: { FM_HOME: home, ...env } });
}

function fields(text: string): Map<string, string> {
    const map = new Map<string, string>();
    for (const line of text.split("\n")) {
        const at = line.indexOf("=");
        if (at > 0) map.set(line.slice(0, at), line.slice(at + 1).trim());
    }

    return map;
}

const words = (text: string | undefined) => (text ?? "").split(/\s+/).filter((word) => word !== "");

function capped(text: string): string {
    if (text.length <= MIRROR_ENTRY_CHARS) return text;
    const keep = Math.floor((MIRROR_ENTRY_CHARS - 80) / 2);

    return `${text.slice(0, keep)}\n[... ${String(text.length - 2 * keep)} characters omitted ...]\n${text.slice(-keep)}`;
}

/** One mirrored line of main's dialog: what the captain typed or main answered, never tool traffic or Firstmate's inputs. */
function mirrorItem(message: { role: string; content: unknown }): string | undefined {
    if (message.role === "user") {
        const text = userText(message).trim();
        if (text === "" || text.startsWith(OPERATIONAL_PREFIX) || text.startsWith(COMPACTED) || text.startsWith(GUARD_HEADER)) return undefined;

        return `[captain] ${capped(text)}`;
    }
    if (message.role === "assistant" && Array.isArray(message.content)) {
        const text = (message.content as { type?: string; text?: string }[])
            .map((part) => (part.type === "text" ? (part.text ?? "") : ""))
            .join("")
            .trim();

        return text === "" ? undefined : `[main] ${capped(text)}`;
    }

    return undefined;
}

/** A request id for unrequested work, paid by whoever asked last in the session, as Pi Pocket's schedules do. */
function requests(host: Partial<Host>) {
    return (conversationId: ConversationId, key: string) => {
        const requester = typeof host.requesterOf === "function" ? host.requesterOf(conversationId) : undefined;

        return requester === undefined ? `fm-${clientKey(key)}` : `p:${requester}:${clientKey(key)}`;
    };
}

/** How one wake was routed: the branch handled it (with main's next processing request, if any), or main takes it. */
type Routed = { handled: true; follow?: Pending } | { handled: false; text: string };

/**
 * The supervision branch's main-side half, run by the main session's watcher task: it starts or reattaches the
 * branch, offers it each wake, runs the turn that handles one, and turns the outcome store into processing requests.
 */
function createSupervision(host: Partial<Host>) {
    const requestFor = requests(host);
    const heldBack = (id: ConversationId) => (typeof host.heldBack === "function" ? host.heldBack(id) : undefined);
    const grantGeneration = `pocket-${BOOT}`;
    /** Homes whose wake grant names this server, and whose outcome store this server validated. */
    const activated = new Set<string>();
    const initialized = new Set<string>();
    /** Consecutive failed branch turns per home, and when the latched-off branch may be tried again. */
    const latches = new Map<string, { failures: number; until: number; cooldown: number }>();
    const told = new Set<string>();

    const tell = (conversationId: ConversationId, message: string) => {
        if (told.has(message)) return;
        told.add(message);
        host.notice?.("warning", message, conversationId);
    };

    /** One more failed start or turn. At the threshold the branch stays off until its cooling-off period ends. */
    function bumpLatch(home: string): void {
        const latch = latches.get(home) ?? { failures: 0, until: 0, cooldown: LATCH_BASE_MS };
        latch.failures += 1;
        if (latch.failures >= LATCH_THRESHOLD) {
            latch.until = Date.now() + latch.cooldown;
            latch.cooldown = Math.min(LATCH_MAX_MS, latch.cooldown * 2);
        }
        latches.set(home, latch);
    }

    function cooledOff(home: string): boolean {
        const latch = latches.get(home);

        return latch !== undefined && latch.failures >= LATCH_THRESHOLD && Date.now() < latch.until;
    }

    /** The home's config directory: FM_CONFIG_OVERRIDE for a test, otherwise the home's own config/. */
    function configDir(home: string): string {
        return process.env.FM_CONFIG_OVERRIDE || join(home, "config");
    }

    /** The first line of a pin file, or undefined when it is absent, empty, or unreadable. */
    async function pinLine(home: string, name: string): Promise<string | undefined> {
        const text = await readFile(join(configDir(home), name), "utf8").catch(() => "");
        const line = (text.split("\n")[0] ?? "").trim();

        return line === "" ? undefined : line;
    }

    /**
     * The model and thinking level to pass to linkedSessions.start.
     * `ok: false` means the owner's list has models and none of them can be used, so the start must not be attempted.
     * An empty list, or a host that does not list models, is `ok` with no model: Pi Pocket then uses the main
     * session's model, which is today's behavior when the owner has not restricted the list.
     */
    async function supervisionStart(home: string): Promise<{ ok: true; model?: string; thinking?: string } | { ok: false }> {
        const allowed = typeof host.subagentModels === "function" ? host.subagentModels() : [];
        const levels = host.thinkingLevels ?? THINKING_LEVELS;
        const effort = await pinLine(home, "supervision-branch-effort");
        const effortLevel = effort !== undefined && (levels as readonly string[]).includes(effort) ? effort : undefined;
        // Omit an effort the chosen model does not support. Passing it makes Pi Pocket refuse the start, which
        // latches the branch off over a level rather than over the model.
        const thinkingFor = (model?: string): string | undefined => {
            // No model means an empty allow-list: leave thinking unset too, so Pi Pocket keeps the main session's own
            // level instead of refusing the start over an effort that session's model does not support.
            if (effortLevel === undefined || model === undefined) return undefined;
            if (typeof host.modelInfo !== "function") return effortLevel;
            try {
                const info = host.modelInfo(model);
                if (info === undefined) return undefined;

                return info.thinkingLevels.some((level) => level === effortLevel) ? effortLevel : undefined;
            } catch {
                return undefined;
            }
        };
        const chosen = (model?: string) => {
            const thinking = thinkingFor(model);

            return { ok: true as const, ...(model === undefined ? {} : { model }), ...(thinking === undefined ? {} : { thinking }) };
        };
        if (allowed.length === 0) return chosen();
        const stored = await pinLine(home, "supervision-branch-model");
        const slash = stored?.indexOf("/") ?? -1;
        const pin = stored !== undefined && slash > 0 && slash < stored.length - 1 ? stored : undefined;
        const usable = async (spec: string): Promise<boolean> => {
            if (typeof host.resolveModel !== "function") return false;
            try {
                const ref = host.resolveModel(spec);
                if (typeof host.modelProblem !== "function") return true;

                return (await host.modelProblem(ref)) === undefined;
            } catch {
                return false;
            }
        };
        // The pin wins only when the owner listed it and Pi Pocket can use it. A pin that is absent, unlisted, or
        // unusable falls through to the first listed model that resolves and has no model problem.
        if (pin !== undefined && allowed.includes(pin) && (await usable(pin))) return chosen(pin);
        for (const candidate of allowed) {
            if (await usable(candidate)) return chosen(candidate);
        }

        return { ok: false };
    }

    /** This home's branch for the main session, started once and reattached after a restart; undefined without one. */
    async function ensure(runtime: WatchRuntime, context: Context, home: string): Promise<ConversationId | undefined> {
        const main = runtime.conversationId;
        const record = await branchRecord(home);
        if (record?.main === Number(main) && (await runtime.conversation(record.branch as unknown as ConversationId, context)) !== undefined) {
            return record.branch as unknown as ConversationId;
        }
        // A refused start uses the same cooling-off as a turn that does not finish, so the next wake does not retry it.
        if (cooledOff(home)) return undefined;
        const linked = host.linkedSessions;
        if (typeof linked?.start !== "function") {
            tell(main, "Firstmate's supervision session needs Pi Pocket's linked sessions, which this Pi Pocket does not offer, so every wake goes to this session.");
            return undefined;
        }
        const choice = await supervisionStart(home);
        if (!choice.ok) {
            tell(main, MODEL_LIST_NOTICE);
            bumpLatch(home);
            return undefined;
        }
        // A start that was under way when the server stopped is retried under the same key, so it is the same session.
        const start = record?.main !== Number(main) ? 0 : record.starting === true ? record.start : record.start + 1;
        const path = join(stateOf(home), BRANCH_RECORD);
        await writeJson(path, { main: Number(main), branch: 0, start, starting: true } satisfies BranchRecord);
        try {
            const { session } = await linked.start(
                main,
                {
                    title: BRANCH_TITLE,
                    message: BRANCH_INTRO,
                    cwd: home,
                    ...(choice.model === undefined ? {} : { model: choice.model }),
                    ...(choice.thinking === undefined ? {} : { thinking: choice.thinking }),
                },
                `firstmate-supervision-${hash(home)}-${String(start)}`,
            );
            await writeJson(path, { main: Number(main), branch: Number(session), start } satisfies BranchRecord);
            latches.delete(home);

            return session;
        } catch (error) {
            await rm(path, { force: true });
            tell(main, `Firstmate could not start its supervision session, so wakes go to this session until it can: ${(error as Error).message}`);
            bumpLatch(home);
            return undefined;
        }
    }

    async function activate(home: string): Promise<boolean> {
        if (activated.has(home)) return true;
        if ((await script(home, "fm-wake-grant.sh", ["activate", SERVER_PID, grantGeneration])).code !== 0) return false;
        activated.add(home);

        return true;
    }

    /** End the recorded turn: free its rows for main, drop the branch's leases, and forget it. */
    async function finish(home: string): Promise<void> {
        if (await activate(home)) await script(home, "fm-wake-grant.sh", ["release", grantGeneration]);
        await script(home, "fm-lease.sh", ["release-actor", "--actor", "branch"], { FM_SUPERVISION_ACTOR: "branch", FM_LEASE_HOLDER_PID: SERVER_PID });
        await rm(join(stateOf(home), BRANCH_TURN), { force: true });
    }

    /** What the captain and main said since the branch's last wake; a branch new to this main session gets the newest few. */
    async function mirror(runtime: WatchRuntime, context: Context, home: string): Promise<{ feed: string; cursor: MirrorCursor }> {
        const main = Number(runtime.conversationId);
        const view = await runtime.context(runtime.conversationId, context);
        const cursor = await readJson<MirrorCursor>(join(stateOf(home), MIRROR_CURSOR));
        const after = cursor?.main === main && Number.isSafeInteger(cursor.entry) ? cursor.entry : undefined;
        const items: string[] = [];
        let newest = after ?? 0;
        view.entries.forEach((entry, index) => {
            const id = Number(entry.id);
            newest = Math.max(newest, id);
            if (after !== undefined && id <= after) return;
            for (const message of view.contributions[index] ?? []) {
                const item = mirrorItem(message as never);
                if (item !== undefined) items.push(item);
            }
        });

        return { feed: items.slice(-(after === undefined ? MIRROR_FRESH_ITEMS : MIRROR_ITEMS)).join("\n"), cursor: { main, entry: newest } };
    }

    function failed(home: string, pending: Pending, why: string): Routed {
        bumpLatch(home);

        return { handled: false, text: `${pending.text}\n\nThe supervision session did not handle this wake (${why}), so it is yours to handle.` };
    }

    /** Wait for the branch's turn to settle, until its deadline; a halted wait leaves the turn running for the next cycle. */
    function settle(wait: Promise<unknown>, remaining: number, stop: AbortSignal): Promise<"settled" | "late"> {
        stop.throwIfAborted();

        return new Promise((resolve, reject) => {
            const halt = () => {
                clearTimeout(timer);
                reject(stop.reason);
            };
            const timer = setTimeout(() => {
                stop.removeEventListener("abort", halt);
                resolve("late");
            }, Math.max(0, remaining));
            stop.addEventListener("abort", halt, { once: true });
            wait.then(
                () => {
                    clearTimeout(timer);
                    stop.removeEventListener("abort", halt);
                    resolve("settled");
                },
                (error: unknown) => {
                    clearTimeout(timer);
                    stop.removeEventListener("abort", halt);
                    reject(error);
                },
            );
        });
    }

    /** Offer one wake to the branch and run the turn that handles it; anything the branch cannot take goes to main. */
    async function route(runtime: WatchRuntime, context: Context, home: string, pending: Pending, stop: AbortSignal): Promise<Routed> {
        try {
            return await turn(runtime, context, home, pending, stop);
        } catch (error) {
            if (stop.aborted || runtime.signal.aborted || context.abortSignal?.aborted) throw error;
            await finish(home).catch(() => {});

            return failed(home, pending, (error as Error).message);
        }
    }

    async function turn(runtime: WatchRuntime, context: Context, home: string, pending: Pending, stop: AbortSignal): Promise<Routed> {
        const main = runtime.conversationId;
        const state = stateOf(home);
        const turnPath = join(state, BRANCH_TURN);
        const toMain: Routed = { handled: false, text: pending.text };
        let current = await readJson<BranchTurn>(turnPath);
        if (current !== undefined && current.wake !== pending.requestId) {
            // A turn for a wake that is no longer waiting: it was settled before its record went away.
            await finish(home);
            current = undefined;
        }
        if (current === undefined) {
            if (cooledOff(home)) return toMain;
            const branch = await ensure(runtime, context, home);
            if (branch === undefined || heldBack(main) !== undefined) return toMain;
            if (!(await activate(home))) return failed(home, pending, "its wake grant could not be activated");
            const offer = fields((await dispatch(home, ["offer"], `${pending.text.split("\n")[0] ?? ""}\n`)).stdout);
            const rows = words(offer.get("rows"));
            if (offer.get("eligible") !== "1" || offer.get("corrupted") !== "0" || rows.length === 0) return toMain;
            const { feed, cursor } = await mirror(runtime, context, home);
            const feedPath = join(state, MIRROR_FEED);
            await writeFile(feedPath, feed, { mode: 0o600 });
            const prompted = await dispatch(home, ["wake-prompt", "--report", REPORT_TOOL, "--mirror-file", feedPath], pending.text);
            await rm(feedPath, { force: true });
            if (prompted.code !== 0 || prompted.stdout.trim() === "") return failed(home, pending, "its wake prompt could not be built");
            current = {
                wake: pending.requestId,
                branch: Number(branch),
                request: requestFor(branch, `fm-branch-${hash(pending.requestId)}`),
                rows,
                tasks: words(offer.get("tasks")),
                unscoped: offer.get("unscoped") === "1",
                prompt: prompted.stdout.replace(/\n+$/, ""),
                mirror: cursor,
                started: Date.now(),
                reports: [],
            };
            await writeJson(turnPath, current);
            if ((await script(home, "fm-wake-grant.sh", ["publish", grantGeneration, ...rows])).code !== 0) {
                await finish(home);
                return toMain;
            }
        } else if (await activate(home)) {
            // Resumed: after a restart the grant must name this server again; the rows may already be consumed.
            await script(home, "fm-wake-grant.sh", ["publish", grantGeneration, ...current.rows]);
        }

        const branch = current.branch as unknown as ConversationId;
        const conversation: ConversationHandle | undefined = await runtime.conversation(branch, context);
        if (conversation === undefined) {
            await finish(home);
            return failed(home, pending, "the supervision session is gone");
        }
        const submission = await conversation.submit({ type: "input", content: current.prompt, whenBusy: "followUp", requestId: current.request }, context);
        const outcome = await settle(submission.wait(context), current.started + BRANCH_TURN_TIMEOUT_MS - Date.now(), signalsOf(stop, runtime.signal, context.abortSignal));
        if (outcome === "late") {
            await submission.abort(context).catch(() => undefined);
            await conversation.abort(context).catch(() => undefined);
        }
        const reports = (await readJson<BranchTurn>(turnPath))?.reports ?? [];
        await finish(home);
        // A late turn may have stopped partway through its rows: what it recorded stays in the store, and main
        // takes the wake, with no success counted and the mirror left where it was.
        if (outcome === "late") return failed(home, pending, "its turn ran past its deadline");
        if (reports.length === 0) return failed(home, pending, "its turn ended without recording an outcome");
        latches.delete(home);
        await writeJson(join(state, MIRROR_CURSOR), current.mirror);
        const follow = await present(home, main);

        return follow === undefined ? { handled: true } : { handled: true, follow };
    }

    function outcomes(home: string, args: string[]): Promise<Ran> {
        return script(home, "fm-branch-outcome.sh", args);
    }

    /**
     * Mark the stored outcomes read and, when captain outcomes wait for main, the processing request that lists them,
     * as the Pi branch presents them. Routine outcomes stay in the store and the supervision session's own transcript.
     */
    async function present(home: string, main: ConversationId): Promise<Pending | undefined> {
        if (!initialized.has(home)) {
            const ran = await outcomes(home, ["processed-init"]);
            if (ran.code !== 0) {
                tell(main, `Firstmate's supervision outcomes could not be read: ${ran.stderr.trim() || "the outcome store failed validation"}`);
                return undefined;
            }
            initialized.add(home);
        }
        // Every stored row is read once presented here: captain rows through the processing request below, routine
        // rows in the supervision session's own transcript. Only the newest row is read, so a large backlog never
        // has to fit one read; mark-read never moves the cursor backwards.
        const last = await outcomes(home, ["list", "--recent", "1"]);
        const newest = Number((last.code === 0 ? jsonLines(last.stdout) : undefined)?.[0]?.seq);
        if (Number.isSafeInteger(newest) && newest > 0) await outcomes(home, ["mark-read", "--through", String(newest)]);
        const listed = await outcomes(home, ["unprocessed"]);
        const rows = listed.code === 0 ? jsonLines(listed.stdout) : undefined;
        const valid = rows?.every(
            (row) => Number.isSafeInteger(row.seq) && typeof row.task === "string" && typeof row.summary === "string" && /^[0-9]+[mhd]$/.test(String(row.recordedAgo)),
        );
        if (rows === undefined || valid !== true) {
            tell(main, "Firstmate's supervision outcomes could not be presented: the outcome store listed a row that breaks its contract. Nothing was marked processed.");
            return undefined;
        }
        const processingPath = join(stateOf(home), BRANCH_PROCESSING);
        if (rows.length === 0) {
            await rm(processingPath, { force: true });
            return undefined;
        }
        const through = Number(rows[rows.length - 1]!.seq);
        await writeJson(processingPath, { main: Number(main), through } satisfies Processing);
        const listedRows = rows.map((row) => `[seq ${String(row.seq)}, recorded ${String(row.recordedAgo)} ago] ${String(row.task)}: ${String(row.summary)}`).join("\n");
        const body = `${PROCESSING_INSTRUCTION.replace("{N}", String(through))}\n\n${listedRows}`;

        return { kind: "outcomes", text: await encode(home, "branch-outcome", body), requestId: requestFor(main, `fm-outcomes-${BOOT}-${String(through)}`) };
    }

    /** End a recorded turn whose wake no longer waits in `pending`, so its rows return to main's drain. */
    async function reconcile(home: string, pending: readonly Pending[]): Promise<void> {
        const current = await readJson<BranchTurn>(join(stateOf(home), BRANCH_TURN));
        if (current !== undefined && !pending.some((item) => item.requestId === current.wake && item.kind === "wake" && item.main !== true)) {
            await finish(home);
        }
    }

    return { ensure, route, present, reconcile };
}

type Supervision = ReturnType<typeof createSupervision>;

// ---------------------------------------------------------------------------------------------------------------
// The watcher task

/**
 * One delivery the model has not had yet: a watcher wake (`main` when it must not go to the branch), a restart's
 * session-start digest, or a processing request for the branch's captain outcomes.
 */
type Pending = { kind: "wake" | "digest" | "outcomes"; text: string; requestId: string; main?: boolean };
type WatchInput = { home: string; boot: string };
type WatchState = {
    phase: "arm";
    /** The server process this checkpoint ran under; another one means a restart re-drove the task. */
    boot: string;
    /** Wakes read so far, which keys the next one. */
    seq: number;
    /** Consecutive failed arm cycles. */
    failures: number;
    /** The arm that just closed, handed to its successor. */
    predecessor?: string;
    /**
     * Deliveries read but not made yet, oldest first: kept here, so a restart delivers each once. The watcher keeps
     * cycling while they wait, so a spend limit holds the model's turns back, never the fleet's monitoring.
     */
    pending?: Pending[];
};
type WatchRuntime = TaskRuntime<WatchInput, WatchState, null, object>;

type Arm = {
    pid: string;
    /** True once the arm reported a started or attached watcher, false when it closed first or never did in time. */
    ready: Promise<boolean>;
    /** The recovery generation a successor reported, for the handling handoff. */
    recovery: () => { generation: string; watcherPid: string } | undefined;
    closed: Promise<Ran>;
    retire: () => Promise<boolean>;
};

function startArm(home: string, conversationId: ConversationId, predecessor: string | undefined): Arm {
    const script = join(home, "bin", "fm-watch-arm.sh");
    const child = spawn(
        "bash",
        [
            "-lc",
            'config_dir="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"; [ -f "$config_dir/x-mode.env" ] && . "$config_dir/x-mode.env"; exec "$FM_WATCH_ARM_SCRIPT" --restart',
        ],
        {
            cwd: home,
            env: {
                ...process.env,
                ...markerEnv(home, conversationId),
                FM_WATCH_ARM_SCRIPT: script,
                ...(predecessor === undefined ? {} : { FM_WATCH_PREDECESSOR_ARM_PID: predecessor }),
            },
            stdio: ["ignore", "pipe", "pipe"],
        },
    );
    let stdout = "";
    let stderr = "";
    let recovery: { generation: string; watcherPid: string } | undefined;
    let markReady: (ready: boolean) => void = () => {};
    const ready = new Promise<boolean>((resolve) => {
        markReady = resolve;
    });
    const closed = new Promise<Ran>((resolve) => {
        child.on("error", (error) => {
            markReady(false);
            resolve({ code: null, signal: null, stdout, stderr: `${stderr}${error.message}` });
        });
        child.on("close", (code, signal) => {
            markReady(false);
            resolve({ code, signal, stdout, stderr });
        });
    });
    child.stdout.on("data", (chunk: Buffer) => {
        stdout += chunk.toString();
        for (const line of stdout.split(/\r?\n/)) {
            const started = /^watcher: started pid=([0-9]+).* recovery-generation=([A-Za-z0-9._-]+)$/.exec(line);
            if (started) recovery = { watcherPid: started[1]!, generation: started[2]! };
            if (/^watcher: (?:started|attached)\b/.test(line)) markReady(true);
        }
    });
    child.stderr.on("data", (chunk: Buffer) => {
        stderr += chunk.toString();
    });
    setTimeout(() => markReady(false), READY_TIMEOUT_MS).unref();

    return {
        pid: String(child.pid ?? ""),
        ready,
        recovery: () => recovery,
        closed,
        retire: async () => {
            child.kill("SIGTERM");
            return Promise.race([closed.then(() => true), pause(RETIRE_TIMEOUT_MS, new AbortController().signal).then(() => false)]);
        },
    };
}

/** What a closed arm cycle means, as the Pi extension classifies it. */
function classify(ran: Ran): { actionable: boolean; message: string } {
    const combined = `${ran.stdout}\n${ran.stderr}`.trim();
    const lines = combined.split(/\r?\n/);
    const reason = lines.find((line) => /^(signal:|stale:|check:|heartbeat($|:))/.test(line));
    if (reason) return { actionable: true, message: reason };
    const healthy = lines.find((line) => /^watcher: healthy\b/.test(line));
    if (healthy) {
        return {
            actionable: false,
            message: `watcher: FAILED - Pi Pocket drop-in arm child found an external healthy watcher instead of owning wake delivery\n${healthy}`,
        };
    }
    const failed = lines.find((line) => /^watcher: FAILED/.test(line));
    if (failed) return { actionable: false, message: failed };
    const detail = combined === "" ? "" : `\n${combined}`;
    if (ran.signal) return { actionable: false, message: `watcher: FAILED - Pi Pocket drop-in arm child ended from ${ran.signal}${detail}` };
    if (ran.code !== 0) return { actionable: false, message: `watcher: FAILED - fm-watch-arm.sh exited ${String(ran.code)}${detail}` };

    return { actionable: false, message: "watcher: FAILED - Pi Pocket drop-in arm cycle ended without an actionable reason" };
}

/** Confirm the handling handoff a successor reported, retried once; a superseded generation counts as confirmed. */
async function confirmHandling(home: string, recovery: { generation: string; watcherPid: string }): Promise<string> {
    let detail = "";
    for (let attempt = 0; attempt < 2; attempt += 1) {
        const ran = await run(
            join(home, "bin", "fm-watch-arm.sh"),
            ["--handling-delivered", recovery.generation, "--watcher-pid", recovery.watcherPid],
            { cwd: home, env: { FM_HOME: home } },
        );
        if (ran.code === 0 || ran.code === 3) return "";
        detail = `watcher: FAILED - handling delivery confirmation was rejected (status=${String(ran.code)} generation=${recovery.generation} watcherPid=${recovery.watcherPid})${ran.stderr.trim() === "" ? "" : `\n${ran.stderr.trim()}`}`;
    }

    return detail;
}

function retryDelay(failures: number): number {
    return Math.min(RETRY_MAX_MS, RETRY_BASE_MS * 2 ** Math.max(0, failures - 1));
}

const clientKey = (key: string) => key.replace(/[^A-Za-z0-9_-]/g, "").slice(0, 64);

/** A short stable name for a text: FNV-1a. */
function hash(text: string): string {
    let value = 0x811c9dc5;
    for (let index = 0; index < text.length; index += 1) {
        value ^= text.charCodeAt(index);
        value = Math.imul(value, 0x01000193) >>> 0;
    }

    return value.toString(16).padStart(8, "0");
}

function createWatchTask(host: Partial<Host>, supervision: Supervision, presented: boolean) {
    const heldBack = (id: ConversationId) =>
        typeof host.heldBack === "function" ? host.heldBack(id) : undefined;
    const whenLimitsChange = (listener: () => void) =>
        typeof host.onLimitsChanged === "function" ? host.onLimitsChanged(listener) : () => {};
    const requestFor = requests(host);

    /**
     * Deliver `content` as one follow-up keyed on `requestId`: a re-driven delivery finds the submission it already
     * made. While the session is past a spend limit it waits rather than start a turn nobody may pay for.
     */
    const deliver = async (runtime: WatchRuntime, context: Context, content: string, requestId: string, summary: string, stop?: AbortSignal) => {
        const signal = signalsOf(runtime.signal, context.abortSignal, stop);
        let told = false;
        for (;;) {
            const reason = heldBack(runtime.conversationId);
            if (reason === undefined) break;
            if (!told) {
                told = true;
                host.notice?.("info", `Firstmate's watcher wake waits: ${reason}`, runtime.conversationId);
            }
            const changed = new AbortController();
            const stop = whenLimitsChange(() => changed.abort());
            try {
                await pause(HELD_RECHECK_MS, signalsOf(signal, changed.signal));
            } catch (error) {
                if (signal.aborted) throw error;
            } finally {
                stop();
            }
        }
        signal.throwIfAborted();
        const conversation = await runtime.conversation(runtime.conversationId, context);
        if (conversation === undefined) throw new Error("the Firstmate session is gone");
        await conversation.submit({ type: "input", content, whenBusy: "followUp", requestId, ...mainEntry(presented, summary) }, context);
    };

    const contentOf = async (home: string, pending: Pending) =>
        pending.kind === "wake" ? encode(home, "watcher", wakeText(pending.text)) : pending.text;

    /** Deliver whatever is still pending, then the failure, and end the task: the model repairs with the tool. */
    const fail = async (task: { state: { checkpoint: WatchState }; input: WatchInput }, runtime: WatchRuntime, context: Context, failure: string) => {
        const { home } = task.input;
        const checkpoint = task.state.checkpoint;
        // Every wake goes to main from here on: no branch turn may keep rows from main's drain.
        await supervision.reconcile(home, []).catch(() => {});
        for (const pending of checkpoint.pending ?? []) {
            await deliver(runtime, context, await contentOf(home, pending), pending.requestId, pendingSummary(pending));
        }
        const requestId = requestFor(runtime.conversationId, `fm-watch-failed-${String(runtime.taskId)}-${checkpoint.seq}`);
        await deliver(runtime, context, await encode(home, "watcher", wakeText(failure)), requestId, failureSummary(failure));
        await runtime.commit(() => ({ status: "terminal", outcome: { status: "completed", result: null } }), context);
    };

    return defineTask<WatchInput, WatchState, null>({
        name: WATCH_KIND,
        version: 1,
        initial: (input) => ({ phase: "arm", boot: input.boot, seq: 0, failures: 0 }),
        phases: {
            arm: async (task, runtime, context) => {
                const { home } = task.input;
                const id = runtime.conversationId;
                const checkpoint = task.state.checkpoint;
                const signal = signalsOf(runtime.signal, context.abortSignal);

                if (checkpoint.boot !== BOOT) {
                    // A server restart re-drove the task: take the lock again as this conversation and give the model
                    // the digest, once per server process, before the watcher runs again.
                    // The digest queues ahead of any wake that was waiting, and is delivered like one, so a spend
                    // limit does not keep the watcher from running again.
                    const digest =
                        (await runtime.memo<string>(`x.firstmate.start-${BOOT}`, context)) ??
                        (await runtime.memo<string>(`x.firstmate.start-${BOOT}`, await sessionStart(home, id, "startup"), context));
                    const start: Pending = { kind: "digest", text: digest, requestId: requestFor(id, `fm-start-${String(runtime.taskId)}-${BOOT}`) };
                    // Captain outcomes the branch stored before the restart that main has not processed follow it.
                    const outcomes = (await ownership(home, id)) === "owned" ? await supervision.present(home, id) : undefined;
                    const waiting = (checkpoint.pending ?? []).filter((item) => item.kind !== "outcomes");
                    const queued = [start, ...(outcomes === undefined ? [] : [outcomes]), ...waiting];
                    await runtime.commit(() => ({ status: "running", checkpoint: { ...checkpoint, boot: BOOT, pending: queued } }), context);
                    return;
                }

                const owner = await ownership(home, id);
                if (owner === "other") {
                    await fail(task, runtime, context, "watcher: FAILED - Pi Pocket drop-in cannot keep the watcher because another firstmate session holds this home's lock; this conversation is read-only");
                    return;
                }
                if (owner === "missing") {
                    await fail(task, runtime, context, `watcher: FAILED - no live session holds the lock; run bin/fm-session-start.sh to reclaim it, then call ${REPAIR_TOOL} to re-arm`);
                    return;
                }
                // The supervision session exists while this session supervises: started once, reattached after a
                // restart, and replaced only when the captain removed it.
                // Neither may stop the watcher: without a branch every wake simply goes to main.
                await supervision.ensure(runtime, context, home).catch(() => undefined);
                await supervision.reconcile(home, checkpoint.pending ?? []).catch(() => undefined);

                const arm = startArm(home, id, checkpoint.predecessor);
                const stop = () => void arm.retire();
                signal.addEventListener("abort", stop, { once: true });
                try {
                    const ready = await arm.ready;
                    signal.throwIfAborted();
                    if (!ready) {
                        const retired = await arm.retire();
                        const output = retired ? `\n${classify(await arm.closed).message}` : "";
                        const failure = `watcher: FAILED - Pi Pocket drop-in could not verify a ready watcher${output}`;
                        await retry(task, runtime, context, retired ? failure : `${failure}\nwatcher: FAILED - the unready arm did not retire`, arm.pid, !retired);
                        return;
                    }

                    // A ready arm does not end a failure streak: only an actionable close does, so an arm that keeps
                    // reporting ready and then failing still reaches the retry limit.
                    let next: WatchState = { ...checkpoint };
                    delete next.predecessor;
                    // Successor first, then the wakes: the fleet is watched again before the model handles them.
                    const recovery = arm.recovery();
                    const waiting = next.pending ?? [];
                    const newest = waiting.findLastIndex((pending) => pending.kind === "wake");
                    if (recovery !== undefined && newest >= 0) {
                        const detail = await confirmHandling(home, recovery);
                        if (detail !== "") {
                            // A wake whose handling handoff failed stays with main, which owns that repair.
                            const pending = waiting.map((item, index) => (index === newest ? { ...item, text: `${item.text}\n\n${detail}`, main: true } : item));
                            next = { ...next, pending };
                            const confirmed = next;
                            await runtime.commit(() => ({ status: "running", checkpoint: confirmed }), context);
                        }
                    }

                    // Deliver the pending queue one by one while this arm keeps watching. A delivery waiting out a
                    // spend limit never holds the watcher: when the arm closes, the delivery stops where it is and
                    // the next cycle, with its successor running, takes the queue up again under the same request ids.
                    // A wake goes to the supervision session first: one it handled is done, with main's processing
                    // request for any captain outcome in its place; one it cannot take goes to main the same way.
                    const halt = new AbortController();
                    type Done = { delivered: string; then?: Pending };
                    let delivering: Promise<Done | { stopped: true }> | undefined;
                    const handle = async (first: Pending): Promise<Done> => {
                        if (first.kind === "wake" && first.main !== true) {
                            const routed = await supervision.route(runtime, context, home, first, halt.signal);
                            if (routed.handled) return { delivered: first.requestId, ...(routed.follow === undefined ? {} : { then: routed.follow }) };
                            return { delivered: first.requestId, then: { ...first, text: routed.text, main: true } };
                        }
                        await deliver(runtime, context, await contentOf(home, first), first.requestId, pendingSummary(first), halt.signal);

                        return { delivered: first.requestId };
                    };
                    const settleDone = (done: Done) => {
                        const rest = (next.pending ?? []).filter((item) => item.requestId !== done.delivered && item.requestId !== done.then?.requestId);
                        const pending = done.then === undefined ? rest : [done.then, ...rest];
                        next = { ...next, pending };
                        if (pending.length === 0) delete next.pending;
                    };
                    const deliverNext = () => {
                        const first = next.pending?.[0];
                        delivering =
                            first === undefined
                                ? undefined
                                : handle(first).catch((error: unknown) => {
                                      if (halt.signal.aborted || signal.aborted) return { stopped: true as const };
                                      throw error;
                                  });
                    };
                    deliverNext();
                    let ran: Ran | undefined;
                    try {
                        while (ran === undefined) {
                            const event = await Promise.race([
                                arm.closed.then((closed) => ({ closed })),
                                ...(delivering === undefined ? [] : [delivering]),
                            ]);
                            if ("closed" in event) {
                                ran = event.closed;
                            } else if ("delivered" in event) {
                                settleDone(event);
                                const delivered = next;
                                await runtime.commit(() => ({ status: "running", checkpoint: delivered }), context);
                                deliverNext();
                            } else {
                                // Stopped by an abort: wait for the arm, which the abort retires, to close.
                                delivering = undefined;
                            }
                        }
                    } finally {
                        halt.abort();
                        const settled = await delivering?.catch(() => undefined);
                        if (settled !== undefined && "delivered" in settled) settleDone(settled);
                    }

                    const closed = classify(ran);
                    signal.throwIfAborted();
                    if (closed.actionable) {
                        const seq = next.seq + 1;
                        const wake: Pending = { kind: "wake", text: closed.message, requestId: requestFor(id, `fm-wake-${String(runtime.taskId)}-${seq}`) };
                        const read: WatchState = { ...next, seq, failures: 0, predecessor: arm.pid, pending: [...(next.pending ?? []), wake] };
                        await runtime.commit(() => ({ status: "running", checkpoint: read }), context);
                        return;
                    }
                    await retry({ ...task, state: { ...task.state, checkpoint: next } }, runtime, context, closed.message, arm.pid, false);
                } finally {
                    signal.removeEventListener("abort", stop);
                }
            },
        },
        abort: (_task, runtime, context) =>
            runtime.commit(() => ({ status: "terminal", outcome: { status: "aborted" } }), context),
    });

    /** Arm again after a bounded, growing delay, while the lock is still this conversation's; then give up visibly. */
    async function retry(
        task: { state: { checkpoint: WatchState }; input: WatchInput },
        runtime: WatchRuntime,
        context: Context,
        message: string,
        predecessor: string,
        now: boolean,
    ) {
        const checkpoint = task.state.checkpoint;
        const failures = checkpoint.failures + 1;
        if ((await ownership(task.input.home, runtime.conversationId)) !== "owned") {
            await fail(task, runtime, context, `watcher: FAILED - Pi Pocket drop-in cannot restore continuity because this conversation no longer owns the lock\n${message}`);
            return;
        }
        if (now || failures > RETRY_LIMIT) {
            await fail(task, runtime, context, `${message}\nwatcher: FAILED - Pi Pocket drop-in could not restore watcher continuity after ${String(checkpoint.failures)} retries`);
            return;
        }
        // The durable wait is sleepUntil: it stores this checkpoint and resumes the arm phase when the delay is up.
        // A running commit here would replace that sleep and retry with no backoff.
        await runtime.sleepUntil(runtime.now() + retryDelay(failures), { ...checkpoint, failures, predecessor }, context);
    }
}

type WatchTask = ReturnType<typeof createWatchTask>;

/**
 * Start the conversation's watcher task unless one is live. True when this call started it. The commit returns
 * nothing, so a hook's task runtime, whose commit reads a returned value as its own next state, can call it too.
 */
async function ensureWatch(
    api: { readonly conversationId: ConversationId; commit(change: (tx: Tx) => Promise<undefined>, context: Context): Promise<unknown> },
    watch: WatchTask,
    home: string,
    context: Context,
): Promise<boolean> {
    let started = false;
    await api.commit(async (tx) => {
        const page = await tx.scanTasks({ conversationId: api.conversationId, kind: WATCH_KIND, order: "descending" }, 50);
        if (page.items.some((task) => task.state.status !== "terminal" && !task.abortRequested)) return undefined;
        await tx.createTask(watch, { home, boot: BOOT }, {
            ownership: { kind: "conversation" },
            background: true,
            abandonOnRestart: false,
            conversationId: api.conversationId,
        });
        started = true;

        return undefined;
    }, context);

    return started;
}

// ---------------------------------------------------------------------------------------------------------------
// The extension

/**
 * The working folder of a hook's session: its execution environment, else its agent's folder. A hook from the
 * Harness gets the task runtime, whose `env` is a function; a hook that Pi Pocket's codemode runs for a call from
 * a script gets the tool's execution API, whose `env` is the environment itself.
 */
async function hookCwd(api: unknown, conversationId: ConversationId, context: Context): Promise<string | undefined> {
    const runtime = api as Partial<Pick<TaskRuntime<unknown, { phase: string }, unknown, object>, "snapshot">> & {
        env?: TaskRuntime<unknown, { phase: string }, unknown, object>["env"] | ToolExecutionApi["env"];
    };
    const env = typeof runtime.env === "function" ? await runtime.env(context).catch(() => undefined) : runtime.env;
    if (env?.cwd) return env.cwd;
    const agent = await runtime.snapshot?.(AgentDoc, conversationId, context);

    return agent?.cwd ?? process.cwd();
}

/** The supervision branch a session is, with the main session it serves, or undefined for any other session. */
async function branchOf(home: string | undefined, conversationId: ConversationId): Promise<ConversationId | undefined> {
    if (home === undefined) return undefined;
    const record = await branchRecord(home);
    if (record === undefined) return undefined;
    const id = Number(conversationId);
    const branch = record.branch === id || (record.starting === true && record.main !== id);

    return branch ? (record.main as unknown as ConversationId) : undefined;
}

/** The slice of Pi Pocket's `web` this drop-in uses. Older apps omit `presentEntry`. */
type PocketSurface = {
    presentEntry?: (spec: { kind: string; label: string; userPrefix?: string }) => void;
    client?: (entry: string, options?: { access?: string }) => void;
    command?: (
        name: string,
        command: {
            description: string;
            scope: "conversation";
            handler: (
                args: string,
                context: { cwd: string; conversationId: ConversationId },
            ) => Promise<{ type: "toast"; level: "info" | "warning"; message: string }>;
        },
    ) => void;
    route?: (
        method: "GET",
        path: string,
        handle: (request: { query: URLSearchParams; sessions?: () => readonly { id: number; cwd: string }[] }) => unknown,
        options?: { access?: string },
    ) => void;
    send?: (event: string, data?: unknown) => void;
};

/**
 * Register the two stored kinds and the operational prefix. False when this Pi Pocket has no presentation API, or the
 * operational kind could not be registered: submits then stay ordinary messages so a wake is never hidden.
 */
function registerPresentations(web: PocketSurface | undefined): boolean {
    if (typeof web?.presentEntry !== "function") return false;
    try {
        web.presentEntry({ kind: START_KIND, label: PRESENTATION_LABEL });
    } catch {
        // The fresh digest keeps today's custom kind. Operational submits still try below.
    }
    try {
        web.presentEntry({ kind: OPERATIONAL_KIND, label: PRESENTATION_LABEL, userPrefix: OPERATIONAL_PREFIX });
        return true;
    } catch {
        return false;
    }
}

/** `/calm` and the reload route. A failure here leaves the command unregistered and does not stop wake delivery. */
function registerCalm(web: PocketSurface | undefined): void {
    if (typeof web?.command !== "function") return;
    const send = web.send?.bind(web);
    try {
        // Pi Pocket refuses a command name with no hyphen, so this cannot be /calm. It toggles the same file.
        web.command("firstmate-calm", {
            description: "Toggle Firstmate's shared Calm preference for this home.",
            scope: "conversation",
            handler: async (_args, context) => {
                const home = await homeOf(context.cwd);
                if (home === undefined) {
                    return { type: "toast", level: "info", message: "Calm is unchanged: this session is not a Firstmate home" };
                }
                const next = !(await calmOn(home));
                try {
                    await writeCalm(home, next);
                } catch {
                    return { type: "toast", level: "warning", message: "Calm is unchanged: the preference could not be saved" };
                }
                send?.("calm", { calm: next, conversation: String(context.conversationId) });

                return { type: "toast", level: "info", message: next ? "Calm on" : "Calm off" };
            },
        });
    } catch {
        return;
    }
    const read = async (request: { query: URLSearchParams; sessions?: () => readonly { id: number; cwd: string }[] }) => {
        const asked = request.query.get("conversation");
        if (asked === null || typeof request.sessions !== "function") return { calm: false };
        const cwd = request.sessions().find((session) => String(session.id) === asked)?.cwd;
        if (cwd === undefined) return { calm: false };
        const home = await homeOf(cwd);
        if (home === undefined) return { calm: false };

        return { calm: await calmOn(home) };
    };
    if (typeof web.route !== "function") return;
    try {
        web.route("GET", "calm", read, { access: "view" });
    } catch {
        try {
            web.route("GET", "calm", read);
        } catch {
            // The command still toggles the file. A reloaded tab keeps the app's own presentation default.
        }
    }
}

/** The browser module applies the home preference. A missing file must not keep the drop-in from loading. */
function registerClient(web: PocketSurface | undefined): void {
    if (typeof web?.client !== "function") return;
    try {
        web.client("firstmate.js", { access: "view" });
    } catch {
        try {
            web.client("firstmate.js");
        } catch {
            // Wakes still deliver. Presentation stays the app's default until the file is installed beside the drop-in.
        }
    }
}

export default function createFirstmate(host: Partial<Host> = {}, web?: PocketSurface) {
    const presented = registerPresentations(web);
    registerCalm(web);
    registerClient(web);
    const supervision = createSupervision(host);
    const watch = createWatchTask(host, supervision, presented);

    const marked = createBashTool({
        prepare: (execution, api) => {
            Object.assign(execution.env, markerEnv(execution.cwd, api.conversationId));
        },
    });
    // The branch's bash: main's marker and the branch actor, read-only inside its shell so an accidental reassignment
    // fails instead of acting as main (the Pi branch's guard, bin/fm-lease-lib.sh owns the threat model).
    const branchBash = (main: ConversationId) =>
        createBashTool({
            prepare: (execution) => {
                Object.assign(execution.env, branchEnv(execution.cwd, main));
                execution.command = `readonly FM_SUPERVISION_ACTOR FM_LEASE_HOLDER_PID\n(\n${execution.command}\n)`;
            },
        });

    const report = defineTool({
        name: REPORT_TOOL,
        description:
            "Record the outcome of one handled fleet event in the durable outcome store; the main Firstmate session is asked to process each captain outcome. Only the Firstmate supervision session reports, and only on the tasks of the wake it is handling.",
        parameters: Type.Object({
            task: Type.String({ description: "The task id the event belongs to (or 'fleet' for fleet-wide events)" }),
            verdict: Type.Union([Type.Literal("routine"), Type.Literal("captain")], {
                description: 'Use captain or routine exactly as the "Verdict: routine or captain" section of your system prompt decides; that section is the one owner of the rule.',
            }),
            summary: Type.String({ description: "One or two sentences in captain outcome language; include the full https:// PR URL when a PR is involved" }),
            wake: Type.Optional(Type.String({ description: "The wake reason line this outcome answers" })),
            silent: Type.Optional(
                Type.Boolean({ description: "True only for an eligible routine no-change outcome; captain outcomes are never silent, and actions, state changes, or new results stay rendered" }),
            ),
        }),
        execute: async (args, api) => {
            const home = await homeOf(api.env?.cwd);
            if ((await branchOf(home, api.conversationId)) === undefined || home === undefined) {
                return say("report refused: only the Firstmate supervision session records outcomes", true);
            }
            const task = args.task.trim();
            const summary = args.summary.trim();
            if (task === "" || summary === "") return say("invalid report: task, verdict (routine|captain), and summary are required", true);
            if (args.silent === true && args.verdict !== "routine") return say("invalid report: --silent true requires the routine verdict", true);
            const turnPath = join(stateOf(home), BRANCH_TURN);
            const current = await readJson<BranchTurn>(turnPath);
            if (current?.branch !== Number(api.conversationId)) return say("report refused: no wake is being handled in this session right now", true);
            if (!current.unscoped && !current.tasks.includes(task)) {
                return say(
                    `report refused: the wake being handled (row ${current.rows.join(", ")}) names ${[...current.tasks].sort().join(", ")}, not ${task}; report only that task, never fleet or a task from memory`,
                    true,
                );
            }
            const appendArgs = ["append", "--task", task, "--verdict", args.verdict, "--summary", summary, "--silent", String(args.silent === true)];
            const wake = args.wake?.trim() ?? "";
            if (wake !== "") appendArgs.push("--wake", wake);
            const appended = await script(home, "fm-branch-outcome.sh", appendArgs);
            const seq = Number(appended.stdout.trim());
            if (appended.code !== 0 || !Number.isSafeInteger(seq) || seq < 1) {
                return say(`outcome store append failed: ${appended.stderr.trim() || `exit ${String(appended.code)}`}`, true);
            }
            await writeJson(turnPath, { ...current, reports: [...current.reports, seq] });

            return say(`recorded seq ${String(seq)} [${args.verdict}]; ${args.verdict === "captain" ? "the main Firstmate session is asked to process it" : "it stays in the outcome store"}`);
        },
    });

    const outcomesTool = defineTool({
        name: OUTCOMES_TOOL,
        description:
            "Read the durable outcome store of the supervision branch: what fleet events it handled, each verdict, and each summary. Use when the captain asks what happened in the fleet.",
        parameters: Type.Object({
            recent: Type.Optional(Type.Number({ description: "How many most-recent outcomes to read (default 20)" })),
        }),
        replay: "safe",
        execute: async (args, api) => {
            const home = await homeOf(api.env?.cwd);
            if (home === undefined) return say("could not read the outcome store: this session does not work in a Firstmate home", true);
            const recent = typeof args.recent === "number" && args.recent >= 1 ? String(Math.floor(args.recent)) : "20";
            const listed = await script(home, "fm-branch-outcome.sh", ["list", "--recent", recent]);
            if (listed.code !== 0) return say(`could not read the outcome store: ${listed.stderr.trim() || `exit ${String(listed.code)}`}`, true);

            return say(listed.stdout.trim() === "" ? "(no branch outcomes recorded)" : listed.stdout);
        },
    });

    const processed = defineTool({
        name: PROCESSED_TOOL,
        description:
            "Acknowledge that every captain-facing supervision outcome up to a sequence number has been processed by this conversation. Call it exactly once after handling a supervision processing request, with through set to the highest sequence that request listed; an outcome that is not acknowledged is presented again.",
        parameters: Type.Object({
            through: Type.Number({ description: "The highest outcome sequence number this conversation has processed" }),
        }),
        execute: async (args, api, context) => {
            const through = Number.isSafeInteger(args.through) && args.through >= 1 ? args.through : undefined;
            if (through === undefined) return say("acknowledgement refused: through must be a positive outcome sequence number", true);
            const home = await homeOf(api.env?.cwd);
            if (home === undefined || (await ownership(home, api.conversationId)) !== "owned") {
                return say("acknowledgement refused: this session does not own the fleet lock", true);
            }
            const active = await readJson<Processing>(join(stateOf(home), BRANCH_PROCESSING));
            if (active?.main !== Number(api.conversationId) || through > active.through) {
                return say(`acknowledgement refused: seq ${String(through)} was not listed in the active processing request`, true);
            }
            const marked = await script(home, "fm-branch-outcome.sh", ["mark-processed", "--through", String(through)]);
            if (marked.code !== 0) return say(`acknowledgement refused: ${marked.stderr.trim() || `exit ${String(marked.code)}`}`, true);
            // The next batch, if any, follows as its own processing request.
            const next = await supervision.present(home, api.conversationId);
            if (next !== undefined) {
                const conversation = await api.conversation(api.conversationId, context);
                await conversation?.submit(
                    { type: "input", content: next.text, whenBusy: "followUp", requestId: next.requestId, ...mainEntry(presented, "branch-outcome") },
                    context,
                );
            }

            return say(`processed through seq ${String(through)}; ${next === undefined ? "no captain outcome remains unprocessed" : "newer captain outcomes remain unprocessed and follow as the next processing request"}`);
        },
    });

    const repair = defineTool({
        name: REPAIR_TOOL,
        description:
            "Start the first Firstmate watcher cycle, or repair one only after a notification says the cycle is missing, failed, or unhealthy. Do not call after ordinary work or ordinary notifications; the Firstmate Pi Pocket drop-in re-arms automatically. Never run bin/fm-watch-arm.sh through bash.",
        parameters: Type.Object({}),
        replay: "safe",
        execute: async (_args, api, context) => {
            const say = (text: string) => ({ output: [{ type: "text" as const, text }] });
            const home = await homeOf(api.env?.cwd);
            if (home === undefined) return say("watcher: not armed - this session does not work in a Firstmate home");
            const owner = await ownership(home, api.conversationId);
            if (owner === "other") return say("watcher: read-only - the session lock is held by another firstmate session");
            if (owner === "missing") {
                return say(`watcher: not armed - no live session holds the lock; run bin/fm-session-start.sh to reclaim it, then call ${REPAIR_TOOL} to re-arm`);
            }
            if (!(await ensureWatch(api, watch, home, context))) {
                return say(`watcher: unchanged - the Firstmate Pi Pocket drop-in already runs this conversation's watcher task; no manual re-arm needed; call ${REPAIR_TOOL} again only after a later notification says the cycle is missing, failed, or unhealthy`);
            }

            return say(`watcher: started the Firstmate Pi Pocket watcher task; future ordinary re-arms are automatic; call ${REPAIR_TOOL} again only after a later notification says the cycle is missing, failed, or unhealthy`);
        },
    });

    /**
     * The first request of a fresh main conversation in a Firstmate home, the one before any answer: run the session
     * start as this conversation and give the model its whole digest, as Firstmate's Pi extension does at session
     * open, instead of asking the model to run it through bash, whose output cap keeps only the digest's tail. The
     * digest is placed as an entry right after the opening input, so every later request sees it where this one
     * did, and the session start that bound the lock here also starts the watcher. A recovered request, whose view
     * predates the placed entry, finds that entry in the commit and places nothing twice.
     */
    const firstStart = async (messages: readonly { role: string }[], api: HookApi, context: Context) => {
        if (messages.some((message) => message.role === "assistant")) return undefined;
        if (messages.some((message) => userText(message as never).startsWith(`${OPERATIONAL_PREFIX}session-start:`))) return undefined;
        const home = await homeOf(await hookCwd(api, api.conversationId, context));
        if (home === undefined || (await branchOf(home, api.conversationId)) !== undefined) return undefined;
        const runtime = api as HookApi & Partial<Pick<TaskRuntime<unknown, { phase: string }, unknown, object>, "commit" | "now">>;
        if (typeof runtime.commit !== "function") return undefined;
        const key = "x.firstmate.first-start";
        const digest = (await api.memo<string>(key, context)) ?? (await api.memo<string>(key, await sessionStart(home, api.conversationId, "startup"), context));
        const message = { role: "user" as const, content: [{ type: "text" as const, text: digest }], timestamp: runtime.now?.() ?? Date.now() };
        await runtime.commit(async (tx) => {
            const recent = await tx.scanEntries({ conversationId: api.conversationId }, 50);
            if (!recent.items.some((entry) => entry.kind === START_KIND)) {
                await tx.appendEntry(api.conversationId, { kind: START_KIND, model: [message], data: { summary: "session-start" } });
            }
            return undefined;
        }, context);
        if ((await ownership(home, api.conversationId)) === "owned") await ensureWatch(runtime as never, watch, home, context);

        return { messages: [...messages, message] as never };
    };

    return defineExtension({
        name: "firstmate",
        tools: [repair, report, outcomesTool, processed],
        tasks: [watch],
        sections: [
            section("firstmate", async (input) => {
                const home = await homeOf(input.env?.cwd);
                if (home === undefined) return undefined;
                if ((await branchOf(home, input.conversationId)) !== undefined) return branchPrompt(home);

                return `The Firstmate Pi Pocket drop-in is active in this session. It marks every bash call with this session's Pi Pocket identity, runs the Firstmate watcher as a durable background task once this session holds the home's session lock, delivers each watcher wake as a follow-up input, and runs the session start itself, giving this session its digest, on the first request, after a server restart, and after a compaction. ${SHELL_MODEL} Repair a missing or failed watcher only with the ${REPAIR_TOOL} tool. The linked session "${BRANCH_TITLE}" is this home's supervision branch: it handles the routine wakes it may take, and its captain outcomes reach this session as processing requests to acknowledge with ${PROCESSED_TOOL}.`;
            }),
        ],
        wraps: [
            // The supervision session's prompt is bin/fm-branch-prompt.sh alone: the home's AGENTS.md is main's
            // supervisor contract, and its skills list is main's, so neither is rendered there.
            ...["project_context", "skills"].map((key) =>
                wrapSection(key, (inner) => ({
                    ...inner,
                    render: async (input, context) =>
                        (await branchOf(await homeOf(input.env?.cwd), input.conversationId)) === undefined ? inner.render(input, context) : undefined,
                })),
            ),
            // In a Firstmate home every bash call carries the marker; the call that binds the home's lock to this
            // session (its session start) also starts the watcher. A watcher that later ends stays ended until the
            // repair tool, so a failing one cannot restart itself on every call. Every other session gets Pi Pocket's
            // own bash.
            wrapTool(createBashTool(), (bash) => ({
                ...bash,
                execute: async (args, api, context) => {
                    const home = await homeOf(api.env?.cwd);
                    if (home === undefined) return bash.execute(args, api, context);
                    const main = await branchOf(home, api.conversationId);
                    if (main !== undefined) return branchBash(main).execute(args, api, context);
                    const before = await ownership(home, api.conversationId);
                    const result = await marked.execute(args, api, context);
                    if (before !== "owned" && (await ownership(home, api.conversationId)) === "owned") {
                        await ensureWatch(api, watch, home, context);
                    }

                    return result;
                },
            })),
        ],
        hooks: [
            hook(ToolTask, {
                beforeTool: async (call, api, context) => {
                    const home = await homeOf(await hookCwd(api, api.conversationId, context));
                    if (home === undefined) return undefined;
                    const branch = (await branchOf(home, api.conversationId)) !== undefined;
                    if (branch && !BRANCH_TOOLS.has(call.name)) {
                        return { block: `[supervision-branch] the Firstmate supervision session uses only read, bash, ${REPORT_TOOL}, and the context tools ${CONTEXT_TOOLS.join(", ")}; ${call.name} belongs to the main Firstmate session.` };
                    }
                    if (!branch && call.name === REPORT_TOOL) {
                        return { block: `[supervision-branch] only the Firstmate supervision session records outcomes with ${REPORT_TOOL}.` };
                    }
                    if (call.name === "bash") {
                        const command = (call.arguments as { command?: unknown }).command;
                        if (typeof command !== "string") return undefined;
                        const block =
                            (await seatbelt(home, "fm-cd-pretool-check.sh", ["--command", command], "denied by the cd-guard PreToolUse seatbelt")) ??
                            (await seatbelt(home, "fm-arm-pretool-check.sh", ["--command", command], "denied by the watcher-arm PreToolUse seatbelt"));

                        return block === undefined ? undefined : { block };
                    }
                    if (POCKET_DELEGATION.has(call.name) && process.env.FM_ALLOW_SUBAGENT !== "1") {
                        return {
                            block: `[subagent-dispatch] the firstmate primary delegates fleet work only through bin/fm-spawn.sh; Pi Pocket's ${call.name} tool starts work with no fleet record and no supervision.`,
                        };
                    }
                    if (CODING_TOOLS.has(call.name) || [REPAIR_TOOL, REPORT_TOOL, OUTCOMES_TOOL, PROCESSED_TOOL].includes(call.name) || call.name.startsWith("mcp__")) {
                        return undefined;
                    }
                    const block = await seatbelt(home, "fm-subagent-pretool-check.sh", ["--tool", call.name], "denied by the subagent-dispatch PreToolUse seatbelt");

                    return block === undefined ? undefined : { block };
                },
            }),
            hook(GenerationTask, {
                // A fresh conversation's first request runs the session start, and after a compaction the digest is
                // gone from context: either way the hook runs it once and gives the model the whole digest.
                beforeRequest: async ({ messages }, api, context) => {
                    const summary = messages.findLastIndex((message) => userText(message as never).startsWith(COMPACTED));
                    if (summary < 0) return firstStart(messages, api, context);
                    const compaction = hash(userText(messages[summary] as never));
                    const after = messages.slice(summary + 1).some((message) => userText(message as never).startsWith(`${OPERATIONAL_PREFIX}session-start:`));
                    if (after) return undefined;
                    const home = await homeOf(await hookCwd(api, api.conversationId, context));
                    // The supervision session never owns the lock, so it never gets the digest.
                    if (home === undefined || (await ownership(home, api.conversationId)) !== "owned") return undefined;
                    const runtime = api as Partial<Pick<ToolExecutionApi, "conversation">>;
                    if (typeof runtime.conversation !== "function") return undefined;
                    const key = `x.firstmate.reemit-${compaction}`;
                    const digest = (await api.memo<string>(key, context)) ?? (await api.memo<string>(key, await sessionStart(home, api.conversationId, "compact"), context));
                    const conversation = await runtime.conversation(api.conversationId, context);
                    await conversation?.submit(
                        {
                            type: "input",
                            content: digest,
                            whenBusy: "steer",
                            requestId: `fm-reemit-${compaction}`,
                            ...mainEntry(presented, "session-start"),
                        },
                        context,
                    );

                    return undefined;
                },
                // A turn that would end with supervision off continues once with the guard's text.
                onYield: async (_answer, api, context) => {
                    const runtime = api as Partial<Pick<TaskRuntime<unknown, { phase: string }, unknown, object>, "context">>;
                    const view = await runtime.context?.(api.conversationId, context);
                    const last = view?.messages.findLast((message) => message.role === "user");
                    // The one forced continuation of this turn already ran: let it end.
                    const lastText = userText(last as never);
                    if (lastText.startsWith(`${OPERATIONAL_PREFIX}turn-end-guard:`) || lastText.startsWith(GUARD_HEADER)) {
                        return undefined;
                    }
                    const home = await homeOf(await hookCwd(api, api.conversationId, context));
                    // The supervision session's turns end with their report; supervision continuity is main's.
                    if (home === undefined || (await branchOf(home, api.conversationId)) !== undefined) return undefined;
                    const key = "x.firstmate.turn-end-guard";
                    let verdict = await api.memo<{ code: number; text: string }>(key, context);
                    if (verdict === undefined) {
                        const ran = await run(join(home, "bin", "fm-turnend-guard.sh"), [], {
                            cwd: home,
                            env: markerEnv(home, api.conversationId),
                            input: '{"stop_hook_active":false}',
                        });
                        verdict = await api.memo(key, { code: ran.code ?? 0, text: ran.stderr }, context);
                    }
                    if (verdict.code !== 2) return undefined;

                    return { continue: await encode(home, "turn-end-guard", `${GUARD_HEADER}${verdict.text}`) };
                },
            }),
        ],
    });
}
