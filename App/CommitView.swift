import BreezyKit
import SwiftUI

struct CommitView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""

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
                if model.isOnDefaultBranch {
                    Section {
                        Text("You are committing directly to \(ws.branch), which publishes the site. Create a branch in Branches to review changes in a pull request first.")
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
                            if !(model.workspace?.hasChanges ?? true) { dismiss() }
                        }
                    }
                    .disabled(message.trimmingCharacters(in: .whitespaces).isEmpty || model.isBusy)
                }
            }
            .onAppear {
                if message.isEmpty {
                    let names = ws.changes.map { (($0.path as NSString).lastPathComponent as NSString).deletingPathExtension }
                    message = "Edit " + names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " and \(names.count - 3) more" : "")
                }
            }
        }
    }
}
