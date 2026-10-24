import Foundation

/// The on-device copy of one repository, as plain files that stay readable in Finder / the Files app:
///
///     <root>/repo.json                         RepoState
///     <root>/objects/<blob-sha>                node file contents as fetched (shared by all branches)
///     <root>/branches/<branch>/state.json      BranchState
///     <root>/branches/<branch>/queue.json      [QueuedCommit], oldest first
///     <root>/branches/<branch>/working/<slug>.md   uncommitted edits (edited or new nodes only)
///
/// Every write is atomic (temporary file, then rename), and state.json is written after the files it refers to.
public struct LocalStore: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    /// `Documents/<owner>/<repo>` in the app container (visible in the Files app on iOS).
    public static func standard(for repo: RepoRef) -> LocalStore {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return LocalStore(root: docs.appendingPathComponent(repo.owner).appendingPathComponent(repo.name))
    }

    private var fm: FileManager { .default }
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: Repo

    public func repoState() -> RepoState? { read(RepoState.self, at: root.appendingPathComponent("repo.json")) }
    public func saveRepoState(_ s: RepoState) throws { try write(s, to: root.appendingPathComponent("repo.json")) }

    // MARK: Objects

    func objectURL(_ sha: String) -> URL { root.appendingPathComponent("objects").appendingPathComponent(sha) }

    public func hasObject(_ sha: String) -> Bool { fm.fileExists(atPath: objectURL(sha).path) }

    public func object(_ sha: String) -> String? { try? String(contentsOf: objectURL(sha), encoding: .utf8) }

    /// Stores text under its blob sha (no-op if present) and returns the sha. Pass `sha` when GitHub reported it,
    /// so the local copy always uses GitHub's IDs even if a file's bytes do not round-trip exactly as text.
    @discardableResult
    public func storeObject(_ text: String, sha known: String? = nil) throws -> String {
        let sha = known ?? GitBlob.sha(of: text)
        if !hasObject(sha) { try writeText(text, to: objectURL(sha)) }
        return sha
    }

    // MARK: Branches

    /// Directory name for a branch: percent-encoded so "feature/x" stays one folder.
    static func folderName(_ branch: String) -> String {
        branch.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))) ?? branch
    }

    func branchDir(_ branch: String) -> URL {
        root.appendingPathComponent("branches").appendingPathComponent(Self.folderName(branch))
    }

    /// Branches with a local copy.
    public func cachedBranches() -> [String] {
        let dir = root.appendingPathComponent("branches")
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { branchState(named: $0.removingPercentEncoding ?? $0)?.branch }.sorted()
    }

    public func branchState(named branch: String) -> BranchState? {
        read(BranchState.self, at: branchDir(branch).appendingPathComponent("state.json"))
    }

    public func saveBranchState(_ s: BranchState) throws {
        try write(s, to: branchDir(s.branch).appendingPathComponent("state.json"))
    }

    public func queue(_ branch: String) -> [QueuedCommit] {
        read([QueuedCommit].self, at: branchDir(branch).appendingPathComponent("queue.json")) ?? []
    }

    public func saveQueue(_ q: [QueuedCommit], for branch: String) throws {
        try write(q, to: branchDir(branch).appendingPathComponent("queue.json"))
    }

    /// Whether a branch's copy holds anything not on GitHub: queued commits, uncommitted edits or deletions,
    /// or (for a branch created on this device) the branch itself.
    public func hasLocalChanges(_ branch: String) -> Bool {
        guard let state = branchState(named: branch) else { return false }
        return !state.existsOnRemote || !queue(branch).isEmpty || !working(branch).isEmpty || !state.deleted.isEmpty
    }

    public func removeBranch(_ branch: String) throws {
        let dir = branchDir(branch)
        if fm.fileExists(atPath: dir.path) { try fm.removeItem(at: dir) }
    }

    // MARK: Working edits

    func workingURL(_ branch: String, _ slug: String) -> URL {
        branchDir(branch).appendingPathComponent("working").appendingPathComponent("\(slug).md")
    }

    /// Uncommitted edits by slug.
    public func working(_ branch: String) -> [String: String] {
        let dir = branchDir(branch).appendingPathComponent("working")
        var out: [String: String] = [:]
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".md") {
            if let text = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) { out[String(name.dropLast(3))] = text }
        }
        return out
    }

    public func saveWorking(_ text: String, slug: String, branch: String) throws { try writeText(text, to: workingURL(branch, slug)) }

    /// When the uncommitted edit of a node was last saved (its file's modification date), or nil if there is none.
    public func workingDate(slug: String, branch: String) -> Date? {
        (try? fm.attributesOfItem(atPath: workingURL(branch, slug).path))?[.modificationDate] as? Date
    }

    public func removeWorking(slug: String, branch: String) throws {
        let u = workingURL(branch, slug)
        if fm.fileExists(atPath: u.path) { try fm.removeItem(at: u) }
    }

    // MARK: Plumbing

    private func read<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(value).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func writeText(_ text: String, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
