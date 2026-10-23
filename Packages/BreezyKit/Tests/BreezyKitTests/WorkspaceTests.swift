import Foundation
import Testing
@testable import BreezyKit

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
        #expect(ws.issues(for: "a").contains { $0.message.contains("unknown node \"b\"") })
        #expect(throws: WorkspaceError.self) { try ws.createNode(slug: "a", title: "dup", type: "x") }
    }
}
