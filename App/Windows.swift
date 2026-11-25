import SwiftUI

// Several windows (the Mac; iPad and iPhone have one, see Info-iOS.plist, and the iOS paths below are for that one
// window, or for when several are allowed again). They share the model, the branch and the content; each keeps its own UI state: the
// selected node, the open sheet, the sidebar, search and filters, the focused field. That state is in @AppStorage like
// the rest (iOS discards scene storage when the app is stopped, see CLAUDE.md › State restoration), under keys ending
// in the window's ID. Only the ID is in scene storage, which is enough: a window that lost it is new, or alone.

/// Which window a view is in, to name the UI state it keeps for itself.
struct WindowKeys: Hashable {
    /// "" for the main window, which uses the keys from before there were several windows: a relaunch that lost scene
    /// storage (iOS after the app was stopped, every iPhone) comes back as the main window, looking as it was left.
    var id = ""

    func callAsFunction(_ key: String) -> String { id.isEmpty ? key : "\(key)@\(id)" }

    static let sheet = "root.sheet"
    /// The selected node per branch, as JSON [branch: slug] (SelectionByBranch).
    static let selection = "root.selectionByBranch"
    static let columns = "root.columns"
    static let compactColumn = "root.compactColumn"
    static let focus = "editor.focus"
    /// The tab of a node with no editor state yet: the last one chosen in this window.
    static let tab = "editor.tab"
    static let draftPage = "editor.draftPage"
    static let search = "list.search"
    static let type = "list.type"
    static let showNew = "list.showNew"
    static let pendingDelete = "list.pendingDelete"
    static let show = "list.show"
    /// Every key a window keeps for itself, removed with the window's state (AppModel.pruneWindows).
    static let perWindow = [sheet, selection, columns, compactColumn, focus, tab, draftPage, search, type, showNew, pendingDelete, show]
}

extension EnvironmentValues {
    /// The window this view is in; nil outside one, so such a view can never pass for the main window.
    @Entry var window: WindowKeys? = nil
}

/// The selected node per branch, stored as JSON [branch: slug].
enum SelectionByBranch {
    static func decode(_ json: String) -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(json.utf8))) ?? [:]
    }

    static func encode(_ map: [String: String]) -> String {
        (try? String(data: JSONEncoder().encode(map), encoding: .utf8)) ?? "{}"
    }
}

/// What a window was opened to show: a node, from Open in New Window. The request makes each value new, so it always
/// opens another window rather than bringing forward one opened for the same node.
struct OpenedNode: Codable, Hashable {
    var slug: String
    var request = UUID()
}

/// The windows, in the order they were last used. App-wide sheets and alerts go to the front one (AppModel.shows).
/// A window that left the screen may come back (iPadOS reconnects a scene from the app switcher, a Mac window tab is
/// brought forward), so it is hidden, not forgotten, and its ID is not given to another window until it is closed.
struct WindowRegistry: Equatable {
    /// The front window last.
    private(set) var open: [String] = []
    /// Not on screen: nothing is shown in it, and it is never the front window.
    private(set) var hidden: Set<String> = []
    /// The live window (WindowRoot) with each ID, to tell a window coming back from a second one with the same ID.
    /// A window whose views are gone (an iPad scene disconnected) has none: its scene coming back takes the ID.
    private var owners: [String: UUID] = [:]
    /// Copies made because a window came up with an ID another live window had: copy → (the ID, the window).
    private var copies: [String: (from: String, window: UUID)] = [:]
    /// Windows to move to another ID (AppModel.windowRestoredLate): window → ID. Each WindowRoot watches its own.
    private(set) var moved: [UUID: String] = [:]

    static func == (a: Self, b: Self) -> Bool {
        a.open == b.open && a.hidden == b.hidden && a.owners == b.owners && a.moved == b.moved
            && a.copies.mapValues(\.from) == b.copies.mapValues(\.from)
    }

    var front: String? { open.last { !hidden.contains($0) } }

    func isVisible(_ id: String) -> Bool { open.contains(id) && !hidden.contains(id) }

    /// The live window with this ID.
    func owner(of id: String) -> UUID? { owners[id] }

