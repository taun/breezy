import Foundation
import Testing
@testable import BreezyKit
import BreezyKitTestSupport

/// A throwaway LocalStore per test.
func tempStore() -> LocalStore {
    LocalStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("breezy-tests-\(UUID().uuidString)"))
}

func client(_ m: MockTransport) -> GitHubClient { GitHubClient(repo: RepoRef(owner: "o", name: "r"), token: "t", transport: m) }

@Suite struct StorageTests {
    @Test func blobShaMatchesGit() {
        // `printf hello | git hash-object --stdin`
        #expect(GitBlob.sha(of: "hello") == "b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0")
    }

    @Test func branchFoldersKeepSlashesInOneFolder() {
        #expect(LocalStore.folderName("feature/new edit") == "feature%2Fnew%20edit")
    }
}

@MainActor @Suite struct WorkspaceTests {
    @Test func downloadedBranchOpensOfflineWithEditsAfterRelaunch() async throws {
        let store = tempStore()
        let ws = try await SiteWorkspace.download("main", client: client(.site()), store: store)
        #expect(ws.slugs == ["a", "b"])
        #expect(ws.assetPaths == ["/assets/images/x.png"])
        try ws.update("a") { try $0.setTitle("A2") }
        try ws.deleteNode("b")
        try ws.createNode(slug: "new-one", title: "New", type: "talk")

        // "Relaunch" with no network at all: everything comes from disk.
        let reopened = try #require(try SiteWorkspace.open("main", store: store))
        #expect(reopened.nodes["a"]?.title == "A2")
        #expect(reopened.nodes["b"] == nil)
        #expect(reopened.nodes["new-one"]?.type == "talk")
        #expect(reopened.changes.map(\.path) == ["src/nodes/a.md", "src/nodes/b.md", "src/nodes/new-one.md"])
        #expect(store.cachedBranches() == ["main"])
    }

    @Test func offlineCommitsQueueAndPushInOrderAsSeparateCommits() async throws {
        let store = tempStore()
        let m = MockTransport.site()
        let ws = try await SiteWorkspace.download("main", client: client(m), store: store)
        for (i, title) in ["One", "Two", "Three"].enumerated() {
            try ws.update("a") { try $0.setTitle(title) }
            try ws.commit(message: "Commit \(i + 1)")
        }
        #expect(ws.queue.count == 3)
        #expect(!ws.hasChanges)
        #expect(try SiteWorkspace.open("main", store: store)?.queue.count == 3) // survives relaunch

        m.acceptCommits()
        let result = try await ws.sync(client: client(m))
        #expect(result == .synced(pushed: 3))
        #expect(m.bodies("POST /git/commits").map { $0["message"] as? String } == ["Commit 1", "Commit 2", "Commit 3"])
        #expect(m.bodies("POST /git/commits").map { $0["parents"] as? [String] } == [["c1"], ["c2"], ["c3"]])
        #expect(ws.queue.isEmpty && ws.headSHA == "c4")
        #expect(ws.nodes["a"]?.title == "Three")
        // The new base is stored locally, so reopening offline shows the pushed state with nothing pending.
        let reopened = try #require(try SiteWorkspace.open("main", store: store))
        #expect(reopened.headSHA == "c4" && reopened.queue.isEmpty && !reopened.hasChanges)
    }

    @Test func untouchedFilesChangedOnGitHubAreTakenSilently() async throws {
        let store = tempStore()
        let m = MockTransport.site()
        let ws = try await SiteWorkspace.download("main", client: client(m), store: store)
        try ws.update("a") { try $0.setTitle("Local A") }
        try ws.commit(message: "Edit A")
        // GitHub moved on: b changed there, a did not.
        let newB = "---\ntitle: \"B remote\"\ntype: company\nlinks: []\n---\n"
        m.remoteMoves(to: "c9", changing: ["src/nodes/b.md": newB])
        m.acceptCommits(startingAt: "c9")
        let result = try await ws.sync(client: client(m))
        #expect(result == .synced(pushed: 1))
        #expect(ws.nodes["b"]?.title == "B remote")
        #expect(ws.nodes["a"]?.title == "Local A")
        #expect(m.bodies("POST /git/commits").first?["parents"] as? [String] == ["c9"])
    }

