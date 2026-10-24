#!/bin/bash
# 还原：把 Dock.app 换回原版（安装时自动备份的版本）
# 由 Installer 以 root 执行；日志 /var/log/launchpadrestore.log

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PACKAGE_MANIFEST="$SCRIPT_DIR/package-manifest.plist"
BACKUP_DIR="/Library/Application Support/LaunchpadRestore"
ORIG_DOCK="$BACKUP_DIR/Dock.app.orig"
BACKUP_MANIFEST="$BACKUP_DIR/Dock.app.orig.manifest.plist"
BUNDLE_STATE_HELPER="$BACKUP_DIR/dock-bundle-state"
MNT="/System/Volumes/Update/LaunchpadRestore-Rollback-$$"
LOCK_DIR="/var/run/launchpadrestore.lock"
LOG="/var/log/launchpadrestore.log"
MOUNTED=0
MOUNT_POINT_CREATED=0
LOCK_HELD=0
SWAP_ACTIVE=0
SNAPSHOT_CREATED=0

exec >>"$LOG" 2>&1
echo "===== $(date '+%Y-%m-%d %H:%M:%S') 还原开始 ====="

fail() { echo "失败: $*"; echo "===== 中止 ====="; exit 1; }

restore_previous() {
    [ "$SWAP_ACTIVE" = 1 ] || return 0
    if [ ! -d "$PREVIOUS" ]; then
        [ -d "$TARGET" ] || return 1
        SWAP_ACTIVE=0
        return 0
    fi
    if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
        [ ! -e "$STAGED" ] && [ ! -L "$STAGED" ] || return 1
        mv "$TARGET" "$STAGED" || return 1
    fi
    mv "$PREVIOUS" "$TARGET" || return 1
    SWAP_ACTIVE=0
    rm -rf "$STAGED"
    return 0
}

cleanup_mount() {
    [ "$MOUNTED" = 1 ] || return 0
    if umount "$MNT" 2>/dev/null || umount -f "$MNT" 2>/dev/null; then
        MOUNTED=0
    else
        echo "提示: 无法卸载本次使用的系统卷挂载点: $MNT"
    fi
}

cleanup_all() {
    if [ "$SWAP_ACTIVE" = 1 ] && [ "$SNAPSHOT_CREATED" = 0 ]; then
        if restore_previous; then
            echo "退出前已恢复系统卷安装前 Dock"
        else
            echo "失败: 退出前未能恢复系统卷；保留 $PREVIOUS 与 $STAGED 供恢复"
        fi
    fi
    cleanup_mount
    if [ "$MOUNT_POINT_CREATED" = 1 ] && [ "$MOUNTED" = 0 ]; then
        rmdir "$MNT" 2>/dev/null || true
    fi
    [ "$LOCK_HELD" = 0 ] || rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup_all EXIT
trap 'exit 1' HUP INT TERM
[ "$(id -u)" = 0 ] || fail "安装器必须以 root 运行"
[ "${3:-/}" = / ] || fail "只支持还原当前启动系统"
if [ -f "$PACKAGE_MANIFEST" ]; then
    package_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$PACKAGE_MANIFEST" 2>/dev/null; }
    [ "$(package_value FormatVersion)" = 1 ] || fail "卸载包清单格式不受支持"
    [ "$(sw_vers -productVersion)" = "$(package_value SupportedProductVersion)" ] \
        && [ "$(sw_vers -buildVersion)" = "$(package_value SupportedBuildVersion)" ] \
        && [ "$(uname -m)" = "$(package_value SupportedArchitecture)" ] \
        || fail "此卸载包不支持当前系统版本、build 或架构"
fi
mkdir "$LOCK_DIR" 2>/dev/null || fail "另一个 LaunchpadRestore 安装或还原操作正在运行: $LOCK_DIR"
LOCK_HELD=1

if [ ! -d "$ORIG_DOCK" ] || [ -L "$ORIG_DOCK" ]; then
    fail "找不到原版备份: $ORIG_DOCK（可能从未安装过，或备份已被删除）"
fi
ORIG_EXEC="$ORIG_DOCK/Contents/MacOS/Dock"
ORIG_INFO="$ORIG_DOCK/Contents/Info.plist"
[ -f "$ORIG_EXEC" ] && [ -f "$ORIG_INFO" ] || fail "原版备份不完整"
[ ! -L "$ORIG_EXEC" ] && [ ! -L "$ORIG_INFO" ] || fail "原版备份的主程序或 Info.plist 是符号链接"
SIGNING_INFO="$(codesign -dv --verbose=3 "$ORIG_DOCK" 2>&1)" || fail "无法读取原版备份签名"
echo "$SIGNING_INFO" | grep -qx 'Identifier=com.apple.dock' || fail "原版备份标识不是 com.apple.dock"
# Some genuine Apple Dock bundles use a legacy resource envelope. --strict
# rejects those bundles even when their signature is valid. The manifest below
# independently binds the executable and Info.plist to the target's backup.
codesign --verify --deep --no-strict "$ORIG_DOCK" || fail "原版备份签名或资源不完整"

plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null; }
OS_VERSION="$(sw_vers -productVersion)"
OS_BUILD="$(sw_vers -buildVersion)"
ARCH="$(uname -m)"
ORIG_SHA="$(shasum -a 256 "$ORIG_EXEC" | awk '{print $1}')"
ORIG_INFO_SHA="$(shasum -a 256 "$ORIG_INFO" | awk '{print $1}')"
ORIG_VERSION="$(plist_value "$ORIG_INFO" CFBundleVersion)"

