#!/usr/bin/env bash
# Local fallback for the Developer ID release (CI does this in .github/workflows/release.yml):
# archive (same sandboxed Release build as the App Store one), export signed with
# Developer ID, notarize, staple, zip.
#
# One-time setup — store notarization credentials in the keychain (app-specific password
# from appleid.apple.com):
#   xcrun notarytool store-credentials inkshot-notary \
#     --apple-id YOU@example.com --team-id 9KYF82HZM5 --password APP-SPECIFIC-PASSWORD
#
# Usage: ./release.sh            (version comes from Inkshot-Info.plist)
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Inkshot-Info.plist)"
OUT="dist"
ARCHIVE="$OUT/Inkshot.xcarchive"
ZIP="$OUT/Inkshot-$VERSION.zip"
PROFILE="${NOTARY_PROFILE:-inkshot-notary}"

rm -rf "$OUT"; mkdir -p "$OUT"

xcodebuild -project Inkshot.xcodeproj -scheme Inkshot -configuration Release \
  -archivePath "$ARCHIVE" archive | grep -E 'error:|ARCHIVE'
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT" \
  -exportOptionsPlist packaging/ExportOptions-DeveloperID.plist | grep -E 'error:|EXPORT'

# Notarize the zipped app, then staple the ticket so it opens offline too.
ditto -c -k --keepParent "$OUT/Inkshot.app" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$OUT/Inkshot.app"
rm "$ZIP"; ditto -c -k --keepParent "$OUT/Inkshot.app" "$ZIP"

spctl --assess --type execute --verbose "$OUT/Inkshot.app"
echo "version $VERSION"
echo "sha256  $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo "Upload $ZIP to the GitHub release v$VERSION, then update the cask's version and sha256."
