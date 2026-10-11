#!/usr/bin/env bash
# Builds Oneshot.app into ./build
#   ./build.sh           build only
#   ./build.sh install   build, copy to /Applications and launch
#
# Signing: macOS ties Screen Recording permission to the app's signature, so Oneshot is signed
# with a stable identity when one exists (in this order):
#   1. SIGN_IDENTITY="…" from the environment
#   2. an Apple Development / Developer ID certificate
#   3. the local signing certificate made by setup-signing.sh ("Oneshot Local Signing",
#      or "Reel Local Signing" from before the rename)
# and ad-hoc otherwise (permission then has to be re-allowed after every rebuild).
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Oneshot"
# Assemble and sign outside the source folder: if it lives somewhere iCloud syncs (like the
# Desktop), the sync keeps re-adding file attributes that codesign refuses to sign over.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/oneshot-build.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/$APP_NAME.app"
# Use an Apple Development certificate automatically if one is installed, so the
# Screen Recording permission survives rebuilds. Otherwise fall back to ad-hoc.
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 -E 'Apple Development|Developer ID Application' | sed -E 's/.*"(.*)".*/\1/' || true)"
fi
for LOCAL_CERT in "Oneshot Local Signing" "Reel Local Signing"; do
  if [[ -z "${SIGN_IDENTITY:-}" ]] && security find-certificate -c "$LOCAL_CERT" >/dev/null 2>&1; then
    SIGN_IDENTITY="$LOCAL_CERT"
  fi
done
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

# UNIVERSAL=1 builds for Apple Silicon and Intel (release.sh uses it).
SWIFT_ARGS=(-c release)
if [[ "${UNIVERSAL:-}" == "1" ]]; then SWIFT_ARGS+=(--arch arm64 --arch x86_64); fi
echo "→ Compiling (release${UNIVERSAL:+, universal})"
swift build "${SWIFT_ARGS[@]}"
BIN_DIR="$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)"

echo "→ Assembling $APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Stamp the build with its commit so the in-app updater knows which version this is.
COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
SUBJECT="$(git log -1 --format=%s 2>/dev/null || true)"
plutil -insert OneshotCommit -string "$COMMIT" "$APP/Contents/Info.plist"
plutil -insert OneshotCommitSubject -string "$SUBJECT" "$APP/Contents/Info.plist"
# Version: VERSION from the environment (release.sh sets it), else the latest v* tag.
if [[ -z "${VERSION:-}" ]]; then
  VERSION="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null | sed 's/^v//' || true)"
fi
if [[ -n "$VERSION" ]]; then
  plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
fi
plutil -replace CFBundleVersion -string "$(git rev-list --count HEAD 2>/dev/null || echo 1)" "$APP/Contents/Info.plist"
cp Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png "$APP/Contents/Resources/"

echo "→ App icon"
# Preferred: compile the Icon Composer package (light / dark / tinted) with Xcode's actool,
# which produces Assets.car for macOS 26+ plus an AppIcon.icns for older systems.
ACTOOL=""
if xcrun --find actool >/dev/null 2>&1; then
  ACTOOL="xcrun actool"
elif [[ -x /Applications/Xcode.app/Contents/Developer/usr/bin/actool ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  ACTOOL="$DEVELOPER_DIR/usr/bin/actool"
fi
ICON_TMP="$(mktemp -d)"
if [[ -n "$ACTOOL" && -d Resources/AppIcon.icon ]] && $ACTOOL \
    --compile "$ICON_TMP" \
    --platform macosx --target-device mac \
    --minimum-deployment-target 15.0 \
    --app-icon AppIcon --include-all-app-icons \
    --output-partial-info-plist "$ICON_TMP/partial.plist" \
    --output-format human-readable-text --errors --warnings \
    Resources/Assets.xcassets Resources/AppIcon.icon && [[ -f "$ICON_TMP/Assets.car" ]]; then
  cp "$ICON_TMP/Assets.car" "$APP/Contents/Resources/"
  [[ -f "$ICON_TMP/AppIcon.icns" ]] && cp "$ICON_TMP/AppIcon.icns" "$APP/Contents/Resources/"
  echo "  compiled AppIcon.icon with actool"
fi
# Fallback (or older-macOS copy): plain .icns from the iconset.
if [[ ! -f "$APP/Contents/Resources/AppIcon.icns" ]]; then
  iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
  echo "  built AppIcon.icns with iconutil"
fi
rm -rf "$ICON_TMP"

# codesign rejects extended attributes (download provenance, Finder info).
xattr -cr "$APP" 2>/dev/null || true

echo "→ Signing ($SIGN_IDENTITY)"
if ! codesign --force --sign "$SIGN_IDENTITY" "$APP"; then
  echo "  Couldn't sign with \"$SIGN_IDENTITY\", falling back to ad-hoc."
  codesign --force --sign - "$APP"
fi

# Keep a copy in ./build too.
mkdir -p build
rm -rf "build/$APP_NAME.app"
cp -R "$APP" build/

if [[ "${1:-}" == "install" ]]; then
  echo "→ Installing to /Applications"
  pkill -x "$APP_NAME" 2>/dev/null || true
  # Remove the pre-rename copy if it's still around.
  pkill -x Reel 2>/dev/null || true
  rm -rf /Applications/Reel.app
  # Wait for the old copy to quit before replacing and relaunching it.
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x "$APP_NAME" >/dev/null || break; sleep 0.3; done
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" /Applications/
  sleep 0.5
  # Tell Finder/Dock the icon changed.
  touch "/Applications/$APP_NAME.app"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/$APP_NAME.app" >/dev/null 2>&1 || true
  open "/Applications/$APP_NAME.app" || { sleep 1.5; open "/Applications/$APP_NAME.app"; }
  echo "✓ Oneshot is running. Look for the record icon in your menu bar."
else
  echo "✓ Built build/$APP_NAME.app  (open it with: open build/$APP_NAME.app)"
fi
