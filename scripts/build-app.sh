#!/usr/bin/env bash
# Build build/AppleLook.app (Apple Silicon + Intel) and build/AppleLook.zip.
# Signed ad hoc for now; Developer ID signing and notarization come later.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/AppleLook.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  swift build -c release --product AppleLook --arch "$arch"
done
lipo -create -output "$APP/Contents/MacOS/AppleLook" \
  .build/arm64-apple-macosx/release/AppleLook \
  .build/x86_64-apple-macosx/release/AppleLook

cp Resources/Info.plist "$APP/Contents/"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
xattr -cr "$APP"  # codesign rejects extended attributes
codesign --force --options runtime --entitlements Resources/AppleLook.entitlements --sign - "$APP"

# ditto keeps the bundle intact; Finder unzips it with a double-click
ditto -c -k --keepParent "$APP" build/AppleLook.zip
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/AppleLook")) and build/AppleLook.zip"
