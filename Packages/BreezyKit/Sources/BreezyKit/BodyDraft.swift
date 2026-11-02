import Foundation

/// A rewrite of a node's body, kept beside the original until it is used or discarded (the editor's Draft view).
/// The text lives in the node's editor state (`EditorState.draft`), synced with the node.
public enum BodyDraft {
    /// Where builds before editor state files kept a draft in settings, per branch and node. Only read to move
    /// those drafts into the editor state (`legacyDrafts`).
    public static func key(branch: String, slug: String) -> String {
        "draft|\(branch)|\(slug)"
    }

    /// The drafts older builds left in settings for `branch`, by slug (empty ones skipped).
    public static func legacyDrafts(in settings: [String: Any], branch: String) -> [String: String] {
        let prefix = "draft|\(branch)|"
        var out: [String: String] = [:]
        for (key, value) in settings where key.hasPrefix(prefix) {
            if let text = value as? String, isStarted(text) { out[String(key.dropFirst(prefix.count))] = text }
        }
        return out
    }

    /// A draft exists once it has any text; empty means none (cleared, discarded or used).
    public static func isStarted(_ text: String) -> Bool { !text.isEmpty }

    /// The body to commit when the draft is used: the draft as written.
    public static func bodyWhenUsed(_ text: String) -> String { text }
}
