#!/bin/bash
# Build self-contained native Launchpad install and uninstall packages.
# The Dock patch remains v9; package v10 adds first-install/restore handling.
# Builds packages only; does not install them or change the running Dock.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="/Library/Application Support/LaunchpadRestore/Dock.app.orig"
EXPECTED_SHA="278ed95b86bdef7e122820a0251c5a607fec377c217fae34a651397e8082e193"
PACKAGE_VERSION="2427.6.10"
EXPERIMENT_VERSION="2427.6.9"
SUPPORTED_PRODUCT_VERSION="26.7.1"
SUPPORTED_BUILD_VERSION="25G241"

usage() {
    cat <<'USAGE'
Usage: build-native-entry-pkg.sh [--source /path/to/Dock.app]

Build full Install and Uninstall packages for macOS 26.7.1 (25G241), x86_64.
--source selects the unmodified Apple Dock 2427.6 bundle used during the build.
Without it, the local LaunchpadRestore Dock.app.orig backup is used.
The resulting Install package contains the complete patched Dock bundle and
does not require an old Launchpad, an existing project backup, or OCLP on its
destination. The destination must meet the documented OS and security checks.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --source)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            SOURCE="$2"
            shift 2
            ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# The bundle inventory helper rejects symlink path components (/tmp on macOS).
BUILD="$(mktemp -d /private/tmp/launchpad-native-entry.XXXXXX)"
trap 'rm -rf "$BUILD"' EXIT

[ "$(uname -m)" = "x86_64" ] || { echo "Only the x86_64 candidate is supported" >&2; exit 1; }
[ "$(sw_vers -productVersion)" = "$SUPPORTED_PRODUCT_VERSION" ] || { echo "macOS $SUPPORTED_PRODUCT_VERSION required" >&2; exit 1; }
[ "$(sw_vers -buildVersion)" = "$SUPPORTED_BUILD_VERSION" ] || { echo "macOS build $SUPPORTED_BUILD_VERSION required" >&2; exit 1; }
[ -d "$SOURCE" ] || { echo "Missing source Dock bundle: $SOURCE (use --source /path/to/Dock.app)" >&2; exit 1; }
[ "$(defaults read "$SOURCE/Contents/Info.plist" CFBundleVersion)" = "2427.6" ] || exit 1
SOURCE_SHA="$(shasum -a 256 "$SOURCE/Contents/MacOS/Dock" | awk '{print $1}')"
[ "$SOURCE_SHA" = "$EXPECTED_SHA" ] || { echo "Source Dock hash mismatch" >&2; exit 1; }

mkdir -p "$BUILD/scripts/Dock.app" "$BUILD/payload/Library/Application Support/LaunchpadRestore"
# rsync does not propagate the source bundle's restricted file flags into /tmp.
rsync -rlt "$SOURCE/" "$BUILD/scripts/Dock.app/"
codesign -d --entitlements :- "$SOURCE" > "$BUILD/entitlements.plist" 2>/dev/null
plutil -lint "$BUILD/entitlements.plist" >/dev/null
lipo -thin x86_64 "$BUILD/scripts/Dock.app/Contents/MacOS/Dock" -output "$BUILD/Dock.x86_64"

/usr/bin/python3 - "$BUILD/Dock.x86_64" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
data = bytearray(path.read_bytes())
# Dock 2427.6 x86_64: feature route at VM 0x1002d7b00, file offset 0x2d7b00.
offset = 0x2D7B00
expected = bytes.fromhex("554889e5b0015dc3")  # mov al, 1
if data[offset:offset + len(expected)] != expected:
    raise SystemExit("Unexpected Springboard route bytes")
data[offset + 5] = 0  # mov al, 0: use retained native Springboard path

# v9 keeps the original display/scale callbacks and animation implementation.
# The installer configures the Dock application's CAEnableMetalWhippet
# preference before the next Dock launch; no driver or framework is patched.

