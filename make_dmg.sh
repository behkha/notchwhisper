#!/bin/bash
# Package build/NotchWhisper.app into a distributable .dmg.
#
# Usage: ./make_dmg.sh [arch]
#   arch   optional architecture suffix appended to the filename and mounted
#          volume name (e.g. arm64, x86_64, universal). Leave empty for a plain
#          "NotchWhisper-<version>.dmg".
#
# Requires build/NotchWhisper.app to exist (run ./build.sh first). Uses only
# Apple-native tools (hdiutil, PlistBuddy) — no Homebrew dependencies.
set -euo pipefail

ARCH="${1:-}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/NotchWhisper.app"

if [ ! -d "$APP" ]; then
  echo "!! build/NotchWhisper.app not found — run ./build.sh first"
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo dev)"

# Build the asset name. With an arch suffix the file (and the mounted volume)
# clearly advertise which Mac it is intended for.
if [ -n "$ARCH" ]; then
  DMG_NAME="NotchWhisper-${VERSION}-${ARCH}"
  VOL_NAME="NotchWhisper ${VERSION} ${ARCH}"
else
  DMG_NAME="NotchWhisper-${VERSION}"
  VOL_NAME="NotchWhisper ${VERSION}"
fi

STAGE="$(mktemp -d)"

cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

# Staging folder: the app plus a symlink to /Applications for easy install.
mkdir -p "$STAGE/$DMG_NAME"
cp -R "$APP" "$STAGE/$DMG_NAME/"
ln -s /Applications "$STAGE/$DMG_NAME/Applications"

echo "==> Creating $DMG_NAME.dmg"
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGE/$DMG_NAME" \
  -ov -format UDZO \
  "$ROOT/$DMG_NAME.dmg"

echo "✓ built $ROOT/$DMG_NAME.dmg"
