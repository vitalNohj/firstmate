import { spawn, spawnSync } from "node:child_process";
import { appendFileSync, mkdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type {
	AgentEndEvent,
	ExtensionAPI,
} from "@earendil-works/pi-coding-agent";
import { classifyFirstmateOperationalText } from "./lib/fm-operational-input.ts";

// Captain-message continuity router (P1) hook wiring - Pi primary only.
// Thin trigger layer: bin/fm-captain-message-router.sh owns scoping,
# classification, briefs, ephemeral router spawn, verdict logging, and pending
// handoff staging. This file only feeds settle/submit text (and an optional
// session id) and observes the machine-readable verdict line.
//
// NOT watcher continuity: unrelated to fm-primary-pi-watch.ts, the turn-end
// guard, or bin/fm-continuity-*. See docs/captain-message-router.md.
//
// P1 submit is synchronous so the hook can observe the verdict and so bash can
// stage pending routes before the primary turn proceeds. Settle stays
// fire-and-forget. Fail-open: spawn/parse errors never block the captain.
// Full cross-session compact+inject is P2; this hook does not spend primary
// context on continuity and never asks the primary agent to run it.

const extensionFile = fileURLToPath(import.meta.url);
const root = resolve(dirname(extensionFile), "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const router = `${root}/bin/fm-captain-message-router.sh`;
const hookLogDir = `${state}/captain-router`;
const hookLog = `${hookLogDir}/hook.log`;

// Last assistant turn text, captured on agent_end and consumed on agent_settled.
let lastAssistantText = "";

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

// Fire-and-forget settle path (anchors + brief refresh). stdout discarded.
function runRouterSettle(text: string, sessionId?: string): void {
	if (!text.trim()) return;
	try {
		const child = spawn(router, ["--on-settle", ...sessionArgs(sessionId)], {
			stdio: ["pipe", "ignore", "ignore"],
		});
		child.on("error", () => {});
		child.stdin.on("error", () => {});
		child.stdin.end(text);
	} catch {
		// Fail-open.
	}
}

// Synchronous submit path: capture the one verdict line. Always fail-open.
function runRouterSubmit(text: string, sessionId?: string): string {
	if (!text.trim()) return "";
	try {
		const result = spawnSync(router, ["--on-submit", ...sessionArgs(sessionId)], {
			input: text,
			encoding: "utf8",
			timeout: 120_000,
		});
		if (result.error) {
			rememberHookNote(`submit-spawn-error ${result.error.message}`);
			return "";
		}
		return String(result.stdout ?? "").trim();
	} catch (error) {
		rememberHookNote(
			`submit-exception ${error instanceof Error ? error.message : "unknown"}`,
		);
		return "";
	}
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

// Surface a durable hook-side pointer for P2 drop-in without injecting into the
// primary prompt (bash already stages pending/*.route).
function surfaceHandoff(verdict: string, target: string, confidence: string): void {
	try {
		mkdirSync(hookLogDir, { recursive: true });
		writeFileSync(
			`${hookLogDir}/last-handoff.txt`,
			[
				`verdict=${verdict}`,
				`target=${target}`,
				`confidence=${confidence}`,
				`staged_at=${new Date().toISOString()}`,
				"note=P1 stages intent only; P2 owns compact+inject drop-in",
				"",
			].join("\n"),
		);
		rememberHookNote(`handoff ${verdict} target=${target} conf=${confidence}`);
	} catch {
		// Fail-open.
	}
}

function eventSessionId(event: unknown): string | undefined {
	const record = event as {
		sessionId?: unknown;
		sessionID?: unknown;
		session_id?: unknown;
	};
	for (const key of ["sessionId", "sessionID", "session_id"] as const) {
		const value = record[key];
		if (typeof value === "string" && value.trim()) return value.trim();
	}
	return undefined;
}

// Concatenate the text blocks of the newest assistant message in an agent_end
// payload. Returns "" when there is no assistant text (e.g. a tool-only turn).
function newestAssistantText(event: AgentEndEvent): string {
	const messages = event.messages ?? [];
	for (let i = messages.length - 1; i >= 0; i -= 1) {
		const message = messages[i] as { role?: unknown; content?: unknown };
		if (message?.role !== "assistant") continue;
		const content = Array.isArray(message.content) ? message.content : [];
		return content
			.flatMap((block) => {
				const typed = block as { type?: unknown; text?: unknown };
				return typed?.type === "text" && typeof typed.text === "string"
					? [typed.text]
					: [];
			})
			.join("\n");
	}
	return "";
}

export default function (pi: ExtensionAPI) {
	// Submit side: the raw captain prompt, after expansion, before the agent loop.
	// Firstmate's own operational injections are not captain messages.
	pi.on("before_agent_start", (event) => {
		const prompt = String((event as { prompt?: unknown }).prompt ?? "");
		if (!prompt.trim()) return;
		if (classifyFirstmateOperationalText(prompt) !== undefined) return;
		const stdout = runRouterSubmit(prompt, eventSessionId(event));
		const parsed = parseVerdict(stdout);
		if (!parsed) {
			if (stdout) rememberHookNote(`unparseable-verdict ${stdout.slice(0, 200)}`);
			return;
		}
		if (parsed.verdict === "same") return;
		// reroute | new: bash staged pending/; record a hook-side handoff pointer.
		surfaceHandoff(parsed.verdict, parsed.target, parsed.confidence);
	});

	pi.on("agent_end", (event) => {
		lastAssistantText = newestAssistantText(event as AgentEndEvent);
	});

	pi.on("agent_settled", (event) => {
		const text = lastAssistantText;
		lastAssistantText = "";
		runRouterSettle(text, eventSessionId(event));
	});
}
