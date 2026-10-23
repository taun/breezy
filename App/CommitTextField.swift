import SwiftUI

/// A text field that keeps its own text while typing and hands it over on Return or when focus leaves.
/// Used where the stored value is normalized (tags, relations) so normalization does not fight the cursor.
struct CommitTextField: View {
    let title: String
    let value: String
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

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
            .onAppear { text = value }
            .onChange(of: value) { _, new in if !focused { text = new } }
    }
}
