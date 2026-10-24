/// The order of the node list.
public enum NodeSort: String, CaseIterable, Sendable, Identifiable {
    /// Most recently changed first (on GitHub, or edited / committed on this device).
    case updated
    /// By the node's own `date`, newest first.
    case date
    /// A to Z.
    case title

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .updated: "Last Updated"
        case .date: "Date"
        case .title: "Title"
        }
    }
}
