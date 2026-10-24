#!/bin/bash
# Package the independent app, one-time layout import, and Dock rollback.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_ZIP="$ROOT/pkg/Lunchpad.zip"
OUTPUT="$ROOT/pkg/LaunchpadRestore-Standalone-Migrate.pkg"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/launchpadrestore-standalone.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT

"$ROOT/scripts/build-standalone-app.sh"

mkdir -p "$BUILD/payload/Applications" \
    "$BUILD/payload/Library/Application Support/LaunchpadRestore" \
    "$BUILD/scripts"
ditto -x -k "$APP_ZIP" "$BUILD/payload/Applications"
codesign --verify --deep --strict "$BUILD/payload/Applications/Lunchpad.app"
cp "$ROOT/scripts/import-native-layout.py" \
    "$BUILD/payload/Library/Application Support/LaunchpadRestore/import-native-layout.py"
cp "$ROOT/scripts/import-native-layout.py" "$BUILD/scripts/import-native-layout.py"
cp "$ROOT/scripts/postinstall-standalone.sh" "$BUILD/scripts/postinstall"
cp "$ROOT/scripts/postinstall-rollback.sh" "$BUILD/scripts/postinstall-rollback.sh"
chmod 755 "$BUILD/scripts/postinstall" "$BUILD/scripts/postinstall-rollback.sh" \
    "$BUILD/scripts/import-native-layout.py"

pkgbuild --root "$BUILD/payload" --scripts "$BUILD/scripts" \
    --install-location / \
    --identifier com.geekaudio.launchpadrestore.standalone \
    --version 0.1.2 \
    "$BUILD/Component.pkg" >/dev/null

cat >"$BUILD/Distribution.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="1">
  <title>LaunchpadRestore 独立启动台迁移</title>
  <options customize="never" require-scripts="true"/>
  <choices-outline><line choice="standalone"/></choices-outline>
  <choice id="standalone" visible="false">
    <pkg-ref id="com.geekaudio.launchpadrestore.standalone"/>
  </choice>
  <pkg-ref id="com.geekaudio.launchpadrestore.standalone"
           version="0.1.2" onConclusion="RequireRestart">Component.pkg</pkg-ref>
</installer-gui-script>
XML

productbuild --distribution "$BUILD/Distribution.xml" \
    --package-path "$BUILD" "$OUTPUT" >/dev/null
echo "迁移安装包已构建: $OUTPUT"
