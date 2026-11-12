# Claude Code skills

Project skills for Swift, SwiftUI and Apple platform work. Claude Code loads each folder's `SKILL.md` description at startup and reads the rest only when a task calls for it.

## Apple (exported from Xcode)

Written by Apple and shipped inside Xcode 27. Exported from Xcode 27.2 (27B52) on 2026-11-09. They have no license file and this repo is public, so they are listed in `.gitignore` and live only on the dev Mac: re-export them on another machine. Claude in CI (the Execute issue workflow, Xcode 26.x) does not have them; it still gets the community skills below.

Breezy targets iOS 17 / macOS 14 and CI builds with the iOS 26 SDK, so advice from `swiftui-whats-new-27` or `app-intents-whats-new-27` needs an `if #available` guard (see CLAUDE.md).

| Skill | Covers |
|---|---|
| `swiftui-specialist` | SwiftUI best practices: `@Observable`, `ForEach`/`List` identity, environment, localization, soft-deprecated APIs |
| `swiftui-whats-new-27` | SwiftUI APIs new in the 27 releases |
| `app-intents-specialist` | App Intents best practices (Siri, Shortcuts, Spotlight) |
| `app-intents-whats-new-27` | App Intents APIs new in the 26 and 27 releases |
| `app-resizability` | Layouts that adapt to resizable windows, iPad multitasking, iPhone Duo |
| `modernize-tests` | Moving tests to Swift Testing |
| `xctrace` | Profiling with Instruments from the command line |
| `audit-xcode-security-settings` | Hardening compiler warnings, analyzer and security build settings |

Refresh after an Xcode update (the export writes every Apple skill; keep only the ones above):

```sh
xcrun agent skills export --output-dir /tmp/xcode-skills
for s in swiftui-specialist swiftui-whats-new-27 app-intents-specialist app-intents-whats-new-27 \
         app-resizability modernize-tests xctrace audit-xcode-security-settings; do
  rm -rf .claude/skills/$s && cp -R /tmp/xcode-skills/$s .claude/skills/
done
```

## Community (MIT, pinned)

| Skill | Source | Commit |
|---|---|---|
| `swiftui-expert-skill` | [AvdLee/SwiftUI-Agent-Skill](https://github.com/AvdLee/SwiftUI-Agent-Skill) `skills/swiftui-expert-skill` | `62bd760f005093d1e2e4de5db156e456a5f96400` (2026-11-06) |
| `swift-concurrency` | [AvdLee/Swift-Concurrency-Agent-Skill](https://github.com/AvdLee/Swift-Concurrency-Agent-Skill) `skills/swift-concurrency` | `3b1580d8398e0b5408b3bf0bada0e941a1cfc642` (2026-11-06) |
| `swift-testing-expert` | [AvdLee/Swift-Testing-Agent-Skill](https://github.com/AvdLee/Swift-Testing-Agent-Skill) `swift-testing-expert` | `798e9b1a2bcac164d4f0c781908199e754f0bab6` (2026-04-22) |

Each folder holds its upstream `LICENSE`. To update one, clone the repo, read the diff since the pinned commit, copy the skill folder over this one (keeping `LICENSE`), and update the commit above.

`swiftui-expert-skill/scripts/` holds Python helpers that record and analyze Instruments traces; they only run `xcrun xctrace`.

## Overlaps

Apple's skills and the community ones cover some of the same ground. Apple's are authoritative for the APIs they cover; the community skills fill what Apple's leave out (navigation, layout, accessibility, macOS specifics, concurrency). Use one community skill per topic: adding a second SwiftUI skill (such as twostraws' `swiftui-pro`) makes Claude pick between them inconsistently.

More skills to consider later: [twostraws/Swift-Agent-Skills](https://github.com/twostraws/swift-agent-skills) is a curated directory.
