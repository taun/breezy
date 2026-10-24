import BreezyKit
import SwiftUI

struct CommitView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("commit.message") private var message = ""

    var body: some View {
        if let ws = model.workspace {
            Form {
                Section("Changes on \(ws.branch)") {
                    ForEach(ws.changes, id: \.path) { c in
                        Label((c.path as NSString).lastPathComponent, systemImage: c.content == nil ? "trash" : "pencil")
                            .foregroundStyle(c.content == nil ? .red : .primary)
                    }
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
            .onAppear {
                if message.isEmpty { message = ws.suggestedCommitMessage }
            }
        }
    }
}
