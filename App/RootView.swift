import BreezyKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    /// The window this is; it keeps the state below for itself (Windows.swift).
    let window: WindowKeys
    // UI state saved in the app's preferences, so a relaunch looks unchanged even after the app was swiped away or
    // stopped (iOS discards SceneStorage in those cases). Content edits are saved separately, to disk, as typed.
    @AppStorage private var sheetRaw: String
    /// Last selected node per branch, as JSON [branch: slug].
    @AppStorage private var selectionJSON: String
    @AppStorage private var columnsRaw: String
    /// iPhone (collapsed split view): whether the list or the editor was showing.
    @AppStorage private var compactColumnRaw: String
    /// The Commit sheet's message (CommitView), cleared here when that sheet goes with nothing left to commit.
    @AppStorage("commit.message") private var commitMessage = ""
    /// The node list's New Node sheet is up (NodeListView), covering this view.
    @AppStorage private var showNewRaw: Bool

    init(window: WindowKeys) {
        self.window = window
        _sheetRaw = AppStorage(wrappedValue: "", window(WindowKeys.sheet))
        _selectionJSON = AppStorage(wrappedValue: "{}", window(WindowKeys.selection))
        _columnsRaw = AppStorage(wrappedValue: "automatic", window(WindowKeys.columns))
        _compactColumnRaw = AppStorage(wrappedValue: "sidebar", window(WindowKeys.compactColumn))
        _showNewRaw = AppStorage(wrappedValue: false, window(WindowKeys.showNew))
    }

    private var compactColumn: Binding<NavigationSplitViewColumn> {
        Binding(
            get: { CompactNavigation.column(compactColumnRaw) },
            set: { compactColumnRaw = CompactNavigation.raw($0) })
    }

    /// The selected node of the current branch; switching branches brings back that branch's selection.
    private var selection: Binding<String?> {
        Binding(
            get: { SelectionByBranch.decode(selectionJSON)[model.currentBranch] },
            set: { slug in
                // A node chosen: the user is in this window. (A branch switch changes the selection without coming
                // through here; a list clearing it, when the node goes, is not the user.)
                if slug != nil { model.windowUsed(window.id) }
                var map = SelectionByBranch.decode(selectionJSON)
                map[model.currentBranch] = slug
                selectionJSON = SelectionByBranch.encode(map)
            })
    }

    private var columns: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: {
                let saved: NavigationSplitViewVisibility = ["all": .all, "doubleColumn": .doubleColumn, "detailOnly": .detailOnly][columnsRaw] ?? .automatic
                // With nothing selected the list is always shown: a hidden list and an empty editor is a blank window.
                return saved == .detailOnly && selection.wrappedValue == nil ? .all : saved
            },
            set: { v in columnsRaw = v == .all ? "all" : v == .doubleColumn ? "doubleColumn" : v == .detailOnly ? "detailOnly" : "automatic" })
    }
    @Environment(\.openURL) private var openURL

    enum Sheet: String, Identifiable {
        case settings, branches, commit, publish
        var id: String { rawValue }
    }

    var body: some View {
        let appModel = model
        @Bindable var model = model
        Group {
            if let ws = model.workspace {
                NavigationSplitView(columnVisibility: columns, preferredCompactColumn: compactColumn) {
                    sidebar(ws)
                } detail: {
                    if let slug = selection.wrappedValue, ws.nodes[slug] != nil {
                        NodeEditorView(workspace: ws, slug: slug, window: window).id(slug)
                    } else if let slug = selection.wrappedValue, ws.deletedNodes[slug] != nil {
                        DeletedNodeView(workspace: ws, slug: slug).id(slug)
                    } else {
                        ContentUnavailableView("No node selected", systemImage: "doc.text", description: Text("Choose a node, or add one with +."))
                    }
                }
                #if os(macOS)
                .toolbar { toolbar(ws) }
                #endif
                .onChange(of: selection.wrappedValue) { _, slug in
                    compactColumnRaw = CompactNavigation.afterSelectionChange(to: slug)
                }
                .onAppear {
                    compactColumnRaw = CompactNavigation.restored(compactColumnRaw, hasSelection: selection.wrappedValue != nil)
                }
            } else if model.isBusy {
                FirstDownloadView()
            } else if !model.hasToken {
                NavigationStack { SettingsView(covered: presentedSheet != nil) }
            } else if !model.isOnline {
                ContentUnavailableView("Not on this device yet", systemImage: "wifi.slash",
                                       description: Text("Connect to the internet once to download the site. After that Breezy works offline."))
            } else {
                NavigationStack { SettingsView(covered: presentedSheet != nil) }
            }
        }
        // One sheet per window: a window shows one at a time (a second asked for at once may never come up).
        .sheet(item: presented) { p in
            Group {
                switch p {
                case let .stored(s):
                    NavigationStack {
                        switch s {
                        case .settings: SettingsView(close: { sheetRaw = "" }) // shows errors itself (it has a sheet of its own)
                        case .branches: BranchesView().errorAlert()
                        case .commit: CommitView().errorAlert()
                        case .publish: PublishView().errorAlert()
                        }
                    }
                    .macSheetFrame(minWidth: 460, minHeight: 480)
                case .conflicts:
                    NavigationStack { ConflictsView() }.macSheetFrame(minWidth: 560, minHeight: 520)
                case .branchDeleted:
                    NavigationStack { BranchDeletedView().errorAlert() }.macSheetFrame(minWidth: 480, minHeight: 380)
                case .newNode:
                    if let ws = appModel.workspace {
                        NavigationStack { NewNodeView(workspace: ws, selection: selection).errorAlert() }
                            .macSheetFrame(minWidth: 420, minHeight: 320)
                    }
                }
            }
            .activityBanner()
            .environment(appModel)
            .environment(\.window, window)
        }
        .activityBanner()
        .onChange(of: model.settingsWindow, initial: true) { openSettingsIfAsked() }
        // Settings asked for while conflicts or a deleted branch were up: it opens once they close.
        .onChange(of: sharedSheetUp) { _, up in if !up { openSettingsIfAsked() } }
        .onChange(of: sheetRaw) { _, raw in if raw.isEmpty { openSettingsIfAsked() } }
        // A Commit sheet stepped aside for conflicts, and everything was committed meanwhile (in another window): it
        // does not come back empty.
        .onChange(of: model.workspace.map { CommitTarget(branch: $0.branch, hasChanges: $0.hasChanges) }) { old, new in
            guard let new else { return }
            // Another branch: a Commit sheet that stepped aside does not come back for it (the message is kept).
            if old?.branch != new.branch {
                if sheetRaw == Sheet.commit.rawValue && presentedSheet != .stored(.commit) { sheetRaw = "" }
                return
            }
            // Only everything committed on the same branch (a branch switch is not a commit).
            guard !new.hasChanges else { return }
            if sheetRaw == Sheet.commit.rawValue && presentedSheet != .stored(.commit) {
                sheetRaw = ""
                commitMessage = ""
            }
        }
        // A window used is the front one, for the app-wide sheets and alerts that follow (an iPad's windows side by
        // side are all active, so being active does not say which one the user is in).
        .onChange(of: sheetRaw) { _, raw in if !raw.isEmpty { model.windowUsed(window.id) } }
        // Shown by the sheet on top when there is one (each shows them): an alert under a sheet does not come up.
        .errorAlert(covered: settingsInPlace || presentedSheet != nil)
    }

    private func shown(_ p: AppModel.Presentation, _ isUp: Bool) -> Bool { isUp && model.shows(p, in: window.id) }

    /// Settings asked for, here: opened unless another sheet is up (conflicts, a deleted branch, or one that stepped
    /// aside for them); it waits until that closes.
    private func openSettingsIfAsked() {
        guard model.settingsWindow == window.id, !sharedSheetUp, sheetRaw.isEmpty else { return }
        sheetRaw = Sheet.settings.rawValue
        model.wantsSettings = nil
    }

    /// Conflicts or the deleted branch is up in this window.
    private var sharedSheetUp: Bool {
        presentedSheet == .conflicts || presentedSheet == .branchDeleted
    }

    /// What this window's one sheet can be.
    enum Presented: Hashable, Identifiable {
        case stored(Sheet), conflicts, branchDeleted, newNode

        /// Conflicts and a deleted branch come first: a sheet open meanwhile (Commit, New Node) steps aside and comes
        /// back after them as it was (its state is saved). Settings, Publish and Branches stay, as what they hold is not
        /// all saved (a token as typed, a publish under way, merge options), and they come up once it is closed.
        static func choose(stored: Sheet?, conflicts: Bool, branchDeleted: Bool, newNode: Bool) -> Presented? {
            if let stored, stored != .commit { return .stored(stored) }
            if conflicts { return .conflicts }
            if branchDeleted { return .branchDeleted }
            if let stored { return .stored(stored) }
            return newNode ? .newNode : nil
        }

        var id: String {
            switch self {
            case let .stored(s): s.rawValue
            case .conflicts: "conflicts"
            case .branchDeleted: "branchDeleted"
            case .newNode: "newNode"
            }
        }
    }

    /// The sheet this window shows (`Presented.choose`).
    private var presentedSheet: Presented? {
        // Conflicts need a site to show (without one the sheet would be empty).
        // Commit lists the site's changes: without a site it would be empty (and its errors nowhere).
        let stored = Sheet(rawValue: sheetRaw).flatMap { $0 == .commit && model.workspace == nil ? nil : $0 }
        return Presented.choose(stored: stored, conflicts: model.workspace != nil && shown(.conflicts, model.showConflicts),
                         branchDeleted: shown(.branchDeleted, model.showBranchDeleted),
                         newNode: showNewRaw && model.workspace != nil)
    }

    private var presented: Binding<Presented?> {
        let model = model, id = window.id
        let current = presentedSheet // read in body, so a change redraws it
        return Binding(get: { current }, set: { new in
            guard new == nil, let current else { return }
            // Dismissed by the user (swipe, Close, Later).
            switch current {
            case .stored: sheetRaw = ""
            case .conflicts: if model.shows(.conflicts, in: id) { model.showConflicts = false }
            case .branchDeleted: if model.shows(.branchDeleted, in: id) { model.showBranchDeleted = false }
            case .newNode: showNewRaw = false
            }
        })
    }

    /// Settings fills the window (no site yet, or no token): it shows the errors itself, over its own sheet.
    private var settingsInPlace: Bool { model.workspace == nil && !model.isBusy && (!model.hasToken || model.isOnline) }

    /// Uncommitted edits are saved with their branch, so switching never loses them.
    private func requestSwitch(to name: String, in ws: SiteWorkspace) {
        guard name != ws.branch else { return }
        model.windowUsed(window.id) // what goes wrong shows here
        Task { await model.switchBranch(name) }
    }

    /// Branch list (switch) plus the branch management sheet; used by the Mac toolbar menu and the iOS title menu.
    @ViewBuilder
    private func branchMenu(_ ws: SiteWorkspace) -> some View {
        Picker("Branch", selection: Binding(get: { ws.branch }, set: { requestSwitch(to: $0, in: ws) })) {
            ForEach(model.branchNames, id: \.self) { name in
                let onDevice = model.isOnDevice(name)
                Text(model.branchLabel(name))
                    .tag(name)
                    .selectionDisabled(!onDevice && !model.isOnline)
            }
        }
        .pickerStyle(.inline)
        Divider()
        Button { sheetRaw = Sheet.branches.rawValue } label: { Label("Manage Branches & Pull Requests…", systemImage: "arrow.triangle.branch") }
    }

    /// The node list column. On iPhone and iPad its bar carries everything: the title is the branch (tap for the
    /// branch menu), sync status on the left, commit and the other actions on the right.
    @ViewBuilder
    private func sidebar(_ ws: SiteWorkspace) -> some View {
        #if os(iOS)
        NodeListView(workspace: ws, selection: selection, window: window)
            .navigationTitle(ws.branch)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarTitleMenu { branchMenu(ws) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { SyncStatusButton(compact: true) }
                ToolbarItem(placement: .topBarTrailing) { moreMenu(ws) }
            }
            // Commit sits below the list as a plain button, not a toolbar item: the top bar is full on iPhone (iOS hid
            // it in an overflow menu), and iOS 26 draws bottom-toolbar buttons as an unlabeled glass icon.
            .safeAreaInset(edge: .bottom) {
                if ws.hasChanges {
                    let n = ws.changedNodes.count
                    Button { sheetRaw = Sheet.commit.rawValue } label: {
                        Label("Commit \(n) Change\(n == 1 ? "" : "s")", systemImage: "checkmark.circle")
                            .labelStyle(.titleAndIcon).bold()
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
            }
        #else
        NodeListView(workspace: ws, selection: selection, window: window)
        #endif
    }

    private func moreMenu(_ ws: SiteWorkspace) -> some View {
        Menu {
            Button { sheetRaw = Sheet.commit.rawValue } label: { Label("Commit (\(ws.changedNodes.count))", systemImage: "checkmark.circle") }
                .disabled(!ws.hasChanges)
            if !model.isOnDefaultBranch {
                Button { sheetRaw = Sheet.publish.rawValue } label: { Label("Publish \(ws.branch)…", systemImage: "paperplane") }
            }
            if let url = model.websiteURL {
                Button { openURL(url) } label: { Label("View Website", systemImage: "safari") }
            }
            Divider()
            Button { sheetRaw = Sheet.branches.rawValue } label: { Label("Branches & Pull Requests", systemImage: "arrow.triangle.branch") }
            Button { sheetRaw = Sheet.settings.rawValue } label: { Label("Settings", systemImage: "gearshape") }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ ws: SiteWorkspace) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            SyncStatusButton()
            Menu {
                branchMenu(ws)
            } label: {
                Label(ws.branch, systemImage: "arrow.triangle.branch").labelStyle(.titleAndIcon)
            }
            .help("Switch branch, or manage branches and pull requests")
            Button { sheetRaw = Sheet.commit.rawValue } label: {
                Label("Commit (\(ws.changedNodes.count))", systemImage: "checkmark.circle")
            }
            .disabled(!ws.hasChanges)
            .help("Commit all changes to \(ws.branch)")
            if !model.isOnDefaultBranch {
                Button { sheetRaw = Sheet.publish.rawValue } label: { Label("Publish", systemImage: "paperplane") }
                    .help("Merge \(ws.branch) into \(model.defaultBranch) to update the website")
            }
            if let url = model.websiteURL {
                Button { openURL(url) } label: { Label("View Website", systemImage: "safari") }
                    .help(url.absoluteString)
            }
            Button { sheetRaw = Sheet.settings.rawValue } label: { Label("Settings", systemImage: "gearshape") }
        }
    }
}

