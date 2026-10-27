#!/bin/bash
# Build the complete native Launchpad packages for macOS 26.7.1 and 26.7.2.
# Package creation does not install Dock, alter the system volume, or reboot.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_261=""
SOURCE_262="/System/Library/CoreServices/Dock.app"
BASELINE_PACKAGE="$ROOT/pkg/LaunchpadRestore-Native2427-Install-2427.6.10.pkg"
BASELINE_PACKAGE_EXPLICIT=0
PACKAGE_VERSION="2427.6.11"
EXPERIMENT_VERSION="2427.6.9"
ARCH="x86_64"

OLD_PRODUCT_VERSION="26.7.1"
OLD_BUILD_VERSION="25G241"
OLD_STOCK_SHA="278ed95b86bdef7e122820a0251c5a607fec377c217fae34a651397e8082e193"
OLD_STOCK_INFO_SHA="df5a816eb4136b81c281ecbc4fe910cf82fbc572268219ae950c569a3ac5c2ab"
OLD_CANDIDATE_SHA="ee0e2448782b753eee37eb156ce97fb10e2c49dc39464a9a58d5da42426fe8ef"
BASELINE_PACKAGE_SHA="461f37f90c8da0f68329628a1a0140d5ec7e0d1bb92a92e5e00e82641c0a3b2c"

NEW_PRODUCT_VERSION="26.7.2"
NEW_BUILD_VERSION="25G332"
NEW_STOCK_SHA="0e13feca187548ea9a1e1c90c69a3a011133d919be7e0d6ad56da5cd46b2ecc2"
NEW_STOCK_INFO_SHA="13ee6ebf392c4c8b86b8a70f8cbe782ac12426f35543ee89fdb6f3f1262fe06c"

usage() {
    cat <<'USAGE'
Usage: build-native-entry-pkg.sh [options]

Build complete Install and Uninstall packages for Intel/x86_64 macOS 26.7.1
(25G241) and 26.7.2 (25G332). This builder must run on macOS 26.7.2 (25G332).

  --source-26.7.1 PATH   Use an unmodified Apple Dock.app from 26.7.1 to
                         reproduce that build's v9 candidate.
  --baseline-package PKG Use the trusted 2427.6.10 Install package to carry
                         forward its byte-identical 26.7.1 Dock (the default).
  --source-26.7.2 PATH   Use an unmodified Apple Dock.app from 26.7.2.
                         Defaults to /System/Library/CoreServices/Dock.app.
  -h, --help             Show this help.

The 26.7.1 source option and baseline-package option are mutually exclusive.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --source-26.7.1)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            SOURCE_261="$2"
            shift 2
            ;;
        --source-26.7.2)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            SOURCE_262="$2"
            shift 2
            ;;
        --baseline-package)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            BASELINE_PACKAGE="$2"
            BASELINE_PACKAGE_EXPLICIT=1
            shift 2
            ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [ -n "$SOURCE_261" ] && [ "$BASELINE_PACKAGE_EXPLICIT" = 1 ]; then
    echo "Choose either --source-26.7.1 or --baseline-package, not both" >&2
    exit 2
fi

# The inventory helper rejects symlink path components such as /tmp on macOS.
BUILD="$(mktemp -d /private/tmp/launchpad-native-entry.XXXXXX)"
trap 'rm -rf "$BUILD"' EXIT

[ "$(uname -m)" = "$ARCH" ] || { echo "Only the x86_64 candidate is supported" >&2; exit 1; }
[ "$(sw_vers -productVersion)" = "$NEW_PRODUCT_VERSION" ] \
    || { echo "macOS $NEW_PRODUCT_VERSION is required for building" >&2; exit 1; }
[ "$(sw_vers -buildVersion)" = "$NEW_BUILD_VERSION" ] \
    || { echo "macOS build $NEW_BUILD_VERSION is required for building" >&2; exit 1; }
[ -d "$SOURCE_262" ] || { echo "Missing 26.7.2 source Dock bundle: $SOURCE_262" >&2; exit 1; }

sha256_file() { shasum -a 256 "$1" | awk '{print $1}'; }
plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null; }
bundle_version() { defaults read "$1/Contents/Info.plist" CFBundleVersion 2>/dev/null; }

