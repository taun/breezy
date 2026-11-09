import Foundation
import Testing
@testable import BreezyKit
import BreezyKitTestSupport

@Suite struct EditorStateTests {
    @Test func readsAndWritesTheFileKeepingUnknownKeys() throws {
        let json = #"{"version":1,"later":{"x":[1,true,null]},"editor":{"tab":"body","mode":"draft","selection":[2,5],"zoom":1.5},"draft":{"text":"New","base":"abc","by":"mac"}}"#
        let s = try #require(EditorState(json: json))
        #expect(s.tab == .body && s.mode == .draft && s.selection == [2, 5])
        #expect(s.draft == .init(text: "New", base: "abc").with(extra: ["by": .string("mac")]))
        let again = try #require(EditorState(json: s.rendered()))
        #expect(again == s)
        #expect(s.rendered().contains("\"zoom\" : 1.5") && s.rendered().contains("\"later\""))
    }

    @Test func aNewerVersionIsNotLowered() throws {
        let s = try #require(EditorState(json: #"{"version":3,"editor":{"tab":"links"}}"#))
        #expect(s.rendered().contains("\"version\" : 3"))
    }

    @Test func theSameStateAlwaysGivesTheSameBytes() {
        let a = EditorState(tab: .body, mode: .edit, selection: [1, 1], draft: .init(text: "/x/", base: "s"))
        let b = EditorState(tab: .body, mode: .edit, selection: [1, 1], draft: .init(text: "/x/", base: "s"))
        #expect(a.rendered() == b.rendered())
        #expect(a.rendered().hasSuffix("}\n") && a.rendered().contains("\"/x/\"")) // slashes are not escaped
    }

    @Test func whatANewerVersionWroteSurvivesAMerge() throws {
        let newer = #"{"version":2,"pinned":true,"editor":{"tab":"history","zoom":2},"draft":{"text":"D","tone":"warm"}}"#
        let remote = try #require(EditorState(json: newer))
        #expect(remote.tab == nil && remote.rendered().contains(#""tab" : "history""#)) // an unknown tab is kept as is
        guard case let .merged(m) = EditorState.merge(base: nil, local: EditorState(selection: [1, 1]), remote: remote) else {
            Issue.record("expected a merge"); return
        }
        let out = m.rendered()
        #expect(out.contains(#""pinned" : true"#) && out.contains(#""zoom" : 2"#) && out.contains(#""tone" : "warm""#))
        #expect(out.contains(#""version" : 2"#) && m.selection == [1, 1] && m.draft?.text == "D")
        guard case let .merged(mine) = EditorState.merge(base: nil, local: EditorState(tab: .links), remote: remote) else {
            Issue.record("expected a merge"); return
        }
        #expect(mine.rendered().contains(#""tab" : "links""#)) // a tab chosen here wins over one not known here
    }

    @Test func somethingElseIsNoState() {
        #expect(EditorState(json: "not json") == nil)
        #expect(EditorState(json: "[1]") == nil)
        #expect(EditorState(json: #"{"editor":{}}"#) == nil) // no version
        #expect(EditorState(json: #"{"version":1e300}"#) == nil) // not an Int: absent, not a crash
        #expect(EditorState(json: #"{"version":1,"editor":{"selection":[1e20,1e20]}}"#)?.selection == nil)
    }

    @Test func afterARemoteChangeTheBodyOpensWithTheCursorAtTheEnd() {
        let kept = EditorState(tab: .links, mode: .preview, selection: [0, 0], draft: .init(text: "D", base: nil))
        let s = EditorState.afterRemoteChange(body: "Hi 👋", keeping: kept)
        #expect(s.tab == .body && s.mode == .edit && s.selection == [5, 5]) // UTF-16: the emoji counts 2
        #expect(s.draft == kept.draft)
        let empty = EditorState.afterRemoteChange(body: "", keeping: nil)
        #expect(empty.tab == .title && empty.selection == nil)
    }

