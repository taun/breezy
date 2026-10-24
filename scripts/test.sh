#!/bin/bash
# Runs the tests. Build output goes outside ~/Documents: inside it, code signing fails on Finder metadata.
#   scripts/test.sh            BreezyKit tests, then the app tests
#   scripts/test.sh kit [...]  BreezyKit tests only (extra args go to swift test, e.g. --filter Workspace)
#   scripts/test.sh app        app tests only (AppModel and navigation, on macOS)
set -euo pipefail
cd "$(dirname "$0")/.."
kit() { (cd Packages/BreezyKit && swift test --scratch-path "${TMPDIR:-/tmp}/breezy-build" "$@"); }
app() {
  xcodegen generate --quiet
  # Show the summary, failures and compile errors; the exit status is xcodebuild's.
  xcodebuild test -project Breezy.xcodeproj -scheme Breezy -destination 'platform=macOS' \
    -derivedDataPath "${TMPDIR:-/tmp}/breezy-dd" CODE_SIGNING_ALLOWED=NO 2>&1 \
    | grep -E 'Test run with|recorded an issue|error:|TEST SUCCEEDED|TEST FAILED'
}
case "${1:-all}" in
  kit) shift; kit "$@" ;;
  app) app ;;
  *) kit; app ;;
esac
