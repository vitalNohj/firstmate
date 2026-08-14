// tests/pi-hook-harness.mjs - shared fake harness for the Pi captain-router hook.
//
// The hook classifies off the harness event loop, so a hook test needs a fake
// child-process boundary that can answer slowly plus a way to wait for a
// classification the `input` handler deliberately does not await. Import it by
// absolute path from an inline `node --input-type=module` test body:
//
//   const harness = await import(process.env.FM_HOOK_HARNESS);
import { EventEmitter } from "node:events";
import { mock } from "node:test";

// Stand-in for one spawned router child: stdout data then close, or an error.
// `delayMs` is what lets a test prove the `input` handler returned first, and
// `onInput` receives the captain message the hook writes to the child's stdin.
// `stdout` may be a function, so a fixture can answer per classified message.
export function fakeChild(stdout, options = {}) {
	const { delayMs = 0, error, onInput } = options;
	const child = new EventEmitter();
	child.stdin = new EventEmitter();
	child.stdin.end = (text) => onInput?.(text === undefined ? "" : String(text));
	child.stdout = new EventEmitter();
	child.stdout.setEncoding = () => {};
	setTimeout(() => {
		if (error) {
			child.emit("error", error);
			return;
		}
		const payload = typeof stdout === "function" ? stdout() : stdout;
		if (payload) child.stdout.emit("data", payload);
		child.emit("close", 0);
	}, delayMs);
	return child;
}

// Replace node:child_process for the hook under test. `lockOwned` answers the
// hook's lock probe, and `operational` answers its operational-input probe when
// supplied. `onSpawnSync` and `onSpawn` answer everything else. Any handler
// left out falls through to the real module, so a fixture can still cross the
// production child-process boundary into a real stub script.
export function installChildProcess(handlers) {
	const real = handlers.real;
	mock.module("node:child_process", {
		namedExports: {
			spawnSync(command, args, options) {
				if (
					command === "bash" &&
					args?.[3]?.endsWith("fm-session-lock-lib.sh")
				) {
					const owned = handlers.lockOwned?.() !== false;
					return { status: owned ? 0 : 1, stdout: "", stderr: "" };
				}
				if (
					handlers.operational &&
					String(command).endsWith("fm-operational-input.sh")
				) {
					const text = String(options?.input ?? "");
					return handlers.operational(text)
						? { status: 0, stdout: text, stderr: "" }
						: { status: 1, stdout: "", stderr: "" };
				}
				const handled = handlers.onSpawnSync?.(command, args, options);
				if (handled !== undefined) return handled;
				return real.spawnSync(command, args, options);
			},
			spawn(command, args, options) {
				const handled = handlers.onSpawn?.(command, args, options);
				if (handled !== undefined) return handled;
				return real.spawn(command, args, options);
			},
		},
	});
}

// Poll a predicate the hook satisfies from its own asynchronous drain.
export async function waitFor(predicate, label, timeoutMs = 5000) {
	const deadline = Date.now() + timeoutMs;
	for (;;) {
		if (predicate()) return;
		if (Date.now() >= deadline)
			throw new Error(`timed out waiting for ${label}`);
		await new Promise((resolve) => setTimeout(resolve, 5));
	}
}
