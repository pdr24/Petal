#!/bin/bash
# Signed + notarized .dmg (PRD §15). Needs a Developer ID Application certificate.
# One-time setup:  xcrun notarytool store-credentials petal-notary \
#                    --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
set -euo pipefail
cd "$(dirname "$0")"
TEAM_ID="${TEAM_ID:?set TEAM_ID=your 10-character team id}"
PROFILE="${NOTARY_PROFILE:-petal-notary}"
xcodegen generate
xcodebuild -project Petal.xcodeproj -scheme Petal -configuration Release -derivedDataPath build \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" clean build
APP=build/Build/Products/Release/Petal.app
codesign --verify --deep --strict --verbose=2 "$APP"
rm -rf dist && mkdir -p dist/dmg && cp -R "$APP" dist/dmg/ && ln -s /Applications dist/dmg/Applications
hdiutil create -volname Petal -srcfolder dist/dmg -ov -format UDZO dist/Petal.dmg
codesign --sign "Developer ID Application" --timestamp dist/Petal.dmg
xcrun notarytool submit dist/Petal.dmg --keychain-profile "$PROFILE" --wait
xcrun stapler staple dist/Petal.dmg
spctl -a -t open --context context:primary-signature -v dist/Petal.dmg
echo "✅ dist/Petal.dmg is signed, notarized and stapled."
