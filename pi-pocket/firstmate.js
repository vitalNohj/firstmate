// Firstmate's browser module: apply the server's Pocket Calm setting to Firstmate's inputs.
// Calm on is one folded line. Calm off is the message. The card's Show, Fold, and Hide control stays available.
// The model still reads each input in full. On an older app there is no presentation to set.
// The app loads this file and calls its default export with `pocket`.

/** The version of `pocket` this module was written for. An older app does not load it. */
export const pocketApi = 1;

const KINDS = ["x.firstmate.operational", "x.firstmate.session-start"];

export default function setup(pocket) {
    if (typeof pocket.entryPresentation !== "function") return;

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

    apply(true);
    let changed = false;
    pocket.on("calm", (data) => {
        if (typeof data?.calm !== "boolean") return;
        changed = true;
        apply(data.calm);
    });
    pocket.api("calm").then((body) => {
        // A later server event can arrive before the initial response.
        if (!changed && typeof body?.calm === "boolean") apply(body.calm);
    }).catch(() => {});
}
