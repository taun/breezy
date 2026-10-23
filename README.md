# Breezy

A Mac, iPhone and iPad app for editing the content of [taun.org](https://www.taun.org), an Eleventy site whose pages are Markdown "nodes" in the [taun/taun.github.io](https://github.com/taun/taun.github.io) repository. Breezy edits those files through GitHub and works offline. See [CHANGELOG.md](CHANGELOG.md) for what it does.

## Setup

You need Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), and the site repository checked out next to this one:

```
taun/
  Breezy/
  taun.github.io/
```

Then:

```
xcodegen generate     # creates Breezy.xcodeproj (not committed; rerun after adding or removing files)
open Breezy.xcodeproj
```

Signing uses the team set in `project.yml`. Keep it there rather than changing it in Xcode, because `xcodegen generate` rewrites the project. Both platforms must use the same team, so the GitHub token syncs between them.

## GitHub token

On first launch Breezy asks for a fine-grained personal access token for `taun/taun.github.io` with:

- **Contents:** read and write
- **Pull requests:** read and write
- **Actions:** read (optional; shows when the website has finished rebuilding after Publish)

It is stored in iCloud Keychain, so your other devices signed in to the same Apple ID get it automatically. Settings shows whether it is syncing.

## Building and testing

```
scripts/test.sh                 # BreezyKit tests, including a cross-check against the site's own parser
scripts/build.sh [macos|ios]    # regenerate the project and build without signing
scripts/simulator.sh            # build, install in the iOS Simulator with the site's nodes preloaded, launch, screenshot
```

The scripts put build output in `$TMPDIR`: building inside `~/Documents` fails at code signing ("resource fork, Finder information, or similar detritus not allowed").

`scripts/simulator.sh` needs no token or network. It copies the nodes from the sibling site repo into the app's local storage, so the UI can be checked with real content. `BREEZY_DEFAULTS` sets saved UI state before launch, for testing restoration, for example `BREEZY_DEFAULTS='root.selectionByBranch={"phase2":"history-of-flash"}' scripts/simulator.sh`.

## Where things are

- `Packages/BreezyKit`: everything testable. Reading and editing node files without disturbing their formatting, the GitHub client, the on-device storage, sync and publishing.
- `App/`: the SwiftUI app (one target for macOS, iOS and iPadOS).
- `project.yml`: the XcodeGen project spec: version, team, entitlements.
- `CLAUDE.md`: design decisions and rules, written for Claude Code but useful to anyone changing the code.

## Releasing

1. Move the **Unreleased** entries in `CHANGELOG.md` under a new version heading with the date.
2. Set `MARKETING_VERSION` in `project.yml` to that version. For TestFlight or the App Store, also raise `CURRENT_PROJECT_VERSION` (the build number) for every upload.
3. Commit, then tag: `git tag -a vX.Y.Z -m "Breezy X.Y.Z"` and `git push origin main vX.Y.Z`.
