# Changelog

All notable changes to Breezy are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Breezy uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed

- **Crash opening Settings on the Mac** (#10): after reverting an edit, opening Settings could quit the app with a SwiftUI environment assertion. Every sheet now receives the app's model explicitly. The cause could not be reproduced without the second half of the crash report, so please confirm.

### Added

- **Editor tabs** (#11): the node editor shows one section at a time — Title, Date, Links, Media, Body — chosen with a segmented control at the top. Each tab has a header naming it and the same grouped look. The Body tab's editor fills the screen (or the Mac window, down to its bottom edge) and scrolls itself, keeping the cursor in view as you type; on iPhone in landscape, the tab and Edit/Preview controls step aside while you type with the on-screen keyboard, and return when it is dismissed (Done in the navigation bar, or drag the text down). The selected tab is restored on relaunch.
- **Symbol tabs on iPhone** (#17): at compact width (iPhone, narrow iPad windows) the editor tabs are symbols, named by the section header below them and read by VoiceOver. The tabs and the Body tab's Edit/Preview control use the large size on iOS 26 and later, so each segment is a full-size touch target.
- **Images in the preview**: an image on a line of its own (`![alt](/assets/…)`) is shown as the picture, taken from the branch's own assets. Breezy downloads the images the nodes show when it downloads or syncs a branch (only those, not the whole assets folder) and keeps them on the device, so the preview shows them offline. A path that is not an asset of the branch shows a "Missing image" placeholder; an image inside a sentence stays inline text. Animated GIFs show their first frame.
- **Easier link relations** (#12): the relation menu is now at the left of each link, with a wider tap area.
- **File issues from Breezy** (#9): Settings › File an Issue… takes a type (Bug or Enhancement), title and description, and an Execute switch that adds the `execute` label so Claude implements it. The token must also cover taun/breezy with Issues read and write; otherwise the error says what to change. The draft is kept if the app is closed.
- **App version in Settings** (#6): the bottom of Settings shows "Breezy 1.0.0 (build N)" in small secondary text.
- **Node states** (#3): each node shows whether it is a **draft** (gold hammer: will not be published), will be **published** (green check: new, changed or edited here) or is **published** and unchanged (blue globe), compared with the published branch (main). The filter menu has a **Show** section (All, Draft, Publish, Published) that combines with type and search; the filter icon fills in while the list is narrowed, and an empty result says why.
- **Deleted nodes stay in the list** (#3), struck through with a red trash icon, until the deletion is published, so they can be opened and undeleted (swipe, long-press or the Undelete button on the node). Deleting a node that others link to says which nodes link to it and offers **Delete Only** (default; the links stay and are flagged) or **Delete and Remove Links**. Nodes linking to a deleted node show an orange link icon and a validation message, and **Show › Broken Links** lists them.
- **Sort by last updated** (#1): the node list can be sorted by Last Updated (new default), Date or Title, with Drafts First (on by default) keeping drafts at the top. "Updated" is the file's latest commit on GitHub, or the time it was edited or committed on this device; rows show it ("updated 2 hours ago") when sorting that way. The dates are fetched once per file and stored for offline use.
- **TestFlight builds** (#4): every app change on `main` is uploaded to TestFlight, and labeling an issue `execute` has Claude implement it and ship a build.
- **App icon** (#5): a golden quill on a fuchsia cloud, with dark and tinted versions on iOS 18 and later, and a Mac version.
- **View › Show/Hide Sidebar** (⌃⌘S) on the Mac and with an iPad keyboard.
- **Delete asks first**, and any uncommitted change, including a deleted node, can be undone from the Commit screen by swiping or long-pressing it.
- **Offline status shows waiting commits:** "Offline · 2 to push" (on iPhone, the offline icon with a count), so it is clear work is saved and will go up when the connection returns.
- **Progress for slow operations:** a banner at the bottom of the window (and of open sheets) says what Breezy is doing — downloading a branch, syncing, publishing, opening or merging a pull request — with a progress bar and file count while files download. The first download shows the same progress full screen.

### Fixed

- **Date defaults to today** (#8): switching a date from Year to Day starts the day picker at today (when the year is the current one) instead of January 1.
- **Body editor:** the cursor no longer jumps back while typing (typing "Hello" gave "ElloH") (#7).
- **iPhone:** tapping a node did nothing on iOS 27, so nodes could not be opened for editing (#2). Tapping a node now always opens it, and going back returns to the list.
- **iPhone:** the Commit button could be hidden in the system's overflow menu when the top bar was full, and on iOS 26 and later it showed only as an unlabeled blue check. It is now a full-width "Commit N Changes" button at the bottom of the node list.
- The suggested commit message called new and deleted nodes "Edit". It now reads like "Add new-talk; Edit bowery; Delete a-theory".
- A branch created in Breezy was briefly labeled "deleted on GitHub" in the branch menus until the next sync.
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
