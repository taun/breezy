import SwiftUI

/// The node body editor. On iOS 18 / macOS 15 and later it also remembers the cursor or selection per node,
/// so a relaunch puts the cursor back exactly where it was.
struct BodyEditor: View {
    @Binding var text: String
    let slug: String
    /// "slug|start|end" in UTF-16 offsets.
    @AppStorage("editor.bodySelection") private var stored = ""
    /// The editor edits this local copy, not the model's text directly: a text view bound to a value that is
    /// re-read from the model on every keystroke resets its cursor (typing "Hello" gave "ElloH").
    @State private var local: String
    #if os(iOS)
    @State private var edits = 0
    #endif

    init(text: Binding<String>, slug: String) {
        _text = text
        self.slug = slug
        _local = State(initialValue: text.wrappedValue)
    }

    var body: some View {
        editor
            #if os(iOS)
            .background(TextKit1(edits: edits))
            #endif
            .onChange(of: local) { _, v in
                #if os(iOS)
                edits &+= 1
                #endif
                if v != text { text = v }
            }
            // Changes from elsewhere (sync, conflict resolution, another node).
            .onChange(of: text) { _, v in if v != local { local = v } }
            .onChange(of: slug) { _, _ in local = text }
    }

    @ViewBuilder private var editor: some View {
        if #available(iOS 18, macOS 15, *) {
            SelectionRestoringEditor(text: $local, slug: slug, stored: $stored)
        } else {
            TextEditor(text: $local)
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

#if os(iOS)
/// Switches the editor's text view to TextKit 1. TextKit 2 lays out a long text lazily and estimates the height of the
/// rest, and the estimate shifts while typing: in a short editor (iPhone landscape), Return at the end of a long body
/// sometimes scrolled to a stale end, past the text, leaving the editor blank or the cursor's line out of view.
/// TextKit 1 lays out the whole text, so following the cursor lands on it. SwiftUI's TextEditor does not expose its
/// text view, so this finds it: the nearest one around this background view that covers its center. If none is found
/// (a future SwiftUI that renders differently), the editor keeps working as before.
private struct TextKit1: UIViewRepresentable {
    /// Changes with every edit, so the check runs again if SwiftUI replaced the text view or it was not there yet.
    let edits: Int

    func makeUIView(context: Context) -> Finder { Finder() }
    func updateUIView(_ view: Finder, context: Context) { view.switchTextView() }

    final class Finder: UIView {
        /// How far up to look: the text view is a near relative of this background view, not elsewhere in the window.
        private static let levels = 6
        /// The text view already handled; it is not searched for again while it is still the editor's.
        private weak var handled: UITextView?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            // The text view may join the hierarchy after this view: check again once this layout pass is done.
            DispatchQueue.main.async { [weak self] in self?.switchTextView() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            switchTextView()
        }

        func switchTextView() {
            guard window != nil, !bounds.isEmpty else { return }
            let center = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: nil)
            if let h = handled, h.window != nil, Self.covers(h, center) { return }
            // Up a level at a time, searching only the branches not searched yet, so each view is visited once.
            var child: UIView = self
            for _ in 0..<Self.levels {
                guard let parent = child.superview else { return }
                for branch in parent.subviews where branch !== child {
                    if let textView = Self.textView(in: branch, covering: center) {
                        // Reading layoutManager is what switches a TextKit 2 text view to TextKit 1.
                        if textView.textLayoutManager != nil { _ = textView.layoutManager }
                        handled = textView
                        return
                    }
                }
                child = parent
            }
        }

        private static func covers(_ view: UIView, _ point: CGPoint) -> Bool {
            view.convert(view.bounds, to: nil).contains(point)
        }

        private static func textView(in view: UIView, covering point: CGPoint) -> UITextView? {
            if let t = view as? UITextView, covers(t, point) { return t }
            for sub in view.subviews { if let t = textView(in: sub, covering: point) { return t } }
            return nil
        }
    }
}
#endif
