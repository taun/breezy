import Foundation
import Observation

/// One branch of the site loaded into memory: its nodes, asset paths, and the edits not yet committed.
@MainActor @Observable
public final class SiteWorkspace {
    public let client: GitHubClient
    public private(set) var branch: String
    /// The commit the loaded files came from; commits are refused if the branch has moved past it.
    public private(set) var headSHA: String = ""
    /// Current (possibly edited) nodes by slug.
    public private(set) var nodes: [String: NodeFile] = [:]
    /// Text of each node as loaded, by slug, to detect edits.
    private var loadedText: [String: String] = [:]
    /// Site-root paths of files under src/assets, e.g. "/assets/images/x.png".
    public private(set) var assetPaths: [String] = []
    public private(set) var isLoading = false

    public init(client: GitHubClient, branch: String) {
        self.client = client
        self.branch = branch
    }

    public static let nodesDir = "src/nodes/"
    static let assetsDir = "src/assets/"

    // MARK: Loading

    public func load(branch: String? = nil) async throws {
        if let branch { self.branch = branch }
        isLoading = true
        defer { isLoading = false }
        let head = try await client.headSHA(of: self.branch)
        let entries = try await client.tree(ofCommit: head)
        let nodeEntries = entries.filter { e in
            e.isBlob && e.path.hasPrefix(Self.nodesDir) && e.path.hasSuffix(".md")
                && !e.path.dropFirst(Self.nodesDir.count).contains("/") // the site's glob is not recursive
        }
        let client = self.client
        let texts = try await withThrowingTaskGroup(of: (String, String).self) { group in
            for e in nodeEntries {
                let slug = String(e.path.dropFirst(Self.nodesDir.count).dropLast(3))
                group.addTask { (slug, try await client.blobText(e.sha)) }
            }
            var out: [String: String] = [:]
            for try await (slug, text) in group { out[slug] = text }
            return out
        }
        var parsed: [String: NodeFile] = [:]
        for (slug, text) in texts { parsed[slug] = try NodeFile(slug: slug, text: text) }
        headSHA = head
        loadedText = texts
        nodes = parsed
        assetPaths = entries.filter { $0.isBlob && $0.path.hasPrefix(Self.assetsDir) }
            .map { "/" + $0.path.dropFirst("src/".count) }.sorted()
    }

    // MARK: Queries

    public var slugs: Set<String> { Set(nodes.keys) }

    /// Types in use, sorted, for pickers.
    public var types: [String] { Array(Set(nodes.values.map(\.type))).sorted() }

    public var sortedNodes: [NodeFile] {
        nodes.values.sorted { ($0.date?.iso ?? "") != ($1.date?.iso ?? "") ? ($0.date?.iso ?? "") > ($1.date?.iso ?? "") : $0.title < $1.title }
    }

    public func issues(for slug: String) -> [ValidationIssue] {
        guard let n = nodes[slug] else { return [] }
        return Validator.validate(n, allSlugs: slugs)
    }

    /// Pending writes and deletions relative to what was loaded.
    public var changes: [FileChange] {
        var out: [FileChange] = []
        for (slug, node) in nodes where loadedText[slug] != node.rendered() {
            out.append(FileChange(path: node.path, content: node.rendered()))
        }
        for slug in loadedText.keys where nodes[slug] == nil {
            out.append(FileChange(path: "\(Self.nodesDir)\(slug).md", content: nil))
        }
        return out.sorted { $0.path < $1.path }
    }

    public var hasChanges: Bool { !changes.isEmpty }

    public func isModified(_ slug: String) -> Bool { loadedText[slug] != nodes[slug]?.rendered() }

    // MARK: Editing

    /// Applies an edit to one node; errors (invalid YAML) leave the node unchanged.
    public func update(_ slug: String, _ edit: (inout NodeFile) throws -> Void) rethrows {
        guard var n = nodes[slug] else { return }
        try edit(&n)
        nodes[slug] = n
    }

    public func createNode(slug: String, title: String, type: String) throws {
        let problems = Validator.validateSlug(slug, existing: slugs)
        if let first = problems.first { throw WorkspaceError.invalidSlug(first.message) }
        nodes[slug] = try NodeFile.new(slug: slug, title: title, type: type)
    }

    public func deleteNode(_ slug: String) { nodes[slug] = nil }

    /// Puts a node back as given (used to carry edits onto a newly created branch).
    public func replace(_ slug: String, with node: NodeFile) { nodes[slug] = node }

    /// Throws away all edits.
    public func revertAll() throws {
        var restored: [String: NodeFile] = [:]
        for (slug, text) in loadedText { restored[slug] = try NodeFile(slug: slug, text: text) }
        nodes = restored
    }

    public func revert(_ slug: String) throws {
        if let text = loadedText[slug] { nodes[slug] = try NodeFile(slug: slug, text: text) } else { nodes[slug] = nil }
    }

    // MARK: Committing

    /// Commits every pending change in one commit, then reloads the branch.
    public func commit(message: String) async throws {
        let pending = changes
        guard !pending.isEmpty else { return }
        _ = try await client.commit(pending, message: message, to: branch, expectedHead: headSHA)
        try await load()
    }
}

public enum WorkspaceError: Error, Equatable, LocalizedError {
    case invalidSlug(String)
    public var errorDescription: String? {
        switch self { case let .invalidSlug(m): m }
    }
}
