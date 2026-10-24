import Foundation

/// Where a node stands relative to the published site (issue #3).
public enum NodeState: String, CaseIterable, Sendable {
    /// `draft: true`: will not be published.
    case draft
    /// Will be published but is not yet: new, changed, or edited on this device.
    case publish
    /// Published and unchanged.
    case published
    /// Deleted here; the deletion is not published yet (it will be). Undelete is possible.
    case deleted
}

/// Which nodes the list shows.
public enum NodeShowFilter: String, CaseIterable, Sendable, Identifiable {
    case all, draft, publish, published, brokenLinks
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .all: "All"
        case .draft: "Draft"
        case .publish: "Publish"
        case .published: "Published"
        case .brokenLinks: "Broken Links"
        }
    }

    public func includes(_ state: NodeState) -> Bool {
        switch self {
        case .all: true
        case .draft: state == .draft
        case .publish: state == .publish || state == .deleted // a deletion is published too
        case .published: state == .published
        case .brokenLinks: false // decided per node, see visibleNodes
        }
    }
}

@MainActor
extension SiteWorkspace {
    /// Draft wins; otherwise Published only if the node is exactly what the published branch has. Without a record of
    /// the published branch yet, only the published branch itself can tell, from its own synced files.
    public func state(of slug: String) -> NodeState? {
        guard let node = nodes[slug] else { return deletedNodes[slug] == nil ? nil : .deleted }
        if node.draft { return .draft }
        let path = Self.path(slug)
        guard let live = state.publishedFiles?[path] else { return .publish }
        let text = node.rendered()
        if live == GitBlob.sha(of: text) { return .published }
        // The same file the published branch has, unedited (compared by GitHub's id, then by content).
        if live == state.base.files[path], store.object(live) == text { return .published }
        return .publish
    }

    /// The list: matching `search` (title, slug or tag), `type` and `show`, in `sort` order.
    public func visibleNodes(search: String = "", type: String? = nil, show: NodeShowFilter = .all,
                             sort: NodeSort, draftsFirst: Bool) -> [NodeFile] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let all = Array(nodes.values) + Array(deletedNodes.values)
        return ordered(all, by: sort, draftsFirst: draftsFirst).filter { n in
            (type == nil || n.type == type)
                && (show == .all
                    || (show == .brokenLinks ? !brokenLinks(of: n.slug).isEmpty : state(of: n.slug).map(show.includes) == true))
                && (q.isEmpty || n.title.lowercased().contains(q) || n.slug.contains(q) || n.tags.contains { $0.lowercased().contains(q) })
        }
    }
}
