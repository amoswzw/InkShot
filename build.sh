#!/usr/bin/env bash
# Build LocalShot.app from LocalShot.swift (no external dependencies).
set -euo pipefail
cd "$(dirname "$0")"

APP="LocalShot.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"

rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

swiftc LocalShot.swift \
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

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>LocalShot</string>
  <key>CFBundleDisplayName</key><string>LocalShot</string>
  <key>CFBundleIdentifier</key><string>local.localshot</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>LocalShot</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc sign so macOS lets it register for Screen Recording permission.
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "Built $APP"
