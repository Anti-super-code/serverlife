#!/bin/bash
# Builds the macOS download that goes on the website: a self-contained
# Serverlife.app (Apple Silicon only), ad-hoc signed — the macOS counterpart of
# package.ps1. No .dmg here (unlike Photokompressor's own packaging script) —
# just the app bundle, staged and ready to zip or hand out directly.
#
#   bash build/package-mac.sh
#   bash build/package-mac.sh --skip-tests   # only when you already ran them
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

1. Drag Serverlife.app to Applications (or run it from wherever you put it - it
   doesn't need to live in /Applications).

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
if [ -n "${SERVERLIFE_SIGN_ID:-}" ]; then
    echo "-> codesign (Developer ID) + hardened runtime"
    codesign --force --options runtime --timestamp \
        --sign "$SERVERLIFE_SIGN_ID" "$APP"
    codesign --verify --strict --verbose "$APP" 2>&1 | tail -5

    if [ -n "${SERVERLIFE_NOTARY_PROFILE:-}" ]; then
        echo "-> notarise"
        ZIP="$DIST/Serverlife-$VERSION.zip"
        ditto -c -k --keepParent "$APP" "$ZIP"
        xcrun notarytool submit "$ZIP" --keychain-profile "$SERVERLIFE_NOTARY_PROFILE" --wait
        xcrun stapler staple "$APP"
        rm -f "$ZIP"
        spctl --assess --type execute --verbose "$APP" 2>&1 | tail -3
    else
        echo "   (SERVERLIFE_NOTARY_PROFILE not set - signed but NOT notarised)"
    fi
else
    echo "-> codesign (ad-hoc)"
    codesign --force --sign - "$APP"
    codesign --verify --strict --verbose "$APP" 2>&1 | tail -5
fi

APP_MB=$(du -sm "$APP" | awk '{print $1}')

echo
echo "  app       $APP"
echo "  size      ${APP_MB} MB"
