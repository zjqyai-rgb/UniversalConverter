#!/bin/bash
# Builds a universal (Apple Silicon + Intel) "Universal Converter.app" and the uconv CLI into ./build,
# using only the Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN=$(swift build -c release "${ARCHS[@]}" --show-bin-path)

APP="build/Universal Converter.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/UniversalConverter" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
[ -f Resources/AppIcon.icns ] || swift scripts/make_icon.swift Resources/AppIcon.icns
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp "$BIN/uconv" build/uconv
codesign --force --deep --sign - "$APP"
echo "Built $APP"
