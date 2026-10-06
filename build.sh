#!/bin/bash
# Builds Petal.app locally (ad-hoc signed). Requires Xcode 15+ and XcodeGen.
set -euo pipefail
cd "$(dirname "$0")"
command -v xcodegen >/dev/null || { echo "Install XcodeGen first:  brew install xcodegen"; exit 1; }
xcodegen generate
xcodebuild -project Petal.xcodeproj -scheme Petal -configuration Release \
  -derivedDataPath build CODE_SIGN_IDENTITY="-" build | xcpretty 2>/dev/null || \
xcodebuild -project Petal.xcodeproj -scheme Petal -configuration Release \
  -derivedDataPath build CODE_SIGN_IDENTITY="-" build
echo ""
echo "✅ Built: $(pwd)/build/Build/Products/Release/Petal.app"
echo "   Run tests with: xcodebuild test -project Petal.xcodeproj -scheme Petal"
