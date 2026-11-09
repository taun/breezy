#!/bin/bash
# Archives the iOS app and uploads it to TestFlight. Signing is done through App Store Connect with an API key, so no
# certificates or profiles need to be installed.
#   ASC_KEY_ID, ASC_ISSUER_ID   the App Store Connect API key (Users and Access › Integrations)
#   ASC_KEY_P8 or ASC_KEY_PATH  the key's .p8 contents (CI) or the path to the .p8 file (locally)
#   BUILD_NUMBER                optional; defaults to the UTC time (YYYYMMDDHHMM), so each upload is higher than the last
#   FORCE=1                     upload a version already shipped (tagged) again, for example after a failed processing
#   TAG=1|0                     tag the uploaded version vX.Y.Z and push the tag; by default when on main. CI passes 0
#                               and tags in a separate job. A tag marks the version as shipped (scripts/version.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
: "${ASC_KEY_ID:?set ASC_KEY_ID}" "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
OUT="${TMPDIR:-/tmp}/breezy-testflight"
rm -rf "$OUT" && mkdir -p "$OUT"
KEY="${ASC_KEY_PATH:-$OUT/AuthKey.p8}"
if [ -z "${ASC_KEY_PATH:-}" ]; then
  printf '%s\n' "${ASC_KEY_P8:?set ASC_KEY_P8 or ASC_KEY_PATH}" > "$KEY"
  trap 'rm -f "$KEY"' EXIT
fi
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
BUILD="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
# Each version ships once: refuse an app change under a shipped version, and skip one already shipped.
CHECK=$(scripts/version.sh check)
STATUS=$(sed -n 's/^status=//p' <<<"$CHECK")
VERSION=$(sed -n 's/^version=//p' <<<"$CHECK")
if [ "$STATUS" = shipped ] && [ "${FORCE:-}" != 1 ]; then
  echo "Breezy $VERSION is already on TestFlight; nothing to upload (FORCE=1 uploads it again)."
  exit 0
fi
TEAM=$(sed -n 's/^ *DEVELOPMENT_TEAM: *//p' project.yml | head -1)

xcodegen generate --quiet
echo "== Archiving Breezy $VERSION ($BUILD)"
xcodebuild archive -project Breezy.xcodeproj -scheme Breezy -destination 'generic/platform=iOS' \
  -archivePath "$OUT/Breezy.xcarchive" CURRENT_PROJECT_VERSION="$BUILD" "${AUTH[@]}" -quiet

cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>destination</key><string>upload</string>
	<key>teamID</key><string>$TEAM</string>
	<key>signingStyle</key><string>automatic</string>
	<key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
EOF
echo "== Uploading to App Store Connect"
xcodebuild -exportArchive -archivePath "$OUT/Breezy.xcarchive" -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -exportPath "$OUT/export" "${AUTH[@]}"

echo "Uploaded Breezy $VERSION ($BUILD). It appears in TestFlight once App Store Connect has processed it."
# Tag the shipped version, so it is not uploaded again and the next app change must raise it. Only a commit that is on
# GitHub's main: a build of another branch, or of a commit not pushed yet, is a trial. A failed tag push is a warning,
# not a failed upload: the build is on TestFlight.
TAG="${TAG:-$([ "$(git symbolic-ref --short -q HEAD)" = main ] && echo 1 || echo 0)}"
if [ "$TAG" = 1 ] && [ "$STATUS" = new ]; then
  if ! git merge-base --is-ancestor HEAD refs/remotes/origin/main 2>/dev/null; then
    echo "Not tagged: this commit is not on GitHub's main yet. Push it, then: git tag -a v$VERSION -m \"Breezy $VERSION\" && git push origin v$VERSION" >&2
  elif git tag -a "v$VERSION" -m "Breezy $VERSION" && git push origin "v$VERSION"; then
    echo "Tagged v$VERSION."
  else
    msg="Breezy $VERSION was uploaded but not tagged: tag it by hand (git tag -a v$VERSION -m \"Breezy $VERSION\" <commit> && git push origin v$VERSION)."
    if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::warning::$msg"; else echo "$msg" >&2; fi
  fi
fi
if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "build=$VERSION ($BUILD)" >> "$GITHUB_OUTPUT"; fi
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then echo "Uploaded **Breezy $VERSION ($BUILD)** to TestFlight." >> "$GITHUB_STEP_SUMMARY"; fi
