import BreezyKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    // UI state saved in the app's preferences, so a relaunch looks unchanged even after the app was swiped away or
    // stopped (iOS discards SceneStorage in those cases). Content edits are saved separately, to disk, as typed.
    @AppStorage("root.sheet") private var sheetRaw = ""
    /// Last selected node per branch, as JSON [branch: slug].
    @AppStorage("root.selectionByBranch") private var selectionJSON = "{}"
    @AppStorage("root.columns") private var columnsRaw = "automatic"
    /// iPhone (collapsed split view): whether the list or the editor was showing.
    @AppStorage("root.compactColumn") private var compactColumnRaw = "sidebar"

    private var compactColumn: Binding<NavigationSplitViewColumn> {
        Binding(
            get: { CompactNavigation.column(compactColumnRaw) },
            set: { compactColumnRaw = CompactNavigation.raw($0) })
    }

    private var sheet: Binding<Sheet?> {
        Binding(get: { Sheet(rawValue: sheetRaw) }, set: { sheetRaw = $0?.rawValue ?? "" })
    }

    /// The selected node of the current branch; switching branches brings back that branch's selection.
    private var selection: Binding<String?> {
        Binding(
            get: { Self.decode(selectionJSON)[model.currentBranch] },
            set: { slug in
                var map = Self.decode(selectionJSON)
                map[model.currentBranch] = slug
                selectionJSON = (try? String(data: JSONEncoder().encode(map), encoding: .utf8)) ?? "{}"
            })
    }

    private static func decode(_ json: String) -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(json.utf8))) ?? [:]
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
                        NodeEditorView(workspace: ws, slug: slug).id(slug)
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
                NavigationStack { SettingsView() }
            } else if !model.isOnline {
                ContentUnavailableView("Not on this device yet", systemImage: "wifi.slash",
                                       description: Text("Connect to the internet once to download the site. After that Breezy works offline."))
            } else {
                NavigationStack { SettingsView() }
            }
        }
        .sheet(item: sheet) { s in
            NavigationStack {
                switch s {
                case .settings: SettingsView(close: { sheetRaw = "" })
                case .branches: BranchesView()
                case .commit: CommitView()
                case .publish: PublishView()
                }
            }
            .activityBanner()
            .macSheetFrame(minWidth: 460, minHeight: 480)
            .environment(appModel)
        }
        .sheet(isPresented: $model.showBranchDeleted) {
            NavigationStack { BranchDeletedView() }.activityBanner().macSheetFrame(minWidth: 480, minHeight: 380).environment(appModel)
        }
        .sheet(isPresented: $model.showConflicts) {
            NavigationStack { ConflictsView() }.activityBanner().macSheetFrame(minWidth: 560, minHeight: 520).environment(appModel)
        }
        .activityBanner()
        .onChange(of: model.wantsSettings) { _, wants in
            if wants { sheetRaw = Sheet.settings.rawValue; model.wantsSettings = false }
        }
        .alert("Breezy", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    /// Uncommitted edits are saved with their branch, so switching never loses them.
    private func requestSwitch(to name: String, in ws: SiteWorkspace) {
        guard name != ws.branch else { return }
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
        NodeListView(workspace: ws, selection: selection)
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
                    let n = ws.changes.count
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
        NodeListView(workspace: ws, selection: selection)
        #endif
    }

    private func moreMenu(_ ws: SiteWorkspace) -> some View {
        Menu {
            Button { sheetRaw = Sheet.commit.rawValue } label: { Label("Commit (\(ws.changes.count))", systemImage: "checkmark.circle") }
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
                Label("Commit (\(ws.changes.count))", systemImage: "checkmark.circle")
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

/// Shows offline / pending / conflicts / synced; tapping syncs now, or opens the conflicts.
struct SyncStatusButton: View {
    @Environment(AppModel.self) private var model

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
            switch model.syncStatus {
            case .conflicts: model.showConflicts = true
            case .branchDeleted: model.showBranchDeleted = true
            case .noToken: model.wantsSettings = true
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

