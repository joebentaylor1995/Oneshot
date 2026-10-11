#!/usr/bin/env bash
# Builds a shareable Oneshot.dmg (universal, ad-hoc signed, no self-updating).
#   ./make-dmg.sh [output-folder]      default: ./build
#
# The app isn't notarized, so on first launch the recipient has to allow it in
# System Settings › Privacy & Security › "Open Anyway".
set -euo pipefail
cd "$(dirname "$0")"
OUT_DIR="${1:-build}"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

# Ad-hoc signing: a local certificate means nothing on another Mac.
UNIVERSAL=1 DISTRIBUTION=1 SIGN_IDENTITY=- bash build.sh

VERSION="$(plutil -extract CFBundleShortVersionString raw build/Oneshot.app/Contents/Info.plist)"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/oneshot-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

echo "→ Packaging DMG"
mkdir -p "$STAGE/Oneshot"
ditto --norsrc --noextattr build/Oneshot.app "$STAGE/Oneshot/Oneshot.app"
codesign --verify --deep "$STAGE/Oneshot/Oneshot.app"
ln -s /Applications "$STAGE/Oneshot/Applications"

DMG="$OUT_DIR/Oneshot-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -quiet -volname "Oneshot" -srcfolder "$STAGE/Oneshot" -fs HFS+ -format UDZO -ov "$DMG"
echo "  architectures: $(lipo -archs build/Oneshot.app/Contents/MacOS/Oneshot)"
echo "✓ $DMG"
