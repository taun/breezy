import BreezyKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var sheet: Sheet?

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
        .alert("Breezy", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ ws: SiteWorkspace) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if model.isBusy { ProgressView().controlSize(.small) }
            Button { sheet = .branches } label: {
                Label(ws.branch, systemImage: "arrow.triangle.branch").labelStyle(.titleAndIcon)
            }
            .help("Branches and pull requests")
            Button { sheet = .commit } label: {
                Label("Commit (\(ws.changes.count))", systemImage: "checkmark.circle")
            }
            .disabled(!ws.hasChanges)
            .help("Commit all changes to \(ws.branch)")
            Button { sheet = .settings } label: { Label("Settings", systemImage: "gearshape") }
        }
    }
}
