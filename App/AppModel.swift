import BreezyKit
import Foundation
import Network
import Observation
#if os(macOS)
import AppKit
#endif

/// App-wide state. Offline-first: the current branch opens from the local copy on disk, and GitHub is only used
/// by `sync` (download, reconcile, push queued commits) and by pull requests.
@MainActor @Observable
final class AppModel {
    private static let repoKey = "repo"

    var repoString: String = UserDefaults.standard.string(forKey: AppModel.repoKey) ?? "taun/taun.github.io"
    private(set) var hasToken: Bool
    /// Whether the token is in iCloud Keychain, only on this device (and why), or missing.
    private(set) var tokenSync: KeychainTokenStore.Status = .missing
    private let tokens: TokenStore

    private(set) var store: LocalStore?
    private(set) var repoState = RepoState()
    private(set) var workspace: SiteWorkspace?
    private(set) var pullRequests: [PullRequest] = []

    /// Whether the device has a network path. Syncing is skipped while false.
    private(set) var isOnline = true
    private(set) var isBusy = false
    /// The last sync failure that was not simply "offline".
    private(set) var lastSyncError: String?

    var errorMessage: String?
    var showConflicts = false

    enum DeployStatus: Equatable {
        case none, waiting, running, live, failed(URL?), unknown
    }
    /// The site deploy started by the last publish.
    private(set) var deployStatus: DeployStatus = .none
    private var deployWatch: Task<Void, Never>?

    private let monitor = NWPathMonitor()
    private var started = false

    init(tokens: TokenStore = KeychainTokenStore()) {
        self.tokens = tokens
        hasToken = tokens.load() != nil
        updateTokenSync()
    }

    var repo: RepoRef? { RepoRef(repoString) }
    var client: GitHubClient? { repo.flatMap { r in tokens.load().map { GitHubClient(repo: r, token: $0) } } }
    var defaultBranch: String { repoState.defaultBranch }
    var currentBranch: String { workspace?.branch ?? defaultBranch }
    var isOnDefaultBranch: Bool { currentBranch == defaultBranch }

    /// Branches on GitHub (as last seen) or on this device.
    var branchNames: [String] { Array(Set(repoState.remoteBranches).union(store?.cachedBranches() ?? [])).sorted() }
    func isOnDevice(_ branch: String) -> Bool { store?.branchState(named: branch) != nil }

    enum SyncStatus: Equatable {
        case offline, syncing, conflicts(Int), pending(Int), failed, synced
    }

    var syncStatus: SyncStatus {
        guard let ws = workspace else { return isOnline ? .synced : .offline }
        if isBusy || ws.isSyncing { return .syncing }
        if !ws.conflicts.isEmpty { return .conflicts(ws.conflicts.count) }
        if !isOnline { return .offline }
        if lastSyncError != nil { return .failed }
        if !ws.queue.isEmpty || !ws.state.existsOnRemote { return .pending(ws.queue.count) }
        return .synced
    }

    // MARK: Start-up

