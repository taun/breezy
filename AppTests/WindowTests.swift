import Foundation
import Testing

/// Several windows: each keeps its own UI state, and the app-wide sheets and alerts show in one.
@MainActor @Suite struct WindowTests {
    @Test func theFirstWindowIsTheMainOneAndLaterOnesGetTheirOwnKeys() {
        var r = WindowRegistry()
        var n = 0
        let next = { n += 1; return "w\(n)" }
        let first = r.claim(by: UUID(), newID: next)
        let second = r.claim(by: UUID(), newID: next)
        #expect(first == "" && second == "w1")
        #expect(r.front == "w1")
        // A window opened for a node never takes the main window's state, even when no window has it.
        var fresh = WindowRegistry()
        let forNode = fresh.claim(by: UUID(), main: false, newID: next)
        #expect(forNode == "w2")
        #expect(WindowKeys(id: "")("root.sheet") == "root.sheet")
        #expect(WindowKeys(id: "w1")("root.sheet") == "root.sheet@w1")
    }

    /// Restored windows come up in no particular order: only activation (the key window) puts one in front.
    @Test func aRestoredWindowStaysBehindUntilActivated() {
        var r = WindowRegistry()
        let a = UUID(), b = UUID()
        let aCame = r.appear("a", by: a)
        r.activate("a")
        let bCame = r.appear("b", by: b)
        #expect(aCame && bCame)
        #expect(r.front == "a")
        r.activate("b")
        #expect(r.front == "b")
        let again = r.appear("a", by: a) // already open: no change
        #expect(again)
        #expect(r.front == "b")
    }

    @Test func openInNewWindowShowsTheNodeInThatWindowOnly() async {
        let h = Harness()
        await h.connect()
        let main = h.model.windowAppeared(nil, by: UUID())
        h.defaults.set(SelectionByBranch.encode(["main": "a"]), forKey: WindowKeys.selection)
        let window = UUID()
        let other = h.model.windowAppeared(nil, by: window, showing: "b")
        #expect(main == "")
        #expect(other != "")
        let otherMap = SelectionByBranch.decode(h.defaults.string(forKey: WindowKeys(id: other)(WindowKeys.selection)) ?? "")
        #expect(otherMap == ["main": "b"])
        #expect(h.defaults.string(forKey: WindowKeys(id: other)(WindowKeys.compactColumn)) == "detail") // narrow: on the node
        #expect(SelectionByBranch.decode(h.defaults.string(forKey: WindowKeys.selection) ?? "") == ["main": "a"])
        // A window that kept its ID is not given a node again (a relaunch restoring it).
        #expect(h.model.windowAppeared(other, by: window, showing: "a") == other)
        #expect(SelectionByBranch.decode(h.defaults.string(forKey: WindowKeys(id: other)(WindowKeys.selection)) ?? "") == ["main": "b"])
    }

    @Test func anAlertStaysInTheWindowItWentUpInUntilThatWindowGoes() {
        let h = Harness()
        let a = h.model.windowAppeared(nil, by: UUID())
        let b = h.model.windowAppeared(nil, by: UUID())
        #expect(h.model.windows.front == b)
        h.model.errorMessage = "Oops"
        #expect(h.model.shows(.error, in: b))
        #expect(!h.model.shows(.error, in: a))
        // Clicking the other window does not move it.
        h.model.windowActivated(a)
        #expect(h.model.shows(.error, in: b))
        #expect(!h.model.shows(.error, in: a))
        // Its window closed: the front one shows it.
        h.model.windowHidden(b)
        #expect(h.model.shows(.error, in: a))
        // Dismissed and raised again: the front window at that time.
        h.model.errorMessage = nil
        let c = h.model.windowAppeared(nil, by: UUID())
        h.model.showConflicts = true
        #expect(h.model.shows(.conflicts, in: c))
        #expect(!h.model.shows(.conflicts, in: a))
    }

