import Foundation
import Yams

public enum NodeFileError: Error, Equatable, LocalizedError {
    case noFrontMatter
    case invalidYAML(String)

    public var errorDescription: String? {
        switch self {
        case .noFrontMatter: "The file has no front matter."
        case let .invalidYAML(message): message
        }
    }
}

/// One `src/nodes/<slug>.md` file: raw text kept for lossless writes, plus the decoded fields.
public struct NodeFile: Sendable {
    public let slug: String
    public private(set) var frontMatter: FrontMatterText
    /// Set with `setBody`, which stores only what TextRules allows.
    public private(set) var body: String

    public private(set) var title: String
    public private(set) var type: String
    public private(set) var summary: String
    public private(set) var tags: [String]
    public private(set) var date: NodeDate?
    public private(set) var draft: Bool
    /// The day (`YYYY-MM-DD`) the node entered the site's RSS feed; nil means it is not in the feed. Not `date`, which is when the thing happened.
    public private(set) var published: String?
    /// Set when `published` is there but is not a real day in `YYYY-MM-DD` form; the site's build warns and leaves the node out of the feed.
    public private(set) var publishedWarning: String?
    /// Characters the site cannot publish (`TextRules.problem`), per field: worked out when the node is read or
    /// edited, not on every redraw of the list.
    public var characterProblems: [String] { frontMatterProblems + (bodyProblem.map { [$0] } ?? []) }
    private var frontMatterProblems: [String] = []
    private var bodyProblem: String?
    public private(set) var links: [NodeLink]
    public private(set) var linkWarnings: [String]
    /// Optional single-string keys (media and similar), see `NodeFile.stringKeys`.
    public private(set) var strings: [String: String]
    /// The page banner and bookshelf thumbnail (`header:`), site paths of files in `src/assets/`.
    public private(set) var header: NodeHeader

    /// Plain string front matter keys the editor exposes besides the dedicated setters.
    public static let stringKeys = ["video", "archive", "slides", "repo"]

    public init(slug: String, text: String) throws {
        let all = text.components(separatedBy: "\n")
        guard all.first == "---", let close = all.dropFirst().firstIndex(of: "---") else { throw NodeFileError.noFrontMatter }
        self.slug = slug
        frontMatter = FrontMatterText(lines: Array(all[1..<close]))
        body = all[(close + 1)...].joined(separator: "\n")
        bodyProblem = Self.bodyProblem(body)
        title = ""; type = "thing"; summary = ""; tags = []; date = nil; draft = false; published = nil; publishedWarning = nil; links = []; linkWarnings = []; strings = [:]; header = NodeHeader()
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
        (published, publishedWarning) = Self.parsePublished(dict["published"], from: slug)
        (links, linkWarnings) = Relations.parse(dict["links"], from: slug)
        let fields = [("Title", title), ("Type", type), ("Summary", summary), ("Tags", tags.joined(separator: ", "))]
            + links.map { ("The relation of the link to \($0.to)", $0.rel) }
        frontMatterProblems = fields.compactMap { TextRules.problem(in: $1, field: $0) }
        strings = [:]
        for k in Self.stringKeys { if let v = dict[k] as? String { strings[k] = v } }
        frontMatterProblems += Self.stringKeys.compactMap { k in strings[k].flatMap { TextRules.problem(in: $0, field: k.capitalized) } }
        let h = dict["header"] as? [String: Any]
        header = NodeHeader(image: h?["image"] as? String, teaser: h?["teaser"] as? String, imageDescription: h?["image_description"] as? String)
    }

    private static func bodyProblem(_ body: String) -> String? { TextRules.problem(in: body, field: "The body") }

