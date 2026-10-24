#!/bin/bash
# Renders the app icon set from Breezy-icon.svg (design "1c", golden quill on a fuchsia cloud, from Claude Design).
# Needs rsvg-convert (brew install librsvg). Writes App/Assets.xcassets/AppIcon.appiconset.
set -euo pipefail
cd "$(dirname "$0")"
OUT=../../App/Assets.xcassets/AppIcon.appiconset
SRC=Breezy-icon.svg
TMP=$(mktemp -d)
art=$(sed -n '/<g transform="translate(-235.7/,$p' "$SRC" | sed '$d')   # the cloud and quill group, without the background
svg() { printf '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">%s</svg>\n' "$1"; }

# iOS: light (as designed), dark (transparent; iOS supplies the dark backdrop), tinted (grayscale; iOS applies the tint).
rsvg-convert -w 1024 -h 1024 "$SRC" -o "$OUT/icon-ios-light.png"
svg "$art" > "$TMP/dark.svg"
rsvg-convert -w 1024 -h 1024 "$TMP/dark.svg" -o "$OUT/icon-ios-dark.png"
tinted=$(echo "$art" | sed -e 's/#E8329E/#D9D9D9/; s/#CC1F86/#B3B3B3/; s/#AE1270/#8C8C8C/; s/#E2A82E/#FFFFFF/; s/#B87A14/#F2F2F2/')
svg "$tinted" > "$TMP/tinted.svg"
rsvg-convert -w 1024 -h 1024 "$TMP/tinted.svg" -o "$OUT/icon-ios-tinted.png"

# macOS: the art on a white rounded tile (824 px on the 1024 grid) with a soft shadow; macOS does not mask icons.
svg "<defs><filter id=\"s\" x=\"-20%\" y=\"-20%\" width=\"140%\" height=\"140%\"><feDropShadow dx=\"0\" dy=\"10\" stdDeviation=\"12\" flood-color=\"#000\" flood-opacity=\"0.3\"/></filter><clipPath id=\"c\"><rect x=\"100\" y=\"100\" width=\"824\" height=\"824\" rx=\"185\"/></clipPath></defs><rect x=\"100\" y=\"100\" width=\"824\" height=\"824\" rx=\"185\" fill=\"#FFFFFF\" filter=\"url(#s)\"/><g clip-path=\"url(#c)\"><g transform=\"translate(100 100) scale(0.8047)\">$art</g></g>" > "$TMP/mac.svg"
for px in 16 32 64 128 256 512 1024; do rsvg-convert -w $px -h $px "$TMP/mac.svg" -o "$OUT/icon-mac-$px.png"; done
rm -rf "$TMP"
