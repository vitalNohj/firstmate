#!/usr/bin/env node
// bin/fm-pi-pocket-bridge.mjs - Firstmate's client of the Pocket worker bridge
// that the Firstmate Pi Pocket drop-in (pi-pocket/firstmate.ts) serves for the
// conversation holding this home's session lock (docs/pi-pocket-backend.md).
//
// usage: fm-pi-pocket-bridge.mjs <verb> --state <state-dir> [options]
//
// Verbs and their options:
//   status                                    the bridge is up: {pocketVersion, stop}
//   spawn --task ID --cwd DIR [--model M] [--thinking E] [--title T]
//         [--prompt-file F] [--env-file F] [--exclude-tools a,b] [--attempt A]
//                                             start a worker session: {session, address, model}
//   send --session N (--text T | --text-file F) [--when-busy followUp|steer] [--request-id R]
//                                             submit into the worker, unfenced: {submission}
//   interrupt --session N                     abort its run: {cancel: confirmed|not-running}
//   capture --session N [--lines N]           print the last N transcript lines as text
//   state --session N                         {state: alive|missing|dead, busy: busy|idle|unknown}
//   kill --session N                          stop + archive, or abort + retire: {archived, retired}
//
// Each call writes one request into <state-dir>/pocket-bridge/requests and
// waits for its result. The drop-in answers only a request whose writer is a
// command of the Pi Pocket conversation that holds the home's lock on this
// server (FM_PI_POCKET_CONVERSATION and FM_PI_POCKET_SERVER_PID, the same
// marker bin/fm-session-lock-lib.sh's fm_pi_pocket_trusted_server_pid reads).
//
// Prints the result as one JSON object (capture prints its text). Exit codes:
//   0 ok; 2 usage; 3 refused by the drop-in (its reason on stderr, prefixed
//   with its code); 5 the bridge is not running or this is not a Pi Pocket
//   command; 7 no answer in time (a send may still have landed: retrying it
//   with the same --request-id is safe).
import { randomUUID } from "node:crypto";
import { lstatSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const HEARTBEAT_MAX_MS = Number(process.env.FM_POCKET_BRIDGE_HEARTBEAT_MAX_MS || 10000);
const POLL_MS = 50;

function die(code, message) {
  process.stderr.write(`${message}\n`);
  process.exit(code);
}

const [verb, ...rest] = process.argv.slice(2);
const VERBS = new Set(["status", "spawn", "send", "interrupt", "capture", "state", "kill"]);
if (!VERBS.has(verb)) die(2, `usage: fm-pi-pocket-bridge.mjs <${[...VERBS].join("|")}> --state <state-dir> [options]`);
const opts = {};
for (let index = 0; index < rest.length; index += 1) {
  const flag = rest[index];
  if (!flag.startsWith("--") || index + 1 >= rest.length) die(2, `error: bad argument ${flag}`);
  opts[flag.slice(2)] = rest[(index += 1)];
}
if (!opts.state) die(2, "error: --state is required");

const conversation = process.env.FM_PI_POCKET_CONVERSATION || "";
const server = process.env.FM_PI_POCKET_SERVER_PID || "";
if (!/^[A-Za-z0-9._:-]{1,128}$/.test(conversation) || !/^[0-9]+$/.test(server)) {
  die(5, "error: backend=pi-pocket needs a command of the Firstmate Pi Pocket session; this command carries no Pi Pocket identity");
}

const dir = join(opts.state, "pocket-bridge");
let heartbeat;
try {
  heartbeat = JSON.parse(readFileSync(join(dir, "heartbeat.json"), "utf8"));
} catch {
  heartbeat = undefined;
}
if (heartbeat?.server !== server || heartbeat?.conversation !== conversation || !(Date.now() - Number(heartbeat?.at) < HEARTBEAT_MAX_MS)) {
  die(5, "error: the Firstmate Pi Pocket drop-in's worker bridge is not running for this session (update the drop-in with bin/fm-pi-pocket-install.sh and reload Pi Pocket, or run bin/fm-session-start.sh in the main Firstmate session)");
}

const read = (path) => readFileSync(path, "utf8");
const request = { v: 1, id: `${Date.now()}-${process.pid}-${randomUUID().slice(0, 8)}`, verb, server, conversation, pid: process.pid };
const session = () => {
  const value = Number(opts.session);
  if (!Number.isSafeInteger(value) || value <= 0) die(2, "error: --session must be a positive session id");
  return value;
};
switch (verb) {
  case "spawn":
    if (!opts.task || !opts.cwd) die(2, "error: spawn needs --task and --cwd");
    Object.assign(request, {
      task: opts.task,
      cwd: opts.cwd,
      ...(opts.model ? { model: opts.model } : {}),
      ...(opts.thinking ? { thinking: opts.thinking } : {}),
      ...(opts.title ? { title: opts.title } : {}),
      ...(opts.attempt ? { attempt: opts.attempt } : {}),
      prompt: opts["prompt-file"] ? read(opts["prompt-file"]) : "",
      env: opts["env-file"] ? JSON.parse(read(opts["env-file"])) : {},
      excludeTools: (opts["exclude-tools"] || "").split(",").filter(Boolean),
    });
    break;
  case "send": {
    const text = opts["text-file"] ? read(opts["text-file"]) : opts.text;
    if (typeof text !== "string" || text === "") die(2, "error: send needs --text or --text-file");
    Object.assign(request, { session: session(), text, whenBusy: opts["when-busy"] === "steer" ? "steer" : "followUp", requestId: opts["request-id"] || request.id });
    break;
  }
  case "capture":
    Object.assign(request, { session: session(), lines: Number(opts.lines || 40) });
    break;
  case "interrupt":
  case "state":
  case "kill":
    request.session = session();
    break;
}

const requests = join(dir, "requests");
const results = join(dir, "results");
for (const path of [requests, results]) {
  mkdirSync(path, { recursive: true, mode: 0o700 });
  const info = lstatSync(path);
  if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== process.getuid() || (info.mode & 0o077) !== 0) {
    die(5, `error: ${path} is not a private directory of this user`);
  }
}
const name = `${request.id}.json`;
const staged = join(requests, `.${name}.tmp`);
writeFileSync(staged, JSON.stringify(request), { mode: 0o600 });
renameSync(staged, join(requests, name));

const timeoutMs = Number(opts["timeout-ms"] || (verb === "spawn" || verb === "kill" ? 60000 : 30000));
const deadline = Date.now() + timeoutMs;
const sleeper = new Int32Array(new SharedArrayBuffer(4));
let result;
for (;;) {
  try {
    result = JSON.parse(read(join(results, name)));
    rmSync(join(results, name), { force: true });
    break;
  } catch {
    // Not answered yet.
  }
  if (Date.now() >= deadline) {
    // Withdraw an unread request; one the drop-in already took may still act.
    rmSync(join(requests, name), { force: true });
    die(7, `error: the Pocket worker bridge did not answer ${verb} within ${String(timeoutMs)} ms`);
  }
  Atomics.wait(sleeper, 0, 0, POLL_MS);
}
if (result?.ok !== true) die(3, `error: ${String(result?.code ?? "error")}: ${String(result?.error ?? "the Pocket worker bridge refused the request")}`);
if (verb === "capture") process.stdout.write(`${String(result.text ?? "")}\n`);
else process.stdout.write(`${JSON.stringify(result)}\n`);