validate_stock_bundle() {
    local bundle="$1" expected_exe="$2" expected_info="$3" label="$4"
    [ -d "$bundle" ] || { echo "Missing $label Dock bundle: $bundle" >&2; exit 1; }
    [ "$(bundle_version "$bundle")" = "2427.6" ] \
        || { echo "$label Dock version is not 2427.6" >&2; exit 1; }
    [ "$(sha256_file "$bundle/Contents/MacOS/Dock")" = "$expected_exe" ] \
        || { echo "$label Dock executable SHA-256 mismatch" >&2; exit 1; }
    [ "$(sha256_file "$bundle/Contents/Info.plist")" = "$expected_info" ] \
        || { echo "$label Dock Info.plist SHA-256 mismatch" >&2; exit 1; }
    lipo "$bundle/Contents/MacOS/Dock" -verify_arch "$ARCH" >/dev/null \
        || { echo "$label Dock does not contain $ARCH" >&2; exit 1; }
    codesign --verify --deep --no-strict -R='anchor apple' "$bundle" >/dev/null \
        || { echo "$label Dock source does not have a valid Apple signature" >&2; exit 1; }
}

validate_stock_bundle "$SOURCE_262" "$NEW_STOCK_SHA" "$NEW_STOCK_INFO_SHA" "macOS 26.7.2"

mkdir -p "$BUILD/scripts/variants/25G241" "$BUILD/scripts/variants/25G332"
mkdir -p "$BUILD/payload/Library/Application Support/LaunchpadRestore"

if [ -n "$SOURCE_261" ]; then
    validate_stock_bundle "$SOURCE_261" "$OLD_STOCK_SHA" "$OLD_STOCK_INFO_SHA" "macOS 26.7.1"
    mkdir -p "$BUILD/scripts/variants/25G241/Dock.app"
    rsync -rlt "$SOURCE_261/" "$BUILD/scripts/variants/25G241/Dock.app/"
    codesign -d --entitlements :- "$SOURCE_261" > "$BUILD/entitlements-25G241.plist" 2>/dev/null
    plutil -lint "$BUILD/entitlements-25G241.plist" >/dev/null
    lipo "$BUILD/scripts/variants/25G241/Dock.app/Contents/MacOS/Dock" -thin "$ARCH" \
        -output "$BUILD/Dock-25G241.x86_64"
    /usr/bin/python3 "$ROOT/scripts/patch-native-dock.py" \
        "$BUILD/Dock-25G241.x86_64" "$BUILD/Dock-25G241.patched"
    cp "$BUILD/Dock-25G241.patched" \
        "$BUILD/scripts/variants/25G241/Dock.app/Contents/MacOS/Dock"
    plutil -insert LPRNativeExperimentVersion -string "$EXPERIMENT_VERSION" \
        "$BUILD/scripts/variants/25G241/Dock.app/Contents/Info.plist"
    codesign --force --sign - --timestamp=none \
        --entitlements "$BUILD/entitlements-25G241.plist" \
        "$BUILD/scripts/variants/25G241/Dock.app" >/dev/null
    codesign --verify --strict "$BUILD/scripts/variants/25G241/Dock.app"
