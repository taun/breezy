import BreezyKit
import BreezyKitTestSupport
import Foundation
import SwiftUI
import Testing

/// An AppModel wired to a fake GitHub (repo "o/r"), a temporary local store and its own settings domain.
@MainActor
struct Harness {
    let model: AppModel
    let github: MockTransport
    let store: LocalStore

    init() {
        let github = MockTransport.site() // main at c1 with nodes a and b
        github.on("GET ", ["default_branch": "main"])
        github.on("GET /branches?per_page=100", [["name": "main", "commit": ["sha": "c1"]]])
        github.on("GET /pulls?state=open&per_page=100", [])
        let store = LocalStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("breezy-app-tests-\(UUID().uuidString)"))
        let defaults = UserDefaults(suiteName: "breezy-app-tests-\(UUID().uuidString)")!
        self.github = github
        self.store = store
        model = AppModel(tokens: MemoryTokenStore("t"), defaults: defaults, transport: github, storeFor: { _ in store })
    }

    /// Connects to the fake repo, which downloads main.
    func connect() async {
        await model.saveSettings(repo: "o/r", token: "")
    }

    /// Lets GitHub accept the creation of `branch` at c1 and list it afterwards, as GitHub does.
    func acceptBranch(_ branch: String) {
        github.on("POST /git/refs", status: 201, ["ref": "refs/heads/\(branch)"])
        github.on("GET /git/ref/heads/\(branch)", ["object": ["sha": "c1"]])
        github.on("GET /branches?per_page=100", [["name": "main", "commit": ["sha": "c1"]], ["name": branch, "commit": ["sha": "c1"]]])
    }

    /// GitHub no longer has `branch` (published and deleted on another device).
    func deleteOnGitHub(_ branch: String) {
        github.on("GET /git/ref/heads/\(branch)", status: 404, ["message": "Not Found"])
        github.on("GET /branches?per_page=100", [["name": "main", "commit": ["sha": "c1"]]])
    }
}

@MainActor @Suite struct AppModelTests {
    @Test func connectingDownloadsTheDefaultBranch() async throws {
        let h = Harness()
        await h.connect()
        #expect(h.model.errorMessage == nil)
        #expect(h.model.currentBranch == "main")
        #expect(h.model.workspace?.slugs == ["a", "b"])
    }

    /// Regression: the branch list was fetched before sync created the new branch on GitHub, so a branch created in
    /// the app was labeled "deleted on GitHub" until the next sync.
    @Test func newBranchIsNotLabeledDeletedOnGitHub() async throws {
        let h = Harness()
        await h.connect()
        h.acceptBranch("feature")
        await h.model.createBranch("feature")
        #expect(h.model.errorMessage == nil)
        #expect(h.model.currentBranch == "feature")
        #expect(h.github.count("POST /git/refs") == 1)
        #expect(!h.model.isDeletedOnGitHub("feature"))
        #expect(!h.model.branchLabel("feature").contains("deleted"))
    }

    @Test func branchDeletedElsewhereWithNothingLocalIsDroppedForMain() async throws {
        let h = Harness()
        await h.connect()
        h.acceptBranch("feature")
        await h.model.createBranch("feature")
        h.deleteOnGitHub("feature")
        await h.model.sync()
        #expect(h.model.currentBranch == "main")
        #expect(h.store.branchState(named: "feature") == nil)
        #expect(h.model.errorMessage?.contains("switched to main") == true)
        #expect(!h.model.showBranchDeleted)
    }

    @Test func branchDeletedElsewhereWithLocalEditsIsKeptAndAsks() async throws {
        let h = Harness()
        await h.connect()
        h.acceptBranch("feature")
        await h.model.createBranch("feature")
        try h.model.workspace?.update("a") { try $0.setTitle("Unpushed") }
        h.deleteOnGitHub("feature")
        await h.model.sync()
        #expect(h.model.currentBranch == "feature")
        #expect(h.model.showBranchDeleted)
        #expect(h.model.isDeletedOnGitHub("feature"))
        #expect(h.model.syncStatus == .branchDeleted)
        #expect(h.model.workspace?.nodes["a"]?.title == "Unpushed")

        // Recreating puts the branch back on GitHub and keeps the edit.
        h.acceptBranch("feature")
        await h.model.recreateBranchOnGitHub()
        #expect(!h.model.showBranchDeleted)
        #expect(h.github.bodies("POST /git/refs").last?["sha"] as? String == "c1")
        #expect(h.model.workspace?.nodes["a"]?.title == "Unpushed")
    }

