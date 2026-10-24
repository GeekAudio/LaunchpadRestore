#!/bin/bash
# Build the independent Lunchpad app. It leaves the system Dock untouched.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/standalone"
ARCH="${TARGET_ARCH:-$(uname -m)}"
OUTPUT="${OUTPUT_DIR:-$ROOT/pkg}"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/launchpadrestore-app.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT

case "$ARCH" in
    x86_64|arm64) ;;
    *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

swift build --package-path "$SOURCE" --configuration release --arch "$ARCH" --product Lunchpad
BIN_DIR="$(swift build --package-path "$SOURCE" --configuration release --arch "$ARCH" --show-bin-path)"
APP="$STAGING/Lunchpad.app"
RESOURCE_BUNDLE="$BIN_DIR/Lunchpad_Lunchpad.bundle"

[ -x "$BIN_DIR/Lunchpad" ] || { echo "Missing Lunchpad executable" >&2; exit 1; }
[ -d "$RESOURCE_BUNDLE" ] || { echo "Missing localization bundle" >&2; exit 1; }

mkdir -p "$OUTPUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
ditto "$BIN_DIR/Lunchpad" "$APP/Contents/MacOS/Lunchpad"
ditto "$RESOURCE_BUNDLE" "$APP/Contents/Resources/Lunchpad_Lunchpad.bundle"
cp "$SOURCE/Packaging/Info.plist" "$APP/Contents/Info.plist"
cp "$SOURCE/LICENSE.upstream" "$APP/Contents/Resources/LICENSE.upstream.txt"

ICON_TMP="$STAGING/icon"
ICONSET="$ICON_TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
swift "$SOURCE/Packaging/generate-icon.swift" "$ICON_TMP/master.png"
for POINTS in 16 32 128 256 512; do
    sips -z "$POINTS" "$POINTS" "$ICON_TMP/master.png" \
        --out "$ICONSET/icon_${POINTS}x${POINTS}.png" >/dev/null
    PIXELS=$((POINTS * 2))
    sips -z "$PIXELS" "$PIXELS" "$ICON_TMP/master.png" \
        --out "$ICONSET/icon_${POINTS}x${POINTS}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

chmod 755 "$APP/Contents/MacOS/Lunchpad"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
xattr -cr "$APP"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"

ditto --norsrc -c -k --keepParent "$APP" "$OUTPUT/Lunchpad.zip"
echo "独立启动台已构建: $OUTPUT/Lunchpad.zip"
echo "此步骤未替换或启动系统 Dock。"
