#!/usr/bin/env bash
# Builds Reel.app into ./build
#   ./build.sh           build only
#   ./build.sh install   build, copy to /Applications and launch
#
# Signing: macOS ties Screen Recording permission to the app's signature, so Reel is signed
# with a stable identity when one exists (in this order):
#   1. SIGN_IDENTITY="…" from the environment
#   2. an Apple Development / Developer ID certificate
#   3. the local "Reel Local Signing" certificate made by setup-signing.sh
# and ad-hoc otherwise (permission then has to be re-allowed after every rebuild).
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Reel"
APP="build/$APP_NAME.app"
# Use an Apple Development certificate automatically if one is installed, so the
# Screen Recording permission survives rebuilds. Otherwise fall back to ad-hoc.
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 -E 'Apple Development|Developer ID Application' | sed -E 's/.*"(.*)".*/\1/' || true)"
fi
if [[ -z "${SIGN_IDENTITY:-}" ]] && security find-certificate -c "Reel Local Signing" >/dev/null 2>&1; then
  SIGN_IDENTITY="Reel Local Signing"
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

echo "→ Compiling (release)"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "→ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "→ Signing ($SIGN_IDENTITY)"
if ! codesign --force --sign "$SIGN_IDENTITY" "$APP"; then
  echo "  Couldn't sign with \"$SIGN_IDENTITY\", falling back to ad-hoc."
  codesign --force --sign - "$APP"
fi

if [[ "${1:-}" == "install" ]]; then
  echo "→ Installing to /Applications"
  pkill -x "$APP_NAME" 2>/dev/null || true
  # Wait for the old copy to quit before replacing and relaunching it.
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x "$APP_NAME" >/dev/null || break; sleep 0.3; done
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" /Applications/
  sleep 0.5
  open "/Applications/$APP_NAME.app" || { sleep 1.5; open "/Applications/$APP_NAME.app"; }
  echo "✓ Reel is running. Look for the record icon in your menu bar."
else
  echo "✓ Built $APP  (open it with: open $APP)"
fi
