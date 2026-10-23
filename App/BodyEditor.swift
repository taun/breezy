import SwiftUI

/// The node body editor. On iOS 18 / macOS 15 and later it also remembers the cursor or selection per node,
/// with the window, so a relaunch puts the cursor back exactly where it was.
struct BodyEditor: View {
    @Binding var text: String
    let slug: String
    /// "slug|start|end" in UTF-16 offsets.
    @SceneStorage("editor.bodySelection") private var stored = ""

    var body: some View {
        if #available(iOS 18, macOS 15, *) {
            SelectionRestoringEditor(text: $text, slug: slug, stored: $stored)
        } else {
            TextEditor(text: $text)
        }
    }
}

@available(iOS 18, macOS 15, *)
private struct SelectionRestoringEditor: View {
    @Binding var text: String
    let slug: String
    @Binding var stored: String
    @State private var selection: TextSelection?

    var body: some View {
        TextEditor(text: $text, selection: $selection)
            .onAppear { selection = restored() }
            .onChange(of: selection) { _, s in save(s) }
    }

    private func save(_ s: TextSelection?) {
        guard let s, case let .selection(range) = s.indices else { return }
        stored = "\(slug)|\(range.lowerBound.utf16Offset(in: text))|\(range.upperBound.utf16Offset(in: text))"
    }

    private func restored() -> TextSelection? {
        let p = stored.split(separator: "|")
        guard p.count == 3, p[0] == slug, let a = Int(p[1]), let b = Int(p[2]) else { return nil }
        let n = text.utf16.count
        let lo = String.Index(utf16Offset: min(max(a, 0), n), in: text)
        let hi = String.Index(utf16Offset: min(max(b, a, 0), n), in: text)
        return TextSelection(range: lo..<hi)
    }
}
