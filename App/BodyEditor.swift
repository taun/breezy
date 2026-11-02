import SwiftUI

/// The node body editor. On iOS 18 / macOS 15 and later it also puts back the node's cursor or selection, kept in
/// its editor state (EditorState.selection): after a relaunch, and on another device once the state has synced.
struct BodyEditor: View {
    @Binding var text: String
    let slug: String
    /// UTF-16 [start, end] to put back, from the node's editor state.
    let selection: [Int]?
    /// Changes when the cursor should be put back again (a sync brought in a new version of the node or its state).
    let restoreToken: Int
    let onSelection: ([Int]) -> Void
    /// The editor edits this local copy, not the model's text directly: a text view bound to a value that is
    /// re-read from the model on every keystroke resets its cursor (typing "Hello" gave "ElloH").
    @State private var local: String
    #if os(iOS)
    @State private var edits = 0
    #endif

    init(text: Binding<String>, slug: String, selection: [Int]?, restoreToken: Int, onSelection: @escaping ([Int]) -> Void) {
        _text = text
        self.slug = slug
        self.selection = selection
        self.restoreToken = restoreToken
        self.onSelection = onSelection
        _local = State(initialValue: text.wrappedValue)
    }

    var body: some View {
        editor
            #if os(iOS)
            .background(TextKit1(edits: edits, selection: selection, restoreToken: restoreToken))
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
            SelectionRestoringEditor(text: $local, selection: selection, restoreToken: restoreToken, onSelection: onSelection)
        } else {
            TextEditor(text: $local)
        }
    }
}

@available(iOS 18, macOS 15, *)
private struct SelectionRestoringEditor: View {
    @Binding var text: String
    let selection: [Int]?
    let restoreToken: Int
    let onSelection: ([Int]) -> Void
    @State private var current: TextSelection?

    var body: some View {
        TextEditor(text: $text, selection: $current)
            .onAppear { current = restored() }
            // After the new text is in place (it arrives in the same update), so the offsets apply to it.
            .onChange(of: restoreToken) { Task { @MainActor in current = restored() } }
            .onChange(of: current) { _, s in save(s) }
    }

    private func save(_ s: TextSelection?) {
        guard let s, case let .selection(range) = s.indices else { return }
        let r = [range.lowerBound.utf16Offset(in: text), range.upperBound.utf16Offset(in: text)]
        if r != selection { onSelection(r) }
    }

    private func restored() -> TextSelection? {
        guard let selection, selection.count == 2 else { return nil }
        let n = text.utf16.count
        let lo = String.Index(utf16Offset: min(max(selection[0], 0), n), in: text)
        let hi = String.Index(utf16Offset: min(max(selection[1], selection[0], 0), n), in: text)
        return TextSelection(range: lo..<hi)
    }
}

#if os(iOS)
/// Switches the editor's text view to TextKit 1. TextKit 2 lays out a long text lazily and estimates the height of the
/// rest, and the estimate shifts while typing: in a short editor (iPhone landscape), Return at the end of a long body
/// sometimes scrolled to a stale end, past the text, leaving the editor blank or the cursor's line out of view.
/// Laid out in full by TextKit 1, the text has its real height, so following the cursor lands on it. SwiftUI's
/// TextEditor does not expose its text view, so this finds it: the nearest one around this background view that covers
/// its center. If none is found (a future SwiftUI that renders differently), the editor keeps working as before.
/// It also brings the cursor put back from the editor state into view: a text view without keyboard focus does not
/// follow its cursor, so the end of a body that changed on GitHub (issue #15) stayed out of sight below the top.
private struct TextKit1: UIViewRepresentable {
    /// Changes with every edit, so the check runs again if SwiftUI replaced the text view or it was not there yet.
    let edits: Int
    /// UTF-16 [start, end] of the cursor put back, and the token that changes when it is put back again.
    let selection: [Int]?
    let restoreToken: Int

    func makeUIView(context: Context) -> Finder { Finder() }

    func updateUIView(_ view: Finder, context: Context) {
        view.selection = selection
        view.switchTextView()
        if view.restoreToken != restoreToken {
            view.restoreToken = restoreToken
            // A run loop later: the text that came with the new state replaces the old one in a following update.
            DispatchQueue.main.async { [weak view] in view?.scrollToSelection() }
        }
    }

    final class Finder: UIView {
        /// How far up to look: the text view is a near relative of this background view, not elsewhere in the window.
        private static let levels = 6
        /// The text view already handled; it is not searched for again while it is still the editor's.
        private weak var handled: UITextView?
        var selection: [Int]?
        var restoreToken: Int?

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
                        Self.layOutWholeText(textView)
                        handled = textView
                        scrollToSelection() // the node just opened: show where its cursor was left
                        return
                    }
                }
                child = parent
            }
        }

        /// TextKit 1 in a text view also lays out only what has been shown (non-contiguous layout), so its scrollable
        /// height would grow as one scrolls; all of it is laid out instead. The switch itself also leaves the scrollable
        /// height at about the editor's own, and the text view recomputes it only on a text change or a resize (the
        /// keyboard), so a body would not scroll until the cursor was placed: it is set here.
        private static func layOutWholeText(_ textView: UITextView) {
            let layout = textView.layoutManager // reading it is what switches a TextKit 2 text view to TextKit 1
            layout.allowsNonContiguousLayout = false
            layout.ensureLayout(for: textView.textContainer)
            let inset = textView.textContainerInset
            let height = layout.usedRect(for: textView.textContainer).maxY + inset.top + inset.bottom
            textView.contentSize = CGSize(width: textView.bounds.width, height: ceil(height))
        }

        /// Scrolls the text view to the saved cursor, clamped to the text. Without a saved cursor it stays as it is.
        func scrollToSelection() {
            guard let textView = handled, let selection, selection.count == 2 else { return }
            let n = (textView.text as NSString).length
            let lo = min(max(selection[0], 0), n), hi = min(max(selection[1], lo), n)
            textView.layoutManager.ensureLayout(for: textView.textContainer)
            textView.scrollRangeToVisible(NSRange(location: lo, length: hi - lo))
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
