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
    let defaults: UserDefaults

    init() {
        let github = MockTransport.site() // main at c1 with nodes a and b
        github.on("GET ", ["default_branch": "main"])
        github.on("GET /branches?per_page=100", [["name": "main", "commit": ["sha": "c1"]]])
        github.on("GET /pulls?state=open&per_page=100", [])
        let store = LocalStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("breezy-app-tests-\(UUID().uuidString)"))
        let defaults = UserDefaults(suiteName: "breezy-app-tests-\(UUID().uuidString)")!
        self.github = github
        self.store = store
        self.defaults = defaults
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

/// Regression (#17): a stored tab name that is no longer a tab showed the first tab with no segment selected. The
/// picker binds to `Tab(stored:)`, which must fall back to the first tab (Title) without the stored name matching.
@Suite struct EditorTabTests {
    @Test func knownTabIsRestored() {
        #expect(NodeEditorView.Tab(stored: "Body") == .body)
    }

    @Test func unknownTabFallsBackToTitle() {
        #expect(NodeEditorView.Tab(stored: "Notes") == .title)
        #expect(NodeEditorView.Tab(stored: "") == .title)
        #expect(NodeEditorView.Tab(stored: "Basics") == .title) // the first tab's former name
    }
}

/// Regression: in iPhone landscape the editor's controls must step aside only while typing leaves a sliver of height
/// (the on-screen keyboard up). Hiding them on focus alone left them hidden for good with a hardware keyboard.
@Suite struct BodyControlsTests {
    @Test func onlyTheOnScreenKeyboardInLandscapeIsAShortSpace() {
        #expect(NodeEditorView.isShortSpace(150)) // landscape, keyboard up
        #expect(NodeEditorView.isShortSpace(190)) // largest iPhones, landscape, keyboard up
        #expect(!NodeEditorView.isShortSpace(267)) // small iPhone, landscape, hardware keyboard with shortcut bar
        #expect(!NodeEditorView.isShortSpace(420)) // portrait, keyboard up
    }

    @Test func onlyWhileTypingTheBodyOnAnIPhone() {
        #expect(NodeEditorView.hidesControls(isPhone: true, bodyFocused: true, shortSpace: true))
        #expect(!NodeEditorView.hidesControls(isPhone: false, bodyFocused: true, shortSpace: true)) // short iPad window
        #expect(!NodeEditorView.hidesControls(isPhone: true, bodyFocused: false, shortSpace: true))
        #expect(!NodeEditorView.hidesControls(isPhone: true, bodyFocused: true, shortSpace: false))
    }
}

/// Images on a line of their own are shown as pictures in the preview; one inside a sentence stays inline text.
@MainActor @Suite struct PreviewImageTests {
    @Test func standaloneImageLineBecomesAnImageBlock() {
        let blocks = MarkdownPreview.blocks("Intro\n\n![lego](/assets/images/big-lego-512.png){.align-right}\nNext ![x](/a.png) inline")
        #expect(blocks == [
            .paragraph("Intro"),
            .image(MarkdownImage(alt: "lego", src: "/assets/images/big-lego-512.png")),
            .paragraph("Next ![x](/a.png) inline"),
        ])
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

/// Issues #16 and #15: per-node editor state lives in the node's state file, not in this device's settings.
@MainActor @Suite struct EditorStateAppTests {
    @Test func draftsAndTheCursorFromOlderBuildsMoveIntoTheirNodes() async throws {
        let h = Harness()
        h.defaults.set("A rewrite", forKey: BodyDraft.key(branch: "main", slug: "a"))
        h.defaults.set("Gone node", forKey: BodyDraft.key(branch: "main", slug: "zz"))
        h.defaults.set("Other branch", forKey: BodyDraft.key(branch: "feature", slug: "a"))
        h.defaults.set("b|2|4", forKey: "editor.bodySelection")
        h.defaults.set(true, forKey: "editor.preview")
        await h.connect()
        let ws = try #require(h.model.workspace)
        #expect(ws.editorState("a").draft?.text == "A rewrite")
        #expect(ws.editorState("b").selection == [2, 4] && ws.editorState("b").mode == .preview)
        #expect(ws.changedNodes.map(\.slug) == ["a"]) // the draft is to be committed; the cursor is not
        #expect(h.defaults.object(forKey: BodyDraft.key(branch: "main", slug: "a")) == nil)
        #expect(h.defaults.object(forKey: "editor.bodySelection") == nil && h.defaults.object(forKey: "editor.preview") == nil)
        #expect(h.defaults.string(forKey: BodyDraft.key(branch: "feature", slug: "a")) == "Other branch") // when opened
        #expect(h.defaults.string(forKey: BodyDraft.key(branch: "main", slug: "zz")) == "Gone node") // no such node here
    }

    @Test func aDraftFromAnOlderBuildIsAddedToOneThatSyncedMeanwhile() async throws {
        let h = Harness()
        await h.connect()
        let ws = try #require(h.model.workspace)
        try ws.setDraft("a", "From the Mac")
        h.defaults.set("From this iPhone", forKey: BodyDraft.key(branch: "main", slug: "a"))
        h.defaults.set("From the Mac", forKey: BodyDraft.key(branch: "main", slug: "b"))
        try ws.setDraft("b", "From the Mac")
        h.model.importLegacyEditorState(ws)
        #expect(ws.editorState("a").draft?.text == "From the Mac\n\nFrom this iPhone") // neither is lost
        #expect(ws.editorState("b").draft?.text == "From the Mac") // the same draft is not repeated
        #expect(h.defaults.object(forKey: BodyDraft.key(branch: "main", slug: "a")) == nil)
    }

