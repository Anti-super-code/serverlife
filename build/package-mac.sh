#!/bin/bash
# Builds the macOS download that goes on the website: a self-contained
# Serverlife.app (Apple Silicon only) wrapped in a drag-to-Applications .dmg —
# the macOS counterpart of package.ps1. Ad-hoc signed by default; Developer ID
# signed + notarised when the two env vars near the bottom are set.
#
#   bash build/package-mac.sh
#   bash build/package-mac.sh --skip-tests   # only when you already ran them
#
# Output in dist-mac/ (not committed):
#   Serverlife.app                          the staged bundle
#   Serverlife-<version>-mac-arm64.dmg      the website download, + .sha256
#   serverlife-cli                          the headless binary
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MACOS_DIR="$REPO/macos"
DIST="$REPO/dist-mac"

SKIP_TESTS=0
for arg in "$@"; do
    [ "$arg" = "--skip-tests" ] && SKIP_TESTS=1
done

# Kept in step with the Windows build's <Version> in src/Serverlife/Serverlife.csproj.
VERSION="0.1.0"
APP="$DIST/Serverlife.app"

echo "Packaging Serverlife $VERSION (macOS, arm64)"

cd "$MACOS_DIR"

if [ "$SKIP_TESTS" -eq 0 ]; then
    echo "-> tests"
    swift test
fi

echo "-> build (release)"
swift build -c release --product Serverlife
swift build -c release --product serverlife-cli

RELEASE_DIR="$MACOS_DIR/.build/release"

echo "-> assemble app bundle"
rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$RELEASE_DIR/Serverlife" "$APP/Contents/MacOS/Serverlife"
cp "$RELEASE_DIR/serverlife-cli" "$DIST/serverlife-cli"

# SwiftPM's generated Bundle.module accessor resolves its resource bundle against
# Bundle.main.bundleURL, which for a packaged app is the .app's own root — outside
# Contents, a location codesign won't seal (same reasoning as Photokompressor's
# package-mac.sh). So the packaged app carries its fonts in the ordinary
# Contents/Resources instead, and Theme.swift's FontRegistration checks Bundle.main
# first for exactly this reason.
if [ -d "$RELEASE_DIR/Serverlife_Serverlife.bundle/Fonts" ]; then
    cp -R "$RELEASE_DIR/Serverlife_Serverlife.bundle/Fonts" "$APP/Contents/Resources/Fonts"
fi

echo "-> icon"
ICONSET="$DIST/Serverlife.iconset"
mkdir -p "$ICONSET"
SRC="$MACOS_DIR/Resources/AppIcon/source-icon-1024.png"
sips -z 16 16     "$SRC" --out "$ICONSET/icon_16x16.png"      >/dev/null
sips -z 32 32     "$SRC" --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
sips -z 32 32     "$SRC" --out "$ICONSET/icon_32x32.png"      >/dev/null
sips -z 64 64     "$SRC" --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
sips -z 128 128   "$SRC" --out "$ICONSET/icon_128x128.png"    >/dev/null
sips -z 256 256   "$SRC" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$SRC" --out "$ICONSET/icon_256x256.png"    >/dev/null
sips -z 512 512   "$SRC" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$SRC" --out "$ICONSET/icon_512x512.png"    >/dev/null
cp "$SRC"                                "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Serverlife.icns"
rm -rf "$ICONSET"

sed "s/__VERSION__/$VERSION/g" "$MACOS_DIR/Resources/Info.plist.template" > "$APP/Contents/Info.plist"

echo "-> licences and read-me"
cp "$REPO/LICENSE" "$DIST/LICENSE"
cp "$REPO/licenses/fira-sans-condensed-OFL.txt" "$DIST/fira-sans-condensed-OFL.txt"

cat > "$DIST/READ-ME-FIRST.txt" << INNER_EOF
Serverlife $VERSION for macOS
==============================