else
    [ -f "$BASELINE_PACKAGE" ] || {
        echo "Missing trusted 26.7.1 baseline package: $BASELINE_PACKAGE" >&2
        echo "Provide --source-26.7.1 or --baseline-package" >&2
        exit 1
    }
    [ "$(sha256_file "$BASELINE_PACKAGE")" = "$BASELINE_PACKAGE_SHA" ] \
        || { echo "Baseline package SHA-256 mismatch" >&2; exit 1; }
    pkgutil --expand-full "$BASELINE_PACKAGE" "$BUILD/baseline-package"
    BASELINE_SCRIPTS="$(find "$BUILD/baseline-package" -type d -path '*/Scripts' -print -quit)"
    [ -n "$BASELINE_SCRIPTS" ] || { echo "Baseline package has no scripts payload" >&2; exit 1; }
    BASELINE_DOCK="$BASELINE_SCRIPTS/Dock.app"
    BASELINE_MANIFEST="$BASELINE_SCRIPTS/package-manifest.plist"
    BASELINE_INVENTORY="$BASELINE_SCRIPTS/bundle-inventory.plist"
    [ -d "$BASELINE_DOCK" ] && [ -f "$BASELINE_MANIFEST" ] && [ -f "$BASELINE_INVENTORY" ] \
        || { echo "Baseline package is missing its Dock or inventory" >&2; exit 1; }
    [ "$(plist_value "$BASELINE_MANIFEST" FormatVersion)" = 1 ] \
        && [ "$(plist_value "$BASELINE_MANIFEST" PackageVersion)" = "2427.6.10" ] \
        && [ "$(plist_value "$BASELINE_MANIFEST" SupportedProductVersion)" = "$OLD_PRODUCT_VERSION" ] \
        && [ "$(plist_value "$BASELINE_MANIFEST" SupportedBuildVersion)" = "$OLD_BUILD_VERSION" ] \
        && [ "$(plist_value "$BASELINE_MANIFEST" StockSourceSHA256)" = "$OLD_STOCK_SHA" ] \
        && [ "$(plist_value "$BASELINE_MANIFEST" CandidateSHA256)" = "$OLD_CANDIDATE_SHA" ] \
        && [ "$(plist_value "$BASELINE_MANIFEST" DockExperimentVersion)" = "$EXPERIMENT_VERSION" ] \
        || { echo "Baseline package manifest does not match the known 26.7.1 candidate" >&2; exit 1; }
    [ "$(sha256_file "$BASELINE_DOCK/Contents/MacOS/Dock")" = "$OLD_CANDIDATE_SHA" ] \
        || { echo "Baseline Dock candidate SHA-256 mismatch" >&2; exit 1; }
    [ "$(bundle_version "$BASELINE_DOCK")" = "2427.6" ] \
        && [ "$(defaults read "$BASELINE_DOCK/Contents/Info.plist" LPRNativeExperimentVersion 2>/dev/null)" = "$EXPERIMENT_VERSION" ] \
        || { echo "Baseline Dock version or patch marker mismatch" >&2; exit 1; }
    codesign --verify --strict "$BASELINE_DOCK"
    ditto "$BASELINE_DOCK" "$BUILD/scripts/variants/25G241/Dock.app"
    cp "$BASELINE_INVENTORY" "$BUILD/scripts/variants/25G241/bundle-inventory.plist"
fi

NEW_DOCK="$BUILD/scripts/variants/25G332/Dock.app"
mkdir -p "$NEW_DOCK"
rsync -rlt "$SOURCE_262/" "$NEW_DOCK/"
codesign -d --entitlements :- "$SOURCE_262" > "$BUILD/entitlements-25G332.plist" 2>/dev/null
plutil -lint "$BUILD/entitlements-25G332.plist" >/dev/null
lipo "$NEW_DOCK/Contents/MacOS/Dock" -thin "$ARCH" -output "$BUILD/Dock-25G332.x86_64"
/usr/bin/python3 "$ROOT/scripts/patch-native-dock.py" \
    "$BUILD/Dock-25G332.x86_64" "$BUILD/Dock-25G332.patched"
cp "$BUILD/Dock-25G332.patched" "$NEW_DOCK/Contents/MacOS/Dock"
plutil -insert LPRNativeExperimentVersion -string "$EXPERIMENT_VERSION" \
    "$NEW_DOCK/Contents/Info.plist"
codesign --force --sign - --timestamp=none --entitlements "$BUILD/entitlements-25G332.plist" \
    "$NEW_DOCK" >/dev/null
codesign --verify --strict "$NEW_DOCK"

OLD_DOCK="$BUILD/scripts/variants/25G241/Dock.app"
[ "$(sha256_file "$OLD_DOCK/Contents/MacOS/Dock")" = "$OLD_CANDIDATE_SHA" ] \
    || { echo "26.7.1 candidate SHA-256 does not match the verified v9 binary" >&2; exit 1; }
OLD_CANDIDATE_SHA_ACTUAL="$(sha256_file "$OLD_DOCK/Contents/MacOS/Dock")"
NEW_CANDIDATE_SHA="$(sha256_file "$NEW_DOCK/Contents/MacOS/Dock")"

# The new candidate and both bundle inventories are built with the same signed
# helper that will validate them on the target Mac.
xcrun clang -arch "$ARCH" -mmacosx-version-min=26.0 -O2 -Wall -Wextra -Werror -fobjc-arc \
    -framework Foundation -framework CoreFoundation "$ROOT/native/ca-render-backend.m" \
    -o "$BUILD/payload/Library/Application Support/LaunchpadRestore/ca-render-backend"
