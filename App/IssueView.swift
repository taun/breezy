import BreezyKit
import SwiftUI

/// Files an issue in Breezy's repository (opened from Settings).
struct IssueView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @AppStorage("issue.title") private var title = ""
    @AppStorage("issue.body") private var details = ""
    @AppStorage("issue.kind") private var kindRaw = IssueKind.bug.rawValue
    @AppStorage("issue.execute") private var execute = false
    let close: () -> Void
    @State private var sending = false
    @State private var filed: Issue?

    private var kind: Binding<IssueKind> {
        Binding(get: { IssueKind(rawValue: kindRaw) ?? .bug }, set: { kindRaw = $0.rawValue })
    }

    var body: some View {
        Form {
            Section {
                Picker("Type", selection: kind) {
                    Text("Bug").tag(IssueKind.bug)
                    Text("Enhancement").tag(IssueKind.enhancement)
                }
                .pickerStyle(.segmented)
                TextField("Title", text: $title)
                TextField("Description", text: $details, axis: .vertical)
                    .lineLimit(5...15)
            } footer: {
                Text("Filed in \(RepoRef.breezy.description). The token needs access to that repository with **Issues** set to read and write.")
            }
            Section {
                Toggle("Execute", isOn: $execute)
            } footer: {
                Text("Adds the execute label, which has Claude implement the issue and ship a TestFlight build.")
            }
            if !model.isOnline {
                Label("Offline: connect to the network to file the issue.", systemImage: "wifi.slash")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let filed {
                Section {
                    Label("Filed #\(filed.number)", systemImage: "checkmark.circle").foregroundStyle(.green)
                    Button("View on GitHub") { openURL(filed.htmlURL) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("File an Issue")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(filed == nil ? "Cancel" : "Done") { close() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create Issue") { submit() }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending || !model.isOnline || filed != nil)
            }
        }
    }

    private func submit() {
        sending = true
        Task {
            defer { sending = false }
            guard let issue = await model.fileIssue(title: title, body: details, kind: kind.wrappedValue, execute: execute) else { return }
            filed = issue
            title = ""; details = ""; execute = false
        }
    }
}