1. Open Serverlife-$VERSION-mac-arm64.dmg and drag Serverlife.app onto the
   Applications shortcut in the same window (or run it from wherever you put it -
   it doesn't need to live in /Applications). Then eject the disk image.

2. Because this build isn't notarized by Apple, the first time you open it
   Gatekeeper will refuse with "Apple could not verify... is free of malware."
     - Double-click Serverlife.app once and let it be blocked.
     - Open  System Settings > Privacy & Security , scroll to the bottom, and
       click "Open Anyway" next to the Serverlife line, then confirm.
   (On macOS 14 and earlier you can instead right-click the app, choose Open,
   and click Open again.) You only need to do this once.

3. Click the gear button, then switch on "Right-click menu". You can now
   right-click any folder in Finder and choose Start server here from Quick
   Actions.

To uninstall: switch "Right-click menu" back off, delete Serverlife.app, and
delete ~/Library/Application Support/Serverlife.

Use at your own risk - see LICENSE and the disclaimer in the main README on
the website.
Source: https://github.com/Anti-super-code/serverlife
INNER_EOF

# A Developer ID signature + Apple notarisation is what actually gets the download
# past Gatekeeper without the user having to visit System Settings. It needs a paid
# Apple Developer account, so it only runs when the two variables below are set;
# otherwise this falls back to the ad-hoc signature (READ-ME-FIRST covers the
# "Open Anyway" step that unblocks that one).
#
#   SERVERLIFE_SIGN_ID        e.g. "Developer ID Application: Christopher Brellis (TEAMID)"
#   SERVERLIFE_NOTARY_PROFILE name of a profile stored once with:
#       xcrun notarytool store-credentials <name> --apple-id <id> --team-id <TEAMID> --password <app-specific-pw>
NOTARISED=0
if [ -n "${SERVERLIFE_SIGN_ID:-}" ]; then
    echo "-> codesign (Developer ID) + hardened runtime"
    codesign --force --options runtime --timestamp \
        --sign "$SERVERLIFE_SIGN_ID" "$APP"
    codesign --verify --strict --verbose "$APP" 2>&1 | tail -5
    [ -n "${SERVERLIFE_NOTARY_PROFILE:-}" ] && NOTARISED=1
else
    echo "-> codesign (ad-hoc)"
    codesign --force --sign - "$APP"
    codesign --verify --strict --verbose "$APP" 2>&1 | tail -5
fi

echo "-> build .dmg"
DMG="$DIST/Serverlife-$VERSION-mac-arm64.dmg"
VOLNAME="Serverlife $VERSION"
STAGE="$DIST/.dmg-stage"
RW_DMG="$DIST/.dmg-rw.dmg"
rm -rf "$STAGE" "$RW_DMG" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/Serverlife.app"
ln -s /Applications "$STAGE/Applications"
cp "$DIST/READ-ME-FIRST.txt" "$STAGE/READ-ME-FIRST.txt"
cp "$DIST/LICENSE" "$STAGE/LICENSE"

# Build a read/write image first so Finder can arrange the icons, then convert it
# to a compressed read-only .dmg for the website.
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -fs HFS+ \
    -format UDRW -ov "$RW_DMG" >/dev/null
rm -rf "$STAGE"

MOUNT_DIR="$(mktemp -d)"
hdiutil attach "$RW_DMG" -mountpoint "$MOUNT_DIR" -nobrowse -noverify -noautoopen >/dev/null

# Stand Serverlife.app and the Applications alias side by side in an icon-view
# window the user drags between — the layout every Mac download uses. Best-effort:
# it needs a Finder that can be scripted (an ordinary desktop login), and is
# skipped without complaint on a headless build box (the alias still works, the
# window just opens unstyled).
if osascript >/dev/null 2>&1 <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 740, 470}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 112
        set text size of opts to 12
        set position of item "Serverlife.app" of container window to {140, 175}
        set position of item "Applications" of container window to {400, 175}
        set position of item "READ-ME-FIRST.txt" of container window to {140, 330}
        set position of item "LICENSE" of container window to {400, 330}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
then
    echo "   icon layout set"
else
    echo "   (Finder not scriptable here - .dmg ships without the custom icon layout)"
fi

sync
hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true
rmdir "$MOUNT_DIR" 2>/dev/null || true

hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG" >/dev/null
rm -f "$RW_DMG"

# Notarisation staples the .dmg itself, so the download is trusted before it's
# even opened. A Developer ID signature + a paid Apple Developer account is what
# this needs; without it the ad-hoc build still ships, and READ-ME-FIRST covers
# the one-time "Open Anyway" step in System Settings that unblocks it.
#
#   SERVERLIFE_SIGN_ID        e.g. "Developer ID Application: Christopher Brellis (TEAMID)"
#   SERVERLIFE_NOTARY_PROFILE name of a profile stored once with:
#       xcrun notarytool store-credentials <name> --apple-id <id> --team-id <TEAMID> --password <app-specific-pw>
if [ "$NOTARISED" -eq 1 ]; then
    echo "-> notarise .dmg"
    xcrun notarytool submit "$DMG" --keychain-profile "$SERVERLIFE_NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose "$DMG" 2>&1 | tail -3
else
    echo "   (not notarised - website copy needs the 'Open Anyway' step in READ-ME-FIRST)"
fi

shasum -a 256 "$DMG" | awk '{print $1}' > "$DMG.sha256"

APP_MB=$(du -sm "$APP" | awk '{print $1}')
DMG_MB=$(du -sm "$DMG" | awk '{print $1}')

echo
echo "  app       $APP  (${APP_MB} MB)"
echo "  dmg       $DMG  (${DMG_MB} MB)"
echo "  sha256    $(cat "$DMG.sha256")"
[ "$NOTARISED" -eq 1 ] && echo "  notarised yes" || echo "  notarised no (ad-hoc)"
