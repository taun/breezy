#!/bin/bash
# Archives the iOS app and uploads it to TestFlight. Signing is done through App Store Connect with an API key, so no
# certificates or profiles need to be installed.
#   ASC_KEY_ID, ASC_ISSUER_ID   the App Store Connect API key (Users and Access › Integrations)
#   ASC_KEY_P8 or ASC_KEY_PATH  the key's .p8 contents (CI) or the path to the .p8 file (locally)
#   BUILD_NUMBER                optional; defaults to the UTC time (YYYYMMDDHHMM), so each upload is higher than the last
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
VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml | head -1)
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
if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "build=$VERSION ($BUILD)" >> "$GITHUB_OUTPUT"; fi
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then echo "Uploaded **Breezy $VERSION ($BUILD)** to TestFlight." >> "$GITHUB_STEP_SUMMARY"; fi
