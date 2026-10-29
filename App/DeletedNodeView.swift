import BreezyKit
import SwiftUI

/// A deleted node (issue #3): its last content, read-only, with Undelete. Shown until the deletion is published.
struct DeletedNodeView: View {
    @Environment(AppModel.self) private var model
    let workspace: SiteWorkspace
    let slug: String

    var body: some View {
        if let node = workspace.deletedNodes[slug] {
            Form {
                Section {
                    Label("Deleted. It will be removed from the site when \(workspace.branch) is published.", systemImage: "trash.fill")
                        .foregroundStyle(.red)
                    let linkers = workspace.incomingLinks(to: slug)
                    if !linkers.isEmpty {
                        Label("Linked from \(linkers.map(\.title).joined(separator: ", ")).", systemImage: "link")
                            .foregroundStyle(.orange)
                    }
                    Button {
                        do { try workspace.undelete(slug) } catch { model.errorMessage = error.localizedDescription }
                    } label: {
                        Label("Undelete", systemImage: "arrow.uturn.backward")
                    }
                }
                Section("Last content") { MarkdownPreview(node: node, workspace: workspace) }
            }
            .formStyle(.grouped)
            .navigationTitle(node.title)
        }
    }
}
