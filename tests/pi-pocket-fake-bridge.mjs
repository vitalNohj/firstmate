#!/usr/bin/env node
// tests/pi-pocket-fake-bridge.mjs - a stand-in for the Firstmate Pi Pocket
// drop-in's worker bridge (pi-pocket/firstmate.ts), for the pi-pocket backend
// suites. It serves <state>/pocket-bridge/requests the way the drop-in does,
// answering from a world.json it re-reads on every request and logging each
// request it took, so no test needs a Pi Pocket server.
//
// usage: pi-pocket-fake-bridge.mjs --state DIR --world FILE --log FILE
//          --server PID --conversation ID [--parent-pid PID]
//
// The world (every key optional):
//   models    the owner's subagent model list (default ["faux/faux-1"])
//   held      a spend-hold reason; spawn and every submit refuse with it
//   stop      true when this Pi Pocket has linkedSessions.stop and archive
//   silent    true to take requests and never answer (the helper's timeout)
//   down      true to stop the heartbeat (the bridge is not running)
//   workers   { "<session>": { task, model, busy, failed, retired, archived,
//               gone, submissions: [{text, whenBusy, requestId}], transcript } }
//   next      the next session id spawn hands out (default 100)
// The fake writes workers back after each mutation, so a test reads them.
import { existsSync, mkdirSync, readFileSync, readdirSync, renameSync, rmSync, writeFileSync, appendFileSync } from "node:fs";
import { join } from "node:path";

const opts = {};
const argv = process.argv.slice(2);
for (let index = 0; index < argv.length; index += 2) opts[argv[index].slice(2)] = argv[index + 1];
const dir = join(opts.state, "pocket-bridge");
for (const sub of ["requests", "results"]) mkdirSync(join(dir, sub), { recursive: true, mode: 0o700 });

const readWorld = () => {
  try {
    return JSON.parse(readFileSync(opts.world, "utf8"));
  } catch {
    return {};
  }
};
const writeWorld = (world) => {
  const staged = `${opts.world}.${String(process.pid)}.tmp`;
  writeFileSync(staged, `${JSON.stringify(world, null, 2)}\n`);
  renameSync(staged, opts.world);
};
const refuse = (code, error) => ({ ok: false, code, error });

function gate(world, worker) {
  const models = world.models ?? ["faux/faux-1"];
  if (!models.includes(worker.model)) return refuse("model", `the worker's model ${worker.model} is not on the owner's subagent model list in Pi Pocket`);
  if (world.held) return refuse("held", `Pi Pocket holds this work back: ${world.held}`);
  return undefined;
}

function handle(world, request) {
  const workers = (world.workers ??= {});
  if (request.verb === "status") return { ok: true, pocketVersion: "0.28.0-fake", stop: world.stop === true };
  if (request.verb === "spawn") {
    const models = world.models ?? ["faux/faux-1"];
    if (world.held) return refuse("held", `Pi Pocket holds this session back: ${world.held}`);
    if (models.length === 0) return refuse("model", "the owner's subagent model list in Pi Pocket is empty");
    if (request.model && !models.includes(request.model)) return refuse("model", `the model ${request.model} is not on the owner's subagent model list in Pi Pocket (${models.join(", ")})`);
    const existing = Object.entries(workers).find(([, worker]) => worker.task === request.task && !worker.retired && !worker.archived);
    if (existing) return { ok: true, session: Number(existing[0]), address: `fake:${existing[0]}`, model: existing[1].model, reused: true };
    const session = Number(world.next ?? 100);
    world.next = session + 1;
    workers[String(session)] = {
      task: request.task,
      cwd: request.cwd,
      model: request.model || models[0],
      ...(request.thinking ? { thinking: request.thinking } : {}),
      env: request.env ?? {},
      excludeTools: request.excludeTools ?? [],
      prompt: request.prompt ?? "",
      busy: false,
      submissions: [],
      transcript: ["user: Firstmate is starting a task worker in this session."],
    };
    return { ok: true, session, address: `fake:${String(session)}`, model: workers[String(session)].model };
  }
  const worker = workers[String(request.session)];
  if (worker === undefined) {
    if (request.verb === "state") return { ok: true, state: "missing", busy: "unknown" };
    if (request.verb === "kill") return { ok: true, archived: false, absent: true };
    return refuse("missing", `no Pocket worker is recorded for session ${String(request.session)}`);
  }
  const torn = worker.retired === true || worker.archived === true;
  switch (request.verb) {
    case "configure":
      if (torn) return refuse("retired", `the worker for ${worker.task} was torn down`);
      worker.env = { ...worker.env, ...request.env };
      return { ok: true };
    case "send": {
      if (torn) return refuse("retired", `the worker for ${worker.task} was torn down; Firstmate sends nothing more to it`);
      const refused = gate(world, worker);
      if (refused) return refused;
      worker.submissions ??= [];
      const same = worker.submissions.find((item) => item.requestId === request.requestId);
      if (!same) {
        worker.submissions.push({ text: request.text, whenBusy: request.whenBusy, requestId: request.requestId });
        worker.transcript.push(`user: ${request.text}`);
      }
      return { ok: true, submission: `sub-${String(worker.submissions.length)}` };
    }
    case "interrupt": {
      if (torn) return refuse("retired", `the worker for ${worker.task} was torn down`);
      const was = worker.busy === true;
      worker.busy = false;
      worker.aborts = (worker.aborts ?? 0) + 1;
      return { ok: true, cancel: was ? "confirmed" : "not-running" };
    }
    case "capture":
      return { ok: true, text: worker.transcript.slice(-Math.max(1, Number(request.lines) || 40)).join("\n") };
    case "state":
      if (torn || worker.gone) return { ok: true, state: "missing", busy: "unknown" };
      if (worker.failed && !worker.busy) return { ok: true, state: "dead", busy: "unknown", failed: worker.failed };
      return { ok: true, state: "alive", busy: worker.busy ? "busy" : "idle" };
    case "kill":
      if (torn) return { ok: true, archived: worker.archived === true, retired: worker.retired === true };
      worker.busy = false;
      if (world.stop === true) {
        worker.archived = true;
        return { ok: true, archived: true };
      }
      worker.retired = true;
      worker.aborts = (worker.aborts ?? 0) + 1;
      return { ok: true, archived: false, retired: true };
  }
  return refuse("invalid", `unknown verb ${String(request.verb)}`);
}

function tick() {
  const world = readWorld();
  if (world.down !== true) {
    writeFileSync(join(dir, "heartbeat.json"), JSON.stringify({ server: opts.server, conversation: opts.conversation, at: Date.now(), stop: world.stop === true }));
  }
  for (const name of readdirSync(join(dir, "requests")).sort()) {
    if (!name.endsWith(".json")) continue;
    const path = join(dir, "requests", name);
    let request;
    try {
      request = JSON.parse(readFileSync(path, "utf8"));
    } catch {
      continue;
    }
    appendFileSync(opts.log, `${JSON.stringify(request)}\n`);
    rmSync(path, { force: true });
    if (world.silent === true) continue;
    const result = request.server === opts.server && request.conversation === opts.conversation ? handle(world, request) : refuse("untrusted", "the request does not come from the conversation that holds this home's lock");
    writeWorld(world);
    const staged = join(dir, "results", `.${name}.tmp`);
    writeFileSync(staged, JSON.stringify(result), { mode: 0o600 });
    renameSync(staged, join(dir, "results", name));
  }
  if (opts["parent-pid"] && !existsSync(`/proc/${opts["parent-pid"]}`)) process.exit(0);
}

setInterval(tick, 30);
