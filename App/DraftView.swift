import BreezyKit
import SwiftUI

/// The Body tab's Draft mode: the original text, read-only, beside a rewrite. Side by side where there is room; on
/// iPhone (compact width) the two are pages to swipe between. The draft is part of the node's editor state, saved as
/// typed and synced with the node, so it survives relaunch and can be continued on another device. "Use" replaces the
/// body with the draft; "Discard" clears it.
struct DraftView: View {
    let original: String
    let compact: Bool
    /// The body changed since the draft was started (here or on another device).
    let isStale: Bool
    let setDraft: (String) -> Void
    let markSeen: () -> Void
    let use: (String) -> Void
    /// The text being edited; a local copy for the same reason as BodyEditor's (the cursor would reset while typing).
    @State private var draft: String
    @AppStorage("editor.draftPage") private var pageRaw = Page.draft.rawValue
    private let saved: String

    enum Page: String { case original, draft }

    init(draft: String, original: String, compact: Bool, isStale: Bool, setDraft: @escaping (String) -> Void,
         markSeen: @escaping () -> Void, use: @escaping (String) -> Void) {
        saved = draft
        self.original = original
        self.compact = compact
        self.isStale = isStale
        self.setDraft = setDraft
        self.markSeen = markSeen
        self.use = use
        _draft = State(initialValue: draft)
    }

    private var originalPane: some View {
        ScrollView {
            Text(original.isEmpty ? "The body is empty." : original)
                .font(.body.monospaced())
                .foregroundStyle(original.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
    }

    private var draftPane: some View {
        VStack(spacing: 0) {
            if isStale && BodyDraft.isStarted(draft) {
                HStack {
                    Label("The original changed since you started this draft.", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Mark as Seen", action: markSeen).font(.footnote)
                }
                .padding(8)
                Divider()
            }
            TextEditor(text: $draft)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(4)
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("Write your draft here, with the original beside it. Clear it and start fresh, or edit a copy (long press › Copy Original). Press and hold the draft for Use Draft, which replaces the body with it, or Discard Draft.")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }
                .contextMenu { actions }
                // Over the draft only, not the original beside it. Copy Original brings in the body as it is: like
                // the file, it is left alone.
                .checkingCharacters($draft, .text, field: "The draft", sources: [saved, original], overlay: true) { v in
                    if v != saved { setDraft(v) }
                }
            if BodyDraft.isStarted(draft) {
                Divider()
                HStack {
                    Button("Discard Draft", role: .destructive) { draft = "" }
                    Spacer()
                    Button("Use Draft") { useDraft() }.buttonStyle(.borderedProminent)
                }
                .padding(8)
            }
        }
    }

    @ViewBuilder private var actions: some View {
        if BodyDraft.isStarted(draft) {
            Button("Use Draft", systemImage: "checkmark") { useDraft() }
            Button("Discard Draft", systemImage: "trash", role: .destructive) { draft = "" }
        } else if !original.isEmpty {
            Button("Copy Original", systemImage: "doc.on.doc") { draft = original }
        }
    }

    private func useDraft() {
        use(BodyDraft.bodyWhenUsed(draft))
        draft = ""
    }

    var body: some View {
        content
            // Changes from elsewhere (a sync, Revert Draft).
            .onChange(of: saved) { _, v in if v != draft { draft = v } }
    }

    @ViewBuilder private var content: some View {
        #if os(iOS)
        if compact {
            TabView(selection: Binding(get: { Page(rawValue: pageRaw) ?? .draft }, set: { pageRaw = $0.rawValue })) {
                originalPane.tag(Page.original)
                draftPane.tag(Page.draft)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
        } else {
            sideBySide
        }
        #else
        sideBySide
        #endif
    }

    private var sideBySide: some View {
        HStack(spacing: 0) {
            originalPane
            Divider()
            draftPane
        }
    }
}
