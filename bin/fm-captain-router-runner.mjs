#!/usr/bin/env node
// fm-captain-router-runner.mjs - the warm classifier process for the captain
// message router.
//
// Classification used to boot a fresh vendor CLI per captain message, so every
// submit paid a full agent cold start. This owner keeps ONE Pi RPC child alive
// and feeds it one prompt per submit, so only the model call itself remains on
// the path.
//
// This file owns the warm process only: its lifetime, its request framing, and
// its per-request chat wipe. It does not own classification.
// bin/fm-captain-message-router.sh still assembles every prompt, normalizes and
// logs every verdict, and owns the fail-open fallback: a runner that is absent,
// wedged, or wrong simply loses the request, and the router falls back to its
// ephemeral vendor spawn. See docs/captain-message-router.md.
//
// Usage:
//   fm-captain-router-runner.mjs serve --state <dir> [--model <id>] [--pi <path>]
//   fm-captain-router-runner.mjs classify --state <dir> --prompt-file <path>
//   fm-captain-router-runner.mjs stop --state <dir>
//
// serve: start the warm child and listen on <dir>/captain-router/runner.sock.
//   Serving is lock-gated by its caller, not here: only the Pi primary that
//   holds the Firstmate session lock starts one. The runner exits when its
//   stdin closes, so it can never outlive the primary that started it.
// classify: hand one assembled prompt file to the warm child and print its
//   reply on stdout. Exits non-zero whenever the warm path cannot answer, which
//   is the router's signal to fall back.
// stop: retire the running server for this state directory.
//
// Every request gets a fresh chat (`new_session` before the prompt), so
// verdicts never accumulate into each other and the Nth submit costs the same
// as the first.

