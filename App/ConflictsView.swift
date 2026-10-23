import BreezyKit
import SwiftUI

/// Files changed both here and on GitHub since the last sync, settled one at a time.
struct ConflictsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @SceneStorage("conflicts.editing") private var editingPath = ""

    private var editing: Binding<Conflict?> {
        Binding(get: { model.workspace?.conflicts.first { $0.path == editingPath } }, set: { editingPath = $0?.path ?? "" })
    }

    var body: some View {
        if let ws = model.workspace {
            List {
                Section {
                    Text("These files changed on GitHub and on this device since the last sync. Choose a version for each. Nothing is pushed until all are settled.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(ws.conflicts) { c in
                    VStack(alignment: .leading, spacing: 8) {
                        Text((c.path as NSString).lastPathComponent).bold()
                        Text(summary(c, ws)).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Keep Mine") { Task { await model.resolve(c.path, with: .mine) } }
                            Button("Use GitHub’s") { Task { await model.resolve(c.path, with: .theirs) } }
                            Button("Edit…") { editingPath = c.path }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Conflicts")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Later") { dismiss() } } }
            .sheet(item: editing) { c in
                NavigationStack { MergeEditor(conflict: c, mine: ws.localText(path: c.path) ?? "", theirs: ws.text(sha: c.remoteSHA) ?? "") }
                    .frame(minWidth: 640, minHeight: 560)
            }
        }
    }

    private func summary(_ c: Conflict, _ ws: SiteWorkspace) -> String {
        let mine = ws.localText(path: c.path) == nil ? "deleted here" : "edited here"
        let theirs = c.remoteSHA == nil ? "deleted on GitHub" : c.baseSHA == nil ? "added on GitHub" : "edited on GitHub"
        return "\(mine), \(theirs)"
    }
}

/// Shows GitHub's version beside an editable copy of the local one; the result becomes an uncommitted edit.
struct MergeEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let conflict: Conflict
    let mine: String
    let theirs: String
    // The draft and the file it belongs to, kept with the window.
    @SceneStorage("merge.text") private var text = ""
    @SceneStorage("merge.path") private var draftPath = ""

    var body: some View {
        Form {
            Section("GitHub’s version") {
                ScrollView { Text(theirs.isEmpty ? "(deleted)" : theirs).font(.callout.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(minHeight: 160)
                Button("Copy GitHub’s Version into the Editor") { text = theirs }
            }
            Section("Merged result (starts as yours)") {
                TextEditor(text: $text).font(.callout.monospaced()).frame(minHeight: 220)
            }
        }
        .formStyle(.grouped)
        .navigationTitle((conflict.path as NSString).lastPathComponent)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Use This") {
                    Task {
                        await model.resolve(conflict.path, with: .edited(text))
                        draftPath = ""
                        dismiss()
                    }
                }
                .disabled(!text.hasPrefix("---\n"))
            }
        }
        .onAppear {
            if draftPath != conflict.path {
                draftPath = conflict.path
                text = mine.isEmpty ? theirs : mine
            }
        }
    }
}