    @Test func fileChangedOnBothSidesIsAConflictResolvedFileByFile() async throws {
        let store = tempStore()
        let m = MockTransport.site()
        let ws = try await SiteWorkspace.download("main", client: client(m), store: store)
        try ws.update("a") { try $0.setTitle("Mine A") }
        try ws.update("b") { try $0.setTitle("Mine B") }
        try ws.commit(message: "Local edits")
        m.remoteMoves(to: "c9", changing: [
            "src/nodes/a.md": "---\ntitle: \"Theirs A\"\ntype: person\nlinks: []\n---\n",
            "src/nodes/b.md": "---\ntitle: \"Theirs B\"\ntype: company\nlinks: []\n---\n",
        ])
        #expect(try await ws.sync(client: client(m)) == .conflicts(2))
        #expect(ws.conflicts.map(\.path) == ["src/nodes/a.md", "src/nodes/b.md"])
        #expect(m.count("POST /git/commits") == 0) // nothing pushed while conflicted
        #expect(try SiteWorkspace.open("main", store: store)?.conflicts.count == 2) // survives relaunch

        let theirsA = try #require(ws.text(sha: ws.conflicts[0].remoteSHA))
        #expect(theirsA.contains("Theirs A"))
        try ws.resolve("src/nodes/a.md", with: .theirs)
        try ws.resolve("src/nodes/b.md", with: .mine)
        #expect(ws.conflicts.isEmpty)
        #expect(ws.headSHA == "c9")
        #expect(ws.nodes["a"]?.title == "Theirs A")
        #expect(ws.nodes["b"]?.title == "Mine B")

        m.acceptCommits(startingAt: "c9")
        #expect(try await ws.sync(client: client(m)) == .synced(pushed: 1))
        let pushed = try #require(m.bodies("POST /git/trees").first?["tree"] as? [[String: Any]])
        #expect(pushed.map { $0["path"] as? String } == ["src/nodes/b.md"]) // a's local change was dropped
    }

    @Test func editedResolutionBecomesAnUncommittedEdit() async throws {
        let store = tempStore()
        let m = MockTransport.site()
        let ws = try await SiteWorkspace.download("main", client: client(m), store: store)
        try ws.update("a") { try $0.setTitle("Mine A") }
        m.remoteMoves(to: "c9", changing: ["src/nodes/a.md": "---\ntitle: \"Theirs A\"\ntype: person\nlinks: []\n---\n"])
        #expect(try await ws.sync(client: client(m)) == .conflicts(1))
        try ws.resolve("src/nodes/a.md", with: .edited("---\ntitle: \"Merged A\"\ntype: person\nlinks: []\n---\n"))
        #expect(ws.nodes["a"]?.title == "Merged A")
        #expect(ws.changes.map(\.path) == ["src/nodes/a.md"])
        #expect(ws.headSHA == "c9")
    }

    @Test func branchCreatedOfflineCarriesEditsAndIsCreatedOnGitHubAtSync() async throws {
        let store = tempStore()
        let m = MockTransport.site()
        let main = try await SiteWorkspace.download("main", client: client(m), store: store)
        try main.update("a") { try $0.setTitle("On branch") }
        let feature = try main.branchOff("feature/x")
        #expect(!main.hasChanges)
        #expect(feature.nodes["a"]?.title == "On branch")
        #expect(store.cachedBranches() == ["feature/x", "main"])

        try feature.commit(message: "Branch edit")
        #expect(throws: WorkspaceError.queuedCommits) { _ = try feature.branchOff("other") }
        m.on("POST /git/refs", status: 201, ["ref": "refs/heads/feature/x"])
        m.on("GET /git/ref/heads/feature/x", ["object": ["sha": "c1"]])
        m.on("POST /git/trees", ["sha": "t2"])
        m.on("POST /git/commits", ["sha": "c2"])
        m.on("PATCH /git/refs/heads/feature/x", ["object": ["sha": "c2"]])
        #expect(try await feature.sync(client: client(m)) == .synced(pushed: 1))
        #expect(m.bodies("POST /git/refs").first?["sha"] as? String == "c1")
        #expect(feature.state.existsOnRemote)
    }

