#!/bin/bash
set -euo pipefail

APP_NAME="SoAgentBar"
SCHEME="SoAgentBar"
BUILD_DIR="build"
DMG_NAME="so-agentbar.dmg"
SIGN_IDENTITY="Developer ID Application: HyeonSeop So (X5NBG68P4L)"
NOTARY_PROFILE="notarytool-profile"

# Clean previous build artifacts
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# 태그에서 버전 추출 (예: v1.2.3 → 1.2.3), 없으면 Info.plist 기본값 사용
VERSION="${GITHUB_REF_NAME:-}"
VERSION="${VERSION#v}"

# Build the app
echo "Building $APP_NAME..."
EXTRA_ARGS=""
if [ -n "$VERSION" ]; then
  EXTRA_ARGS="MARKETING_VERSION=$VERSION CURRENT_PROJECT_VERSION=$VERSION"
fi

xcodebuild -project "$APP_NAME.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  -archivePath "$BUILD_DIR/$APP_NAME.xcarchive" \
  archive \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  CODE_SIGN_STYLE=Manual \
  OTHER_CODE_SIGN_FLAGS="--options runtime" \
  $EXTRA_ARGS

# Export the app from the archive
echo "Exporting app..."
APP_PATH="$BUILD_DIR/$APP_NAME.app"
cp -R "$BUILD_DIR/$APP_NAME.xcarchive/Products/Applications/$APP_NAME.app" "$APP_PATH"

# Codesign the app with hardened runtime
echo "Signing app..."
codesign --force --deep --options runtime \
  --sign "$SIGN_IDENTITY" \
  "$APP_PATH"

# Verify signature
echo "Verifying signature..."
codesign --verify --verbose "$APP_PATH"

# Remove old DMG if exists
rm -f "$DMG_NAME"

# Create DMG
echo "Creating DMG..."
create-dmg \
  --volname "$APP_NAME" \
  --volicon "$APP_NAME/AppIcon.icns" \
  --background "scripts/dmg-background.png" \
  --window-pos 200 120 \
  --window-size 540 380 \
  --icon-size 120 \
  --icon "$APP_NAME.app" 150 170 \
  --app-drop-link 390 170 \
  --hide-extension "$APP_NAME.app" \
  "$DMG_NAME" \
  "$APP_PATH"

# Sign the DMG
echo "Signing DMG..."
codesign --force --sign "$SIGN_IDENTITY" "$DMG_NAME"

# Notarize
echo "Submitting for notarization..."
xcrun notarytool submit "$DMG_NAME" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

# Staple the notarization ticket
echo "Stapling notarization ticket..."
xcrun stapler staple "$DMG_NAME"

echo "Done! Created and notarized $DMG_NAME"
