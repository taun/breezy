import Foundation

/// A directed link from the declaring node to `to`, with a relation. Mirrors lib/relations.js in the site repo.
public struct NodeLink: Equatable, Hashable, Sendable {
    public var to: String
    public var rel: String

    public init(to: String, rel: String = Relations.defaultRel) {
        self.to = to
        self.rel = rel
    }
}

public enum Relations {
    public static let defaultRel = "led-to"

    /// Known relations with their outgoing/incoming wording. Any other word is allowed.
    public static let known: [(rel: String, out: String, incoming: String)] = [
        ("led-to", "Led to", "Came from"),
        ("worked-at", "Worked at", "Worked here"),
        ("founded", "Founded", "Founded by"),
        ("part-of", "Part of", "Includes"),
    ]

    /// Trim, lowercase, whitespace to hyphens ("Worked At" -> "worked-at").
    public static func normalize(_ rel: String) -> String {
        let parts = rel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .split(whereSeparator: { $0.isWhitespace })
        return parts.joined(separator: "-")
    }

    /// Parses a decoded `links:` value. Drops self links and duplicates silently; other bad entries produce a warning.
    public static func parse(_ raw: Any?, from slug: String) -> (links: [NodeLink], warnings: [String]) {
        var links: [NodeLink] = []
        var warnings: [String] = []
        var seen = Set<NodeLink>()
        for entry in (raw as? [Any]) ?? [] {
            var to: String?
            var rel = defaultRel
            if let s = entry as? String {
                to = s
            } else if let d = entry as? [String: Any], let t = d["to"] as? String {
                to = t
                if let r = d["rel"] {
                    let n = normalize("\(r)")
                    if !n.isEmpty { rel = n }
                }
            }
            guard let target = to else {
                warnings.append("\(slug): link is neither a slug nor { to, rel }: \(entry)")
                continue
            }
            let link = NodeLink(to: target, rel: rel)
            if target == slug || seen.contains(link) { continue }
            seen.insert(link)
            links.append(link)
        }
        return (links, warnings)
    }
}
