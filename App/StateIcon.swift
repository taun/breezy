import BreezyKit
import SwiftUI

/// A node's state as an icon (issue #3): gold hammer = draft (will not be published), green check = will be
/// published (new or changed), link-blue globe = published and unchanged. VoiceOver reads the state.
struct StateIcon: View {
    let state: NodeState

    static func symbol(_ state: NodeState) -> String {
        switch state {
        case .draft: "hammer.fill"
        case .publish: "checkmark.circle.fill"
        case .published: "globe"
        case .deleted: "trash.fill"
        }
    }

    static func color(_ state: NodeState) -> Color {
        switch state {
        case .draft: Color(red: 0.83, green: 0.63, blue: 0.09) // gold
        case .publish: .green
        case .published: .blue // link blue
        case .deleted: .red
        }
    }

    static func meaning(_ state: NodeState) -> String {
        switch state {
        case .draft: "Draft, will not be published"
        case .publish: "Will be published"
        case .published: "Published"
        case .deleted: "Deleted, will be removed from the site when published"
        }
    }

    var body: some View {
        Image(systemName: Self.symbol(state))
            .foregroundStyle(Self.color(state))
            .imageScale(.small)
            .accessibilityLabel(Self.meaning(state))
    }
}

extension NodeShowFilter {
    /// The state this filter shows, if it is a single state.
    var state: NodeState? {
        switch self {
        case .all: nil
        case .draft: .draft
        case .publish: .publish
        case .published: .published
        case .brokenLinks: nil
        }
    }
}
