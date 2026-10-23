# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What Breezy is

A macOS / iOS / iPadOS app (SwiftUI, multiplatform) for editing the content of the Eleventy site in `../taun.github.io`. The site's content is Markdown files with YAML front matter in `src/nodes/`. Breezy edits those files through the GitHub API and never runs Eleventy.

**The content model is owned by the site repo.** Read `../taun.github.io/docs/content-model.md` before changing anything that reads or writes node files. `docs/front-matter.schema.json` is the structural schema, and `docs/fixtures/` (with `expected.json`, produced by the site's real parsing code) is the cross-check. If the model needs to change, change the site repo first, regenerate the fixtures there (`node docs/fixtures/check.mjs --write`), then update Breezy to match.

## Decisions made

- **Offline-first:** everything reads and edits a local copy on disk; GitHub is only the sync. Works with no network once a branch has been downloaded (for example on a plane). Edits are saved to disk as they happen.
- **Storage:** plain files in the app's Documents folder (visible in the Files app; on macOS via "Show Local Files in Finder"), synced with the GitHub API, not a git clone (iOS has no git). Every branch opened stays on the device. Branches are first-class: create (offline too), select, commit to, and merge them.
- **Offline commits** queue on the device and are pushed in order as separate GitHub commits.
- **Conflicts** (a file changed both locally and on GitHub since the last sync) are resolved file by file: keep mine, use GitHub's, or edit a merged version. Nothing is pushed while any are open.
- **Merging:** open a pull request and merge it through the API (merge / squash / rebase choice). GitHub reports conflicts; Breezy does not resolve file conflicts in v1.
- **Auth:** a fine-grained personal access token (contents + pull requests read/write, optionally actions read; this repo only), stored as a synchronizable Keychain item so iCloud Keychain delivers it to the user's other devices. On macOS that requires the data protection keychain; both platforms must be signed with the same team. Tokens saved by older builds (device-only) are migrated on first read.
- **State restoration:** the app must relaunch looking exactly as it was left, mid-edit included. Content edits are saved to disk as typed; UI state (selected node per branch, which column the iPhone was showing, open sheet, drafts, search/filter, preview mode, focused field, body cursor on iOS 18 / macOS 15+) uses `@AppStorage`, not `@SceneStorage`: iOS discards scene storage when the app is swiped away or stopped, and restoring must survive that. Add new UI state the same way.
- **Publishing:** merge the current branch into the default branch via a pull request (`Publisher`), then watch the GitHub Actions deploy and offer View Website (opens the default browser; URL from `src/CNAME`, editable in Settings).
- **Preview:** native Markdown rendering in the app. No web view of the deployed site.
- **Assets:** v1 only references existing files in `src/assets/` (choose a path); no uploads.
- **v1 scope:** node list and search; node editor with validation; link and relation editor; branches and pull requests.

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
cd Packages/BreezyKit && swift test --scratch-path /tmp/breezy-build      # core tests
xcodegen generate                                                          # (re)create Breezy.xcodeproj after adding files
xcodebuild -project Breezy.xcodeproj -scheme Breezy -destination 'platform=macOS' -derivedDataPath /tmp/breezy-dd CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Breezy.xcodeproj -scheme Breezy -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/breezy-dd CODE_SIGNING_ALLOWED=NO build
```

Builds and tests fail at code signing when their output is inside `~/Documents` ("resource fork, Finder information, or similar detritus not allowed"), so keep `--scratch-path` / `-derivedDataPath` outside it. To run on a device, open the project in Xcode and set a development team (automatic signing); the Keychain token store needs a signed app. The fixture tests look for the site repo at `../taun.github.io` (sibling of this repo); set `BREEZY_SITE_DIR` to override.