# Dock 2427.6 still contains LPSpringboard and the old display methods, but
# unlike 2419 it does not construct the global LPSpringboard instance at startup.
# After the normal Spotlight object is initialized, create LPSpringboard with
# the same Dock environment already held in rbx. The additional code lives in
# unused executable __TEXT padding between __eh_frame and __DATA_CONST.
image_base = 0x100000000
hook = 0x100058885
resume = 0x10005888C
cave = 0x1003F9300
lpspringboard_class = 0x1004760E0
init_with_environment_selref = 0x10046A720
springboard_global = 0x1004972E8
objc_alloc_with_zone = 0x10035FD0A
objc_msg_send = 0x10035FD76
original = bytes.fromhex("498b45004885c0")  # mov rax,[r13]; test rax,rax
if data[hook - image_base:resume - image_base] != original:
    raise SystemExit("Unexpected Dock startup bytes")
if any(data[cave - image_base:cave - image_base + 96]):
    raise SystemExit("Dock executable padding is not empty")

code = bytearray()
def rel32(target: int, instruction_size: int) -> bytes:
    next_pc = cave + len(code) + instruction_size
    return (target - next_pc).to_bytes(4, "little", signed=True)

def lea_rdi(target: int) -> None:
    code.extend(b"\x48\x8d\x3d" + rel32(target, 7))

def mov_rsi_ref(target: int) -> None:
    code.extend(b"\x48\x8b\x35" + rel32(target, 7))

def lea_rcx(target: int) -> None:
    code.extend(b"\x48\x8d\x0d" + rel32(target, 7))

def call(target: int) -> None:
    code.extend(b"\xe8" + rel32(target, 5))

lea_rdi(lpspringboard_class)
call(objc_alloc_with_zone)
mov_rsi_ref(init_with_environment_selref)
code.extend(bytes.fromhex("4889c74889da"))  # rdi = allocated object; rdx = environment
call(objc_msg_send)
lea_rcx(springboard_global)
code.extend(bytes.fromhex("488b3948890141ffd6"))  # replace global; release previous value
code.extend(original)
code.extend(b"\xe9" + rel32(resume, 5))
if len(code) > 96:
    raise SystemExit("Startup trampoline exceeds reserved padding")
data[cave - image_base:cave - image_base + len(code)] = code
data[hook - image_base:resume - image_base] = b"\xe9" + (
    cave - (hook + 5)).to_bytes(4, "little", signed=True) + b"\x90\x90"
path.write_bytes(data)
PY

cp "$BUILD/Dock.x86_64" "$BUILD/scripts/Dock.app/Contents/MacOS/Dock"
plutil -insert LPRNativeExperimentVersion -string "$EXPERIMENT_VERSION" \
    "$BUILD/scripts/Dock.app/Contents/Info.plist"
codesign --force --sign - --timestamp=none \
    --entitlements "$BUILD/entitlements.plist" "$BUILD/scripts/Dock.app" >/dev/null
codesign --verify --strict "$BUILD/scripts/Dock.app"
CANDIDATE_SHA="$(shasum -a 256 "$BUILD/scripts/Dock.app/Contents/MacOS/Dock" | awk '{print $1}')"

# Kept beside postinstall so target validation uses the exact bundled candidate.
# No paths or backups from the build machine are transferred to the target.
/usr/bin/python3 - "$BUILD/scripts/package-manifest.plist" "$PACKAGE_VERSION" \
    "$EXPERIMENT_VERSION" "$SUPPORTED_PRODUCT_VERSION" "$SUPPORTED_BUILD_VERSION" \
    "$EXPECTED_SHA" "$CANDIDATE_SHA" <<'PY'
import plistlib
import sys
from pathlib import Path

path, package, experiment, product, build, stock_hash, candidate_hash = sys.argv[1:]
manifest = {
    "FormatVersion": 1,
    "PackageVersion": package,
    "DockVersion": "2427.6",
    "DockExperimentVersion": experiment,
    "SupportedProductVersion": product,
    "SupportedBuildVersion": build,
    "SupportedArchitecture": "x86_64",
    "StockSourceSHA256": stock_hash,
    "CandidateSHA256": candidate_hash,
}
Path(path).write_bytes(plistlib.dumps(manifest, sort_keys=False))
PY

cp "$ROOT/scripts/postinstall-native-entry.sh" "$BUILD/scripts/postinstall"
chmod 755 "$BUILD/scripts/postinstall"
cat > "$BUILD/payload/Library/Application Support/LaunchpadRestore/native-entry-readme.txt" <<'README'
LaunchpadRestore — complete native Launchpad package 2427.6.10