    @Test func revertAndValidation() async throws {
        let ws = try await SiteWorkspace.download("main", client: client(.site()), store: tempStore())
        try ws.update("a") { try $0.setString("video", "https://youtu.be/abc?si=1") }
        #expect(ws.isModified("a"))
        try ws.revert("a")
        #expect(!ws.hasChanges)
        try ws.deleteNode("b")
        #expect(ws.issues(for: "a").contains { $0.message.contains("deleted node \"b\"") }) // a link to a node deleted here
        #expect(throws: WorkspaceError.self) { try ws.createNode(slug: "a", title: "dup", type: "x") }
    }
}

/// A branch published and deleted on another device: GitHub answers 404 for it.
@MainActor @Suite struct DeletedBranchTests {
    /// Downloads "edit" (same files as the site fixture's main) into a fresh store.
    func editBranch() async throws -> (SiteWorkspace, MockTransport, LocalStore) {
        let m = MockTransport.site()
        m.on("GET /git/ref/heads/edit", ["object": ["sha": "c1"]])
        let store = tempStore()
        let ws = try await SiteWorkspace.download("edit", client: client(m), store: store)
        m.on("GET /git/ref/heads/edit", status: 404, ["message": "Not Found"]) // now deleted
        return (ws, m, store)
    }

    @Test func headOfMissingBranchIsBranchNotFound() async {
        await #expect(throws: GitHubError.branchNotFound("gone")) { _ = try await client(MockTransport()).headSHA(of: "gone") }
    }

    @Test func deletedWithoutLocalChangesIsReportedAndCanBeDropped() async throws {
        let (ws, _, store) = try await editBranch()
        #expect(try await ws.sync(client: client(MockTransport())) == .branchDeleted(hasLocalChanges: false))
        #expect(!ws.isDeletedOnGitHub) // nothing to keep, so no lasting mark
        #expect(!store.hasLocalChanges("edit"))
    }

    @Test func deletedWithQueuedCommitsCanBeRecreatedAndPushed() async throws {
        let (ws, m, store) = try await editBranch()
        try ws.update("a") { try $0.setTitle("Late edit") }
        try ws.commit(message: "Late edit")
        #expect(try await ws.sync(client: client(m)) == .branchDeleted(hasLocalChanges: true))
        #expect(ws.isDeletedOnGitHub)
        #expect(try SiteWorkspace.open("edit", store: store)?.isDeletedOnGitHub == true) // survives relaunch
        #expect(store.hasLocalChanges("edit"))

        try ws.recreateOnGitHub()
        m.on("POST /git/refs", status: 201, ["ref": "refs/heads/edit"])
        m.on("GET /git/ref/heads/edit", ["object": ["sha": "c1"]])
        m.on("POST /git/trees", ["sha": "t2"])
        m.on("POST /git/commits", ["sha": "c2"])
        m.on("PATCH /git/refs/heads/edit", ["object": ["sha": "c2"]])
        #expect(try await ws.sync(client: client(m)) == .synced(pushed: 1))
        #expect(m.bodies("POST /git/refs").first?["sha"] as? String == "c1") // recreated at the copy's base
        #expect(!ws.isDeletedOnGitHub)
    }

