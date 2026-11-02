// The Firstmate Pi Pocket drop-in (pi-pocket/firstmate.ts) inside a real Pi Pocket app, driven by
// tests/fm-pi-pocket-dropin.test.sh. That wrapper copies this file and the drop-in into a directory whose
// node_modules links to the Pi Pocket checkout's, and passes:
//   FM_PI_POCKET_CHECKOUT  the Pi Pocket checkout whose test/helpers.ts opens apps on temporary data directories
//   FM_PI_POCKET_BIN       a copy of Firstmate's bin/ that every fixture home starts from
//   FM_PI_POCKET_DROPIN    the drop-in file under test
// Run with `--child <dataDir> <home>`, the file is instead the server that experiment (b) kills mid-delivery.
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { createServer, type Server } from "node:http";
import {
    chmodSync,
    copyFileSync,
    cpSync,
    existsSync,
    mkdirSync,
    mkdtempSync,
    readFileSync,
    renameSync,
    statSync,
    writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { after, mock, test } from "node:test";
import { fauxAssistantMessage, fauxText, fauxToolCall } from "@earendil-works/pi-ai/providers/faux";

const checkout = process.env.FM_PI_POCKET_CHECKOUT!;
const bin = process.env.FM_PI_POCKET_BIN!;
const dropIn = process.env.FM_PI_POCKET_DROPIN!;
/** This checkout can present an extension's own inputs. The running app the captain uses cannot, yet. */
const presents = existsSync(join(checkout, "src/server/entry-presentation.ts"));
const helpers = await import(join(checkout, "test", "helpers.ts"));
const { context, fakeTab, lastText, newSession, openApp, owner, recordCost, root, say, scriptedModel, until, work } = helpers;

type App = Awaited<ReturnType<typeof openApp>>;

const WAKE = "FIRSTMATE WATCHER WAKE: ";
const BRANCH_WAKE = "FIRSTMATE SUPERVISION WAKE: ";
const PROCESSING = "supervision processing request";
const LONG = 30_000;

// ---------------------------------------------------------------------------------------------------------------
// Fixtures

const STUBS: Record<string, string> = {
    // Session start takes the real lock as the marked conversation; its digest is a stub.
    "fm-session-start.sh": `#!/usr/bin/env bash
"$(dirname "$0")/fm-lock.sh" >/dev/null 2>&1 || { echo "STUB SESSION START: lock refused"; exit 0; }
echo "STUB SESSION START conversation=$FM_PI_POCKET_CONVERSATION"
`,
    "fm-sessionstart-run.sh": `#!/usr/bin/env bash
echo "$2" >> "$FM_HOME/stub/starts.log"
"$(dirname "$0")/fm-lock.sh" >/dev/null 2>&1 || { echo "STUB DIGEST $2: lock refused"; exit 0; }
echo "STUB DIGEST $2 conversation=$FM_PI_POCKET_CONVERSATION"
[ ! -e "$FM_HOME/stub/digest-tail" ] || cat "$FM_HOME/stub/digest-tail"
`,
    // One arm: report a started watcher, then end with the first wake reason a test drops into stub/fire.*.
    // It leaves when its server dies, as a real arm's watcher would be orphaned and reaped.
    "fm-watch-arm.sh": `#!/usr/bin/env bash
stub="$FM_HOME/stub"
if [ "\${1:-}" = --handling-delivered ]; then echo "$2 $4" >> "$stub/handled.log"; exit 0; fi
server=$PPID
printf '%s %s\\n' "$$" "\${FM_WATCH_PREDECESSOR_ARM_PID:-none}" >> "$stub/arms.log"
trap 'exit 143' TERM
echo "watcher: started pid=$$ (beacon fresh)"
if [ -e "$stub/fail-always" ]; then echo "watcher: FAILED - stub arm broke after reporting ready"; exit 0; fi
while kill -0 "$server" 2>/dev/null; do
  for fire in "$stub"/fire.*; do
    [ -e "$fire" ] || continue
    if mv "$fire" "$stub/taken.$$" 2>/dev/null; then cat "$stub/taken.$$"; exit 0; fi
  done
  sleep 0.1
done
exit 1
`,
    "fm-turnend-guard.sh": `#!/usr/bin/env bash
cat >/dev/null
echo x >> "$FM_HOME/stub/guards.log"
if [ "$(cat "$FM_HOME/stub/guard-code" 2>/dev/null)" = 2 ]; then echo "STUB GUARD: call the repair tool" >&2; exit 2; fi
exit 0
`,
};

let homes = 0;

/**
 * A Firstmate primary home: a plain Git repository (not a linked worktree, so Firstmate's scripts see a primary
 * checkout) with AGENTS.md, a copy of bin/ with stubs, and state/.
 */
async function home(): Promise<string> {
    homes += 1;
    const home = join(root, `fm-home-${homes}`);
    await new Promise<void>((resolve, reject) => {
        const git = spawn("git", ["init", "-q", home], { stdio: "ignore" });
        git.on("close", (code) => (code === 0 ? resolve() : reject(new Error(`git init exited ${String(code)}`))));
    });
    cpSync(bin, join(home, "bin"), { recursive: true });
    // The branch's prompt and wake dispatch read these tracked files beside bin/, as in a real home.
    cpSync(join(bin, "..", ".agents", "skills"), join(home, ".agents", "skills"), { recursive: true });
    cpSync(join(bin, "..", ".pi", "extensions", "lib"), join(home, ".pi", "extensions", "lib"), { recursive: true });
    for (const [name, body] of Object.entries(STUBS)) {
        writeFileSync(join(home, "bin", name), body);
        chmodSync(join(home, "bin", name), 0o755);
    }
    writeFileSync(join(home, "AGENTS.md"), "# Firstmate fixture\n");
    mkdirSync(join(home, "state"));
    mkdirSync(join(home, "stub"));

    return home;
}

function lines(path: string): string[] {
    return existsSync(path) ? readFileSync(path, "utf8").split("\n").filter((line) => line !== "") : [];
}

let fires = 0;

/** Hand the live stub arm a wake reason, whole: it only sees renamed files. */
function fire(home: string, reason: string): void {
    fires += 1;
    const staged = join(home, "stub", `.staged-${fires}`);
    writeFileSync(staged, `${reason}\n`);
    renameSync(staged, join(home, "stub", `fire.${fires}`));
}

/** The text of every user-role message the model sees in the session. */
async function userTexts(app: App, id: unknown): Promise<string[]> {
    const view = await (await app.harness.conversation(id, context))!.context(context);

    return view.messages
        .filter((message: { role: string }) => message.role === "user")
        .map((message: { role: string; content: unknown }) => lastText({ messages: [message] }).text);
}

const count = (texts: string[], needle: string) => texts.filter((text) => text.includes(needle)).length;

type StoredEntry = { kind: string; summary?: string; text: string };

function entryText(model: { role: string; content: unknown }[] | undefined): string {
    const message = model?.find((item) => item.role === "user");

    return message === undefined ? "" : lastText({ messages: [message] }).text;
}

function entrySummary(data: unknown): string | undefined {
    if (typeof data !== "object" || data === null || !("summary" in data)) return undefined;
    const summary = (data as { summary?: unknown }).summary;

    return typeof summary === "string" ? summary : undefined;
}

/** Stored transcript entries, not only the text the model sees. */
async function storedEntries(app: App, id: unknown): Promise<StoredEntry[]> {
    const page = await app.harness.commit(
        async (tx: {
            scanEntries: (query: object, limit: number) => Promise<{ items: { kind: string; data?: unknown; model?: { role: string; content: unknown }[] }[] }>;
        }) => tx.scanEntries({ conversationId: id }, 200),
        context,
    );

    return page.items.map((entry) => ({ kind: entry.kind, summary: entrySummary(entry.data), text: entryText(entry.model) }));
}

const entryFor = (entries: StoredEntry[], needle: string) => entries.find((entry) => entry.text.includes(needle));

/** A main-conversation submit is a presented operational entry only when this Pi Pocket can show one. */
function assertOperational(entry: StoredEntry | undefined, summary: string, what: string): void {
    assert.ok(entry !== undefined, what);
    if (presents) {
        assert.equal(entry.kind, "x.firstmate.operational", what);
        assert.equal(entry.summary, summary, what);
    } else {
        assert.equal(entry.kind, "pi.user", `${what} stays an ordinary message without the presentation API`);
    }
}

/** A queued wake row for a task the branch may take: its metadata names a project, as a dispatched task's does. */
function queueTaskWake(home: string, task: string): string {
    const state = join(home, "state");
    const seq = Number(existsSync(join(state, ".wake-queue.seq")) ? readFileSync(join(state, ".wake-queue.seq"), "utf8") : "0") + 1;
    writeFileSync(join(state, `${task}.meta`), `project=fixture\nwindow=${task}-window\n`);
    writeFileSync(join(state, `${task}.status`), "working: started\ndone: finished\n");
    writeFileSync(join(state, ".wake-queue"), `${String(Math.floor(Date.now() / 1000))}\t${String(seq)}\tsignal\t${task}.status\tdone: finished\n`, { flag: "a" });
    writeFileSync(join(state, ".wake-queue.seq"), `${String(seq)}\n`);

    return `signal: ${task}.status`;
}

type BranchRecord = { main: number; branch: number; start: number; starting?: boolean };

function branchRecord(home: string): BranchRecord | undefined {
    const path = join(home, "state", ".pocket-branch");

    return existsSync(path) ? (JSON.parse(readFileSync(path, "utf8")) as BranchRecord) : undefined;
}

/** The supervision sessions Pi Pocket lists, each linked under the session that started it. */
function supervisionSessions(app: App): { id: number; title?: string; cwd?: string; linkedFrom?: { id: number } }[] {
    return app.sessions().filter((session: { title?: string }) => session.title === "Firstmate supervision");
}

async function branchStarted(app: App, fmHome: string): Promise<number> {
    await until(() => {
        const record = branchRecord(fmHome);
        return record !== undefined && record.starting !== true && record.branch > 0;
    }, "the supervision session", LONG);
    const branch = branchRecord(fmHome)!.branch;
    await (await app.harness.conversation(branch, context))!.waitForIdle(context);

    return branch;
}

function outcomeRows(home: string): { seq: number; task: string; verdict: string; summary: string }[] {
    return lines(join(home, "state", "branch-outcomes.jsonl")).map((line) => JSON.parse(line));
}

/** Tool result texts the model saw, as echoed back by the route. */
async function toolSaid(app: App, id: unknown): Promise<string[]> {
    const view = await (await app.harness.conversation(id, context))!.context(context);

    return view.messages
        .filter((message: { role: string }) => message.role === "toolResult")
        .map((message: { role: string; content: unknown }) => lastText({ messages: [message] }).text);
}

// The model: user words name a tool call; tool results and everything else get a short answer.
const call = (name: string, args: Record<string, unknown>) =>
    fauxAssistantMessage([fauxToolCall(name, args)], { stopReason: "toolUse" });

/** Every system prompt the model was sent, its sections joined: Pi Durable sends them as system messages. */
const systemPrompts: string[] = [];

const route = (request: unknown) => {
    const sections = (request as { messages: { role: string; sections?: Record<string, string> }[] }).messages
        .filter((message) => message.role === "system")
        .flatMap((message) => Object.values(message.sections ?? {}));
    systemPrompts.push(sections.join("\n"));
    // A fresh conversation's digest follows the captain's opening input; the route answers that input.
    const all = (request as { messages: { role: string; content: unknown }[] }).messages;
    const tail = all.findLastIndex((message) => !(message.role === "user" && lastText({ messages: [message] }).text.startsWith("\u2063FIRSTMATE_OP: v1 session-start: ")));
    const { role, text } = lastText({ messages: all.slice(0, tail + 1) });
    // A branch turn that reports and then hangs past its deadline.
    const whole = (request as { messages: { role: string; content: unknown }[] }).messages;
    if (role === "toolResult" && text.startsWith("recorded seq") && whole.some((message) => JSON.stringify(message.content).includes("task-report-stall"))) {
        return call("bash", { command: "sleep 60" });
    }
    if (role === "toolResult") return fauxAssistantMessage([fauxText("noted the tool result")]);
    if (text.endsWith("start firstmate")) return call("bash", { command: "bin/fm-session-start.sh" });
    if (text.endsWith("go elsewhere")) return call("bash", { command: "cd /tmp && ls" });
    if (text.endsWith("background the watcher")) return call("bash", { command: "bin/fm-watch-arm.sh --restart &" });
    // subagent is offered from the start; Pi Pocket offers schedule and watch_pr only after a tool search.
    if (text.endsWith("ask a subagent")) return call("subagent", { action: "status" });
    if (text.endsWith("read from a script")) {
        return call("codemode", { code: `try { return "read: " + (await tools.bash({ command: "echo script-ran" })); } catch (error) { return "failed: " + error.message; }` });
    }
    if (text.endsWith("schedule from a script")) {
        return call("codemode", { code: `try { return "ran: " + (await tools.schedule({ action: "list" })); } catch (error) { return "failed: " + error.message; }` });
    }
    if (text.endsWith("show the marker")) {
        return call("bash", { command: `printf 'marker=%s server=%s' "\${FM_PI_POCKET_CONVERSATION:-none}" "\${FM_PI_POCKET_SERVER_PID:-none}"` });
    }
    if (text.endsWith("repair the watcher")) return call("fm_watch_arm_pocket", {});
    if (text.endsWith("compress the context")) return call("compress", { content: "fold the consumed range" });
    if (text.endsWith("start a subagent")) return call("subagent", { action: "spawn", name: "helper", message: "look around" });
    if (text.endsWith("run a script")) return call("codemode", { code: `return await tools.read({ path: "AGENTS.md" });` });
    if (text.endsWith("show the actor")) {
        return call("bash", {
            command: `printf 'marker=%s actor=%s holder=%s primary=%s ' "$FM_PI_POCKET_CONVERSATION" "$FM_SUPERVISION_ACTOR" "$FM_LEASE_HOLDER_PID" "$FM_SUPERVISION_PRIMARY_HARNESS"; (FM_SUPERVISION_ACTOR=main) 2>/dev/null && echo reassign=allowed || echo reassign=refused`,
        });
    }
    if (text.endsWith("what happened in the fleet")) return call("fm_branch_outcomes", {});
    // A Pocket worker: its task environment, and a run long enough for a restart to cut.
    if (text.endsWith("show the task env")) {
        return call("bash", { command: `printf 'task=%s inbox=%s marker=%s token=%s' "$FM_TASK_ID" "$FM_TASK_INBOX" "\${FM_PI_POCKET_CONVERSATION:-none}" "\${FM_PI_POCKET_BRIDGE_TOKEN:-none}"` });
    }
    if (text.endsWith("work for a long time")) return call("bash", { command: "sleep 20" });
    if (text.endsWith("show the bridge token")) return call("bash", { command: `printf 'token=%s' "\${FM_PI_POCKET_BRIDGE_TOKEN:-none}"` });
    if (text.endsWith("report from main")) return call("fm_branch_report", { task: "task-a", verdict: "routine", summary: "main reporting" });
    // The supervision session: a wake for a task it reports on, and one it leaves without an outcome.
    const reported = /FIRSTMATE SUPERVISION WAKE: signal: (task-report[a-z0-9-]*)\.status/.exec(text);
    if (reported) {
        return call("fm_branch_report", { task: reported[1]!, verdict: "captain", summary: `${reported[1]!} needs the captain's merge call`, wake: `signal: ${reported[1]!}.status` });
    }
    if (text.includes("FIRSTMATE SUPERVISION WAKE: signal: task-off-scope.status")) {
        return call("fm_branch_report", { task: "some-other-task", verdict: "routine", summary: "off scope" });
    }
    if (text.includes("supervision processing request")) {
        const through = /through=([0-9]+)/.exec(text);
        if (through) return call("fm_branch_processed", { through: Number(through[1]) });
    }

    return fauxAssistantMessage([fauxText("noted")]);
};

async function open(dataDir: string, enable: boolean): Promise<App> {
    mkdirSync(join(dataDir, "extensions"), { recursive: true });
    copyFileSync(dropIn, join(dataDir, "extensions", "firstmate.ts"));
    copyFileSync(join(dirname(dropIn), "firstmate.js"), join(dataDir, "extensions", "firstmate.js"));
    const app = await openApp(scriptedModel(route), dataDir);
    if (enable) await app.setExtensionEnabled(owner(app), "firstmate.ts", true);

    return app;
}

/** The session's newest watcher task record, live or ended. */
async function watchTask(app: App, id: unknown) {
    return app.harness.commit(async (tx: { scanTasks: (query: object, limit: number) => Promise<{ items: any[] }> }) => {
        const page = await tx.scanTasks({ conversationId: id, kind: "x.firstmate.watch", order: "descending" }, 1);

        return page.items[0];
    }, context);
}

const clientKey = (key: string) => key.replace(/[^A-Za-z0-9_-]/g, "").slice(0, 64);

// ---------------------------------------------------------------------------------------------------------------
// Pocket workers: Firstmate's side of the worker bridge is bin/fm-pi-pocket-bridge.mjs, run as a command of main

type Called = { code: number; out: string; err: string };

/** The bridge secret main's marked bash commands carry, read once from one of them (see "show the bridge token"). */
let bridgeToken = "";

async function readBridgeToken(app: App, main: unknown): Promise<void> {
    await say(app, main as never, "show the bridge token");
    const said = (await toolSaid(app, main)).findLast((text) => text.includes("token="))!;
    bridgeToken = /token=(\S+)/.exec(said)![1]!;
}

/** One bridge call, as a command of main's session: a child of this server carrying main's Pi Pocket identity. */
function bridgeCall(fmHome: string, main: unknown, args: string[], token = bridgeToken): Promise<Called> {
    return new Promise((resolve) => {
        const child = spawn(process.execPath, [join(fmHome, "bin", "fm-pi-pocket-bridge.mjs"), ...args, "--state", join(fmHome, "state")], {
            env: { ...process.env, FM_PI_POCKET_CONVERSATION: String(main), FM_PI_POCKET_SERVER_PID: String(process.pid), FM_PI_POCKET_BRIDGE_TOKEN: token },
            stdio: ["ignore", "pipe", "pipe"],
        });
        let out = "";
        let err = "";
        child.stdout!.on("data", (chunk: Buffer) => (out += chunk.toString()));
        child.stderr!.on("data", (chunk: Buffer) => (err += chunk.toString()));
        child.on("close", (code) => resolve({ code: code ?? -1, out, err }));
    });
}

async function bridgeUp(fmHome: string, main: unknown): Promise<void> {
    await until(() => {
        const beat = readJsonFile(join(fmHome, "state", "pocket-bridge", "heartbeat.json"));
        return beat?.server === String(process.pid) && beat?.conversation === String(main);
    }, "the worker bridge", LONG);
}

function readJsonFile(path: string): any {
    try {
        return JSON.parse(readFileSync(path, "utf8"));
    } catch {
        return undefined;
    }
}

const workerRecord = (fmHome: string, task: string) => readJsonFile(join(fmHome, "state", "pocket-bridge", "workers", `${task}.json`));

/** Arm the task's busy contract, as fm-spawn does before a Pocket worker starts. */
function armBusy(fmHome: string, task: string): void {
    execFileSync(join(fmHome, "bin", "fm-busy-event.sh"), ["arm", join(fmHome, "state"), task, "--state", "idle", "--source", "fm-spawn", "--event", "pocket-start"], { stdio: "ignore" });
}

/** The busy record's seq, state, and event. */
function busyRecord(fmHome: string, task: string): { seq: number; state: string; event: string } | undefined {
    const path = join(fmHome, "state", `${task}.busy-state`);
    if (!existsSync(path)) return undefined;
    const text = readFileSync(path, "utf8");
    const field = (name: string) => new RegExp(`(?:^| )${name}=(\\S+)`).exec(text)?.[1] ?? "";

    return { seq: Number(field("seq")), state: field("state"), event: field("event") };
}

async function spawnWorker(fmHome: string, main: unknown, task: string, cwd: string, extra: string[] = []): Promise<number> {
    const prompt = join(cwd, "..", `${task}.prompt`);
    const env = join(cwd, "..", `${task}.env`);
    writeFileSync(prompt, "You are a task worker launched by Firstmate (fixture channel statement).");
    writeFileSync(env, JSON.stringify({ FM_TASK_ID: task, FM_TASK_INBOX: `/fixture/${task}.inbox`, FM_PI_POCKET_CONVERSATION: "forged" }));
    const started = await bridgeCall(fmHome, main, ["spawn", "--task", task, "--cwd", cwd, "--prompt-file", prompt, "--env-file", env, ...extra]);
    assert.equal(started.code, 0, started.err);

    return Number(JSON.parse(started.out).session);
}

function worktree(name: string): string {
    const dir = join(root, `${name}-${String(Date.now())}`, "wt");
    mkdirSync(dir, { recursive: true });

    return dir;
}

const settle = (ms = 400) => new Promise((resolve) => setTimeout(resolve, ms));

// ---------------------------------------------------------------------------------------------------------------
// Experiment (b)'s server: bind, hold one wake back, report, and wait to be killed.

if (process.argv.includes("--branch-child")) {
    // The restart experiment's first server: supervise, start the branch, and wait to be killed.
    const [dataDir, fmHome] = process.argv.slice(process.argv.indexOf("--branch-child") + 1) as [string, string];
    const app = await open(dataDir, true);
    const id = await newSession(app, fmHome);
    await say(app, id, "start firstmate");
    const branch = await branchStarted(app, fmHome);
    process.stdout.write(`branch ${String(id)} ${String(branch)}\n`);
    await new Promise(() => {});
}

if (process.argv.includes("--stall-child")) {
    // A server whose branch deadline is short (the parent sets it): a turn that reported, then ran past it.
    const [dataDir, fmHome] = process.argv.slice(process.argv.indexOf("--stall-child") + 1) as [string, string];
    const app = await open(dataDir, true);
    const id = await newSession(app, fmHome);
    await say(app, id, "start firstmate");
    await branchStarted(app, fmHome);
    await until(() => lines(join(fmHome, "stub", "arms.log")).length === 1, "the first arm", LONG);
    const reason = queueTaskWake(fmHome, "task-report-stall");
    fire(fmHome, reason);
    await until(async () => count(await userTexts(app, id), `${WAKE}${reason}`) === 1, "the late wake back on main", LONG);
    const wake = (await userTexts(app, id)).find((text) => text.includes(`${WAKE}${reason}`))!;
    assert.match(wake, /did not handle this wake \(its turn ran past its deadline\)/);
    assert.equal(outcomeRows(fmHome).length, 1, "the outcome recorded before the deadline stays in the store");
    assert.equal(existsSync(join(fmHome, "state", ".pocket-branch-mirror")), false, "a late turn does not advance the mirror");
    assert.equal(existsSync(join(fmHome, "state", ".branch-eligible-rows")), false, "the grant is released for main's drain");
    process.stdout.write("stall ok\n");
    await app.close();
    process.exit(0);
}

if (process.argv.includes("--worker-child")) {
    // The worker restart experiment's first server: start a worker, put it in a long tool call, and wait to be killed.
    const [dataDir, fmHome, wt] = process.argv.slice(process.argv.indexOf("--worker-child") + 1) as [string, string, string];
    const app = await open(dataDir, true);
    await app.setSubagentModels(owner(app), ["faux/faux-1"]);
    const id = await newSession(app, fmHome);
    await say(app, id, "start firstmate");
    await bridgeUp(fmHome, id);
    await readBridgeToken(app, id);
    armBusy(fmHome, "task-cut");
    const session = await spawnWorker(fmHome, id, "task-cut", wt);
    const sent = await bridgeCall(fmHome, id, ["send", "--session", String(session), "--text", "work for a long time"]);
    assert.equal(sent.code, 0, sent.err);
    await until(() => workerRecord(fmHome, "task-cut")?.busy === true, "the worker's long run", LONG);
    process.stdout.write(`worker ${String(id)} ${String(session)}\n`);
    await new Promise(() => {});
}

if (process.argv.includes("--child")) {
    const [dataDir, fmHome] = process.argv.slice(process.argv.indexOf("--child") + 1) as [string, string];
    const app = await open(dataDir, true);
    const id = await newSession(app, fmHome);
    await say(app, id, "start firstmate");
    await until(() => lines(join(fmHome, "stub", "arms.log")).length === 1, "the first arm", LONG);
    await recordCost(app, id, 2);
    await app.spend.setSessionBudget(owner(app), id, 1);
    fire(fmHome, "signal: crash wake");
    await until(async () => {
        const task = await watchTask(app, id);
        return task?.state.checkpoint?.pending?.length === 1 && lines(join(fmHome, "stub", "arms.log")).length >= 2;
    }, "the held-back wake", LONG);
    process.stdout.write(`held ${String(id)}\n`);
    await new Promise(() => {});
}

// ---------------------------------------------------------------------------------------------------------------
// Tests

const apps: App[] = [];

after(async () => {
    for (const app of apps) await app.close().catch(() => {});
});

async function started(dataDir = join(root, `data-${homes + 1}`)) {
    const fmHome = await home();
    const app = await open(dataDir, true);
    apps.push(app);
    const id = await newSession(app, fmHome);

    return { app, id, fmHome };
}

test("a session start binds the lock to the session, starts the watcher, and delivers each wake once", async () => {
    const { app, id, fmHome } = await started();

    await say(app, id, "start firstmate");
    assert.equal(readFileSync(join(fmHome, "state", ".lock"), "utf8").split("\n")[0], String(process.pid));
    assert.equal(readFileSync(join(fmHome, "state", ".lock-session"), "utf8").split("\n")[0], `pi-pocket:${String(id)}`);
    await until(() => lines(join(fmHome, "stub", "arms.log")).length === 1, "the first arm", LONG);

    fire(fmHome, "signal: first wake");
    await until(async () => count(await userTexts(app, id), `${WAKE}signal: first wake`) === 1, "the first wake", LONG);
    // The successor was armed, handed the predecessor, before the wake reached the model.
    const arms = lines(join(fmHome, "stub", "arms.log"));
    assert.equal(arms.length, 2);
    assert.equal(arms[1]!.split(" ")[1], arms[0]!.split(" ")[0]);
    const wake = (await userTexts(app, id)).find((text) => text.includes(WAKE))!;
    assert.match(wake, /^\u2063FIRSTMATE_OP: v1 watcher: /);
    assert.match(wake, /Run bin\/fm-wake-drain\.sh first/);
    assertOperational(entryFor(await storedEntries(app, id), `${WAKE}signal: first wake`), "watcher", "the watcher wake");

    fire(fmHome, "check: second wake");
    await until(async () => count(await userTexts(app, id), `${WAKE}check: second wake`) === 1, "the second wake", LONG);
    assert.equal(count(await userTexts(app, id), WAKE), 2);

    // The repair tool leaves a live watcher alone.
    await say(app, id, "repair the watcher");
    assert.ok((await toolSaid(app, id)).some((text) => text.startsWith("watcher: unchanged")));
    assert.equal(lines(join(fmHome, "stub", "arms.log")).length, 3);
});

test("a fresh conversation's first request runs the session start and gives the model the whole digest, once", async () => {
    const { app, id, fmHome } = await started();
    const elsewhere = await newSession(app, work);
    // A digest well past Pi Pocket's 50 KiB bash output cap, which kept only a model-run digest's tail.
    const big = "x".repeat(120 * 1024);
    writeFileSync(join(fmHome, "stub", "digest-tail"), `${big}\nDIGEST END\n`);

    await say(app, id, "hello");
    await say(app, elsewhere, "hello");
    assert.deepEqual(lines(join(fmHome, "stub", "starts.log")), ["startup"], "one session start, by the drop-in");
    assert.equal(readFileSync(join(fmHome, "state", ".lock-session"), "utf8").split("\n")[0], `pi-pocket:${String(id)}`);
    const texts = await userTexts(app, id);
    assert.equal(texts[0], "hello", "the captain's input stays first");
    const digest = texts.find((text) => text.includes("STUB DIGEST startup"));
    assert.ok(digest !== undefined, texts.join("\n---\n"));
    assert.match(digest, /^\u2063FIRSTMATE_OP: v1 session-start: /);
    assert.ok(digest.includes(big) && digest.includes("DIGEST END"), "the whole digest, not its tail");
    const digestEntry = entryFor(await storedEntries(app, id), "STUB DIGEST startup");
    assert.equal(digestEntry?.kind, "x.firstmate.session-start");
    assert.equal(digestEntry?.summary, "session-start");
    assert.equal(entryFor(await storedEntries(app, id), "hello")?.kind, "pi.user", "a person's own message stays theirs");
    // The session start that bound the lock also started the watcher.
    await until(() => lines(join(fmHome, "stub", "arms.log")).length === 1, "the first arm", LONG);

    // Later requests and turns see the placed digest and run nothing again.
    await say(app, id, "show the marker");
    assert.equal(lines(join(fmHome, "stub", "starts.log")).length, 1);
    assert.equal(count(await userTexts(app, id), "STUB DIGEST startup"), 1);
    assert.equal(count(await userTexts(app, elsewhere), "STUB DIGEST"), 0, "no digest outside a Firstmate home");
    // The prompt states the shell model and no longer asks the model to run the session start.
    const prompt = systemPrompts.findLast((text) => text.includes("Firstmate Pi Pocket drop-in is active"))!;
    assert.ok(prompt.includes("Every bash call starts a new shell in this conversation's working directory; a cd never carries over to the next call."));
    assert.ok(!prompt.includes("run `bin/fm-session-start.sh` once"), prompt);
});

test("bash carries the Pi Pocket marker only in a Firstmate home", async () => {
    const { app, id } = await started();
    const elsewhere = await newSession(app, work);

    await say(app, id, "show the marker");
    await say(app, elsewhere, "show the marker");
    assert.ok((await toolSaid(app, id)).some((text) => text.includes(`marker=${String(id)} server=${String(process.pid)}`)));
    assert.ok((await toolSaid(app, elsewhere)).some((text) => text.includes("marker=none server=none")));
});

test("seatbelts block a persistent cd, a backgrounded watcher, and Pi Pocket's delegation tools only in a Firstmate home", async () => {
    const { app, id } = await started();
    const elsewhere = await newSession(app, work);

    await say(app, id, "go elsewhere");
    await say(app, id, "background the watcher");
    await say(app, id, "ask a subagent");
    const said = await toolSaid(app, id);
    assert.ok(said.some((text) => text.includes("Tool call blocked: [persistent-cd]")), said.join("\n"));
    assert.ok(said.some((text) => text.includes("Tool call blocked: [watcher-background]")), said.join("\n"));
    assert.ok(said.some((text) => text.includes("Tool call blocked: [subagent-dispatch]") && text.includes("bin/fm-spawn.sh")), said.join("\n"));

    await say(app, elsewhere, "go elsewhere");
    await say(app, elsewhere, "ask a subagent");
    const free = await toolSaid(app, elsewhere);
    assert.ok(free.every((text) => !text.includes("Tool call blocked")), free.join("\n"));
});

test("a codemode script's tool calls pass the same seatbelts: allowed ones run, delegation stays blocked", async () => {
    const { app, id } = await started();

    await say(app, id, "read from a script");
    await say(app, id, "schedule from a script");
    const said = await toolSaid(app, id);
    assert.ok(said.some((text) => text.includes("script-ran")), said.join("\n"));
    assert.ok(said.every((text) => !text.includes("is not a function")), said.join("\n"));
    assert.ok(said.some((text) => text.includes("failed: Tool call blocked: [subagent-dispatch]")), said.join("\n"));
});

test("wakes wait while the session is held back by a spend limit, the watcher keeps cycling, and each wake arrives once", async () => {
    const { app, id, fmHome } = await started();

    await say(app, id, "start firstmate");
    await until(() => lines(join(fmHome, "stub", "arms.log")).length === 1, "the first arm", LONG);
    await recordCost(app, id, 2);
    await app.spend.setSessionBudget(owner(app), id, 1);
    assert.notEqual(app.spend.heldBack(id), undefined);

    fire(fmHome, "signal: held wake");
    await until(async () => (await watchTask(app, id))?.state.checkpoint?.pending !== undefined, "the pending wake", LONG);
    await until(() => lines(join(fmHome, "stub", "arms.log")).length === 2, "the successor arm", LONG);
    // A second wake while the first still waits: the successor's close is read and a third arm starts anyway.
    fire(fmHome, "check: second held wake");
    await until(() => lines(join(fmHome, "stub", "arms.log")).length === 3, "the arm after the second held wake", LONG);
    await until(async () => (await watchTask(app, id))?.state.checkpoint?.pending?.length === 2, "two pending wakes", LONG);
    const arms = lines(join(fmHome, "stub", "arms.log"));
    assert.equal(arms[2]!.split(" ")[1], arms[1]!.split(" ")[0], "the third arm succeeds the second");
    await new Promise((resolve) => setTimeout(resolve, 500));
    assert.equal(count(await userTexts(app, id), WAKE), 0, "no wake while held back");

    await app.spend.setSessionBudget(owner(app), id, null);
    await until(async () => count(await userTexts(app, id), `${WAKE}check: second held wake`) === 1, "the released wakes", LONG);
    const texts = await userTexts(app, id);
    assert.equal(count(texts, `${WAKE}signal: held wake`), 1);
    assert.equal(count(texts, WAKE), 2);
    assert.ok(
        texts.findIndex((text) => text.includes(`${WAKE}signal: held wake`)) < texts.findIndex((text) => text.includes(`${WAKE}check: second held wake`)),
        "the wakes arrive in the order they were read",
    );
    await until(async () => (await watchTask(app, id))?.state.checkpoint?.pending === undefined, "an empty queue", LONG);
    assert.equal(lines(join(fmHome, "stub", "arms.log")).length, 3, "delivery started no extra arm");
});

test("an arm that keeps reporting ready and then failing still exhausts the retry limit and ends visibly", async () => {
    const { app, id, fmHome } = await started();

    await say(app, id, "start firstmate");
    await until(() => lines(join(fmHome, "stub", "arms.log")).length === 1, "the first arm", LONG);
    writeFileSync(join(fmHome, "stub", "fail-always"), "");
    fire(fmHome, "signal: last good wake");
    await until(async () => (await watchTask(app, id))?.state.status === "terminal", "the watcher task to give up", 4 * LONG);
    // The failure is a follow-up: it reaches the session once the wake's turn answers.
    await until(async () => count(await userTexts(app, id), "could not restore watcher continuity") > 0, "the failure", LONG);
    const texts = await userTexts(app, id);
    assert.equal(count(texts, `${WAKE}signal: last good wake`), 1);
    assert.equal(count(texts, "could not restore watcher continuity after 5 retries"), 1, texts.join("\n---\n"));
    const failure = entryFor(await storedEntries(app, id), "could not restore watcher continuity");
    if (presents) {
        assert.equal(failure?.kind, "x.firstmate.operational");
        assert.equal(failure?.summary, "watcher: FAILED - stub arm broke after reporting ready");
    } else {
        assert.equal(failure?.kind, "pi.user");
    }
    // The arm that read the good wake, then the first failing one and its five retries.
    assert.equal(lines(join(fmHome, "stub", "arms.log")).length, 7);
});

test("the turn-end guard continues a turn that would end blind exactly once", async () => {
    const { app, id, fmHome } = await started();

    writeFileSync(join(fmHome, "stub", "guard-code"), "2");
    await say(app, id, "hello");
    await until(async () => (await userTexts(app, id)).some((text) => text.includes("STUB GUARD")), "the guard continuation", LONG);
    await (await app.harness.conversation(id, context))!.waitForIdle(context);
    const texts = await userTexts(app, id);
    assert.equal(count(texts, "TURN WOULD END BLIND"), 1, texts.join("\n---\n"));
    assert.match(texts.find((text) => text.includes("STUB GUARD"))!, /^\u2063FIRSTMATE_OP: v1 turn-end-guard: /);
    assert.equal(entryFor(await storedEntries(app, id), "STUB GUARD")?.kind, "pi.user", "the turn-end guard is presented by its prefix, not a new stored kind");
});

test("experiment (b): a server killed while a wake waits redelivers the digest and the wake exactly once after restart", async () => {
    const fmHome = await home();
    const dataDir = mkdtempSync(join(root, "crash-"));
    const child = spawn(process.execPath, [process.argv[1]!, "--child", dataDir, fmHome], {
        env: { ...process.env, TMPDIR: mkdtempSync(join(tmpdir(), "fm-child-")) },
        stdio: ["ignore", "pipe", "inherit"],
    });
    const id = await new Promise<string>((resolve, reject) => {
        let out = "";
        child.stdout!.on("data", (chunk: Buffer) => {
            out += chunk.toString();
            const held = /^held (\S+)$/m.exec(out);
            if (held) resolve(held[1]!);
        });
        child.on("close", (code) => reject(new Error(`the child server ended first (${String(code)}): ${out}`)));
    });
    child.kill("SIGKILL");
    await new Promise((resolve) => child.once("close", resolve));
    assert.deepEqual(lines(join(fmHome, "stub", "starts.log")), ["startup"], "only the first request's session start");

    const app = await open(dataDir, false);
    apps.push(app);
    await until(() => lines(join(fmHome, "stub", "starts.log")).length === 2, "the restart's session start", LONG);
    await app.spend.setSessionBudget(owner(app), id, null);
    await until(async () => count(await userTexts(app, id), `${WAKE}signal: crash wake`) === 1, "the redelivered wake", LONG);
    const texts = await userTexts(app, id);
    assert.equal(count(texts, "STUB DIGEST startup"), 2, "the first request's digest and one restart digest");
    assert.equal(count(texts, WAKE), 1, "one wake");
    const digests = (await storedEntries(app, id)).filter((entry) => entry.text.includes("STUB DIGEST startup"));
    assert.ok(digests.some((entry) => entry.kind === "x.firstmate.session-start" && entry.summary === "session-start"));
    assertOperational(
        digests.find((entry) => entry.kind !== "x.firstmate.session-start"),
        "session-start",
        "the restart digest",
    );
    assert.equal(readFileSync(join(fmHome, "state", ".lock"), "utf8").split("\n")[0], String(process.pid));

    // A duplicate submission of the wake's request id, through the durable handle, is the same submission.
    const task = await watchTask(app, id);
    assert.notEqual(task, undefined, "the watcher task");
    assert.notEqual(task.state.status, "terminal", `the watcher task still runs: ${JSON.stringify(task.state)}`);
    const requestId = `p:${owner(app).id}:${clientKey(`fm-wake-${String(task.id)}-1`)}`;
    const existing = await app.harness.commit((tx: { submissionByRequest: (c: unknown, r: string) => Promise<unknown> }) => tx.submissionByRequest(id, requestId), context);
    assert.notEqual(existing, undefined, `a submission for ${requestId}`);
    const conversation = (await app.harness.conversation(id, context))!;
    await conversation.submit({ type: "input", content: "duplicate", requestId }, context);
    await conversation.waitForIdle(context);
    assert.equal(count(await userTexts(app, id), "duplicate"), 0);
    assert.equal(count(await userTexts(app, id), WAKE), 1);
});

// ---------------------------------------------------------------------------------------------------------------
// The supervision branch

test("the supervision session starts once as a visible linked session, takes a task wake, and its captain outcome reaches main through the store", async () => {
    const { app, id, fmHome } = await started();

    await say(app, id, "start firstmate");
    const branch = await branchStarted(app, fmHome);
    await until(() => lines(join(fmHome, "stub", "arms.log")).length === 1, "the first arm", LONG);
    // One linked session, in the home, titled for the captain, listed under main.
    const listed = supervisionSessions(app);
    assert.equal(listed.length, 1, JSON.stringify(app.sessions()));
    assert.equal(listed[0]!.id, branch);
    assert.equal(listed[0]!.cwd, fmHome);
    assert.equal(listed[0]!.linkedFrom?.id, Number(id));

    // The supervision session's prompt is the branch prompt, not main's supervisor contract.
    assert.ok(systemPrompts.some((prompt) => prompt.includes("You are the SUPERVISION BRANCH of firstmate") && !prompt.includes("# Firstmate fixture")));
    assert.ok(systemPrompts.some((prompt) => prompt.includes("# Firstmate fixture") && !prompt.includes("SUPERVISION BRANCH")));

    fire(fmHome, queueTaskWake(fmHome, "task-report"));
    await until(() => outcomeRows(fmHome).length === 1, "the branch's outcome", LONG);
    const [row] = outcomeRows(fmHome);
    assert.equal(row!.task, "task-report");
    assert.equal(row!.verdict, "captain");
    // The wake ran in the supervision session, never in main, with main's dialog mirrored at its head.
    const branchTexts = await userTexts(app, branch);
    assert.equal(count(branchTexts, `${BRANCH_WAKE}signal: task-report.status`), 1, branchTexts.join("\n---\n"));
    const branchWake = branchTexts.find((text) => text.includes(BRANCH_WAKE))!;
    assert.match(branchWake, /^MAIN DIALOG MIRROR \(read-only context/);
    assert.ok(branchWake.includes("[captain] start firstmate"), branchWake);
    assert.ok(!branchWake.includes("STUB DIGEST") && !branchWake.includes("FIRSTMATE_OP"), "Firstmate's own inputs are not dialog");
    assert.ok(branchWake.includes("finish with fm_branch_report"));
    // Main gets the processing request, processes it once, and the store records it processed.
    await until(async () => count(await userTexts(app, id), PROCESSING) === 1, "the processing request", LONG);
    await until(() => existsSync(join(fmHome, "state", ".branch-outcomes-processed")) && readFileSync(join(fmHome, "state", ".branch-outcomes-processed"), "utf8").trim() === String(row!.seq), "the acknowledgement", LONG);
    const mainTexts = await userTexts(app, id);
    assert.equal(count(mainTexts, `${WAKE}signal: task-report.status`), 0, "the handled wake never reached main");
    assert.ok(mainTexts.find((text) => text.includes(PROCESSING))!.includes(`task-report: task-report needs the captain's merge call`));
    assertOperational(entryFor(await storedEntries(app, id), PROCESSING), "branch-outcome", "the processing request");
    assert.equal(entryFor(await storedEntries(app, branch), BRANCH_WAKE)?.kind, "pi.user", "the supervision session's wake stays an ordinary message");
    await until(async () => (await toolSaid(app, id)).some((text) => text.startsWith(`processed through seq ${String(row!.seq)}`)), "the acknowledgement's result", LONG);
    // Main reads the store through fm_branch_outcomes, and the branch's grant and turn are gone.
    await say(app, id, "what happened in the fleet");
    assert.ok((await toolSaid(app, id)).some((text) => text.includes("task-report needs the captain's merge call")));
    assert.equal(existsSync(join(fmHome, "state", ".pocket-branch-turn")), false);
    assert.equal(existsSync(join(fmHome, "state", ".branch-eligible-rows")), false);

    // A wake the branch may not take (no task row queued) still goes to main, and no second session starts.
    fire(fmHome, "check: a merged PR");
    await until(async () => count(await userTexts(app, id), `${WAKE}check: a merged PR`) === 1, "the main-owned wake", LONG);
    assert.equal(supervisionSessions(app).length, 1);
    // Main may not report, and the branch may not use main's tools.
    await say(app, id, "report from main");
    assert.ok((await toolSaid(app, id)).some((text) => text.includes("[supervision-branch] only the Firstmate supervision session records outcomes")));
    await say(app, branch, "repair the watcher");
    assert.ok((await toolSaid(app, branch)).some((text) => text.includes("[supervision-branch] the Firstmate supervision session uses only read, bash, fm_branch_report, and the context tools compress, decompress, search_context, acp_status, acp_cache; fm_watch_arm_pocket belongs to the main Firstmate session.")));
    // Context tools manage only this session's context, so the branch may use them; spawn and steer tools stay blocked.
    await say(app, branch, "compress the context");
    const branchSaid = await toolSaid(app, branch);
    assert.ok(branchSaid.some((text) => text.includes("Tool compress is not available") && !text.includes("[supervision-branch]")), branchSaid.join("\n"));
    await say(app, branch, "start a subagent");
    await say(app, branch, "run a script"); // codemode would reach main's tools from a script, so the branch must not have it
    const blocked = await toolSaid(app, branch);
    assert.ok(blocked.some((text) => text.includes("[supervision-branch]") && text.includes("subagent belongs to the main Firstmate session")), blocked.join("\n"));
    assert.ok(blocked.some((text) => text.includes("[supervision-branch]") && text.includes("codemode belongs to the main Firstmate session")), blocked.join("\n"));
    // The branch's bash runs as the branch actor under main's Pi Pocket identity, with the actor read-only.
    await say(app, branch, "show the actor");
    assert.ok(
        (await toolSaid(app, branch)).some((text) => text.includes(`marker=${String(id)} actor=branch holder=${String(process.pid)} primary=pi-pocket reassign=refused`)),
        (await toolSaid(app, branch)).join("\n"),
    );
    // A branch never gets a second one, and main's next cycles keep the same one.
    assert.equal(supervisionSessions(app).length, 1);
    assert.equal(branchRecord(fmHome)!.branch, branch);
});

test("a branch turn that records nothing, or reports outside its wake, hands the wake to main", async () => {
    const { app, id, fmHome } = await started();

    await say(app, id, "start firstmate");
    await branchStarted(app, fmHome);
    await until(() => lines(join(fmHome, "stub", "arms.log")).length === 1, "the first arm", LONG);

    const reason = queueTaskWake(fmHome, "task-off-scope");
    fire(fmHome, reason);
    await until(async () => count(await userTexts(app, id), `${WAKE}${reason}`) === 1, "the wake back on main", LONG);
    const branch = branchRecord(fmHome)!.branch;
    assert.ok((await toolSaid(app, branch)).some((text) => text.includes("report refused: the wake being handled") && text.includes("not some-other-task")));
    assert.match((await userTexts(app, id)).find((text) => text.includes(`${WAKE}${reason}`))!, /did not handle this wake \(its turn ended without recording an outcome\)/);
    assert.equal(outcomeRows(fmHome).length, 0);
    assert.equal(existsSync(join(fmHome, "state", ".branch-eligible-rows")), false, "the grant is released for main's drain");
});

test("after a Pi Pocket restart the supervision session is reattached, never duplicated, and still takes wakes", async () => {
    const fmHome = await home();
    const dataDir = mkdtempSync(join(root, "branch-restart-"));
    const child = spawn(process.execPath, [process.argv[1]!, "--branch-child", dataDir, fmHome], {
        env: { ...process.env, TMPDIR: mkdtempSync(join(tmpdir(), "fm-child-")) },
        stdio: ["ignore", "pipe", "inherit"],
    });
    const [id, branch] = await new Promise<[number, number]>((resolve, reject) => {
        let out = "";
        child.stdout!.on("data", (chunk: Buffer) => {
            out += chunk.toString();
            const started = /^branch (\S+) (\S+)$/m.exec(out);
            if (started) resolve([Number(started[1]), Number(started[2])]);
        });
        child.on("close", (code) => reject(new Error(`the child server ended first (${String(code)}): ${out}`)));
    });
    child.kill("SIGKILL");
    await new Promise((resolve) => child.once("close", resolve));

    const app = await open(dataDir, false);
    apps.push(app);
    await until(() => lines(join(fmHome, "stub", "starts.log")).length === 2, "the restart's session start", LONG);
    await until(() => lines(join(fmHome, "stub", "arms.log")).length === 2, "the re-arm", LONG);
    assert.deepEqual(branchRecord(fmHome), { main: id, branch, start: 0 });
    assert.equal(supervisionSessions(app).length, 1, JSON.stringify(app.sessions()));

    fire(fmHome, queueTaskWake(fmHome, "task-report-after"));
    await until(() => outcomeRows(fmHome).length === 1, "the outcome after the restart", LONG);
    assert.equal(count(await userTexts(app, branch), `${BRANCH_WAKE}signal: task-report-after.status`), 1);
    assert.equal(count(await userTexts(app, id), `${WAKE}signal: task-report-after.status`), 0);
    assert.equal(supervisionSessions(app).length, 1);
});

test("a branch turn that runs past its deadline hands its wake to main even after it recorded an outcome", async () => {
    const fmHome = await home();
    const dataDir = mkdtempSync(join(root, "branch-stall-"));
    const child = spawn(process.execPath, [process.argv[1]!, "--stall-child", dataDir, fmHome], {
        env: { ...process.env, TMPDIR: mkdtempSync(join(tmpdir(), "fm-child-")), FM_POCKET_BRANCH_TURN_TIMEOUT_MS: "3000" },
        stdio: ["ignore", "pipe", "pipe"],
    });
    let out = "";
    child.stdout!.on("data", (chunk: Buffer) => (out += chunk.toString()));
    child.stderr!.on("data", (chunk: Buffer) => (out += chunk.toString()));
    const code = await new Promise<number | null>((resolve) => child.once("close", resolve));
    assert.equal(code, 0, out);
    assert.match(out, /^stall ok$/m);
});

function pin(fmHome: string, name: string, value: string): void {
    mkdirSync(join(fmHome, "config"), { recursive: true });
    writeFileSync(join(fmHome, "config", name), `${value}\n`);
}

async function sessionModel(app: App, session: unknown): Promise<string | undefined> {
    return (await app.agentState(session))?.model?.modelId;
}

test("a supervision start without an allowed model is refused, and the drop-in names one from the owner's list", async () => {
    const { app, id, fmHome } = await started();
    await app.setSubagentModels(owner(app), ["faux/faux-2"]);
    // The pin is not on the list, so the first usable listed model is the one that must be named.
    pin(fmHome, "supervision-branch-model", "faux/faux-1");
    pin(fmHome, "supervision-branch-effort", "off");
    const linked = app.linkedSessions;
    const real = linked.start.bind(linked);
    const calls: { model?: string; thinking?: string }[] = [];
    linked.start = async (source: unknown, request: { model?: string; thinking?: string }, key: string) => {
        calls.push({ model: request.model, thinking: request.thinking });
        if (request.model !== "faux/faux-2") {
            throw new Error("A model is required: this session's model is not on the owner's list for subagents and linked sessions. Choose one that suits the work: faux/faux-2.");
        }
        return real(source, request, key);
    };
    // The stand-in refuses the same way Pi Pocket does when the owner's list is set and no allowed model is named.
    await assert.rejects(linked.start(id, { message: "probe", title: "probe" }, "probe-without-model"), /A model is required[^]*faux\/faux-2/);
    await say(app, id, "start firstmate");
    const branch = await branchStarted(app, fmHome);
    assert.deepEqual(calls[1], { model: "faux/faux-2", thinking: "off" }, JSON.stringify(calls));
    assert.equal(await sessionModel(app, branch), "faux-2");
    assert.equal(supervisionSessions(app).length, 1);
});

test("the supervision model pin wins when it is listed, and an effort the model does not support is left out", async () => {
    const { app, id, fmHome } = await started();
    await app.setSubagentModels(owner(app), ["faux/faux-2", "faux/faux-1"]);
    pin(fmHome, "supervision-branch-model", "faux/faux-1");
    pin(fmHome, "supervision-branch-effort", "xhigh");
    const linked = app.linkedSessions;
    const real = linked.start.bind(linked);
    const calls: { model?: string; thinking?: string }[] = [];
    linked.start = async (source: unknown, request: { model?: string; thinking?: string }, key: string) => {
        calls.push({ model: request.model, thinking: request.thinking });
        return real(source, request, key);
    };
    await say(app, id, "start firstmate");
    const branch = await branchStarted(app, fmHome);
    assert.equal(calls[0]?.model, "faux/faux-1", JSON.stringify(calls));
    assert.equal(calls[0]?.thinking, undefined, JSON.stringify(calls));
    assert.equal(await sessionModel(app, branch), "faux-1");
});

test("when no listed model can be used, wakes stay on main and the start is not attempted again", async () => {
    const { app, id, fmHome } = await started();
    await app.setSubagentModels(owner(app), ["faux/faux-2"]);
    mock.method(app.providers, "problem", async (ref: { provider: string; modelId: string }) =>
        `${ref.provider}/${ref.modelId}` === "faux/faux-2" ? "its sign-in expired" : undefined);
    const linked = app.linkedSessions;
    const real = linked.start.bind(linked);
    let starts = 0;
    linked.start = async (source: unknown, request: unknown, key: string) => {
        starts += 1;
        return real(source, request, key);
    };
    const tab = fakeTab(id, owner(app));
    app.attach(tab.client);
    await say(app, id, "start firstmate");
    await until(
        () => tab.events.some((event) => event.event === "notice" && String(event.data.message).includes("add a model to Pi Pocket's list for subagents and linked sessions")),
        "the model-list notice",
        LONG,
    );
    assert.equal(starts, 0);
    assert.equal(supervisionSessions(app).length, 0);
    await until(() => lines(join(fmHome, "stub", "arms.log")).length === 1, "the first arm", LONG);
    fire(fmHome, "signal: listed models unusable");
    await until(async () => count(await userTexts(app, id), `${WAKE}signal: listed models unusable`) === 1, "the wake on main", LONG);
    assert.equal(starts, 0);
});

test("a refused supervision start cools off instead of being retried on every wake", async () => {
    const { app, id, fmHome } = await started();
    await app.setSubagentModels(owner(app), ["faux/faux-2"]);
    const linked = app.linkedSessions;
    let starts = 0;
    linked.start = async (_source: unknown, request: { model?: string }) => {
        starts += 1;
        if (request.model !== "faux/faux-2") {
            throw new Error("A model is required: this session's model is not on the owner's list for subagents and linked sessions. Choose one that suits the work: faux/faux-2.");
        }
        throw new Error("linked session refused");
    };
    await say(app, id, "start firstmate");
    await until(() => starts === 1, "the first refused start", LONG);
    await until(() => lines(join(fmHome, "stub", "arms.log")).length >= 1, "the first arm", LONG);
    fire(fmHome, "signal: first refused");
    await until(async () => starts === 2 && count(await userTexts(app, id), `${WAKE}signal: first refused`) === 1, "the second refusal and its wake on main", LONG);
    fire(fmHome, "signal: cooled off");
    await until(async () => count(await userTexts(app, id), `${WAKE}signal: cooled off`) === 1, "the cooled-off wake on main", LONG);
    assert.equal(starts, 2);
});

test("a compaction re-emits the session start for the model", { timeout: 60_000 }, async () => {
    const { app, id, fmHome } = await started();
    app.settings.getCompactionSettings = () => ({ enabled: true, reserveTokens: 16384, keepRecentTokens: 0 }) as never;
    await say(app, id, "hello");
    const conversation = (await app.harness.conversation(id, context))!;
    assert.equal(typeof conversation.compact, "function");
    const task = await conversation.compact(undefined, context);
    await app.harness.waitForTask(task, context);
    await say(app, id, "after the compaction");
    await until(() => lines(join(fmHome, "stub", "starts.log")).includes("compact"), "the compact re-emit", LONG);
    const digest = entryFor(await storedEntries(app, id), "STUB DIGEST compact");
    assertOperational(digest, "session-start", "the compaction digest");
    assert.match(digest!.text, /^\u2063FIRSTMATE_OP: v1 session-start: /);
});

test("/calm toggles the shared preference file and a reloaded tab can read it", { timeout: 60_000 }, async () => {
    const { app, id, fmHome } = await started();
    const elsewhere = await newSession(app, work);
    const path = join(fmHome, "config", "calm");
    const commandId = app.webs.commands().find((command: { name?: string }) => command.name === "firstmate-calm")?.id;
    assert.equal(typeof commandId, "string");
    const toggle = async (session: unknown, args = "") =>
        app.extensionCommands.run(session, owner(app), { commandId, args, requestId: crypto.randomUUID() }) as Promise<{
            type?: string;
            level?: string;
            message?: string;
            status?: string;
        }>;

    const textsBefore = (await userTexts(app, id)).length;
    const turnedOn = await toggle(id);
    assert.equal(turnedOn.status, "done");
    assert.equal(turnedOn.type, "toast");
    assert.equal(turnedOn.message, "Calm on");
    assert.equal(readFileSync(path, "utf8"), "on\n");
    assert.equal(statSync(path).mode & 0o777, 0o600);
    assert.equal((await userTexts(app, id)).length, textsBefore, "/calm does not add a transcript row");

    const turnedOff = await toggle(id, "please");
    assert.equal(turnedOff.message, "Calm off");
    assert.equal(readFileSync(path, "utf8"), "off\n");

    writeFileSync(path, "max\n", { mode: 0o600 });
    assert.equal((await toggle(id)).message, "Calm off", "the legacy max value is on, so /calm turns it off");
    assert.equal(readFileSync(path, "utf8"), "off\n");

    const unchanged = await toggle(elsewhere);
    assert.equal(unchanged.message, "Calm is unchanged: this session is not a Firstmate home");
    assert.equal(readFileSync(path, "utf8"), "off\n");

    assert.equal((await toggle(id)).message, "Calm on");

    const { createHandler } = await import(join(checkout, "src/server/http.ts"));
    const server: Server = createServer(createHandler({ app, listen: { host: "127.0.0.1", port: 0 }, restart: () => {} }));
    try {
        await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
        const base = `http://127.0.0.1:${(server.address() as { port: number }).port}`;
        const readCalm = async () => {
            const response = await fetch(`${base}/api/x/firstmate/calm?conversation=${String(id)}`, {
                headers: { authorization: `Bearer ${app.config.ownerToken}`, "x-pocket": "1" },
            });
            assert.equal(response.status, 200);
            return response.json() as Promise<{ calm?: boolean }>;
        };
        assert.deepEqual(await readCalm(), { calm: true });
        assert.equal((await toggle(id)).message, "Calm off");
        assert.deepEqual(await readCalm(), { calm: false });
    } finally {
        server.closeAllConnections();
        server.close();
    }
});

// ---------------------------------------------------------------------------------------------------------------
// Pocket workers

const NUDGE = "Firstmate: the Pi Pocket server restarted while you were working";
const FENCE = "a request, not an order";

/** A started main session that holds the lock, serves the worker bridge, and may start workers on faux/faux-1. */
async function workerMain() {
    const ctx = await started();
    await ctx.app.setSubagentModels(owner(ctx.app), ["faux/faux-1"]);
    await say(ctx.app, ctx.id, "start firstmate");
    await bridgeUp(ctx.fmHome, ctx.id);
    await readBridgeToken(ctx.app, ctx.id);

    return ctx;
}

async function idle(app: App, session: number): Promise<void> {
    await (await app.harness.conversation(session, context))!.waitForIdle(context);
}

test("a Pocket worker is a linked session in its worktree whose brief arrives unfenced, with its task env, prompt, and blocked tools", { timeout: 90_000 }, async () => {
    const { app, id, fmHome } = await workerMain();
    const wt = worktree("worker-basic");
    armBusy(fmHome, "task-w");
    const session = await spawnWorker(fmHome, id, "task-w", wt, ["--exclude-tools", "web_fetch"]);
    // Listed under main, in the worktree, on the listed model.
    const listed = app.sessions().find((row: { id: number }) => row.id === session);
    assert.equal(listed?.cwd, wt);
    assert.equal(listed?.linkedFrom?.id, Number(id));
    assert.equal(await sessionModel(app, session), "faux-1");
    // A repeated spawn of the same task is the session it already started.
    const again = await spawnWorker(fmHome, id, "task-w", wt);
    assert.equal(again, session);
    await idle(app, session);

    const sent = await bridgeCall(fmHome, id, ["send", "--session", String(session), "--text", "show the task env", "--request-id", "brief-1"]);
    assert.equal(sent.code, 0, sent.err);
    await until(async () => (await toolSaid(app, session)).some((text) => text.includes("task=task-w")), "the worker's env command", LONG);
    await idle(app, session);
    const said = await toolSaid(app, session);
    assert.ok(said.some((text) => text.includes("task=task-w inbox=/fixture/task-w.inbox marker=none token=none")), said.join("\n"));
    const texts = await userTexts(app, session);
    const brief = texts.find((text) => text.includes("show the task env"))!;
    assert.ok(!brief.includes(FENCE), "a submit is not fenced like a linked-session message");
    assert.ok(texts[0]!.includes("Firstmate is starting a task worker"), "the first, fenced message is the neutral one");
    // The same request id again is the same submission.
    assert.equal((await bridgeCall(fmHome, id, ["send", "--session", String(session), "--text", "show the task env", "--request-id", "brief-1"])).code, 0);
    await settle();
    assert.equal(count(await userTexts(app, session), "show the task env"), 1);
    // The worker's prompt section, and its seatbelts.
    assert.ok(systemPrompts.some((prompt) => prompt.includes("fixture channel statement") && prompt.includes("Firstmate task worker for task-w")));
    await say(app, session, "ask a subagent");
    assert.ok((await toolSaid(app, session)).some((text) => text.includes("[pocket-worker]") && text.includes("subagent")));
    // Run events reached the busy record: the last run ended idle with its turn-ended notification.
    await until(() => busyRecord(fmHome, "task-w")?.state === "idle" && existsSync(join(fmHome, "state", "task-w.turn-ended")), "the idle record", LONG);
    const state = await bridgeCall(fmHome, id, ["state", "--session", String(session)]);
    assert.deepEqual(JSON.parse(state.out), { ok: true, state: "alive", busy: "idle" });
    const captured = await bridgeCall(fmHome, id, ["capture", "--session", String(session), "--lines", "20"]);
    assert.ok(captured.out.includes("show the task env"), captured.out);
    // A worker cannot drive the bridge: a request that claims main but comes from a process without main's Pi Pocket
    // identity (as every worker command is) is refused.
    const other = await bridgeCall(fmHome, session, ["state", "--session", String(session)]);
    assert.equal(other.code, 5, other.out + other.err);
    const writer = spawn("sleep", ["30"], { env: { PATH: process.env.PATH ?? "" }, stdio: "ignore" });
    try {
        const name = `forged-${String(writer.pid)}.json`;
        const dir = join(fmHome, "state", "pocket-bridge");
        writeFileSync(join(dir, "requests", `.${name}.tmp`), JSON.stringify({ v: 1, id: name.slice(0, -5), verb: "state", server: String(process.pid), conversation: String(id), pid: writer.pid, session }), { mode: 0o600 });
        renameSync(join(dir, "requests", `.${name}.tmp`), join(dir, "requests", name));
        await until(() => existsSync(join(dir, "results", name)), "the forged request's answer", LONG);
        assert.equal(readJsonFile(join(dir, "results", name))?.code, "untrusted");
        // Main's identity without the bridge secret, as a supervision-branch command or a worker that copied main's
        // marker has it, is refused too, even where the writer's environment cannot be read.
        const tokenless = await bridgeCall(fmHome, id, ["state", "--session", String(session)], "forged");
        assert.equal(tokenless.code, 3, tokenless.out + tokenless.err);
        assert.match(tokenless.err, /untrusted/);
    } finally {
        writer.kill();
    }
});

test("Pocket worker submits refuse a model off the owner's list and a spend hold, and a spawn refuses an unlisted model, a hold, and plan mode", { timeout: 90_000 }, async () => {
    const { app, id, fmHome } = await workerMain();
    const wt = worktree("worker-gates");
    const refused = await bridgeCall(fmHome, id, ["spawn", "--task", "task-unlisted", "--cwd", wt, "--model", "faux/faux-2"]);
    assert.equal(refused.code, 3);
    assert.match(refused.err, /model: the model faux\/faux-2 is not on the owner's subagent model list/);
    const session = await spawnWorker(fmHome, id, "task-g", wt);
    await idle(app, session);
    const before = (await userTexts(app, session)).length;

    await app.setSubagentModels(owner(app), ["faux/faux-2"]);
    const offList = await bridgeCall(fmHome, id, ["send", "--session", String(session), "--text", "steer one"]);
    assert.equal(offList.code, 3);
    assert.match(offList.err, /model: the worker's model faux\/faux-1 is not on the owner's subagent model list/);

    await app.setSubagentModels(owner(app), ["faux/faux-1"]);
    await recordCost(app, id, 2);
    await app.spend.setSessionBudget(owner(app), id, 1);
    const held = await bridgeCall(fmHome, id, ["send", "--session", String(session), "--text", "steer two"]);
    assert.equal(held.code, 3);
    assert.match(held.err, /held: Pi Pocket holds this work back/);
    const heldSpawn = await bridgeCall(fmHome, id, ["spawn", "--task", "task-held", "--cwd", wt]);
    assert.equal(heldSpawn.code, 3);
    assert.match(heldSpawn.err, /held: /);
    await settle();
    assert.equal((await userTexts(app, session)).length, before, "a refused submit sends nothing");

    // Main in plan mode: Pi Pocket refuses the start, and the drop-in reports that refusal.
    await app.spend.setSessionBudget(owner(app), id, null);
    const { PlanDoc } = await import(join(checkout, "src/server/docs.ts"));
    await app.harness.commit(async (tx: { doc: (doc: unknown, id: unknown) => Promise<{ on: boolean }> }) => {
        (await tx.doc(PlanDoc, id)).on = true;
        return undefined;
    }, context);
    const planned = await bridgeCall(fmHome, id, ["spawn", "--task", "task-plan", "--cwd", wt]);
    assert.equal(planned.code, 3, planned.out);
    assert.match(planned.err, /start: Pi Pocket refused to start the worker session: This session is in plan mode/);
    assert.equal(workerRecord(fmHome, "task-plan"), undefined, "a refused start records no worker");
});

test("doubled and missed run events change a worker's busy state once, and the list reconcile corrects a lost run.ended", { timeout: 90_000 }, async () => {
    const { app, id, fmHome } = await workerMain();
    const wt = worktree("worker-events");
    armBusy(fmHome, "task-e");
    const session = await spawnWorker(fmHome, id, "task-e", wt);
    // The neutral first turn can end before the registry records the worker, so its events may be missed; the
    // record was armed idle either way.
    await idle(app, session);
    await settle(1000);
    assert.equal(busyRecord(fmHome, "task-e")?.state, "idle");
    const seq = busyRecord(fmHome, "task-e")!.seq;
    const emit = (name: "run.started" | "run.ended", extra: object = {}) => app.events.emit(name, { conversationId: session, session, ...extra } as never);
    // A reload doubles the end of a run that is already over: nothing changes.
    emit("run.ended");
    emit("run.ended");
    await settle();
    assert.equal(busyRecord(fmHome, "task-e")!.seq, seq);
    // A run.started whose run.ended a hard close lost: the reconcile reads Pi Pocket's list and ends it.
    emit("run.started");
    await until(() => busyRecord(fmHome, "task-e")!.seq >= seq + 1, "the started run", LONG);
    await until(() => busyRecord(fmHome, "task-e")?.state === "idle" && busyRecord(fmHome, "task-e")?.event === "reconcile", "the reconciled idle", LONG);
    assert.equal(busyRecord(fmHome, "task-e")!.seq, seq + 2);
    // The run-failed signal, where Pi Pocket has it: a failed run reads dead until a later run starts.
    emit("run.started");
    emit("run.ended", { outcome: "failed", failure: "the provider refused" });
    await until(() => workerRecord(fmHome, "task-e")?.failed === "the provider refused", "the failed run", LONG);
    const dead = await bridgeCall(fmHome, id, ["state", "--session", String(session)]);
    assert.deepEqual(JSON.parse(dead.out), { ok: true, state: "dead", busy: "unknown", failed: "the provider refused" });
    emit("run.started");
    await until(() => workerRecord(fmHome, "task-e")?.failed === undefined, "the next run", LONG);
});

test("a Pocket worker interrupt aborts its run, a kill without linked-session stop retires it and refuses later sends, and a relaunched task's old session id reaches nothing", { timeout: 90_000 }, async () => {
    const { app, id, fmHome } = await workerMain();
    const wt = worktree("worker-kill");
    armBusy(fmHome, "task-k");
    const session = await spawnWorker(fmHome, id, "task-k", wt);
    await idle(app, session);
    assert.equal((await bridgeCall(fmHome, id, ["send", "--session", String(session), "--text", "work for a long time"])).code, 0);
    await until(() => workerRecord(fmHome, "task-k")?.busy === true, "the long run", LONG);
    const interrupted = await bridgeCall(fmHome, id, ["interrupt", "--session", String(session)]);
    assert.equal(interrupted.code, 0, interrupted.err);
    assert.equal(JSON.parse(interrupted.out).cancel, "confirmed");
    await until(() => workerRecord(fmHome, "task-k")?.busy === false, "the aborted run", 10_000);

    const killed = await bridgeCall(fmHome, id, ["kill", "--session", String(session)]);
    assert.equal(killed.code, 0, killed.err);
    assert.deepEqual(JSON.parse(killed.out), { ok: true, archived: false, retired: true });
    const after = await bridgeCall(fmHome, id, ["send", "--session", String(session), "--text", "are you there"]);
    assert.equal(after.code, 3);
    assert.match(after.err, /retired: the worker for task-k was torn down/);
    assert.deepEqual(JSON.parse((await bridgeCall(fmHome, id, ["state", "--session", String(session)])).out), { ok: true, state: "missing", busy: "unknown" });
    assert.equal(count(await userTexts(app, session), "are you there"), 0);

    // A relaunch's replacement session takes the task's record; the old session id never reaches the replacement.
    const replacement = await spawnWorker(fmHome, id, "task-k", wt);
    assert.notEqual(replacement, session);
    await idle(app, replacement);
    const stale = await bridgeCall(fmHome, id, ["send", "--session", String(session), "--text", "stale steer"]);
    assert.equal(stale.code, 3);
    assert.match(stale.err, /missing: no Pocket worker is recorded for session/);
    assert.deepEqual(JSON.parse((await bridgeCall(fmHome, id, ["kill", "--session", String(session)])).out), { ok: true, archived: false, absent: true });
    assert.equal(workerRecord(fmHome, "task-k")?.session, replacement);
    assert.equal(workerRecord(fmHome, "task-k")?.retired, undefined, "a stale kill leaves the replacement running");
    assert.equal(count(await userTexts(app, replacement), "stale steer"), 0);
});

test("a Pocket worker kill stops and archives it, reading the archive back, when Pi Pocket has linked-session stop and archive", { timeout: 90_000 }, async () => {
    const { app, id, fmHome } = await workerMain();
    const linked = app.linkedSessions as any;
    const archived = new Set<string>();
    const stops: string[] = [];
    linked.stop = async (_source: unknown, request: { to: string }) => {
        stops.push(request.to);
        return { busy: false };
    };
    linked.archive = async (_source: unknown, request: { to: string }) => {
        archived.add(request.to);
        return { archived: true };
    };
    const realList = linked.list.bind(linked);
    linked.list = async (source: unknown) => (await realList(source)).map((row: { address: string }) => (archived.has(row.address) ? { ...row, archived: true } : row));
    assert.equal(JSON.parse((await bridgeCall(fmHome, id, ["status"])).out).stop, true);
    const session = await spawnWorker(fmHome, id, "task-a", worktree("worker-archive"));
    await idle(app, session);
    const killed = await bridgeCall(fmHome, id, ["kill", "--session", String(session)]);
    assert.equal(killed.code, 0, killed.err);
    assert.deepEqual(JSON.parse(killed.out), { ok: true, archived: true });
    assert.equal(stops.length, 1);
    assert.equal(workerRecord(fmHome, "task-a")?.archived, true);
    assert.equal((await bridgeCall(fmHome, id, ["send", "--session", String(session), "--text", "x"])).code, 3);
});

test("after a Pi Pocket restart cut a worker's run, it gets one short nudge, recorded so it is sent once", { timeout: 120_000 }, async () => {
    const fmHome = await home();
    const dataDir = mkdtempSync(join(root, "worker-restart-"));
    const wt = worktree("worker-restart");
    const child = spawn(process.execPath, [process.argv[1]!, "--worker-child", dataDir, fmHome, wt], {
        env: { ...process.env, TMPDIR: mkdtempSync(join(tmpdir(), "fm-child-")) },
        stdio: ["ignore", "pipe", "inherit"],
    });
    const [id, session] = await new Promise<[number, number]>((resolve, reject) => {
        let out = "";
        child.stdout!.on("data", (chunk: Buffer) => {
            out += chunk.toString();
            const started = /^worker (\S+) (\S+)$/m.exec(out);
            if (started) resolve([Number(started[1]), Number(started[2])]);
        });
        child.on("close", (code) => reject(new Error(`the child server ended first (${String(code)}): ${out}`)));
    });
    child.kill("SIGKILL");
    await new Promise((resolve) => child.once("close", resolve));
    assert.equal(workerRecord(fmHome, "task-cut")?.busy, true, "the record says the cut run was going");

    const app = await open(dataDir, false);
    apps.push(app);
    await app.setSubagentModels(owner(app), ["faux/faux-1"]);
    await bridgeUp(fmHome, id);
    await until(async () => count(await userTexts(app, session), NUDGE) === 1, "the restart nudge", LONG);
    await until(() => workerRecord(fmHome, "task-cut")?.nudgedFor !== undefined, "the recorded nudge", LONG);
    await idle(app, session);
    // Later reconciles and a reload's doubled run.ended send no second nudge.
    app.events.emit("run.ended", { conversationId: session, session } as never);
    await settle(2500);
    assert.equal(count(await userTexts(app, session), NUDGE), 1);
    assert.equal(workerRecord(fmHome, "task-cut")?.busy, false);
    assert.equal(busyRecord(fmHome, "task-cut")?.state, "idle");
});
