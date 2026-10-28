// The Pi Pocket browser module (pi-pocket/firstmate.js), driven by
// tests/fm-pi-pocket-dropin.test.sh. A preference read applies only while the
// conversation and refresh generation it captured are still current.
import assert from "node:assert/strict";
import { test } from "node:test";

const { default: setup } = await import(new URL("../pi-pocket/firstmate.js", import.meta.url).href);

const OPEN = {
    "x.firstmate.operational": "open",
    "x.firstmate.session-start": "open",
};
const FOLDED = {
    "x.firstmate.operational": "folded",
    "x.firstmate.session-start": "folded",
};

function harness() {
    const presented = [];
    const reads = [];
    const calmListeners = [];
    let conversationHandler = null;
    const pocket = {
        entryPresentation(kind, mode) {
            presented.push({ kind, mode });
        },
        api(path) {
            let resolve;
            let reject;
            const promise = new Promise((res, rej) => {
                resolve = res;
                reject = rej;
            });
            reads.push({ path, promise, resolve, reject });
            return promise;
        },
        on(name, listener) {
            if (name === "calm") calmListeners.push(listener);
        },
        onConversation(handler) {
            conversationHandler = handler;
        },
    };
    setup(pocket);
    return {
        presented,
        reads,
        show(id) {
            conversationHandler(id);
        },
        calm(data) {
            for (const listener of calmListeners) listener(data);
        },
    };
}

function modes(presented) {
    const found = {};
    for (const entry of presented) found[entry.kind] = entry.mode;
    return found;
}

test("an older calm read that resolves last does not change the active conversation", async () => {
    const ui = harness();
    ui.show("conv-on");
    ui.show("conv-off");
    assert.equal(ui.reads[0].path, "calm?conversation=conv-on");
    assert.equal(ui.reads[1].path, "calm?conversation=conv-off");

    ui.reads[1].resolve({ calm: false });
    await ui.reads[1].promise;
    assert.deepEqual(modes(ui.presented), OPEN);

    const applied = ui.presented.length;
    ui.reads[0].resolve({ calm: true });
    await ui.reads[0].promise;
    assert.equal(ui.presented.length, applied);
    assert.deepEqual(modes(ui.presented), OPEN);
});

test("an older calm read that resolves before the active one does not present it", async () => {
    const ui = harness();
    ui.show("conv-on");
    ui.show("conv-off");

    ui.reads[0].resolve({ calm: true });
    await ui.reads[0].promise;
    assert.deepEqual(modes(ui.presented), {});

    ui.reads[1].resolve({ calm: false });
    await ui.reads[1].promise;
    assert.deepEqual(modes(ui.presented), OPEN);
});

test("a calm toggle is kept when the earlier settings response resolves last", async () => {
    const ui = harness();
    ui.show("conv");
    assert.equal(ui.reads.length, 1);
    assert.equal(ui.reads[0].path, "calm?conversation=conv");

    ui.calm({ calm: true, conversation: "conv" });
    assert.deepEqual(modes(ui.presented), FOLDED);

    const applied = ui.presented.length;
    ui.reads[0].resolve({ calm: false });
    await ui.reads[0].promise;
    assert.equal(ui.presented.length, applied);
    assert.deepEqual(modes(ui.presented), FOLDED);
});

test("a calm event for another conversation rereads the shown conversation", async () => {
    const ui = harness();
    ui.show("conv-b");
    assert.equal(ui.reads[0].path, "calm?conversation=conv-b");

    ui.calm({ calm: true, conversation: "conv-a" });
    assert.equal(ui.reads.length, 2);
    assert.equal(ui.reads[1].path, "calm?conversation=conv-b");
    assert.deepEqual(modes(ui.presented), {});

    ui.reads[1].resolve({ calm: true });
    await ui.reads[1].promise;
    assert.deepEqual(modes(ui.presented), FOLDED);

    const applied = ui.presented.length;
    ui.reads[0].resolve({ calm: false });
    await ui.reads[0].promise;
    assert.equal(ui.presented.length, applied);
    assert.deepEqual(modes(ui.presented), FOLDED);

    const otherHome = harness();
    otherHome.show("conv-b");
    otherHome.calm({ calm: true, conversation: "conv-a" });
    otherHome.reads[1].resolve({ calm: false });
    await otherHome.reads[1].promise;
    assert.deepEqual(modes(otherHome.presented), OPEN);
});