    /// Like parsePublished in lib/frontmatter.js: absent is fine; anything but a real day as `YYYY-MM-DD` is not a publish date.
    static func parsePublished(_ raw: Any?, from slug: String) -> (String?, String?) {
        guard let raw, !(raw is NSNull) else { return (nil, nil) }
        // [0-9], not \d, which also matches other scripts' digits that Int() cannot read.
        if let s = raw as? String, s.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil {
            let parts = s.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return (nil, "\"\(slug)\" has an invalid published date: \(raw); it stays out of the RSS feed.") }
            let calendar = Calendar.gregorianUTC
            if DateComponents(calendar: calendar, year: parts[0], month: parts[1], day: parts[2]).isValidDate { return (s, nil) }
        }
        return (nil, "\"\(slug)\" has an invalid published date: \(raw); it stays out of the RSS feed.")
    }

    /// A new node in the site's usual layout. It starts as a draft, so nothing goes live until the author says so.
    public static func new(slug: String, title: String, type: String) throws -> NodeFile {
        let title = TextRules.cleaned(title, .line), type = TextRules.cleaned(type, .line)
        let text = "---\ntitle: \(YAMLFormat.quoted(title))\ntype: \(YAMLFormat.scalar(type))\ntags: []\nlinks: []\ndraft: true\n---\n\n"
        return try NodeFile(slug: slug, text: text)
    }

    /// The path of this node in the site repo.
    public var path: String { "src/nodes/\(slug).md" }

    // MARK: Editing. Each setter rewrites only its own key's lines, then re-decodes.

    // The setters store only what TextRules allows, whatever the caller passed (the fields already refuse the rest).
    // Setting a key to the value it already has changes nothing, so a field handing back what it was given (on focus
    // loss, say) cannot rewrite text written by another tool.
    public mutating func setTitle(_ v: String) throws {
        if frontMatter.contains("title"), v == title { return }
        frontMatter.set("title", to: ["title: \(YAMLFormat.quoted(TextRules.cleaned(v, .line)))"])
        try decode()
    }
    public mutating func setType(_ v: String) throws {
        if frontMatter.contains("type"), v == type { return }
        frontMatter.set("type", to: ["type: \(YAMLFormat.scalar(TextRules.cleaned(v, .line)))"])
        try decode()
    }

    public mutating func setSummary(_ v: String) throws {
        if v == summary { return }
        let v = TextRules.cleaned(v, .text) // line breaks are allowed: the site shows them as spaces
        if v.isEmpty { frontMatter.remove("summary") } else { frontMatter.set("summary", to: ["summary: \(YAMLFormat.quoted(v))"]) }
        try decode()
    }

    public mutating func setTags(_ v: [String]) throws {
        if frontMatter.contains("tags"), v == tags { return }
        let v = v.map { TextRules.cleaned($0, .line).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        frontMatter.set("tags", to: ["tags: \(YAMLFormat.flowList(v.map(YAMLFormat.scalar)))"])
        try decode()
    }

    /// Sets or (with nil/empty) removes a plain string key such as `video` or `slides`.
    public mutating func setString(_ key: String, _ value: String?) throws {
        if (value ?? "") == (strings[key] ?? "") { return }
        let value = value.map { TextRules.cleaned($0, .line) }
        if let value, !value.isEmpty { frontMatter.set(key, to: ["\(key): \(YAMLFormat.scalarOrURL(value))"]) } else { frontMatter.remove(key) }
        try decode()
    }

    /// Sets or (nil) removes the banner image and the thumbnail; `image_description` and any other `header` keys stay.
    public mutating func setHeader(image: String?, teaser: String?) throws {
        var edited = frontMatter // both or neither, if the header cannot be changed
        try edited.setChild("header", "image", to: image.flatMap { $0.isEmpty ? nil : $0 })
        try edited.setChild("header", "teaser", to: teaser.flatMap { $0.isEmpty ? nil : $0 })
        frontMatter = edited
        try decode()
    }

    public mutating func setBody(_ v: String) {
        if v == body { return }
        body = TextRules.cleaned(v, .text)
        bodyProblem = nil // cleaned
    }

    public mutating func setLinks(_ v: [NodeLink]) throws {
        if frontMatter.contains("links"), v == links { return }
        let v = v.map { l in
            let rel = TextRules.cleaned(l.rel, .line)
            return NodeLink(to: l.to, rel: rel.trimmingCharacters(in: .whitespaces).isEmpty ? Relations.defaultRel : rel)
        }
        frontMatter.set("links", to: [YAMLFormat.linksLine(v)])
        try decode()
    }

    /// Going back to draft also takes the node out of the RSS feed. Going live leaves it out: the feed is opt-in (`setPublished`).
    public mutating func setDraft(_ v: Bool) throws {
        if v {
            frontMatter.set("draft", to: ["draft: true"])
            frontMatter.remove("published")
        } else {
            frontMatter.remove("draft")
        }
        try decode()
    }

    /// Sets or (nil) removes the day the node entered the RSS feed.
    public mutating func setPublished(_ iso: String?) throws {
        if let iso { frontMatter.set("published", to: ["published: \(iso)"]) } else { frontMatter.remove("published") }
        try decode()
    }

    /// Today in the author's time zone, not UTC (an evening post should not be dated tomorrow), and always as a Gregorian
    /// date: a device set to the Japanese or Buddhist calendar would otherwise give year 8 or 2569.
    public static func todayISO(now: Date = .now, timeZone: TimeZone = .current) -> String {
        isoDay(now, timeZone: timeZone)
    }

    /// The Gregorian day of `date` in `timeZone`, as `YYYY-MM-DD`.
    public static func isoDay(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar.gregorianUTC
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 2000, c.month ?? 1, c.day ?? 1)
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

/// The `header:` mapping of a node: its page banner, bookshelf thumbnail and (unused by the site so far) description.
public struct NodeHeader: Equatable, Sendable {
    public var image: String?
    public var teaser: String?
    public var imageDescription: String?

    public init(image: String? = nil, teaser: String? = nil, imageDescription: String? = nil) {
        self.image = image
        self.teaser = teaser
        self.imageDescription = imageDescription
    }

    /// Whether the banner or the thumbnail is the asset at `site` ("/assets/…").
    public func uses(_ site: String) -> Bool { [image, teaser].contains { $0.map(MarkdownImage.sitePath) == site } }
}
