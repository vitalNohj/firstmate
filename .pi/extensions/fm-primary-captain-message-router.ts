import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
	appendFileSync,
	existsSync,
	mkdtempSync,
	mkdirSync,
	readFileSync,
	renameSync,
	rmSync,
	writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type {
	AgentEndEvent,
	ContextEvent,
	ExtensionAPI,
	InputEvent,
} from "@earendil-works/pi-coding-agent";
import { classifyFirstmateOperationalText } from "./lib/fm-operational-input.ts";

// Captain-message continuity router hook wiring - Pi primary only.
// bin/fm-captain-message-router.sh owns primary-home scope, state formats,
// classification, briefs, the ephemeral router spawn, verdict normalization
// and logging, fail-open fallback, and pending handoff staging. This hook owns
// callback-context session ids, session-lock eligibility, logical-run isolation,
// operational-input exclusion, bounded transcript handoff, and observation of
// the machine-readable verdict line.
//
// NOT watcher continuity: unrelated to fm-primary-pi-watch.ts, the turn-end
// guard, or bin/fm-continuity-*. See docs/captain-message-router.md.
//
// Submit never occupies Pi's input path: the `input` handler holds the send,
// returns immediately so the editor stays live, classifies off the event loop,
// and re-injects the held message through pi.sendUserMessage only on `same`.
// Slash traffic passes through instead of being held, because a re-injected
// copy skips Pi's skill and template expansion. Settle is synchronous so
// session replacement cannot overtake its publication. Fail-open: a spawn,
// timeout, or parse failure injects into the current session anyway.
// Submit always reaches the configured router model; bash owns the bound and
// the fail-open fallback.
// Cross-session compact+inject is not implemented; this hook does not spend
// primary context on continuity and never asks the primary agent to run it.

