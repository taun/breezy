# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What Breezy is

A macOS / iOS / iPadOS app (SwiftUI, multiplatform) for editing the content of the Eleventy site in `../taun.github.io`. The site's content is Markdown files with YAML front matter in `src/nodes/`. Breezy edits those files through the GitHub API and never runs Eleventy.

**The content model is owned by the site repo.** Read `../taun.github.io/docs/content-model.md` before changing anything that reads or writes node files. `docs/front-matter.schema.json` is the structural schema, and `docs/fixtures/` (with `expected.json`, produced by the site's real parsing code) is the cross-check. If the model needs to change, change the site repo first, regenerate the fixtures there (`node docs/fixtures/check.mjs --write`), then update Breezy to match.

## Decisions made

- **Offline-first:** everything reads and edits a local copy on disk; GitHub is only the sync. Works with no network once a branch has been downloaded (for example on a plane). Edits are saved to disk as they happen.
- **Storage:** plain files in the app's Documents folder (visible in the Files app; on macOS via "Show Local Files in Finder"), synced with the GitHub API, not a git clone (iOS has no git). Every branch opened stays on the device. Branches are first-class: create (offline too), select, commit to, and merge them.
- **Offline commits** queue on the device and are pushed in order as separate GitHub commits.
- **Branches deleted on GitHub** (typically published with delete on another device): `GitHubClient.headSHA` throws `branchNotFound`, and `sync` returns `.branchDeleted(hasLocalChanges:)`. Without local changes the app drops the copy and switches to the default branch. With them it keeps everything and offers `recreateOnGitHub` (recreate at the copy's base commit, then push) or `moveEdits(toNewBranch:from:client:)` (new local branch from the default branch, edits carried over, files changed on both sides become conflicts). Clean copies of branches missing from GitHub are pruned on each sync. Never delete a copy that `LocalStore.hasLocalChanges` reports.
- **Conflicts** (a file changed both locally and on GitHub since the last sync) are resolved file by file: keep mine, use GitHub's, or edit a merged version. Nothing is pushed while any are open.
- **Merging:** open a pull request and merge it through the API (merge / squash / rebase choice). Conflicts *inside a pull request* are reported by GitHub and resolved there; Breezy only resolves conflicts between local edits and GitHub during sync (see Conflicts above).
- **Auth:** a fine-grained personal access token (contents + pull requests read/write, optionally actions read; this repo only), stored as a synchronizable Keychain item so iCloud Keychain delivers it to the user's other devices. On macOS that requires the data protection keychain; both platforms must be signed with the same team. Tokens saved by older builds (device-only) are migrated on first read.
- **State restoration:** the app must relaunch looking exactly as it was left, mid-edit included. Content edits are saved to disk as typed; UI state (selected node per branch, which column the iPhone was showing, open sheet, drafts, search/filter, preview mode, focused field, body cursor on iOS 18 / macOS 15+) uses `@AppStorage`, not `@SceneStorage`: iOS discards scene storage when the app is swiped away or stopped, and restoring must survive that. Add new UI state the same way.
- **Publishing:** merge the current branch into the default branch via a pull request (`Publisher`), then watch the GitHub Actions deploy and offer View Website (opens the default browser; URL from `src/CNAME`, editable in Settings).
- **Preview:** native Markdown rendering in the app. No web view of the deployed site.
- **Assets:** v1 only references existing files in `src/assets/` (choose a path); no uploads.
- **iPhone / iPad layout:** the split view collapses on iPhone, and toolbar items attached to the split view itself are not shown there. iOS controls live on the node list's bar (branch as a title menu, sync status, Commit, a More menu); the Mac keeps them in the window toolbar. Sheets get a minimum size only on macOS (`macSheetFrame`).

## Structure

- `Packages/BreezyKit`: the platform-free core, tested with Swift Testing. Put anything testable here.
  - Node files: `NodeFile`, lossless front matter editing (`FrontMatterText`: line-based, so unknown keys, comments, order and spacing are preserved exactly), `NodeDate`, `Relations`, `Validator`. Depends on Yams.
  - `GitHub/`: `GitHubClient` (branches, git data API reads, one-commit-per-save via blobs/trees/commits/ref update with a moved-branch check, pull requests and merge), `HTTPTransport` (the network seam; tests use `MockTransport` with routes keyed `"METHOD /path?query"`), `TokenStore` (Keychain, or in-memory for tests).
  - `Storage/`: `LocalStore`, the on-device copy (layout documented at the top of `LocalStore.swift`: `objects/<blob-sha>`, `branches/<branch>/{state.json,queue.json,working/}`, `repo.json`), its Codable models, and `GitBlob` (git blob IDs computed locally, so changes are detected without the network). Writes are atomic; `state.json` is written after the files it refers to.
  - `Workspace/SiteWorkspace`: one branch, offline-first. Displayed nodes = base snapshot + queued commits + working edits. Edits persist immediately; `commit` queues; `sync(client:)` creates the branch on GitHub if needed, adopts GitHub's newer files that were not touched locally, records conflicts for those that were (`resolve`), then pushes the queue one commit at a time with the moved-branch check. `branchOff` creates a branch locally. `@MainActor @Observable`.
- `App/`: the SwiftUI app, one multiplatform target (macOS, iOS, iPadOS). `AppModel` owns settings, the local store, the workspace, branches and PRs, watches the network (`NWPathMonitor`) and syncs when it comes back; network errors mean "offline", not an alert; views are `RootView` (split view + toolbar), `NodeListView` (search, type filter, new/delete), `NodeEditorView` (fields, date, media with asset picker, body edit/preview), `LinkEditorView`, `BranchesView` (switch/create/delete branches, open/merge PRs), `CommitView`, `ConflictsView` (+ `MergeEditor`), `SettingsView`, `MarkdownPreview`, and `SyncStatusButton` in the toolbar.
- Signing: `project.yml` sets the team and per-platform entitlements (`App/Breezy-*.entitlements`); the keychain access group gives the Mac app an identity in the data protection keychain, without which the token cannot sync through iCloud.
- `project.yml` is the XcodeGen spec; `Breezy.xcodeproj` is generated and not committed.

### Rules that matter when editing node files

- Never rewrite a whole front matter block from a decoded model. Change only the keys the user edited, via `NodeFile.set…`, and re-decode.
- Yams must be loaded with `Resolver.default.removing(.timestamp)`: the default makes `date: 2018-09-06` a `Date`, the basic resolver stops typing `true` and `2021`. A test against the site fixtures catches regressions.
- A year-precision date is written as `date: YYYY-01-01` plus `datePrecision: year`.
- Links are directed. A plain slug means `led-to`; use `{ to, rel }` only for other relations. Derived data (incoming links, labels, colors, glyphs) is never written to files.
- The slug is the filename without `.md` and must be unique, lowercase letters, digits and hyphens.

## Commands

```
scripts/test.sh [kit|app]       # BreezyKit tests (swift test; `kit --filter X` passes args) and the app tests (macOS)
scripts/build.sh [macos|ios]    # xcodegen generate + unsigned builds for macOS and/or the iOS Simulator
scripts/simulator.sh [device]   # build, install in the simulator seeded with the site's nodes, launch, screenshot
```

- Build output must stay outside `~/Documents` (code signing fails on Finder metadata there); the scripts use `$TMPDIR`.
- Run `xcodegen generate` (the build scripts do) after adding or removing files; `Breezy.xcodeproj` is not committed. The team is set in `project.yml`, so do not set it in Xcode.
- The fixture tests look for the site repo at `../taun.github.io`; set `BREEZY_SITE_DIR` to override.
- **Checking UI changes:** `scripts/simulator.sh` needs no token: it writes the site's nodes into the app's local store, so the app opens offline with real content, and saves a screenshot to read. `BREEZY_DEFAULTS='key=value ...'` presets `@AppStorage` keys to test restoration. Interactive flows: when the XcodeBuildMCP server is available (it is configured at user scope on the main dev Mac with the simulator, ui-automation and macos workflows), use `snapshot_ui` to read the screen and `tap` / `type_text` / `swipe` to drive it. Set its session defaults first (project, scheme, simulator, and a `derivedDataPath` outside `~/Documents`).
- **Real GitHub flows:** `BREEZY_SANDBOX=1 scripts/simulator.sh` runs a debug build against the sandbox repo `taun/taun-io-sandbox` with the Keychain token `taun-io-sandbox-token` (see README). Never paste or print the token: read it with `security find-generic-password -s taun-io-sandbox-token -w` inside a command that passes it through an environment variable. Never point tests at `taun/taun.github.io`.
- XcodeBuildMCP's `screenshot` can return a stale frame; take screenshots with `xcrun simctl io <udid> screenshot` and use `snapshot_ui` for the element tree.
- Only iOS 17.2 simulators are installed here; behavior on newer iOS (e.g. search bar placement) can differ.

## Conventions

- Add a line under **Unreleased** in `CHANGELOG.md` for every user-visible change. Releasing is described in `README.md` (version in `project.yml`, then an annotated `vX.Y.Z` tag).
- New UI state and drafts get `@AppStorage` keys (see State restoration). New features must work offline, or degrade clearly when offline (see Offline-first).
- Keep logic in BreezyKit with tests; network behavior is tested through `MockTransport` (in the `BreezyKitTestSupport` library), never against GitHub.
- App-layer logic (`AppModel`, navigation policies such as `CompactNavigation`) is tested in `AppTests/` (target `BreezyTests`, macOS). It compiles the app sources directly rather than hosting the app, and `Harness` wires `AppModel` to a fake GitHub, a temporary `LocalStore` and its own `UserDefaults`. Every bug fixed in the app gets a regression test there when the logic can be expressed without a view; keep view code thin so it can.
