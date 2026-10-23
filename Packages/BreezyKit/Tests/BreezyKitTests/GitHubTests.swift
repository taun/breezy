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

@Suite struct PublishTests {
    let repo = RepoRef(owner: "o", name: "r")

    @Test func publishOpensWaitsForMergeabilityMergesAndDeletes() async throws {
        let m = MockTransport()
        m.on("GET /pulls?state=open&per_page=100", [])
        m.on("POST /pulls", status: 201, ["number": 5, "title": "T", "state": "open", "head": ["ref": "edit"], "base": ["ref": "main"]])
        var polls = 0
        m.on("GET /pulls/5") { _ in
            polls += 1
            return (200, ["number": 5, "title": "T", "state": "open", "head": ["ref": "edit"], "base": ["ref": "main"],
                          "mergeable": polls >= 2 ? true as Any : NSNull()])
        }
        m.on("PUT /pulls/5/merge", ["merged": true, "sha": "m9"])
        m.on("DELETE /git/refs/heads/edit", status: 204, [:])
        let r = try await Publisher.publish(branch: "edit", into: "main", title: "T", method: .squash, deleteBranch: true,
                                            client: GitHubClient(repo: repo, token: "t", transport: m), pollDelay: .zero)
        #expect(r == Publisher.Result(pullRequest: 5, mergeCommit: "m9"))
        #expect(m.count("GET /pulls/5") == 2)
        #expect(m.count("DELETE /git/refs/heads/edit") == 1)
    }

    @Test func publishReusesOpenPullRequestAndStopsOnConflicts() async throws {
        let m = MockTransport()
        m.on("GET /pulls?state=open&per_page=100", [["number": 3, "title": "T", "state": "open", "head": ["ref": "edit"], "base": ["ref": "main"], "mergeable": false]])
        await #expect(throws: GitHubError.self) {
            _ = try await Publisher.publish(branch: "edit", into: "main", title: "T", method: .merge, deleteBranch: true,
                                            client: GitHubClient(repo: repo, token: "t", transport: m), pollDelay: .zero)
        }
        #expect(m.count("POST /pulls") == 0 && m.count("PUT /pulls/3/merge") == 0)
    }

    @Test func compareWorkflowAndFiles() async throws {
        let m = MockTransport()
        m.on("GET /compare/main...feature/x", ["ahead_by": 2, "behind_by": 0, "files": [["filename": "src/nodes/a.md"]]])
        m.on("GET /actions/runs?head_sha=m9&per_page=1", ["workflow_runs": [["name": "Deploy", "status": "completed", "conclusion": "success"]]])
        m.on("GET /contents/src/CNAME?ref=main", ["content": Data("www.taun.org\n".utf8).base64EncodedString()])
        let c = GitHubClient(repo: repo, token: "t", transport: m)
        #expect(try await c.compare(base: "main", head: "feature/x") == Comparison(aheadBy: 2, behindBy: 0, files: ["src/nodes/a.md"]))
        #expect(try await c.workflowRun(forCommit: "m9")?.succeeded == true)
        #expect(try await c.fileText("src/CNAME", ref: "main") == "www.taun.org\n")
        #expect(try await c.fileText("missing", ref: "main") == nil)
    }

    @Test func siteURLs() {
        #expect(Publisher.siteURL(repo: RepoRef(owner: "taun", name: "taun.github.io"), cname: "www.taun.org\n")?.absoluteString == "https://www.taun.org/")
        #expect(Publisher.siteURL(repo: RepoRef(owner: "Taun", name: "taun.github.io"), cname: nil)?.absoluteString == "https://taun.github.io/")
        #expect(Publisher.siteURL(repo: RepoRef(owner: "taun", name: "blog"), cname: nil)?.absoluteString == "https://taun.github.io/blog/")
    }
}
