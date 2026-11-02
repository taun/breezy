import BreezyKit
import SwiftUI

struct CommitView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("commit.message") private var message = ""

    var body: some View {
        if let ws = model.workspace {
            Form {
                Section {
                    ForEach(ws.changedNodes) { c in
                        VStack(alignment: .leading, spacing: 2) {
                            Label("\(c.slug).md", systemImage: c.file == .deleted ? "trash" : c.file == nil ? "doc.text" : "pencil")
                                .foregroundStyle(c.file == .deleted ? .red : .primary)
                            Text(Self.caption(c)).font(.caption).foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            if c.file != nil { Button("Revert") { revert(c.slug, in: ws) }.tint(.orange) }
                            if c.draft != nil { Button("Revert Draft") { revertDraft(c.slug, in: ws) }.tint(.gray) }
                        }
                        .contextMenu {
                            if c.file != nil { Button(c.file == .deleted ? "Restore" : "Revert Changes") { revert(c.slug, in: ws) } }
                            if c.draft != nil { Button("Revert Draft") { revertDraft(c.slug, in: ws) } }
                        }
                    }
                } header: {
                    Text("Changes on \(ws.branch)")
                } footer: {
                    Text("Swipe or long-press a change to undo it, including restoring a deleted node. Drafts are committed too, so they can be continued on your other devices.")
                }
                Section("Message") {
                    TextField("Describe the change", text: $message, axis: .vertical)
                }
                Section {
                    if !model.isOnline {
                        Label("Offline: the commit is saved on this device and pushed to GitHub the next time Breezy is online.", systemImage: "wifi.slash")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if model.isOnDefaultBranch {
                        Text("You are committing to \(ws.branch), which publishes the site when pushed. Create a branch in Branches to review changes in a pull request first.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Commit")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Commit") {
                        Task {
                            await model.commit(message: message)
                            if !(model.workspace?.hasChanges ?? true) { message = ""; dismiss() }
                        }
                    }
                    .disabled(message.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onChange(of: ws.hasChanges) { _, has in if !has { message = ""; dismiss() } }
            .onAppear {
                if message.isEmpty { message = ws.suggestedCommitMessage }
            }
        }
    }

    private func revert(_ slug: String, in ws: SiteWorkspace) {
        do { try ws.revert(slug) } catch { model.errorMessage = error.localizedDescription }
        message = ws.suggestedCommitMessage
    }

    private func revertDraft(_ slug: String, in ws: SiteWorkspace) {
        do { try ws.revertDraft(slug) } catch { model.errorMessage = error.localizedDescription }
        message = ws.suggestedCommitMessage
    }

    /// "edited", "draft updated", "edited · draft used"…
    static func caption(_ c: SiteWorkspace.NodeChange) -> String {
        let file: String? = switch c.file {
        case .added: "added"
        case .edited: "edited"
        case .deleted: "deleted"
        case nil: nil
        }
        let draft: String? = switch c.draft {
        case .started: "draft started"
        case .updated: "draft updated"
        case .removed: c.file == .edited ? "draft used" : "draft discarded"
        case nil: nil
        }
        return [file, draft].compactMap { $0 }.joined(separator: " · ")
    }
}