    @Test func editsMoveOntoNewBranchFromMainWithConflictsForFilesMainChangedToo() async throws {
        let (ws, m, store) = try await editBranch()
        try ws.update("a") { try $0.setTitle("Mine A") }     // main also changes a, differently -> conflict
        try ws.update("b") { try $0.setTitle("Published B") } // main has exactly this already -> nothing to move
        let publishedB = try #require(ws.nodes["b"]).rendered()
        try ws.commit(message: "Edits")
        try ws.createNode(slug: "new-one", title: "New", type: "talk") // only here -> moves cleanly
        #expect(try await ws.sync(client: client(m)) == .branchDeleted(hasLocalChanges: true))

        m.remoteMoves(to: "c9", changing: [
            "src/nodes/a.md": "---\ntitle: \"Main A\"\ntype: person\nlinks: []\n---\n",
            "src/nodes/b.md": publishedB,
        ])
        let moved = try await ws.moveEdits(toNewBranch: "edit-2", from: "main", client: client(m))
        #expect(moved.branch == "edit-2" && !moved.state.existsOnRemote && moved.headSHA == "c9")
        #expect(moved.conflicts.map(\.path) == ["src/nodes/a.md"])
        #expect(moved.nodes["a"]?.title == "Mine A")
        #expect(moved.nodes["new-one"]?.title == "New")
        #expect(moved.changes.map(\.path) == ["src/nodes/a.md", "src/nodes/new-one.md"])
        #expect(store.branchState(named: "edit") == nil) // old copy removed
        #expect(store.cachedBranches() == ["edit-2"])

        try moved.resolve("src/nodes/a.md", with: .theirs)
        #expect(moved.nodes["a"]?.title == "Main A")
        #expect(moved.changes.map(\.path) == ["src/nodes/new-one.md"])
    }

    @Test func storeKnowsWhichCopiesHoldLocalWork() async throws {
        let (ws, _, store) = try await editBranch()
        #expect(!store.hasLocalChanges("edit"))
        try ws.update("a") { try $0.setTitle("x") }
        #expect(store.hasLocalChanges("edit"))
        try ws.revert("a")
        #expect(!store.hasLocalChanges("edit"))
        _ = try ws.branchOff("local-only")
        #expect(store.hasLocalChanges("local-only")) // never pushed
    }
}

@MainActor @Suite struct ProgressTests {
    @Test func downloadReportsEachFileThenSkipsFilesAlreadyOnDevice() async throws {
        let store = tempStore()
        var reports: [String] = []
        _ = try await SiteWorkspace.download("main", client: client(.site()), store: store) { reports.append("\($0)/\($1)") }
        #expect(reports == ["0/2", "1/2", "2/2"])
        // A second branch with the same files downloads nothing new.
        let m = MockTransport.site()
        m.on("GET /git/ref/heads/other", ["object": ["sha": "c1"]])
        reports = []
        _ = try await SiteWorkspace.download("other", client: client(m), store: store) { reports.append("\($0)/\($1)") }
        #expect(reports == ["0/0"])
        #expect(m.count("GET /git/blobs/ba") == 0)
    }
}

@MainActor @Suite struct CommitMessageTests {
    /// Regression: the suggested message called every change "Edit", including new and deleted nodes.
    @Test func suggestedMessageNamesAddsEditsAndDeletes() async throws {
        let ws = try await SiteWorkspace.download("main", client: client(.site()), store: tempStore())
        #expect(ws.suggestedCommitMessage == "")
        try ws.createNode(slug: "new-one", title: "New", type: "talk")
        try ws.update("a") { try $0.setTitle("A2") }
        try ws.deleteNode("b")
        #expect(ws.suggestedCommitMessage == "Add new-one; Edit a; Delete b")
        for i in 1...4 { try ws.createNode(slug: "n\(i)", title: "N\(i)", type: "post") }
        #expect(ws.suggestedCommitMessage.hasPrefix("Add n1, n2, n3 and 2 more; Edit a; Delete b"))
    }
}

