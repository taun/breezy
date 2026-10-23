# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What Breezy is

A macOS / iOS / iPadOS app (SwiftUI, multiplatform) for editing the content of the Eleventy site in `../taun.github.io`. The site's content is Markdown files with YAML front matter in `src/nodes/`. Breezy edits those files through the GitHub API and never runs Eleventy.

**The content model is owned by the site repo.** Read `../taun.github.io/docs/content-model.md` before changing anything that reads or writes node files. `docs/front-matter.schema.json` is the structural schema, and `docs/fixtures/` (with `expected.json`, produced by the site's real parsing code) is the cross-check. If the model needs to change, change the site repo first, regenerate the fixtures there (`node docs/fixtures/check.mjs --write`), then update Breezy to match.

## Decisions made

- **Storage:** the GitHub API, not a local clone (iOS has no git). Branches are first-class: create, select, commit to, and merge them.
- **Merging:** open a pull request and merge it through the API (merge / squash / rebase choice). GitHub reports conflicts; Breezy does not resolve file conflicts in v1.
- **Auth:** a fine-grained personal access token (contents + pull requests, this repo only), stored in the Keychain.
- **Preview:** native Markdown rendering in the app. No web view of the deployed site.
- **Assets:** v1 only references existing files in `src/assets/` (choose a path); no uploads.
- **v1 scope:** node list and search; node editor with validation; link and relation editor; branches and pull requests.

## Structure

- `Packages/BreezyKit`: the platform-free core, tested with Swift Testing. Node file model (`NodeFile`), lossless front matter editing (`FrontMatterText`: line-based, so unknown keys, comments, order and spacing are preserved exactly), date and link semantics (`NodeDate`, `Relations`), and `Validator`. Depends on Yams.
- The app target (not created yet) should be a thin SwiftUI layer over BreezyKit plus a GitHub client. Put anything testable in BreezyKit.

### Rules that matter when editing node files

- Never rewrite a whole front matter block from a decoded model. Change only the keys the user edited, via `NodeFile.set…`, and re-decode.
- Yams must be loaded with `Resolver.default.removing(.timestamp)`: the default makes `date: 2018-09-06` a `Date`, the basic resolver stops typing `true` and `2021`. A test against the site fixtures catches regressions.
- A year-precision date is written as `date: YYYY-01-01` plus `datePrecision: year`.
- Links are directed. A plain slug means `led-to`; use `{ to, rel }` only for other relations. Derived data (incoming links, labels, colors, glyphs) is never written to files.
- The slug is the filename without `.md` and must be unique, lowercase letters, digits and hyphens.

## Commands

```
cd Packages/BreezyKit
swift build
swift test --scratch-path /tmp/breezy-build
```

`swift test` fails at code signing when `.build` is inside `~/Documents` ("resource fork, Finder information, or similar detritus not allowed"), so keep the scratch path outside it. The fixture tests look for the site repo at `../taun.github.io` (sibling of this repo); set `BREEZY_SITE_DIR` to override.