    /// The ID for a window that has none (new, or its scene storage discarded): the main window's when no window has
    /// had it yet (unless `main` is false), otherwise a new one. The window comes to the front, as a new window does.
    mutating func claim(by window: UUID, main: Bool = true, newID: () -> String = { String(UUID().uuidString.prefix(8)) }) -> String {
        // Free: no window has had it, or its window is gone (closed on iPad, which says nothing of closing).
        let mainFree = !open.contains("") || (hidden.contains("") && owners[""] == nil)
        let id = main && mainFree ? "" : newID()
        owners[id] = window
        activate(id)
        return id
    }

    /// A window that kept its ID came up. False when another live window has that ID (two scenes restored with the
    /// same one): this one needs another. With `takeOver` (iOS, one window), it is always the same window coming back
    /// (a scene reconnected, which may not have said it went). A window coming back is put behind the others until it
    /// is activated, since restored windows come up in no particular order and only the key one should be in front.
    mutating func appear(_ id: String, by window: UUID, takeOver: Bool = false) -> Bool {
        if let owner = owners[id], owner != window, !takeOver { return false }
        owners[id] = window
        if !open.contains(id) { open.insert(id, at: 0) }
        hidden.remove(id) // its views are up: on screen (a minimized Mac window is reported again by WindowWatcher)
        return true
    }

    /// A new ID for `window`, which came up with `id` while another live window had it. It goes behind the others,
    /// like any window coming back, until it is activated.
    mutating func copy(_ id: String, for window: UUID, newID: () -> String = { String(UUID().uuidString.prefix(8)) }) -> String {
        let copy = newID()
        owners[copy] = window
        open.insert(copy, at: 0)
        copies[copy] = (id, window)
        return copy
    }

    /// The live window that got a copy of `id`, if any, and its copy.
    func copy(of id: String) -> (copy: String, window: UUID)? {
        copies.first { $0.value.from == id && owners[$0.key] == $0.value.window }.map { ($0.key, $0.value.window) }
    }

    /// Moves `window` from `copy` to `id`, keeping its place among the windows.
    mutating func move(_ window: UUID, from copy: String, to id: String) {
        if let i = open.firstIndex(of: copy) { open[i] = id } else { open.insert(id, at: 0) }
        if hidden.remove(copy) != nil { hidden.insert(id) }
        owners[copy] = nil
        owners[id] = window
        copies[copy] = nil
        moved[window] = id
    }

    mutating func moveDone(_ window: UUID) { moved[window] = nil }

    mutating func activate(_ id: String) {
        open.removeAll { $0 == id }
        open.append(id)
        hidden.remove(id)
    }

    mutating func hide(_ id: String) {
        if open.contains(id) { hidden.insert(id) }
    }

    /// The window's views are gone; its scene may come back with the ID and take it.
    mutating func release(_ id: String, by window: UUID) {
        guard owners[id] == window else { return } // taken over meanwhile: not this window's to hide
        hide(id)
        owners[id] = nil
    }

    /// Closed for good (the Mac says so; iPadOS never does): its ID is free again, so the next window without one
    /// can be the main window again.
    mutating func close(_ id: String) {
        open.removeAll { $0 == id }
        hidden.remove(id)
        owners[id] = nil
        copies[id] = nil
        copies = copies.filter { $0.value.from != id } // copies of it: a later window with this ID is another one
    }
}

/// One window: gives it its ID, then shows RootView with that window's state.
struct WindowRoot: View {
    @Environment(AppModel.self) private var model
    /// The node it was opened for (Open in New Window); nil for File › New Window and the first window.
    let opened: OpenedNode?
    @SceneStorage("window.id") private var id: String?
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @Environment(\.controlActiveState) private var activeState
    #endif

    /// This window, as opposed to another one restored with the same ID.
    @State private var instance = UUID()
    /// The ID once the model has accepted it: a window restored with another window's ID is given its own first,
    /// so it never shows (or writes) that window's state.
    @State private var confirmed: String?