    /// Regression (review): what was shown in a window that left the screen moves to one on screen; a window only out
    /// of sight keeps its ID from new windows, and one whose views are gone comes back as itself.
    @Test func aWindowOutOfSightKeepsItsIDButShowsNothing() {
        let h = Harness()
        let mainWindow = UUID()
        let main = h.model.windowAppeared(nil, by: mainWindow)
        let other = h.model.windowAppeared(nil, by: UUID())
        h.model.errorMessage = "Oops" // in `other`, the front window
        h.model.windowHidden(other)
        #expect(h.model.windows.front == main)
        #expect(h.model.shows(.error, in: main))
        h.model.windowHidden(main)
        // Both out of sight but alive: a new window gets an ID of its own.
        let third = h.model.windowAppeared(nil, by: UUID())
        #expect(third != main && third != other)
        // The main window's views go and its scene comes back (iPadOS reconnecting it makes a new WindowRoot).
        h.model.windowGone(main, by: mainWindow)
        #expect(h.model.windowAppeared(main, by: UUID()) == main)
        h.model.windowActivated(main)
        #expect(h.model.windows.front == main)
    }

    /// Regression (review): a second scene restored with the ID of a window only minimized shared its state.
    @Test func aWindowOnlyOutOfSightKeepsItsIDFromASecondOne() {
        let h = Harness()
        let a = h.model.windowAppeared(nil, by: UUID())
        let b = h.model.windowAppeared(nil, by: UUID())
        h.model.windowHidden(b) // minimized: still alive
        #expect(h.model.windowAppeared(b, by: UUID()) != b)
        #expect(a == "")
    }

    /// Regression (review): with every window out of sight, the conflicts sheet came up in all of them.
    @Test func withNoWindowOnScreenASheetStaysInOne() {
        let h = Harness()
        let a = h.model.windowAppeared(nil, by: UUID())
        let b = h.model.windowAppeared(nil, by: UUID())
        h.model.windowActivated(a)
        h.model.showConflicts = true
        h.model.windowHidden(a) // it goes to b…
        h.model.windowHidden(b) // …and stays there, in that one only
        #expect(h.model.shows(.conflicts, in: b))
        #expect(!h.model.shows(.conflicts, in: a))
    }

    /// Regression (review): a window whose ID came late had made the main window, restored meanwhile, take a copy.
    @Test func theMainWindowGetsItsIDBackFromAWindowWhoseIDCameLate() {
        let h = Harness()
        let late = UUID(), main = UUID()
        #expect(h.model.windowAppeared(nil, by: late) == "") // no ID yet: given the main window's
        h.defaults.set("commit", forKey: WindowKeys.sheet) // the main window had Commit open
        let copy = h.model.windowAppeared("", by: main) // the main window, restored with ""
        #expect(copy != "")
        #expect(h.model.windows.front == "") // a copy goes behind, like any window coming back
        h.defaults.set(SelectionByBranch.encode(["main": "b"]), forKey: WindowKeys(id: copy)(WindowKeys.selection))
        #expect(h.model.windowRestoredLate(given: "", restored: "w1", by: late) == "w1")
        #expect(h.model.windows.moved[main] == "") // the main window moves back to ""…
        #expect(SelectionByBranch.decode(h.defaults.string(forKey: WindowKeys.selection) ?? "") == ["main": "b"]) // …with its state
        #expect(h.defaults.string(forKey: WindowKeys.sheet) == "commit") // and its sheet
        h.model.windowMoveDone(main)
        #expect(h.model.windows.open.contains("") && !h.model.windows.open.contains(copy))
    }

    /// Regression (review): a window restored minimized whose ID came late counted as on screen under its own ID.
    @Test func aLateIDKeepsTheWindowHidden() {
        let h = Harness()
        let late = UUID()
        _ = h.model.windowAppeared(nil, by: UUID()) // the main window
        let given = h.model.windowAppeared(nil, by: late)
        h.model.windowHidden(given) // reported minimized
        let own = h.model.windowRestoredLate(given: given, restored: "w1", by: late)
        #expect(own == "w1")
        #expect(!h.model.windows.isVisible("w1"))
    }

    /// Regression (review): a sheet up in a window that was minimized jumped back to it when it came back, closing
    /// under the user in the window they had gone on in.
    @Test func aSheetStaysInTheWindowItWentToWhenItsFirstCameBack() {
        let h = Harness()
        let a = h.model.windowAppeared(nil, by: UUID())
        let b = h.model.windowAppeared(nil, by: UUID())
        h.model.windowActivated(a)
        h.model.showConflicts = true
        h.model.windowHidden(a)
        #expect(h.model.shows(.conflicts, in: b))
        h.model.windowActivated(a) // back from the Dock
        #expect(h.model.shows(.conflicts, in: b))
        #expect(!h.model.shows(.conflicts, in: a))
    }

