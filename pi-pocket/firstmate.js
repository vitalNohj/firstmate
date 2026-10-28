// Firstmate's browser module: this browser follows the home's config/calm for Firstmate's own inputs.
// Calm on is one folded line. Calm off is the message. The card's Show, Fold, and Hide control stays available.
// The model still reads each input in full. On an older app there is no presentation to set.
// The app loads this file and calls its default export with `pocket`.

/** The version of `pocket` this module was written for. An older app does not load it. */
export const pocketApi = 1;

const KINDS = ["x.firstmate.operational", "x.firstmate.session-start"];

/** A missing conversation matches only a missing one. A shown conversation matches by its id string. */
function sameConversation(left, right) {
    if (left == null || right == null) return left == null && right == null;
    return String(left) === String(right);
}

export default function setup(pocket) {
    if (typeof pocket.entryPresentation !== "function") return;

    let conversation = null;
    // A preference read applies only while this generation and conversation are still the ones it captured.
    // Switching conversations, a toggle for the shown conversation, and a toggle elsewhere advance it.
    let generation = 0;

    const apply = (calm) => {
        const mode = calm ? "folded" : "open";
        for (const kind of KINDS) {
            try {
                pocket.entryPresentation(kind, mode);
            } catch {
                // One kind this app does not present. The other still follows the file.
            }
        }
    };

    const refresh = () => {
        const requested = ++generation;
        const requestedConversation = conversation;
        const path = requestedConversation == null ? "calm" : `calm?conversation=${requestedConversation}`;
        pocket
            .api(path)
            .then((body) => {
                if (requested !== generation || !sameConversation(requestedConversation, conversation)) return;
                apply(body?.calm === true);
            })
            .catch(() => {});
    };

    pocket.on("calm", (data) => {
        if (data == null || typeof data.calm !== "boolean") return;
        // Another conversation may share this home's config/calm. Re-read the shown home
        // instead of copying that event, and instead of leaving this tab on the old mode.
        if (conversation != null && data.conversation != null && !sameConversation(data.conversation, conversation)) {
            refresh();
            return;
        }
        generation += 1;
        apply(data.calm);
    });

    if (typeof pocket.onConversation === "function") {
        pocket.onConversation((id) => {
            conversation = id;
            refresh();
        });
    } else {
        refresh();
    }
}