    var body: some View {
        // A ZStack, not a Group: a Group's modifiers go to each child, and the placeholder's onDisappear, when RootView
        // replaces it, would hide the window that just got its ID.
        ZStack {
            if let id = confirmed {
                let keys = WindowKeys(id: id)
                RootView(window: keys).id(id).environment(\.window, keys)
            } else {
                Color.clear // for the moment until the window has its ID
            }
        }
        .onAppear {
            let got = model.windowAppeared(id, by: instance, showing: opened?.slug)
            if id != got { id = got }
            confirmed = got
            // Already the window the user is in: the onChange below may have run before it had its ID.
            activateIfInFront(got)
        }
        // Scene storage can arrive after the window appeared (a Mac window restored minimized): the window was given
        // an ID as a new one, and now its own comes. It takes its own and gives the other back.
        .onChange(of: id) { _, restored in
            guard let restored, let given = confirmed, restored != given else { return }
            let got = model.windowRestoredLate(given: given, restored: restored, by: instance)
            if got != restored { id = got }
            confirmed = got
            activateIfInFront(got)
        }
        // Another window came up with this one's ID before it (AppModel.windowRestoredLate): it moves to that ID.
        .onChange(of: model.windows.moved[instance]) { _, to in
            guard let to else { return }
            id = to
            confirmed = to
            model.windowMoveDone(instance)
        }
        // Closed, or only out of sight (an iPad scene disconnected): either way hidden.
        // On iPad its views going is all there is to tell (iPadOS never says a window closed), so its ID is released:
        // its scene coming back takes it, and a new window may have the main window's. A Mac window keeps its ID until
        // AppKit says it closed (WindowWatcher).
        .onDisappear {
            guard let confirmed else { return }
            #if os(iOS)
            flushIfVisible(confirmed)
            model.windowGone(confirmed, by: instance)
            #else
            hide(confirmed)
            #endif
        }
        #if os(macOS)
        // The window the user is in comes to the front: the key window, or the main one while its sheet is key.
        .onChange(of: activeState, initial: true) { _, state in
            if state != .inactive, let confirmed { model.windowActivated(confirmed) }
        }
        // Minimized or closed: SwiftUI says nothing (the window is merely not key; onDisappear also comes for a window
        // only out of sight), so ask AppKit.
        .background(WindowWatcher { event in
            guard let confirmed else { return false }
            switch event {
            case .minimized: hide(confirmed)
            case .restored: model.windowActivated(confirmed)
            case .closed:
                try? model.workspace?.flushEditorStates()
                model.windowClosed(confirmed)
            }
            return true
        })
        #else
        // Going to the background changes nothing here (the app comes back as it was): windows side by side are all
        // active, and come back in no particular order, so which one the user is in is told by use (windowUsed).
        // Only the cursor moves held back are written now, not when the whole app leaves.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { try? model.workspace?.flushEditorStates() }
        }
        #endif
    }
}

extension WindowRoot {
    /// Out of sight: its cursor moves still held back are written now, not when the whole app leaves.
    private func hide(_ id: String) {
        flushIfVisible(id)
        model.windowHidden(id)
    }

    private func flushIfVisible(_ id: String) {
        if model.windows.isVisible(id) { try? model.workspace?.flushEditorStates() }
    }

    private func activateIfInFront(_ id: String) {
        #if os(macOS)
        if activeState != .inactive { model.windowActivated(id) }
        #endif
    }
}

#if os(macOS)
/// Reports the window it is in being minimized (also when it comes up so, restored minimized), brought back or
/// closed. `changed` returns false when it could not take the event yet (the window has no ID yet).
private struct WindowWatcher: NSViewRepresentable {
    enum Event { case minimized, restored, closed }
    let changed: (Event) -> Bool

    func makeNSView(context: Context) -> WatcherView { WatcherView(changed: changed) }
    func updateNSView(_ view: WatcherView, context: Context) {
        view.changed = changed
        view.reportIfMinimized()
    }

    final class WatcherView: NSView {
        var changed: (Event) -> Bool
        /// Whether a window that was already minimized has been reported.
        private var reportedMinimized = false
        // Removed in deinit, which is not on the main actor; NotificationCenter is thread-safe.
        nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

        init(changed: @escaping (Event) -> Bool) {
            self.changed = changed
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        /// After the view update, not during it: the model is observed by the views being updated.
        func reportIfMinimized() {
            guard window?.isMiniaturized == true, !reportedMinimized else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window?.isMiniaturized == true, !self.reportedMinimized else { return }
                self.reportedMinimized = self.changed(.minimized)
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            window.tabbingMode = .disallowed // as BreezyApp says for all windows: never merged into tabs
            let events: [(Notification.Name, Event)] = [(NSWindow.didMiniaturizeNotification, .minimized),
                                                        (NSWindow.didDeminiaturizeNotification, .restored),
                                                        (NSWindow.willCloseNotification, .closed)]
            for (name, event) in events {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if event == .restored { self.reportedMinimized = false }
                        _ = self.changed(event)
                    }
                })
            }
            reportIfMinimized()
        }
    }
}
#endif

