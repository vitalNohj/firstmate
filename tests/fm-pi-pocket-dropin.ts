// The Firstmate Pi Pocket drop-in (pi-pocket/firstmate.ts) inside a real Pi Pocket app, driven by
// tests/fm-pi-pocket-dropin.test.sh. That wrapper copies this file and the drop-in into a directory whose
// node_modules links to the Pi Pocket checkout's, and passes:
//   FM_PI_POCKET_CHECKOUT  the Pi Pocket checkout whose test/helpers.ts opens apps on temporary data directories
//   FM_PI_POCKET_BIN       a copy of Firstmate's bin/ that every fixture home starts from
//   FM_PI_POCKET_DROPIN    the drop-in file under test
// Run with `--child <dataDir> <home>`, the file is instead the server that experiment (b) kills mid-delivery.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import {
    chmodSync,
    copyFileSync,
    cpSync,
    existsSync,
    mkdirSync,
    mkdtempSync,
    readFileSync,
    renameSync,
    writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { fauxAssistantMessage, fauxText, fauxToolCall } from "@earendil-works/pi-ai/providers/faux";

const checkout = process.env.FM_PI_POCKET_CHECKOUT!;
const bin = process.env.FM_PI_POCKET_BIN!;
const dropIn = process.env.FM_PI_POCKET_DROPIN!;
const helpers = await import(join(checkout, "test", "helpers.ts"));
const { context, lastText, newSession, openApp, owner, recordCost, root, say, scriptedModel, until, work } = helpers;

type App = Awaited<ReturnType<typeof openApp>>;

const WAKE = "FIRSTMATE WATCHER WAKE: ";
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

const route = (request: unknown) => {
    const { role, text } = lastText(request);
    if (role === "toolResult") return fauxAssistantMessage([fauxText("noted the tool result")]);
    if (text.endsWith("start firstmate")) return call("bash", { command: "bin/fm-session-start.sh" });
    if (text.endsWith("go elsewhere")) return call("bash", { command: "cd /tmp && ls" });
    if (text.endsWith("background the watcher")) return call("bash", { command: "bin/fm-watch-arm.sh --restart &" });
    if (text.endsWith("schedule something")) return call("schedule", { action: "list" });
    if (text.endsWith("show the marker")) {
        return call("bash", { command: `printf 'marker=%s server=%s' "\${FM_PI_POCKET_CONVERSATION:-none}" "\${FM_PI_POCKET_SERVER_PID:-none}"` });
    }
    if (text.endsWith("repair the watcher")) return call("fm_watch_arm_pocket", {});

    return fauxAssistantMessage([fauxText("noted")]);
};

async function open(dataDir: string, enable: boolean): Promise<App> {
    mkdirSync(join(dataDir, "extensions"), { recursive: true });
    copyFileSync(dropIn, join(dataDir, "extensions", "firstmate.ts"));
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
// Experiment (b)'s server: bind, hold one wake back, report, and wait to be killed.

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

    fire(fmHome, "check: second wake");
    await until(async () => count(await userTexts(app, id), `${WAKE}check: second wake`) === 1, "the second wake", LONG);
    assert.equal(count(await userTexts(app, id), WAKE), 2);

    // The repair tool leaves a live watcher alone.
    await say(app, id, "repair the watcher");
    assert.ok((await toolSaid(app, id)).some((text) => text.startsWith("watcher: unchanged")));
    assert.equal(lines(join(fmHome, "stub", "arms.log")).length, 3);
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
    await say(app, id, "schedule something");
    const said = await toolSaid(app, id);
    assert.ok(said.some((text) => text.includes("Tool call blocked: [persistent-cd]")), said.join("\n"));
    assert.ok(said.some((text) => text.includes("Tool call blocked: [watcher-background]")), said.join("\n"));
    assert.ok(said.some((text) => text.includes("Tool call blocked: [subagent-dispatch]") && text.includes("bin/fm-spawn.sh")), said.join("\n"));

    await say(app, elsewhere, "go elsewhere");
    await say(app, elsewhere, "schedule something");
    const free = await toolSaid(app, elsewhere);
    assert.ok(free.every((text) => !text.includes("Tool call blocked")), free.join("\n"));
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

test("the turn-end guard continues a turn that would end blind exactly once", async () => {
    const { app, id, fmHome } = await started();

    writeFileSync(join(fmHome, "stub", "guard-code"), "2");
    await say(app, id, "hello");
    await until(async () => (await userTexts(app, id)).some((text) => text.includes("STUB GUARD")), "the guard continuation", LONG);
    await (await app.harness.conversation(id, context))!.waitForIdle(context);
    const texts = await userTexts(app, id);
    assert.equal(count(texts, "TURN WOULD END BLIND"), 1, texts.join("\n---\n"));
    assert.match(texts.find((text) => text.includes("STUB GUARD"))!, /^\u2063FIRSTMATE_OP: v1 turn-end-guard: /);
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
    assert.equal(lines(join(fmHome, "stub", "starts.log")).length, 0);

    const app = await open(dataDir, false);
    apps.push(app);
    await until(() => lines(join(fmHome, "stub", "starts.log")).length === 1, "the restart's session start", LONG);
    await app.spend.setSessionBudget(owner(app), id, null);
    await until(async () => count(await userTexts(app, id), `${WAKE}signal: crash wake`) === 1, "the redelivered wake", LONG);
    const texts = await userTexts(app, id);
    assert.equal(count(texts, "STUB DIGEST startup"), 1, "one digest");
    assert.equal(count(texts, WAKE), 1, "one wake");
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
