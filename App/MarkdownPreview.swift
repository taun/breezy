import BreezyKit
import SwiftUI

/// A native approximation of the node page: chips and dates from front matter, then the Markdown body rendered
/// block by block (headings, lists, quotes, code, paragraphs) with inline Markdown. Not pixel-exact with the site.
struct MarkdownPreview: View {
    let node: NodeFile

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(node.type).font(.caption).padding(.horizontal, 6).background(.quaternary, in: Capsule())
                Text(node.date?.label ?? "undated").font(.caption).foregroundStyle(.secondary)
                ForEach(node.tags, id: \.self) { Text("#\($0)").font(.caption).foregroundStyle(.secondary) }
            }
            Text(node.title).font(.title.bold())
            if !node.summary.isEmpty { Text(node.summary).foregroundStyle(.secondary) }
            ForEach(Array(Self.blocks(node.body).enumerated()), id: \.offset) { _, block in view(for: block) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    enum Block: Equatable {
        case heading(Int, String), paragraph(String), bullet(String), quote(String), code(String), rule
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case let .heading(level, text):
            inline(text).font(level <= 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
        case let .paragraph(text): inline(text)
        case let .bullet(text): HStack(alignment: .firstTextBaseline, spacing: 6) { Text("•"); inline(text) }
        case let .quote(text): inline(text).foregroundStyle(.secondary).padding(.leading, 10)
            .overlay(alignment: .leading) { Rectangle().fill(.tertiary).frame(width: 3) }
        case let .code(text): Text(text).font(.callout.monospaced()).padding(8)
            .frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        case .rule: Divider()
        }
    }

    private func inline(_ text: String) -> Text {
        // Images become a visible placeholder; the site serves them, the app does not fetch them.
        let shown = text.replacingOccurrences(of: #"!\[([^\]]*)\]\(([^)\s]+)[^)]*\)(\{[^}]*\})?"#, with: "🖼 $1 ($2)", options: .regularExpression)
        let attributed = (try? AttributedString(markdown: shown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(shown)
        return Text(attributed)
    }

    static func blocks(_ body: String) -> [Block] {
        var out: [Block] = []
        var para: [String] = []
        var code: [String]?
        func flush() {
            if !para.isEmpty { out.append(.paragraph(para.joined(separator: " "))); para = [] }
        }
        for raw in body.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let c = code { out.append(.code(c.joined(separator: "\n"))); code = nil } else { flush(); code = [] }
                continue
            }
            if code != nil { code!.append(raw); continue }
            if line.isEmpty || line.hasPrefix("<!--") { flush(); continue }
            if let m = line.firstMatch(of: /^(#{1,6})\s+(.*)$/) { flush(); out.append(.heading(m.1.count, String(m.2))); continue }
            if let m = line.firstMatch(of: /^(?:[-*+]|\d+\.)\s+(.*)$/) { flush(); out.append(.bullet(String(m.1))); continue }
            if line.hasPrefix(">") { flush(); out.append(.quote(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))); continue }
            if line == "---" || line == "***" { flush(); out.append(.rule); continue }
            para.append(line)
        }
        if let c = code { out.append(.code(c.joined(separator: "\n"))) }
        flush()
        return out
    }
}
