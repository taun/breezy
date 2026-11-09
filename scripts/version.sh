#!/bin/bash
# Breezy's version, MARKETING_VERSION in project.yml. Each version ships to TestFlight once: the TestFlight workflow
# uploads it and then tags it vX.Y.Z, so builds can be told apart by version rather than by 12-digit build numbers.
#   scripts/version.sh          print the version
#   scripts/version.sh check    is this commit's build new, already shipped, or a changed build under a shipped version?
#                               (scripts/testflight.sh runs it, uploads only a new version, and then tags it.)
#                               Prints status=new|shipped and version=X.Y.Z (also to $GITHUB_OUTPUT in Actions); fails
#                               when the build changed but the version was not raised, or the version went down.
set -euo pipefail
cd "$(dirname "$0")/.."
# Everything a TestFlight build is made from. testflight.yml's push paths list the same (YAML cannot share it).
BUILD_INPUTS=(App Packages project.yml scripts/testflight.sh)

version_of() { sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' | head -1; }
version=$(version_of < project.yml)
[ -n "$version" ] || { echo "version.sh: no MARKETING_VERSION in project.yml" >&2; exit 1; }
[ "${1:-}" = "check" ] || { echo "$version"; exit 0; }

fail() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::error::$1"; else echo "version.sh: $1" >&2; fi
  exit 1
}
report() {
  echo "status=$1"; echo "version=$version"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then printf 'status=%s\nversion=%s\n' "$1" "$version" >> "$GITHUB_OUTPUT"; fi
}
raise="Raise MARKETING_VERSION in project.yml (minor when anything user-visible is new, patch for fixes only) and move the Unreleased entries in CHANGELOG.md under it."

# (Package.resolved is left out: the test and build tools rewrite it.)
if [ -n "$(git status --porcelain -- "${BUILD_INPUTS[@]}" ':!Packages/BreezyKit/Package.resolved')" ]; then
  fail "There are uncommitted or untracked changes to the app; commit them first, so the check sees what will be pushed."
fi
# The shipped versions and main as GitHub has them; offline, what is here.
git fetch -q --tags origin main 2>/dev/null || true
# Never lower than the last version shipped, even one restored by a revert (it would be skipped as already shipped).
latest=$(git tag -l 'v[0-9]*' | sed 's/^v//' | sort -V | tail -1)
if [ -n "$latest" ] && [ "$(printf '%s\n%s\n' "$latest" "$version" | sort -V | tail -1)" != "$version" ]; then
  fail "Version $version is lower than the last one shipped, $latest. $raise"
fi
if git rev-parse -q --verify "refs/tags/v$version" >/dev/null; then
  if git diff --quiet "v$version" HEAD -- "${BUILD_INPUTS[@]}"; then
    echo "Breezy $version is already on TestFlight (tag v$version) and the app has not changed since."
    report shipped
    exit 0
  fi
  fail "The app changed since Breezy $version shipped (tag v$version), but the version is still $version. $raise"
fi
# Main may hold a version not tagged yet (its upload still running, or failed): a different app needs a higher one.
upstream=refs/remotes/origin/main
# (A commit main already contains, such as an older push whose run is still going, has nothing to compare.)
if git rev-parse -q --verify "$upstream" >/dev/null && ! git merge-base --is-ancestor HEAD "$upstream" &&
  ! git diff --quiet "$upstream" HEAD -- "${BUILD_INPUTS[@]}"; then
  on_main=$(git show "$upstream:project.yml" | version_of)
  if [ "$(printf '%s\n%s\n' "$on_main" "$version" | sort -V | tail -1)" != "$version" ] || [ "$on_main" = "$version" ]; then
    fail "main is at $on_main with a different app, so this needs a version above it, not $version. $raise"
  fi
fi
echo "Breezy $version is new${latest:+ (last shipped: $latest)}."
report new
