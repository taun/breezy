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
    /// Editor state files in base + queue, by slug, parsed (one that does not parse counts as empty).
    private var committedStates: [String: EditorState] = [:]
    /// Images added by queued commits, not pushed yet: site path ("/assets/…") -> blob sha.
    private var queuedAssets: [String: String] = [:]
    /// Each node's editor state: uncommitted if changed here, else committed. Read with `editorState(_:)`.
    public private(set) var editorStates: [String: EditorState] = [:]
    /// Slugs whose editor state changed in memory and is not on disk yet (cursor moves are written in batches).
    private var unsavedStates: Set<String> = []
    private var stateSaveTask: Task<Void, Never>?
    /// Bumped for a node whenever a sync brings in a new version of it or of its editor state, so an open editor
    /// shows the new content and state (issue #15).
    public private(set) var remoteRevision: [String: Int] = [:]
    public private(set) var isSyncing = false
    /// Counts images stored on the device, so an open preview showing a placeholder can try again.
    public private(set) var storedImages = 0

    public static let nodesDir = "src/nodes/"
    static let assetsDir = "src/assets/"

    public var branch: String { state.branch }
    /// The commit the local copy is based on.
    public var headSHA: String { state.base.commit }
    /// The branch's assets: pushed, queued and not yet committed.
    public var assetPaths: [String] {
        let added = Set(queuedAssets.keys).union(state.pendingAssets?.keys ?? [:].keys).subtracting(state.base.assets)
        return added.isEmpty ? state.base.assets : (state.base.assets + added).sorted()
    }
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
        return try SiteWorkspace(store: store, state: state) // images follow at the sync that comes next
    }

    /// The node files and assets at the branch head, downloading any file contents not already stored.
    static func fetchSnapshot(_ branch: String, client: GitHubClient, store: LocalStore, progress: Progress? = nil) async throws -> Snapshot {
        let head = try await client.headSHA(of: branch)
        return try await fetchSnapshot(commit: head, client: client, store: store, progress: progress)
    }

    static func fetchSnapshot(commit: String, client: GitHubClient, store: LocalStore, progress: Progress? = nil) async throws -> Snapshot {
        let entries = try await client.tree(ofCommit: commit)
        let nodeEntries = entries.filter(SitePath.isNodeEntry)
        let stateEntries = entries.filter(SitePath.isStateEntry)
        try await storeBlobs(of: nodeEntries + stateEntries, client: client, store: store, progress: progress)
        let assetSHAs = assetSHAs(entries)
        return Snapshot(commit: commit, files: Dictionary(uniqueKeysWithValues: nodeEntries.map { ($0.path, $0.sha) }),
                        assets: assetSHAs.keys.sorted(), assetSHAs: assetSHAs,
                        states: Dictionary(uniqueKeysWithValues: stateEntries.map { ($0.path, $0.sha) }))
    }

    /// Downloads the text of every entry not already on the device.
    private static func storeBlobs(of entries: [TreeEntry], client: GitHubClient, store: LocalStore, progress: Progress?) async throws {
        let missing = entries.filter { !store.hasObject($0.sha) }
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
    }

    /// Site path ("/assets/…") -> blob sha of every file under src/assets.
    static func assetSHAs(_ entries: [TreeEntry]) -> [String: String] {
        Dictionary(entries.filter { $0.isBlob && $0.path.hasPrefix(assetsDir) }.map { ("/" + $0.path.dropFirst("src/".count), $0.sha) }) { a, _ in a }
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

    /// Uncommitted drafts: editor state files whose draft differs from the committed one. A draft counts as a change by
    /// itself, so it can be committed and continued on another device; a moved cursor or another tab does not.
    public var draftChanges: [FileChange] {
        editorStates.keys.sorted().compactMap { slug in
            guard nodes[slug] != nil, editorState(slug).draftDiffers(from: committedState(slug)) else { return nil }
            return FileChange(path: SitePath.statePath(slug), content: editorState(slug).rendered())
        }
    }

    /// What a commit takes: the node changes and drafts, plus the editor state of every node they touch when it
    /// differs from the committed one (it rides along), and the deletion of a deleted node's state file.
    var commitChanges: [FileChange] {
        let nodeChanges = changes
        var slugs = Set(nodeChanges.compactMap { if case let .node(s)? = SitePath.kind($0.path) { s } else { nil } })
        slugs.formUnion(draftChanges.compactMap { if case let .state(s)? = SitePath.kind($0.path) { s } else { nil } })
        var out = nodeChanges
        for slug in slugs.sorted() {
            let path = SitePath.statePath(slug)
            if nodes[slug] == nil {
                if committedStates[slug] != nil { out.append(FileChange(path: path, content: nil)) }
            } else if editorState(slug) != committedState(slug) ?? EditorState() {
                out.append(FileChange(path: path, content: editorState(slug).rendered()))
            }
        }
        return out + usedPendingAssets.sorted { $0.key < $1.key }.map { site, sha in
            FileChange(path: SitePath.repoPath(site: site), content: nil, blobSHA: sha)
        }
    }

    /// The new images a commit takes: pending ones some node has as its header. A node using one counts as changed
    /// even when its text is not (a new picture at the path it already had). The others are dropped as soon as an
    /// edit stops using them (`persist`).
    private var usedPendingAssets: [String: String] {
        guard let pending = state.pendingAssets, !pending.isEmpty else { return [:] }
        return pending.filter { site, _ in nodes.values.contains { $0.header.uses(site) } }
    }

    private func usesPendingAsset(_ slug: String) -> Bool {
        guard let pending = state.pendingAssets, let header = nodes[slug]?.header else { return false }
        return pending.keys.contains(where: header.uses)
    }

    /// One row per node with something to commit: its file and/or its draft.
    public struct NodeChange: Equatable, Sendable, Identifiable {
        public enum File: Equatable, Sendable { case added, edited, deleted }
        public enum DraftChange: Equatable, Sendable { case started, updated, removed }
        public var slug: String
        public var file: File?
        public var draft: DraftChange?
        public var id: String { slug }
    }

    public var changedNodes: [NodeChange] {
        var rows: [String: NodeChange] = [:]
        for c in changes {
            let slug = Self.slug(c.path)
            rows[slug] = NodeChange(slug: slug, file: c.content == nil ? .deleted : committedText[slug] == nil ? .added : .edited)
        }
        for slug in nodes.keys where rows[slug] == nil && usesPendingAsset(slug) { rows[slug] = NodeChange(slug: slug, file: .edited) }
        for c in draftChanges {
            guard case let .state(slug)? = SitePath.kind(c.path) else { continue }
            let before = committedState(slug)?.draft, after = editorState(slug).draft
            rows[slug, default: NodeChange(slug: slug)].draft = before == nil ? .started : after == nil ? .removed : .updated
        }
        return rows.values.sorted { $0.slug < $1.slug }
    }

    public var hasChanges: Bool {
        !changes.isEmpty || editorStates.contains { nodes[$0.key] != nil && $0.value.draftDiffers(from: committedStates[$0.key]) }
            || !usedPendingAssets.isEmpty
    }

    /// Anything here that is not on GitHub: uncommitted edits or drafts, or queued commits.
    public var hasLocalChanges: Bool { hasChanges || !queue.isEmpty }

    /// A default commit message naming what the uncommitted changes do, e.g. "Add new-talk; Edit bowery; Delete a-theory".
    /// Each group lists up to three nodes, then "and N more".
    public var suggestedCommitMessage: String {
        var added: [String] = [], edited: [String] = [], deleted: [String] = [], drafts: [String] = []
        for row in changedNodes {
            switch row.file {
            case .added: added.append(row.slug)
            case .edited: edited.append(row.slug)
            case .deleted: deleted.append(row.slug)
            case nil: drafts.append(row.slug)
            }
        }
        func part(_ verb: String, _ slugs: [String]) -> String? {
            guard !slugs.isEmpty else { return nil }
            return "\(verb) " + slugs.prefix(3).joined(separator: ", ") + (slugs.count > 3 ? " and \(slugs.count - 3) more" : "")
        }
        return [part("Add", added), part("Edit", edited), part("Delete", deleted), part("Update draft of", drafts)]
            .compactMap { $0 }.joined(separator: "; ")
    }

    /// The branch was found deleted on GitHub while this copy had local changes; see `recreateOnGitHub` and `moveEdits`.
    public var isDeletedOnGitHub: Bool { state.deletedOnGitHubAt != nil }
    public func isModified(_ slug: String) -> Bool { committedText[slug] != nodes[slug]?.rendered() || usesPendingAsset(slug) }

    /// Text of a node in the base snapshot / GitHub's pending snapshot, for showing conflicts.
    public func text(sha: String?) -> String? { sha.flatMap(store.object) }

    /// The local version of a conflicted node path (nil: deleted locally).
    public func localText(path: String) -> String? { nodes[Self.slug(path)]?.rendered() }

    /// The two sides of a conflict as text to compare and merge: node files whole, editor state files by their draft.
    public func conflictSides(_ c: Conflict) -> (isDraft: Bool, mine: String?, theirs: String?) {
        if case let .state(slug)? = SitePath.kind(c.path) {
            return (true, editorState(slug).draft?.text, store.editorState(sha: c.remoteSHA)?.draft?.text)
        }
        return (false, localText(path: c.path), text(sha: c.remoteSHA))
    }

    // MARK: Editor state (tab, mode, cursor, draft)

    /// A node's editor state (empty for a node never opened anywhere).
    public func editorState(_ slug: String) -> EditorState { editorStates[slug] ?? EditorState() }

    /// The committed editor state (base + queue), nil if there is none.
    func committedState(_ slug: String) -> EditorState? { committedStates[slug] }

    /// Changes a node's tab, mode or cursor. Kept in memory at once and written to disk shortly after, so moving the
    /// cursor while typing does not write a file per keystroke; `flushEditorStates` writes them now.
    public func setEditor(_ slug: String, _ change: (inout EditorState) -> Void) {
        var s = editorState(slug)
        change(&s)
        guard s != editorState(slug) else { return }
        editorStates[slug] = s
        unsavedStates.insert(slug)
        stateSaveTask?.cancel()
        stateSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            try? self?.flushEditorStates()
        }
    }

    /// Sets (or with nil or "", removes) a node's body draft, saved at once like any edit. Starting a draft records
    /// the body it started from.
    public func setDraft(_ slug: String, _ text: String?) throws {
        var s = editorState(slug)
        if let text, !text.isEmpty {
            if s.draft == nil { s.draft = .init(text: text, base: EditorState.bodySHA(nodes[slug]?.body ?? "")) } else { s.draft?.text = text }
        } else {
            s.draft = nil
        }
        guard s != editorState(slug) else { return }
        editorStates[slug] = s
        try saveState(slug)
    }

    /// Whether the body changed since the draft was started (or last marked as seen).
    public func draftIsStale(_ slug: String) -> Bool {
        guard let base = editorState(slug).draft?.base, let body = nodes[slug]?.body else { return false }
        return base != EditorState.bodySHA(body)
    }

    /// Marks the current body as the one the draft is based on.
    public func rebaseDraft(_ slug: String) throws {
        guard editorState(slug).draft != nil, let body = nodes[slug]?.body else { return }
        editorStates[slug]?.draft?.base = EditorState.bodySHA(body)
        try saveState(slug)
    }

    /// Puts the committed draft back, keeping the tab, mode and cursor.
    public func revertDraft(_ slug: String) throws {
        var s = editorState(slug)
        s.draft = committedState(slug)?.draft
        guard s != editorState(slug) else { return }
        editorStates[slug] = s
        try saveState(slug)
    }

    /// Drops editor state writes still pending, for a copy that was just removed (it would be written again).
    public func cancelPendingStateWrites() {
        stateSaveTask?.cancel()
        stateSaveTask = nil
        unsavedStates = []
    }

    /// Writes editor state changes still held in memory. Call before the app goes to the background.
    public func flushEditorStates() throws {
        stateSaveTask?.cancel()
        stateSaveTask = nil
        for slug in unsavedStates.sorted() { try saveState(slug) }
    }

    /// Writes one node's uncommitted editor state, or removes it when it matches the committed one.
    private func saveState(_ slug: String) throws {
        unsavedStates.remove(slug)
        let s = editorState(slug)
        if s == committedState(slug) ?? EditorState() {
            try store.removeWorkingState(slug: slug, branch: branch)
        } else {
            try store.saveWorkingState(s.rendered(), slug: slug, branch: branch)
        }
    }

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
        if committedText[slug] == nil { try dropEditorState(slug) } // never committed: it cannot be undeleted
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
            // The committed deletion also removes its editor state file. Not pushed yet, the base still has it: put it
            // back, draft and all, as an uncommitted change that goes up with the node. Once the deletion is pushed
            // the draft is gone with it, like the node's unpublished edits.
            if editorStates[slug] == nil, let s = store.editorState(sha: state.base.states?[SitePath.statePath(slug)]) {
                editorStates[slug] = s
                try saveState(slug)
            }
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
        try dropNewPictures(of: slug, queued: false)
        if let text = committedText[slug] {
            nodes[slug] = try NodeFile(slug: slug, text: text)
        } else {
            nodes[slug] = nil // an added node: its editor state goes with it
            try dropEditorState(slug)
        }
        try persist(slug)
    }

    /// Forgets a node's uncommitted editor state (its node is going away without ever having been committed).
    private func dropEditorState(_ slug: String) throws {
        editorStates[slug] = committedState(slug)
        unsavedStates.remove(slug)
        try store.removeWorkingState(slug: slug, branch: branch)
    }

    /// Reverts every node and draft.
    public func revertAll() throws {
        for slug in Set(nodes.keys).union(committedText.keys) { try revert(slug) }
        for slug in Array(editorStates.keys) { try revertDraft(slug) }
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
        // A new picture this edit stopped using (another file chosen, the header removed, the node deleted, a .png
        // banner in place of a .jpg) is no longer a change; left pending, the branch would count as changed for good.
        if state.pendingAssets != nil { try dropUnusedPendingAssets() }
    }

    // MARK: Committing (works offline)

    /// Turns the uncommitted changes into a queued commit; `sync` pushes it.
    public func commit(message: String) throws {
        try flushEditorStates()
        let pending = commitChanges
        guard !pending.isEmpty else { return }
        queue.append(QueuedCommit(message: message, changes: pending))
        try store.saveQueue(queue, for: branch)
        let deletedPaths = pending.filter { $0.content == nil && Self.isNodePath($0.path) }.map(\.path)
        if !deletedPaths.isEmpty { state.pendingDeletions = Array(Set((state.pendingDeletions ?? []) + deletedPaths)).sorted() }
        for c in pending {
            switch SitePath.kind(c.path) {
            case let .node(slug)?:
                try store.removeWorking(slug: slug, branch: branch)
                if c.content == nil { try store.removeWorkingState(slug: slug, branch: branch) } // never committed
            case let .state(slug)?: try store.removeWorkingState(slug: slug, branch: branch)
            case nil: break
            }
        }
        state.deleted = []
        state.pendingAssets = nil // the ones used went into the commit; the rest were left over
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
        try flushEditorStates()
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
        // A copy saved before editor state files were synced (no `states` in its base) compares GitHub's with none, even
        // when GitHub has not moved: its states then arrive like any GitHub change, merged with this device's or
        // reported as draft conflicts, before anything made without them is pushed over them.
        if head != state.base.commit || state.base.states == nil {
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
            for c in next.changes {
                if let sha = c.blobSHA {
                    guard let data = store.objectData(sha), GitBlob.sha(of: data) == sha else { throw WorkspaceError.missingObject(c.path) }
                    // A different sha would leave the tree pointing at a blob GitHub does not have.
                    guard try await client.createBlob(data) == sha else { throw GitHubError.invalidResponse }
                }
            }
            let newHead = try await client.commit(next.changes, message: next.message, to: branch, expectedHead: state.base.commit)
            var base = state.base
            for c in next.changes {
                if let sha = c.blobSHA { base.applyAsset(c.path, sha: sha) } else { base.apply(c.path, sha: try c.content.map { try store.storeObject($0) }) }
            }
            base.commit = newHead
            for c in next.changes where Self.isNodePath(c.path) { state.fileDates = (state.fileDates ?? [:]).merging([c.path: .now]) { $1 } }
            state.base = base
            queue.removeFirst()
            // Queue first: if the app stops between the two writes, a commit is never pushed twice.
            try store.saveQueue(queue, for: branch)
            try store.saveBranchState(state)
            pushed += 1
        }
        await fillMissingFileDates(client: client)
        await fillMissingAssetSHAs(client: client)
        await prefetchImages(client: client)
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
        state.publishedFiles = Dictionary(uniqueKeysWithValues: entries.filter(SitePath.isNodeEntry).map { ($0.path, $0.sha) })
        state.publishedCommit = head
    }

    static func isNodePath(_ path: String) -> Bool { if case .node? = SitePath.kind(path) { true } else { false } }

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

    // MARK: Images

    /// The blob sha of an image the preview shows, by its site path ("/assets/…"), or nil if this branch has no such
    /// asset (or the copy predates asset shas and has not synced since).
    public func assetSHA(_ path: String) -> String? {
        let site = MarkdownImage.sitePath(path)
        return state.pendingAssets?[site] ?? queuedAssets[site] ?? state.base.assetSHAs?[site]
    }

    /// Makes a node's banner (and, with `makeThumbnail`, its bookshelf thumbnail) from a picture: both are fitted to
    /// the site's boxes, kept as new assets named after the node, and written into its `header`. Without a thumbnail
    /// the node's existing one stays. Nothing changes if the bytes are not an image. Works offline.
    public func setHeaderImage(slug: String, from data: Data, makeThumbnail: Bool = true) throws {
        guard var node = nodes[slug] else { return }
        let banner = try ImageResizer.resize(data, fitting: ImageResizer.headerBox)
        let small = makeThumbnail ? try ImageResizer.resize(data, fitting: ImageResizer.teaserBox) : nil
        let image = HeaderImages.sitePath(slug: slug, teaser: false, fileExtension: banner.fileExtension)
        let teaser = small.map { HeaderImages.sitePath(slug: slug, teaser: true, fileExtension: $0.fileExtension) } ?? node.header.teaser
        // The header first: one Breezy cannot rewrite throws before any picture is kept.
        try node.setHeader(image: image, teaser: teaser)
        try addAsset(banner.data, at: image)
        if let small, let teaser { try addAsset(small.data, at: teaser) }
        try update(slug) { $0 = node }
    }

    /// Takes the banner and thumbnail off a node. The files stay in the site (another node may use them).
    public func removeHeaderImage(slug: String) throws {
        try update(slug) { try $0.setHeader(image: nil, teaser: nil) }
    }

    /// Adds an image to the branch at a site path ("/assets/images/name.jpg"): kept on the device, and committed
    /// with the next commit if a node has it as its header (`setHeaderImage`). Replaces any image at that path. Works offline.
    public func addAsset(_ data: Data, at path: String) throws {
        let site = MarkdownImage.sitePath(path)
        guard site.hasPrefix("/assets/"), !site.contains("..") else { throw WorkspaceError.invalidAssetPath(path) }
        let sha = GitBlob.sha(of: data)
        try store.storeObjectData(data, sha: sha)
        var pending = state.pendingAssets ?? [:]
        // The same picture the branch already has there is no change.
        pending[site] = sha == (queuedAssets[site] ?? state.base.assetSHAs?[site]) ? nil : sha
        state.pendingAssets = pending.isEmpty ? nil : pending
        try store.saveBranchState(state)
        storedImages += 1
    }

    /// Forgets new images no node uses any more.
    private func dropUnusedPendingAssets() throws {
        let used = usedPendingAssets
        try dropPendingAssets { used[$0] == nil }
    }

    private func dropPendingAssets(where drop: (String) -> Bool) throws {
        guard let pending = state.pendingAssets else { return }
        let kept = pending.filter { !drop($0.key) }
        guard kept.count != pending.count else { return }
        state.pendingAssets = kept.isEmpty ? nil : kept
        try store.saveBranchState(state)
        storedImages += 1 // a preview showing a dropped picture goes back to the branch's
    }

    /// Whether the path names an asset on this branch (as far as this copy knows).
    public func hasAsset(_ path: String) -> Bool { assetSHA(path) != nil || state.base.assetSHAs == nil }

    /// The image's bytes if they are on this device. Works offline.
    public func imageData(_ path: String) -> Data? { assetSHA(path).flatMap(store.objectData) }

    /// The image's bytes, downloading and keeping them if they are not on this device yet. nil if not an asset here.
    public func loadImage(_ path: String, client: GitHubClient) async throws -> Data? {
        guard let sha = assetSHA(path) else { return nil }
        if let data = store.objectData(sha) { return data }
        let data = try await client.blobData(sha)
        try store.storeObjectData(data, sha: sha)
        storedImages += 1
        return data
    }

    /// Downloads every image the nodes show that is not on this device yet, so previews work offline. Only the
    /// referenced ones: the site's assets folder is much larger. Best effort, four at a time; misses are tried again.
    func prefetchImages(client: GitHubClient) async {
        // Deleted nodes too: their last content is still previewed (DeletedNodeView).
        let bodies = nodes.values.map(\.body) + deletedNodes.values.map(\.body)
        let shas = Set(bodies.flatMap(MarkdownImage.shown).compactMap { assetSHA($0.src) })
            .filter { !store.hasObject($0) }.sorted()
        var index = 0
        while index < shas.count {
            let chunk = shas[index..<min(index + 4, shas.count)]
            index += chunk.count
            await withTaskGroup(of: (String, Data?).self) { group in
                for sha in chunk { group.addTask { (sha, try? await client.blobData(sha)) } }
                for await (sha, data) in group {
                    if let data, (try? store.storeObjectData(data, sha: sha)) != nil { storedImages += 1 }
                }
            }
        }
    }

    /// Copies saved before assets had shas get them from the base commit's tree (one request), once.
    func fillMissingAssetSHAs(client: GitHubClient) async {
        guard state.base.assetSHAs == nil, let entries = try? await client.tree(ofCommit: state.base.commit) else { return }
        state.base.assetSHAs = Self.assetSHAs(entries)
        try? store.saveBranchState(state)
    }

    /// Paths GitHub changed since the base that were also changed here (queued, edited or deleted).
    func conflicts(with remote: Snapshot) -> [Conflict] {
        let touched = Set(queue.flatMap { $0.changes.map(\.path) })
            .union(store.working(branch).keys.map(Self.path))
            .union(state.deleted.map(Self.path))
        // Nodes with a draft here (uncommitted or queued): deleting one on GitHub would silently take the draft along.
        let drafted = Set((draftChanges.map(\.path) + queue.flatMap(\.changes).map(\.path)).compactMap { path -> String? in
            if case let .state(slug)? = SitePath.kind(path) { Self.path(slug) } else { nil }
        })
        let nodeConflicts = Set(state.base.files.keys).union(remote.files.keys).sorted().compactMap { path -> Conflict? in
            let b = state.base.files[path], r = remote.files[path]
            guard b != r, touched.contains(path) || (r == nil && drafted.contains(path)) else { return nil }
            // Same result on both sides is not a conflict.
            if r == localText(path: path).map(GitBlob.sha) { return nil }
            return Conflict(path: path, baseSHA: b, remoteSHA: r)
        }
        // Editor state: only a draft changed differently on both sides; the tab, mode and cursor are merged silently.
        let baseStates = state.base.states ?? [:], remoteStates = remote.states ?? [:]
        let stateConflicts = Set(baseStates.keys).union(remoteStates.keys).sorted().compactMap { path -> Conflict? in
            let b = baseStates[path], r = remoteStates[path]
            guard b != r, case let .state(slug)? = SitePath.kind(path) else { return nil }
            let base = store.editorState(sha: b), theirs = store.editorState(sha: r)
            // The queued versions count too: a working state can undo a queued draft (discarded after committing).
            let queued = queue.flatMap(\.changes).filter { $0.path == path }.compactMap { $0.content.flatMap(EditorState.init(json:)) }
            let local = [editorState(slug)] + queued
            guard local.contains(where: { EditorState.merge(base: base, local: $0, remote: theirs) == .draftConflict }) else { return nil }
            return Conflict(path: path, baseSHA: b, remoteSHA: r)
        }
        return nodeConflicts + stateConflicts
    }

    /// Makes GitHub's snapshot the new base. Local queued and working changes stay on top of it.
    /// Editor state files GitHub changed are merged with this device's (EditorState.merge); a node whose content
    /// changed without a newer state opens on its new content (issue #15). Both bump `remoteRevision`.
    private func adopt(_ remote: Snapshot) throws {
        try flushEditorStates()
        let before = nodes.mapValues { $0.rendered() }
        let arrived = try carryStates(from: state.base.states ?? [:], to: remote.states ?? [:])
        // Files GitHub changed get their dates fetched again at the end of this sync.
        for (path, sha) in remote.files where state.base.files[path] != sha { state.fileDates?[path] = nil }
        state.base = remote
        state.pendingRemote = nil
        state.conflicts = []
        try store.saveBranchState(state)
        try rebuild()
        // GitHub's version of a node (or its deletion) can leave a new picture here that no node uses.
        if state.pendingAssets != nil { try dropUnusedPendingAssets() }
        // A node gone from GitHub takes its uncommitted editor state with it (a draft on it was a conflict, settled).
        for slug in store.workingStates(branch).keys where nodes[slug] == nil && !state.deleted.contains(slug) {
            try dropEditorState(slug)
        }
        for (slug, node) in nodes where node.rendered() != before[slug] {
            if !arrived.contains(slug) {
                editorStates[slug] = EditorState.afterRemoteChange(body: node.body, keeping: editorStates[slug])
                try saveState(slug)
            }
            remoteRevision[slug, default: 0] += 1
        }
        for slug in arrived where nodes[slug]?.rendered() == before[slug] { remoteRevision[slug, default: 0] += 1 }
    }

    /// Puts this device's queued and working editor states on top of GitHub's state files (`old` -> `new`), merging
    /// each with what changed under it (EditorState.merge). Returns the slugs whose state file changed. Run before
    /// `new` becomes the base.
    private func carryStates(from old: [String: String], to new: [String: String]) throws -> Set<String> {
        let working = store.workingStates(branch)
        var arrived: Set<String> = []
        var queueChanged = false
        for path in Set(old.keys).union(new.keys) where old[path] != new[path] {
            guard case let .state(slug)? = SitePath.kind(path) else { continue }
            arrived.insert(slug)
            let base = store.editorState(sha: old[path]), theirs = store.editorState(sha: new[path])
            // Queued versions were made on top of the old base: merge GitHub's draft into them, or pushing them would
            // put back the old one.
            for i in queue.indices {
                for j in queue[i].changes.indices where queue[i].changes[j].path == path {
                    guard let text = queue[i].changes[j].content, let mine = EditorState(json: text),
                          case let .merged(m) = EditorState.merge(base: base, local: mine, remote: theirs) else { continue }
                    queue[i].changes[j].content = m.rendered()
                    queueChanged = true
                }
            }
            guard let text = working[slug], let mine = EditorState(json: text) else { continue }
            // The working state was made on base + queue, and lies on the last queued version (merged above) or on
            // GitHub's after this sync. Compared with the base alone, a queued draft discarded here would come back.
            let below = committedStates[slug]
            let newBelow = queue.flatMap(\.changes).last { $0.path == path }.map { $0.content.flatMap(EditorState.init(json:)) } ?? theirs
            if !mine.draftDiffers(from: below) {
                try store.removeWorkingState(slug: slug, branch: branch) // nothing of value here: what is below applies
            } else if case let .merged(m) = EditorState.merge(base: below, local: mine, remote: newBelow) {
                try store.saveWorkingState(m.rendered(), slug: slug, branch: branch)
            } // a draft conflict settled as "keep mine" keeps the local draft
        }
        if queueChanged { try store.saveQueue(queue, for: branch) }
        return arrived
    }

    /// Settles one conflicted file. When the last one is settled, GitHub's snapshot becomes the base; sync again to push.
    public func resolve(_ path: String, with resolution: ConflictResolution) throws {
        guard state.conflicts.contains(where: { $0.path == path }) else { return }
        try flushEditorStates()
        switch (SitePath.kind(path), resolution) {
        case let (.node(slug)?, .mine):
            // A node kept for its draft alone (deleted on GitHub, otherwise unchanged here) is put back as an edit.
            if let text = localText(path: path), store.working(branch)[slug] == nil,
               !queue.contains(where: { $0.changes.contains { $0.path == path } }) {
                try store.saveWorking(text, slug: slug, branch: branch)
            }
        case (_, .mine), (nil, _):
            break
        case let (.node(slug)?, .theirs):
            try dropNewPictures(of: slug, queued: true)
            try dropQueued(path)
            try store.removeWorking(slug: slug, branch: branch)
            state.deleted.removeAll { $0 == slug }
            if conflicts.first(where: { $0.path == path })?.remoteSHA == nil { // gone from GitHub: its draft goes too
                try dropQueued(SitePath.statePath(slug))
                try dropEditorState(slug)
            }
        case let (.node(slug)?, .edited(text)):
            try store.saveWorking(text, slug: slug, branch: branch)
            state.deleted.removeAll { $0 == slug }
        case let (.state(slug)?, .theirs):
            try dropQueued(path)
            try store.removeWorkingState(slug: slug, branch: branch)
        case let (.state(slug)?, .edited(text)):
            // The merged draft becomes this device's; the adopt below keeps it over GitHub's.
            var s = editorState(slug)
            if text.isEmpty { s.draft = nil } else { var d = s.draft ?? .init(text: text, base: nil); d.text = text; s.draft = d }
            try store.saveWorkingState(s.rendered(), slug: slug, branch: branch)
        }
        state.conflicts.removeAll { $0.path == path }
        if state.conflicts.isEmpty, let remote = state.pendingRemote {
            try adopt(remote)
        } else {
            try store.saveBranchState(state)
            try rebuild()
            if state.pendingAssets != nil { try dropUnusedPendingAssets() } // as in adopt
        }
    }

    /// Removes a path from every queued commit, dropping commits left empty.
    private func dropQueued(_ path: String) throws {
        for i in queue.indices { queue[i].changes.removeAll { $0.path == path } }
        queue.removeAll { $0.changes.isEmpty }
        try store.saveQueue(queue, for: branch)
    }

    /// Forgets the new pictures this node uses and no other node does: the uncommitted ones, and with `queued` the
    /// queued ones too. For Revert and Use GitHub's: a replaced picture keeps its path, so the node's text going back
    /// would not take it along. "Uses" covers the node as shown and its queued versions (a queued one may be about to
    /// be dropped, or still be pushed for another node).
    private func dropNewPictures(of slug: String, queued: Bool) throws {
        let path = Self.path(slug)
        let queuedNodes = queue.flatMap(\.changes).filter { $0.blobSHA == nil && Self.isNodePath($0.path) }
        let mine = queuedNodes.filter { $0.path == path }.compactMap(\.content)
        let theirs = queuedNodes.filter { $0.path != path }.compactMap(\.content)
        let header = nodes[slug]?.header
        let others = nodes.filter { $0.key != slug }.values.map(\.header)
        let only = { (site: String) in
            (header?.uses(site) == true || mine.contains { $0.contains(site) })
                && !others.contains { $0.uses(site) } && !theirs.contains { $0.contains(site) }
        }
        try dropPendingAssets(where: only)
        guard queued else { return }
        let before = queue
        for i in queue.indices { queue[i].changes.removeAll { $0.blobSHA != nil && only(SitePath.sitePath(repo: $0.path)) } }
        queue.removeAll { $0.changes.isEmpty }
        if queue != before { try store.saveQueue(queue, for: branch) }
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
        try flushEditorStates()
        let target = try await Self.fetchSnapshot(base, client: client, store: store, progress: progress)
        let touched = Set(queue.flatMap { $0.changes.map(\.path) }.filter(Self.isNodePath))
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
        // Images added here (queued or not) go along unless the new base has the same file.
        let carried = (state.pendingAssets ?? [:]).merging(queuedAssets) { mine, _ in mine }.filter { target.assetSHAs?[$0.key] != $0.value }
        newState.pendingAssets = carried.isEmpty ? nil : carried
        // Drafts not on GitHub go along too (the tab and cursor of other nodes do not).
        for (slug, mine) in editorStates where nodes[slug] != nil {
            let path = SitePath.statePath(slug)
            let old = store.editorState(sha: state.base.states?[path])
            guard mine.draftDiffers(from: old) else { continue }
            try store.saveWorkingState(mine.rendered(), slug: slug, branch: name)
            let nodePath = Self.path(slug)
            if target.files[nodePath] == nil, edits[slug] == nil, let text = localText(path: nodePath) {
                // The new base deleted the node: it goes along for its draft, a conflict to settle (as in sync).
                try store.saveWorking(text, slug: slug, branch: name)
                newState.conflicts.append(Conflict(path: nodePath, baseSHA: state.base.files[nodePath], remoteSHA: nil))
            }
            let theirsSHA = target.states?[path]
            let theirs = store.editorState(sha: theirsSHA)
            if EditorState.merge(base: old, local: mine, remote: theirs) == .draftConflict {
                newState.conflicts.append(Conflict(path: path, baseSHA: state.base.states?[path], remoteSHA: theirsSHA))
            }
        }
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
        try flushEditorStates()
        var newState = BranchState(branch: name, base: state.base, existsOnRemote: false, fetchedAt: state.fetchedAt)
        newState.fileDates = state.fileDates
        newState.deleted = state.deleted
        newState.pendingAssets = state.pendingAssets
        try store.saveBranchState(newState)
        for (slug, text) in store.working(branch) {
            try store.saveWorking(text, slug: slug, branch: name)
            try store.removeWorking(slug: slug, branch: branch)
        }
        for (slug, text) in store.workingStates(branch) {
            try store.saveWorkingState(text, slug: slug, branch: name)
            try store.removeWorkingState(slug: slug, branch: branch)
        }
        state.deleted = []
        state.pendingAssets = nil
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
        var states: [String: String] = [:]
        for (path, sha) in state.base.states ?? [:] {
            if case let .state(slug)? = SitePath.kind(path), let text = store.object(sha) { states[slug] = text }
        }
        var assets: [String: String] = [:]
        for qc in queue {
            for c in qc.changes {
                if let sha = c.blobSHA { assets[SitePath.sitePath(repo: c.path)] = sha; continue }
                switch SitePath.kind(c.path) {
                case let .node(slug)?: committed[slug] = c.content
                case let .state(slug)?: states[slug] = c.content
                case nil: break // not a file this app tracks
                }
            }
        }
        queuedAssets = assets
        var display: [String: NodeFile] = [:]
        for (slug, text) in committed { display[slug] = try NodeFile(slug: slug, text: text) }
        for (slug, text) in store.working(branch) { display[slug] = try NodeFile(slug: slug, text: text) }
        for slug in state.deleted { display[slug] = nil }
        let parsed = states.mapValues { EditorState(json: $0) ?? EditorState() }
        var editor = parsed
        for (slug, text) in store.workingStates(branch) { if let s = EditorState(json: text) { editor[slug] = s } }
        // Changes not written yet stay (rebuilds happen while the cursor-move batch is pending).
        for slug in unsavedStates { editor[slug] = editorStates[slug] }
        committedText = committed
        committedStates = parsed
        editorStates = editor
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
    case invalidAssetPath(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidSlug(m): m
        case .queuedCommits: "This branch has commits waiting to be pushed. Sync first, then create the branch."
        case let .branchExists(name): "A branch named “\(name)” already exists on this device."
        case let .invalidAssetPath(path): "“\(path)” is not a place for images. Images go under /assets/."
        case let .missingObject(path): "The local copy is missing the contents of \(path). Delete the branch's local copy and download it again."
        }
    }
}