codesign --force --sign - --timestamp=none \
    "$BUILD/payload/Library/Application Support/LaunchpadRestore/ca-render-backend" >/dev/null

xcrun clang -arch "$ARCH" -mmacosx-version-min=26.0 -O2 -Wall -Wextra -Werror -fobjc-arc \
    -framework Foundation -framework IOKit "$ROOT/native/dock-bundle-state.m" \
    -o "$BUILD/payload/Library/Application Support/LaunchpadRestore/dock-bundle-state"
codesign --force --sign - --timestamp=none \
    "$BUILD/payload/Library/Application Support/LaunchpadRestore/dock-bundle-state" >/dev/null
BUNDLE_HELPER="$BUILD/payload/Library/Application Support/LaunchpadRestore/dock-bundle-state"

if [ -z "$SOURCE_261" ]; then
    "$BUNDLE_HELPER" --verify-bundle "$OLD_DOCK" \
        "$BUILD/scripts/variants/25G241/bundle-inventory.plist"
else
    "$BUNDLE_HELPER" --inventory "$OLD_DOCK" > "$BUILD/inventory-25G241.json"
    /usr/bin/python3 - "$BUILD/inventory-25G241.json" \
        "$BUILD/scripts/variants/25G241/bundle-inventory.plist" <<'PY'
import json
import plistlib
import sys
from pathlib import Path

source, destination = map(Path, sys.argv[1:])
destination.write_bytes(plistlib.dumps(json.loads(source.read_text()), sort_keys=False))
PY
fi
"$BUNDLE_HELPER" --inventory "$NEW_DOCK" > "$BUILD/inventory-25G332.json"
/usr/bin/python3 - "$BUILD/inventory-25G332.json" \
    "$BUILD/scripts/variants/25G332/bundle-inventory.plist" <<'PY'
import json
import plistlib
import sys
from pathlib import Path

source, destination = map(Path, sys.argv[1:])
destination.write_bytes(plistlib.dumps(json.loads(source.read_text()), sort_keys=False))
PY
"$BUNDLE_HELPER" --verify-bundle "$OLD_DOCK" \
    "$BUILD/scripts/variants/25G241/bundle-inventory.plist"
"$BUNDLE_HELPER" --verify-bundle "$NEW_DOCK" \
    "$BUILD/scripts/variants/25G332/bundle-inventory.plist"

# The package carries both complete Dock bundles; the target selects the entry
# matching its exact product/build pair before changing the system volume.
/usr/bin/python3 - "$BUILD/scripts/package-manifest.plist" \
    "$PACKAGE_VERSION" "$EXPERIMENT_VERSION" "$OLD_CANDIDATE_SHA_ACTUAL" \
    "$NEW_CANDIDATE_SHA" <<'PY'
import plistlib
import sys
from pathlib import Path

path, package, experiment, old_candidate, new_candidate = sys.argv[1:]
manifest = {
    "FormatVersion": 2,
    "PackageVersion": package,
    "SupportedArchitecture": "x86_64",
    "DockVersion": "2427.6",
    "Variants": {
        "25G241": {
            "ProductVersion": "26.7.1",
            "BuildVersion": "25G241",
            "StockSourceSHA256": "278ed95b86bdef7e122820a0251c5a607fec377c217fae34a651397e8082e193",
            "CandidateSHA256": old_candidate,
            "StockInfoPlistSHA256": "df5a816eb4136b81c281ecbc4fe910cf82fbc572268219ae950c569a3ac5c2ab",
            "DockExperimentVersion": experiment,
            "RelativeDirectory": "variants/25G241",
        },
        "25G332": {
            "ProductVersion": "26.7.2",
            "BuildVersion": "25G332",
            "StockSourceSHA256": "0e13feca187548ea9a1e1c90c69a3a011133d919be7e0d6ad56da5cd46b2ecc2",
            "CandidateSHA256": new_candidate,
            "StockInfoPlistSHA256": "13ee6ebf392c4c8b86b8a70f8cbe782ac12426f35543ee89fdb6f3f1262fe06c",
            "DockExperimentVersion": experiment,
            "RelativeDirectory": "variants/25G332",
        },
    },
}
Path(path).write_bytes(plistlib.dumps(manifest, sort_keys=False))
PY

cp "$ROOT/scripts/postinstall-native-entry.sh" "$BUILD/scripts/postinstall"
cp "$ROOT/scripts/native-package-profile.sh" "$BUILD/scripts/native-package-profile.sh"
chmod 755 "$BUILD/scripts/postinstall" "$BUILD/scripts/native-package-profile.sh"

