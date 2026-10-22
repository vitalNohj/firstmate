/**
 * Firstmate: runs a Firstmate primary's main chat inside Pi Pocket. In a session whose folder is a Firstmate home it
 * marks every bash call with the session's Pi Pocket identity, keeps the watcher running as a durable background task
 * once the session holds the home's lock, delivers each watcher wake as a follow-up, guards turn ends and tool calls
 * the way Firstmate's Pi extensions do, and offers the fm_watch_arm_pocket repair tool. Every other session is
 * untouched. Install it with Firstmate's bin/fm-pi-pocket-install.sh, then turn it on in Menu → Extensions.
 */
import { spawn } from "node:child_process";
import { readFile, stat } from "node:fs/promises";
import { join } from "node:path";
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
    wrapTool,
} from "@earendil-works/pi-durable";
import type { Context } from "@earendil-works/chord";
import type { ConversationId, ToolExecutionApi, TaskRuntime } from "@earendil-works/pi-durable";
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

/** Owned when the lock names this server and its sidecar this conversation, as fm_session_lock_owned_by_self decides. */
async function ownership(home: string, conversationId: ConversationId): Promise<Ownership> {
    // The same state directory bin/fm-lock.sh binds, which the scripts the drop-in runs inherit from the server.
    const state = process.env.FM_STATE_OVERRIDE || join(home, "state");
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
// The watcher task

/** One delivery the model has not had yet: a watcher wake, or a restart's session-start digest. */
type Pending = { kind: "wake" | "digest"; text: string; requestId: string };
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

function createWatchTask(host: Partial<Host>) {
    const heldBack = (id: ConversationId) =>
        typeof host.heldBack === "function" ? host.heldBack(id) : undefined;
    const whenLimitsChange = (listener: () => void) =>
        typeof host.onLimitsChanged === "function" ? host.onLimitsChanged(listener) : () => {};

    /** A request id for unrequested work, paid by whoever asked last in the session, as Pi Pocket's schedules do. */
    const requestFor = (conversationId: ConversationId, key: string) => {
        const requester = typeof host.requesterOf === "function" ? host.requesterOf(conversationId) : undefined;

        return requester === undefined ? `fm-${clientKey(key)}` : `p:${requester}:${clientKey(key)}`;
    };

    /**
     * Deliver `content` as one follow-up keyed on `requestId`: a re-driven delivery finds the submission it already
     * made. While the session is past a spend limit it waits rather than start a turn nobody may pay for.
     */
    const deliver = async (runtime: WatchRuntime, context: Context, content: string, requestId: string, stop?: AbortSignal) => {
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
        await conversation.submit({ type: "input", content, whenBusy: "followUp", requestId }, context);
    };

    const contentOf = async (home: string, pending: Pending) =>
        pending.kind === "digest" ? pending.text : encode(home, "watcher", wakeText(pending.text));

    /** Deliver whatever is still pending, then the failure, and end the task: the model repairs with the tool. */
    const fail = async (task: { state: { checkpoint: WatchState }; input: WatchInput }, runtime: WatchRuntime, context: Context, failure: string) => {
        const { home } = task.input;
        const checkpoint = task.state.checkpoint;
        for (const pending of checkpoint.pending ?? []) {
            await deliver(runtime, context, await contentOf(home, pending), pending.requestId);
        }
        const requestId = requestFor(runtime.conversationId, `fm-watch-failed-${String(runtime.taskId)}-${checkpoint.seq}`);
        await deliver(runtime, context, await encode(home, "watcher", wakeText(failure)), requestId);
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
                    await runtime.commit(
                        () => ({ status: "running", checkpoint: { ...checkpoint, boot: BOOT, pending: [start, ...(checkpoint.pending ?? [])] } }),
                        context,
                    );
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
                            const pending = waiting.map((item, index) => (index === newest ? { ...item, text: `${item.text}\n\n${detail}` } : item));
                            next = { ...next, pending };
                            const confirmed = next;
                            await runtime.commit(() => ({ status: "running", checkpoint: confirmed }), context);
                        }
                    }

                    // Deliver the pending queue one by one while this arm keeps watching. A delivery waiting out a
                    // spend limit never holds the watcher: when the arm closes, the delivery stops where it is and
                    // the next cycle, with its successor running, takes the queue up again under the same request ids.
                    const halt = new AbortController();
                    let delivering: Promise<{ delivered: string } | { stopped: true }> | undefined;
                    const deliverNext = () => {
                        const first = next.pending?.[0];
                        delivering =
                            first === undefined
                                ? undefined
                                : contentOf(home, first)
                                      .then((content) => deliver(runtime, context, content, first.requestId, halt.signal))
                                      .then(
                                          () => ({ delivered: first.requestId }),
                                          (error: unknown) => {
                                              if (halt.signal.aborted || signal.aborted) return { stopped: true as const };
                                              throw error;
                                          },
                                      );
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
                                const pending = (next.pending ?? []).filter((item) => item.requestId !== event.delivered);
                                next = { ...next, pending };
                                if (pending.length === 0) delete next.pending;
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
                        if (settled !== undefined && "delivered" in settled) {
                            const pending = (next.pending ?? []).filter((item) => item.requestId !== settled.delivered);
                            next = { ...next, pending };
                            if (pending.length === 0) delete next.pending;
                        }
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
        await runtime.sleep(runtime.now() + retryDelay(failures), context);
        await runtime.commit(() => ({ status: "running", checkpoint: { ...checkpoint, failures, predecessor } }), context);
    }
}

