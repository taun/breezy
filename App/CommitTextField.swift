import SwiftUI

/// A text field that keeps its own text while typing and hands it over on Return or when focus leaves.
/// Used where the stored value is normalized (tags, relations) so normalization does not fight the cursor.
struct CommitTextField: View {
    let title: String
    let value: String
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    @Environment(\.scenePhase) private var scenePhase

    init(_ title: String, value: String, commit: @escaping (String) -> Void) {
        self.title = title
        self.value = value
        self.commit = commit
    }

    var body: some View {
        TextField(title, text: $text)
            .focused($focused)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .onSubmit { commit(text) }
            .onChange(of: focused) { _, now in if !now { commit(text) } }
            // Leaving the app mid-typing keeps what was typed (it is saved to disk like any other edit).
            .onChange(of: scenePhase) { _, phase in if phase != .active && focused && text != value { commit(text) } }
            .onAppear { text = value }
            .onChange(of: value) { _, new in if !focused { text = new } }
    }
}
