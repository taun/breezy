import Foundation
import Observation

/// One branch of the site, offline-first. The local copy in `LocalStore` is the source for everything shown and
/// edited; GitHub is only contacted by `sync`, which reconciles and then pushes queued commits.
///
/// Three layers make up what is displayed:
/// 1. `state.base`: the files of the commit the local copy is based on (what GitHub had at the last sync).
/// 2. `queue`: commits made in the app and not yet pushed, applied in order.
/// 3. working edits: uncommitted changes, saved to disk as they happen.
@MainActor @Observable
public final class SiteWorkspace {
    public let store: LocalStore
    public private(set) var state: BranchState
    public private(set) var queue: [QueuedCommit]
    /// Displayed (possibly edited) nodes by slug.
    public private(set) var nodes: [String: NodeFile] = [:]
    /// Nodes deleted here whose deletion is not published yet (uncommitted, committed, or on an unmerged branch), with
    /// their last content. Shown struck through in the list; see `undelete`. Issue #3.
    public private(set) var deletedNodes: [String: NodeFile] = [:]
    /// base + queue, by slug: what working edits are compared against.
    private var committedText: [String: String] = [:]
    public private(set) var isSyncing = false

    public static let nodesDir = "src/nodes/"
    static let assetsDir = "src/assets/"

    public var branch: String { state.branch }
    /// The commit the local copy is based on.
    public var headSHA: String { state.base.commit }
    public var assetPaths: [String] { state.base.assets }
    public var conflicts: [Conflict] { state.conflicts }

    init(store: LocalStore, state: BranchState) throws {
        self.store = store
        self.state = state
        queue = store.queue(state.branch)
        try rebuild()
    }

    // MARK: Opening

    /// Opens the local copy of a branch, or nil if this device has none.
    public static func open(_ branch: String, store: LocalStore) throws -> SiteWorkspace? {
        guard let state = store.branchState(named: branch) else { return nil }
        return try SiteWorkspace(store: store, state: state)
    }

    /// Downloads a branch that has no local copy yet, saves it, and opens it.
    /// Reports file downloads as (files done, files to download). Only files not already on the device are counted.
    public typealias Progress = @MainActor (_ done: Int, _ total: Int) -> Void

    public static func download(_ branch: String, client: GitHubClient, store: LocalStore, progress: Progress? = nil) async throws -> SiteWorkspace {
        let snapshot = try await fetchSnapshot(branch, client: client, store: store, progress: progress)
        let state = BranchState(branch: branch, base: snapshot, existsOnRemote: true, fetchedAt: .now)
        try store.saveBranchState(state)
        return try SiteWorkspace(store: store, state: state)
    }

    /// The node files and assets at the branch head, downloading any file contents not already stored.
    static func fetchSnapshot(_ branch: String, client: GitHubClient, store: LocalStore, progress: Progress? = nil) async throws -> Snapshot {
        let head = try await client.headSHA(of: branch)
        return try await fetchSnapshot(commit: head, client: client, store: store, progress: progress)
    }

    static func fetchSnapshot(commit: String, client: GitHubClient, store: LocalStore, progress: Progress? = nil) async throws -> Snapshot {
        let entries = try await client.tree(ofCommit: commit)
        let nodeEntries = entries.filter { e in
            e.isBlob && e.path.hasPrefix(nodesDir) && e.path.hasSuffix(".md")
                && !e.path.dropFirst(nodesDir.count).contains("/") // the site's glob is not recursive
        }
        let missing = nodeEntries.filter { !store.hasObject($0.sha) }
        let texts = try await withThrowingTaskGroup(of: (String, String).self) { group in
            for e in missing { group.addTask { (e.sha, try await client.blobText(e.sha)) } }
            var out: [(String, String)] = []
            progress?(0, missing.count)
            for try await t in group {
                out.append(t)
                progress?(out.count, missing.count)
            }
            return out
        }
        for (sha, text) in texts { try store.storeObject(text, sha: sha) }
        let assets = entries.filter { $0.isBlob && $0.path.hasPrefix(assetsDir) }.map { "/" + $0.path.dropFirst("src/".count) }.sorted()
        return Snapshot(commit: commit, files: Dictionary(uniqueKeysWithValues: nodeEntries.map { ($0.path, $0.sha) }), assets: assets)
    }