    @Test func draftsMergeThreeWaysAndTheRestStaysLocal() {
        let base = EditorState(tab: .body, draft: .init(text: "Base", base: nil))
        var local = base; local.tab = .links
        var remote = base; remote.tab = .media; remote.draft?.text = "Remote"
        // Only GitHub changed the draft: theirs, with the local tab.
        #expect(EditorState.merge(base: base, local: local, remote: remote) == .merged(EditorState(tab: .links, draft: .init(text: "Remote", base: nil))))
        // Only this device changed it: mine.
        var mine = local; mine.draft?.text = "Mine"
        #expect(EditorState.merge(base: base, local: mine, remote: base) == .merged(mine))
        // Both, differently: a conflict; the same way: fine.
        #expect(EditorState.merge(base: base, local: mine, remote: remote) == .draftConflict)
        var same = remote; same.tab = .links
        #expect(EditorState.merge(base: base, local: same, remote: remote) == .merged(same))
        // GitHub removed the draft that is unchanged here.
        #expect(EditorState.merge(base: base, local: local, remote: nil) == .merged(EditorState(tab: .links)))
    }
}

extension EditorState.Draft {
    func with(extra: [String: JSONValue]) -> Self { var d = self; d.extra = extra; return d }
}

@MainActor @Suite struct EditorStateWorkspaceTests {
    let aState = ".breezy/nodes/a.json", bState = ".breezy/nodes/b.json"

    func site() async throws -> (SiteWorkspace, MockTransport, LocalStore) {
        let store = tempStore()
        let m = MockTransport.siteWithStates()
        return (try await SiteWorkspace.download("main", client: client(m), store: store), m, store)
    }

    @Test func downloadKeepsStateFilesAndIgnoresOthers() async throws {
        let (ws, _, _) = try await site()
        #expect(ws.state.base.states == [aState: "sa"])
        #expect(ws.state.base.files.keys.sorted() == ["src/nodes/a.md", "src/nodes/b.md"])
        #expect(ws.editorState("a").tab == .body && ws.editorState("a").selection == [3, 3])
        #expect(ws.editorState("a").draft?.text == "Old draft")
        #expect(ws.editorState("b").isEmpty)
        #expect(!ws.hasChanges)
    }

    @Test func aMovedCursorIsNotAChangeButSurvivesRelaunch() async throws {
        let (ws, _, store) = try await site()
        ws.setEditor("b") { $0.tab = .links; $0.selection = [4, 4] }
        try ws.flushEditorStates()
        #expect(!ws.hasChanges && ws.changedNodes.isEmpty)
        #expect(!store.hasLocalChanges("main"))
        let reopened = try #require(try SiteWorkspace.open("main", store: store))
        #expect(reopened.editorState("b").tab == .links && reopened.editorState("b").selection == [4, 4])
    }

    @Test func committingANodeTakesItsEditorStateAlong() async throws {
        let (ws, m, _) = try await site()
        ws.setEditor("b") { $0.selection = [9, 9] } // not flushed: the commit writes it
        ws.setEditor("a") { $0.tab = .links }        // a is not edited: stays uncommitted
        try ws.update("b") { try $0.setTitle("B2") }
        try ws.commit(message: "Edit b")
        #expect(ws.queue.first?.changes.map(\.path) == ["src/nodes/b.md", bState])
        m.acceptCommits()
        _ = try await ws.sync(client: client(m))
        let paths = (m.bodies("POST /git/trees").first?["tree"] as? [[String: Any]])?.compactMap { $0["path"] as? String }
        #expect(paths == ["src/nodes/b.md", bState])
        #expect(ws.state.base.states?[bState] != nil)
        #expect(ws.editorState("b").selection == [9, 9] && ws.editorState("a").tab == .links)
    }

    @Test func aDraftAloneIsACommittableChange() async throws {
        let (ws, _, store) = try await site()
        try ws.setDraft("b", "A rewrite")
        #expect(ws.editorState("b").draft?.base == EditorState.bodySHA(ws.nodes["b"]!.body))
        #expect(ws.hasChanges && ws.changes.isEmpty)
        #expect(ws.changedNodes == [.init(slug: "b", draft: .started)])
        #expect(ws.suggestedCommitMessage == "Update draft of b")
        #expect(store.hasLocalChanges("main"))
        try ws.commit(message: "Draft")
        #expect(ws.queue.first?.changes.map(\.path) == [bState])
        #expect(!ws.hasChanges)

        try ws.setDraft("a", nil) // removing a committed draft is a change too
        #expect(ws.changedNodes == [.init(slug: "a", draft: .removed)])
        try ws.revertDraft("a")
        #expect(ws.editorState("a").draft?.text == "Old draft" && !ws.hasChanges)
    }

