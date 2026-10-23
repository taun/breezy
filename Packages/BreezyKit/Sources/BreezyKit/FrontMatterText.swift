import Foundation

/// The raw YAML lines of a front matter block, edited line by line so everything the app does not touch
/// (unknown keys, comments, order, spacing) is written back exactly as it was.
public struct FrontMatterText: Equatable, Sendable {
    public var lines: [String]

    public init(lines: [String]) { self.lines = lines }

    /// The key if `line` starts a top-level `key:` entry.
    static func topLevelKey(_ line: String) -> String? {
        guard let first = line.first, first.isLetter || first == "_" else { return nil }
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = line[..<colon]
        return key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) ? String(key) : nil
    }

    /// Lines belonging to `key`: its line, and the indented / list lines after it, excluding trailing blank lines.
    func range(of key: String) -> Range<Int>? {
        guard let start = lines.firstIndex(where: { Self.topLevelKey($0) == key }) else { return nil }
        var end = start + 1
        while end < lines.count {
            let l = lines[end]
            if Self.topLevelKey(l) != nil || l.hasPrefix("#") { break }
            end += 1
        }
        while end > start + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
        return start..<end
    }

    public func contains(_ key: String) -> Bool { range(of: key) != nil }

    /// Replaces `key`'s block with `valueLines` (the first should be `key: ...`), or appends it.
    public mutating func set(_ key: String, to valueLines: [String]) {
        if let r = range(of: key) {
            lines.replaceSubrange(r, with: valueLines)
        } else {
            var at = lines.count
            while at > 0, lines[at - 1].trimmingCharacters(in: .whitespaces).isEmpty { at -= 1 }
            lines.insert(contentsOf: valueLines, at: at)
        }
    }

    public mutating func remove(_ key: String) {
        if let r = range(of: key) { lines.removeSubrange(r) }
    }
}

/// YAML formatting helpers in the style the site's files use.
public enum YAMLFormat {
    private static let reserved: Set<String> = ["true", "false", "yes", "no", "null", "on", "off", "~"]

    /// Plain when safe; otherwise double-quoted with escapes.
    public static func scalar(_ s: String) -> String {
        let plain = !s.isEmpty && s.range(of: #"^[A-Za-z][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil
            && !reserved.contains(s.lowercased())
        if plain { return s }
        return quoted(s)
    }

    /// URLs and paths stay unquoted (as in the site's files) when YAML reads them back unchanged.
    public static func scalarOrURL(_ s: String) -> String {
        let safe = s.range(of: #"^[A-Za-z0-9/][A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]*$"#, options: .regularExpression) != nil
            && !s.contains(": ") && !s.contains(" #") && !reserved.contains(s.lowercased())
        return safe ? s : quoted(s)
    }

        public static func quoted(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    public static func flowList(_ items: [String]) -> String { "[" + items.joined(separator: ", ") + "]" }

    /// `links: [creo, { to: ken-spencer, rel: worked-at }]`; plain slug when the relation is the default.
    public static func linksLine(_ links: [NodeLink]) -> String {
        let items = links.map { l in
            l.rel == Relations.defaultRel ? scalar(l.to) : "{ to: \(scalar(l.to)), rel: \(scalar(l.rel)) }"
        }
        return "links: " + flowList(items)
    }
}