    // MARK: Queries

    public var slugs: Set<String> { Set(nodes.keys) }
    public var types: [String] { Array(Set(nodes.values.map(\.type))).sorted() }

    public var sortedNodes: [NodeFile] { sortedNodes(by: .date, draftsFirst: false) }

    /// When a node last changed: its latest commit on GitHub, or later if it was edited or committed on this device.
    public func lastUpdated(_ slug: String) -> Date? {
        let path = Self.path(slug)
        var dates = [state.fileDates?[path], store.workingDate(slug: slug, branch: branch)].compactMap { $0 }
        dates += queue.filter { $0.changes.contains { $0.path == path } }.map(\.date)
        return dates.max()
    }

    /// The nodes in list order. With `draftsFirst`, drafts come before everything else, each group in `sort` order.
    public func sortedNodes(by sort: NodeSort, draftsFirst: Bool) -> [NodeFile] {
        ordered(Array(nodes.values), by: sort, draftsFirst: draftsFirst)
    }

    func ordered(_ list: [NodeFile], by sort: NodeSort, draftsFirst: Bool) -> [NodeFile] {
        let updated = sort == .updated ? Dictionary(uniqueKeysWithValues: list.map { ($0.slug, lastUpdated($0.slug)) }) : [:]
        func dateOrder(_ a: NodeFile, _ b: NodeFile) -> Bool? {
            let x = a.date?.iso ?? "", y = b.date?.iso ?? ""
            return x == y ? nil : x > y
        }
        func titleOrder(_ a: NodeFile, _ b: NodeFile) -> Bool {
            let c = a.title.localizedStandardCompare(b.title)
            return c == .orderedSame ? a.slug < b.slug : c == .orderedAscending
        }
        return list.sorted { a, b in
            if draftsFirst, a.draft != b.draft { return a.draft }
            switch sort {
            case .title:
                return titleOrder(a, b)
            case .date:
                return dateOrder(a, b) ?? titleOrder(a, b)
            case .updated:
                // Newest first; nodes with no known date last.
                switch (updated[a.slug] ?? nil, updated[b.slug] ?? nil) {
                case let (x?, y?) where x != y: return x > y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return dateOrder(a, b) ?? titleOrder(a, b)
                }
            }
        }
    }

    public func issues(for slug: String) -> [ValidationIssue] {
        guard let n = nodes[slug] else { return [] }
        return Validator.validate(n, allSlugs: slugs, deletedSlugs: Set(deletedNodes.keys))
    }

    /// Uncommitted writes and deletions.
    public var changes: [FileChange] {
        var out: [FileChange] = []
        for (slug, node) in nodes where committedText[slug] != node.rendered() {
            out.append(FileChange(path: node.path, content: node.rendered()))
        }
        for slug in committedText.keys where nodes[slug] == nil {
            out.append(FileChange(path: Self.path(slug), content: nil))
        }
        return out.sorted { $0.path < $1.path }
    }

    public var hasChanges: Bool { !changes.isEmpty }

    /// Anything here that is not on GitHub: uncommitted edits or queued commits.
    public var hasLocalChanges: Bool { hasChanges || !queue.isEmpty }

    /// A default commit message naming what the uncommitted changes do, e.g. "Add new-talk; Edit bowery; Delete a-theory".
    /// Each group lists up to three nodes, then "and N more".
    public var suggestedCommitMessage: String {
        var added: [String] = [], edited: [String] = [], deleted: [String] = []
        for c in changes {
            let slug = Self.slug(c.path)
            if c.content == nil { deleted.append(slug) } else if committedText[slug] == nil { added.append(slug) } else { edited.append(slug) }
        }
        func part(_ verb: String, _ slugs: [String]) -> String? {
            guard !slugs.isEmpty else { return nil }
            return "\(verb) " + slugs.prefix(3).joined(separator: ", ") + (slugs.count > 3 ? " and \(slugs.count - 3) more" : "")
        }
        return [part("Add", added), part("Edit", edited), part("Delete", deleted)].compactMap { $0 }.joined(separator: "; ")
    }

    /// The branch was found deleted on GitHub while this copy had local changes; see `recreateOnGitHub` and `moveEdits`.
    public var isDeletedOnGitHub: Bool { state.deletedOnGitHubAt != nil }
    public func isModified(_ slug: String) -> Bool { committedText[slug] != nodes[slug]?.rendered() }

