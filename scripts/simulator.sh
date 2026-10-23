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
xcrun simctl install "$UDID" "$DD/Build/Products/Debug-iphonesimulator/Breezy.app"
DATA="$(xcrun simctl get_app_container "$UDID" org.taun.Breezy data)"
BRANCH="${BREEZY_BRANCH:-$(git -C "$SITE" branch --show-current)}"

# Write the site's nodes in Breezy's on-device layout (see LocalStore.swift).
python3 - "$DATA/Documents/taun/taun.github.io" "$SITE" "$BRANCH" <<'PY'
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
assets = sorted("/" + os.path.relpath(os.path.join(d, f), f"{site}/src")
                for d, _, fs in os.walk(f"{site}/src/assets") for f in fs if not f.startswith("."))
head = subprocess.check_output(["git", "-C", site, "rev-parse", "HEAD"]).decode().strip()
os.makedirs(f"{root}/branches/{branch}", exist_ok=True)
json.dump({"version": 1, "branch": branch, "base": {"commit": head, "files": files, "assets": assets},
           "existsOnRemote": True, "deleted": [], "conflicts": []}, open(f"{root}/branches/{branch}/state.json", "w"))
json.dump({"defaultBranch": "main", "remoteBranches": sorted({"main", branch}), "lastBranch": branch},
          open(f"{root}/repo.json", "w"))
print(f"Seeded {len(files)} nodes as branch '{branch}'")
PY

for pair in ${BREEZY_DEFAULTS:-}; do
  xcrun simctl spawn "$UDID" defaults write org.taun.Breezy "${pair%%=*}" -string "${pair#*=}"
done
SIMCTL_CHILD_BREEZY_DEMO_ACTIVITY="${BREEZY_DEMO_ACTIVITY:-}" xcrun simctl launch "$UDID" org.taun.Breezy >/dev/null
sleep 4
xcrun simctl io "$UDID" screenshot "$SHOT" >/dev/null
echo "Screenshot: $SHOT"