if [ -e "$BACKUP_MANIFEST" ] || [ -L "$BACKUP_MANIFEST" ]; then
    [ -f "$BACKUP_MANIFEST" ] && [ ! -L "$BACKUP_MANIFEST" ] || fail "原版备份清单不是普通文件"
    [ "$(stat -f%u "$BACKUP_MANIFEST")" = 0 ] || fail "原版备份清单不属于 root"
    # A manifest is local installation state, never a payload supplied by a
    # different computer. Bind it to the stable APFS system/data volume group;
    # the root snapshot UUID changes each time bless creates a snapshot.
    plutil -lint "$BACKUP_MANIFEST" >/dev/null || fail "原版备份清单损坏"
    [ "$(plist_value "$BACKUP_MANIFEST" FormatVersion)" = 1 ] || fail "原版备份清单格式不受支持"
    [ "$(plist_value "$BACKUP_MANIFEST" OSProductVersion)" = "$OS_VERSION" ] \
        || fail "备份 macOS 版本与当前系统不匹配，拒绝跨系统还原"
    [ "$(plist_value "$BACKUP_MANIFEST" OSBuildVersion)" = "$OS_BUILD" ] \
        || fail "备份系统 build 与当前系统不匹配，拒绝跨系统还原"
    [ "$(plist_value "$BACKUP_MANIFEST" Architecture)" = "$ARCH" ] \
        || fail "备份架构与当前系统不匹配"
    HARDWARE_UUID="$(ioreg -rd1 -c IOPlatformExpertDevice | awk -F '\"' '/\"IOPlatformUUID\"/ {print $(NF-1); exit}')"
    [ -n "$HARDWARE_UUID" ] && [ "$(plist_value "$BACKUP_MANIFEST" HardwareUUID)" = "$HARDWARE_UUID" ] \
        || fail "备份不属于当前电脑，拒绝使用其他电脑的 Dock 作为本机回滚"
    VOLUME_GROUP="$(diskutil info -plist / | plutil -extract APFSVolumeGroupID raw - 2>/dev/null)"
    [ -n "$VOLUME_GROUP" ] && [ "$(plist_value "$BACKUP_MANIFEST" APFSVolumeGroupUUID)" = "$VOLUME_GROUP" ] \
        || fail "备份不属于当前 APFS 系统卷组，拒绝使用其他系统的 Dock 作为本机回滚"
    [ "$(plist_value "$BACKUP_MANIFEST" DockBundleVersion)" = "$ORIG_VERSION" ] \
        || fail "备份 Dock 版本与本机备份清单不匹配"
    [ "$(plist_value "$BACKUP_MANIFEST" DockExecutableSHA256)" = "$ORIG_SHA" ] \
        || fail "备份 Dock 主程序 SHA-256 与本机备份清单不匹配"
    [ "$(plist_value "$BACKUP_MANIFEST" DockInfoPlistSHA256)" = "$ORIG_INFO_SHA" ] \
        || fail "备份 Dock Info.plist SHA-256 与本机备份清单不匹配"
    [ -x "$BUNDLE_STATE_HELPER" ] && [ ! -L "$BUNDLE_STATE_HELPER" ] \
        || fail "缺少本机备份完整性校验工具，请先重新安装完整安装包"
    codesign --verify --strict "$BUNDLE_STATE_HELPER" || fail "本机备份完整性校验工具签名无效"
    "$BUNDLE_STATE_HELPER" --verify "$ORIG_DOCK" "$BACKUP_MANIFEST" \
        || fail "本机备份文件、资源或目录与备份清单不一致"
    echo "本机原版备份清单校验通过: macOS $OS_VERSION ($OS_BUILD), $ARCH"