import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { createConnection, createServer } from "node:net";
import {
	existsSync,
	mkdirSync,
	readFileSync,
	rmSync,
	writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

// The warm child hosts whatever model Pi is configured for unless the caller
// pins one. FM_CAPTAIN_ROUTER_MODEL names a Cursor id for the ephemeral
// fallback spawn, which is a different catalog, so it is deliberately not read
// here: pin the warm child with FM_CAPTAIN_ROUTER_RUNNER_MODEL.
const RUNNER_MODEL = process.env.FM_CAPTAIN_ROUTER_RUNNER_MODEL || "";
const RUNNER_PI = process.env.FM_CAPTAIN_ROUTER_PI || "pi";
// A wedged model call must not pin the warm child forever: the request is
// abandoned, the child is recycled, and the caller falls back.
const REQUEST_TIMEOUT_MS = 90_000;

// Print this file's own header comment, matching the shell owners' --help.
function usage() {
	let source = "";
	try {
		source = readFileSync(new URL(import.meta.url), "utf8");
	} catch {
		return "fm-captain-router-runner.mjs serve|classify|stop --state <dir>";
	}
	const lines = [];
	for (const line of source.split("\n").slice(1)) {
		if (!line.startsWith("//")) break;
		lines.push(line.replace(/^\/\/ ?/, ""));
	}
	return lines.join("\n");
}

function parseArgs(argv) {
	const args = { command: argv[0] };
	for (let i = 1; i < argv.length; i += 1) {
		const flag = argv[i];
		if (!flag.startsWith("--"))
			return { error: `unexpected argument: ${flag}` };
		const value = argv[i + 1];
		if (value === undefined) return { error: `${flag} requires a value` };
		args[flag.slice(2)] = value;
		i += 1;
	}
	return args;
}

// The socket lives in the temp dir, not the state dir: a Firstmate home can sit
// well past the ~104-byte sockaddr_un path limit, and a bind failure there
// would silently cost every submit its warm path. The name is derived from the
// state dir, so serve and classify agree without a lookup, and two homes on one
// host never collide.
function runnerPaths(state) {
	const dir = join(state, "captain-router");
	const digest = createHash("sha256")
		.update(resolve(state))
		.digest("hex")
		.slice(0, 16);
	return {
		dir,
		socket: join(tmpdir(), `fm-captain-router-${digest}.sock`),
		pid: join(dir, "runner.pid"),
	};
}

// One Pi RPC child, one request at a time. Each request wipes the chat first,
// so the warm child carries no memory of earlier captain messages.
class WarmChild {
	constructor(pi, model) {
		this.pi = pi;
		this.model = model;
		this.child = undefined;
		this.buffer = "";
		this.pending = undefined;
	}

	start() {
		const args = ["--mode", "rpc", "--no-session", "--no-tools"];
		if (this.model) args.push("--model", this.model);
		const child = spawn(this.pi, args, {
			stdio: ["pipe", "pipe", "ignore"],
			env: {
				...process.env,
				PI_CODING_AGENT: undefined,
				FM_PI_HARNESS: undefined,
			},
		});
		child.stdout.setEncoding("utf8");
		child.stdout.on("data", (chunk) => this.consume(chunk));
		child.on("close", () => {
			this.child = undefined;
			this.settle({ error: "warm classifier child exited" });
		});
		child.on("error", (error) => {
			this.child = undefined;
			this.settle({ error: `warm classifier child failed: ${error.message}` });
		});
		this.child = child;
	}

	// RPC framing is strict JSONL on LF, so split on LF only.
	consume(chunk) {
		this.buffer += chunk;
		let index = this.buffer.indexOf("\n");
		while (index >= 0) {
			const line = this.buffer.slice(0, index).replace(/\r$/, "");
			this.buffer = this.buffer.slice(index + 1);
			if (line) this.handleEvent(line);
			index = this.buffer.indexOf("\n");
		}
	}

	handleEvent(line) {
		let event;
		try {
			event = JSON.parse(line);
		} catch {
			return;
		}
		const pending = this.pending;
		if (!pending) return;
		if (event.type === "response" && event.id === pending.wipeId) {
			pending.onWiped(event.success === true);
			return;
		}
		if (event.type === "message_end" && event.message?.role === "assistant") {
			const text = (event.message.content ?? [])
				.filter(
					(block) => block?.type === "text" && typeof block.text === "string",
				)
				.map((block) => block.text)
				.join("");
			if (text.trim()) pending.text = text;
			return;
		}
		if (event.type === "agent_settled") pending.onSettled();
	}

	settle(result) {
		const pending = this.pending;
		if (!pending) return;
		this.pending = undefined;
		clearTimeout(pending.timer);
		pending.resolve(result);
	}

	send(command) {
		this.child?.stdin.write(`${JSON.stringify(command)}\n`);
	}

	// Recycle after any failed request: a child that lost framing or wedged
	// mid-turn would poison every later classification.
	recycle() {
		const child = this.child;
		this.child = undefined;
		this.buffer = "";
		try {
			child?.kill("SIGKILL");
		} catch {
			// The child is already gone.
		}
		this.start();
	}

	classify(prompt) {
		if (this.pending)
			return Promise.resolve({ error: "warm classifier is busy" });
		if (!this.child) this.start();
		return new Promise((resolve) => {
			const pending = {
				resolve,
				text: "",
				wipeId: `wipe-${Date.now()}`,
				onWiped: (ok) => {
					if (!ok) {
						this.settle({
							error: "warm classifier could not start a fresh chat",
						});
						this.recycle();
						return;
					}
					this.send({ type: "prompt", message: prompt });
				},
				onSettled: () => {
					const text = pending.text;
					this.settle(
						text ? { text } : { error: "warm classifier returned no text" },
					);
					if (!text) this.recycle();
				},
			};
			pending.timer = setTimeout(() => {
				this.settle({ error: "warm classifier timed out" });
				this.recycle();
			}, REQUEST_TIMEOUT_MS);
			this.pending = pending;
			this.send({ type: "new_session", id: pending.wipeId });
		});
	}

	stop() {
		try {
			this.child?.kill("SIGTERM");
		} catch {
			// Already gone.
		}
		this.child = undefined;
	}
}

function serve(args) {
	const state = args.state;
	if (!state) return fatal("serve requires --state");
	const paths = runnerPaths(state);
	mkdirSync(paths.dir, { recursive: true });
	// A stale socket from a killed predecessor would block the bind.
	rmSync(paths.socket, { force: true });

	const warm = new WarmChild(args.pi || RUNNER_PI, args.model || RUNNER_MODEL);
	warm.start();

	const server = createServer((socket) => {
		socket.setEncoding("utf8");
		let buffer = "";
		socket.on("data", async (chunk) => {
			buffer += chunk;
			const index = buffer.indexOf("\n");
			if (index < 0) return;
			const line = buffer.slice(0, index);
			buffer = "";
			let request;
			try {
				request = JSON.parse(line);
			} catch {
				socket.end(`${JSON.stringify({ error: "unparseable request" })}\n`);
				return;
			}
			let prompt = "";
			try {
				prompt = readFileSync(request.promptFile, "utf8");
			} catch (error) {
				socket.end(
					`${JSON.stringify({ error: `unreadable prompt file: ${error.message}` })}\n`,
				);
				return;
			}
			const result = await warm.classify(prompt);
			socket.end(`${JSON.stringify(result)}\n`);
		});
		socket.on("error", () => socket.destroy());
	});

	const shutdown = () => {
		warm.stop();
		server.close();
		rmSync(paths.socket, { force: true });
		rmSync(paths.pid, { force: true });
		process.exit(0);
	};
	process.on("SIGTERM", shutdown);
	process.on("SIGINT", shutdown);
	// The starter holds this pipe, so the runner can never outlive it.
	process.stdin.resume();
	process.stdin.on("end", shutdown);
	process.stdin.on("close", shutdown);

	server.on("error", (error) => fatal(`could not listen: ${error.message}`));
	server.listen(paths.socket, () => {
		writeFileSync(paths.pid, `${process.pid}\n`);
		process.stdout.write("ready\n");
	});
	return undefined;
}

function classify(args) {
	const state = args.state;
	const promptFile = args["prompt-file"];
	if (!state) return fatal("classify requires --state");
	if (!promptFile) return fatal("classify requires --prompt-file");
	const paths = runnerPaths(state);
	if (!existsSync(paths.socket))
		return fatal("no warm classifier is listening");
	const socket = createConnection(paths.socket);
	socket.setEncoding("utf8");
	let buffer = "";
	socket.on("connect", () =>
		socket.write(`${JSON.stringify({ promptFile })}\n`),
	);
	socket.on("data", (chunk) => {
		buffer += chunk;
	});
	socket.on("error", (error) =>
		fatal(`warm classifier unreachable: ${error.message}`),
	);
	socket.on("close", () => {
		let reply;
		try {
			reply = JSON.parse(buffer.trim());
		} catch {
			fatal("warm classifier reply was unparseable");
			return;
		}
		if (reply.error || !reply.text) {
			fatal(reply.error || "warm classifier returned no text");
			return;
		}
		process.stdout.write(
			reply.text.endsWith("\n") ? reply.text : `${reply.text}\n`,
		);
		process.exit(0);
	});
	return undefined;
}

function stop(args) {
	const state = args.state;
	if (!state) return fatal("stop requires --state");
	const paths = runnerPaths(state);
	let pid = 0;
	try {
		pid = Number.parseInt(readFileSync(paths.pid, "utf8").trim(), 10);
	} catch {
		pid = 0;
	}
	if (Number.isFinite(pid) && pid > 0) {
		try {
			process.kill(pid, "SIGTERM");
		} catch {
			// Already gone.
		}
	}
	rmSync(paths.socket, { force: true });
	rmSync(paths.pid, { force: true });
	process.exit(0);
}

function fatal(message) {
	process.stderr.write(`fm-captain-router-runner: ${message}\n`);
	process.exit(1);
}

const args = parseArgs(process.argv.slice(2));
if (args.error) fatal(args.error);
switch (args.command) {
	case "serve":
		serve(args);
		break;
	case "classify":
		classify(args);
		break;
	case "stop":
		stop(args);
		break;
	case "--help":
	case "-h":
		process.stdout.write(`${usage()}\n`);
		process.exit(0);
		break;
	default:
		fatal(`unknown command: ${args.command ?? "(none)"}`);
}
