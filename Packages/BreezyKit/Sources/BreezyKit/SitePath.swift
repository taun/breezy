import Foundation

/// The two kinds of files Breezy reads and writes in the site repo: node files `src/nodes/<slug>.md` and their
/// editor state files `.breezy/nodes/<slug>.json` (EditorState). Everything else in the repo is left alone.
public enum SitePath {
    public static let nodesDir = "src/nodes/"
    public static let statesDir = ".breezy/nodes/"

    public enum Kind: Equatable, Sendable {
        case node(String)
        case state(String)
    }

    /// What a repo path is, with its slug; nil for any other file. Both folders are flat (the site's glob is not
    /// recursive), so nested files are neither.
    public static func kind(_ path: String) -> Kind? {
        if let slug = slug(path, in: nodesDir, ext: ".md") { return .node(slug) }
        if let slug = slug(path, in: statesDir, ext: ".json") { return .state(slug) }
        return nil
    }

    public static func nodePath(_ slug: String) -> String { "\(nodesDir)\(slug).md" }
    public static func statePath(_ slug: String) -> String { "\(statesDir)\(slug).json" }

    static func isNodeEntry(_ e: TreeEntry) -> Bool { e.isBlob && kind(e.path).map { if case .node = $0 { true } else { false } } == true }
    static func isStateEntry(_ e: TreeEntry) -> Bool { e.isBlob && kind(e.path).map { if case .state = $0 { true } else { false } } == true }

    private static func slug(_ path: String, in dir: String, ext: String) -> String? {
        guard path.hasPrefix(dir), path.hasSuffix(ext) else { return nil }
        let name = path.dropFirst(dir.count).dropLast(ext.count)
        return name.isEmpty || name.contains("/") ? nil : String(name)
    }
}
