import SwiftUI

/// Which column a collapsed split view (iPhone) shows: the node list or the editor. Kept as a pure policy so it can
/// be unit tested; RootView stores the result in @AppStorage so a relaunch reopens the same screen.
///
/// The stored value is never second-guessed by reading the selection in the getter: when a row is tapped, iOS sets
/// the column and the selection in an unspecified order, and gating one on the other made taps do nothing on iOS 27.
enum CompactNavigation {
    /// Stored form of a column.
    static func raw(_ column: NavigationSplitViewColumn) -> String { column == .detail ? "detail" : "sidebar" }

    static func column(_ raw: String) -> NavigationSplitViewColumn { raw == "detail" ? .detail : .sidebar }

    /// After the selection changes: choosing a node opens it; clearing it goes back to the list.
    static func afterSelectionChange(to slug: String?) -> String { slug == nil ? "sidebar" : "detail" }

    /// At launch: the editor can only be restored if there is a node to show in it.
    static func restored(_ raw: String, hasSelection: Bool) -> String { raw == "detail" && !hasSelection ? "sidebar" : raw }
}