Supported destination: Intel/x86_64, macOS 26.7.1, build 25G241 only.
Contains the complete patched Dock 2427.6 bundle and the preference helper.
The Dock patch and software bitmap rendering setting remain v9 (2427.6.9).
OCLP, an old Launchpad, and a pre-existing LaunchpadRestore backup are not
prerequisites. System volume security requirements are checked by the installer.

On first installation, the installer saves this destination's own original Dock
to /Library/Application Support/LaunchpadRestore/Dock.app.orig. Keep that backup.
The Install package is used to enable Launchpad. The Uninstall package is used
to restore this destination's saved Dock and the saved rendering preferences.
Uninstall cannot restore a machine that has no valid local original backup.
Neither package includes an original backup borrowed from the build machine.

Installation prepares the next boot snapshot. Restart when ready.
README

# A separate user-scoped preference helper preserves both original host scopes
# so rollback can restore the exact prior setting without replacing Dock prefs.
xcrun clang -arch x86_64 -O2 -Wall -Wextra -Werror -fobjc-arc \
    -framework Foundation -framework CoreFoundation "$ROOT/native/ca-render-backend.m" \
    -o "$BUILD/payload/Library/Application Support/LaunchpadRestore/ca-render-backend"
codesign --force --sign - --timestamp=none \
    "$BUILD/payload/Library/Application Support/LaunchpadRestore/ca-render-backend" >/dev/null

# Inventory the complete bundle and bind target-created original backups to the
# target machine. Both Install and Uninstall carry the same signed helper.
xcrun clang -arch x86_64 -O2 -Wall -Wextra -Werror -fobjc-arc \
    -framework Foundation -framework IOKit "$ROOT/native/dock-bundle-state.m" \
    -o "$BUILD/payload/Library/Application Support/LaunchpadRestore/dock-bundle-state"
codesign --force --sign - --timestamp=none \
    "$BUILD/payload/Library/Application Support/LaunchpadRestore/dock-bundle-state" >/dev/null
"$BUILD/payload/Library/Application Support/LaunchpadRestore/dock-bundle-state" \
    --inventory "$BUILD/scripts/Dock.app" > "$BUILD/bundle-inventory.json"
/usr/bin/python3 - "$BUILD/bundle-inventory.json" "$BUILD/scripts/bundle-inventory.plist" <<'PY'
import json
import plistlib
import sys
from pathlib import Path

source, destination = map(Path, sys.argv[1:])
inventory = json.loads(source.read_text())
destination.write_bytes(plistlib.dumps(inventory, sort_keys=False))
PY
"$BUILD/payload/Library/Application Support/LaunchpadRestore/dock-bundle-state" \
    --verify-bundle "$BUILD/scripts/Dock.app" "$BUILD/scripts/bundle-inventory.plist"

mkdir -p "$ROOT/pkg"
pkgbuild --root "$BUILD/payload" --scripts "$BUILD/scripts" \
    --ownership recommended --install-location / --identifier com.geekaudio.launchpadrestore.native-entry \
    --version "$PACKAGE_VERSION" "$BUILD/Component.pkg" >/dev/null

mkdir -p "$BUILD/resources"
cat > "$BUILD/resources/InstallReadme.html" <<'HTML'
<!doctype html><html lang="zh-CN"><meta charset="utf-8"><body>
<h2>安装完整原生启动台</h2>
<p>仅支持 Intel / x86_64、macOS 26.7.1（25G241）。安装前会检查系统版本及系统卷的安全设置。</p>
<p>需要已关闭 Authenticated Root，并具备运行修改后系统程序的代码签名策略。本包不会自动更改 SIP、AMFI 或 EFI；普通 Mac 默认安全配置不能直接安装此系统 Dock 版本。</p>
<p>此包携带完整 Dock.app 和渲染设置助手。目标电脑不需要预装旧版启动台、OCLP 或本项目的原版备份。</p>
<p>首次安装会自动备份目标电脑自己的 Dock。请保留此备份；之后的卸载还原依赖它。</p>
<p>安装启动台请选择 Install 包。Uninstall 包仅用于还原本机备份；打开“还原本机原版 Dock”包时的失败不代表 Install 安装结果。</p>
<p>软件包版本为 2427.6.10，启动台代码与已验证的第九版 2427.6.9 相同，保留原生交互动画及软件位图渲染修复。</p>
<p>安装完成后由你选择何时重启。</p>
</body></html>
HTML
cat > "$BUILD/resources/UninstallReadme.html" <<'HTML'
<!doctype html><html lang="zh-CN"><meta charset="utf-8"><body>
<h2>卸载启动台并还原本机 Dock</h2>
<p>这是还原包，使用这台电脑首次安装时保存的原版 Dock 和渲染设置备份。</p>
<p>它不提供通用原版 Dock。没有有效本机备份时会停止并说明原因；请使用 Install 包安装启动台。</p>
<p>仅支持 Intel / x86_64、macOS 26.7.1（25G241）。还原完成后由你选择何时重启。</p>
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

