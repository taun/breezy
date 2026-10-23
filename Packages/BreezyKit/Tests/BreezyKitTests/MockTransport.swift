import Foundation
@testable import BreezyKit

/// Answers requests by "METHOD path" (path without /repos/owner/name and with the query) and records them.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [String: (Int, Any)] = [:]
    private(set) var requests: [(key: String, body: [String: Any]?)] = []

    func on(_ key: String, status: Int = 200, _ json: Any) { lock.withLock { routes[key] = (status, json) } }

    func bodies(_ key: String) -> [[String: Any]] { lock.withLock { requests.filter { $0.key == key }.compactMap(\.body) } }
    func count(_ key: String) -> Int { lock.withLock { requests.filter { $0.key == key }.count } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let full = request.url!.absoluteString
        let path = full.replacingOccurrences(of: "https://api.github.com/repos/o/r", with: "")
        let key = "\(request.httpMethod!) \(path)"
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let route: (Int, Any)? = lock.withLock {
            requests.append((key, body))
            return routes[key]
        }
        guard let (status, json) = route else {
            return (Data(#"{"message":"no route \#(key)"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        let data = try JSONSerialization.data(withJSONObject: json)
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

extension MockTransport {
    /// A tiny repo: branch main at c1 with two nodes, a nested file that must be ignored, and one asset.
    static func site() -> MockTransport {
        let m = MockTransport()
        let b64 = { (s: String) in Data(s.utf8).base64EncodedString() }
        m.on("GET /git/ref/heads/main", ["object": ["sha": "c1"]])
        m.on("GET /git/commits/c1", ["sha": "c1", "tree": ["sha": "t1"]])
        m.on("GET /git/trees/t1?recursive=1", ["tree": [
            ["path": "src/nodes/a.md", "type": "blob", "sha": "ba"],
            ["path": "src/nodes/b.md", "type": "blob", "sha": "bb"],
            ["path": "src/nodes/sub/c.md", "type": "blob", "sha": "bc"],
            ["path": "src/nodes", "type": "tree", "sha": "tn"],
            ["path": "src/assets/images/x.png", "type": "blob", "sha": "bx"],
            ["path": "README.md", "type": "blob", "sha": "br"],
        ]])
        m.on("GET /git/blobs/ba", ["content": b64("---\ntitle: \"A\"\ntype: person\nlinks: [b]\n---\n\nBody A\n"), "encoding": "base64"])
        m.on("GET /git/blobs/bb", ["content": b64("---\ntitle: \"B\"\ntype: company\ndate: 2001\nlinks: []\n---\n"), "encoding": "base64"])
        return m
    }
}