const extensionFile = fileURLToPath(import.meta.url);
const root = resolve(dirname(extensionFile), "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const router = `${root}/bin/fm-captain-message-router.sh`;
const sessionLockLib = `${root}/bin/fm-session-lock-lib.sh`;
const configDir = process.env.FM_CONFIG_OVERRIDE || `${fmHome}/config`;
const routerToggleFile = `${configDir}/captain-router`;
const hookLogDir = `${state}/captain-router`;
const hookLog = `${hookLogDir}/hook.log`;
const marker = `${state}/.pi-captain-router-extension-loaded`;
const warmRunnerScript =
	process.env.FM_CAPTAIN_ROUTER_RUNNER ||
	`${root}/bin/fm-captain-router-runner.mjs`;
const extensionVersion = `sha256:${createHash("sha256").update(readFileSync(extensionFile)).digest("hex")}`;
const HISTORY_MAX_TURNS = 12;
const HISTORY_MAX_CHARS = 6000;
// Every scanned user message costs one classify subprocess, so bound the scan
// itself: an operational message is skipped without collecting a line, and a
// long fleet session is mostly operational wakes.
const HISTORY_MAX_SCANNED = HISTORY_MAX_TURNS * 4;

function rememberHookNote(note: string): void {
	try {
		mkdirSync(hookLogDir, { recursive: true });
		appendFileSync(hookLog, `${new Date().toISOString()}\t${note}\n`);
	} catch {
		// Fail-open: never let hook bookkeeping impede the captain.
	}
}

function sessionArgs(sessionId: string | undefined): string[] {
	if (!sessionId || !/^[A-Za-z0-9._-]+$/.test(sessionId)) return [];
	return ["--session-id", sessionId];
}

type LockOwnership = "owned" | "missing" | "other";

function parentPid(pid: string): string {
	const result = spawnSync("ps", ["-o", "ppid=", "-p", pid], {
		encoding: "utf8",
	});
	if (result.status !== 0) return "";
	return String(result.stdout ?? "").trim();
}

function pidAlive(pid: string): boolean {
	try {
		process.kill(Number(pid), 0);
		return true;
	} catch {
		return false;
	}
}

function lockOwnership(): LockOwnership {
	let lockPid = "";
	try {
		lockPid = readFileSync(`${state}/.lock`, "utf8").trim();
	} catch {
		return "missing";
	}
	if (!/^[0-9]+$/.test(lockPid) || lockPid === "1") return "other";
	let pid = String(process.pid);
	for (let i = 0; i < 8; i += 1) {
		if (pid === lockPid) return "owned";
		pid = parentPid(pid);
		if (!pid || pid === "1") break;
	}
	return pidAlive(lockPid) ? "other" : "missing";
}

// Toggle parsing mirrors router_enabled() in bin/fm-captain-message-router.sh
// exactly: `off`, `0`, `false` (any case) disable, and anything else means on,
// because a router that silently disables itself is the same outage as one that
// silently drops messages. Do not tighten this into a stricter parser.
function toggleValueIsOff(raw: string): boolean {
	const stored = raw.replace(/\s/g, "");
	return (
		stored === "off" ||
		stored === "OFF" ||
		stored === "0" ||
		stored === "false" ||
		stored === "FALSE"
	);
}

type ToggleReport = {
	enabled: boolean;
	source: string;
	envOverride: string | undefined;
};

// The bash owner prefers a non-empty FM_CAPTAIN_ROUTER_ENABLED over the file,
// so read the same way rather than reporting a file value the owner ignores.
function readToggle(): ToggleReport {
	const env = process.env.FM_CAPTAIN_ROUTER_ENABLED;
	const envOverride = env ? env : undefined;
	if (envOverride) {
		return {
			enabled: !toggleValueIsOff(envOverride),
			source: `FM_CAPTAIN_ROUTER_ENABLED=${envOverride}`,
			envOverride,
		};
	}
	let raw = "";
	try {
		raw = readFileSync(routerToggleFile, "utf8");
	} catch {
		return {
			enabled: true,
			source: `${routerToggleFile} absent, and absent means on`,
			envOverride,
		};
	}
	if (!raw.replace(/\s/g, "")) {
		return {
			enabled: true,
			source: `${routerToggleFile} is empty, and that means on`,
			envOverride,
		};
	}
	const firstLine = raw.split("\n", 1)[0] ?? "";
	return {
		enabled: !toggleValueIsOff(firstLine),
		source: `${routerToggleFile} holds ${JSON.stringify(firstLine.trim())}`,
		envOverride,
	};
}

// Atomic: write a sibling temp file, then rename over the toggle, so a reader
// racing the write never sees a half-written or missing value. The trailing
// newline matches the documented `printf 'off\n'` form.
function writeToggle(value: "on" | "off"): void {
	mkdirSync(configDir, { recursive: true });
	const temp = `${routerToggleFile}.tmp.${process.pid}`;
	try {
		writeFileSync(temp, `${value}\n`);
		renameSync(temp, routerToggleFile);
	} catch (error) {
		try {
			rmSync(temp, { force: true });
		} catch {
			// The rename already consumed it, or the temp write never landed.
		}
		throw error;
	}
}

function markLoaded(): void {
	try {
		if (!existsSync(state) || lockOwnership() === "other") return;
		writeFileSync(marker, `${extensionVersion}\n${process.pid}\n`);
	} catch {
		return;
	}
}

function sessionLockOwned(): boolean {
	try {
		const result = spawnSync(
			"bash",
			[
				"-c",
				'. "$1"; fm_session_lock_owned_by_self "$2"',
				"fm-captain-router-lock-check",
				sessionLockLib,
				state,
			],
			{ stdio: "ignore" },
		);
		return result.status === 0;
	} catch {
		return false;
	}
}

// The warm classifier: one Pi RPC child that survives across submits, so a
// captain message no longer pays a vendor CLI cold start. Only the primary
// holding the Firstmate session lock runs one, and it is retired on shutdown
// and on session replacement. bin/fm-captain-router-runner.mjs owns the
// process; the bash owner falls back to its ephemeral spawn without it, so
// every failure here is silent.
let warmRunner: ReturnType<typeof spawn> | undefined;

function startWarmRunner(): void {
	if (warmRunner) return;
	if (!sessionLockOwned()) return;
	try {
		const child = spawn(
			process.execPath,
			[warmRunnerScript, "serve", "--state", state],
			{ stdio: ["pipe", "ignore", "ignore"] },
		);
		child.on("error", () => {
			warmRunner = undefined;
		});
		child.on("close", () => {
			warmRunner = undefined;
		});
		// The runner exits when this pipe closes, so it cannot outlive this Pi.
		child.unref();
		warmRunner = child;
	} catch {
		warmRunner = undefined;
	}
}

function retireWarmRunner(): void {
	const child = warmRunner;
	warmRunner = undefined;
	try {
		child?.stdin?.end();
		child?.kill("SIGTERM");
	} catch {
		// Fail-open: a runner that cannot be signaled still dies with this Pi.
	}
}

// Synchronous settle path (anchors + brief refresh). stdout discarded.
function runRouterSettle(text: string, sessionId?: string): void {
	if (!text.trim()) return;
	try {
		spawnSync(router, ["--on-settle", ...sessionArgs(sessionId)], {
			input: text,
			stdio: ["pipe", "ignore", "ignore"],
		});
	} catch {
		// Fail-open.
	}
}

// Asynchronous submit path: capture the one verdict line without occupying the
// harness event loop, so the editor stays live while the router classifies.
// Always fail-open: every failure resolves to an empty verdict.
function runRouterSubmit(
	text: string,
	sessionId: string | undefined,
	recentChatHistory: string,
): Promise<string> {
	if (!text.trim()) return Promise.resolve("");
	let historyDir = "";
	let historyFile = "";
	try {
		if (recentChatHistory) {
			historyDir = mkdtempSync(join(tmpdir(), "fm-captain-router-history-"));
			historyFile = join(historyDir, "history.txt");
			writeFileSync(historyFile, recentChatHistory, {
				flag: "wx",
				mode: 0o600,
			});
		}
	} catch {
		historyFile = "";
	}
	const discardHistory = (): void => {
		if (!historyDir) return;
		try {
			rmSync(historyDir, { force: true, recursive: true });
		} catch {
			// Fail-open.
		}
		historyDir = "";
	};
	return new Promise<string>((resolve) => {
		let settled = false;
		const finish = (verdictLine: string): void => {
			if (settled) return;
			settled = true;
			discardHistory();
			resolve(verdictLine);
		};
		let child: ReturnType<typeof spawn>;
		try {
			child = spawn(
				router,
				[
					"--on-submit",
					...sessionArgs(sessionId),
					...(historyFile ? ["--chat-history-file", historyFile] : []),
				],
				{ stdio: ["pipe", "pipe", "ignore"] },
			);
		} catch (error) {
			rememberHookNote(
				`submit-exception ${error instanceof Error ? error.message : "unknown"}`,
			);
			finish("");
			return;
		}
		let stdout = "";
		child.stdout?.setEncoding?.("utf8");
		child.stdout?.on("data", (chunk: unknown) => {
			stdout += String(chunk);
		});
		child.on("error", (error: Error) => {
			rememberHookNote(`submit-spawn-error ${error.message}`);
			finish("");
		});
		child.on("close", () => finish(stdout.trim()));
		// A router that exits before reading stdin must not raise EPIPE here.
		child.stdin?.on("error", () => {});
		try {
			child.stdin?.end(text);
		} catch {
			// Fail-open: the close/error handlers still resolve the verdict.
		}
	});
}

function parseVerdict(stdout: string): {
	verdict: string;
	target: string;
	confidence: string;
} | null {
	const line = stdout
		.split(/\r?\n/)
		.map((entry) => entry.trim())
		.find((entry) =>
			/^verdict=(same|reroute|new)\s+target=\S+\s+confidence=(det|model)$/.test(
				entry,
			),
		);
	if (!line) return null;
	const verdict = line.match(/^verdict=(\S+)/)?.[1] ?? "";
	const target = line.match(/\btarget=(\S+)/)?.[1] ?? "";
	const confidence = line.match(/\bconfidence=(\S+)/)?.[1] ?? "";
	if (!verdict || !target || !confidence) return null;
	return { verdict, target, confidence };
}

// Surface a durable hook-side pointer for the staged handoff. Whether the
// message then transfers to another session or stays here is recorded too, so
// last-handoff.txt never claims a transfer that did not happen.
function surfaceHandoff(
	verdict: string,
	target: string,
	confidence: string,
	delivery: DeliveryOutcome,
): void {
	try {
		mkdirSync(hookLogDir, { recursive: true });
		writeFileSync(
			`${hookLogDir}/last-handoff.txt`,
			[
				`verdict=${verdict}`,
				`target=${target}`,
				`confidence=${confidence}`,
				`staged_at=${new Date().toISOString()}`,
				`delivered=${delivery.delivered ? "yes" : "no"}`,
				`delivery_target=${delivery.target || "-"}`,
				`delivery_reason=${delivery.reason || "-"}`,
				delivery.delivered
					? "note=the message was transferred to its own visible session; it was not answered here"
					: "note=transfer did not happen, so the message was delivered into the current session instead",
				"",
			].join("\n"),
		);
		rememberHookNote(
			`handoff ${verdict} target=${target} conf=${confidence} delivered=${delivery.delivered} reason=${delivery.reason}`,
		);
	} catch {
		// Fail-open.
	}
}

type DeliveryOutcome = {
	delivered: boolean;
	target: string;
	reason: string;
};

// Hand the newest staged route to the bash owner for real delivery. Bash owns
// what a destination is and whether one was reached; this only reports the
// answer. Anything unexpected counts as NOT delivered, because the caller's
// fallback (deliver into the current session) is the safe direction.
function deliverStagedRoute(): Promise<DeliveryOutcome> {
	const undelivered = (reason: string): DeliveryOutcome => ({
		delivered: false,
		target: "",
		reason,
	});
	let routeFile = "";
	try {
		const latest = readFileSync(`${hookLogDir}/pending/LATEST`, "utf8").trim();
		if (!latest || latest.includes("/")) {
			return Promise.resolve(undelivered("no-staged-route"));
		}
		routeFile = `${hookLogDir}/pending/${latest}`;
	} catch {
		return Promise.resolve(undelivered("no-staged-route"));
	}
	return new Promise<DeliveryOutcome>((resolve) => {
		let child: ReturnType<typeof spawn>;
		try {
			child = spawn(router, ["--deliver", routeFile], {
				stdio: ["ignore", "pipe", "ignore"],
			});
		} catch {
			resolve(undelivered("deliver-spawn-failed"));
			return;
		}
		let stdout = "";
		child.stdout?.setEncoding?.("utf8");
		child.stdout?.on("data", (chunk: unknown) => {
			stdout += String(chunk);
		});
		child.on("error", () => resolve(undelivered("deliver-spawn-failed")));
		child.on("close", (code) => {
			const line = stdout
				.split(/\r?\n/)
				.map((entry) => entry.trim())
				.find((entry) => entry.startsWith("delivery="));
			const target = line?.match(/\btarget=(\S+)/)?.[1] ?? "";
			const reason = line?.match(/\breason=(\S+)/)?.[1] ?? "no-delivery-line";
			if (code === 0 && line?.startsWith("delivery=delivered")) {
				resolve({ delivered: true, target, reason });
				return;
			}
			resolve(undelivered(reason));
		});
	});
}

function contextSessionId(context: unknown): string | undefined {
	try {
		const sessionId = (
			context as {
				sessionManager?: { getSessionId?: () => unknown };
			}
		).sessionManager?.getSessionId?.();
		return typeof sessionId === "string" && sessionId.trim()
			? sessionId.trim()
			: undefined;
	} catch {
		return undefined;
	}
}

// Flatten one message's text blocks. Non-text blocks (tool calls, images) are
// dropped: the router judges the conversation, not the tool traffic.
function messageText(message: unknown): string {
	const content = (message as { content?: unknown })?.content;
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	return content
		.flatMap((block) => {
			const typed = block as { type?: unknown; text?: unknown };
			return typed?.type === "text" && typeof typed.text === "string"
				? [typed.text]
				: [];
		})
		.join("\n");
}

// Bounded recent transcript for the router prompt: the newest user/assistant
// turns only, capped by turn count and characters. Firstmate's own operational
// injections are dropped here and bash redacts again on its side.
function recentTranscript(event: AgentEndEvent): string {
	const messages = event.messages ?? [];
	const lines: string[] = [];
	let scanned = 0;
	for (let i = messages.length - 1; i >= 0; i -= 1) {
		if (lines.length >= HISTORY_MAX_TURNS) break;
		const role = (messages[i] as { role?: unknown }).role;
		if (role !== "user" && role !== "assistant") continue;
		const text = messageText(messages[i]).trim();
		if (!text) continue;
		if (scanned >= HISTORY_MAX_SCANNED) break;
		scanned += 1;
		if (
			role === "user" &&
			classifyFirstmateOperationalText(text) !== undefined
		) {
			continue;
		}
		lines.unshift(`${role}: ${text}`);
	}
	const joined = lines.join("\n\n");
	return joined.length > HISTORY_MAX_CHARS
		? joined.slice(joined.length - HISTORY_MAX_CHARS)
		: joined;
}
// Text of the newest assistant message in an agent_end payload. Returns ""
// when there is no assistant text (e.g. a tool-only turn).
function newestAssistantText(event: AgentEndEvent): string {
	const messages = event.messages ?? [];
	for (let i = messages.length - 1; i >= 0; i -= 1) {
		const message = messages[i] as { role?: unknown };
		if (message?.role !== "assistant") continue;
		return messageText(messages[i]);
	}
	return "";
}

export default function (pi: ExtensionAPI) {
	type RunState = {
		sessionId: string | undefined;
		generation: number;
		hasCaptainInput: boolean;
		hasOperationalInput: boolean;
		intakeRecords: Array<{
			prompt: string;
			sessionId: string | undefined;
			generation: number;
			operational: boolean;
		}>;
		fallbackPrompts: Set<string>;
		candidateAssistantText: string;
		candidateRecentChatHistory: string;
	};

	let activeSessionId: string | undefined;
	let sessionBound = false;
	let nextRunGeneration = 0;
	let activeRunGeneration = 0;
	let currentRun: RunState | undefined;
	let recentChatHistory = "";
	let observedSessionStartMessages = new Set<number>();

	function newRun(sessionId: string | undefined): RunState {
		nextRunGeneration += 1;
		activeRunGeneration = nextRunGeneration;
		return {
			sessionId,
			generation: nextRunGeneration,
			hasCaptainInput: false,
			hasOperationalInput: false,
			intakeRecords: [],
			fallbackPrompts: new Set(),
			candidateAssistantText: "",
			candidateRecentChatHistory: "",
		};
	}

	function bindSession(
		context: unknown,
		allowReplacement = false,
	): string | undefined {
		const sessionId = contextSessionId(context);
		if (!sessionBound || (allowReplacement && sessionId !== activeSessionId)) {
			// A replaced session must not inherit the previous session's warm chat.
			if (sessionBound) retireWarmRunner();
			activeSessionId = sessionId;
			currentRun = undefined;
			recentChatHistory = "";
			observedSessionStartMessages = new Set();
			sessionBound = true;
		}
		return sessionId;
	}

	function runForInput(
		sessionId: string | undefined,
		streamingBehavior: unknown,
	): RunState {
		if (
			!currentRun ||
			currentRun.sessionId !== sessionId ||
			(streamingBehavior === undefined && currentRun.hasCaptainInput)
		) {
			currentRun = newRun(sessionId);
		}
		return currentRun;
	}

	function markOperational(run: RunState): void {
		run.hasOperationalInput = true;
		run.candidateAssistantText = "";
		run.candidateRecentChatHistory = "";
	}

	// A held captain send waiting on its verdict. `deliver` is false for input
	// that already passed through to Pi (slash traffic and the fallback path):
	// those are classified for their verdict only and never re-injected.
	type PendingSubmit = {
		prompt: string;
		images: InputEvent["images"];
		sessionId: string | undefined;
		generation: number;
		history: string;
		deliver: boolean;
		deliverAs: "steer" | "followUp" | undefined;
	};

	const pendingSubmits: PendingSubmit[] = [];
	// Prompts this hook injected itself, so the copy Pi echoes back as
	// `source === "extension"` is not classified a second time.
	const injectedPrompts = new Map<string, number>();
	let draining = false;

	function rememberInjectedPrompt(prompt: string): void {
		injectedPrompts.set(prompt, (injectedPrompts.get(prompt) ?? 0) + 1);
	}

	function consumeInjectedPrompt(prompt: string): boolean {
		const count = injectedPrompts.get(prompt);
		if (!count) return false;
		if (count === 1) injectedPrompts.delete(prompt);
		else injectedPrompts.set(prompt, count - 1);
		return true;
	}

	function injectHeldSubmit(submit: PendingSubmit): void {
		rememberInjectedPrompt(submit.prompt);
		try {
			const content = submit.images?.length
				? [{ type: "text" as const, text: submit.prompt }, ...submit.images]
				: submit.prompt;
			pi.sendUserMessage(content, {
				deliverAs: submit.deliverAs ?? "followUp",
			});
		} catch (error) {
			consumeInjectedPrompt(submit.prompt);
			rememberHookNote(
				`inject-failed ${error instanceof Error ? error.message : "unknown"}`,
			);
		}
	}

	// Classify one held send, then act on its verdict.
	//
	// A reroute/new verdict is only allowed to withhold the message from THIS
	// chat when the message provably landed somewhere else. Delivery confirmed:
	// the captain sees it answered in its own visible session, and answering it
	// here too would duplicate the turn. Delivery refused or failed for any
	// reason: it comes back here. Every other path - a classifier error, a
	// timeout, an unparseable verdict - is a `same` and lands here as well.
	//
	// The invariant this enforces is that no verdict destroys a captain message.
	// Withholding is conditional on a confirmed transfer; it is never the default.
	async function resolveSubmit(submit: PendingSubmit): Promise<void> {
		let parsed: ReturnType<typeof parseVerdict> = null;
		try {
			const stdout = await runRouterSubmit(
				submit.prompt,
				submit.sessionId,
				submit.history,
			);
			parsed = parseVerdict(stdout);
			if (!parsed && stdout) {
				rememberHookNote(`unparseable-verdict ${stdout.slice(0, 200)}`);
			}
		} catch (error) {
			rememberHookNote(
				`submit-exception ${error instanceof Error ? error.message : "unknown"}`,
			);
		}
		if (parsed && parsed.verdict !== "same") {
			let delivery: DeliveryOutcome = {
				delivered: false,
				target: "",
				reason: "deliver-exception",
			};
			try {
				delivery = await deliverStagedRoute();
			} catch (error) {
				rememberHookNote(
					`deliver-exception ${error instanceof Error ? error.message : "unknown"}`,
				);
			}
			surfaceHandoff(
				parsed.verdict,
				parsed.target,
				parsed.confidence,
				delivery,
			);
			if (delivery.delivered) return;
		}
		if (submit.deliver) injectHeldSubmit(submit);
	}

	// One held send at a time, in submit order, so a queued Enter press cannot
	// overtake the send before it.
	async function drainPendingSubmits(): Promise<void> {
		if (draining) return;
		draining = true;
		try {
			for (
				let submit = pendingSubmits.shift();
				submit;
				submit = pendingSubmits.shift()
			) {
				await resolveSubmit(submit);
			}
		} finally {
			draining = false;
		}
	}

	function queueSubmit(submit: PendingSubmit): void {
		pendingSubmits.push(submit);
		void drainPendingSubmits();
	}

	// The control surface over the existing kill switch. No routing behavior
	// changes here: the value is read per message by the bash owner, so a toggle
	// takes effect on the very next captain message with no restart.
	pi.registerCommand?.("captain-router", {
		description:
			"Toggle captain-message routing, or set it: /captain-router [on|off].",
		handler: async (args, ctx) => {
			const argument = String(args ?? "").trim();
			let wanted: "on" | "off";
			if (argument) {
				const requested = argument.toLowerCase();
				if (requested !== "on" && requested !== "off") {
					ctx.ui.notify(
						`captain-router: unrecognized argument ${JSON.stringify(argument)}. Valid: /captain-router (flip), /captain-router on, /captain-router off.`,
						"error",
					);
					return;
				}
				wanted = requested;
			} else {
				// Flip relative to the effective state readToggle() reports, which
				// already folds in the environment override, so a bare call never
				// writes the value routing is already running under.
				wanted = readToggle().enabled ? "off" : "on";
			}
			try {
				writeToggle(wanted);
			} catch (error) {
				ctx.ui.notify(
					`captain-router: could not write ${routerToggleFile}: ${error instanceof Error ? error.message : String(error)}`,
					"error",
				);
				return;
			}
			const report = readToggle();
			// Under an override the written value is not the running state, so lead
			// with the effective state rather than claiming the write took hold.
			if (report.envOverride) {
				ctx.ui.notify(
					[
						`captain-router: ${routerToggleFile} now holds "${wanted}", but FM_CAPTAIN_ROUTER_ENABLED=${report.envOverride} is set and overrides that file.`,
						`Routing stays ${report.enabled ? "on" : "off"} until that variable is unset.`,
					].join("\n"),
					"warning",
				);
				return;
			}
			ctx.ui.notify(
				`captain-router: ${wanted}. ${routerToggleFile} now holds "${wanted}" (${report.source}). Effective on the next captain message, with no restart.`,
				"info",
			);
		},
	});

	pi.on?.("session_start", (_event, context) => {
		bindSession(context, true);
		markLoaded();
		startWarmRunner();
	});

	pi.on?.("session_shutdown", () => {
		retireWarmRunner();
	});

	pi.on("context", (event, context) => {
		const sessionId = bindSession(context);
		if (sessionId !== activeSessionId || !sessionLockOwned()) return;
		const run = currentRun;
		if (!run || run.sessionId !== sessionId) return;
		for (const entry of (event as ContextEvent).messages ?? []) {
			const message = entry as {
				role?: unknown;
				customType?: unknown;
				details?: { kind?: unknown };
				timestamp?: unknown;
			};
			if (
				message.role !== "custom" ||
				message.customType !== "firstmate-sessionstart-nudge" ||
				message.details?.kind !== "session-start" ||
				typeof message.timestamp !== "number" ||
				!Number.isFinite(message.timestamp)
			) {
				continue;
			}
			if (observedSessionStartMessages.has(message.timestamp)) continue;
			observedSessionStartMessages.add(message.timestamp);
			markOperational(run);
		}
	});

	// The handler never awaits the router: it holds the send, queues the
	// classification, and returns at once so the editor keeps accepting input.
	pi.on("input", (event, context) => {
		const sessionId = bindSession(context);
		if (sessionId !== activeSessionId) return { action: "continue" };
		const input = event as InputEvent;
		const prompt = String(input.text ?? "");
		if (!prompt.trim()) return { action: "continue" };
		// This hook's own re-injected copy: already classified, let it through.
		if (input.source === "extension" && consumeInjectedPrompt(prompt)) {
			return { action: "continue" };
		}
		if (!sessionLockOwned()) return { action: "continue" };
		const run = runForInput(sessionId, input.streamingBehavior);
		const operational = classifyFirstmateOperationalText(prompt) !== undefined;
		run.intakeRecords.push({
			prompt,
			sessionId,
			generation: run.generation,
			operational,
		});
		if (operational) {
			markOperational(run);
			return { action: "continue" };
		}
		run.hasCaptainInput = true;
		// A re-injected copy skips Pi's skill and template expansion, so slash
		// traffic passes through to expansion and is classified without a hold.
		const deliver = !prompt.startsWith("/");
		queueSubmit({
			prompt,
			images: input.images,
			sessionId,
			generation: run.generation,
			history: run.candidateRecentChatHistory || recentChatHistory,
			deliver,
			deliverAs: input.streamingBehavior,
		});
		return deliver ? { action: "handled" } : { action: "continue" };
	});

	// Fallback for a genuine accepted prompt path that did not emit `input`.
	// Ordinary idle input is deduplicated by exact prompt within the run.
	pi.on("before_agent_start", (event, context) => {
		const sessionId = bindSession(context);
		if (sessionId !== activeSessionId) return;
		const prompt = String((event as { prompt?: unknown }).prompt ?? "");
		if (!prompt.trim()) return;
		if (!sessionLockOwned()) return;
		if (!currentRun || currentRun.sessionId !== sessionId) {
			currentRun = newRun(sessionId);
		}
		const run: RunState = currentRun;
		if (run.intakeRecords.length > 0 || run.fallbackPrompts.has(prompt)) return;
		run.fallbackPrompts.add(prompt);
		if (classifyFirstmateOperationalText(prompt) !== undefined) {
			markOperational(run);
			return;
		}
		run.hasCaptainInput = true;
		// This prompt already reached the agent, so classify it for its verdict
		// only: re-injecting it here would duplicate the captain's message.
		queueSubmit({
			prompt,
			images: undefined,
			sessionId,
			generation: run.generation,
			history: run.candidateRecentChatHistory || recentChatHistory,
			deliver: false,
			deliverAs: undefined,
		});
	});

	pi.on("agent_end", (event, context) => {
		const sessionId = bindSession(context);
		if (sessionId !== activeSessionId) return;
		const run = currentRun;
		if (!run || run.sessionId !== sessionId) return;
		if (!run.hasCaptainInput || run.hasOperationalInput) return;
		if (!sessionLockOwned()) {
			currentRun = undefined;
			return;
		}
		run.candidateAssistantText = newestAssistantText(event as AgentEndEvent);
		run.candidateRecentChatHistory = recentTranscript(event as AgentEndEvent);
	});

	pi.on("agent_settled", (_event, context) => {
		const sessionId = bindSession(context);
		if (sessionId !== activeSessionId) return;
		const run = currentRun;
		if (!run || run.sessionId !== sessionId) return;
		const generation = run.generation;
		currentRun = undefined;
		if (!run.hasCaptainInput || run.hasOperationalInput) return;
		if (!sessionLockOwned()) return;
		if (activeSessionId !== sessionId || activeRunGeneration !== generation)
			return;
		runRouterSettle(run.candidateAssistantText, sessionId);
		// An aborted turn never reaches agent_end, so the candidate stays empty:
		// keep the prior transcript rather than blanking the router's context.
		if (run.candidateRecentChatHistory) {
			recentChatHistory = run.candidateRecentChatHistory;
		}
	});

	markLoaded();
}
