import BreezyKit
import SwiftUI

/// The current branch is gone from GitHub (usually published and deleted on another device), but this device still
/// has edits or commits on it. Nothing is lost; this asks where they should go.
struct BranchDeletedView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("branchDeleted.newName") private var newName = ""

    private var branch: String { model.currentBranch }
    private var nameTaken: Bool { model.branchNames.contains(newName) }

    var body: some View {
        Form {
            Section {
                Text("“\(branch)” no longer exists on GitHub. It was probably published and deleted on another device. This device still has changes on it that are not on GitHub, and they are safe.")
                if let ws = model.workspace {
                    if !ws.queue.isEmpty { LabeledContent("Commits not pushed", value: "\(ws.queue.count)") }
                    if ws.hasChanges { LabeledContent("Uncommitted changes", value: "\(ws.changes.count)") }
                }
            }
            Section {
                Button {
                    Task { await model.recreateBranchOnGitHub() }
                } label: {
                    Label("Recreate “\(branch)” on GitHub", systemImage: "arrow.uturn.backward.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.isOnline || model.isBusy)
            } footer: {
                Text("Puts the branch back as it was before it was deleted, then pushes your commits. Publish it again when ready. Recommended: your work stays exactly as it is.")
            }
            Section {
                TextField("new-branch-name", text: $newName)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                Button {
                    let name = newName
                    Task { await model.moveEditsToNewBranch(name); newName = "" }
                } label: {
                    Label("Move Changes to a New Branch from \(model.defaultBranch)", systemImage: "arrow.triangle.branch")
                }
                .disabled(!model.isOnline || model.isBusy || !BranchesView.isValidBranchName(newName) || nameTaken)
                if nameTaken { Text("A branch with that name already exists.").font(.caption).foregroundStyle(.red) }
            } footer: {
                Text("Starts a new branch from the published \(model.defaultBranch) and brings your changes along as uncommitted edits. Any file \(model.defaultBranch) also changed is shown as a conflict to settle file by file.")
            }
            if !model.isOnline {
                Section { Label("Both options need a connection.", systemImage: "wifi.slash").foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Branch Deleted on GitHub")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Later") { dismiss() } } }
        .onAppear { if newName.isEmpty { newName = Self.suggestion(for: branch, taken: Set(model.branchNames)) } }
    }

    static func suggestion(for branch: String, taken: Set<String>) -> String {
        var n = 2
        while taken.contains("\(branch)-\(n)") { n += 1 }
        return "\(branch)-\(n)"
    }
}
