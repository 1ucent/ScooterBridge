#!/usr/bin/env bash
#
# build.sh — build ScooterBridge and package it as an unsigned .ipa.
# Run on macOS with Xcode + XcodeGen. On GitHub Actions this is automatic.
#
set -euo pipefail
cd "$(dirname "$0")"

APP="ScooterBridge"

echo "==> Generating Xcode project"
xcodegen generate

echo "==> Building (unsigned)"
xcodebuild -project "${APP}.xcodeproj" \
  -scheme "${APP}" \
  -sdk iphoneos \
  -configuration Release \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build

echo "==> Packaging IPA"
rm -rf Payload "${APP}.ipa"
mkdir -p Payload
cp -R "build/Build/Products/Release-iphoneos/${APP}.app" Payload/
zip -qry "${APP}.ipa" Payload

echo "==> Done: ${APP}.ipa"
ls -lh "${APP}.ipa"
echo
echo "Sideload with AltStore / Sideloadly / TrollStore."
echo "After launching, open the app and note the IP it prints."