    @Test func staleDraftsAreFlaggedUntilSeen() async throws {
        let (ws, _, _) = try await site()
        try ws.setDraft("b", "New")
        #expect(!ws.draftIsStale("b"))
        try ws.update("b") { $0.setBody("Changed\n") }
        #expect(ws.draftIsStale("b"))
        try ws.rebaseDraft("b")
        #expect(!ws.draftIsStale("b"))
    }

    @Test func deletingANodeDeletesItsStateAtCommit() async throws {
        let (ws, _, _) = try await site()
        try ws.deleteNode("a")
        try ws.undelete("a")
        #expect(ws.editorState("a").draft?.text == "Old draft") // undelete before commit keeps it
        try ws.deleteNode("a")
        try ws.commit(message: "Delete a")
        let changes = try #require(ws.queue.first?.changes)
        #expect(changes.map(\.path) == ["src/nodes/a.md", aState] && changes.allSatisfy { $0.content == nil })
        #expect(ws.state.pendingDeletions == ["src/nodes/a.md"])
    }

    @Test func undeletingAfterCommittingTheDeletionBringsTheDraftBack() async throws {
        let (ws, _, _) = try await site()
        try ws.deleteNode("a")
        try ws.commit(message: "Delete a") // queues the removal of a's state file too
        try ws.undelete("a")
        #expect(ws.editorState("a").draft?.text == "Old draft")
        #expect(ws.changedNodes == [.init(slug: "a", file: .added, draft: .started)])
        try ws.commit(message: "Undelete a")
        #expect(ws.queue.last?.changes.map(\.path) == ["src/nodes/a.md", aState])
    }

    @Test func aNodeThatGoesAwayLeavesNoStateBehind() async throws {
        let (ws, _, store) = try await site()
        try ws.createNode(slug: "new-one", title: "New", type: "talk")
        try ws.setDraft("new-one", "Draft")
        try ws.revert("new-one") // the added node goes, and its draft with it
        #expect(ws.editorState("new-one").isEmpty && store.workingStates("main")["new-one"] == nil)
        ws.setEditor("b") { $0.tab = .links }
        try ws.flushEditorStates()
        try ws.deleteNode("b")
        try ws.commit(message: "Delete b") // b's state was never committed: nothing to delete on GitHub, nothing left here
        #expect(ws.queue.first?.changes.map(\.path) == ["src/nodes/b.md"])
        #expect(store.workingStates("main")["b"] == nil)
    }

    @Test func aNodeChangedOnGitHubOpensOnItsNewContent() async throws {
        let store = tempStore()
        let m = MockTransport.site()
        let ws = try await SiteWorkspace.download("main", client: client(m), store: store)
        ws.setEditor("a") { $0.tab = .links; $0.mode = .preview; $0.selection = [0, 0] }
        ws.setEditor("b") { $0.tab = .date }
        m.remoteMoves(to: "c2", changing: ["src/nodes/a.md": "---\ntitle: \"A\"\n---\n\nNew body\n", "src/nodes/b.md": "---\ntitle: \"B2\"\n---\n"])
        #expect(try await ws.sync(client: client(m)) == .synced(pushed: 0))
        let end = try #require(ws.nodes["a"]).body.utf16.count
        #expect(end > 0)
        #expect(ws.editorState("a") == EditorState(tab: .body, mode: .edit, selection: [end, end]))
        #expect(ws.editorState("b").tab == .title) // no body: the title
        #expect(ws.remoteRevision == ["a": 1, "b": 1])
        #expect(!ws.hasChanges)
    }

    @Test func aNewerStateFromGitHubWinsOverTheTabAndCursorHere() async throws {
        let (ws, m, _) = try await site()
        ws.setEditor("a") { $0.tab = .title }
        let theirs = EditorState(tab: .media, selection: [1, 1], draft: .init(text: "Old draft", base: "x")).rendered()
        m.remoteMoves(to: "c2", changing: [aState: theirs], base: ["src/nodes/a.md": "ba", "src/nodes/b.md": "bb", aState: "sa"])
        _ = try await ws.sync(client: client(m))
        #expect(ws.editorState("a").tab == .media && ws.editorState("a").selection == [1, 1])
        #expect(ws.remoteRevision["a"] == 1)
    }