/// Issue #1: sort nodes by last updated, drafts first.
@MainActor @Suite struct LastUpdatedTests {
    static func iso(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    /// GitHub's last commit date for a node file on main.
    func commitDate(_ m: MockTransport, _ slug: String, _ date: String, ref: String = "main") {
        m.on("GET /commits?sha=\(ref)&path=src/nodes/\(slug).md&per_page=1", [["commit": ["committer": ["date": date]]]])
    }

    func synced() async throws -> (SiteWorkspace, MockTransport) {
        let m = MockTransport.site()
        commitDate(m, "a", "2020-01-01T00:00:00Z")
        commitDate(m, "b", "2024-06-01T00:00:00Z")
        let ws = try await SiteWorkspace.download("main", client: client(m), store: tempStore())
        _ = try await ws.sync(client: client(m))
        return (ws, m)
    }

    @Test func syncFetchesEachFilesLastCommitDate() async throws {
        let (ws, m) = try await synced()
        #expect(ws.lastUpdated("a") == Self.iso("2020-01-01T00:00:00Z"))
        #expect(ws.lastUpdated("b") == Self.iso("2024-06-01T00:00:00Z"))
        #expect(ws.sortedNodes(by: .updated, draftsFirst: false).map(\.slug) == ["b", "a"])
        // Already known: the next sync asks GitHub for nothing.
        let before = m.requests.filter { $0.key.hasPrefix("GET /commits?") }.count
        _ = try await ws.sync(client: client(m))
        #expect(m.requests.filter { $0.key.hasPrefix("GET /commits?") }.count == before)
    }

    @Test func editsOnThisDeviceCountAsUpdatedNow() async throws {
        let (ws, _) = try await synced()
        try ws.update("a") { try $0.setTitle("Fresh") }
        #expect(ws.sortedNodes(by: .updated, draftsFirst: false).map(\.slug) == ["a", "b"])
        try ws.commit(message: "Queued") // still newest while waiting to be pushed
        #expect(ws.sortedNodes(by: .updated, draftsFirst: false).first?.slug == "a")
    }

    @Test func filesChangedOnGitHubGetTheirDateAgain() async throws {
        let (ws, m) = try await synced()
        m.remoteMoves(to: "c9", changing: ["src/nodes/a.md": "---\ntitle: \"A remote\"\ntype: person\nlinks: []\n---\n"])
        commitDate(m, "a", "2026-01-01T00:00:00Z")
        _ = try await ws.sync(client: client(m))
        #expect(ws.lastUpdated("a") == Self.iso("2026-01-01T00:00:00Z"))
        #expect(ws.lastUpdated("b") == Self.iso("2024-06-01T00:00:00Z")) // unchanged, not fetched again
    }

    @Test func pushedFilesAreDatedAtThePush() async throws {
        let (ws, m) = try await synced()
        try ws.update("a") { try $0.setTitle("Pushed") }
        try ws.commit(message: "Push it")
        m.acceptCommits()
        let start = Date()
        _ = try await ws.sync(client: client(m))
        #expect(ws.state.fileDates?["src/nodes/a.md"].map { $0 >= start } == true)
    }

    @Test func sortOrdersAndDraftsFirst() async throws {
        let (ws, _) = try await synced()
        #expect(ws.sortedNodes(by: .title, draftsFirst: false).map(\.slug) == ["a", "b"])
        #expect(ws.sortedNodes(by: .date, draftsFirst: false).map(\.slug) == ["b", "a"]) // b is dated 2001, a undated
        try ws.update("a") { try $0.setDraft(true) }
        #expect(ws.sortedNodes(by: .date, draftsFirst: true).map(\.slug) == ["a", "b"])
        #expect(ws.sortedNodes(by: .date, draftsFirst: false).map(\.slug) == ["b", "a"])
    }

    @Test func branchNamesAndPathsAreEscapedInTheQuery() {
        #expect(GitHubClient.escapeQuery("feature/a b&c") == "feature/a%20b%26c")
    }
}

/// Issue #3: draft / publish / published, and the Show filter.
@MainActor @Suite struct NodeStateTests {
    @Test func onThePublishedBranchSyncedNodesArePublishedAndEditsArePublish() async throws {
        let m = MockTransport.site()
        let ws = try await SiteWorkspace.download("main", client: client(m), store: tempStore())
        _ = try await ws.sync(client: client(m), publishedBranch: "main")
        #expect(ws.state(of: "a") == .published)
        try ws.update("a") { try $0.setTitle("Changed") }
        #expect(ws.state(of: "a") == .publish)
        try ws.commit(message: "Queued, not pushed")
        #expect(ws.state(of: "a") == .publish) // committed on the device is not live yet
        try ws.createNode(slug: "new-one", title: "New", type: "post")
        #expect(ws.state(of: "new-one") == .publish)
        try ws.update("b") { try $0.setDraft(true) }
        #expect(ws.state(of: "b") == .draft) // draft wins even though b changed
    }

