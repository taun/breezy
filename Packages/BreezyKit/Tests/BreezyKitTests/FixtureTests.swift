import Foundation
import Testing
@testable import BreezyKit

/// Runs against the site repo's docs/fixtures so the app and the real build agree. Set BREEZY_SITE_DIR to override the location.
enum Fixtures {
    static var dir: URL {
        if let p = ProcessInfo.processInfo.environment["BREEZY_SITE_DIR"] { return URL(fileURLWithPath: p).appendingPathComponent("docs/fixtures") }
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { u.deleteLastPathComponent() } // BreezyKitTests, Tests, BreezyKit, Packages, Breezy, taun
        return u.appendingPathComponent("taun.github.io/docs/fixtures")
    }

    static func files() throws -> [(key: String, slug: String, text: String)] {
        var out: [(String, String, String)] = []
        for group in ["valid", "edge"] {
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent(group).path).filter { $0.hasSuffix(".md") }.sorted()
            for n in names {
                let slug = String(n.dropLast(3))
                out.append(("\(group)/\(slug)", slug, try String(contentsOfFile: dir.appendingPathComponent("\(group)/\(n)").path, encoding: .utf8)))
            }
        }
        return out
    }
}

@Suite struct FixtureTests {
    @Test func derivedValuesMatchTheSiteBuild() throws {
        let data = try Data(contentsOf: Fixtures.dir.appendingPathComponent("expected.json"))
        let expected = try #require(JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
        let files = try Fixtures.files()
        #expect(files.count == expected.count)
        for f in files {
            let exp = try #require(expected[f.key], "no expected entry for \(f.key)")
            let node = try NodeFile(slug: f.slug, text: f.text)
            #expect(node.type == exp["type"] as? String, "\(f.key) type")
            #expect(node.date?.iso == exp["date"] as? String, "\(f.key) date")
            #expect(node.date?.precision.rawValue == exp["datePrecision"] as? String, "\(f.key) precision")
            #expect(node.draft == exp["draft"] as? Bool, "\(f.key) draft")
            let expLinks = (exp["links"] as? [[String: String]] ?? []).map { NodeLink(to: $0["to"]!, rel: $0["rel"]!) }
            #expect(node.links == expLinks, "\(f.key) links")
            #expect(node.linkWarnings.count == (exp["warnings"] as? [String] ?? []).count, "\(f.key) warnings")
        }
    }

    @Test func unmodifiedFilesRenderByteForByte() throws {
        for f in try Fixtures.files() {
            #expect(try NodeFile(slug: f.slug, text: f.text).rendered() == f.text, "\(f.key)")
        }
    }
}
