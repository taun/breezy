import BreezyKit
import SwiftUI

struct NodeListView: View {
    @Environment(AppModel.self) private var model
    let workspace: SiteWorkspace
    @Binding var selection: String?
    @SceneStorage("list.search") private var search = ""
    /// "" means all types.
    @SceneStorage("list.type") private var typeRaw = ""
    @SceneStorage("list.showNew") private var showNew = false

    private var typeFilter: String? { typeRaw.isEmpty ? nil : typeRaw }

    private var visible: [NodeFile] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return workspace.sortedNodes.filter { n in
            (typeFilter == nil || n.type == typeFilter)
                && (q.isEmpty || n.title.lowercased().contains(q) || n.slug.contains(q) || n.tags.contains { $0.lowercased().contains(q) })
        }
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(visible, id: \.slug) { node in
                NodeRow(node: node, modified: workspace.isModified(node.slug), hasIssues: !workspace.issues(for: node.slug).isEmpty)
                    .tag(node.slug)
                    .contextMenu {
                        if workspace.isModified(node.slug) { Button("Revert Changes") { try? workspace.revert(node.slug) } }
                        Button("Delete", role: .destructive) { delete(node.slug) }
                    }
                    .swipeActions { Button("Delete", role: .destructive) { delete(node.slug) } }
            }
        }
        .searchable(text: $search, prompt: "Title, slug or tag")
        .navigationTitle("Nodes")
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Type", selection: Binding(get: { typeFilter }, set: { typeRaw = $0 ?? "" })) {
                        Text("All types").tag(String?.none)
                        ForEach(workspace.types, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                } label: {
                    Label("Filter", systemImage: typeFilter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
            }
            ToolbarItem { Button { showNew = true } label: { Label("New Node", systemImage: "plus") } }
        }
        .sheet(isPresented: $showNew) {
            NavigationStack { NewNodeView(workspace: workspace, selection: $selection) }.frame(minWidth: 420, minHeight: 320)
        }
        .refreshable { await model.sync() }
    }

    private func delete(_ slug: String) {
        if selection == slug { selection = nil }
        do { try workspace.deleteNode(slug) } catch { model.errorMessage = error.localizedDescription }
    }
}

struct NodeRow: View {
    let node: NodeFile
    let modified: Bool
    let hasIssues: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(node.title).lineLimit(1)
                if modified { Circle().fill(.orange).frame(width: 7, height: 7).accessibilityLabel("Modified") }
                if hasIssues { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).imageScale(.small).accessibilityLabel("Has issues") }
                if node.draft { Text("draft").font(.caption2).foregroundStyle(.secondary) }
            }
            HStack(spacing: 6) {
                Text(node.type).font(.caption).padding(.horizontal, 6).background(.quaternary, in: Capsule())
                Text(node.date?.label ?? "undated").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct NewNodeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let workspace: SiteWorkspace
    @Binding var selection: String?
    // Draft kept with the window, so a half-filled form survives a relaunch.
    @SceneStorage("new.slug") private var slug = ""
    @SceneStorage("new.title") private var title = ""
    @SceneStorage("new.type") private var type = "post"

    private var slugIssues: [ValidationIssue] { slug.isEmpty ? [] : Validator.validateSlug(slug, existing: workspace.slugs) }

    var body: some View {
        Form {
            TextField("Title", text: $title)
                .onChange(of: title) { old, new in
                    // Suggest a slug from the title until the user edits the slug themselves.
                    if slug.isEmpty || slug == Self.slugify(old) { slug = Self.slugify(new) }
                }
            TextField("File name (slug)", text: $slug)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            ForEach(slugIssues, id: \.message) { Text($0.message).font(.caption).foregroundStyle(.red) }
            TypeField(type: $type, known: workspace.types)
        }
        .formStyle(.grouped)
        .navigationTitle("New Node")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { slug = ""; title = ""; dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") {
                    do {
                        try workspace.createNode(slug: slug, title: title, type: type)
                        selection = slug
                        slug = ""; title = ""; type = "post"
                        dismiss()
                    } catch { model.errorMessage = error.localizedDescription }
                }
                .disabled(slug.isEmpty || title.isEmpty || type.isEmpty || !slugIssues.isEmpty)
            }
        }
    }

    static func slugify(_ s: String) -> String {
        s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

/// A type text field with a menu of the types already in use.
struct TypeField: View {
    @Binding var type: String
    let known: [String]

    var body: some View {
        HStack {
            TextField("Type", text: $type)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            Menu {
                ForEach(known, id: \.self) { t in Button(t) { type = t } }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Existing types")
        }
    }
}
