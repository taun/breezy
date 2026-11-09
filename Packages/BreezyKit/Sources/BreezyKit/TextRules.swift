import Foundation

/// Characters node content may contain. Invisible control characters (usually pasted from Word, a PDF or a terminal)
/// are never wanted: YAML cannot hold them unescaped and XML 1.0 forbids them, so one of them can fail the site build
/// or make feed readers reject the whole RSS feed. One-line fields (title, type, summary, tags, relations, media
/// addresses) also take no line breaks or tabs. The summary may have line breaks: the site shows them as spaces.
public enum TextRules {
    public enum Kind: Sendable {
        /// One line: title, type, tags, relation, media addresses.
        case line
        /// Free text with line breaks and tabs: the summary, the body, drafts.
        case text
        /// A whole node file (the merge editor): like text, but every line or page separator other than `\n` and
        /// `\r` becomes a space, since YAML readers disagree on them and a break inside front matter splits a value.
        case file
    }

    /// The text with every character `kind` cannot hold replaced or removed; nil when the text is fine as it is.
    /// Line breaks and tabs in a one-line field become spaces. The control characters that separate lines or pages
    /// (vertical tab, Word's soft return; form feed, a PDF's page break; NEL) become a line break, or a space in a
    /// line, so the words on each side stay apart. Other control characters are removed. The message, for the person
    /// typing, says what happened to the control characters; a plain break that became a space is in plain sight.
    public static func check(_ s: String, _ kind: Kind, field: String) -> (text: String, message: String?)? {
        guard s.unicodeScalars.contains(where: { !isAllowed($0, kind) }) else { return nil }
        let separator: Unicode.Scalar = kind == .text ? "\n" : " "
        var out = String.UnicodeScalarView()
        var replaced: [Unicode.Scalar] = []
        var removed: [Unicode.Scalar] = []
        var previous: Unicode.Scalar?
        for c in s.unicodeScalars {
            defer { previous = c }
            if isAllowed(c, kind) {
                out.append(c)
            } else if isBreakOrTab(c) && kind == .line {
                if !(c == "\n" && previous == "\r") { out.append(" ") } // CRLF is one break
            } else if separatesLines(c) || isBreakOrTab(c) {
                out.append(separator)
                if !replaced.contains(c) { replaced.append(c) }
            } else if !removed.contains(c) {
                removed.append(c)
            }
        }
        var parts: [String] = []
        if !replaced.isEmpty {
            parts.append("Replaced \(list(replaced)) with \(separator == " " ? "a space" : "a line break").")
        }
        if !removed.isEmpty { parts.append("Removed \(list(removed)).") }
        let message = parts.isEmpty ? nil : parts.joined(separator: " ") + " \(field) can't contain invisible control characters."
        return (String(out), message)
    }

    /// `s` as `kind` can hold it: what the setters store, whatever the caller passed.
    public static func cleaned(_ s: String, _ kind: Kind) -> String { check(s, kind, field: "")?.text ?? s }

    /// Characters the site cannot publish in text already in a file (written elsewhere), for the node's issue banner;
    /// nil when there are none. Line breaks and tabs are not reported: YAML and the feed handle them.
    public static func problem(in s: String, field: String) -> String? {
        var bad: [Unicode.Scalar] = []
        for c in s.unicodeScalars where !isAllowed(c, .text) && !bad.contains(c) { bad.append(c) }
        guard !bad.isEmpty else { return nil }
        return "\(field) contains \(list(bad)), which the RSS feed leaves out. Editing the field removes it."
    }

    public static func isAllowed(_ c: Unicode.Scalar, _ kind: Kind) -> Bool {
        if isBreakOrTab(c) {
            switch kind {
            case .line: return false
            case .text: return true
            case .file: return c.value < 0x2028 // tab, \n, \r
            }
        }
        switch c.value {
        case 0x00...0x1F, 0x7F...0x9F: return false
        default: return !c.properties.isNoncharacterCodePoint
        }
    }

    private static func isBreakOrTab(_ c: Unicode.Scalar) -> Bool { [0x09, 0x0A, 0x0D, 0x2028, 0x2029].contains(c.value) }

    private static func separatesLines(_ c: Unicode.Scalar) -> Bool { [0x0B, 0x0C, 0x85].contains(c.value) }

    /// A refused control character or noncharacter, as the notes name it.
    static func describe(_ c: Unicode.Scalar) -> String {
        let code = String(format: "U+%04X", c.value)
        switch c.value {
        case 0x0B: return "a vertical tab (\(code))"
        case 0x0C: return "a form feed (\(code))"
        case 0x85: return "a next-line character (\(code))"
        case 0x2028: return "a line separator (\(code))"
        case 0x2029: return "a paragraph separator (\(code))"
        case 0x00: return "a null character (\(code))"
        case 0x1B: return "an escape character (\(code))"
        default: return c.properties.isNoncharacterCodePoint ? "a noncharacter (\(code))" : "a control character (\(code))"
        }
    }

    /// Distinct characters, named and joined: "a form feed (U+000C) and a vertical tab (U+000B)".
    private static func list(_ scalars: [Unicode.Scalar]) -> String {
        let names = scalars.map(describe)
        return names.count < 3 ? names.joined(separator: " and ") : names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
}

/// What a field last turned away, for the note under it. Every view that edits node content keeps one and does what
/// `review` says, so a refused character is never written and text that came from the file is never touched.
public struct CharacterCheck: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// Text the field may hand on as it is: clean typed text, or text equal to a source (what the file already
        /// holds), which is never cleaned: opening or syncing a node must not edit it. The issue banner reports it, and
        /// editing the field removes it.
        case forward
        /// Typed text with refused characters: show this instead (it is handed on at the next change).
        case replace(String)
    }

    public private(set) var message: String?
    /// Bumped on every rejection worth a note, so the note stays up for the full time after the latest one.
    public private(set) var count = 0

    public init() {}

    public mutating func review(_ text: String, _ kind: TextRules.Kind, field: String, sources: [String]) -> Outcome {
        if sources.contains(text) { return .forward }
        guard let r = TextRules.check(text, kind, field: field) else { return .forward }
        if let m = r.message {
            message = m
            count &+= 1
        }
        return .replace(r.text)
    }
}

public extension Calendar {
    /// The Gregorian calendar in UTC, which the site's `YYYY-MM-DD` dates are read in.
    static var gregorianUTC: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
}