cat > "$BUILD/payload/Library/Application Support/LaunchpadRestore/native-entry-readme.txt" <<'README'
LaunchpadRestore 完整原生启动台 2427.6.11

支持 Intel / x86_64 的 macOS 26.7.1（25G241）和 macOS 26.7.2（25G332）。
安装包内含两套完整 Dock.app 和辅助工具，安装时按系统版本选择对应版本；
不要求电脑预先安装旧版启动台或 OCLP。

首次安装会把本机 Dock 按系统 build 分别保存在：
/Library/Application Support/LaunchpadRestore/Originals/25G241/
/Library/Application Support/LaunchpadRestore/Originals/25G332/
升级前后的原版备份分开保留，不会用另一台电脑的 Dock 作为还原备份。
卸载包使用本机相同系统 build 的备份。

OCLP 恢复或重建系统快照可能把 Dock 恢复为 Apple 原版。完成 OCLP 操作后，
如需继续使用本项目启动台，请重新安装本包。

安装完成后，重启以从新快照启动。安装器不会更改 SIP、Authenticated Root、
AMFI、EFI 或驱动设置。
README

mkdir -p "$BUILD/resources"
cat > "$BUILD/resources/InstallReadme.html" <<'HTML'
<!doctype html><html lang="zh-CN"><meta charset="utf-8"><body>
<h2>安装完整原生启动台</h2>
<p>支持 Intel / x86_64、macOS 26.7.1（25G241）和 macOS 26.7.2（25G332）。安装器会按系统 build 选择对应的完整 Dock。</p>
<p>本包包含完整 Dock.app 和辅助工具，不要求电脑预先安装旧版启动台或 OCLP。</p>
<p>目标系统须关闭 Authenticated Root，并符合运行重新签名系统程序的要求。本包不会更改 SIP、安全设置、EFI 或驱动。</p>
<p>首次安装会把本机 Dock 保存在 Originals/25G241/ 或 Originals/25G332/ 下；升级前后的原版备份分开保留，卸载时按当前系统 build 还原本机备份。</p>
<p>OCLP 恢复或重建系统快照可能把 Dock 恢复成 Apple 原版。OCLP 操作完成后，如需继续使用本项目启动台，请重新安装本包。</p>
<p>安装前会检查系统版本和安全设置。本包不会更改 SIP、Authenticated Root、AMFI、EFI 或驱动设置。安装完成后重启生效。</p>
<p>软件包版本为 2427.6.11；Dock 改动继续使用第九版（2427.6.9）。</p>
</body></html>
HTML
cat > "$BUILD/resources/UninstallReadme.html" <<'HTML'
<!doctype html><html lang="zh-CN"><meta charset="utf-8"><body>
<h2>卸载并还原本机 Dock</h2>
<p>支持 Intel / x86_64、macOS 26.7.1（25G241）和 macOS 26.7.2（25G332）。卸载器按当前系统 build 读取对应的本机原版备份。</p>
<p>升级前后的 Dock 备份分别保存在 Originals/25G241/ 和 Originals/25G332/ 下。没有可验证的同 build 本机备份时，卸载器会停止，不会套用其他电脑的 Dock。</p>
<p>还原后重启以从新快照启动。</p>
</body></html>
HTML

cat > "$BUILD/Distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="1">
  <title>LaunchpadRestore 安装完整原生启动台</title>
  <options customize="never" require-scripts="true" hostArchitectures="x86_64"/>
  <readme file="InstallReadme.html"/>
  <choices-outline><line choice="native"/></choices-outline>
  <choice id="native" visible="false">
    <pkg-ref id="com.geekaudio.launchpadrestore.native-entry"/>
  </choice>
  <pkg-ref id="com.geekaudio.launchpadrestore.native-entry"
           version="$PACKAGE_VERSION" onConclusion="RequireRestart">Component.pkg</pkg-ref>
</installer-gui-script>
XML

mkdir -p "$ROOT/pkg"
COMPONENT="$BUILD/Component.pkg"
pkgbuild --root "$BUILD/payload" --scripts "$BUILD/scripts" \
    --ownership recommended --install-location / --identifier com.geekaudio.launchpadrestore.native-entry \
    --version "$PACKAGE_VERSION" "$COMPONENT" >/dev/null

