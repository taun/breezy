import Foundation

/// Publishing = merging a branch into the default branch through a pull request, which triggers the site deploy.
public enum Publisher {
    public struct Result: Equatable, Sendable {
        public var pullRequest: Int
        public var mergeCommit: String
    }

    /// Uses the open pull request for `branch` (or opens one), waits for GitHub to decide whether it can merge,
    /// merges it, and optionally deletes the branch on GitHub.
    public static func publish(branch: String, into base: String, title: String, method: MergeMethod, deleteBranch: Bool,
                               client: GitHubClient, pollDelay: Duration = .seconds(1), attempts: Int = 10) async throws -> Result {
        let open = try await client.openPullRequests().first { $0.head == branch && $0.base == base }
        var pr = if let open { open } else { try await client.createPullRequest(title: title, head: branch, base: base) }
        // GitHub computes mergeability in the background; `mergeable` is null until it has.
        var tries = 0
        while pr.mergeable == nil && tries < attempts {
            try await Task.sleep(for: pollDelay)
            pr = try await client.pullRequest(pr.number)
            tries += 1
        }
        if pr.mergeable == false {
            throw GitHubError.mergeFailed("“\(branch)” conflicts with \(base). Resolve it on GitHub (pull request #\(pr.number)), then publish again.")
        }
        let sha = try await client.merge(pr.number, method: method)
        if deleteBranch { try? await client.deleteBranch(branch) }
        return Result(pullRequest: pr.number, mergeCommit: sha)
    }

    /// The public address of a GitHub Pages site: the custom domain in CNAME if there is one, else github.io.
    public static func siteURL(repo: RepoRef, cname: String?) -> URL? {
        if let domain = cname?.trimmingCharacters(in: .whitespacesAndNewlines), !domain.isEmpty {
            return URL(string: "https://\(domain)/")
        }
        let user = repo.owner.lowercased()
        return repo.name.lowercased() == "\(user).github.io" ? URL(string: "https://\(user).github.io/") : URL(string: "https://\(user).github.io/\(repo.name)/")
    }
}