    /// Regression (review): conflicts found with every window out of sight, shown in a new window, jumped to the
    /// next window brought back.
    @Test func aNewWindowKeepsWhatWentUpWithNoWindowOnScreen() {
        let h = Harness()
        let a = h.model.windowAppeared(nil, by: UUID())
        h.model.windowHidden(a)
        h.model.showConflicts = true
        let b = h.model.windowAppeared(nil, by: UUID()) // File › New Window: in front as it comes up
        h.model.windowActivated(b) // its WindowRoot, once key
        h.model.windowActivated(a) // back from the Dock
        #expect(h.model.shows(.conflicts, in: b))
    }

    /// Regression (review): on iPad (which never says a window closed), closing the only window and opening Breezy
    /// again gave a blank window.
    @Test func theMainWindowsIDIsFreeOnceItsWindowIsGone() {
        let h = Harness()
        let old = UUID()
        let main = h.model.windowAppeared(nil, by: old)
        h.model.windowGone(main, by: old)
        #expect(h.model.windowAppeared(nil, by: UUID()) == main)
    }

    /// Regression (review): an error shown in a window whose own ID then came late went to another window.
    @Test func whatIsUpInAWindowGoesWithItToItsOwnID() {
        let h = Harness()
        _ = h.model.windowAppeared(nil, by: UUID()) // the main window
        let late = UUID()
        let given = h.model.windowAppeared(nil, by: late)
        h.model.report("Oops", in: given)
        h.model.wantsSettings = given
        let own = h.model.windowRestoredLate(given: given, restored: "w1", by: late)
        h.model.windowActivated(own)
        #expect(h.model.shows(.error, in: own))
        #expect(h.model.settingsWindow == own)
    }

    /// Regression (review): a sheet whose window left with no other on screen jumped back to it when it returned.
    @Test func aSheetStaysWithTheFirstWindowBackWhenItsOwnWasMinimized() {
        let h = Harness()
        let a = h.model.windowAppeared(nil, by: UUID())
        let b = h.model.windowAppeared(nil, by: UUID())
        h.model.windowHidden(b)
        h.model.windowActivated(a)
        h.model.showConflicts = true
        h.model.windowHidden(a) // none on screen: it stays tied to `a`
        h.model.windowActivated(b) // `b` back first: it takes it
        h.model.windowActivated(a)
        #expect(h.model.shows(.conflicts, in: b))
    }

    /// Regression (review): a late onDisappear of a scene's old view hid the window that had taken its ID over.
    @Test func aLateGoneFromAnOldViewLeavesTheNewOneAlone() {
        let h = Harness()
        let old = UUID(), new = UUID()
        _ = h.model.windowAppeared(nil, by: UUID()) // the main window
        let id = h.model.windowAppeared(nil, by: old)
        h.model.windowHidden(id) // put away
        #expect(h.model.windowAppeared(id, by: new) != id) // on the Mac a copy; the iPad's take-over is below
        var r = WindowRegistry()
        _ = r.appear("x", by: old)
        r.hide("x")
        let took = r.appear("x", by: new, takeOver: true)
        r.activate("x")
        r.release("x", by: old) // the old view's late onDisappear
        #expect(took && r.isVisible("x") && r.owner(of: "x") == new)
    }

    /// Regression (review): a sheet opened in a window while it had a copy ID closed when it moved back.
    @Test func aSheetOpenedOnTheCopyMovesBackWithTheWindow() {
        let h = Harness()
        let late = UUID(), main = UUID()
        _ = h.model.windowAppeared(nil, by: late)
        let copy = h.model.windowAppeared("", by: main)
        h.defaults.set("commit", forKey: WindowKeys(id: copy)(WindowKeys.sheet))
        _ = h.model.windowRestoredLate(given: "", restored: "w1", by: late)
        #expect(h.defaults.string(forKey: WindowKeys.sheet) == "commit")
    }

    /// Regression (review): an iPad window whose views went and came back stayed hidden, so using it did nothing.
    @Test func aWindowWhoseViewsComeBackIsOnScreen() {
        let h = Harness()
        let a = UUID()
        let id = h.model.windowAppeared(nil, by: a)
        _ = h.model.windowAppeared(nil, by: UUID())
        h.model.windowGone(id, by: a)
        let back = UUID()
        _ = h.model.windowAppeared(id, by: back) // no windowActivated: on iOS nothing else calls it
        #expect(h.model.windows.isVisible(id))
        h.model.windowUsed(id)
        #expect(h.model.windows.front == id)
    }

