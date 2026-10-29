#!/bin/sh
# Builds Breezy for the iOS Simulator, installs it, seeds it with a local copy of the site taken from the sibling
# repo (so it opens without a GitHub token or network), launches it, and saves a screenshot.
#
# Usage: scripts/simulator.sh [device-name] [screenshot.png]
#   device-name defaults to the first available iPhone; screenshot defaults to $TMPDIR/breezy-sim.png.
# Env:   BREEZY_SITE_DIR  site repo (default ../taun.github.io)
#        BREEZY_BRANCH    branch name to present the seeded copy as (default: the site repo's current branch)
#        BREEZY_DEFAULTS  extra "key=value" pairs (space-separated) written to the app's preferences before launch,
#                         e.g. 'root.compactColumn=detail editor.focus=history-of-flash|title' to test state restoration
#        BREEZY_DEMO_ACTIVITY  debug builds: show a fake activity banner, "title|done|total" (e.g. 'Downloading main…|12|41')
#        BREEZY_SANDBOX=1 debug builds: use the sandbox repo (BREEZY_SANDBOX_REPO, default taun/taun-io-sandbox) with the
#                         token stored in the Mac Keychain as "taun-io-sandbox-token"; skips seeding, so the app
#                         downloads from GitHub for real. The token goes straight from the Keychain to the app's
#                         environment and is never printed or written to a file.
#        BREEZY_FRESH=1   uninstall first, so the app starts with no local copy and no saved UI state
#        BREEZY_OFFLINE=1 debug builds: every GitHub request fails as with no network (tests offline behavior)
set -eu
cd "$(dirname "$0")/.."
SITE="${BREEZY_SITE_DIR:-../taun.github.io}"
SHOT="${2:-${TMPDIR:-/tmp}/breezy-sim.png}"
DEVICE="${1:-$(xcrun simctl list devices available | grep -m1 -o 'iPhone[^(]*' | sed 's/ *$//')}"
UDID="$(xcrun simctl list devices available | grep -m1 "$DEVICE (" | grep -oE '[0-9A-F-]{36}')"
[ -n "$UDID" ] || { echo "No simulator named '$DEVICE'"; exit 1; }
xcrun simctl boot "$UDID" 2>/dev/null || true

xcodegen generate --quiet
DD="${TMPDIR:-/tmp}/breezy-dd"
xcodebuild -project Breezy.xcodeproj -scheme Breezy -destination "id=$UDID" -derivedDataPath "$DD" \
  CODE_SIGNING_ALLOWED=NO build -quiet
xcrun simctl terminate "$UDID" org.taun.Breezy 2>/dev/null || true
if [ "${BREEZY_FRESH:-0}" = 1 ]; then
  xcrun simctl uninstall "$UDID" org.taun.Breezy 2>/dev/null || true
  # Preferences written with `simctl spawn defaults` live outside the app and survive uninstalling it.
  xcrun simctl spawn "$UDID" defaults delete org.taun.Breezy 2>/dev/null || true
fi
xcrun simctl install "$UDID" "$DD/Build/Products/Debug-iphonesimulator/Breezy.app"
DATA="$(xcrun simctl get_app_container "$UDID" org.taun.Breezy data)"
BRANCH="${BREEZY_BRANCH:-$(git -C "$SITE" branch --show-current)}"

 # Write the site's nodes in Breezy's on-device layout (see LocalStore.swift). Not for sandbox runs, which download.
[ "${BREEZY_SANDBOX:-0}" = 1 ] || python3 - "$DATA/Documents/taun/taun.github.io" "$SITE" "$BRANCH" <<'PY'
import hashlib, json, os, subprocess, sys
root, site, branch = sys.argv[1:4]
os.makedirs(f"{root}/objects", exist_ok=True)
files = {}
for name in sorted(os.listdir(f"{site}/src/nodes")):
    if not name.endswith(".md"):
        continue
    data = open(f"{site}/src/nodes/{name}", "rb").read()
    sha = hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()  # git blob id
    open(f"{root}/objects/{sha}", "wb").write(data)
    files[f"src/nodes/{name}"] = sha
def blob_sha(data): return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()
# Asset shas for all of src/assets; image contents only for the images the nodes show, as a sync would keep them.
asset_shas = {}
for d, _, fs in os.walk(f"{site}/src/assets"):
    for f in fs:
        if not f.startswith("."):
            asset_shas["/" + os.path.relpath(os.path.join(d, f), f"{site}/src")] = blob_sha(open(os.path.join(d, f), "rb").read())
assets = sorted(asset_shas)
import re
for name in os.listdir(f"{site}/src/nodes"):
    if name.endswith(".md"):
        for src in re.findall(r"!\[[^\]]*\]\(([^)\s]+)", open(f"{site}/src/nodes/{name}", encoding="utf-8").read()):
            if src in asset_shas:
                open(f"{root}/objects/{asset_shas[src]}", "wb").write(open(f"{site}/src{src}", "rb").read())
head = subprocess.check_output(["git", "-C", site, "rev-parse", "HEAD"]).decode().strip()
os.makedirs(f"{root}/branches/{branch}", exist_ok=True)
json.dump({"version": 1, "branch": branch, "base": {"commit": head, "files": files, "assets": assets, "assetSHAs": asset_shas},
           "existsOnRemote": True, "deleted": [], "conflicts": []}, open(f"{root}/branches/{branch}/state.json", "w"))
json.dump({"defaultBranch": "main", "remoteBranches": sorted({"main", branch}), "lastBranch": branch},
          open(f"{root}/repo.json", "w"))
print(f"Seeded {len(files)} nodes as branch '{branch}'")
PY

for pair in ${BREEZY_DEFAULTS:-}; do
  xcrun simctl spawn "$UDID" defaults write org.taun.Breezy "${pair%%=*}" -string "${pair#*=}"
done
if [ "${BREEZY_SANDBOX:-0}" = 1 ]; then
  TOKEN="$(security find-generic-password -s taun-io-sandbox-token -w 2>/dev/null)" \
    || { echo "No 'taun-io-sandbox-token' in the Keychain"; exit 1; }
  SIMCTL_CHILD_BREEZY_TEST_TOKEN="$TOKEN" SIMCTL_CHILD_BREEZY_TEST_REPO="${BREEZY_SANDBOX_REPO:-taun/taun-io-sandbox}" \
    SIMCTL_CHILD_BREEZY_TEST_OFFLINE="${BREEZY_OFFLINE:-0}" \
    xcrun simctl launch "$UDID" org.taun.Breezy >/dev/null
  unset TOKEN
  echo "Launched against ${BREEZY_SANDBOX_REPO:-taun/taun-io-sandbox}"
else
  SIMCTL_CHILD_BREEZY_DEMO_ACTIVITY="${BREEZY_DEMO_ACTIVITY:-}" xcrun simctl launch "$UDID" org.taun.Breezy >/dev/null
fi
sleep 4
xcrun simctl io "$UDID" screenshot "$SHOT" >/dev/null
echo "Screenshot: $SHOT"
