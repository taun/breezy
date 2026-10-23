import Foundation

/// Repository-wide facts remembered for offline use.
public struct RepoState: Codable, Equatable, Sendable {
    public var defaultBranch: String
    /// Branch names last seen on GitHub.
    public var remoteBranches: [String]
    public var lastBranch: String?
    /// The published site's address (from CNAME, or github.io); editable in Settings.
    public var websiteURL: URL?

    public init(defaultBranch: String = "main", remoteBranches: [String] = [], lastBranch: String? = nil) {
        self.defaultBranch = defaultBranch
        self.remoteBranches = remoteBranches
        self.lastBranch = lastBranch
    }
}

/// The node files and assets of a commit: node path -> git blob sha, plus asset paths.
public struct Snapshot: Codable, Equatable, Sendable {
    public var commit: String
    public var files: [String: String]
    public var assets: [String]

    public init(commit: String, files: [String: String], assets: [String]) {
        self.commit = commit
        self.files = files
        self.assets = assets
    }
}

/// A file changed both locally and on GitHub since the local copy's base. Resolved one file at a time.
public struct Conflict: Codable, Equatable, Sendable, Identifiable {
    public var path: String
    /// The version both sides started from (nil: the file was new on both sides).
    public var baseSHA: String?
    /// GitHub's version (nil: deleted on GitHub).
    public var remoteSHA: String?
    public var id: String { path }
}

public enum ConflictResolution: Equatable, Sendable {
    /// Keep the local version; it replaces GitHub's when pushed.
    case mine
    /// Take GitHub's version and drop the local changes to this file.
    case theirs
    /// Use this merged text as a new uncommitted edit.
    case edited(String)
}

/// Everything known about one branch on this device, besides file contents (in objects/) and edits (in working/).
public struct BranchState: Codable, Equatable, Sendable {
    public var version = 1
    public var branch: String
    /// The commit the local copy is based on; queued commits are pushed on top of it.
    public var base: Snapshot
    /// False for a branch created on this device and not yet pushed.
    public var existsOnRemote: Bool
    public var fetchedAt: Date?
    /// Slugs deleted locally and not yet committed.
    public var deleted: [String] = []
    /// Set while reconciling: GitHub's newer snapshot, adopted once every conflict is resolved.
    public var pendingRemote: Snapshot?
    public var conflicts: [Conflict] = []
    /// When a sync found the branch gone from GitHub (published and deleted on another device, or deleted on
    /// github.com) while this copy still had local changes. Optional so older state files still decode.
    public var deletedOnGitHubAt: Date?

    public init(branch: String, base: Snapshot, existsOnRemote: Bool, fetchedAt: Date? = nil) {
        self.branch = branch
        self.base = base
        self.existsOnRemote = existsOnRemote
        self.fetchedAt = fetchedAt
    }
}

/// A commit made in the app and not yet pushed. Pushed in order, one GitHub commit each.
public struct QueuedCommit: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var message: String
    public var date: Date
    public var changes: [FileChange]

    public init(message: String, date: Date = .now, changes: [FileChange]) {
        self.message = message
        self.date = date
        self.changes = changes
    }
}
