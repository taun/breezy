import BreezyKit
import SwiftUI

/// A text field that keeps its own text while typing and hands it over on Return or when focus leaves.
/// Used where the stored value is normalized (tags, relations) so normalization does not fight the cursor.
struct CommitTextField: View {
    let title: String
    let value: String
    let commit: (String) -> Void
    /// The field's name in a rejected-character note.
    let name: String
    @State private var text = ""
    @FocusState private var focused: Bool
    /// Typed since the last hand-over; only that text is worth saving when the view goes away.
    @State private var pending = false
    @Environment(\.scenePhase) private var scenePhase

    init(_ title: String, value: String, name: String? = nil, commit: @escaping (String) -> Void) {
        self.title = title
        self.name = name ?? title
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
            // Only typed text is handed over: committing the value as it came would rewrite a file whose text the
            // setter cleans, although nothing was edited.
            .onSubmit { if pending { handOver() } }
            .onChange(of: focused) { _, now in if !now && pending { handOver() } }
            // Leaving the app mid-typing keeps what was typed (it is saved to disk like any other edit).
            .onChange(of: scenePhase) { _, phase in if phase != .active && focused && pending { handOver() } }
            // Leaving the node or switching tab tears the view down without a focus change, so hand over here too.
            .onDisappear { if pending { handOver() } }
            .onAppear { text = value }
            .onChange(of: value) { _, new in if !focused { text = new } }
            .checkingCharacters($text, .line, field: name, sources: [value]) { v in if focused && v != value { pending = true } }
    }

    private func handOver() {
        pending = false
        commit(text)
    }
}