else
    # Older releases did not record a manifest. Keep their existing rollback
    # available only for the exact original Apple binary this project shipped
    # against. DTSDKName records the SDK used to build an app, not the installed
    # OS build, so it is not a safe compatibility or provenance check.
    [ "$OS_VERSION" = 26.7.1 ] && [ "$OS_BUILD" = 25G241 ] && [ "$ARCH" = x86_64 ] \
        || fail "旧备份没有本机清单，且当前系统不在已确认的旧包回滚范围内"
    [ "$ORIG_VERSION" = 2427.6 ] \
        && [ "$ORIG_SHA" = 278ed95b86bdef7e122820a0251c5a607fec377c217fae34a651397e8082e193 ] \
        && [ "$ORIG_INFO_SHA" = df5a816eb4136b81c281ecbc4fe910cf82fbc572268219ae950c569a3ac5c2ab ] \
        || fail "旧备份没有本机清单，且不匹配已确认的原版 Dock，拒绝还原"
    echo "$SIGNING_INFO" | grep -qx 'Authority=Apple Root CA' || fail "旧版备份缺少 Apple 签名链"
    echo "旧包原版备份通过固定 SHA-256 校验: macOS $OS_VERSION ($OS_BUILD), $ARCH"
fi
lipo -verify_arch "$ARCH" "$ORIG_EXEC" || fail "原版备份不包含当前系统架构"

echo "备份版本: $ORIG_VERSION"
echo "备份 Dock SHA-256: $ORIG_SHA"

# 定位系统卷
DEV="$(diskutil info -plist / | plutil -extract DeviceIdentifier raw - 2>/dev/null)"
if [[ "$DEV" =~ ^(disk[0-9]+s[0-9]+)s[0-9]+$ ]]; then
    ROOTDEV="${BASH_REMATCH[1]}"
else
    ROOTDEV="$DEV"
fi
[[ "$ROOTDEV" =~ ^disk[0-9]+s[0-9]+$ ]] || fail "无法识别当前 APFS 系统卷设备: $DEV"
echo "根卷: /dev/$ROOTDEV"

mkdir "$MNT" || fail "无法建立系统卷挂载点"
MOUNT_POINT_CREATED=1
mount -o nobrowse -t apfs "/dev/$ROOTDEV" "$MNT" || fail "挂载失败"
MOUNTED=1

TARGET="$MNT/System/Library/CoreServices/Dock.app"
STAGED="$TARGET.restore-$$"
PREVIOUS="$TARGET.previous-$$"
[ -d "$TARGET" ] && [ ! -L "$TARGET" ] || fail "系统卷中的 Dock.app 缺失或不是普通目录"
[ ! -e "$STAGED" ] && [ ! -L "$STAGED" ] && [ ! -e "$PREVIOUS" ] && [ ! -L "$PREVIOUS" ] \
    || fail "还原暂存目录已存在，拒绝覆盖"
if ! ditto "$ORIG_DOCK" "$STAGED"; then
    rm -rf "$STAGED"
    fail "暂存原版 Dock 失败"
fi
if ! chown -R root:wheel "$STAGED" || ! chmod -R 755 "$STAGED" \
        || ! codesign --verify --deep --no-strict "$STAGED" \
        || [ "$(shasum -a 256 "$STAGED/Contents/MacOS/Dock" | awk '{print $1}')" != "$ORIG_SHA" ] \
        || [ "$(shasum -a 256 "$STAGED/Contents/Info.plist" | awk '{print $1}')" != "$ORIG_INFO_SHA" ]; then
    rm -rf "$STAGED"
    fail "暂存原版 Dock 完整性校验失败"