    @Test func aNodeChangedOnGitHubOpensOnItsBodyWithTheCursorAtTheEnd() async throws {
        let h = Harness()
        await h.connect()
        let ws = try #require(h.model.workspace)
        ws.setEditor("a") { $0.tab = .links; $0.selection = [0, 0] }
        h.github.remoteMoves(to: "c9", changing: ["src/nodes/a.md": "---\ntitle: \"A\"\n---\n\nRewritten elsewhere\n"])
        await h.model.sync()
        let body = try #require(ws.nodes["a"]).body
        #expect(ws.editorState("a").tab == .body && ws.editorState("a").selection == [body.utf16.count, body.utf16.count])
        #expect(ws.remoteRevision["a"] == 1)
        #expect(!ws.hasChanges)
    }

    @Test func theCommitCountIgnoresCursorMovesButCountsDrafts() async throws {
        let h = Harness()
        await h.connect()
        let ws = try #require(h.model.workspace)
        ws.setEditor("a") { $0.selection = [3, 3] }
        #expect(ws.changedNodes.isEmpty && !ws.hasChanges)
        try ws.setDraft("b", "New text")
        #expect(ws.changedNodes.map(\.slug) == ["b"] && ws.hasChanges)
        #expect(CommitView.caption(ws.changedNodes[0]) == "draft started")
    }
}

/// Fetches from a table, like the web would.
struct FakeImageFetcher: ImageFetching {
    var images: [URL: Data] = [:]
    var failure: ImageFetchError?
    func fetch(_ url: URL) async throws -> Data {
        if let failure { throw failure }
        guard let data = images[url] else { throw ImageFetchError.http(404) }
        return data
    }
}

@MainActor @Suite struct HeaderImageAppTests {
    /// A tiny valid PNG (1×1, opaque red, with an alpha channel): opaque, so it is saved as a JPEG.
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==")!

    private func model(fetcher: FakeImageFetcher) -> (AppModel, Harness) {
        let h = Harness()
        let model = AppModel(tokens: MemoryTokenStore("t"), defaults: h.defaults, transport: h.github, imageFetcher: fetcher, storeFor: { _ in h.store })
        return (model, h)
    }

    @Test func aPictureFromAWebAddressIsCopiedAndTheAddressIsNotKept() async throws {
        let url = URL(string: "https://example.com/cover.png")!
        let (model, _) = model(fetcher: FakeImageFetcher(images: [url: Self.png]))
        await model.saveSettings(repo: "o/r", token: "")
        let ws = try #require(model.workspace)
        #expect(await model.importHeaderImage(slug: "a", from: "example.com/cover.png", makeThumbnail: true))
        let node = try #require(ws.nodes["a"])
        #expect(node.header.image == "/assets/images/a-header.jpg" && node.header.teaser == "/assets/images/a-teaser.jpg")
        #expect(!node.rendered().contains("example.com"))
        #expect(ws.imageData("/assets/images/a-header.jpg") != nil)
        #expect(model.errorMessage == nil)
    }

    @Test func aFailedDownloadLeavesTheNodeAlone() async throws {
        let (model, _) = model(fetcher: FakeImageFetcher(failure: .http(404)))
        await model.saveSettings(repo: "o/r", token: "")
        let ws = try #require(model.workspace)
        let before = ws.nodes["a"]?.rendered()
        #expect(await model.importHeaderImage(slug: "a", from: "https://example.com/missing.png", makeThumbnail: true) == false)
        #expect(ws.nodes["a"]?.rendered() == before && ws.state.pendingAssets == nil)
        #expect(model.errorMessage?.contains("404") == true)
    }

    @Test func somethingThatIsNotAnImageIsRefused() async throws {
        let url = URL(string: "https://example.com/page.html")!
        let (model, _) = model(fetcher: FakeImageFetcher(images: [url: Data("<html>".utf8)]))
        await model.saveSettings(repo: "o/r", token: "")
        let ws = try #require(model.workspace)
        let before = ws.nodes["a"]?.rendered()
        #expect(await model.importHeaderImage(slug: "a", from: url.absoluteString, makeThumbnail: true) == false)
        #expect(ws.nodes["a"]?.rendered() == before && model.errorMessage != nil)
    }

    /// The unsent address belongs to the node it was typed for; clearing it after an import leaves another node's alone.
    @Test func anUnsentAddressBelongsToItsNode() {
        let stored = HeaderImageSection.stored("example.com/a.png", for: "a")
        #expect(HeaderImageSection.address(stored, for: "a") == "example.com/a.png")
        #expect(HeaderImageSection.address(stored, for: "ab") == "" && HeaderImageSection.address(stored, for: "b") == "")
        #expect(HeaderImageSection.stored("", for: "a") == "")
        #expect(stored != HeaderImageSection.stored("example.com/a.png", for: "b"))
    }

    @Test func pastedBytesWorkOffline() async throws {
        let (model, h) = model(fetcher: FakeImageFetcher())
        await model.saveSettings(repo: "o/r", token: "")
        h.github.isOffline = true
        let ws = try #require(model.workspace)
        #expect(model.setHeaderImage(slug: "a", from: Self.png, makeThumbnail: false))
        #expect(ws.nodes["a"]?.header.image == "/assets/images/a-header.jpg" && ws.nodes["a"]?.header.teaser == nil)
        #expect(ws.state.pendingAssets?.keys.sorted() == ["/assets/images/a-header.jpg"])
    }
}