    /// Opens the local copy straight away, then syncs whenever a network path is available.
    func start() async {
        guard !started else { return } // one model, possibly several windows
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let was = self.isOnline
                self.isOnline = satisfied
                if satisfied && !was { await self.sync() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "org.taun.Breezy.network"))
        openLocal()
        await sync()
    }

    private func openLocal() {
        guard let repo else { return }
        let store = LocalStore.standard(for: repo)
        self.store = store
        repoState = store.repoState() ?? RepoState()
        do { workspace = try SiteWorkspace.open(repoState.lastBranch ?? repoState.defaultBranch, store: store) } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Settings

    @discardableResult
    func saveSettings(repo newRepo: String, token: String) async -> Bool {
        guard RepoRef(newRepo) != nil else {
            errorMessage = "Repository must be owner/name."
            return false
        }
        if newRepo != repoString || store == nil {
            repoString = newRepo
            UserDefaults.standard.set(newRepo, forKey: Self.repoKey)
            workspace = nil
            openLocal()
        }
        if !token.isEmpty {
            do { try tokens.save(token) } catch {
                errorMessage = "Could not save the token in the Keychain: \(error.localizedDescription)"
                return false
            }
            hasToken = true
            updateTokenSync()
        }
        await sync()
        return workspace != nil
    }

    /// Re-reads the token, which iCloud Keychain may have delivered since launch, and connects if it is new.
    func refreshToken() async {
        let had = hasToken
        hasToken = tokens.load() != nil
        updateTokenSync()
        if hasToken && !had { await sync() }
    }

    private func updateTokenSync() {
        tokenSync = (tokens as? KeychainTokenStore)?.status() ?? (hasToken ? .synced : .missing)
    }

    func signOut() {
        tokens.delete()
        tokenSync = .missing
        hasToken = false
    }

    // MARK: Syncing

    /// Refreshes branch names and pull requests, downloads the branch if there is no local copy, then reconciles and pushes.
    func sync() async {
        guard isOnline, let client, let store, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            async let main = client.defaultBranch()
            async let remote = client.branches()
            repoState.defaultBranch = try await main
            repoState.remoteBranches = try await remote.map(\.name)
            if workspace == nil {
                let branch = repoState.lastBranch.flatMap { repoState.remoteBranches.contains($0) ? $0 : nil } ?? repoState.defaultBranch
                workspace = try await SiteWorkspace.download(branch, client: client, store: store)
                repoState.lastBranch = branch
            }
            if repoState.websiteURL == nil, let repo {
                let cname = try await client.fileText("src/CNAME", ref: repoState.defaultBranch)
                repoState.websiteURL = Publisher.siteURL(repo: repo, cname: cname)
            }
            try store.saveRepoState(repoState)
            if let ws = workspace, case .conflicts = try await ws.sync(client: client) { showConflicts = true }
            pullRequests = try await client.openPullRequests()
            lastSyncError = nil
        } catch {
            handle(error)
        }
    }

    /// Network failures mean "offline" and stay quiet; anything else is reported.
    private func handle(_ error: Error) {
        let offlineCodes: [URLError.Code] = [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
                                             .cannotConnectToHost, .dataNotAllowed, .internationalRoamingOff]
        if let e = error as? URLError, offlineCodes.contains(e.code) {
            isOnline = false
            return
        }
        lastSyncError = error.localizedDescription
        errorMessage = error.localizedDescription
    }

    private func attempt(_ op: () throws -> Void) {
        do { try op() } catch { errorMessage = error.localizedDescription }
    }

    // MARK: Branches

    /// Opens a branch from the device, downloading it first if needed (online only).
    func switchBranch(_ name: String) async {
        guard let store else { return }
        do {
            if let ws = try SiteWorkspace.open(name, store: store) {
                workspace = ws
            } else {
                guard isOnline, let client else {
                    errorMessage = "“\(name)” is not on this device yet. Connect to the internet to download it."
                    return
                }
                isBusy = true
                defer { isBusy = false }
                workspace = try await SiteWorkspace.download(name, client: client, store: store)
            }
            repoState.lastBranch = name
            try store.saveRepoState(repoState)
        } catch {
            handle(error)
        }
        await sync()
    }

    /// Creates a branch on this device carrying the uncommitted edits; it reaches GitHub at the next sync.
    func createBranch(_ name: String) async {
        guard let ws = workspace, let store else { return }
        attempt {
            workspace = try ws.branchOff(name)
            repoState.lastBranch = name
            try store.saveRepoState(repoState)
        }
        await sync()
    }

    /// Deletes a branch on GitHub (if it is there) and its local copy.
    func deleteBranch(_ name: String) async {
        guard name != currentBranch, name != defaultBranch, let store else { return }
        if repoState.remoteBranches.contains(name) {
            guard isOnline, let client else {
                errorMessage = "Deleting a branch on GitHub needs a connection."
                return
            }
            do { try await client.deleteBranch(name) } catch { return handle(error) }
            repoState.remoteBranches.removeAll { $0 == name }
        }
        attempt {
            try store.removeBranch(name)
            try store.saveRepoState(repoState)
        }
    }

    // MARK: Commits and conflicts

    func commit(message: String) async {
        guard let ws = workspace else { return }
        attempt { try ws.commit(message: message) }
        await sync()
    }

    func resolve(_ path: String, with resolution: ConflictResolution) async {
        guard let ws = workspace else { return }
        attempt { try ws.resolve(path, with: resolution) }
        if ws.conflicts.isEmpty {
            showConflicts = false
            await sync()
        }
    }

    // MARK: Pull requests (online only)

    func openPullRequest(title: String, body: String) async {
        guard let client else { return }
        let head = currentBranch, base = defaultBranch
        await online {
            _ = try await client.createPullRequest(title: title, head: head, base: base, body: body)
            pullRequests = try await client.openPullRequests()
        }
    }

    func refreshPullRequest(_ number: Int) async {
        guard let client else { return }
        await online {
            let pr = try await client.pullRequest(number)
            if let i = pullRequests.firstIndex(where: { $0.number == number }) { pullRequests[i] = pr }
        }
    }

    func merge(_ pr: PullRequest, method: MergeMethod, deleteBranch: Bool) async {
        guard let client else { return }
        await online {
            try await client.merge(pr.number, method: method)
            if deleteBranch, pr.head != defaultBranch {
                try? await client.deleteBranch(pr.head)
                repoState.remoteBranches.removeAll { $0 == pr.head }
                if currentBranch != pr.head { try? store?.removeBranch(pr.head) }
            }
        }
        if deleteBranch, currentBranch == pr.head {
            await switchBranch(defaultBranch)
            try? store?.removeBranch(pr.head)
        } else {
            await sync()
        }
    }

    private func online(_ op: () async throws -> Void) async {
        guard isOnline else {
            errorMessage = "Pull requests need a connection."
            return
        }
        isBusy = true
        defer { isBusy = false }
        do { try await op() } catch { handle(error) }
    }

    // MARK: Publishing

    var websiteURL: URL? { repoState.websiteURL ?? repo.flatMap { Publisher.siteURL(repo: $0, cname: nil) } }

    func setWebsiteURL(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        repoState.websiteURL = trimmed.isEmpty ? nil : URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)")
        attempt { try store?.saveRepoState(repoState) }
    }

    /// What publishing the current branch would add to the default branch.
    func comparison() async -> Comparison? {
        guard isOnline, let client, !isOnDefaultBranch, workspace?.state.existsOnRemote == true else { return nil }
        return try? await client.compare(base: defaultBranch, head: currentBranch)
    }

    /// Pushes anything queued, merges the current branch into the default branch, and watches the site deploy.
    func publish(method: MergeMethod, deleteBranch: Bool) async -> Bool {
        guard let ws = workspace, let client, let store, !isOnDefaultBranch else { return false }
        guard isOnline else { errorMessage = "Publishing needs a connection."; return false }
        guard !ws.hasChanges else { errorMessage = "Commit your changes first, then publish."; return false }
        await sync()
        guard ws.queue.isEmpty, ws.conflicts.isEmpty, ws.state.existsOnRemote else {
            errorMessage = ws.conflicts.isEmpty ? "Some commits could not be pushed yet. Try again when the sync succeeds." : "Resolve the conflicts first."
            return false
        }
        let branch = ws.branch
        isBusy = true
        do {
            let result = try await Publisher.publish(branch: branch, into: defaultBranch, title: "Publish \(branch)",
                                                     method: method, deleteBranch: deleteBranch, client: client)
            isBusy = false
            watchDeploy(result.mergeCommit)
            if deleteBranch {
                repoState.remoteBranches.removeAll { $0 == branch }
                await switchBranch(defaultBranch)
                try? store.removeBranch(branch)
                try? store.saveRepoState(repoState)
            } else {
                await sync()
            }
            return true
        } catch {
            isBusy = false
            handle(error)
            return false
        }
    }

    /// Polls the GitHub Actions run for the merge commit until the deploy finishes (up to 15 minutes).
    private func watchDeploy(_ sha: String) {
        deployWatch?.cancel()
        deployStatus = .waiting
        guard let client else { return }
        deployWatch = Task { [weak self] in
            for _ in 0..<90 {
                do {
                    if let run = try await client.workflowRun(forCommit: sha) {
                        if run.isFinished {
                            self?.deployStatus = run.succeeded ? .live : .failed(run.htmlURL)
                            return
                        }
                        self?.deployStatus = .running
                    }
                } catch {
                    // Most likely the token lacks "Actions: read"; the site still deploys, we just cannot watch it.
                    self?.deployStatus = .unknown
                    return
                }
                try? await Task.sleep(for: .seconds(10))
                if Task.isCancelled { return }
            }
            self?.deployStatus = .unknown
        }
    }

    // MARK: Local files

    var localFolder: URL? { store?.root }

    func revealLocalFiles() {
        #if os(macOS)
        guard let root = store?.root else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([root])
        #endif
    }
}