    @Test func aQueuedStateDoesNotPutBackAnOldDraft() async throws {
        let (ws, m, _) = try await site()
        ws.setEditor("a") { $0.selection = [1, 1] }
        try ws.update("a") { try $0.setTitle("A2") }
        try ws.commit(message: "Edit a") // carries a's state with the old draft
        var theirs = try #require(EditorState(json: MockTransport.stateA))
        theirs.draft?.text = "Written on the Mac"
        m.remoteMoves(to: "c5", changing: [aState: theirs.rendered()], base: ["src/nodes/a.md": "ba", "src/nodes/b.md": "bb", aState: "sa"])
        m.acceptCommits(startingAt: "c5")
        #expect(try await ws.sync(client: client(m)) == .synced(pushed: 1))
        let pushed = (m.bodies("POST /git/trees").first?["tree"] as? [[String: Any]])?.first { $0["path"] as? String == aState }
        let content = try #require(pushed?["content"] as? String)
        let state = try #require(EditorState(json: content))
        #expect(state.draft?.text == "Written on the Mac" && state.selection == [1, 1])
    }

    @Test(arguments: [true, false])
    func aDraftChangedOnBothSidesIsAConflict(useTheirs: Bool) async throws {
        let (ws, m, _) = try await site()
        try ws.setDraft("a", "Mine")
        var theirs = try #require(EditorState(json: MockTransport.stateA))
        theirs.draft?.text = "Theirs"
        m.remoteMoves(to: "c2", changing: [aState: theirs.rendered()], base: ["src/nodes/a.md": "ba", "src/nodes/b.md": "bb", aState: "sa"])
        #expect(try await ws.sync(client: client(m)) == .conflicts(1))
        let c = try #require(ws.conflicts.first)
        #expect(c.path == aState)
        #expect(ws.conflictSides(c) == (true, "Mine", "Theirs"))
        #expect(m.count("POST /git/commits") == 0)
        try ws.resolve(c.path, with: useTheirs ? .theirs : .edited("Mine and theirs"))
        #expect(ws.conflicts.isEmpty && ws.headSHA == "c2")
        #expect(ws.editorState("a").draft?.text == (useTheirs ? "Theirs" : "Mine and theirs"))
        #expect(ws.hasChanges == !useTheirs)
    }

    @Test(arguments: [true, false])
    func aSettledDraftStaysSettledWhileOtherConflictsAreOpen(useTheirs: Bool) async throws {
        let (ws, m, _) = try await site()
        try ws.setDraft("a", "Mine")
        try ws.update("b") { try $0.setTitle("B here") }
        var theirs = try #require(EditorState(json: MockTransport.stateA))
        theirs.draft?.text = "Theirs"
        m.remoteMoves(to: "c2", changing: [aState: theirs.rendered(), "src/nodes/b.md": "---\ntitle: \"B there\"\n---\n"],
                      base: ["src/nodes/a.md": "ba", "src/nodes/b.md": "bb", aState: "sa"])
        #expect(try await ws.sync(client: client(m)) == .conflicts(2))
        try ws.resolve(aState, with: useTheirs ? .theirs : .edited("Merged"))
        ws.setEditor("a") { $0.selection = [2, 2] } // moving the cursor before the last conflict is settled
        try ws.flushEditorStates()
        try ws.resolve("src/nodes/b.md", with: .mine)
        #expect(ws.conflicts.isEmpty)
        #expect(ws.editorState("a").draft?.text == (useTheirs ? "Theirs" : "Merged"))
    }

    @Test func deletingANewNodeTakesItsDraftAlong() async throws {
        let (ws, _, store) = try await site()
        try ws.createNode(slug: "new-one", title: "New", type: "talk")
        try ws.setDraft("new-one", "Draft")
        try ws.deleteNode("new-one") // never committed: nothing is left to commit or to come back
        #expect(store.workingStates("main")["new-one"] == nil && !store.hasLocalChanges("main"))
        try ws.createNode(slug: "new-one", title: "Again", type: "talk")
        #expect(ws.editorState("new-one").draft == nil)
    }

