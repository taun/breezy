import BreezyKit
import SwiftUI

/// Switch, create and delete branches; open and merge pull requests into the default branch.
struct BranchesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var newBranch = ""
    @State private var prTitle = ""
    @State private var prBody = ""
    @State private var pendingSwitch: String?
    @State private var mergeMethod: MergeMethod = .squash
    @State private var deleteAfterMerge = true

    var body: some View {
        Form {
            if let ws = model.workspace {
                Section("Current") {
                    LabeledContent("Branch", value: ws.branch)
                    LabeledContent("Loaded commit", value: String(ws.headSHA.prefix(7)))
                    Button("Reload from GitHub") { Task { await model.reload() } }
                        .disabled(ws.hasChanges)
                }
                Section {
                    ForEach(model.branches) { b in
                        Button {
                            if ws.hasChanges { pendingSwitch = b.name } else { Task { await model.switchBranch(b.name) } }
                        } label: {
                            HStack {
                                Text(b.name)
                                if b.name == model.defaultBranch { Text("default").font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                if b.name == ws.branch { Image(systemName: "checkmark") }
                            }
                        }
                        .disabled(b.name == ws.branch)
                        .swipeActions {
                            if b.name != ws.branch && b.name != model.defaultBranch {
                                Button("Delete", role: .destructive) { Task { await model.deleteBranch(b.name) } }
                            }
                        }
                        .contextMenu {
                            if b.name != ws.branch && b.name != model.defaultBranch {
                                Button("Delete Branch", role: .destructive) { Task { await model.deleteBranch(b.name) } }
                            }
                        }
                    }
                    HStack {
                        TextField("new-branch-name", text: $newBranch)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                        Button("Create") {
                            let name = newBranch.trimmingCharacters(in: .whitespaces)
                            Task { await model.createBranch(name); newBranch = "" }
                        }
                        .disabled(!Self.isValidBranchName(newBranch) || model.branches.contains { $0.name == newBranch })
                    }
                } header: {
                    Text("Branches")
                } footer: {
                    Text("A new branch starts at the loaded commit and keeps your uncommitted edits.")
                }
                Section("Pull requests") {
                    if model.pullRequests.isEmpty { Text("No open pull requests.").foregroundStyle(.secondary) }
                    ForEach(model.pullRequests) { pr in PullRequestRow(pr: pr, method: mergeMethod, deleteBranch: deleteAfterMerge) }
                    if !model.pullRequests.isEmpty {
                        Picker("Merge method", selection: $mergeMethod) {
                            ForEach(MergeMethod.allCases) { Text($0.rawValue.capitalized).tag($0) }
                        }
                        Toggle("Delete branch after merging", isOn: $deleteAfterMerge)
                    }
                }
                if !model.isOnDefaultBranch && !model.pullRequests.contains(where: { $0.head == ws.branch }) {
                    Section("Open a pull request: \(ws.branch) → \(model.defaultBranch)") {
                        TextField("Title", text: $prTitle)
                        TextField("Description (optional)", text: $prBody, axis: .vertical)
                        Button("Open pull request") { Task { await model.openPullRequest(title: prTitle, body: prBody); prTitle = ""; prBody = "" } }
                            .disabled(prTitle.trimmingCharacters(in: .whitespaces).isEmpty || ws.hasChanges)
                        if ws.hasChanges { Text("Commit your changes first.").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Branches")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            ToolbarItem { Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") } }
        }
        .task { await model.refresh() }
        .confirmationDialog("Discard uncommitted changes?", isPresented: Binding(get: { pendingSwitch != nil }, set: { if !$0 { pendingSwitch = nil } })) {
            Button("Discard and switch", role: .destructive) {
                if let name = pendingSwitch { Task { await model.switchBranch(name) } }
                pendingSwitch = nil
            }
        } message: {
            Text("Switching branches reloads all nodes. Commit first, or create a new branch to keep the edits.")
        }
    }

    /// Conservative subset of git's rules: letters, digits, "-", "_", ".", "/" segments, no "..", no leading or trailing "/" or ".".
    static func isValidBranchName(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && t.range(of: #"^[A-Za-z0-9_-]+([./][A-Za-z0-9_-]+)*$"#, options: .regularExpression) != nil
    }
}

struct PullRequestRow: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let method: MergeMethod
    let deleteBranch: Bool
    @State private var confirmMerge = false

    private var status: (String, Color) {
        switch (pr.mergeable, pr.mergeableState) {
        case (nil, _): ("Checking mergeability…", .secondary)
        case (false?, _): ("Conflicts: resolve on GitHub", .red)
        case (true?, "clean"?): ("Ready to merge", .green)
        case (true?, let s?): ("Mergeable (\(s))", .orange)
        default: ("Mergeable", .green)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("#\(pr.number) \(pr.title)").bold()
                Spacer()
                if let url = pr.htmlURL { Link(destination: url) { Image(systemName: "arrow.up.right.square") }.accessibilityLabel("Open on GitHub") }
            }
            Text("\(pr.head) → \(pr.base)").font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(status.0).font(.caption).foregroundStyle(status.1)
                Spacer()
                Button("Check") { Task { await model.refreshPullRequest(pr.number) } }.buttonStyle(.borderless)
                Button("Merge") { confirmMerge = true }.buttonStyle(.borderless).disabled(pr.mergeable == false)
            }
        }
        .task { if pr.mergeable == nil { await model.refreshPullRequest(pr.number) } }
        .confirmationDialog("\(method.rawValue.capitalized) #\(pr.number) into \(pr.base)?", isPresented: $confirmMerge) {
            Button("Merge") { Task { await model.merge(pr, method: method, deleteBranch: deleteBranch) } }
        } message: {
            Text(pr.base == model.defaultBranch ? "Merging into \(pr.base) publishes the site." : "")
        }
    }
}
