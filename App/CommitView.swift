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
                    ForEach(ws.changes, id: \.path) { c in
                        let slug = ((c.path as NSString).lastPathComponent as NSString).deletingPathExtension
                        Label((c.path as NSString).lastPathComponent, systemImage: c.content == nil ? "trash" : "pencil")
                            .foregroundStyle(c.content == nil ? .red : .primary)
                            .swipeActions { Button("Revert") { revert(slug, in: ws) }.tint(.orange) }
                            .contextMenu { Button(c.content == nil ? "Restore" : "Revert Changes") { revert(slug, in: ws) } }
                    }
                } header: {
                    Text("Changes on \(ws.branch)")
                } footer: {
                    Text("Swipe or long-press a change to undo it, including restoring a deleted node.")
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
            .onChange(of: ws.changes.isEmpty) { _, empty in if empty { message = ""; dismiss() } }
            .onAppear {
                if message.isEmpty { message = ws.suggestedCommitMessage }
            }
        }
    }

    private func revert(_ slug: String, in ws: SiteWorkspace) {
        do { try ws.revert(slug) } catch { model.errorMessage = error.localizedDescription }
        message = ws.suggestedCommitMessage
    }
}