OUTPUT="$ROOT/pkg/LaunchpadRestore-Native2427-Install-$PACKAGE_VERSION.pkg"
productbuild --distribution "$BUILD/Distribution.xml" --package-path "$BUILD" \
    --resources "$BUILD/resources" "$OUTPUT" >/dev/null
cp "$OUTPUT" "$ROOT/pkg/LaunchpadRestore-Native2427-Install.pkg"
echo "Install package: $OUTPUT"
echo "Bundled Dock SHA-256: $CANDIDATE_SHA"
shasum -a 256 "$OUTPUT"

mkdir -p "$BUILD/rollback-scripts"
cp "$ROOT/scripts/postinstall-rollback.sh" "$BUILD/rollback-scripts/postinstall"
cp "$BUILD/scripts/package-manifest.plist" "$BUILD/rollback-scripts/package-manifest.plist"
chmod 755 "$BUILD/rollback-scripts/postinstall"
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
ROLLBACK="$ROOT/pkg/LaunchpadRestore-Native2427-Uninstall-$PACKAGE_VERSION.pkg"
productbuild --distribution "$BUILD/DistributionRollback.xml" --package-path "$BUILD" \
    --resources "$BUILD/resources" "$ROLLBACK" >/dev/null
cp "$ROLLBACK" "$ROOT/pkg/LaunchpadRestore-Native2427-Uninstall.pkg"
echo "Uninstall package: $ROLLBACK"
shasum -a 256 "$ROLLBACK"

DELIVERY="$BUILD/LaunchpadRestore-Native2427-$PACKAGE_VERSION"
mkdir "$DELIVERY"
cp "$OUTPUT" "$ROLLBACK" "$DELIVERY/"
cat > "$DELIVERY/使用说明.txt" <<'README'
LaunchpadRestore 完整原生启动台 2427.6.10

支持范围：Intel / x86_64、macOS 26.7.1、build 25G241。
系统须已关闭 Authenticated Root，并允许运行重新签名的系统程序。
安装器不会修改 SIP、AMFI、EFI 或驱动。

1. 安装启动台：打开文件名含 Install 的 pkg。
   包内自带完整 Dock、资源、插件和辅助程序；不需要目标电脑预装旧启动台或 OCLP。
   首次安装会备份目标电脑自己的 Dock，再准备下次启动快照。
2. 安装完成后，由你选择何时重启。
3. 卸载还原：打开文件名含 Uninstall 的 pkg。
   它使用这台电脑安装前的备份；没有有效本机备份时无法还原。

请保留 /Library/Application Support/LaunchpadRestore/Dock.app.orig
及同目录 Dock.app.orig.manifest.plist，不要拿另一台电脑的备份覆盖它们。
包内没有分发构建电脑的原始备份。

本次完善完整打包、首次备份和还原校验。
Dock 主程序与第九版相同，保留本机已验证的分辨率切换修复。
尚未在另一台无 OCLP 的电脑上实际安装验证。
开机首次打开时短暂空白图标的问题尚未确认修复。

安装日志：/var/log/launchpadrestore.log
README
(cd "$DELIVERY" && shasum -a 256 ./*.pkg > SHA256.txt)
ARCHIVE="$ROOT/pkg/LaunchpadRestore-Native2427-Full-$PACKAGE_VERSION.zip"
ditto -c -k --keepParent "$DELIVERY" "$ARCHIVE"
echo "Complete distribution: $ARCHIVE"
shasum -a 256 "$ARCHIVE"
