import Foundation

/// A Markdown image, `![alt](src "title"){.attrs}`, as the site's nodes write them. `src` is usually a site path such
/// as "/assets/images/x.png"; the trailing `{…}` attributes (markdown-it-attrs, e.g. `.align-right`) are ignored.
public struct MarkdownImage: Equatable, Sendable {
    public var alt: String
    public var src: String

    public init(alt: String, src: String) {
        self.alt = alt
        self.src = src
    }

    nonisolated(unsafe) private static let pattern = /!\[([^\]]*)\]\(([^)\s]+)[^)]*\)(?:\{[^}]*\})?/

    /// Every image in the text, in order.
    public static func all(in text: String) -> [MarkdownImage] {
        text.matches(of: pattern).map { MarkdownImage(alt: String($0.1), src: String($0.2)) }
    }

    /// The images the preview shows as pictures: standalone lines outside fenced code.
    public static func shown(in body: String) -> [MarkdownImage] {
        var inCode = false
        return body.components(separatedBy: "\n").compactMap { line in
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inCode.toggle(); return nil }
            return inCode ? nil : standalone(line)
        }
    }

    /// The site path a src names, as asset paths are keyed: leading slash, no query or fragment, percent-decoded
    /// ("/assets/my%20photo.png?v=2" -> "/assets/my photo.png").
    public static func sitePath(_ src: String) -> String {
        let bare = String(src.prefix { $0 != "?" && $0 != "#" })
        let decoded = bare.removingPercentEncoding ?? bare
        return decoded.hasPrefix("/") ? decoded : "/" + decoded
    }

    /// The image when it is the whole line (surrounding spaces aside), which the preview shows as a picture.
    public static func standalone(_ line: String) -> MarkdownImage? {
        guard let m = line.trimmingCharacters(in: .whitespaces).wholeMatch(of: pattern) else { return nil }
        return MarkdownImage(alt: String(m.1), src: String(m.2))
    }
}
