import BreezyKit
import SwiftUI

struct NodeListView: View {
    @Environment(AppModel.self) private var model
    let workspace: SiteWorkspace
    @Binding var selection: String?
    @AppStorage("list.search") private var search = ""
    /// "" means all types.
    @AppStorage("list.type") private var typeRaw = ""
    @AppStorage("list.showNew") private var showNew = false
    /// Slug awaiting delete confirmation ("" = none); kept across relaunches like the rest of the UI state.
    @AppStorage("list.pendingDelete") private var pendingDelete = ""
    /// List order (issue #1): most recently updated first, drafts on top, unless changed in the filter menu.
    @AppStorage("list.sort") private var sortRaw = NodeSort.updated.rawValue
    @AppStorage("list.draftsFirst") private var draftsFirst = true

    private var sort: NodeSort { NodeSort(rawValue: sortRaw) ?? .updated }

    private var typeFilter: String? { typeRaw.isEmpty ? nil : typeRaw }

    private var visible: [NodeFile] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return workspace.sortedNodes(by: sort, draftsFirst: draftsFirst).filter { n in
            (typeFilter == nil || n.type == typeFilter)
                && (q.isEmpty || n.title.lowercased().contains(q) || n.slug.contains(q) || n.tags.contains { $0.lowercased().contains(q) })
        }
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(visible, id: \.slug) { node in
                NodeRow(node: node, modified: workspace.isModified(node.slug), hasIssues: !workspace.issues(for: node.slug).isEmpty,
                        updated: sort == .updated ? workspace.lastUpdated(node.slug) : nil)
                    .tag(node.slug)
                    .contextMenu {
                        if workspace.isModified(node.slug) { Button("Revert Changes") { try? workspace.revert(node.slug) } }
                        Button("Delete", role: .destructive) { pendingDelete = node.slug }
                    }
                    .swipeActions { Button("Delete", role: .destructive) { pendingDelete = node.slug } }
            }
        }
        .searchable(text: $search, prompt: "Title, slug or tag")
        #if os(macOS)
        .navigationTitle("Nodes") // on iPhone/iPad the title is the branch menu (RootView)
        #endif
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Sort by", selection: Binding(get: { sort }, set: { sortRaw = $0.rawValue })) {
                        ForEach(NodeSort.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Toggle("Drafts First", isOn: $draftsFirst)
                    Divider()
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
            NavigationStack { NewNodeView(workspace: workspace, selection: $selection) }.macSheetFrame(minWidth: 420, minHeight: 320)
        }
        .refreshable { await model.sync() }
        .confirmationDialog(
            "Delete “\(workspace.nodes[pendingDelete]?.title ?? pendingDelete)”?",
            isPresented: Binding(get: { workspace.nodes[pendingDelete] != nil }, set: { if !$0 { pendingDelete = "" } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                delete(pendingDelete)
                pendingDelete = ""
            }
        } message: {
            Text("It is removed from \(workspace.branch) when you commit. Until then you can restore it from the Commit screen.")
        }
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
    /// Shown when the list is sorted by last update.
    var updated: Date? = nil

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
                if let updated {
                    Text("· updated \(updated, format: .relative(presentation: .named))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
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
    // Draft kept across relaunches, so a half-filled form survives.
    @AppStorage("new.slug") private var slug = ""
    @AppStorage("new.title") private var title = ""
    @AppStorage("new.type") private var type = "post"

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
