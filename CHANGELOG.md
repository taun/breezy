# Changelog

All notable changes to Breezy are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Breezy uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **View › Show/Hide Sidebar** (⌃⌘S) on the Mac and with an iPad keyboard.
- **Progress for slow operations:** a banner at the bottom of the window (and of open sheets) says what Breezy is doing — downloading a branch, syncing, publishing, opening or merging a pull request — with a progress bar and file count while files download. The first download shows the same progress full screen.

### Fixed

- **A branch published and deleted on another device** no longer leaves this device stuck on "Sync failed". If the copy here has nothing unpushed, Breezy removes it and switches to `main`. If it has edits or commits, Breezy keeps them and offers to recreate the branch on GitHub (recommended) or to move the changes to a new branch from `main`, with conflicts settled file by file. Other devices' copies of deleted branches without local changes are cleaned up automatically. Copies with local changes are marked "deleted on GitHub" in the branch menus.
- Hiding the node list with no node selected could relaunch into an empty window with no visible way back. With nothing selected, the list is now always shown.

## [1.0.0] - 2026-10-23

First release. Breezy edits the content of the taun.org Eleventy site (`taun/taun.github.io`) on macOS, iOS and iPadOS, through GitHub.

### Added

- **Nodes:** list of all nodes with search (title, slug or tag) and a type filter; create and delete nodes; markers for edited nodes and nodes with problems.
- **Node editor:** title, type (with the types already in use), summary, tags, draft, date with year or day precision, and media fields (video, archive, slides, source) with a picker for files already in `src/assets/`. The body has Edit and Preview modes. Validation warns about unknown link targets, bad slugs and other problems the site build would report.
- **Links:** add, remove and retarget links, with a relation (`led-to`, `worked-at`, `founded`, `part-of`, or any word). Links pointing in from other nodes are listed too.
- **Offline-first:** every branch you open is kept on the device as plain files, visible in the Files app on iPhone and iPad and through Settings › Show Local Files in Finder on the Mac. Breezy opens and edits without a network, for example on a plane.
- **Commits:** edits are saved to disk as you type. Commits made offline wait on the device and are pushed in order, as separate commits, when the connection returns.
- **Sync:** changes made on GitHub to files you did not touch are taken automatically. Files changed in both places are listed as conflicts, resolved one at a time: keep mine, use GitHub's, or edit a merged version. Nothing is pushed until all are settled.
- **Branches:** switch from the toolbar (Mac) or the branch name at the top of the list (iPhone, iPad). Each branch keeps its own uncommitted edits. Branches can be created offline and are created on GitHub at the next sync.
- **Publish:** merges the current branch into `main` through a pull request, then follows the site's rebuild ("Building", "Live", or a link to the failure). **View Website** opens the site in the default browser; its address comes from the site's `CNAME` and can be changed in Settings.
- **Pull requests:** open, check and merge pull requests, with merge, squash or rebase.
- **Sign-in:** a GitHub fine-grained token, entered once and shared with your other devices through iCloud Keychain. Settings shows whether it is syncing.
- **Picks up where you left off:** relaunching restores the branch, the selected node, the screen that was showing, open sheets, drafts, search and filter, and the cursor, even after the app was swiped away.
- **Sync status** in the toolbar: synced, offline, commits waiting to push, conflicts, failed, or no token.

[Unreleased]: https://github.com/taun/breezy/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/taun/breezy/releases/tag/v1.0.0