    /// Regression (review): a window's onDisappear, running after it left the screen, brought it back in front.
    @Test func useOfAWindowOffScreenIsIgnored() {
        let h = Harness()
        let a = h.model.windowAppeared(nil, by: UUID())
        let b = h.model.windowAppeared(nil, by: UUID())
        h.model.windowHidden(a)
        h.model.windowUsed(a)
        #expect(h.model.windows.front == b)
    }

    /// Regression (review): a window opened for a node before the workspace was open saved it under a guessed branch.
    @Test func aNodeForAWindowWaitsForTheBranch() async {
        let h = Harness()
        let id = h.model.windowAppeared(nil, by: UUID(), showing: "b")
        #expect(h.defaults.string(forKey: WindowKeys(id: id)(WindowKeys.selection)) == nil)
        await h.connect()
        #expect(SelectionByBranch.decode(h.defaults.string(forKey: WindowKeys(id: id)(WindowKeys.selection)) ?? "") == ["main": "b"])
    }

    /// Regression (review): on the Mac, closing the only window and opening a new one gave a blank window.
    @Test func aClosedMainWindowIsTheNextNewWindow() {
        let h = Harness()
        let main = h.model.windowAppeared(nil, by: UUID())
        h.model.windowHidden(main) // onDisappear comes too
        h.model.windowClosed(main)
        #expect(h.model.windowAppeared(nil, by: UUID()) == main)
    }

    /// Regression: a Mac window restored minimized gets its scene storage after it appeared. It was given the main
    /// window's ID as a new window, kept it after its own came, and so held it for good.
    @Test func aWindowWhoseIDArrivesLateGivesBackTheOneItWasGiven() {
        let h = Harness()
        let window = UUID()
        let given = h.model.windowAppeared(nil, by: window)
        #expect(given == "")
        // Its own ID arrives (WindowRoot.onChange(of: id)).
        #expect(h.model.windowRestoredLate(given: given, restored: "restored", by: window) == "restored")
        #expect(h.model.windowAppeared(nil, by: UUID()) == "") // the main window's ID is free again
    }

    /// Regression (review): two windows restored with the same ID shared one set of state.
    @Test func aSecondWindowWithTheSameIDGetsACopyOfItsOwn() {
        let h = Harness()
        let main = h.model.windowAppeared(nil, by: UUID())
        h.defaults.set(SelectionByBranch.encode(["main": "a"]), forKey: WindowKeys.selection)
        h.defaults.set("commit", forKey: WindowKeys.sheet)
        let copy = h.model.windowAppeared(main, by: UUID()) // another scene that kept the ID ""
        #expect(copy != main)
        #expect(SelectionByBranch.decode(h.defaults.string(forKey: WindowKeys(id: copy)(WindowKeys.selection)) ?? "") == ["main": "a"])
        #expect(h.defaults.string(forKey: WindowKeys(id: copy)(WindowKeys.sheet)) == nil) // the sheet stays with the first
    }

    /// Regression (review): conflicts up in a window out of sight could not be brought up anywhere else.
    @Test func askingInAWindowShowsItThereEvenWhenAlreadyUp() {
        let h = Harness()
        let a = h.model.windowAppeared(nil, by: UUID())
        let b = h.model.windowAppeared(nil, by: UUID())
        h.model.windowActivated(a)
        h.model.showConflicts = true // a sync, with `a` in front
        #expect(h.model.shows(.conflicts, in: a))
        h.model.request(.conflicts, in: b) // the sync status clicked in `b`
        #expect(h.model.shows(.conflicts, in: b))
        #expect(!h.model.shows(.conflicts, in: a))
        // A new error goes to the front window, even with an older one up elsewhere.
        h.model.report("First", in: b)
        #expect(h.model.shows(.error, in: b))
        h.model.errorMessage = "Second"
        #expect(h.model.shows(.error, in: a))
    }

    /// Regression (review): with the asking window out of sight, Settings opened in every window.
    @Test func settingsOpenInOneWindow() {
        let h = Harness()
        let a = h.model.windowAppeared(nil, by: UUID())
        let b = h.model.windowAppeared(nil, by: UUID())
        h.model.wantsSettings = a
        #expect(h.model.settingsWindow == a)
        h.model.windowHidden(a)
        #expect(h.model.settingsWindow == b)
        h.model.windowHidden(b) // none on screen: none until one comes back
        #expect(h.model.settingsWindow == nil)
        h.model.windowActivated(a)
        #expect(h.model.settingsWindow == a)
    }