INSTALL="$ROOT/pkg/LaunchpadRestore-Native2427-Install-$PACKAGE_VERSION.pkg"
productbuild --distribution "$BUILD/Distribution.xml" --package-path "$BUILD" \
    --resources "$BUILD/resources" "$INSTALL" >/dev/null
echo "Install package: $INSTALL"
echo "26.7.1 Dock SHA-256: $OLD_CANDIDATE_SHA_ACTUAL"
echo "26.7.2 Dock SHA-256: $NEW_CANDIDATE_SHA"
shasum -a 256 "$INSTALL"

mkdir -p "$BUILD/rollback-scripts"
cp "$ROOT/scripts/postinstall-rollback.sh" "$BUILD/rollback-scripts/postinstall"
cp "$ROOT/scripts/native-package-profile.sh" "$BUILD/rollback-scripts/native-package-profile.sh"
cp "$BUILD/scripts/package-manifest.plist" "$BUILD/rollback-scripts/package-manifest.plist"
chmod 755 "$BUILD/rollback-scripts/postinstall" "$BUILD/rollback-scripts/native-package-profile.sh"
pkgbuild --root "$BUILD/payload" --scripts "$BUILD/rollback-scripts" \
    --ownership recommended --install-location / --identifier com.geekaudio.launchpadrestore.native-entry-rollback \
    --version "$PACKAGE_VERSION" "$BUILD/Rollback.pkg" >/dev/null
cat > "$BUILD/DistributionRollback.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="1">
  <title>LaunchpadRestore 卸载并还原本机 Dock</title>
  <options customize="never" require-scripts="true" hostArchitectures="x86_64"/>
  <readme file="UninstallReadme.html"/>
  <choices-outline><line choice="rollback"/></choices-outline>
  <choice id="rollback" visible="false">
    <pkg-ref id="com.geekaudio.launchpadrestore.native-entry-rollback"/>
  </choice>
  <pkg-ref id="com.geekaudio.launchpadrestore.native-entry-rollback"
           version="$PACKAGE_VERSION" onConclusion="RequireRestart">Rollback.pkg</pkg-ref>
</installer-gui-script>
XML
UNINSTALL="$ROOT/pkg/LaunchpadRestore-Native2427-Uninstall-$PACKAGE_VERSION.pkg"
productbuild --distribution "$BUILD/DistributionRollback.xml" --package-path "$BUILD" \
    --resources "$BUILD/resources" "$UNINSTALL" >/dev/null
echo "Uninstall package: $UNINSTALL"
shasum -a 256 "$UNINSTALL"

DELIVERY="$BUILD/LaunchpadRestore-Native2427-$PACKAGE_VERSION"
mkdir "$DELIVERY"
cp "$INSTALL" "$UNINSTALL" "$DELIVERY/"
cat > "$DELIVERY/使用说明.txt" <<'README'
LaunchpadRestore 完整原生启动台 2427.6.11

支持 Intel / x86_64 的 macOS 26.7.1（25G241）和 macOS 26.7.2（25G332）。安装包包含两套完整 Dock.app，自动按系统 build 选择。

安装：打开文件名含 Install 的 pkg。首次安装会把本机 Dock 备份到 /Library/Application Support/LaunchpadRestore/Originals/25G241/ 或 25G332/。升级前后的原版备份分开保留，卸载时按当前系统 build 还原。

卸载：打开文件名含 Uninstall 的 pkg。它只使用本机同系统 build 的原版备份；缺少有效备份时会停止，不会拿其他电脑的 Dock 还原。

本包不要求预装旧版启动台或 OCLP。OCLP 恢复或重建系统快照可能会恢复 Apple 原版 Dock；完成 OCLP 操作后，如需继续使用本项目启动台，请重新安装本包。

安装或还原完成后重启以从新快照启动。安装器不会更改 SIP、Authenticated Root、AMFI、EFI 或驱动设置。
README
(cd "$DELIVERY" && shasum -a 256 ./*.pkg > SHA256.txt)
ARCHIVE="$ROOT/pkg/LaunchpadRestore-Native2427-Full-$PACKAGE_VERSION.zip"
ditto -c -k --keepParent "$DELIVERY" "$ARCHIVE"
echo "Complete distribution: $ARCHIVE"
shasum -a 256 "$ARCHIVE"