    @Test func onABranchStatesCompareWithThePublishedBranch() async throws {
        let m = MockTransport.site()
        // "edit" has a changed a; main (published) still has the original files.
        let changedA = "---\ntitle: \"A on edit\"\ntype: person\nlinks: [b]\n---\n\nBody A\n"
        let shaA = GitBlob.sha(of: changedA)
        m.on("GET /git/blobs/\(shaA)", ["content": Data(changedA.utf8).base64EncodedString()])
        m.on("GET /git/ref/heads/edit", ["object": ["sha": "e1"]])
        m.on("GET /git/commits/e1", ["sha": "e1", "tree": ["sha": "te1"]])
        m.on("GET /git/trees/te1?recursive=1", ["tree": [
            ["path": "src/nodes/a.md", "type": "blob", "sha": shaA],
            ["path": "src/nodes/b.md", "type": "blob", "sha": "bb"],
        ]])
        let ws = try await SiteWorkspace.download("edit", client: client(m), store: tempStore())
        #expect(ws.state(of: "b") == .publish) // nothing known about main yet: not claimed as published
        _ = try await ws.sync(client: client(m), publishedBranch: "main")
        #expect(ws.state.publishedCommit == "c1")
        #expect(ws.state(of: "a") == .publish)
        #expect(ws.state(of: "b") == .published)
        // main does not move: the next sync does not read its tree again.
        let reads = m.count("GET /git/trees/t1?recursive=1")
        _ = try await ws.sync(client: client(m), publishedBranch: "main")
        #expect(m.count("GET /git/trees/t1?recursive=1") == reads)
    }

    @Test func showFilterCombinesWithTypeAndSearch() async throws {
        let m = MockTransport.site()
        let ws = try await SiteWorkspace.download("main", client: client(m), store: tempStore())
        _ = try await ws.sync(client: client(m), publishedBranch: "main")
        try ws.createNode(slug: "draft-talk", title: "Draft Talk", type: "talk")
        try ws.update("draft-talk") { try $0.setDraft(true) }
        try ws.createNode(slug: "new-talk", title: "New Talk", type: "talk")
        func slugs(_ show: NodeShowFilter, type: String? = nil, search: String = "") -> [String] {
            ws.visibleNodes(search: search, type: type, show: show, sort: .title, draftsFirst: false).map(\.slug)
        }
        #expect(slugs(.all) == ["a", "b", "draft-talk", "new-talk"])
        #expect(slugs(.draft) == ["draft-talk"])
        #expect(slugs(.publish) == ["new-talk"])
        #expect(slugs(.published) == ["a", "b"])
        #expect(slugs(.publish, type: "person") == [])
        #expect(slugs(.all, type: "talk", search: "new") == ["new-talk"])
    }
}

/// Issue #3, part 2: deleted nodes stay listed until the deletion is published; undelete; links to deleted nodes.
@MainActor @Suite struct DeletedNodeTests {
    /// main at c1 with a (links to b) and b, synced as the published branch.
    func mainWorkspace() async throws -> (SiteWorkspace, MockTransport) {
        let m = MockTransport.site()
        let ws = try await SiteWorkspace.download("main", client: client(m), store: tempStore())
        _ = try await ws.sync(client: client(m), publishedBranch: "main")
        return (ws, m)
    }