    /// Regression (review): conflicts found with every window out of sight followed whichever window was in front.
    @Test func whatWentUpWithNoWindowOnScreenStaysInTheFirstOneBack() {
        let h = Harness()
        let a = h.model.windowAppeared(nil, by: UUID())
        let b = h.model.windowAppeared(nil, by: UUID())
        h.model.windowHidden(a)
        h.model.windowHidden(b)
        h.model.showConflicts = true
        h.model.windowActivated(a)
        h.model.windowActivated(b)
        #expect(h.model.shows(.conflicts, in: a))
        #expect(!h.model.shows(.conflicts, in: b))
    }

    /// Regression (review): only a window's own WindowRoot registers it; a view's report of use cannot add one.
    @Test func useOfAnUnknownWindowIsIgnored() {
        let h = Harness()
        let main = h.model.windowAppeared(nil, by: UUID())
        h.model.windowUsed("elsewhere")
        h.model.windowUsed(nil)
        #expect(h.model.windows.open == [main])
    }

    @Test func theStateOfWindowsLongClosedIsRemoved() {
        let h = Harness()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let later = start.addingTimeInterval(AppModel.windowStateLifetime + 1)
        // Windows of an earlier run: "old" not used since `start`.
        h.defaults.set(["old": start.timeIntervalSince1970], forKey: "window.lastUsed")
        let main = h.model.windowAppeared(nil, by: UUID(), now: start)
        let open = h.model.windowAppeared(nil, by: UUID(), now: start)
        for id in [main, "old", open] { h.defaults.set("{}", forKey: WindowKeys(id: id)(WindowKeys.selection)) }
        // `open` is open in this run, however long ago it was used; `main` is never removed.
        h.model.pruneWindows(now: later)
        #expect(h.defaults.string(forKey: WindowKeys(id: "old")(WindowKeys.selection)) == nil)
        #expect(h.defaults.string(forKey: WindowKeys(id: open)(WindowKeys.selection)) != nil)
        #expect(h.defaults.string(forKey: WindowKeys.selection) != nil)
    }

    /// Regression (review): conflicts found while another sheet was open in the window never came up.
    @Test func conflictsComeBeforeSheetsThatKeepTheirState() {
        typealias P = RootView.Presented
        #expect(P.choose(stored: .commit, conflicts: true, branchDeleted: false, newNode: false) == .conflicts)
        #expect(P.choose(stored: .commit, conflicts: false, branchDeleted: true, newNode: false) == .branchDeleted)
        #expect(P.choose(stored: nil, conflicts: true, branchDeleted: false, newNode: true) == .conflicts)
        // Settings, Publish and Branches hold what is not all saved: conflicts wait for them.
        #expect(P.choose(stored: .branches, conflicts: true, branchDeleted: false, newNode: false) == .stored(.branches))
        #expect(P.choose(stored: .settings, conflicts: true, branchDeleted: false, newNode: false) == .stored(.settings))
        #expect(P.choose(stored: .publish, conflicts: true, branchDeleted: false, newNode: false) == .stored(.publish))
        // Once dealt with, the sheet that stepped aside comes back.
        #expect(P.choose(stored: .commit, conflicts: false, branchDeleted: false, newNode: false) == .stored(.commit))
        #expect(P.choose(stored: nil, conflicts: false, branchDeleted: false, newNode: true) == .newNode)
    }

    /// Regression (review): a window that held the main window's ID until its own came late left its changes there.
    @Test func aWindowWhoseIDCameLateLeavesTheMainStateAsItWas() {
        let h = Harness()
        h.defaults.set("commit", forKey: WindowKeys.sheet)
        let late = UUID()
        let given = h.model.windowAppeared(nil, by: late)
        #expect(given == "")
        h.defaults.set("settings", forKey: WindowKeys.sheet) // written while it held ""
        _ = h.model.windowRestoredLate(given: given, restored: "w1", by: late)
        #expect(h.defaults.string(forKey: WindowKeys.sheet) == "commit")
    }

    /// Regression (review): a copy of a closed window's ID was moved onto a later window with that ID.
    @Test func copiesOfAClosedWindowAreForgotten() {
        var r = WindowRegistry()
        let m = UUID(), w2 = UUID()
        _ = r.claim(by: m)
        let c = r.copy("", for: w2)
        r.close("")
        #expect(r.copy(of: "") == nil)
        #expect(r.isVisible(c))
    }
}
