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

    var repoString: String
    private(set) var hasToken: Bool
    /// Whether the token is in iCloud Keychain, only on this device (and why), or missing.
    private(set) var tokenSync: KeychainTokenStore.Status = .missing
    private let tokens: TokenStore
    // Injected so tests can run AppModel against a fake GitHub, a temporary folder and their own settings.
    private let defaults: UserDefaults
    private let transport: HTTPTransport
    private let imageFetcher: ImageFetching
    private let storeFor: (RepoRef) -> LocalStore

    private(set) var store: LocalStore?
    private(set) var repoState = RepoState()
    private(set) var workspace: SiteWorkspace? {
        didSet {
            guard workspace !== oldValue else { return }
            // A picture on its way belongs to the copy just left (which must not write its stale state over the new one).
            if headerImageImport?.cancelled == false {
                cancelHeaderImage()
                errorMessage = HeaderImageError.branchChanged.localizedDescription
            }
            // Cursor moves not written yet; dropped for a copy that was just removed (moved edits, published branch).
            if let old = oldValue {
                if old.store.branchState(named: old.branch) != nil { try? old.flushEditorStates() } else { old.cancelPendingStateWrites() }
            }
            if let workspace { importLegacyEditorState(workspace) }
        }
    }
    private(set) var pullRequests: [PullRequest] = []

    /// Whether the device has a network path. Syncing is skipped while false.
    private(set) var isOnline = true
    /// The slow operation in progress, shown as a banner (with file counts while downloading). nil when idle.
    struct Activity: Equatable {
        var title: String
        var done = 0
        var total = 0
    }
    private(set) var activity: Activity?
    var isBusy: Bool { activity != nil }

    private func begin(_ title: String) { activity = Activity(title: title) }
    private func end() { activity = nil }
    /// Feeds download counts into the current activity.
    private var progress: SiteWorkspace.Progress {
        { [weak self] done, total in
            self?.activity?.done = done
            self?.activity?.total = total
        }
    }
    /// The last sync failure that was not simply "offline".
    private(set) var lastSyncError: String?

    var errorMessage: String?
    var showConflicts = false
    /// Shown when the current branch is gone from GitHub but this device still has local changes on it.
    var showBranchDeleted = false
    /// Set to ask the window to open Settings (e.g. from the sync status when there is no token).
    var wantsSettings = false

    enum DeployStatus: Equatable {
        case none, waiting, running, live, failed(URL?), unknown
    }
    /// The site deploy started by the last publish.
    private(set) var deployStatus: DeployStatus = .none
    private var deployWatch: Task<Void, Never>?

    private let monitor = NWPathMonitor()
    private var started = false

    init(tokens: TokenStore = KeychainTokenStore(), defaults: UserDefaults = .standard,
         transport: HTTPTransport = URLSessionTransport(), imageFetcher: ImageFetching = URLSessionImageFetcher(),
         storeFor: @escaping (RepoRef) -> LocalStore = LocalStore.standard(for:)) {
        var tokens = tokens
        var transport = transport
        self.defaults = defaults
        self.storeFor = storeFor
        repoString = defaults.string(forKey: Self.repoKey) ?? "taun/taun.github.io"
        #if DEBUG
        // Test runs against a sandbox repo (scripts/simulator.sh with BREEZY_SANDBOX=1): the token comes from the
        // environment and lives only in memory, so it never touches the Keychain or iCloud. Not in release builds.
        let env = ProcessInfo.processInfo.environment
        if let token = env["BREEZY_TEST_TOKEN"], !token.isEmpty, let repo = env["BREEZY_TEST_REPO"], RepoRef(repo) != nil {
            tokens = MemoryTokenStore(token)
            repoString = repo
        }
        // BREEZY_TEST_OFFLINE=1: every GitHub request fails as with no network, to exercise the offline paths.
        if env["BREEZY_TEST_OFFLINE"] == "1" { transport = OfflineTransport() }
        #endif
        self.transport = transport
        self.imageFetcher = imageFetcher
        self.tokens = tokens
        hasToken = tokens.load() != nil
        updateTokenSync()
    }

    var repo: RepoRef? { RepoRef(repoString) }
    var client: GitHubClient? { repo.flatMap { r in tokens.load().map { GitHubClient(repo: r, token: $0, transport: transport) } } }

    // MARK: Header images

    /// The header picture being added: read from a drop or the clipboard, or downloaded. One at a time, since a later
    /// one would be replaced when an earlier one lands. Kept here, not in the Media tab's view, so leaving the tab does
    /// not forget it while it is still on its way.
    struct HeaderImageImport: Equatable {
        /// The workspace and node it is for.
        var workspace: ObjectIdentifier
        var slug: String
        /// From a typed address, rather than a drop or paste: only that control shows progress.
        var fromAddress: Bool
        /// Cancel was asked for; it ends when a picture being resized is done.
        var cancelled = false

        func isFor(_ slug: String, in ws: SiteWorkspace) -> Bool { self.slug == slug && workspace == ObjectIdentifier(ws) }
    }

    private(set) var headerImageImport: HeaderImageImport?
    private var headerImageTask: Task<Bool, Never>?

    /// A picture dropped on a node's Media tab. Its items are asked for at once, while the drop is being performed.
    /// Nil when the drop is not taken (another picture is on its way).
    @discardableResult
    func dropHeaderImage(_ providers: [NSItemProvider], slug: String, in ws: SiteWorkspace, makeThumbnail: Bool) -> Task<Bool, Never>? {
        readHeaderImage(providers, slug: slug, in: ws, makeThumbnail: makeThumbnail, takingAddress: true, else: .nothingToDrop)
    }

    /// A picture pasted from the clipboard, read like a dropped one. A link on the clipboard is not downloaded.
    @discardableResult
    func pasteHeaderImage(_ providers: [NSItemProvider], slug: String, in ws: SiteWorkspace, makeThumbnail: Bool) -> Task<Bool, Never>? {
        readHeaderImage(providers, slug: slug, in: ws, makeThumbnail: makeThumbnail, takingAddress: false, else: .nothingOnClipboard)
    }

    private func readHeaderImage(_ providers: [NSItemProvider], slug: String, in ws: SiteWorkspace, makeThumbnail: Bool,
                                 takingAddress: Bool, else none: HeaderImageError) -> Task<Bool, Never>? {
        guard !providers.isEmpty, claimHeaderImage(slug: slug, in: ws, fromAddress: false) else { return nil }
        let pending = DroppedImage.start(providers)
        return addHeaderImage(slug: slug, in: ws, makeThumbnail: makeThumbnail) {
            switch try await pending.value() {
            case let .data(data)?: return .data(data)
            case let .address(address)? where takingAddress: return .address(ImageSource.secured(address))
            default: throw none
            }
        }
    }

    /// Copies the picture at a web address into the node's header images. Only the downloaded picture is kept, never
    /// the address. Needs a connection; the node is left alone if anything fails.
    @discardableResult
    func importHeaderImage(slug: String, from address: String, makeThumbnail: Bool, in ws: SiteWorkspace) -> Task<Bool, Never>? {
        guard claimHeaderImage(slug: slug, in: ws, fromAddress: true) else { return nil }
        return addHeaderImage(slug: slug, in: ws, makeThumbnail: makeThumbnail) { .address(address) }
    }

    /// Stops the picture on its way (a photo still downloading from iCloud, a slow website). The node is left alone.
    /// Waiting (for a download, a photo from iCloud, a slow file) ends at once; a picture being resized finishes first,
    /// so two are never resized together.
    func cancelHeaderImage() {
        headerImageTask?.cancel()
        headerImageImport?.cancelled = true
    }

    private enum HeaderImageError: LocalizedError {
        case busy, nothingToDrop, nothingOnClipboard, branchChanged, nodeGone

        var errorDescription: String? {
            switch self {
            case .busy: "A picture is still being added. Try again when it is done, or cancel it."
            case .nothingToDrop: "Only a picture, a picture file or a link to a picture can be dropped here."
            case .nothingOnClipboard: "There is no picture on the clipboard that Breezy can read."
            case .branchChanged: "The picture was not added: the branch (or repository) changed before it was ready. Add it again."
            case .nodeGone: "The node was deleted before its picture was ready."
            }
        }
    }

    private func claimHeaderImage(slug: String, in ws: SiteWorkspace, fromAddress: Bool) -> Bool {
        guard ws === workspace else { return false } // a view still showing the copy just left
        guard headerImageImport == nil else {
            errorMessage = HeaderImageError.busy.localizedDescription
            return false
        }
        headerImageImport = HeaderImageImport(workspace: ObjectIdentifier(ws), slug: slug, fromAddress: fromAddress)
        return true
    }

    /// Reads (or downloads) the picture, makes the banner and thumbnail off the main actor, and gives them to the node,
    /// if it and its branch are still there: a branch switched meanwhile has a new workspace, and the old one must not
    /// write its stale state over it. Works offline for bytes. The returned work's value says if it succeeded.
    private func addHeaderImage(slug: String, in ws: SiteWorkspace, makeThumbnail: Bool,
                                _ load: @escaping @MainActor () async throws -> DroppedImage) -> Task<Bool, Never> {
        let task = Task { [imageFetcher] in
            defer {
                headerImageImport = nil
                headerImageTask = nil
            }
            do {
                let data: Data
                switch try await load() {
                case let .data(bytes): data = bytes
                case let .address(address):
                    guard isOnline else { throw ImageFetchError.offline }
                    data = try await imageFetcher.fetch(try ImageSource.url(from: address))
                }
                try Task.checkCancellation()
                let pictures = try await Task.detached(priority: .userInitiated) {
                    try HeaderPictures(from: data, makeThumbnail: makeThumbnail)
                }.value
                try Task.checkCancellation() // also when the branch changed: see `workspace`
                guard ws.nodes[slug] != nil else { throw HeaderImageError.nodeGone }
                try ws.setHeaderImage(slug: slug, pictures: pictures)
                return true
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
                return false
            }
        }
        headerImageTask = task
        return task
    }

    /// Files an issue in Breezy's own repository with the saved token. Returns the new issue, or nil with `errorMessage` set.
    /// The token must also cover taun/breezy with Issues read and write; GitHub answers 403/404 otherwise.
    func fileIssue(title: String, body: String, kind: IssueKind, execute: Bool) async -> Issue? {
        guard isOnline else {
            errorMessage = "Filing an issue needs a network connection. Try again when you are online."
            return nil
        }
        guard let token = tokens.load() else {
            errorMessage = "Save a GitHub token in Settings first."
            return nil
        }
        let client = GitHubClient(repo: .breezy, token: token, transport: transport)
        let labels = [kind.rawValue] + (execute ? ["execute"] : [])
        do {
            return try await client.createIssue(title: title.trimmingCharacters(in: .whitespacesAndNewlines), body: body, labels: labels)
        } catch let GitHubError.http(status, _) where status == 403 || status == 404 {
            errorMessage = "GitHub would not let this token file issues in \(RepoRef.breezy.description) (\(status)). Edit the token on github.com: add that repository and set **Issues** to read and write."
        } catch {
            handle(error)
        }
        return nil
    }

    var defaultBranch: String { repoState.defaultBranch }
    var currentBranch: String { workspace?.branch ?? defaultBranch }
    var isOnDefaultBranch: Bool { currentBranch == defaultBranch }

    /// Branches on GitHub (as last seen) or on this device.
    var branchNames: [String] { Array(Set(repoState.remoteBranches).union(store?.cachedBranches() ?? [])).sorted() }
    func isOnDevice(_ branch: String) -> Bool { store?.branchState(named: branch) != nil }

    /// On this device, was on GitHub, and is not there any more (kept because it has local changes).
    func isDeletedOnGitHub(_ branch: String) -> Bool {
        guard let state = store?.branchState(named: branch) else { return false }
        return state.existsOnRemote && !repoState.remoteBranches.contains(branch)
    }

    /// Branch menu label: name plus default / not on device / deleted on GitHub.
    func branchLabel(_ name: String) -> String {
        var label = name
        if name == defaultBranch { label += " (default)" }
        if !isOnDevice(name) { label += " (not on device)" } else if isDeletedOnGitHub(name) { label += " (deleted on GitHub)" }
        return label
    }

    enum SyncStatus: Equatable {
        /// `pending`: commits waiting on this device to be pushed when the connection returns.
        case offline(pending: Int), syncing, conflicts(Int), branchDeleted, noToken, pending(Int), failed, synced
    }

    var syncStatus: SyncStatus {
        guard let ws = workspace else { return isOnline ? .synced : .offline(pending: 0) }
        if isBusy || ws.isSyncing { return .syncing }
        if !ws.conflicts.isEmpty { return .conflicts(ws.conflicts.count) }
        if ws.isDeletedOnGitHub { return .branchDeleted }
        if !hasToken { return .noToken }
        if !isOnline { return .offline(pending: ws.queue.count) }
        if lastSyncError != nil { return .failed }
        if !ws.queue.isEmpty || !ws.state.existsOnRemote { return .pending(ws.queue.count) }
        return .synced
    }

    #if DEBUG
    /// Fails every request as if the device had no network (debug runs with BREEZY_TEST_OFFLINE=1).
    private struct OfflineTransport: HTTPTransport {
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.notConnectedToInternet) }
    }

    /// Tests have no network monitor; this stands in for it reporting a connection again.
    func setOnlineForTesting(_ online: Bool) { isOnline = online }
    #endif

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
        #if DEBUG
        // For checking the activity banner without a network: BREEZY_DEMO_ACTIVITY="Downloading phase2…|12|41".
        if let demo = ProcessInfo.processInfo.environment["BREEZY_DEMO_ACTIVITY"], !demo.isEmpty {
            let p = demo.split(separator: "|")
            activity = Activity(title: String(p[0]), done: p.count > 1 ? Int(p[1]) ?? 0 : 0, total: p.count > 2 ? Int(p[2]) ?? 0 : 0)
            return
        }
        #endif
        await sync()
    }

    private func openLocal() {
        guard let repo else { return }
        let store = storeFor(repo)
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
            defaults.set(newRepo, forKey: Self.repoKey)
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
        begin("Syncing with GitHub…")
        defer { end() }
        do {
            async let main = client.defaultBranch()
            async let remote = client.branches()
            repoState.defaultBranch = try await main
            repoState.remoteBranches = try await remote.map(\.name)
            if workspace == nil {
                let branch = repoState.lastBranch.flatMap { repoState.remoteBranches.contains($0) ? $0 : nil } ?? repoState.defaultBranch
                activity?.title = "Downloading \(branch)…"
                workspace = try await SiteWorkspace.download(branch, client: client, store: store, progress: progress)
                repoState.lastBranch = branch
            }
            if repoState.websiteURL == nil, let repo {
                let cname = try await client.fileText("src/CNAME", ref: repoState.defaultBranch)
                repoState.websiteURL = Publisher.siteURL(repo: repo, cname: cname)
            }
            pruneDeletedBranches(store)
            try store.saveRepoState(repoState)
            if let ws = workspace {
                switch try await ws.sync(client: client, progress: progress, publishedBranch: repoState.defaultBranch) {
                case .conflicts: showConflicts = true
                case .branchDeleted(hasLocalChanges: false): try await leaveDeletedBranch(ws.branch, client: client, store: store)
                case .branchDeleted(hasLocalChanges: true): showBranchDeleted = true
                case .synced:
                    // A branch created on this device reaches GitHub during ws.sync, after the branch list was
                    // fetched above; record it, or the menus would call it "deleted on GitHub" until the next sync.
                    // Only after .synced: that is when GitHub confirmed the branch exists.
                    if !repoState.remoteBranches.contains(ws.branch) {
                        repoState.remoteBranches.append(ws.branch)
                        try store.saveRepoState(repoState)
                    }
                }
            }
            pullRequests = try await client.openPullRequests()
            lastSyncError = nil
        } catch {
            handle(error)
        }
    }

    /// Removes copies of branches that are gone from GitHub and hold nothing that is not on GitHub
    /// (typically published and deleted on another device). Copies with local changes stay, marked in the menus.
    private func pruneDeletedBranches(_ store: LocalStore) {
        for name in store.cachedBranches()
        where name != currentBranch && !repoState.remoteBranches.contains(name) && !store.hasLocalChanges(name) {
            try? store.removeBranch(name)
        }
    }

    /// The current branch was published or deleted elsewhere and has nothing local: drop it and go to the default branch.
    private func leaveDeletedBranch(_ name: String, client: GitHubClient, store: LocalStore) async throws {
        let main = repoState.defaultBranch
        let next: SiteWorkspace
        if let local = try SiteWorkspace.open(main, store: store) { next = local } else {
            activity = Activity(title: "Downloading \(main)…")
            next = try await SiteWorkspace.download(main, client: client, store: store, progress: progress)
        }
        workspace = next
        try? store.removeBranch(name)
        repoState.lastBranch = main
        try store.saveRepoState(repoState)
        if case .conflicts = try await next.sync(client: client, progress: progress, publishedBranch: repoState.defaultBranch) { showConflicts = true }
        errorMessage = "“\(name)” was published or deleted on another device, so Breezy switched to \(main)."
    }

    // MARK: A branch deleted on GitHub with local changes here

    /// Creates the branch on GitHub again at the commit this copy is based on, then pushes its commits.
    func recreateBranchOnGitHub() async {
        guard let ws = workspace else { return }
        attempt { try ws.recreateOnGitHub() }
        showBranchDeleted = false
        await sync()
    }

    /// Moves the local changes onto a new branch from the default branch's current files.
    func moveEditsToNewBranch(_ name: String) async {
        guard let ws = workspace, let client, let store else { return }
        guard isOnline else { errorMessage = "Moving the edits needs a connection to read \(defaultBranch)."; return }
        begin("Moving changes to \(name)…")
        do {
            let moved = try await ws.moveEdits(toNewBranch: name, from: defaultBranch, client: client, progress: progress)
            workspace = moved
            repoState.lastBranch = name
            try store.saveRepoState(repoState)
            showBranchDeleted = false
            end()
            if !moved.conflicts.isEmpty { showConflicts = true } else { await sync() }
        } catch {
            end()
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
                begin("Downloading \(name)…")
                defer { end() }
                workspace = try await SiteWorkspace.download(name, client: client, store: store, progress: progress)
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
        await online("Opening pull request…") {
            _ = try await client.createPullRequest(title: title, head: head, base: base, body: body)
            pullRequests = try await client.openPullRequests()
        }
    }

    func refreshPullRequest(_ number: Int) async {
        guard let client else { return }
        await online("Checking pull request…") {
            let pr = try await client.pullRequest(number)
            if let i = pullRequests.firstIndex(where: { $0.number == number }) { pullRequests[i] = pr }
        }
    }

    func merge(_ pr: PullRequest, method: MergeMethod, deleteBranch: Bool) async {
        guard let client else { return }
        await online("Merging pull request…") {
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

    private func online(_ title: String, _ op: () async throws -> Void) async {
        guard isOnline else {
            errorMessage = "Pull requests need a connection."
            return
        }
        begin(title)
        defer { end() }
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
        // When only editor state files differ (drafts, cursors), the site does not deploy (paths-ignore): nothing to watch.
        let files = await comparison()?.files
        let changesSite = files.map { !$0.allSatisfy { $0.hasPrefix(SitePath.statesDir) } } ?? true
        begin("Publishing \(branch)…")
        do {
            let result = try await Publisher.publish(branch: branch, into: defaultBranch, title: "Publish \(branch)",
                                                     method: method, deleteBranch: deleteBranch, client: client)
            end()
            if changesSite { watchDeploy(result.mergeCommit) } else { deployStatus = .none }
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
            end()
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

    // MARK: Editor state from older builds

    /// Builds before editor state files kept drafts, the body cursor and the Edit/Draft/Preview mode in settings on
    /// this device. Moves what belongs to this branch's nodes into their editor state (drafts then show in Commit,
    /// to be synced), and removes those keys. Drafts of other branches wait until those branches are opened.
    func importLegacyEditorState(_ ws: SiteWorkspace) {
        for (slug, text) in BodyDraft.legacyDrafts(in: defaults.dictionaryRepresentation(), branch: ws.branch) where ws.nodes[slug] != nil {
            // The key goes only once the draft is safely in the node's state. One that synced from another device
            // meanwhile keeps its text, followed by this one, so neither is lost (Commit then lists the change).
            let existing = ws.editorState(slug).draft?.text
            if existing != text {
                guard (try? ws.setDraft(slug, existing.map { "\($0)\n\n\(text)" } ?? text)) != nil else { continue }
            }
            defaults.removeObject(forKey: BodyDraft.key(branch: ws.branch, slug: slug))
        }
        // The cursor, and the mode it was in: one node's, named in the key.
        if let stored = defaults.string(forKey: "editor.bodySelection") {
            let p = stored.split(separator: "|")
            if p.count == 3, let a = Int(p[1]), let b = Int(p[2]), ws.nodes[String(p[0])] != nil {
                let slug = String(p[0])
                let preview = defaults.bool(forKey: "editor.preview"), draft = defaults.bool(forKey: "editor.draft")
                ws.setEditor(slug) { s in
                    if s.selection == nil { s.selection = [min(a, b), max(a, b)] }
                    if s.mode == nil, preview || draft { s.mode = preview ? .preview : .draft }
                }
                defaults.removeObject(forKey: "editor.bodySelection")
                defaults.removeObject(forKey: "editor.preview")
                defaults.removeObject(forKey: "editor.draft")
            }
        } else {
            // The mode alone names no node: nothing to move it to.
            defaults.removeObject(forKey: "editor.preview")
            defaults.removeObject(forKey: "editor.draft")
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