    @Test func uncommittedDeletionIsListedAndUndeleteCancelsIt() async throws {
        let (ws, _) = try await mainWorkspace()
        try ws.deleteNode("b")
        #expect(ws.nodes["b"] == nil)
        #expect(ws.state(of: "b") == .deleted)
        #expect(ws.visibleNodes(sort: .title, draftsFirst: false).map(\.slug) == ["a", "b"]) // still in the list
        #expect(ws.visibleNodes(show: .publish, sort: .title, draftsFirst: false).map(\.slug) == ["b"])
        try ws.undelete("b")
        #expect(ws.state(of: "b") == .published)
        #expect(!ws.hasChanges)
    }

    @Test func committedDeletionStaysUntilPublishedAndCanBeUndeleted() async throws {
        let (ws, m) = try await mainWorkspace()
        try ws.deleteNode("b")
        try ws.commit(message: "Delete b")
        #expect(ws.state(of: "b") == .deleted) // queued: main still has b
        try ws.undelete("b") // re-adds b as an uncommitted change on top of the queued deletion
        #expect(ws.nodes["b"] != nil && ws.hasChanges)
        try ws.revert("b") // back to deleted
        #expect(ws.state(of: "b") == .deleted)

        // Pushed to main (the published branch): the deletion is live, so b leaves the list.
        m.acceptCommits()
        _ = try await ws.sync(client: client(m), publishedBranch: "main")
        #expect(ws.state(of: "b") == nil)
        #expect(ws.visibleNodes(sort: .title, draftsFirst: false).map(\.slug) == ["a"])
        #expect(ws.state.pendingDeletions == nil)
    }

    @Test func deletionOnABranchStaysUntilMainLosesTheFile() async throws {
        let (main, m) = try await mainWorkspace()
        _ = main
        let store = main.store
        // A branch "edit" at c1, created from main's copy.
        m.on("POST /git/refs", status: 201, ["ref": "refs/heads/edit"])
        let ws = try main.branchOff("edit")
        try ws.deleteNode("b")
        try ws.commit(message: "Delete b on edit")
        m.on("GET /git/ref/heads/edit", ["object": ["sha": "c1"]])
        m.on("POST /git/trees", ["sha": "t2"])
        m.on("POST /git/commits", ["sha": "e2"])
        m.on("GET /git/commits/e2", ["sha": "e2", "tree": ["sha": "t2"]])
        m.on("PATCH /git/refs/heads/edit", ["object": ["sha": "e2"]])
        _ = try await ws.sync(client: client(m), publishedBranch: "main")
        #expect(ws.state(of: "b") == .deleted) // pushed to edit, but main (published) still has b
        #expect(try SiteWorkspace.open("edit", store: store)?.state(of: "b") == .deleted) // survives relaunch
        try ws.undelete("b")
        #expect(ws.nodes["b"]?.title == "B")
    }

    @Test func linksToDeletedNodesAreFlaggedAndCanBeRemoved() async throws {
        let (ws, _) = try await mainWorkspace()
        #expect(ws.incomingLinks(to: "b").map(\.slug) == ["a"])
        try ws.deleteNode("b")
        #expect(ws.brokenLinks(of: "a") == [NodeLink(to: "b")])
        #expect(ws.issues(for: "a").contains { $0.message.contains("deleted node \"b\"") })
        #expect(ws.visibleNodes(show: .brokenLinks, sort: .title, draftsFirst: false).map(\.slug) == ["a"])
        try ws.undelete("b")
        #expect(ws.brokenLinks(of: "a").isEmpty) // undelete clears the flag

        try ws.deleteNode("b", removingIncomingLinks: true)
        #expect(ws.nodes["a"]?.links.isEmpty == true)
        #expect(ws.brokenLinks(of: "a").isEmpty)
        #expect(ws.changes.map(\.path) == ["src/nodes/a.md", "src/nodes/b.md"]) // a edited, b deleted
    }
}

@Suite struct MarkdownImageTests {
    @Test func findsImagesAndIgnoresAttributes() {
        let text = "Intro ![lego](/assets/images/big-lego-512.png){.align-right} and ![](/assets/a.gif \"t\")"
        #expect(MarkdownImage.all(in: text) == [
            MarkdownImage(alt: "lego", src: "/assets/images/big-lego-512.png"),
            MarkdownImage(alt: "", src: "/assets/a.gif"),
        ])
    }

    @Test func shownSkipsInlineImagesAndFencedCode() {
        let body = "![a](/a.png)\nSee ![b](/b.png) inline\n```\n![c](/c.png)\n```\n![d](/d.png)"
        #expect(MarkdownImage.shown(in: body).map(\.src) == ["/a.png", "/d.png"])
    }

    @Test func sitePathDecodesAndDropsQuery() {
        #expect(MarkdownImage.sitePath("/assets/my%20photo.png?v=2#top") == "/assets/my photo.png")
        #expect(MarkdownImage.sitePath("assets/x.png") == "/assets/x.png")
    }

    @Test func standaloneOnlyWhenTheImageIsTheWholeLine() {
        #expect(MarkdownImage.standalone("  ![lego](/assets/l.png){.align-right} ") == MarkdownImage(alt: "lego", src: "/assets/l.png"))
        #expect(MarkdownImage.standalone("See ![lego](/assets/l.png)") == nil)
    }
}

