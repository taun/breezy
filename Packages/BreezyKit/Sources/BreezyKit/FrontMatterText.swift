import Foundation
import Yams

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

    /// Sets or (with nil) removes one scalar child of a top-level mapping such as `header`, touching only that child's
    /// line: its siblings, comments and order stay as written. A mapping left empty is removed. A flow-style mapping
    /// (`header: {image: x}`) is first rewritten as a block with its entries in order, each value as written; one with
    /// a value that is not a plain value (a list or a mapping), or a parent that is not a mapping, is left alone and throws.
    public mutating func setChild(_ parent: String, _ key: String, to value: String?) throws {
        guard var r = range(of: parent) else {
            if let value { set(parent, to: ["\(parent):", "  \(key): \(YAMLFormat.scalarOrURL(value))"]) }
            return
        }
        let head = lines[r.lowerBound]
        let rest = head.drop { $0 != ":" }.dropFirst().trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty, !rest.hasPrefix("#") {
            lines.replaceSubrange(r, with: ["\(parent):"] + (try Self.blockLines(flow: rest, parent: parent)))
            r = range(of: parent) ?? r.lowerBound..<(r.lowerBound + 1)
        }
        let children = r.dropFirst()
        // From the first entry: a blank line or a comment inside the block may be indented differently.
        let first = children.first { let t = lines[$0].trimmingCharacters(in: .whitespaces); return !t.isEmpty && !t.hasPrefix("#") }
        let indent = first.map { String(lines[$0].prefix { $0 == " " || $0 == "\t" }) } ?? "  "
        let existing = children.first { lines[$0].dropFirst(indent.count).hasPrefix("\(key):") && lines[$0].hasPrefix(indent) }
        switch (existing, value) {
        case let (i?, v?): lines[i] = "\(indent)\(key): \(YAMLFormat.scalarOrURL(v))"
        case let (i?, nil): lines.remove(at: i)
        case (nil, let v?):
            let at = (children.last { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty } ?? r.lowerBound) + 1
            lines.insert("\(indent)\(key): \(YAMLFormat.scalarOrURL(v))", at: at)
        case (nil, nil): break
        }
        if let again = range(of: parent), again.count == 1, lines[again.lowerBound].trimmingCharacters(in: .whitespaces) == "\(parent):" {
            lines.remove(at: again.lowerBound)
        }
    }

    /// The entries of a one-line value (`{image: x, teaser: y}`, or null) as block lines, in order and as written.
    private static func blockLines(flow text: String, parent: String) throws -> [String] {
        let unsupported = NodeFileError.invalidYAML("“\(parent)” is written on one line in a form Breezy cannot change. Put each of its keys on a line of its own.")
        guard let node = try? Yams.compose(yaml: text) else { throw unsupported }
        if case let .scalar(s) = node, s.style == .plain, ["", "~", "null"].contains(s.string.lowercased()) { return [] }
        guard case let .mapping(mapping) = node else { throw unsupported }
        return try mapping.map { k, v in
            guard let name = k.scalar?.string, let scalar = v.scalar else { throw unsupported }
            return "  \(name): \(scalar.style == .plain ? scalar.string : YAMLFormat.quoted(scalar.string))"
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
