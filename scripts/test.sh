#!/bin/sh
# Runs the BreezyKit tests (the app's logic, including the cross-check against the site repo's fixtures).
# Build output goes outside ~/Documents: inside it, code signing fails on Finder metadata.
set -eu
cd "$(dirname "$0")/../Packages/BreezyKit"
exec swift test --scratch-path "${TMPDIR:-/tmp}/breezy-build" "$@"
