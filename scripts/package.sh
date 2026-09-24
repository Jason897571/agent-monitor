#!/usr/bin/env bash
# Build a universal, ad-hoc signed Agent Monitor.app and wrap it in a drag-to-install DMG.
#
#   scripts/package.sh [version]        →  dist/Agent Monitor.app
#                                           dist/AgentMonitor-<version>.dmg
#
# Two things about what this produces:
#
# - Universal without Xcode. `swift build --arch arm64 --arch x86_64` needs xcbuild,
#   which only ships with Xcode, so each architecture is built on its own and merged
#   with `lipo`.
#
# - Ad-hoc signed, not Developer ID. There is no signing identity on the build machine.
#   The app runs as-is on the Mac that built it; on another Mac, Gatekeeper blocks a
#   downloaded copy until the user allows it in System Settings → Privacy & Security, or
#   runs `xattr -dr com.apple.quarantine "/Applications/Agent Monitor.app"`. Shipping it
#   without that friction needs a paid Developer ID certificate plus notarization.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-0.1.0}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
NAME="Agent Monitor"
BUNDLE_ID="io.github.jason897571.agent-monitor"
EXECUTABLE="agent-monitor"
DIST="dist"
APP="$DIST/$NAME.app"
DMG="$DIST/AgentMonitor-$VERSION.dmg"

echo "==> building $VERSION ($BUILD) for arm64 and x86_64"
for arch in arm64 x86_64; do
    swift build -c release --triple "$arch-apple-macosx14.0" --product "$EXECUTABLE" >/dev/null
done

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create \
    ".build/arm64-apple-macosx/release/$EXECUTABLE" \
    ".build/x86_64-apple-macosx/release/$EXECUTABLE" \
    -output "$APP/Contents/MacOS/$EXECUTABLE"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>          <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>                <string>$NAME</string>
    <key>CFBundleDisplayName</key>         <string>$NAME</string>
    <key>CFBundleExecutable</key>          <string>$EXECUTABLE</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleShortVersionString</key>  <string>$VERSION</string>
    <key>CFBundleVersion</key>             <string>$BUILD</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key>      <string>14.0</string>
    <!-- No Dock icon, no menu bar of its own; the pet and a menu-bar item are the UI. -->
    <key>LSUIElement</key>                 <true/>
    <key>NSHighResolutionCapable</key>     <true/>
    <key>NSHumanReadableCopyright</key>    <string>Open source — see github.com/Jason897571/agent-monitor</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> signing (ad-hoc)"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict "$APP"

echo "==> building $DMG"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "$NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG"

echo
echo "  $(lipo -archs "$APP/Contents/MacOS/$EXECUTABLE")   $(du -sh "$APP" | cut -f1)   $APP"
echo "  $(du -sh "$DMG" | cut -f1)   $DMG"
