import BreezyKit
import Foundation
import Observation

/// App-wide state: settings, the GitHub connection, the loaded branch, and branch / pull request lists.
@MainActor @Observable
final class AppModel {
    private static let repoKey = "repo"

    var repoString: String = UserDefaults.standard.string(forKey: AppModel.repoKey) ?? "taun/taun.github.io"
    private(set) var hasToken: Bool
    private let tokens: TokenStore

    private(set) var workspace: SiteWorkspace?
    private(set) var defaultBranch = "main"
    private(set) var branches: [Branch] = []
    private(set) var pullRequests: [PullRequest] = []

    var selection: String?
    var errorMessage: String?
    private(set) var isBusy = false

    init(tokens: TokenStore = KeychainTokenStore()) {
        self.tokens = tokens
        hasToken = tokens.load() != nil
    }

    var isConfigured: Bool { hasToken && RepoRef(repoString) != nil }
    var currentBranch: String { workspace?.branch ?? defaultBranch }
    var isOnDefaultBranch: Bool { currentBranch == defaultBranch }

    // MARK: Connection

    func connectIfConfigured() async {
        if isConfigured, workspace == nil { await connect() }
    }

    /// Saves settings, then connects; returns whether the connection worked.
    @discardableResult
    func saveSettings(repo: String, token: String) async -> Bool {
        guard RepoRef(repo) != nil else {
            errorMessage = "Repository must be owner/name."
            return false
        }
        repoString = repo
        UserDefaults.standard.set(repo, forKey: Self.repoKey)
        if !token.isEmpty {
            do { try tokens.save(token) } catch {
                errorMessage = "Could not save the token in the Keychain: \(error.localizedDescription)"
                return false
            }
            hasToken = true
        }
        workspace = nil
        await connect()
        return workspace != nil
    }

    func signOut() {
        tokens.delete()
        hasToken = false
        workspace = nil
        selection = nil
    }

    private func connect() async {
        guard let repo = RepoRef(repoString), let token = tokens.load() else { return }
        let client = GitHubClient(repo: repo, token: token)
        await run {
            let main = try await client.defaultBranch()
            let ws = SiteWorkspace(client: client, branch: main)
            try await ws.load()
            self.defaultBranch = main
            self.workspace = ws
            try await self.refreshLists()
        }
    }

    // MARK: Branches and pull requests

    func refreshLists() async throws {
        guard let client = workspace?.client else { return }
        async let b = client.branches()
        async let p = client.openPullRequests()
        branches = try await b
        pullRequests = try await p
    }

    func refresh() async { await run { try await self.refreshLists() } }

    func reload() async {
        await run {
            try await self.workspace?.load()
            try await self.refreshLists()
        }
    }

    /// Loads another branch. Callers confirm first when there are unsaved edits; they are discarded.
    func switchBranch(_ name: String) async {
        await run {
            try await self.workspace?.load(branch: name)
            if let s = self.selection, self.workspace?.nodes[s] == nil { self.selection = nil }
        }
    }

    /// Creates a branch at the loaded head and switches to it, keeping any uncommitted edits.
    func createBranch(_ name: String) async {
        guard let ws = workspace else { return }
        let edits = ws.nodes
        await run {
            try await ws.client.createBranch(name, from: ws.headSHA)
            try await ws.load(branch: name)
            for (slug, node) in edits { ws.replace(slug, with: node) }
            for slug in ws.slugs where edits[slug] == nil { ws.deleteNode(slug) }
            try await self.refreshLists()
        }
    }

    func deleteBranch(_ name: String) async {
        guard let client = workspace?.client, name != currentBranch, name != defaultBranch else { return }
        await run {
            try await client.deleteBranch(name)
            try await self.refreshLists()
        }
    }

    func commit(message: String) async {
        await run { try await self.workspace?.commit(message: message) }
    }

    func openPullRequest(title: String, body: String) async {
        guard let client = workspace?.client else { return }
        let head = currentBranch, base = defaultBranch
        await run {
            _ = try await client.createPullRequest(title: title, head: head, base: base, body: body)
            try await self.refreshLists()
        }
    }

    /// Fetches one PR again (GitHub computes `mergeable` lazily).
    func refreshPullRequest(_ number: Int) async {
        guard let client = workspace?.client else { return }
        await run {
            let pr = try await client.pullRequest(number)
            if let i = self.pullRequests.firstIndex(where: { $0.number == number }) { self.pullRequests[i] = pr }
        }
    }

    func merge(_ pr: PullRequest, method: MergeMethod, deleteBranch: Bool) async {
        guard let client = workspace?.client else { return }
        await run {
            try await client.merge(pr.number, method: method)
            if deleteBranch, pr.head != self.defaultBranch { try? await client.deleteBranch(pr.head) }
            if deleteBranch, self.currentBranch == pr.head { try await self.workspace?.load(branch: self.defaultBranch) }
            else if self.currentBranch == pr.base { try await self.workspace?.load() }
            try await self.refreshLists()
        }
    }

    // MARK: Helpers

    private func run(_ op: () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do { try await op() } catch { errorMessage = error.localizedDescription }
    }
}
