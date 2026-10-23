import Foundation
import Testing
@testable import BreezyKit

@Suite struct GitHubClientTests {
    let repo = RepoRef(owner: "o", name: "r")

    @Test func commitBuildsTreeCommitAndMovesRef() async throws {
        let m = MockTransport.site()
        m.on("POST /git/trees", ["sha": "t2"])
        m.on("POST /git/commits", ["sha": "c2"])
        m.on("PATCH /git/refs/heads/main", ["object": ["sha": "c2"]])
        let client = GitHubClient(repo: repo, token: "tok", transport: m)
        let sha = try await client.commit([FileChange(path: "src/nodes/a.md", content: "x"), FileChange(path: "src/nodes/b.md", content: nil)],
                                          message: "msg", to: "main", expectedHead: "c1")
        #expect(sha == "c2")
        let tree = try #require(m.bodies("POST /git/trees").first)
        #expect(tree["base_tree"] as? String == "t1")
        let entries = try #require(tree["tree"] as? [[String: Any]])
        #expect(entries[0]["content"] as? String == "x")
        #expect(entries[1]["sha"] is NSNull) // deletion
        #expect(m.bodies("POST /git/commits").first?["parents"] as? [String] == ["c1"])
        #expect(m.bodies("PATCH /git/refs/heads/main").first?["force"] as? Bool == false)
    }

    @Test func commitRefusesWhenBranchMoved() async throws {
        let m = MockTransport.site()
        let client = GitHubClient(repo: repo, token: "tok", transport: m)
        await #expect(throws: GitHubError.branchMoved(branch: "main", expected: "old", actual: "c1")) {
            try await client.commit([FileChange(path: "p", content: "x")], message: "m", to: "main", expectedHead: "old")
        }
        #expect(m.count("POST /git/trees") == 0)
    }

    @Test func pullRequestCreateAndMerge() async throws {
        let m = MockTransport()
        m.on("POST /pulls", status: 201, ["number": 7, "title": "T", "state": "open", "head": ["ref": "edit"], "base": ["ref": "main"],
                                          "html_url": "https://github.com/o/r/pull/7"])
        m.on("PUT /pulls/7/merge", ["merged": true, "sha": "m1"])
        let client = GitHubClient(repo: repo, token: "tok", transport: m)
        let pr = try await client.createPullRequest(title: "T", head: "edit", base: "main")
        #expect(pr.number == 7 && pr.head == "edit" && pr.base == "main")
        try await client.merge(7, method: .squash)
        #expect(m.bodies("PUT /pulls/7/merge").first?["merge_method"] as? String == "squash")
    }

    @Test func mergeConflictIsReported() async throws {
        let m = MockTransport()
        m.on("PUT /pulls/8/merge", status: 405, ["message": "Pull Request is not mergeable"])
        let client = GitHubClient(repo: repo, token: "tok", transport: m)
        await #expect(throws: GitHubError.mergeFailed("Pull Request is not mergeable")) { try await client.merge(8, method: .merge) }
    }

    @Test func branchesAndErrors() async throws {
        let m = MockTransport()
        m.on("GET /branches?per_page=100", [["name": "main", "commit": ["sha": "c1"]], ["name": "feature/x", "commit": ["sha": "c3"]]])
        m.on("POST /git/refs", status: 201, ["ref": "refs/heads/new"])
        let client = GitHubClient(repo: repo, token: "tok", transport: m)
        #expect(try await client.branches().map(\.name) == ["main", "feature/x"])
        try await client.createBranch("new", from: "c1")
        #expect(m.bodies("POST /git/refs").first?["ref"] as? String == "refs/heads/new")
        #expect(GitHubClient.escapeRef("feature/my edit") == "feature/my%20edit")
        await #expect(throws: GitHubError.self) { _ = try await client.defaultBranch() } // unrouted -> 404
    }

    @Test func repoRefParsing() {
        #expect(RepoRef("taun/taun.github.io") == RepoRef(owner: "taun", name: "taun.github.io"))
        #expect(RepoRef("nope") == nil)
    }
}
