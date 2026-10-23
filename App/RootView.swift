import BreezyKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var sheet: Sheet?
    @State private var pendingSwitch: String?

    enum Sheet: String, Identifiable {
        case settings, branches, commit
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
                ProgressView("Connecting to GitHub…")
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
                }
            }
            .frame(minWidth: 460, minHeight: 480)
        }
        .confirmationDialog("Discard uncommitted changes?", isPresented: Binding(get: { pendingSwitch != nil }, set: { if !$0 { pendingSwitch = nil } })) {
            Button("Discard and Switch to \(pendingSwitch ?? "")", role: .destructive) {
                if let name = pendingSwitch { Task { await model.switchBranch(name) } }
                pendingSwitch = nil
            }
        } message: {
            Text("Switching branches reloads all nodes. Commit first, or use Manage Branches to create a new branch that keeps the edits.")
        }
        .alert("Breezy", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private func requestSwitch(to name: String, in ws: SiteWorkspace) {
        guard name != ws.branch else { return }
        if ws.hasChanges { pendingSwitch = name } else { Task { await model.switchBranch(name) } }
    }

    @ToolbarContentBuilder
    private func toolbar(_ ws: SiteWorkspace) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if model.isBusy { ProgressView().controlSize(.small) }
            Menu {
                Picker("Branch", selection: Binding(get: { ws.branch }, set: { requestSwitch(to: $0, in: ws) })) {
                    ForEach(model.branches) { b in
                        Text(b.name == model.defaultBranch ? "\(b.name) (default)" : b.name).tag(b.name)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Button("Manage Branches & Pull Requests…") { sheet = .branches }
                Button("Refresh Branch List") { Task { await model.refresh() } }
            } label: {
                Label(ws.branch, systemImage: "arrow.triangle.branch").labelStyle(.titleAndIcon)
            }
            .help("Switch branch, or manage branches and pull requests")
            Button { sheet = .commit } label: {
                Label("Commit (\(ws.changes.count))", systemImage: "checkmark.circle")
            }
            .disabled(!ws.hasChanges)
            .help("Commit all changes to \(ws.branch)")
            Button { sheet = .settings } label: { Label("Settings", systemImage: "gearshape") }
        }
    }
}
