import Foundation

/// The editing state of one node, kept in the site repo at `.breezy/nodes/<slug>.json` (docs/content-model.md in the
/// site repo) so it follows the node from device to device: the tab, mode and cursor it was left with, and its
/// unpublished body draft. Breezy is the only writer, but several app versions may be: keys this version does not
/// know are kept as they were, and a higher `version` is never lowered.
public struct EditorState: Equatable, Sendable {
    public enum Tab: String, Sendable, CaseIterable { case title, date, links, media, body }
    public enum Mode: String, Sendable { case edit, draft, preview }

    /// A rewrite of the body, kept beside it until used or discarded.
    public struct Draft: Equatable, Sendable {
        public var text: String
        /// Git blob sha of the body (`NodeFile.body`) when the draft was started or last marked as seen: tells
        /// whether the original changed since.
        public var base: String?
        var extra: [String: JSONValue] = [:]

        public init(text: String, base: String?) {
            self.text = text
            self.base = base
        }
    }

    public var tab: Tab?
    public var mode: Mode?
    /// Cursor or selection in the body, as UTF-16 offsets.
    public var selection: [Int]?
    public var draft: Draft?

    var version = 1
    var extra: [String: JSONValue] = [:]
    var editorExtra: [String: JSONValue] = [:]

    public init(tab: Tab? = nil, mode: Mode? = nil, selection: [Int]? = nil, draft: Draft? = nil) {
        self.tab = tab
        self.mode = mode
        self.selection = selection
        self.draft = draft
    }

    // MARK: File format

    /// Parses a state file; nil if it is not one (it is then treated as absent and replaced at the next write).
    public init?(json: String) {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)), case var .object(top) = value,
              case let .number(v)? = top.removeValue(forKey: "version"), let n = Int(exactly: v) else { return nil }
        version = n
        if case var .object(editor)? = top.removeValue(forKey: "editor") {
            // A tab or mode this version does not know stays in `editorExtra`, written back as it was.
            if case let .string(s)? = editor["tab"], let t = Tab(rawValue: s) { tab = t; editor["tab"] = nil }
            if case let .string(s)? = editor["mode"], let m = Mode(rawValue: s) { mode = m; editor["mode"] = nil }
            if case let .array(a)? = editor.removeValue(forKey: "selection") {
                let n = a.compactMap { if case let .number(x) = $0 { Int(exactly: x) } else { nil } }
                if n.count == 2, n[0] >= 0, n[1] >= n[0] { selection = n }
            }
            editorExtra = editor
        }
        if case var .object(d)? = top.removeValue(forKey: "draft"), case let .string(text)? = d.removeValue(forKey: "text") {
            var draft = Draft(text: text, base: nil)
            if case let .string(b)? = d.removeValue(forKey: "base") { draft.base = b }
            draft.extra = d
            self.draft = draft
        }
        extra = top
    }

    /// The file's text. The same state always gives the same bytes (sorted keys), so the same blob sha.
    public func rendered() -> String {
        var editor = editorExtra
        if let tab { editor["tab"] = .string(tab.rawValue) }
        if let mode { editor["mode"] = .string(mode.rawValue) }
        if let selection { editor["selection"] = .array(selection.map { .number(Double($0)) }) }
        var top = extra
        top["version"] = .number(Double(max(version, 1)))
        if !editor.isEmpty { top["editor"] = .object(editor) }
        if let draft {
            var d = draft.extra
            d["text"] = .string(draft.text)
            if let base = draft.base { d["base"] = .string(base) }
            top["draft"] = .object(d)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(JSONValue.object(top))) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// Nothing worth a file.
    public var isEmpty: Bool { self == EditorState() }

    // MARK: Rules

    /// The blob sha a draft's `base` records for a body.
    public static func bodySHA(_ body: String) -> String { GitBlob.sha(of: body) }

    /// Whether the draft differs from `other`'s: the only part of the state that counts as a change by itself
    /// (tab, mode and cursor ride along with commits that touch the node). nil means no state.
    public func draftDiffers(from other: EditorState?) -> Bool { draft != other?.draft }

    /// The state for a node whose content just changed on GitHub without a newer state coming with it (issue #15):
    /// the body, in Edit mode, with the cursor at the end; the Title tab when there is no body. A draft is kept.
    public static func afterRemoteChange(body: String, keeping old: EditorState?) -> EditorState {
        var s = old ?? EditorState()
        s.mode = .edit
        if body.isEmpty {
            s.tab = .title
            s.selection = nil
        } else {
            s.tab = .body
            s.selection = [body.utf16.count, body.utf16.count]
        }
        return s
    }

    public enum Merge: Equatable, Sendable {
        case merged(EditorState)
        /// The draft changed differently on both sides.
        case draftConflict
    }

    /// Combines a local state with GitHub's when GitHub's changed since `base` (nil: no file). The draft is merged
    /// three ways; the tab, mode and cursor stay local, since the node is being worked on here. Keys this version
    /// does not know come from GitHub's where both have them (a newer version may have written them there).
    public static func merge(base: EditorState?, local: EditorState, remote: EditorState?) -> Merge {
        var out = local
        if local.draft == base?.draft {
            out.draft = remote?.draft
        } else if remote?.draft != base?.draft, remote?.draft != local.draft {
            return .draftConflict
        }
        if let remote {
            out.extra.merge(remote.extra) { _, theirs in theirs }
            // A tab or mode not known here stays only if this device has not chosen one of its own.
            let chosen = Set([local.tab == nil ? nil : "tab", local.mode == nil ? nil : "mode"].compactMap { $0 })
            out.editorExtra.merge(remote.editorExtra.filter { !chosen.contains($0.key) }) { _, theirs in theirs }
        }
        out.version = max(local.version, remote?.version ?? 1)
        return .merged(out)
    }
}

/// Any JSON value, so state keys this version does not understand are written back unchanged.
enum JSONValue: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(b): try c.encode(b)
        case let .number(n):
            if n == n.rounded(), abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case let .string(s): try c.encode(s)
        case let .array(a): try c.encode(a)
        case let .object(o): try c.encode(o)
        }
    }
}
