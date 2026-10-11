#!/usr/bin/env bash
# Publishes a new Oneshot release on GitHub — what Check for Updates installs.
#   ./release.sh          next patch version (2.1 → 2.1.1)
#   ./release.sh 2.2      a specific version
#   INSTALL=1 ./release.sh   …and install it on this Mac too
#
# Builds a universal app signed with your local certificate (so Screen Recording permission carries
# over between updates), packages Oneshot-<version>.zip (downloaded by Check for Updates) and
# Oneshot-<version>.dmg (for sharing), tags the commit and uploads both to GitHub Releases.
# Uploading uses GITHUB_TOKEN, `gh auth token`, or the GitHub login git already has, in that order.
set -euo pipefail
cd "$(dirname "$0")"
REPO="joebentaylor1995/Oneshot"

git fetch --quiet --tags origin
LAST="$(git tag --list 'v*' --sort=-v:refname | head -1 | sed 's/^v//')"
if [[ -n "${1:-}" ]]; then
  VERSION="${1#v}"
elif [[ -n "$LAST" ]]; then
  IFS=. read -r MAJOR MINOR PATCH <<< "$LAST"
  VERSION="$MAJOR.${MINOR:-0}.$(( ${PATCH:-0} + 1 ))"
else
  echo "No releases yet: give a version, e.g. ./release.sh 2.1" >&2
  exit 1
fi
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
  echo "v$VERSION already exists." >&2
  exit 1
fi
echo "→ Releasing Oneshot $VERSION from $(git log -1 --format='%h %s')"

VERSION="$VERSION" UNIVERSAL=1 bash build.sh
if codesign -dvv build/Oneshot.app 2>&1 | grep -q "Signature=adhoc"; then
  echo "This build is only ad-hoc signed, so updating to it would reset Screen Recording permission." >&2
  echo "Run ./setup-signing.sh once to create the local signing certificate, then try again." >&2
  exit 1
fi

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/oneshot-release.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/dmg"
ditto --norsrc --noextattr build/Oneshot.app "$STAGE/dmg/Oneshot.app"
codesign --verify --deep --strict "$STAGE/dmg/Oneshot.app"

OUT="$PWD/build/release"
rm -rf "$OUT" && mkdir -p "$OUT"
ZIP="$OUT/Oneshot-$VERSION.zip"
DMG="$OUT/Oneshot-$VERSION.dmg"
echo "→ Packaging"
(cd "$STAGE/dmg" && ditto -c -k --keepParent Oneshot.app "$ZIP")
ln -s /Applications "$STAGE/dmg/Applications"
hdiutil create -quiet -volname "Oneshot" -srcfolder "$STAGE/dmg" -fs HFS+ -format UDZO -ov "$DMG"
echo "  $(lipo -archs build/Oneshot.app/Contents/MacOS/Oneshot) · $(du -h "$ZIP" | cut -f1) zip · $(du -h "$DMG" | cut -f1) dmg"

if [[ -n "$LAST" ]]; then
  NOTES="$(git log --no-merges --format='- %s' "v$LAST"..HEAD)"
else
  NOTES="- Check for Updates now installs new versions straight from GitHub Releases."
fi

TOKEN="${GITHUB_TOKEN:-}"
if [[ -z "$TOKEN" ]] && command -v gh >/dev/null 2>&1; then TOKEN="$(gh auth token 2>/dev/null || true)"; fi
if [[ -z "$TOKEN" ]]; then
  TOKEN="$(printf 'protocol=https\nhost=github.com\n\n' | GIT_TERMINAL_PROMPT=0 git credential fill 2>/dev/null | sed -n 's/^password=//p' || true)"
fi
if [[ -z "$TOKEN" ]]; then
  echo "Built, but there's no GitHub login to publish with. Files are in $OUT" >&2
  exit 2
fi

echo "→ Publishing v$VERSION"
git tag -a "v$VERSION" -m "Oneshot $VERSION"
if ! git push --quiet origin "v$VERSION"; then
  git tag -d "v$VERSION" >/dev/null
  echo "Couldn't push the v$VERSION tag to GitHub. Files are in $OUT" >&2
  exit 1
fi
PAYLOAD="$(VERSION="$VERSION" NOTES="$NOTES" /usr/bin/python3 -c 'import json, os; v = os.environ["VERSION"]; print(json.dumps({"tag_name": "v" + v, "name": "Oneshot " + v, "body": os.environ["NOTES"]}))')"
RELEASE="$(curl -fsS -X POST -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/$REPO/releases" -d "$PAYLOAD")"
RELEASE_ID="$(printf '%s' "$RELEASE" | /usr/bin/python3 -c 'import json, sys; print(json.load(sys.stdin)["id"])')"
for FILE in "$ZIP" "$DMG"; do
  curl -fsS -o /dev/null -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/octet-stream" \
    --data-binary @"$FILE" "https://uploads.github.com/repos/$REPO/releases/$RELEASE_ID/assets?name=$(basename "$FILE")"
  echo "  uploaded $(basename "$FILE")"
done

if [[ "${INSTALL:-}" == "1" ]]; then
  echo "→ Installing on this Mac"
  pkill -x Oneshot 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Oneshot >/dev/null || break; sleep 0.3; done
  rm -rf /Applications/Oneshot.app
  ditto "$STAGE/dmg/Oneshot.app" /Applications/Oneshot.app
  open /Applications/Oneshot.app || { sleep 1.5; open /Applications/Oneshot.app; }
fi
echo "✓ Oneshot $VERSION is out: https://github.com/$REPO/releases/tag/v$VERSION"
