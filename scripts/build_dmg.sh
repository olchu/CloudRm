
#!/usr/bin/env bash
# Builds CloudeRm in Release and packs it into a drag-to-Applications DMG.
#
# Usage:
#   scripts/build_dmg.sh
#       Signed with the Xcode signing identity (Apple Development).
#       Fine for this Mac; Gatekeeper blocks it on other Macs.
#
#   NOTARY_PROFILE=cloudeRm scripts/build_dmg.sh
#       Exports with Developer ID, notarizes and staples the DMG so it opens
#       on any Mac. Needs a Developer ID Application certificate and a
#       notarytool keychain profile, created once with:
#         xcrun notarytool store-credentials cloudeRm --apple-id <apple-id> --team-id 6PEVX4KK6Z
#
# Result: build/CloudeRm-<version>.dmg

set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="CloudeRm"
PROJECT="CloudeRm.xcodeproj"
SCHEME="CloudeRm"
TEAM_ID="6PEVX4KK6Z"
BUILD_DIR="build"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
STAGING_DIR="$BUILD_DIR/dmg"

rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR" "$STAGING_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Archiving $APP_NAME (Release)"
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "$ARCHIVE_PATH" \
    -allowProvisioningUpdates \
    -quiet

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "==> Exporting with Developer ID"
    EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
    cat > "$EXPORT_OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
EOF
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "$EXPORT_DIR" \
        -exportOptionsPlist "$EXPORT_OPTIONS" \
        -allowProvisioningUpdates \
        -quiet
    APP_PATH="$EXPORT_DIR/$APP_NAME.app"
else
    APP_PATH="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
DMG_PATH="$BUILD_DIR/$APP_NAME-$VERSION.dmg"

echo "==> Creating $DMG_PATH"
mkdir -p "$STAGING_DIR"
ditto "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING_DIR" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    -quiet \
    "$DMG_PATH"
rm -rf "$STAGING_DIR"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "==> Signing and notarizing DMG"
    codesign --sign "Developer ID Application" --timestamp "$DMG_PATH"
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG_PATH"
fi

echo "==> Done: $DMG_PATH"
