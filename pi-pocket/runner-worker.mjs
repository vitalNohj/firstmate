#!/usr/bin/env node
// Invoked by runner-owner.sh in the verified runner home, never by the server's shell.
// A foreground lifecycle script holds one command slot. Only bridge clients descended
// from that slot's live local holder can make requests for its one task.
import { execFileSync, spawnSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { constants, existsSync, lstatSync, mkdirSync, openSync, closeSync, readFileSync, readdirSync, realpathSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';

const [op, main, ...args] = process.argv.slice(2);
const home = process.env.FM_HOME;
const generation = process.env.FM_POCKET_RUNNER_COMMAND;
const state = join(home, 'state');
const lock = join(state, '.lock');
const slot = join(lock, 'runner-worker-command');
const bridge = join(state, 'pocket-bridge');
const intents = join(lock, 'runner-workers');
const records = join(bridge, 'workers');
const MAX_RECORD = 50_000;
const validTask = (task) => typeof task === 'string' && /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(task);
const validId = (id) => typeof id === 'string' && /^[A-Za-z0-9._-]{1,128}$/.test(id);
const refuse = (why) => { throw new Error(why); };

function info(path) {
  try { return lstatSync(path); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
}
function directory(path, make = false) {
  if (make && info(path) === undefined) mkdirSync(path, { mode: 0o700 });
  const dir = info(path);
  if (dir === undefined) return false;
  if (!dir.isDirectory() || dir.uid !== process.getuid() || (dir.mode & 0o077) !== 0) refuse('unsafe runner bridge directory');
  return true;
}
function read(path) {
  const entry = info(path);
  if (entry === undefined) return undefined;
  if (!entry.isFile() || entry.uid !== process.getuid() || entry.size > MAX_RECORD) refuse('unsafe runner worker record');
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try { return readFileSync(fd, 'utf8'); } finally { closeSync(fd); }
}
const json = (path) => JSON.parse(read(path) ?? 'null');
function write(path, value) {
  const text = JSON.stringify(value);
  if (Buffer.byteLength(text) > MAX_RECORD) refuse('runner worker record is too large');
  const temporary = `${path}.${randomUUID()}.tmp`;
  writeFileSync(temporary, text, { flag: 'wx', mode: 0o600 });
  try { renameSync(temporary, path); } finally { if (existsSync(temporary)) rmSync(temporary); }
}
const print = (value) => process.stdout.write(`${JSON.stringify(value)}\n`);
const recordPath = (task) => join(records, `${task}.json`);
const intentPath = (task) => join(intents, `${task}.json`);

function mine(task) {
  if (!validTask(task) || !directory(bridge) || !directory(records)) return null;
  const record = json(recordPath(task));
  return record?.runnerGeneration === generation && record.task === task && record.main === Number(main) && record.home === home ? record : null;
}
function configured() {
  const pin = join(home, 'config', 'backend');
  return info(pin)?.isFile() === true && readFileSync(pin, 'utf8').trim() === 'pi-pocket';
}
function taskMeta(task) {
  const path = join(state, `${task}.meta`);
  const lines = (read(path) ?? '').split('\n');
  const field = (name) => {
    const values = lines.filter((line) => line.startsWith(`${name}=`));
    return values.length === 1 ? values[0].slice(name.length + 1) : undefined;
  };
  return { backend: field('backend'), project: field('project'), worktree: field('worktree'), session: field('pocket_session') };
}
function inspectLease(project, supplied, task, mainCheckout = true) {
  const cwd = realpathSync(supplied);
  if (cwd !== supplied || !lstatSync(cwd).isDirectory() || (mainCheckout && cwd === project)) refuse('worker folder is not a canonical, isolated worktree');
  const pool = JSON.parse(execFileSync('treehouse', ['status', '--json'], { cwd: project, encoding: 'utf8', timeout: 2500, maxBuffer: 262_144 }));
  const match = pool.filter((row) => row.path === cwd && row.status === 'leased' && row.lease_holder === task && validId(row.lease_id));
  if (match.length !== 1) refuse('the runner cannot verify the exact Treehouse lease');
  return { cwd, lease: match[0].lease_id };
}
function writer(pid) {
  const root = Number(process.env.FM_POCKET_RUNNER_WRITER_ROOT);
  if (!Number.isSafeInteger(pid) || pid <= 1 || !Number.isSafeInteger(root) || root <= 1) return false;
  for (let hop = 0; hop < 24; hop += 1) {
    try { pid = Number(execFileSync('ps', ['-o', 'ppid=', '-p', String(pid)], { encoding: 'utf8', timeout: 400 }).trim()); }
    catch { return false; }
    if (pid === root) return true;
    if (!Number.isSafeInteger(pid) || pid <= 1) return false;
  }
  return false;
}
const allowed = {
  spawn: new Set(['status', 'preflight', 'spawn', 'configure', 'send', 'state', 'kill']),
  send: new Set(['status', 'state', 'capture', 'send']),
  interrupt: new Set(['status', 'state', 'interrupt']),
  exit: new Set(['status', 'state', 'kill']),
  relaunch: new Set(['status', 'preflight', 'state', 'capture', 'kill', 'spawn', 'configure', 'send', 'interrupt']),
  teardown: new Set(['status', 'state', 'kill']),
};

function lifecycleArgs() {
  const [token, raw, grant] = args;
  const { operation, task, args: flags } = JSON.parse(raw);
  if (!validId(token) || !validTask(task) || !Array.isArray(flags) || flags.length > 48 || flags.some((flag) => typeof flag !== 'string' || flag.includes('\0'))) refuse('invalid runner worker arguments');
  if (grant !== undefined && !(operation === 'send' || operation === 'teardown' || (operation === 'control' && ['interrupt', 'exit'].includes(flags[0])))) {
    refuse('runner branch cannot start or relaunch workers');
  }
  return { token, grant, operation, task, flags };
}

function authorize() {
  const { task, grant } = lifecycleArgs();
  const helper = join(home, 'pi-pocket', 'runner-supervision.sh');
  if (grant === undefined || info(helper)?.isFile() !== true) refuse('runner branch helper is unavailable');
  const checked = spawnSync('bash', [helper, 'branch-worker-allowed', grant, task], { cwd: home, timeout: 3000 });
  if (checked.status !== 0) refuse('the local branch grant does not cover this task');
}

function run() {
  const { token, grant, operation, task, flags } = lifecycleArgs();
  let command;
  let argv;
  let action = operation;
  let project;
  const meta = taskMeta(task);
  if (operation === 'spawn') {
    if (!configured() || meta.backend !== undefined) refuse('runner spawn needs config/backend set to pi-pocket and a new task');
    if (!flags[0]?.startsWith('/') || flags.slice(1).some((flag) => /^--(?:backend|harness|secondmate|relaunch|raw)(?:$|=)/.test(flag))) refuse('runner spawn needs a project folder and cannot select another backend or harness');
    project = realpathSync(flags[0]);
    command = 'fm-spawn.sh';
    argv = [task, project, ...flags.slice(1), '--backend', 'pi-pocket', '--harness', 'pi'];
  } else {
    const current = mine(task);
    if (meta.backend !== 'pi-pocket' || current?.session !== Number(meta.session) || current?.cwd !== meta.worktree) refuse('this generation does not own a recorded Pocket worker for this task');
    project = meta.project;
    if (operation === 'send') {
      // Existing fm-send owns durable inbox writing; text is one argument, not a shell fragment.
      if (flags.length !== 1 || !flags[0] || flags[0].startsWith('-')) refuse('runner send needs one non-option message');
      command = 'fm-send.sh'; argv = [task, flags[0]];
    } else if (operation === 'control' && ['interrupt', 'exit', 'relaunch'].includes(flags[0])) {
      action = flags[0];
      if (action === 'relaunch') {
        if (!configured() || flags.slice(1).some((flag) => /^--(?:backend|harness|secondmate)(?:$|=)/.test(flag))) refuse('runner relaunch must stay on pi-pocket with the pi harness');
        argv = [task, ...flags, '--harness', 'pi'];
      } else {
        if (flags.length !== 1) refuse('unexpected runner control options');
        argv = [task, ...flags];
      }
      command = 'fm-control.sh';
    } else if (operation === 'teardown' && flags.length === 0) {
      command = 'fm-teardown.sh'; argv = [task];
    } else refuse('unknown runner lifecycle operation or unsupported options');
  }
  write(join(slot, 'scope'), { token, generation, task, project, action });
  const result = spawnSync('bash', [join(home, 'bin', command), ...argv], {
    cwd: home, stdio: 'inherit', env: { ...process.env, FM_SUPERVISION_ACTOR: grant === undefined ? 'main' : 'branch', FM_PI_POCKET_RUNNER_BRIDGE: token, FM_PI_POCKET_CONVERSATION: main },
  });
  process.exitCode = result.status ?? 1;
}

function commandScope(token) {
  if (!validId(token) || !directory(slot)) return undefined;
  const scope = json(join(slot, 'scope'));
  return scope?.generation === generation && scope.token === token ? scope : undefined;
}

function next() {
  const scope = commandScope(args[0]);
  if (scope === undefined || !directory(bridge) || !directory(join(bridge, 'requests'))) return;
  for (const name of readdirSync(join(bridge, 'requests')).sort().slice(0, 32)) {
    if (!name.endsWith('.json') || !validId(name.slice(0, -5))) continue;
    const path = join(bridge, 'requests', name);
    if ((info(path)?.size ?? 0) > MAX_RECORD) continue;
    const request = json(path);
    if (request?.runner !== scope.token || request.conversation !== main || request.id !== name.slice(0, -5) || request.v !== 1 || !writer(request.pid)) continue;
    // Do not let a client choose a verb, task, project or session beyond the foreground script's scope.
    const current = mine(scope.task);
    let error;
    let lease;
    if (!allowed[scope.action]?.has(request.verb) || (request.task !== undefined && request.task !== scope.task) ||
        (request.session !== undefined && request.session !== current?.session)) error = 'the request is outside the runner command scope';
    if (request.verb === 'spawn' && error === undefined) {
      try {
        if (!configured() || request.task !== scope.task) refuse('runner launch is not enabled for this task');
        ({ cwd: request.cwd, lease } = inspectLease(scope.project, request.cwd, scope.task));
      } catch (failure) { error = failure.message; }
    }
    print({ request, task: scope.task, lease, error, current });
    return;
  }
}

function save(record) {
  const { task, cwd, session, address } = record;
  if (!validTask(task) || typeof cwd !== 'string' || typeof address !== 'string' || !Number.isSafeInteger(session) || session < 1 || record.runnerGeneration !== generation || record.main !== Number(main) || record.home !== home) refuse('invalid runner worker binding');
  if (!directory(intents) || json(intentPath(task))?.key !== record.key) refuse('there is no matching runner start intent');
  directory(bridge, true);
  directory(records, true);
  write(recordPath(task), record);
}

try {
  switch (op) {
    case 'worker-authorize': authorize(); break;
    case 'worker-run': run(); break;
    case 'worker-next': next(); break;
    case 'worker-answer': {
      const [token, id, result] = args;
      if (!commandScope(token) || !validId(id) || !directory(bridge) || !directory(join(bridge, 'results')) || !directory(join(bridge, 'requests'))) refuse('invalid runner bridge reply');
      const path = join(bridge, 'requests', `${id}.json`);
      const pending = json(path);
      if (pending?.id !== id || pending.runner !== token) refuse('the request is no longer in this runner command');
      write(join(bridge, 'results', `${id}.json`), JSON.parse(result));
      rmSync(path, { force: true });
      break;
    }
    case 'worker-intent': {
      const { task, lease, key } = JSON.parse(args[0]);
      if (!validTask(task) || !validId(lease) || !validId(key)) refuse('invalid runner start intent');
      directory(intents, true);
      const old = json(intentPath(task));
      const current = mine(task);
      if (old !== null && !(current?.archived === true && current.key === old.key)) {
        if (old.lease !== lease || old.key !== key) refuse('a previous runner start is still unconfirmed; keep its lease');
      } else write(intentPath(task), { task, lease, key });
      break;
    }
    case 'worker-save': save(JSON.parse(args[0])); break;
    case 'worker-record': print(mine(args[0])); break;
    case 'worker-busy': {
      const [task, rawSession, busy] = args;
      const current = mine(task);
      if (current?.session !== Number(rawSession) || current.archived === true || !['busy', 'idle'].includes(busy)) break;
      const argv = ['apply', state, task, busy, '--current-gen', '--source', 'pi-pocket', '--event', 'runner-reconcile'];
      if (busy === 'idle') argv.push('--turn-ended');
      const changed = spawnSync('bash', [join(home, 'bin', 'fm-busy-event.sh'), ...argv], { cwd: home, encoding: 'utf8', timeout: 3500 });
      if (changed.status === 0) save({ ...current, busy: busy === 'busy' });
      break;
    }
    case 'worker-handoff': {
      if (!directory(intents) || !directory(bridge) || !directory(records)) refuse('worker start has no cleanup receipt');
      for (const name of readdirSync(intents)) {
        if (!name.endsWith('.json') || !validTask(name.slice(0, -5))) refuse('unknown runner start record');
        const intent = json(join(intents, name));
        const record = json(join(records, name));
        if (record?.key !== intent?.key || record?.archived !== true || record?.runnerGeneration !== args[0]) refuse('worker cleanup has not been confirmed');
      }
      break;
    }
    default: refuse('unknown runner worker operation');
  }
} catch (error) {
  process.stderr.write(`Runner worker: ${error.message}\n`);
  process.exitCode = 1;
}
