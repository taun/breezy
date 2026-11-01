import BreezyKit
import SwiftUI

/// The Body tab's Draft mode: the original text, read-only, beside a rewrite. Side by side where there is room; on
/// iPhone (compact width) the two are pages to swipe between. The draft is kept per branch and node in `@AppStorage`,
/// so it survives relaunch. "Use" replaces the body with the draft; "Discard" clears it.
struct DraftView: View {
    let original: String
    let compact: Bool
    let use: (String) -> Void
    @AppStorage private var draft: String
    @AppStorage("editor.draftPage") private var pageRaw = Page.draft.rawValue

    enum Page: String { case original, draft }

    init(branch: String, slug: String, original: String, compact: Bool, use: @escaping (String) -> Void) {
        self.original = original
        self.compact = compact
        self.use = use
        _draft = AppStorage(wrappedValue: "", BodyDraft.key(branch: branch, slug: slug))
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
