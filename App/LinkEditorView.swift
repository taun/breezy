import BreezyKit
import SwiftUI

/// Outgoing links with target and relation pickers, plus the incoming links for context.
struct LinkEditorView: View {
    @Environment(AppModel.self) private var model
    let workspace: SiteWorkspace
    let slug: String

    private var links: [NodeLink] { workspace.nodes[slug]?.links ?? [] }
    private var targets: [NodeFile] { workspace.nodes.values.filter { $0.slug != slug }.sorted { $0.title < $1.title } }
    private var incoming: [(NodeFile, String)] {
        workspace.nodes.values.flatMap { n in n.links.filter { $0.to == slug }.map { (n, $0.rel) } }.sorted { $0.0.title < $1.0.title }
    }

    var body: some View {
        Section {
            ForEach(Array(links.enumerated()), id: \.offset) { i, link in
                HStack {
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Picker("Target", selection: Binding(get: { link.to }, set: { slug in modify(i) { $0.to = slug } })) {
                        if workspace.nodes[link.to] == nil { Text("\(link.to) (missing)").tag(link.to) }
                        ForEach(targets, id: \.slug) { Text($0.title).tag($0.slug) }
                    }
                    .labelsHidden()
                    RelationField(rel: link.rel) { rel in modify(i) { $0.rel = rel } }
                    Button(role: .destructive) { setLinks(links.enumerated().filter { $0.offset != i }.map(\.element)) } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove link")
                }
            }
            Button {
                if let first = targets.first(where: { t in !links.contains { $0.to == t.slug } }) ?? targets.first {
                    setLinks(links + [NodeLink(to: first.slug)])
                }
            } label: {
                Label("Add link", systemImage: "plus.circle")
            }
            .disabled(targets.isEmpty)
            if !incoming.isEmpty {
                DisclosureGroup("Incoming (\(incoming.count))") {
                    ForEach(incoming, id: \.0.slug) { n, rel in
                        Label("\(n.title) — \(rel.replacingOccurrences(of: "-", with: " "))", systemImage: "arrow.left").foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Links")
        } footer: {
            Text("Links point from this node to the target. Plain links mean “led to”.")
        }
    }

    private func modify(_ index: Int, _ apply: (inout NodeLink) -> Void) {
        var new = links
        guard new.indices.contains(index) else { return }
        apply(&new[index])
        setLinks(new)
    }

    private func setLinks(_ new: [NodeLink]) {
        do { try workspace.update(slug) { try $0.setLinks(new) } } catch { model.errorMessage = error.localizedDescription }
    }
}

/// Relation with suggestions; any word is allowed and is normalized like the site does.
struct RelationField: View {
    let rel: String
    let set: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            CommitTextField("relation", value: rel) { text in
                let n = Relations.normalize(text)
                set(n.isEmpty ? Relations.defaultRel : n)
            }
            .frame(minWidth: 90)
            Menu {
                ForEach(Relations.known, id: \.rel) { k in Button("\(k.rel) — \(k.out)") { set(k.rel) } }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Known relations")
        }
    }
}
