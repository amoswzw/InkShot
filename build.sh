#!/usr/bin/env bash
# Build Inkshot.app from Inkshot.swift (no external dependencies).
set -euo pipefail
cd "$(dirname "$0")"

APP="Inkshot.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"

rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

# Match Info.plist's LSMinimumSystemVersion (14.0) so the binary's min OS is
# honest. ScreenCaptureKit capture needs macOS 14. Target the host arch so the
# build stays native on both Apple Silicon and Intel.
TARGET="$(uname -m)-apple-macosx14.0"

swiftc main.swift Inkshot.swift \
  -o "$MACOS/Inkshot" \
  -target "$TARGET" \
  -swift-version 5 \
  -framework Cocoa \
  -framework CoreImage \
  -framework Carbon \
  -O

# App icon (regenerate from make_icon.swift if missing).
if [ ! -f AppIcon.icns ]; then
        swift make_icon.swift
        iconutil -c icns AppIcon.iconset -o AppIcon.icns
fi
cp AppIcon.icns "$RES/AppIcon.icns"

cp Inkshot-Info.plist "$APP/Contents/Info.plist"

echo 'APPL????' > "$APP/Contents/PkgInfo"

# Sign with an Apple Development identity when one is installed: privacy grants
# (Screen Recording) are keyed to the signing identity, so they survive rebuilds.
# An ad-hoc signature has no stable identity, so macOS re-asks after every build
# and can attribute the request to a stale app.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)"
codesign --force --deep --sign "${IDENTITY:--}" "$APP" 2>/dev/null \
  || codesign --force --deep --sign - "$APP" 2>/dev/null || true
echo "Signed with: ${IDENTITY:-ad-hoc}"

echo "Built $APP"
