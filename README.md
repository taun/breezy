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
scripts/test.sh [kit|app]       # BreezyKit tests (incl. a cross-check against the site's parser) and app tests
scripts/build.sh [macos|ios]    # regenerate the project and build without signing
scripts/simulator.sh            # build, install in the iOS Simulator with the site's nodes preloaded, launch, screenshot
```

The scripts put build output in `$TMPDIR`: building inside `~/Documents` fails at code signing ("resource fork, Finder information, or similar detritus not allowed").

`scripts/simulator.sh` needs no token or network. It copies the nodes from the sibling site repo into the app's local storage, so the UI can be checked with real content. `BREEZY_DEMO_ACTIVITY='Downloading main…|12|41'` shows a fake progress banner (debug builds). `BREEZY_DEFAULTS` sets saved UI state before launch, for testing restoration, for example `BREEZY_DEFAULTS='root.selectionByBranch={"phase2":"history-of-flash"}' scripts/simulator.sh`.

## Testing against GitHub (sandbox)

Real flows (download, commit, conflicts, Publish, a branch deleted elsewhere) are tested against `taun/taun-io-sandbox`, a private copy of the site with Pages off, so nothing can reach www.taun.org. Refresh it from the site repo with `git push sandbox phase2:main` (add `--force` if it has test commits).

```
BREEZY_FRESH=1 BREEZY_SANDBOX=1 scripts/simulator.sh "iPhone 15 Pro"
```

`BREEZY_SANDBOX=1` makes a debug build use the sandbox with a fine-grained token stored in the Mac Keychain as `taun-io-sandbox-token` (`security add-generic-password -s taun-io-sandbox-token -a "$USER" -w`). The token goes straight from the Keychain into the app's environment and is kept in memory only. Release builds ignore it. `BREEZY_FRESH=1` starts from a clean install, and `BREEZY_OFFLINE=1` makes every GitHub request fail as if there were no network, to test offline behavior. With the XcodeBuildMCP server available, Claude Code can then tap through the app.

## Pipeline: issues to TestFlight

GitHub Actions (macOS runners, free for this public repo) runs three workflows in `.github/workflows/`:

- **Test:** every branch and pull request: the BreezyKit and app tests, and an iOS build.
- **TestFlight:** when the app changes on `main`, tests, archives the iOS app and uploads it to TestFlight. The build number is the UTC time (`YYYYMMDDHHMM`). It can also be run by hand (Actions › TestFlight › Run workflow), and `scripts/testflight.sh` does the same locally with `ASC_KEY_PATH` pointing at the `.p8` file.
- **Execute issue:** adding the `execute` label to an issue has Claude implement it with the [Claude Code GitHub Action](https://github.com/anthropics/claude-code-action), following `CLAUDE.md`. If the tests pass, the commits are pushed straight to `main` (closing the issue), a TestFlight build is uploaded, and the result is commented on the issue. If anything fails, nothing is pushed, the label is removed, and the comment links to the run; add the label again to retry. Only issues opened **and** labeled by the repo owner run, because the issue text is Claude's instructions. Claude cannot drive the simulator there, so UI changes still need a look on a device. When other people contribute, switch the push job to opening a pull request instead.

One-time setup:

1. In App Store Connect, create the app record for bundle ID `org.taun.Breezy`, and a TestFlight internal testing group with yourself in it.
2. Create an App Store Connect API key (Users and Access › Integrations › Team Keys) with the **Admin** role, so Xcode can create the distribution certificate and profile in the cloud. Note its Key ID and the Issuer ID, and download the `.p8` (once only).
3. In this repo's Settings › Secrets and variables › Actions, add `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` (the whole `.p8` file's text) and `CLAUDE_CODE_OAUTH_TOKEN` (run `claude setup-token` in a terminal and paste what it prints).
4. Create a label named `execute` (Issues › Labels).

Without the App Store Connect secrets the TestFlight step is skipped with a notice; everything else still runs.

## Where things are

- `Packages/BreezyKit`: everything testable. Reading and editing node files without disturbing their formatting, the GitHub client, the on-device storage, sync and publishing.
- `App/`: the SwiftUI app (one target for macOS, iOS and iPadOS).
- `project.yml`: the XcodeGen project spec: version, team, entitlements.
- `CLAUDE.md`: design decisions and rules, written for Claude Code but useful to anyone changing the code.

## Releasing

1. Move the **Unreleased** entries in `CHANGELOG.md` under a new version heading with the date.
2. Set `MARKETING_VERSION` in `project.yml` to that version. For TestFlight or the App Store, also raise `CURRENT_PROJECT_VERSION` (the build number) for every upload.
3. Commit, then tag: `git tag -a vX.Y.Z -m "Breezy X.Y.Z"` and `git push origin main vX.Y.Z`.
