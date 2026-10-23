import Foundation

/// The subset of the GitHub REST API Breezy needs: branches, the git data API for reading and committing files,
/// and pull requests. Stateless and Sendable; one instance per repo and token.
public struct GitHubClient: Sendable {
    public let repo: RepoRef
    let token: String
    let transport: HTTPTransport
    let baseURL: URL

    public init(repo: RepoRef, token: String, transport: HTTPTransport = URLSessionTransport(),
                baseURL: URL = URL(string: "https://api.github.com")!) {
        self.repo = repo
        self.token = token
        self.transport = transport
        self.baseURL = baseURL
    }

    // MARK: Repository and branches

    public func defaultBranch() async throws -> String {
        let json = try await object("GET", "")
        guard let b = json["default_branch"] as? String else { throw GitHubError.invalidResponse }
        return b
    }

    public func branches() async throws -> [Branch] {
        let list = try await array("GET", "/branches?per_page=100")
        return list.compactMap { b in
            guard let name = b["name"] as? String, let sha = (b["commit"] as? [String: Any])?["sha"] as? String else { return nil }
            return Branch(name: name, sha: sha)
        }
    }

    /// Head commit of a branch.
    public func headSHA(of branch: String) async throws -> String {
        let json = try await object("GET", "/git/ref/heads/\(Self.escapeRef(branch))")
        guard let sha = (json["object"] as? [String: Any])?["sha"] as? String else { throw GitHubError.invalidResponse }
        return sha
    }

    @discardableResult
    public func createBranch(_ name: String, from sha: String) async throws -> Branch {
        _ = try await object("POST", "/git/refs", body: ["ref": "refs/heads/\(name)", "sha": sha])
        return Branch(name: name, sha: sha)
    }

    public func deleteBranch(_ name: String) async throws {
        _ = try await request("DELETE", "/git/refs/heads/\(Self.escapeRef(name))")
    }

    // MARK: Files

    /// All entries of the commit's tree, recursively.
    public func tree(ofCommit sha: String) async throws -> [TreeEntry] {
        let commit = try await object("GET", "/git/commits/\(sha)")
        guard let treeSHA = (commit["tree"] as? [String: Any])?["sha"] as? String else { throw GitHubError.invalidResponse }
        let json = try await object("GET", "/git/trees/\(treeSHA)?recursive=1")
        let entries = (json["tree"] as? [[String: Any]]) ?? []
        return entries.compactMap { e in
            guard let path = e["path"] as? String, let sha = e["sha"] as? String else { return nil }
            return TreeEntry(path: path, sha: sha, isBlob: (e["type"] as? String) == "blob")
        }
    }

    public func blobText(_ sha: String) async throws -> String {
        let json = try await object("GET", "/git/blobs/\(sha)")
        guard let b64 = json["content"] as? String,
              let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
              let text = String(data: data, encoding: .utf8) else { throw GitHubError.invalidResponse }
        return text
    }

    /// Commits all changes as one commit on `branch`, refusing if the branch head is no longer `expectedHead`.
    /// Returns the new head SHA.
    public func commit(_ changes: [FileChange], message: String, to branch: String, expectedHead: String) async throws -> String {
        let head = try await headSHA(of: branch)
        guard head == expectedHead else { throw GitHubError.branchMoved(branch: branch, expected: expectedHead, actual: head) }
        let parent = try await object("GET", "/git/commits/\(head)")
        guard let baseTree = (parent["tree"] as? [String: Any])?["sha"] as? String else { throw GitHubError.invalidResponse }
        let entries: [[String: Any]] = changes.map { c in
            var e: [String: Any] = ["path": c.path, "mode": "100644", "type": "blob"]
            if let content = c.content { e["content"] = content } else { e["sha"] = NSNull() } // null sha deletes
            return e
        }
        let tree = try await object("POST", "/git/trees", body: ["base_tree": baseTree, "tree": entries])
        guard let treeSHA = tree["sha"] as? String else { throw GitHubError.invalidResponse }
        let commit = try await object("POST", "/git/commits", body: ["message": message, "tree": treeSHA, "parents": [head]])
        guard let commitSHA = commit["sha"] as? String else { throw GitHubError.invalidResponse }
        _ = try await object("PATCH", "/git/refs/heads/\(Self.escapeRef(branch))", body: ["sha": commitSHA, "force": false])
        return commitSHA
    }

    // MARK: Pull requests

    public func openPullRequests() async throws -> [PullRequest] {
        try await array("GET", "/pulls?state=open&per_page=100").map(Self.pullRequest)
    }

    public func pullRequest(_ number: Int) async throws -> PullRequest {
        Self.pullRequest(try await object("GET", "/pulls/\(number)"))
    }

    public func createPullRequest(title: String, head: String, base: String, body: String = "") async throws -> PullRequest {
        Self.pullRequest(try await object("POST", "/pulls", body: ["title": title, "head": head, "base": base, "body": body]))
    }

    /// Merges through GitHub; conflicts and failed checks come back as `GitHubError.mergeFailed`.
    public func merge(_ number: Int, method: MergeMethod) async throws {
        do {
            let json = try await object("PUT", "/pulls/\(number)/merge", body: ["merge_method": method.rawValue])
            if (json["merged"] as? Bool) != true { throw GitHubError.mergeFailed((json["message"] as? String) ?? "not merged") }
        } catch let GitHubError.http(status, message) where status == 405 || status == 409 {
            throw GitHubError.mergeFailed(message)
        }
    }

    // MARK: Plumbing

    static func pullRequest(_ j: [String: Any]) -> PullRequest {
        PullRequest(
            number: j["number"] as? Int ?? 0,
            title: j["title"] as? String ?? "",
            head: (j["head"] as? [String: Any])?["ref"] as? String ?? "",
            base: (j["base"] as? [String: Any])?["ref"] as? String ?? "",
            state: j["state"] as? String ?? "",
            mergeable: j["mergeable"] as? Bool,
            mergeableState: j["mergeable_state"] as? String,
            htmlURL: (j["html_url"] as? String).flatMap(URL.init(string:)))
    }

    /// Branch names may contain "/", which stays as a path separator; everything else is percent-encoded.
    static func escapeRef(_ name: String) -> String {
        name.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? String($0) }
            .joined(separator: "/")
    }

    func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Data {
        guard let url = URL(string: "\(baseURL.absoluteString)/repos/\(repo.owner)/\(repo.name)\(path)") else { throw GitHubError.invalidResponse }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, http) = try await transport.send(req)
        guard (200..<300).contains(http.statusCode) else {
            let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["message"] as? String
            throw GitHubError.http(status: http.statusCode, message: message ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
        return data
    }

    func object(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        let data = try await request(method, path, body: body)
        if data.isEmpty { return [:] }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GitHubError.invalidResponse }
        return json
    }

    func array(_ method: String, _ path: String) async throws -> [[String: Any]] {
        guard let json = try JSONSerialization.jsonObject(with: try await request(method, path)) as? [[String: Any]] else {
            throw GitHubError.invalidResponse
        }
        return json
    }
}