type WatchTask = ReturnType<typeof createWatchTask>;

/** Start the conversation's watcher task unless one is live. True when this call started it. */
async function ensureWatch(
    api: Pick<ToolExecutionApi, "commit" | "conversationId">,
    watch: WatchTask,
    home: string,
    context: Context,
): Promise<boolean> {
    return api.commit(async (tx) => {
        const page = await tx.scanTasks({ conversationId: api.conversationId, kind: WATCH_KIND, order: "descending" }, 50);
        if (page.items.some((task) => task.state.status !== "terminal" && !task.abortRequested)) return false;
        await tx.createTask(watch, { home, boot: BOOT }, {
            ownership: { kind: "conversation" },
            background: true,
            abandonOnRestart: false,
            conversationId: api.conversationId,
        });

        return true;
    }, context);
}

// ---------------------------------------------------------------------------------------------------------------
// The extension

/** The working folder of a hook's session: its execution environment, else its agent's folder. */
async function hookCwd(api: unknown, conversationId: ConversationId, context: Context): Promise<string | undefined> {
    const runtime = api as Partial<Pick<TaskRuntime<unknown, { phase: string }, unknown, object>, "env" | "snapshot">>;
    const env = await runtime.env?.(context).catch(() => undefined);
    if (env?.cwd) return env.cwd;
    const agent = await runtime.snapshot?.(AgentDoc, conversationId, context);

    return agent?.cwd ?? process.cwd();
}

export default function createFirstmate(host: Partial<Host> = {}) {
    const watch = createWatchTask(host);

    const marked = createBashTool({
        prepare: (execution, api) => {
            Object.assign(execution.env, markerEnv(execution.cwd, api.conversationId));
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

    return defineExtension({
        name: "firstmate",
        tools: [repair],
        tasks: [watch],
        sections: [
            section("firstmate", async (input) => {
                if ((await homeOf(input.env?.cwd)) === undefined) return undefined;

                return `The Firstmate Pi Pocket drop-in is active in this session. It marks every bash call with this session's Pi Pocket identity, runs the Firstmate watcher as a durable background task once this session holds the home's session lock, delivers each watcher wake as a follow-up input, and runs the session start again after a server restart or a compaction. If this session has no Firstmate session-start digest yet, run \`bin/fm-session-start.sh\` once before anything else. Repair a missing or failed watcher only with the ${REPAIR_TOOL} tool.`;
            }),
        ],
        wraps: [
            // In a Firstmate home every bash call carries the marker; the call that binds the home's lock to this
            // session (its session start) also starts the watcher. A watcher that later ends stays ended until the
            // repair tool, so a failing one cannot restart itself on every call. Every other session gets Pi Pocket's
            // own bash.
            wrapTool(createBashTool(), (bash) => ({
                ...bash,
                execute: async (args, api, context) => {
                    const home = await homeOf(api.env?.cwd);
                    if (home === undefined) return bash.execute(args, api, context);
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
                    if (CODING_TOOLS.has(call.name) || call.name === REPAIR_TOOL || call.name.startsWith("mcp__")) return undefined;
                    const block = await seatbelt(home, "fm-subagent-pretool-check.sh", ["--tool", call.name], "denied by the subagent-dispatch PreToolUse seatbelt");

                    return block === undefined ? undefined : { block };
                },
            }),
            hook(GenerationTask, {
                // After a compaction the digest is gone from context: run the session start again, once, and send it.
                beforeRequest: async ({ messages }, api, context) => {
                    const summary = messages.findLastIndex((message) => userText(message as never).startsWith(COMPACTED));
                    if (summary < 0) return undefined;
                    const compaction = hash(userText(messages[summary] as never));
                    const after = messages.slice(summary + 1).some((message) => userText(message as never).startsWith(`${OPERATIONAL_PREFIX}session-start:`));
                    if (after) return undefined;
                    const home = await homeOf(await hookCwd(api, api.conversationId, context));
                    if (home === undefined || (await ownership(home, api.conversationId)) !== "owned") return undefined;
                    const runtime = api as Partial<Pick<ToolExecutionApi, "conversation">>;
                    if (typeof runtime.conversation !== "function") return undefined;
                    const key = `x.firstmate.reemit-${compaction}`;
                    const digest = (await api.memo<string>(key, context)) ?? (await api.memo<string>(key, await sessionStart(home, api.conversationId, "compact"), context));
                    const conversation = await runtime.conversation(api.conversationId, context);
                    await conversation?.submit(
                        { type: "input", content: digest, whenBusy: "steer", requestId: `fm-reemit-${compaction}` },
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
                    if (home === undefined) return undefined;
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
