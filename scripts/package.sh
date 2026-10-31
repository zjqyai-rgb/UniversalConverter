#!/bin/bash
# Builds the app and wraps it in a drag-to-install DMG (plus a zip) in ./build for sharing.
set -euo pipefail
cd "$(dirname "$0")/.."

./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
NAME="UniversalConverter-$VERSION"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

cp -R "build/Universal Converter.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp scripts/HOW-TO-OPEN.txt "$STAGE/How to Open.txt"

rm -f "build/$NAME.dmg" "build/$NAME.zip"
hdiutil create -quiet -volname "Universal Converter" -srcfolder "$STAGE" -ov -format UDZO "build/$NAME.dmg"
ditto -c -k --sequesterRsrc --keepParent "build/Universal Converter.app" "build/$NAME.zip"
echo "Packaged build/$NAME.dmg and build/$NAME.zip"
