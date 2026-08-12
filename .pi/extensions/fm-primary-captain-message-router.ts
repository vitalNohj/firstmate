import { spawn } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type {
	AgentEndEvent,
	ExtensionAPI,
} from "@earendil-works/pi-coding-agent";
import { classifyFirstmateOperationalText } from "./lib/fm-operational-input.ts";

// Captain-message continuity router (P0) hook wiring - Pi primary only.
// This is the thin trigger layer described in data/firstmate-captain-continuity/spec.md
// section 6a. It owns NOTHING: bin/fm-captain-message-router.sh owns all scoping,
// classification, anchor persistence, and verdict logging. This file only feeds it
// the captain's submitted message (submit) and the last assistant turn (settle).
//
// NOT watcher continuity: unrelated to fm-primary-pi-watch.ts, the turn-end guard,
// or bin/fm-continuity-*. See the spec's disambiguation banner.
//
// P0 is log-only: every router invocation is fire-and-forget and its stdout is
// discarded. Nothing is injected into the primary context (the router's own
// multi-ask stderr surface is the only human-visible output, and it never blocks).
// Fail-safe: any spawn error is swallowed so the captain is never impeded.

const extensionFile = fileURLToPath(import.meta.url);
const root = resolve(dirname(extensionFile), "../..");
const router = `${root}/bin/fm-captain-message-router.sh`;

// Last assistant turn text, captured on agent_end and consumed on agent_settled.
let lastAssistantText = "";

// Fire the router in a chosen mode with the given text on stdin, discarding
// stdout (P0 is log-only). Never throws; a spawn failure is a silent no-op so a
// broken router can never impede the captain.
function runRouter(mode: "--on-settle" | "--on-submit", text: string): void {
	if (!text.trim()) return;
	try {
		const child = spawn(router, [mode], {
			stdio: ["pipe", "ignore", "ignore"],
		});
		child.on("error", () => {});
		child.stdin.on("error", () => {});
		child.stdin.end(text);
	} catch {
		// Fail-open: never let a router spawn failure reach the captain.
	}
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
	// Firstmate's own operational injections (session-start, watcher, turn-end
	// guard, away-supervisor, launch-brief, from-firstmate) are not captain
	// messages, so they never route.
	pi.on("before_agent_start", (event) => {
		const prompt = String((event as { prompt?: unknown }).prompt ?? "");
		if (!prompt.trim()) return;
		if (classifyFirstmateOperationalText(prompt) !== undefined) return;
		runRouter("--on-submit", prompt);
	});

	// Settle side: capture the last assistant turn as it ends, then refresh the
	// open-ask anchors once the run has fully settled (matching the turn-end guard's
	// use of agent_settled: it also covers abort/failure via a finally block).
	pi.on("agent_end", (event) => {
		lastAssistantText = newestAssistantText(event as AgentEndEvent);
	});

	pi.on("agent_settled", () => {
		const text = lastAssistantText;
		lastAssistantText = "";
		runRouter("--on-settle", text);
	});
}