/// The preview shows a node's images from the branch's own assets, kept on the device so it works offline.
@MainActor @Suite struct ImageTests {
    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    /// Node a shows src/assets/images/x.png (blob bx).
    static func siteWithImage() -> MockTransport {
        let m = MockTransport.site()
        let a = "---\ntitle: \"A\"\ntype: person\nlinks: [b]\n---\n\n![x](/assets/images/x.png){.align-right}\n"
        m.on("GET /git/blobs/ba", ["content": Data(a.utf8).base64EncodedString(), "encoding": "base64"])
        m.on("GET /git/blobs/bx", ["content": png.base64EncodedString(), "encoding": "base64"])
        return m
    }

    @Test func downloadKeepsReferencedImagesForOfflinePreview() async throws {
        let m = Self.siteWithImage()
        let store = tempStore()
        let ws = try await SiteWorkspace.download("main", client: client(m), store: store)
        #expect(m.count("GET /git/blobs/bx") == 0) // the branch opens without waiting for images
        _ = try await ws.sync(client: client(m))
        #expect(m.count("GET /git/blobs/bx") == 1)
        // Reopened from disk, with no client: still there.
        let reopened = try #require(try SiteWorkspace.open("main", store: store))
        #expect(reopened.imageData("/assets/images/x.png") == Self.png)
        #expect(ws.hasAsset("/assets/images/x.png"))
        _ = try await ws.sync(client: client(m))
        #expect(m.count("GET /git/blobs/bx") == 1) // not fetched again
        #expect(ws.imageData("/assets/images/x.png?v=2") == Self.png)
    }

    @Test func unknownPathIsNotAnAsset() async throws {
        let ws = try await SiteWorkspace.download("main", client: client(Self.siteWithImage()), store: tempStore())
        #expect(!ws.hasAsset("/assets/images/missing.png"))
        #expect(try await ws.loadImage("/assets/images/missing.png", client: client(Self.siteWithImage())) == nil)
    }

    @Test func copiesFromOlderBuildsGetAssetShasAtSync() async throws {
        let m = Self.siteWithImage()
        let store = tempStore()
        _ = try await SiteWorkspace.download("main", client: client(m), store: store)
        var old = try #require(store.branchState(named: "main"))
        old.base.assetSHAs = nil // as saved before assets had shas
        try store.saveBranchState(old)
        let ws = try #require(try SiteWorkspace.open("main", store: store))
        #expect(ws.imageData("/assets/images/x.png") == nil)
        #expect(ws.hasAsset("/assets/images/missing.png")) // unknown yet, so not flagged
        _ = try await ws.sync(client: client(m))
        #expect(ws.imageData("/assets/images/x.png") == Self.png)
        #expect(!ws.hasAsset("/assets/images/missing.png"))
    }
}
