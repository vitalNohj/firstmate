// Firstmate's browser module: this browser follows the home's config/calm for Firstmate's own inputs.
// Calm on is one folded line. Calm off is the message. The card's Show, Fold, and Hide control stays available.
// The model still reads each input in full. On an older app there is no presentation to set.
// The app loads this file and calls its default export with `pocket`.

/** The version of `pocket` this module was written for. An older app does not load it. */
export const pocketApi = 1;

const KINDS = ["x.firstmate.operational", "x.firstmate.session-start"];

export default function setup(pocket) {
    if (typeof pocket.entryPresentation !== "function") return;

    let conversation = null;

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
        const path = conversation == null ? "calm" : `calm?conversation=${conversation}`;
        pocket
            .api(path)
            .then((body) => apply(body?.calm === true))
            .catch(() => {});
    };

    pocket.on("calm", (data) => {
        if (data == null || typeof data.calm !== "boolean") return;
        if (conversation != null && data.conversation != null && String(data.conversation) !== String(conversation)) return;
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