extension View {
    /// The error alert (`AppModel.errorMessage`), in this view's window only (AppModel.shows). Put on the root of the
    /// window and on each sheet, so the one on top shows it; `covered` while a sheet of this view is up.
    func errorAlert(covered: Bool = false) -> some View { modifier(ErrorAlert(covered: covered)) }
}

private struct ErrorAlert: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.window) private var window
    let covered: Bool

    func body(content: Content) -> some View {
        let model = model, id = window?.id
        let isUp = { model.errorMessage != nil && model.shows(.error, in: id ?? model.windows.front ?? "") }
        let shown = !covered && isUp() // read in body, so a change redraws it
        // Cleared only by the user's OK: not when a sheet coming up covers it (its own alert shows it then).
        content.alert("Breezy", isPresented: Binding(get: { shown }, set: { up in if !up && shown && isUp() { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

/// Shows offline / pending / conflicts / synced; tapping syncs now, or opens the conflicts.
struct SyncStatusButton: View {
    @Environment(AppModel.self) private var model
    /// The window it is in: what it opens shows there.
    @Environment(\.window) private var window

    /// Commits waiting to be pushed, shown as a badge on the compact (icon-only) status.
    private var waiting: Int {
        switch model.syncStatus {
        case let .offline(n), let .pending(n): n
        default: 0
        }
    }
    /// Icon only (narrow iPhone bars); the text is still read by VoiceOver.
    var compact = false

    var body: some View {
        let (text, icon, color) = describe(model.syncStatus)
        Button {
            model.windowUsed(window?.id)
            switch model.syncStatus {
            case .conflicts: model.request(.conflicts, in: window?.id)
            case .branchDeleted: model.request(.branchDeleted, in: window?.id)
            case .noToken: model.wantsSettings = window?.id ?? model.windows.front ?? ""
            default: Task { await model.sync() }
            }
        } label: {
            if model.syncStatus == .syncing {
                ProgressView().controlSize(.small)
            } else {
                if compact {
                    // Icon plus a count of waiting commits; iOS toolbars drop overlays on a Label, so this is a plain HStack.
                    HStack(spacing: 2) {
                        Image(systemName: icon)
                        if waiting > 0 { Text("\(waiting)").font(.caption.bold().monospacedDigit()) }
                    }
                    .foregroundStyle(color)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(text)
                } else {
                    Label(text, systemImage: icon).foregroundStyle(color).labelStyle(.titleAndIcon)
                }
            }
        }
        .disabled(model.syncStatus == .syncing)
        .help(model.lastSyncError ?? "Sync with GitHub")
    }

    private func describe(_ s: AppModel.SyncStatus) -> (String, String, Color) {
        switch s {
        case let .offline(n): (n == 0 ? "Offline" : "Offline · \(n) to push", "wifi.slash", .secondary)
        case .noToken: ("No GitHub token", "key.slash", .orange)
        case .branchDeleted: ("Deleted on GitHub", "exclamationmark.triangle.fill", .orange)
        case .syncing: ("Syncing", "arrow.triangle.2.circlepath", .secondary)
        case let .conflicts(n): ("\(n) conflict\(n == 1 ? "" : "s")", "exclamationmark.triangle.fill", .orange)
        case let .pending(n): (n == 0 ? "Not pushed" : "\(n) to push", "arrow.up.circle", .blue)
        case .failed: ("Sync failed", "exclamationmark.icloud", .red)
        case .synced: ("Synced", "checkmark.icloud", .secondary)
        }
    }
}

