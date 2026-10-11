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
APP="build/$APP_NAME.app"
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
  # Remove the pre-rename copy if it's still around.
  pkill -x Reel 2>/dev/null || true
  rm -rf /Applications/Reel.app
  # Wait for the old copy to quit before replacing and relaunching it.
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x "$APP_NAME" >/dev/null || break; sleep 0.3; done
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" /Applications/
  sleep 0.5
  open "/Applications/$APP_NAME.app" || { sleep 1.5; open "/Applications/$APP_NAME.app"; }
  echo "✓ Oneshot is running. Look for the record icon in your menu bar."
else
  echo "✓ Built $APP  (open it with: open $APP)"
fi
