import BreezyKit
import SwiftUI

/// A native approximation of the node page: chips and dates from front matter, then the Markdown body rendered
/// block by block (headings, lists, quotes, code, images, paragraphs) with inline Markdown. Not pixel-exact with the
/// site. Images come from the branch's assets (via `workspace`), kept on the device once fetched.
struct MarkdownPreview: View {
    let node: NodeFile
    var workspace: SiteWorkspace?

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
        case heading(Int, String), paragraph(String), bullet(String), quote(String), code(String), image(MarkdownImage), rule
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
        case let .image(image): PreviewImage(image: image, workspace: workspace)
        case .rule: Divider()
        }
    }

    private func inline(_ text: String) -> Text {
        // An image inside a line of text stays a placeholder; one on a line of its own is an .image block.
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
            if let image = MarkdownImage.standalone(line) { flush(); out.append(.image(image)); continue }
            para.append(line)
        }
        if let c = code { out.append(.code(c.joined(separator: "\n"))) }
        flush()
        return out
    }
}

/// One image of the preview: from the device if it is there, otherwise fetched once from GitHub and kept. Offline
/// and not yet fetched, or not an asset of this branch, it shows a labeled placeholder instead.
private struct PreviewImage: View {
    @Environment(AppModel.self) private var model
    let image: MarkdownImage
    let workspace: SiteWorkspace?
    /// Decoded once per image, not on every render, with its size so small images are not stretched.
    @State private var picture: (image: Image, size: CGSize)?

    private var webURL: URL? {
        let src = image.src.hasPrefix("//") ? "https:" + image.src : image.src // protocol-relative
        return src.hasPrefix("http://") || src.hasPrefix("https://") ? URL(string: src) : nil
    }

    /// Changes when the image this src names changes (another branch, or its sha becoming known after a sync), and
    /// when the network comes back, so an image that could not be fetched offline is tried again.
    private var key: String {
        "\(workspace?.branch ?? "")|\(image.src)|\(workspace?.assetSHA(image.src) ?? "")|\(model.isOnline)"
    }

    var body: some View {
        Group {
            if let picture {
                picture.image.resizable().scaledToFit().frame(maxWidth: picture.size.width)
            } else if let url = webURL {
                AsyncImage(url: url) { $0.resizable().scaledToFit() } placeholder: { placeholder(missing: false) }
            } else {
                placeholder(missing: workspace.map { !$0.hasAsset(image.src) } ?? false)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel(image.alt.isEmpty ? "Image" : image.alt)
        .task(id: key) {
            picture = nil // this view can be reused for another image (blocks are identified by position)
            guard webURL == nil, let workspace else { return }
            let data = if let client = model.client { try? await workspace.loadImage(image.src, client: client) } else { workspace.imageData(image.src) }
            picture = data.flatMap(Self.picture)
        }
    }

    private func placeholder(missing: Bool) -> some View {
        Label(missing ? "Missing image: \(image.src)" : "\(image.alt) (\(image.src))",
              systemImage: missing ? "exclamationmark.triangle" : "photo")
            .font(.callout)
            .foregroundStyle(missing ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func picture(_ data: Data) -> (image: Image, size: CGSize)? {
        #if os(iOS)
        UIImage(data: data).map { (Image(uiImage: $0), $0.size) }
        #else
        NSImage(data: data).map { (Image(nsImage: $0), $0.size) }
        #endif
    }
}
