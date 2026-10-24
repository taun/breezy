import Foundation
import BreezyKit

/// A fake GitHub for tests (BreezyKit's and the app's). Answers requests by "METHOD path" (path without /repos/owner/name and with the query) and records them.
public final class MockTransport: HTTPTransport, @unchecked Sendable {
    public init() {}

    private let lock = NSLock()
    private var routes: [String: ([String: Any]?) -> (Int, Any)] = [:]
    public private(set) var requests: [(key: String, body: [String: Any]?)] = []

    public func on(_ key: String, status: Int = 200, _ json: Any) { lock.withLock { routes[key] = { _ in (status, json) } } }
    /// A route whose answer depends on the request body or on state captured by the closure.
    public func on(_ key: String, handler: @escaping ([String: Any]?) -> (Int, Any)) { lock.withLock { routes[key] = handler } }

    public func bodies(_ key: String) -> [[String: Any]] { lock.withLock { requests.filter { $0.key == key }.compactMap(\.body) } }
    public func count(_ key: String) -> Int { lock.withLock { requests.filter { $0.key == key }.count } }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let full = request.url!.absoluteString
        let path = full.replacingOccurrences(of: "https://api.github.com/repos/o/r", with: "")
        let key = "\(request.httpMethod!) \(path)"
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let handler = lock.withLock {
            requests.append((key, body))
            return routes[key]
        }
        guard let (status, json) = handler?(body) else {
            return (Data(#"{"message":"no route \#(key)"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        let data = try JSONSerialization.data(withJSONObject: json)
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

extension MockTransport {
    /// Accepts pushes to `main`: each commit gets a new sha (c2, c3...) and moves the branch head, as GitHub would.
    public func acceptCommits(startingAt head: String = "c1") {
        let lock = NSLock()
        var current = head, n = 1
        on("POST /git/trees") { _ in (201, ["sha": "tree-new"]) }
        on("POST /git/commits") { [weak self] _ in
            let sha = lock.withLock { n += 1; return "c\(n)" }
            self?.on("GET /git/commits/\(sha)", ["sha": sha, "tree": ["sha": "tree-new"]])
            return (201, ["sha": sha])
        }
        on("PATCH /git/refs/heads/main") { body in
            lock.withLock { current = body?["sha"] as? String ?? current; return (200, ["object": ["sha": current]]) }
        }
        on("GET /git/ref/heads/main") { _ in lock.withLock { (200, ["object": ["sha": current]]) } }
    }

    /// A tiny repo: branch main at c1 with two nodes, a nested file that must be ignored, and one asset.
    public static func site() -> MockTransport {
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

    /// GitHub's branch moves to `commit`, whose tree is the original one with `changing` applied (text, or nil to delete).
    public func remoteMoves(to commit: String, changing: [String: String?]) {
        var files: [String: String] = ["src/nodes/a.md": "ba", "src/nodes/b.md": "bb"]
        for (path, text) in changing {
            if let text {
                let sha = GitBlob.sha(of: text)
                files[path] = sha
                on("GET /git/blobs/\(sha)", ["content": Data(text.utf8).base64EncodedString(), "encoding": "base64"])
            } else {
                files[path] = nil
            }
        }
        on("GET /git/ref/heads/main", ["object": ["sha": commit]])
        on("GET /git/commits/\(commit)", ["sha": commit, "tree": ["sha": "t-\(commit)"]])
        var tree: [[String: Any]] = files.map { ["path": $0.key, "type": "blob", "sha": $0.value] }
        tree.append(["path": "src/assets/images/x.png", "type": "blob", "sha": "bx"])
        on("GET /git/trees/t-\(commit)?recursive=1", ["tree": tree])
    }
}
