import BreezyKit
import SwiftUI

/// Publishing merges the current branch into the default branch, which deploys the site.
struct PublishView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var comparison: Comparison?
    @State private var method: MergeMethod = .squash
    @State private var deleteBranch = true
    @State private var confirming = false
    @State private var published = false

    var body: some View {
        Form {
            if published || model.deployStatus != .none && model.isOnDefaultBranch {
                Section("Published") {
                    DeployStatusRow()
                    if let url = model.websiteURL {
                        Button { openURL(url) } label: { Label("View Website", systemImage: "safari") }
                    }
                }
            } else if let ws = model.workspace {
                Section("\(ws.branch) → \(model.defaultBranch)") {
                    if let c = comparison {
                        LabeledContent("Commits", value: "\(c.aheadBy)")
                        ForEach(c.files, id: \.self) { Text(($0 as NSString).lastPathComponent).font(.callout) }
                        if c.aheadBy == 0 { Text("Nothing to publish: \(model.defaultBranch) already has everything on this branch.").foregroundStyle(.secondary) }
                    } else if ws.queue.isEmpty && ws.state.existsOnRemote {
                        ProgressView()
                    } else {
                        Text("\(ws.queue.count) commit(s) will be pushed first.").foregroundStyle(.secondary)
                    }
                }
                Section {
                    if !model.isOnline { Label("Publishing needs a connection.", systemImage: "wifi.slash").foregroundStyle(.secondary) }
                    if ws.hasChanges { Label("Commit your changes first.", systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
                    if !ws.conflicts.isEmpty { Label("Resolve the conflicts first.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    Picker("Merge as", selection: $method) {
                        Text("One commit (squash)").tag(MergeMethod.squash)
                        Text("Merge commit").tag(MergeMethod.merge)
                        Text("Rebase").tag(MergeMethod.rebase)
                    }
                    Toggle("Delete \(ws.branch) after publishing", isOn: $deleteBranch)
                } footer: {
                    Text("Publishing merges this branch into \(model.defaultBranch) through a pull request. GitHub then rebuilds the website, which takes a minute or two.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Publish")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(published ? "Done" : "Cancel") { dismiss() } }
            if !published, let ws = model.workspace {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Publish…") { confirming = true }
                        .disabled(!model.isOnline || ws.hasChanges || !ws.conflicts.isEmpty || model.isBusy || comparison?.aheadBy == 0)
                }
            }
        }
        .confirmationDialog("Publish \(model.currentBranch) to the website?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Publish") {
                Task { published = await model.publish(method: method, deleteBranch: deleteBranch) }
            }
        } message: {
            Text("This merges it into \(model.defaultBranch). Everyone sees the changes once the site rebuilds.")
        }
        .overlay { if model.isBusy { ProgressView("Publishing…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)) } }
        .task { comparison = await model.comparison() }
    }
}

struct DeployStatusRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        switch model.deployStatus {
        case .none, .waiting: Label("Waiting for the site build to start…", systemImage: "clock")
        case .running: HStack { ProgressView().controlSize(.small); Text("Building the website…") }
        case .live: Label("Live on the website.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case let .failed(url):
            HStack {
                Label("The site build failed.", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                if let url { Button("Details") { openURL(url) } }
            }
        case .unknown: Label("Merged. The website updates in a minute or two.", systemImage: "checkmark.circle")
        }
    }
}
