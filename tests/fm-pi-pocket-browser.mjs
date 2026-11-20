// The Pi Pocket browser module (pi-pocket/firstmate.js), driven by
// tests/fm-pi-pocket-dropin.test.sh. A delayed read must not undo a newer server event.
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
    const modes = {};
    const reads = [];
    const listeners = [];
    let resolve;
    const response = new Promise((done) => { resolve = done; });
    setup({
        entryPresentation(kind, mode) { modes[kind] = mode; },
        api(path) {
            reads.push(path);
            return response;
        },
        on(name, listener) {
            if (name === "calm") listeners.push(listener);
        },
    });
    return {
        modes,
        reads,
        async receive(calm) {
            resolve({ calm });
            await response;
        },
        calm(calm) {
            for (const listener of listeners) listener({ calm });
        },
    };
}

test("Firstmate inputs start folded and a browser loads the shared Pocket setting", async () => {
    const ui = harness();
    assert.deepEqual(ui.modes, FOLDED);
    assert.deepEqual(ui.reads, ["calm"]);

    await ui.receive(false);
    assert.deepEqual(ui.modes, OPEN);
    ui.calm(true);
    assert.deepEqual(ui.modes, FOLDED);
    assert.deepEqual(ui.reads, ["calm"], "a server-wide event needs no conversation lookup");
});

test("a calm toggle is kept when the earlier settings response resolves last", async () => {
    const ui = harness();
    ui.calm(false);
    assert.deepEqual(ui.modes, OPEN);

    await ui.receive(true);
    assert.deepEqual(ui.modes, OPEN);
});