    @Test func aDiscardedQueuedDraftStaysDiscarded() async throws {
        let (ws, m, _) = try await site()
        try ws.setDraft("b", "Queued")
        try ws.commit(message: "Draft b")
        try ws.setDraft("b", nil) // discarded after committing, before pushing
        // Another device saves b's state (no draft) meanwhile.
        m.remoteMoves(to: "c5", changing: [bState: EditorState(tab: .links).rendered()],
                      base: ["src/nodes/a.md": "ba", "src/nodes/b.md": "bb", aState: "sa"])
        m.acceptCommits(startingAt: "c5")
        _ = try await ws.sync(client: client(m))
        #expect(ws.editorState("b").draft == nil)
        #expect(ws.changedNodes == [.init(slug: "b", draft: .removed)])
    }

    @Test func aQueuedDraftChangedOnGitHubIsAConflict() async throws {
        let (ws, m, _) = try await site()
        try ws.setDraft("b", "Queued")
        try ws.commit(message: "Draft b")
        try ws.setDraft("b", nil)
        let theirs = EditorState(draft: .init(text: "Theirs", base: "x")).rendered()
        m.remoteMoves(to: "c5", changing: [bState: theirs], base: ["src/nodes/a.md": "ba", "src/nodes/b.md": "bb", aState: "sa"])
        #expect(try await ws.sync(client: client(m)) == .conflicts(1))
        try ws.resolve(bState, with: .mine)
        #expect(ws.editorState("b").draft == nil) // mine: discarded
    }

    @Test(arguments: [true, false])
    func aDraftOnANodeDeletedOnGitHubIsAConflict(keepMine: Bool) async throws {
        let (ws, m, store) = try await site()
        try ws.setDraft("b", "Mine")
        m.remoteMoves(to: "c2", changing: ["src/nodes/b.md": nil], base: ["src/nodes/a.md": "ba", "src/nodes/b.md": "bb", aState: "sa"])
        #expect(try await ws.sync(client: client(m)) == .conflicts(1))
        #expect(ws.conflicts.map(\.path) == ["src/nodes/b.md"])
        try ws.resolve("src/nodes/b.md", with: keepMine ? .mine : .theirs)
        #expect(ws.conflicts.isEmpty)
        if keepMine { // the node comes back as an addition, with its draft
            #expect(ws.nodes["b"] != nil && ws.editorState("b").draft?.text == "Mine")
            #expect(ws.changedNodes == [.init(slug: "b", file: .added, draft: .started)])
        } else { // both go, nothing left behind
            #expect(ws.nodes["b"] == nil && ws.editorState("b").draft == nil)
            #expect(store.workingStates("main").isEmpty && !store.hasLocalChanges("main"))
        }
    }

    @Test func aCommitBeforeTheFirstSyncOfAnOlderCopyKeepsGitHubsDraft() async throws {
        let (ws, m, store) = try await site()
        var old = ws.state
        old.base.states = nil
        try store.saveBranchState(old)
        let reopened = try #require(try SiteWorkspace.open("main", store: store))
        reopened.setEditor("a") { $0.selection = [5, 5] } // made without knowing a's state file
        try reopened.update("a") { try $0.setTitle("A2") }
        try reopened.commit(message: "Edit a")
        m.acceptCommits()
        #expect(try await reopened.sync(client: client(m)) == .synced(pushed: 1))
        let pushed = (m.bodies("POST /git/trees").first?["tree"] as? [[String: Any]])?.first { $0["path"] as? String == aState }
        let content = try #require(pushed?["content"] as? String)
        let state = try #require(EditorState(json: content))
        #expect(state.draft?.text == "Old draft" && state.selection == [5, 5])
    }

    @Test func aDraftFromBeforeTheFirstSyncOfAnOlderCopyConflictsWithGitHubs() async throws {
        let (ws, m, store) = try await site()
        var old = ws.state
        old.base.states = nil
        try store.saveBranchState(old)
        let reopened = try #require(try SiteWorkspace.open("main", store: store))
        try reopened.setDraft("a", "Mine") // GitHub has "Old draft", unknown to this copy yet
        try reopened.commit(message: "Draft a")
        m.acceptCommits()
        #expect(try await reopened.sync(client: client(m)) == .conflicts(1)) // GitHub has not moved: compared anyway
        #expect(reopened.conflicts.map(\.path) == [aState] && m.count("POST /git/trees") == 0)
        try reopened.resolve(aState, with: .theirs)
        #expect(reopened.editorState("a").draft?.text == "Old draft" && reopened.queue.isEmpty)
        #expect(reopened.state.base.states == [aState: "sa"])
    }

