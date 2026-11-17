#!/bin/bash
set -euo pipefail

APP_PATH="${1:-$HOME/Applications/Pocketclip.app}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: app not found at $APP_PATH" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
if [[ -z "$VERSION" ]]; then
  echo "error: could not read CFBundleShortVersionString from $APP_PATH" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$REPO_ROOT/dist"
DMG_PATH="$DIST_DIR/Pocketclip-${VERSION}.dmg"

mkdir -p "$DIST_DIR"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/pocketclip-dmg.XXXXXX")"
cleanup() {
  rm -rf "$STAGE"
}
trap cleanup EXIT

ditto --norsrc --noextattr --noqtn "$APP_PATH" "$STAGE/Pocketclip.app"
ln -s /Applications "$STAGE/Applications"

find "$STAGE" \( -name '._*' -o -name '.DS_Store' \) -delete

# hdiutil's default -srcfolder image is often a tight fit and can fail
# with "No space left on device" while copying a large model weight.
STAGE_KB="$(du -sk "$STAGE" | awk '{print $1}')"
SIZE_MB="$(( (STAGE_KB + STAGE_KB / 5 + 32768 + 1023) / 1024 ))"
if (( SIZE_MB < 128 )); then
  SIZE_MB=128
fi

hdiutil create \
  -volname "Pocketclip ${VERSION}" \
  -srcfolder "$STAGE" \
  -ov \
  -fs HFS+ \
  -size "${SIZE_MB}m" \
  -format UDZO \
  "$DMG_PATH"

BYTES="$(stat -f%z "$DMG_PATH")"
echo "Created: $DMG_PATH"
echo "Size: $BYTES bytes"
shasum -a 256 "$DMG_PATH"