fi
if [ -f "$BACKUP_MANIFEST" ] && ! "$BUNDLE_STATE_HELPER" --verify "$STAGED" "$BACKUP_MANIFEST"; then
    rm -rf "$STAGED"
    fail "暂存原版 Dock 文件库存与本机备份清单不一致"
fi
SWAP_ACTIVE=1
if ! mv "$TARGET" "$PREVIOUS"; then
    rm -rf "$STAGED"
    fail "无法保留系统卷当前 Dock，未执行替换"
fi
if ! mv "$STAGED" "$TARGET"; then
    if restore_previous; then
        fail "切换 Dock 失败，系统卷已恢复安装前版本"
    fi
    fail "切换 Dock 且恢复安装前版本失败；原文件保留于 $PREVIOUS，暂存文件保留于 $STAGED，当前启动快照未变"
fi
echo "已还原为版本: $(defaults read "$TARGET/Contents/Info.plist" CFBundleVersion 2>/dev/null)"

if ! bless --mount "$MNT" --bootefi --create-snapshot; then
    if restore_previous; then
        fail "快照重建未报告成功，系统卷已恢复安装前版本"
    fi
    fail "快照重建失败且未能自动恢复系统卷；原文件保留于 $PREVIOUS，还原文件可能保留于 $STAGED"
fi
SNAPSHOT_CREATED=1
SWAP_ACTIVE=0
rm -rf "$PREVIOUS" || echo "提示: 快照已创建，但未能移除安装前的临时副本: $PREVIOUS"
echo "快照已重建"

cleanup_mount

# 只删除本项目写入的 SpotlightPlus 键，保留用户或其他软件的配置。
if defaults delete /Library/Preferences/FeatureFlags/Domain/SpotlightUI.plist SpotlightPlus 2>/dev/null; then
    echo "SpotlightPlus FeatureFlag 已删除"
else
    echo "SpotlightPlus FeatureFlag 不存在，跳过"
fi

# 移除图标自检 agent —— 它是给 Dock 2419 用的，原版 Dock 不需要
AGENT="/Library/LaunchAgents/com.geekaudio.launchpadiconfix.plist"
if [ -f "$AGENT" ]; then
    CU="$(stat -f%Su /dev/console 2>/dev/null)"
    if [ -n "$CU" ] && [ "$CU" != "root" ]; then
        UID_N="$(id -u "$CU" 2>/dev/null)"
        launchctl asuser "$UID_N" launchctl bootout "gui/$UID_N/com.geekaudio.launchpadiconfix" 2>/dev/null
    fi
    rm -f "$AGENT"
    echo "图标自检 agent 已移除"
fi
rm -f "$BACKUP_DIR/fix-launchpad-icon.sh"

# Restore only this experiment's CA preference, including whether each scope
# originally had a value. Other Dock preferences and user layouts are retained.
RASTER_HELPER="$BACKUP_DIR/ca-render-backend"
if [ -x "$RASTER_HELPER" ]; then
    while IFS= read -r RASTER_ACCOUNT; do
        RASTER_HOME="$(dscl . -read "/Users/$RASTER_ACCOUNT" NFSHomeDirectory 2>/dev/null | sed 's/^NFSHomeDirectory: //')"
        [[ "$RASTER_HOME" = /* ]] || continue
        RASTER_STATE="$RASTER_HOME/Library/Application Support/LaunchpadRestore/RenderBackend/original.plist"
        [ -f "$RASTER_STATE" ] || continue
        RASTER_UID="$(stat -f%u "$RASTER_STATE")"
        RASTER_USER="$(id -nu "$RASTER_UID" 2>/dev/null)"
        [ -n "$RASTER_USER" ] && [ "$RASTER_UID" != 0 ] || continue
        if launchctl asuser "$RASTER_UID" /usr/bin/sudo -H -u "$RASTER_USER" \
                "$RASTER_HELPER" --restore "$RASTER_STATE"; then
            echo "已恢复 $RASTER_USER 的原始 Dock 位图后端设置"
        else
            fail "原版 Dock 快照已创建；$RASTER_USER 的位图后端设置未能恢复，原值备份仍保留"
        fi
    done < <(dscl . -list /Users)
fi

echo "===== 还原完成，重启后生效 ====="
exit 0