    /// Text of a node in the base snapshot / GitHub's pending snapshot, for showing conflicts.
    public func text(sha: String?) -> String? { sha.flatMap(store.object) }

    /// The local version of a conflicted path (nil: deleted locally).
    public func localText(path: String) -> String? { nodes[Self.slug(path)]?.rendered() }

    // MARK: Editing (saved to disk immediately)

    public func update(_ slug: String, _ edit: (inout NodeFile) throws -> Void) throws {
        guard var n = nodes[slug] else { return }
        try edit(&n)
        nodes[slug] = n
        try persist(slug)
    }

    public func createNode(slug: String, title: String, type: String) throws {
        if let first = Validator.validateSlug(slug, existing: slugs).first { throw WorkspaceError.invalidSlug(first.message) }
        nodes[slug] = try NodeFile.new(slug: slug, title: title, type: type)
        try persist(slug)
    }

    /// Deletes a node. With `removingIncomingLinks`, nodes linking to it also drop those links; otherwise they keep
    /// them and are flagged (`brokenLinks`) until the node is undeleted or the links are removed.
    public func deleteNode(_ slug: String, removingIncomingLinks: Bool = false) throws {
        if removingIncomingLinks {
            for other in incomingLinks(to: slug) {
                try update(other.slug) { node in try node.setLinks(node.links.filter { $0.to != slug }) }
            }
        }
        nodes[slug] = nil
        try persist(slug)
    }

    /// Brings back a deleted node: cancels an uncommitted deletion, or re-adds the file (an uncommitted addition)
    /// when the deletion was already committed.
    public func undelete(_ slug: String) throws {
        guard nodes[slug] == nil, let gone = deletedNodes[slug] else { return }
        if committedText[slug] != nil {
            try revert(slug)
        } else {
            nodes[slug] = gone
            try persist(slug)
        }
    }

