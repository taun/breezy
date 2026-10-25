import Foundation

/// `owner/name` of the site repository.
public struct RepoRef: Codable, Hashable, Sendable {
    public var owner: String
    public var name: String

    public init(owner: String, name: String) {
        self.owner = owner
        self.name = name
    }

    /// Parses "owner/name".
    public init?(_ string: String) {
        let parts = string.trimmingCharacters(in: .whitespaces).split(separator: "/")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        self.init(owner: String(parts[0]), name: String(parts[1]))
    }

    public var description: String { "\(owner)/\(name)" }
}

public extension RepoRef {
    /// Where Breezy's own issues are filed.
    static let breezy = RepoRef(owner: "taun", name: "breezy")
}

/// A GitHub issue, as returned right after creating it.
public struct Issue: Hashable, Sendable {
    public var number: Int
    public var title: String
    public var htmlURL: URL
}

public enum GitHubError: Error, Equatable, LocalizedError {
    case invalidResponse
    /// Non-2xx status with GitHub's message.
    case http(status: Int, message: String)
    /// The branch moved since it was loaded; reload before committing.
    case branchMoved(branch: String, expected: String, actual: String)
    case mergeFailed(String)
    /// The branch does not exist on GitHub (published and deleted elsewhere, or deleted on github.com).
    case branchNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "GitHub returned an unexpected response."
        case let .http(status, message):
            status == 401 ? "GitHub rejected the token (401). Check it in Settings." : "GitHub error \(status): \(message)"
        case let .branchMoved(branch, _, _): "“\(branch)” changed on GitHub since it was loaded. Reload, then commit again."
        case let .mergeFailed(message): "Merge failed: \(message)"
        case let .branchNotFound(branch): "“\(branch)” no longer exists on GitHub."
        }
    }
}

public struct Branch: Hashable, Sendable, Identifiable {
    public var name: String
    public var sha: String
    public var id: String { name }
}

public struct TreeEntry: Hashable, Sendable {
    public var path: String
    public var sha: String
    public var isBlob: Bool
}

/// A file write (`content`) or deletion (`content == nil`) in one commit.
public struct FileChange: Codable, Hashable, Sendable {
    public var path: String
    public var content: String?

    public init(path: String, content: String?) {
        self.path = path
        self.content = content
    }
}

public enum MergeMethod: String, CaseIterable, Sendable, Identifiable {
    case merge, squash, rebase
    public var id: String { rawValue }
}

public struct Comparison: Hashable, Sendable {
    public var aheadBy: Int
    public var behindBy: Int
    public var files: [String]
}

public struct WorkflowRun: Hashable, Sendable {
    public var name: String
    /// queued, in_progress, completed...
    public var status: String
    /// success, failure, cancelled... once completed.
    public var conclusion: String?
    public var htmlURL: URL?

    public var isFinished: Bool { status == "completed" }
    public var succeeded: Bool { conclusion == "success" }
}

public struct PullRequest: Hashable, Sendable, Identifiable {
    public var number: Int
    public var title: String
    public var head: String
    public var base: String
    public var state: String
    /// nil while GitHub is still computing it.
    public var mergeable: Bool?
    public var mergeableState: String?
    public var htmlURL: URL?
    public var id: Int { number }
}

/// The label that classifies an issue filed from the app.
public enum IssueKind: String, CaseIterable, Sendable {
    case bug, enhancement
}