    @Test func branchingOffTakesTheEditorStates() async throws {
        let (ws, _, store) = try await site()
        try ws.setDraft("b", "Draft")
        ws.setEditor("a") { $0.tab = .links }
        let feature = try ws.branchOff("feature")
        #expect(feature.editorState("b").draft?.text == "Draft" && feature.editorState("a").tab == .links)
        #expect(store.workingStates("main").isEmpty)
        #expect(ws.editorState("a").tab == .body)
    }

    @Test func movingEditsTakesDraftsAndReportsDraftConflicts() async throws {
        let (ws, m, store) = try await site()
        try ws.setDraft("a", "Mine")
        try ws.setDraft("b", "B draft")
        var theirs = try #require(EditorState(json: MockTransport.stateA))
        theirs.draft?.text = "Main's"
        m.remoteMoves(to: "c2", changing: [aState: theirs.rendered()], base: ["src/nodes/a.md": "ba", "src/nodes/b.md": "bb", aState: "sa"])
        let moved = try await ws.moveEdits(toNewBranch: "rescued", from: "main", client: client(m))
        #expect(moved.editorState("b").draft?.text == "B draft")
        #expect(moved.conflicts.map(\.path) == [aState])
        #expect(store.branchState(named: "main") == nil)
    }

    @Test func movingEditsKeepsADraftWhoseNodeTheNewBaseDeleted() async throws {
        let (ws, m, _) = try await site()
        try ws.setDraft("b", "B draft")
        m.remoteMoves(to: "c2", changing: ["src/nodes/b.md": nil], base: ["src/nodes/a.md": "ba", "src/nodes/b.md": "bb", aState: "sa"])
        let moved = try await ws.moveEdits(toNewBranch: "rescued", from: "main", client: client(m))
        #expect(moved.nodes["b"] != nil && moved.editorState("b").draft?.text == "B draft")
        #expect(moved.conflicts.map(\.path) == ["src/nodes/b.md"])
        try moved.resolve("src/nodes/b.md", with: .theirs) // both go
        #expect(moved.nodes["b"] == nil && moved.editorState("b").draft == nil && !moved.hasLocalChanges)
    }

    @Test func pathsThisAppDoesNotKnowAreSkipped() async throws {
        let (ws, _, store) = try await site()
        try ws.update("a") { try $0.setTitle("A2") }
        try ws.commit(message: "Edit")
        var q = store.queue("main")
        q[0].changes.append(FileChange(path: "README.md", content: "# Hello"))
        try store.saveQueue(q, for: "main")
        let reopened = try #require(try SiteWorkspace.open("main", store: store))
        #expect(reopened.nodes["a"]?.title == "A2")
    }

    @Test func stateFilesGetNoFileDatesAndAreNotPublishedNodes() async throws {
        let (ws, m, _) = try await site()
        _ = try await ws.sync(client: client(m), publishedBranch: "main")
        #expect(!m.requests.contains { $0.key.contains("/commits?") && $0.key.contains("breezy") })
        #expect(ws.state.fileDates?.keys.contains(aState) != true)
        #expect(ws.state.publishedFiles?.keys.sorted() == ["src/nodes/a.md", "src/nodes/b.md"])
    }

    @Test func copiesFromOlderBuildsGetTheirStatesOnce() async throws {
        let (ws, m, store) = try await site()
        var old = ws.state
        old.base.states = nil
        try store.saveBranchState(old)
        let reopened = try #require(try SiteWorkspace.open("main", store: store))
        #expect(reopened.editorState("a").isEmpty)
        let trees = m.count("GET /git/trees/t1?recursive=1")
        _ = try await reopened.sync(client: client(m))
        #expect(reopened.editorState("a").draft?.text == "Old draft")
        _ = try await reopened.sync(client: client(m))
        #expect(m.count("GET /git/trees/t1?recursive=1") == trees + 1)
    }
}