    /// Nodes (not deleted) whose links point at `slug`.
    public func incomingLinks(to slug: String) -> [NodeFile] {
        nodes.values.filter { $0.slug != slug && $0.links.contains { $0.to == slug } }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Links of `slug` that point at deleted nodes.
    public func brokenLinks(of slug: String) -> [NodeLink] {
        nodes[slug]?.links.filter { deletedNodes[$0.to] != nil } ?? []
    }

    public func revert(_ slug: String) throws {
        if let text = committedText[slug] { nodes[slug] = try NodeFile(slug: slug, text: text) } else { nodes[slug] = nil }
        try persist(slug)
    }

    public func revertAll() throws {
        for slug in Set(nodes.keys).union(committedText.keys) { try revert(slug) }
    }

    /// Writes one node's working state: an edit file, a deletion mark, or nothing when it matches the committed text.
    private func persist(_ slug: String) throws {
        let committed = committedText[slug]
        let current = nodes[slug]?.rendered()
        if let current, current != committed { try store.saveWorking(current, slug: slug, branch: branch) } else { try store.removeWorking(slug: slug, branch: branch) }
        let deleted = current == nil && committed != nil
        if deleted != state.deleted.contains(slug) {
            if deleted { state.deleted.append(slug) } else { state.deleted.removeAll { $0 == slug } }
            try store.saveBranchState(state)
        }
        try refreshDeleted()
    }

    // MARK: Committing (works offline)

    /// Turns the uncommitted changes into a queued commit; `sync` pushes it.
    public func commit(message: String) throws {
        let pending = changes
        guard !pending.isEmpty else { return }
        queue.append(QueuedCommit(message: message, changes: pending))
        try store.saveQueue(queue, for: branch)
        let deletedPaths = pending.filter { $0.content == nil }.map(\.path)
        if !deletedPaths.isEmpty { state.pendingDeletions = Array(Set((state.pendingDeletions ?? []) + deletedPaths)).sorted() }
        for c in pending { try store.removeWorking(slug: Self.slug(c.path), branch: branch) }
        state.deleted = []
        try store.saveBranchState(state)
        try rebuild()
    }

    // MARK: Syncing

    public enum SyncResult: Equatable, Sendable {
        /// Up to date with GitHub; `pushed` queued commits went up.
        case synced(pushed: Int)
        /// GitHub changed files that were also changed here; resolve them, then sync again.
        case conflicts(Int)
        /// The branch is gone from GitHub (usually published and deleted on another device). Without local changes
        /// the copy can simply be removed; with them, use `recreateOnGitHub` or `moveEdits(toNewBranch:from:client:)`.
        case branchDeleted(hasLocalChanges: Bool)
    }

    /// Creates the branch on GitHub if needed, takes GitHub's newer files, and pushes queued commits in order.
    @discardableResult
    /// `publishedBranch` is the branch the site is built from (the default branch); its files are recorded so node
    /// states can be compared with what is live.
    public func sync(client: GitHubClient, progress: Progress? = nil, publishedBranch: String? = nil) async throws -> SyncResult {
        isSyncing = true
        defer { isSyncing = false }
        if !state.conflicts.isEmpty { return .conflicts(state.conflicts.count) }
        if !state.existsOnRemote {
            try await client.createBranch(branch, from: state.base.commit)
            state.existsOnRemote = true
            try store.saveBranchState(state)
        }
        let head: String
        do {
            head = try await client.headSHA(of: branch)
        } catch GitHubError.branchNotFound {
            if hasLocalChanges, state.deletedOnGitHubAt == nil {
                state.deletedOnGitHubAt = .now
                try store.saveBranchState(state)
            }
            return .branchDeleted(hasLocalChanges: hasLocalChanges)
        }
        if state.deletedOnGitHubAt != nil { // it is back (recreated elsewhere)
            state.deletedOnGitHubAt = nil
            try store.saveBranchState(state)
        }
        if head != state.base.commit {
            let remote = try await Self.fetchSnapshot(commit: head, client: client, store: store, progress: progress)
            let found = conflicts(with: remote)
            if !found.isEmpty {
                state.pendingRemote = remote
                state.conflicts = found
                try store.saveBranchState(state)
                return .conflicts(found.count)
            }
            try adopt(remote)
        }
        var pushed = 0
        while let next = queue.first {
            let newHead = try await client.commit(next.changes, message: next.message, to: branch, expectedHead: state.base.commit)
            var base = state.base
            for c in next.changes {
                if let content = c.content { base.files[c.path] = try store.storeObject(content) } else { base.files[c.path] = nil }
            }
            base.commit = newHead
            for c in next.changes { state.fileDates = (state.fileDates ?? [:]).merging([c.path: .now]) { $1 } }
            state.base = base
            queue.removeFirst()
            // Queue first: if the app stops between the two writes, a commit is never pushed twice.
            try store.saveQueue(queue, for: branch)
            try store.saveBranchState(state)
            pushed += 1
        }
        await fillMissingFileDates(client: client)
        if let publishedBranch { await refreshPublished(publishedBranch, client: client) }
        state.fetchedAt = .now
        try store.saveBranchState(state)
        try rebuild()
        return .synced(pushed: pushed)
    }

    /// Records the published branch's node files. On the published branch itself that is the base just synced;
    /// otherwise its tree is read from GitHub, only when its head moved. Best effort, like the file dates.
    func refreshPublished(_ publishedBranch: String, client: GitHubClient) async {
        if publishedBranch == branch {
            state.publishedCommit = state.base.commit
            state.publishedFiles = state.base.files
            return
        }
        guard let head = try? await client.headSHA(of: publishedBranch) else { return }
        guard head != state.publishedCommit || state.publishedFiles == nil else { return }
        guard let entries = try? await client.tree(ofCommit: head) else { return }
        state.publishedFiles = Dictionary(uniqueKeysWithValues: entries.filter(Self.isNodeEntry).map { ($0.path, $0.sha) })
        state.publishedCommit = head
    }

    static func isNodeEntry(_ e: TreeEntry) -> Bool {
        e.isBlob && e.path.hasPrefix(nodesDir) && e.path.hasSuffix(".md") && !e.path.dropFirst(nodesDir.count).contains("/")
    }

    /// Fetches the last-commit date of every node file that has none yet (all of them after a download). Best effort:
    /// a file whose date cannot be fetched now is tried again at the next sync. Eight requests at a time.
    func fillMissingFileDates(client: GitHubClient) async {
        let missing = state.base.files.keys.filter { state.fileDates?[$0] == nil }.sorted()
        guard !missing.isEmpty else { return }
        var found: [String: Date] = [:]
        var index = 0
        while index < missing.count {
            let chunk = missing[index..<min(index + 8, missing.count)]
            index += chunk.count
            let ref = branch
            await withTaskGroup(of: (String, Date?).self) { group in
                for path in chunk { group.addTask { (path, try? await client.lastCommitDate(path: path, ref: ref)) } }
                for await (path, date) in group { if let date { found[path] = date } }
            }
        }
        state.fileDates = (state.fileDates ?? [:]).merging(found) { $1 }
    }

    /// Paths GitHub changed since the base that were also changed here (queued, edited or deleted).
    func conflicts(with remote: Snapshot) -> [Conflict] {
        let touched = Set(queue.flatMap { $0.changes.map(\.path) })
            .union(store.working(branch).keys.map(Self.path))
            .union(state.deleted.map(Self.path))
        return Set(state.base.files.keys).union(remote.files.keys).sorted().compactMap { path in
            let b = state.base.files[path], r = remote.files[path]
            guard b != r, touched.contains(path) else { return nil }
            // Same result on both sides is not a conflict.
            if r == localText(path: path).map(GitBlob.sha) { return nil }
            return Conflict(path: path, baseSHA: b, remoteSHA: r)
        }
    }

    /// Makes GitHub's snapshot the new base. Local queued and working changes stay on top of it.
    private func adopt(_ remote: Snapshot) throws {
        // Files GitHub changed get their dates fetched again at the end of this sync.
        for (path, sha) in remote.files where state.base.files[path] != sha { state.fileDates?[path] = nil }
        state.base = remote
        state.pendingRemote = nil
        state.conflicts = []
        try store.saveBranchState(state)
        try rebuild()
    }

    /// Settles one conflicted file. When the last one is settled, GitHub's snapshot becomes the base; sync again to push.
    public func resolve(_ path: String, with resolution: ConflictResolution) throws {
        guard state.conflicts.contains(where: { $0.path == path }) else { return }
        let slug = Self.slug(path)
        switch resolution {
        case .mine:
            break
        case .theirs:
            for i in queue.indices { queue[i].changes.removeAll { $0.path == path } }
            queue.removeAll { $0.changes.isEmpty }
            try store.saveQueue(queue, for: branch)
            try store.removeWorking(slug: slug, branch: branch)
            state.deleted.removeAll { $0 == slug }
        case let .edited(text):
            try store.saveWorking(text, slug: slug, branch: branch)
            state.deleted.removeAll { $0 == slug }
        }
        state.conflicts.removeAll { $0.path == path }
        if state.conflicts.isEmpty, let remote = state.pendingRemote {
            try adopt(remote)
        } else {
            try store.saveBranchState(state)
            try rebuild()
        }
    }

    // MARK: Branches

    /// Recreates a branch that was deleted on GitHub, at the commit this copy is based on (GitHub keeps it, for
    /// example through the pull request), so the next `sync` creates it and pushes the queued commits.
    public func recreateOnGitHub() throws {
        state.existsOnRemote = false
        state.deletedOnGitHubAt = nil
        try store.saveBranchState(state)
    }

    /// Moves this copy's local changes (uncommitted edits and queued commits, as uncommitted edits) onto a new branch
    /// created on this device from `base`'s current files on GitHub. Files `base` also changed differently become
    /// conflicts, resolved file by file as usual. This branch's local copy is removed afterwards.
    public func moveEdits(toNewBranch name: String, from base: String, client: GitHubClient, progress: Progress? = nil) async throws -> SiteWorkspace {
        guard store.branchState(named: name) == nil else { throw WorkspaceError.branchExists(name) }
        let target = try await Self.fetchSnapshot(base, client: client, store: store, progress: progress)
        let touched = Set(queue.flatMap { $0.changes.map(\.path) })
            .union(store.working(branch).keys.map(Self.path))
            .union(state.deleted.map(Self.path))
        var newState = BranchState(branch: name, base: target, existsOnRemote: false, fetchedAt: .now)
        var edits: [String: String] = [:]
        for path in touched.sorted() {
            let mine = localText(path: path)
            let mineSHA = mine.map(GitBlob.sha)
            let theirs = target.files[path]
            if mineSHA == theirs { continue } // already the same on the new base
            if let mine { edits[Self.slug(path)] = mine } else { newState.deleted.append(Self.slug(path)) }
            if theirs != state.base.files[path] { // the new base changed it too
                newState.conflicts.append(Conflict(path: path, baseSHA: state.base.files[path], remoteSHA: theirs))
            }
        }
        for (slug, text) in edits { try store.saveWorking(text, slug: slug, branch: name) }
        try store.saveBranchState(newState)
        let moved = try SiteWorkspace(store: store, state: newState)
        try store.removeBranch(branch)
        return moved
    }

    /// Creates a branch on this device from this branch's base, moving the uncommitted edits to it.
    /// It is created on GitHub at the next sync. Refused while commits are queued, so they are never pushed twice.
    public func branchOff(_ name: String) throws -> SiteWorkspace {
        guard queue.isEmpty else { throw WorkspaceError.queuedCommits }
        guard store.branchState(named: name) == nil else { throw WorkspaceError.branchExists(name) }
        var newState = BranchState(branch: name, base: state.base, existsOnRemote: false, fetchedAt: state.fetchedAt)
        newState.fileDates = state.fileDates
        newState.deleted = state.deleted
        try store.saveBranchState(newState)
        for (slug, text) in store.working(branch) {
            try store.saveWorking(text, slug: slug, branch: name)
            try store.removeWorking(slug: slug, branch: branch)
        }
        state.deleted = []
        try store.saveBranchState(state)
        try rebuild()
        return try SiteWorkspace(store: store, state: newState)
    }

    // MARK: Rebuilding the displayed nodes from disk

    private func rebuild() throws {
        var committed: [String: String] = [:]
        for (path, sha) in state.base.files {
            guard let text = store.object(sha) else { throw WorkspaceError.missingObject(path) }
            committed[Self.slug(path)] = text
        }
        for qc in queue {
            for c in qc.changes { committed[Self.slug(c.path)] = c.content }
        }
        var display: [String: NodeFile] = [:]
        for (slug, text) in committed { display[slug] = try NodeFile(slug: slug, text: text) }
        for (slug, text) in store.working(branch) { display[slug] = try NodeFile(slug: slug, text: text) }
        for slug in state.deleted { display[slug] = nil }
        committedText = committed
        nodes = display
        try refreshDeleted()
    }

    /// Recomputes `deletedNodes` from uncommitted deletions and committed ones not yet published. Cheap; runs after
    /// every change so the list and the link flags stay current.
    private func refreshDeleted() throws {
        let committed = committedText, display = nodes
        // Committed deletions stay listed until the published branch no longer has the file (the deletion is live) or
        // the node exists again.
        if let pending = state.pendingDeletions {
            let kept = pending.filter { path in
                committed[Self.slug(path)] == nil && (state.publishedFiles.map { $0[path] != nil } ?? true)
            }
            if kept != pending { state.pendingDeletions = kept.isEmpty ? nil : kept; try store.saveBranchState(state) }
        }
        var gone: [String: NodeFile] = [:]
        for slug in state.deleted {
            if let text = committed[slug] { gone[slug] = try? NodeFile(slug: slug, text: text) }
        }
        for path in state.pendingDeletions ?? [] where display[Self.slug(path)] == nil {
            let sha = state.base.files[path] ?? state.publishedFiles?[path]
            if let text = sha.flatMap(store.object) { gone[Self.slug(path)] = try? NodeFile(slug: Self.slug(path), text: text) }
        }
        deletedNodes = gone
    }

    static func slug(_ path: String) -> String { String(path.dropFirst(nodesDir.count).dropLast(3)) }
    static func path(_ slug: String) -> String { "\(nodesDir)\(slug).md" }
}

public enum WorkspaceError: Error, Equatable, LocalizedError {
    case invalidSlug(String)
    case queuedCommits
    case branchExists(String)
    case missingObject(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidSlug(m): m
        case .queuedCommits: "This branch has commits waiting to be pushed. Sync first, then create the branch."
        case let .branchExists(name): "A branch named “\(name)” already exists on this device."
        case let .missingObject(path): "The local copy is missing the contents of \(path). Delete the branch's local copy and download it again."
        }
    }
}
