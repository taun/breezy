import Foundation

public struct ValidationIssue: Equatable, Sendable {
    public enum Severity: Sendable { case error, warning }
    public var severity: Severity
    public var message: String
}

public enum Validator {
    /// Checks one node against the set of all node slugs (the content model's build-time rules).
    public static func validate(_ node: NodeFile, allSlugs: Set<String>, deletedSlugs: Set<String> = [], now: Date = .now) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        if node.title.isEmpty || node.title == node.slug { issues.append(.init(severity: .warning, message: "No title; the slug is used.")) }
        if node.type.isEmpty { issues.append(.init(severity: .error, message: "type is empty.")) }
        for l in node.links where !allSlugs.contains(l.to) {
            issues.append(.init(severity: .warning, message: deletedSlugs.contains(l.to)
                ? "Links to deleted node \"\(l.to)\"; undelete it or remove the link."
                : "Links to unknown node \"\(l.to)\"; the build drops it."))
        }
        for w in node.linkWarnings { issues.append(.init(severity: .warning, message: w)) }
        if let w = node.publishedWarning { issues.append(.init(severity: .warning, message: w)) }
        // Written by another tool (the fields refuse these). The site still builds the node, minus them in the feed.
        issues += node.characterProblems.map { .init(severity: .warning, message: $0) }
        // The site leaves a day after tomorrow (UTC) out of the feed as a typo, so say so before it is published.
        if let p = node.published, p > NodeFile.isoDay(now.addingTimeInterval(86_400), timeZone: Calendar.gregorianUTC.timeZone) {
            issues.append(.init(severity: .warning, message: "The RSS feed date \(p) is in the future; the site leaves the node out of the feed until then."))
        }
        return issues
    }

    /// Slugs must be unique and conventional (lowercase letters, digits, hyphens).
    public static func validateSlug(_ slug: String, existing: Set<String>) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        if existing.contains(slug) { issues.append(.init(severity: .error, message: "A node named \"\(slug)\" already exists.")) }
        if slug.range(of: #"^[a-z0-9]+(-[a-z0-9]+)*$"#, options: .regularExpression) == nil {
            issues.append(.init(severity: .error, message: "Use lowercase letters, digits and hyphens."))
        }
        return issues
    }
}