    @Test func cleanCopiesOfBranchesGoneFromGitHubArePruned() async throws {
        let h = Harness()
        await h.connect()
        h.acceptBranch("old")
        await h.model.createBranch("old")
        await h.model.switchBranch("main")
        #expect(h.store.branchState(named: "old") != nil)
        h.deleteOnGitHub("old")
        await h.model.sync()
        #expect(h.store.branchState(named: "old") == nil)
        #expect(!h.model.branchNames.contains("old"))
    }
}

/// Regression: on iOS 27 tapping a node did nothing. The column getter only allowed the editor while a selection
/// existed, and iOS sets the column before the selection, so the request to open the editor was turned back.
@Suite struct CompactNavigationTests {
    @Test func openingTheEditorDoesNotDependOnTheSelectionAlreadyBeingSet() {
        // iOS asks for the editor first: the stored value must say editor, with no selection consulted.
        let stored = CompactNavigation.raw(.detail)
        #expect(CompactNavigation.column(stored) == .detail)
    }

    @Test func selectionDrivesTheColumn() {
        #expect(CompactNavigation.afterSelectionChange(to: "a") == "detail")
        #expect(CompactNavigation.afterSelectionChange(to: nil) == "sidebar")
    }

    @Test func editorIsOnlyRestoredWithSomethingToShow() {
        #expect(CompactNavigation.restored("detail", hasSelection: true) == "detail")
        #expect(CompactNavigation.restored("detail", hasSelection: false) == "sidebar")
        #expect(CompactNavigation.restored("sidebar", hasSelection: true) == "sidebar")
    }
}

/// Regression (#17): a stored tab name that is no longer a tab showed Basics with no segment selected. The picker
/// binds to `Tab(stored:)`, which must fall back to Basics without the stored name being needed to match.
@Suite struct EditorTabTests {
    @Test func knownTabIsRestored() {
        #expect(NodeEditorView.Tab(stored: "Body") == .body)
    }

    @Test func unknownTabFallsBackToBasics() {
        #expect(NodeEditorView.Tab(stored: "Notes") == .basics)
        #expect(NodeEditorView.Tab(stored: "") == .basics)
    }
}

@MainActor @Suite struct OfflineTests {
    /// Offline: the app keeps working from the local copy, commits wait, and they are pushed when back online.
    @Test func offlineCommitsWaitAndPushWhenBackOnline() async throws {
        let h = Harness()
        await h.connect()
        h.github.isOffline = true
        await h.model.sync()
        #expect(!h.model.isOnline)
        #expect(h.model.syncStatus == .offline(pending: 0))
        #expect(h.model.errorMessage == nil) // being offline is not an error

        try h.model.workspace?.update("a") { try $0.setTitle("Written on a plane") }
        await h.model.commit(message: "Plane edit")
        #expect(h.model.workspace?.queue.count == 1)
        #expect(h.model.syncStatus == .offline(pending: 1)) // the waiting commit is visible while offline
        #expect(h.github.count("POST /git/commits") == 0)

        // Back online: sync pushes the waiting commit.
        h.github.isOffline = false
        h.github.acceptCommits()
        h.model.setOnlineForTesting(true)
        await h.model.sync()
        #expect(h.model.workspace?.queue.isEmpty == true)
        #expect(h.github.bodies("POST /git/commits").map { $0["message"] as? String } == ["Plane edit"])
        #expect(h.model.syncStatus == .synced)
    }
}

@MainActor @Suite struct FileIssueTests {
    let issues = "POST https://api.github.com/repos/taun/breezy/issues"

    @Test func filesAnIssueWithKindAndExecuteLabels() async throws {
        let h = Harness()
        h.github.on(issues, status: 201, ["number": 9, "title": "T", "html_url": "https://github.com/taun/breezy/issues/9"])
        let issue = await h.model.fileIssue(title: " T ", body: "B", kind: .enhancement, execute: true)
        #expect(issue?.number == 9)
        #expect(h.model.errorMessage == nil)
        let sent = try #require(h.github.bodies(issues).first)
        #expect(sent["title"] as? String == "T")
        #expect(sent["labels"] as? [String] == ["enhancement", "execute"])
    }

    @Test func tokenWithoutAccessExplainsWhatToChange() async throws {
        let h = Harness()
        h.github.on(issues, status: 404, ["message": "Not Found"])
        let issue = await h.model.fileIssue(title: "T", body: "", kind: .bug, execute: false)
        #expect(issue == nil)
        #expect(h.model.errorMessage?.contains("Issues") == true)
    }

    @Test func offlineDoesNotSend() async throws {
        let h = Harness()
        h.model.setOnlineForTesting(false)
        let issue = await h.model.fileIssue(title: "T", body: "", kind: .bug, execute: false)
        #expect(issue == nil)
        #expect(h.github.count(issues) == 0)
        #expect(h.model.errorMessage != nil)
    }
}
