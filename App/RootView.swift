import BreezyKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var sheet: Sheet?
    @Environment(\.openURL) private var openURL

    enum Sheet: String, Identifiable {
        case settings, branches, commit, publish
        var id: String { rawValue }
    }

    var body: some View {
        @Bindable var model = model
        Group {
            if let ws = model.workspace {
                NavigationSplitView {
                    NodeListView(workspace: ws)
                } detail: {
                    if let slug = model.selection, ws.nodes[slug] != nil {
                        NodeEditorView(workspace: ws, slug: slug).id(slug)
                    } else {
                        ContentUnavailableView("No node selected", systemImage: "doc.text", description: Text("Choose a node, or add one with +."))
                    }
                }
                .toolbar { toolbar(ws) }
            } else if model.isBusy {
                ProgressView("Downloading from GitHub…")
            } else if !model.hasToken {
                NavigationStack { SettingsView() }
            } else if !model.isOnline {
                ContentUnavailableView("Not on this device yet", systemImage: "wifi.slash",
                                       description: Text("Connect to the internet once to download the site. After that Breezy works offline."))
            } else {
                NavigationStack { SettingsView() }
            }
        }
        .sheet(item: $sheet) { s in
            NavigationStack {
                switch s {
                case .settings: SettingsView(close: { sheet = nil })
                case .branches: BranchesView()
                case .commit: CommitView()
                case .publish: PublishView()
                }
            }
            .frame(minWidth: 460, minHeight: 480)
        }
        .sheet(isPresented: $model.showConflicts) {
            NavigationStack { ConflictsView() }.frame(minWidth: 560, minHeight: 520)
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

    @ToolbarContentBuilder
    private func toolbar(_ ws: SiteWorkspace) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            SyncStatusButton()
            Menu {
                Picker("Branch", selection: Binding(get: { ws.branch }, set: { requestSwitch(to: $0, in: ws) })) {
                    ForEach(model.branchNames, id: \.self) { name in
                        let onDevice = model.isOnDevice(name)
                        Text(name + (name == model.defaultBranch ? " (default)" : "") + (onDevice ? "" : " (not on device)"))
                            .tag(name)
                            .selectionDisabled(!onDevice && !model.isOnline)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Button("Manage Branches & Pull Requests…") { sheet = .branches }
            } label: {
                Label(ws.branch, systemImage: "arrow.triangle.branch").labelStyle(.titleAndIcon)
            }
            .help("Switch branch, or manage branches and pull requests")
            Button { sheet = .commit } label: {
                Label("Commit (\(ws.changes.count))", systemImage: "checkmark.circle")
            }
            .disabled(!ws.hasChanges)
            .help("Commit all changes to \(ws.branch)")
            if !model.isOnDefaultBranch {
                Button { sheet = .publish } label: { Label("Publish", systemImage: "paperplane") }
                    .help("Merge \(ws.branch) into \(model.defaultBranch) to update the website")
            }
            if let url = model.websiteURL {
                Button { openURL(url) } label: { Label("View Website", systemImage: "safari") }
                    .help(url.absoluteString)
            }
            Button { sheet = .settings } label: { Label("Settings", systemImage: "gearshape") }
        }
    }
}

/// Shows offline / pending / conflicts / synced; tapping syncs now, or opens the conflicts.
struct SyncStatusButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let (text, icon, color) = describe(model.syncStatus)
        Button {
            if case .conflicts = model.syncStatus { model.showConflicts = true } else { Task { await model.sync() } }
        } label: {
            if model.syncStatus == .syncing {
                ProgressView().controlSize(.small)
            } else {
                Label(text, systemImage: icon).foregroundStyle(color).labelStyle(.titleAndIcon)
            }
        }
        .disabled(model.syncStatus == .syncing)
        .help(model.lastSyncError ?? "Sync with GitHub")
    }

    private func describe(_ s: AppModel.SyncStatus) -> (String, String, Color) {
        switch s {
        case .offline: ("Offline", "wifi.slash", .secondary)
        case .syncing: ("Syncing", "arrow.triangle.2.circlepath", .secondary)
        case let .conflicts(n): ("\(n) conflict\(n == 1 ? "" : "s")", "exclamationmark.triangle.fill", .orange)
        case let .pending(n): (n == 0 ? "Not pushed" : "\(n) to push", "arrow.up.circle", .blue)
        case .failed: ("Sync failed", "exclamationmark.icloud", .red)
        case .synced: ("Synced", "checkmark.icloud", .secondary)
        }
    }
}
