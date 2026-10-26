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

# App icon from a 1024x1024 Resources/AppIcon.png, if there is one
if [[ -f Resources/AppIcon.png ]]; then
  ICONSET=build/AppIcon.iconset
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  plutil -insert CFBundleIconFile -string AppIcon "$APP/Contents/Info.plist"
fi
plutil -lint "$APP/Contents/Info.plist" >/dev/null
xattr -cr "$APP"  # codesign rejects extended attributes
# Same certificate every build, so macOS keeps users' Calendar permission across updates
IDENTITY="AppleLook Self-Signed"
if ! security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  echo "warning: no \"$IDENTITY\" certificate (run scripts/make-signing-cert.sh); signing ad hoc," >&2
  echo "         so users will be asked for Calendar access again after updating." >&2
  IDENTITY="-"
fi
codesign --force --options runtime --entitlements Resources/AppleLook.entitlements --sign "$IDENTITY" "$APP"

# ditto keeps the bundle intact; Finder unzips it with a double-click
ditto -c -k --keepParent "$APP" build/AppleLook.zip
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/AppleLook")) and build/AppleLook.zip"
