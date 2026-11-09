import BreezyKit
import SwiftUI

extension View {
    /// Turns away what `kind` cannot hold (TextRules) as it is typed or pasted into `text`, a view's own copy of the
    /// content, and shows a note saying what changed: under the view, or over its top (`overlay`, for a full-size
    /// editor that must stay the view focus and fonts apply to). `forward` gets every value that may be handed on,
    /// including one equal to a source (the file's own text, which is never cleaned: opening or syncing a node must not
    /// edit it), so it should skip values its target already holds. A change of `scope` (another node) starts afresh.
    func checkingCharacters(_ text: Binding<String>, _ kind: TextRules.Kind, field: String, sources: [String],
                            scope: String = "", overlay: Bool = false, forward: @escaping (String) -> Void) -> some View {
        modifier(CharacterGuard(text: text, kind: kind, field: field, sources: sources, scope: scope, overlay: overlay, forward: forward))
    }
}

private struct CharacterGuard: ViewModifier {
    @Binding var text: String
    let kind: TextRules.Kind
    let field: String
    let sources: [String]
    let scope: String
    let overlay: Bool
    let forward: (String) -> Void
    @State private var check = CharacterCheck()
    /// The rejection count last shown; nil until the view first appears, so an old note is not shown again.
    @State private var announced: Int?
    @State private var shown: String?

    func body(content: Content) -> some View {
        Group {
            if overlay {
                content.overlay(alignment: .top) {
                    if shown != nil {
                        note.padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(8)
                            .allowsHitTesting(false) // taps reach the text underneath
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    content
                    note
                }
            }
        }
        .onChange(of: text) { _, v in
            switch check.review(v, kind, field: field, sources: sources) {
            case let .replace(clean): text = clean // handed on at the next change
            case .forward: forward(v)
            }
        }
        .onChange(of: scope) { check = CharacterCheck() }
        .task(id: check.count) {
            guard let last = announced else { announced = check.count; return }
            guard last != check.count else { return } // the view reappeared: nothing new
            announced = check.count
            guard let message = check.message else { shown = nil; return }
            shown = message
            AccessibilityNotification.Announcement(message).post()
            do { try await Task.sleep(for: .seconds(6)) } catch { return } // a newer rejection replaced this one
            shown = nil
        }
        .onDisappear { shown = nil }
    }

    @ViewBuilder private var note: some View {
        if let shown {
            Label(shown, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true) // announced when it appears
        }
    }
}

/// A text field for node content that turns away characters the site cannot publish, with a note saying why.
/// It edits its own copy of the text: a field bound straight to the file would keep showing a character the file
/// refused, since the stored value would not change.
struct CheckedTextField<Focus: Hashable>: View {
    let title: String
    @Binding var text: String
    var kind: TextRules.Kind = .line
    var axis: Axis = .horizontal
    var focus: FocusState<Focus?>.Binding?
    var focusValue: Focus?
    @State private var local = ""

    var body: some View {
        field
            .onAppear { local = text }
            .onChange(of: text) { _, v in if v != local { local = v } }
            .checkingCharacters($local, kind, field: title, sources: [text]) { v in if v != text { text = v } }
    }

    @ViewBuilder private var field: some View {
        let f = TextField(title, text: $local, axis: axis)
        if let focus, let focusValue { f.focused(focus, equals: focusValue) } else { f }
    }
}

extension CheckedTextField where Focus == Never {
    init(_ title: String, text: Binding<String>, kind: TextRules.Kind = .line, axis: Axis = .horizontal) {
        self.init(title: title, text: text, kind: kind, axis: axis)
    }
}

extension CheckedTextField {
    init(_ title: String, text: Binding<String>, kind: TextRules.Kind = .line, axis: Axis = .horizontal,
         focus: FocusState<Focus?>.Binding, equals value: Focus) {
        self.init(title: title, text: text, kind: kind, axis: axis, focus: focus, focusValue: value)
    }
}
