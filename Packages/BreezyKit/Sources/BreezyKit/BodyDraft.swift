import Foundation

/// A rewrite of a node's body, kept beside the original until it is used or discarded (the editor's Draft view).
/// The text itself lives in `@AppStorage` under `key`, so it survives relaunch.
public enum BodyDraft {
    /// Per branch and node, so a draft of one node never shows up in another or on another branch.
    public static func key(branch: String, slug: String) -> String {
        "draft|\(branch)|\(slug)"
    }

    /// A draft exists once it has any text; empty means none (cleared, discarded or used).
    public static func isStarted(_ text: String) -> Bool { !text.isEmpty }

    /// The body to commit when the draft is used: the draft as written.
    public static func bodyWhenUsed(_ text: String) -> String { text }
}
