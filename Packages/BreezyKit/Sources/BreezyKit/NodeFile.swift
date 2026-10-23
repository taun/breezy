import Foundation
import Yams

public enum NodeFileError: Error, Equatable {
    case noFrontMatter
    case invalidYAML(String)
}

/// One `src/nodes/<slug>.md` file: raw text kept for lossless writes, plus the decoded fields.
public struct NodeFile: Sendable {
    public let slug: String
    public private(set) var frontMatter: FrontMatterText
    public var body: String

    public private(set) var title: String
    public private(set) var type: String
    public private(set) var summary: String
    public private(set) var tags: [String]
    public private(set) var date: NodeDate?
    public private(set) var draft: Bool
    public private(set) var links: [NodeLink]
    public private(set) var linkWarnings: [String]
    /// Optional single-string keys (media and similar), see `NodeFile.stringKeys`.
    public private(set) var strings: [String: String]

    /// Plain string front matter keys the editor exposes besides the dedicated setters.
    public static let stringKeys = ["video", "archive", "slides", "repo"]

    public init(slug: String, text: String) throws {
        let all = text.components(separatedBy: "\n")
        guard all.first == "---", let close = all.dropFirst().firstIndex(of: "---") else { throw NodeFileError.noFrontMatter }
        self.slug = slug
        frontMatter = FrontMatterText(lines: Array(all[1..<close]))
        body = all[(close + 1)...].joined(separator: "\n")
        title = ""; type = "thing"; summary = ""; tags = []; date = nil; draft = false; links = []; linkWarnings = []; strings = [:]
        try decode()
    }

    /// The full file text.
    public func rendered() -> String {
        "---\n" + frontMatter.lines.map { $0 + "\n" }.joined() + "---\n" + (body.isEmpty ? "" : body)
    }

    private mutating func decode() throws {
        let yaml = frontMatter.lines.joined(separator: "\n")
        let loaded: Any?
        do {
            // Default YAML typing minus timestamps, so `2018-09-06` stays a string but `2021` and `true` are typed.
            loaded = try Yams.load(yaml: yaml, Resolver.default.removing(.timestamp))
        } catch {
            throw NodeFileError.invalidYAML("\(error)")
        }
        let dict = (loaded as? [String: Any]) ?? [:]
        title = (dict["title"] as? String) ?? slug
        type = (dict["type"] as? String) ?? "thing"
        summary = (dict["summary"] as? String) ?? ""
        tags = ((dict["tags"] as? [Any]) ?? []).map { "\($0)" }
        date = NodeDate.parse(date: dict["date"], precision: dict["datePrecision"])
        draft = (dict["draft"] as? Bool) ?? false
        (links, linkWarnings) = Relations.parse(dict["links"], from: slug)
        strings = [:]
        for k in Self.stringKeys { if let v = dict[k] as? String { strings[k] = v } }
    }

    /// A new node in the site's usual layout.
    public static func new(slug: String, title: String, type: String) throws -> NodeFile {
        let text = "---\ntitle: \(YAMLFormat.quoted(title))\ntype: \(YAMLFormat.scalar(type))\ntags: []\nlinks: []\n---\n\n"
        return try NodeFile(slug: slug, text: text)
    }

    /// The path of this node in the site repo.
    public var path: String { "src/nodes/\(slug).md" }

    // MARK: Editing. Each setter rewrites only its own key's lines, then re-decodes.

    public mutating func setTitle(_ v: String) throws { frontMatter.set("title", to: ["title: \(YAMLFormat.quoted(v))"]); try decode() }
    public mutating func setType(_ v: String) throws { frontMatter.set("type", to: ["type: \(YAMLFormat.scalar(v))"]); try decode() }

    public mutating func setSummary(_ v: String) throws {
        if v.isEmpty { frontMatter.remove("summary") } else { frontMatter.set("summary", to: ["summary: \(YAMLFormat.quoted(v))"]) }
        try decode()
    }

    public mutating func setTags(_ v: [String]) throws {
        frontMatter.set("tags", to: ["tags: \(YAMLFormat.flowList(v.map(YAMLFormat.scalar)))"])
        try decode()
    }

    /// Sets or (with nil/empty) removes a plain string key such as `video` or `slides`.
    public mutating func setString(_ key: String, _ value: String?) throws {
        if let value, !value.isEmpty { frontMatter.set(key, to: ["\(key): \(YAMLFormat.scalarOrURL(value))"]) } else { frontMatter.remove(key) }
        try decode()
    }

    public mutating func setBody(_ v: String) { body = v }

    public mutating func setLinks(_ v: [NodeLink]) throws { frontMatter.set("links", to: [YAMLFormat.linksLine(v)]); try decode() }

    public mutating func setDraft(_ v: Bool) throws {
        if v { frontMatter.set("draft", to: ["draft: true"]) } else { frontMatter.remove("draft") }
        try decode()
    }

    /// nil removes `date` and `datePrecision`. A year-precision date is written as a bare year, like the site files.
    public mutating func setDate(_ v: NodeDate?) throws {
        guard let v else {
            frontMatter.remove("date"); frontMatter.remove("datePrecision")
            return try decode()
        }
        frontMatter.set("date", to: ["date: \(v.iso)"])
        if v.precision == .year { frontMatter.set("datePrecision", to: ["datePrecision: year"]) } else { frontMatter.remove("datePrecision") }
        try decode()
    }
}
