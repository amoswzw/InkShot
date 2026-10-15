#!/usr/bin/env bash
# Build LocalShot.app from LocalShot.swift (no external dependencies).
set -euo pipefail
cd "$(dirname "$0")"

APP="LocalShot.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"

rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

swiftc main.swift LocalShot.swift \
  -o "$MACOS/LocalShot" \
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

cp LocalShot-Info.plist "$APP/Contents/Info.plist"

echo 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc sign so macOS lets it register for Screen Recording permission.
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "Built $APP"
