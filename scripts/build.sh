#!/bin/sh
# Regenerates the Xcode project and builds the app for macOS and the iOS Simulator, without signing.
# Usage: scripts/build.sh [macos|ios]   (default: both)
set -eu
cd "$(dirname "$0")/.."
xcodegen generate --quiet
DD="${TMPDIR:-/tmp}/breezy-dd"
build() {
  echo "== $1"
  xcodebuild -project Breezy.xcodeproj -scheme Breezy -destination "$2" -derivedDataPath "$DD" \
    CODE_SIGNING_ALLOWED=NO build -quiet
}
case "${1:-all}" in
  macos) build macOS 'platform=macOS' ;;
  ios) build "iOS Simulator" 'generic/platform=iOS Simulator' ;;
  *) build macOS 'platform=macOS'; build "iOS Simulator" 'generic/platform=iOS Simulator' ;;
esac
echo "Built into $DD/Build/Products"
