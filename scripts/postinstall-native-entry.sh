#!/bin/bash
# Install the complete native Dock bundle; back up this target Mac on first use.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
NEW_DOCK="$SCRIPT_DIR/Dock.app"
ORIGINAL="/Library/Application Support/LaunchpadRestore/Dock.app.orig"
BACKUP_DIR="/Library/Application Support/LaunchpadRestore"
BACKUP_MANIFEST="$ORIGINAL.manifest.plist"
PACKAGE_MANIFEST="$SCRIPT_DIR/package-manifest.plist"
BUNDLE_INVENTORY="$SCRIPT_DIR/bundle-inventory.plist"
CURRENT="/System/Library/CoreServices/Dock.app"
EXPECTED_SHA="278ed95b86bdef7e122820a0251c5a607fec377c217fae34a651397e8082e193"
FIRST_EXPERIMENT_SHA="210926c10070447338e6dfa768992e9d97f607ef62764ef2093031a90d71cff6"
SECOND_EXPERIMENT_SHA="961788046953c7fe0ae13b66efafeb6596aa63c1e88aab5923af02cd6590767f"
FOURTH_EXPERIMENT_SHA="40fa542b81369a905d6fbb07bcd72be4052cf043215833a7ca48e90d6a9d82b1"
FIFTH_EXPERIMENT_SHA="84f364ee4dc3843690050e87fab167eda2ab5c0db4160c1f36d9950cd69ca591"
SIXTH_EXPERIMENT_SHA="679d54571bfa71448c6807c51befa7a28659c1b1ddf4c17a26051a6099d72c96"
SEVENTH_EXPERIMENT_SHA="d8abe59f75dfa6e7163d5883f5db633630cf474959bd4d375cb3fd9791b1e8ea"
EIGHTH_EXPERIMENT_SHA="01b7dfc025e4de48d1294b01f1139ebf76c8c6393e36e0167f77f625bae0b770"
NINTH_EXPERIMENT_SHA="ee0e2448782b753eee37eb156ce97fb10e2c49dc39464a9a58d5da42426fe8ef"
RASTER_HELPER="/Library/Application Support/LaunchpadRestore/ca-render-backend"
BUNDLE_HELPER="$BACKUP_DIR/dock-bundle-state"
MNT="/System/Volumes/Update/LaunchpadRestore-Install-$$"
LOCK="/var/run/launchpadrestore.lock"
LOG="/var/log/launchpadrestore.log"

exec >>"$LOG" 2>&1
echo "===== $(date '+%Y-%m-%d %H:%M:%S') 完整原生启动台安装开始 ====="
fail() { echo "失败: $*"; exit 1; }
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null; }
MOUNTED=0
HAVE_LOCK=0
SWAP_ACTIVE=0
SNAPSHOT_CREATED=0
RASTER_TOUCHED=0
STAGED=""
PREVIOUS=""
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
}
cleanup() {
    if [ "$SNAPSHOT_CREATED" = 0 ]; then
        if ! restore_previous; then
            echo "未能自动恢复系统卷，保留安装前副本: $PREVIOUS"
        fi
        if [ "$RASTER_TOUCHED" = 1 ]; then
            restore_attempt_raster_state
        fi
        if [ "$SWAP_ACTIVE" = 0 ] && [ -n "$STAGED" ] && [ -d "$STAGED" ]; then
            rm -rf "$STAGED"
        fi
    fi
    if [ "$MOUNTED" = 1 ]; then
        umount "$MNT" 2>/dev/null || umount -f "$MNT" 2>/dev/null || true
    fi
    rmdir "$MNT" 2>/dev/null || true
    [ "$HAVE_LOCK" = 0 ] || rmdir "$LOCK" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

[ "$(id -u)" = 0 ] || fail "安装器必须以 root 运行"
[ "${3:-/}" = / ] || fail "只支持安装到当前启动系统"
mkdir "$LOCK" 2>/dev/null || fail "另一个安装或还原任务正在运行"
HAVE_LOCK=1
[ -f "$PACKAGE_MANIFEST" ] || fail "安装包清单缺失，请重新获取完整安装包"
[ "$(plist "$PACKAGE_MANIFEST" FormatVersion)" = 1 ] || fail "安装包清单版本不支持"
[ "$(sw_vers -productVersion)" = "$(plist "$PACKAGE_MANIFEST" SupportedProductVersion)" ] \
    || fail "系统版本不在此完整包支持范围内"
[ "$(sw_vers -buildVersion)" = "$(plist "$PACKAGE_MANIFEST" SupportedBuildVersion)" ] \
    || fail "系统 build 不在此完整包支持范围内"
[ "$(uname -m)" = "$(plist "$PACKAGE_MANIFEST" SupportedArchitecture)" ] \
    || fail "机器架构不在此完整包支持范围内"
csrutil authenticated-root status 2>/dev/null | grep -q 'disabled' \
    || fail "Authenticated Root 仍启用，当前系统不允许替换 Dock；完整包不会更改系统安全配置"

[ "$(sw_vers -productVersion)" = "26.7.1" ] || fail "系统版本不是 26.7.1"
[ "$(uname -m)" = "x86_64" ] || fail "机器架构不是 x86_64"
[ -d "$NEW_DOCK" ] || fail "安装包内完整 Dock.app 缺失"
[ "$(defaults read "$CURRENT/Contents/Info.plist" CFBundleVersion 2>/dev/null)" = "2427.6" ] \
    || fail "当前 Dock 版本不是 2427.6"
CURRENT_SHA="$(shasum -a 256 "$CURRENT/Contents/MacOS/Dock" | awk '{print $1}')"
NEW_SHA="$(shasum -a 256 "$NEW_DOCK/Contents/MacOS/Dock" | awk '{print $1}')"
[ "$NEW_SHA" = "$(plist "$PACKAGE_MANIFEST" CandidateSHA256)" ] || fail "包内 Dock 哈希与清单不符"
[ "$(plist "$PACKAGE_MANIFEST" StockSourceSHA256)" = "$EXPECTED_SHA" ] || fail "包内源版本标识不符"
codesign --verify --strict "$NEW_DOCK" || fail "候选 Dock 签名验证失败"
codesign --verify --strict "$RASTER_HELPER" || fail "位图后端配置工具缺失或签名不完整"
codesign --verify --strict "$BUNDLE_HELPER" || fail "完整备份工具缺失或签名不完整"
[ -f "$BUNDLE_INVENTORY" ] || fail "完整 Dock 文件库存清单缺失"
"$BUNDLE_HELPER" --verify-bundle "$NEW_DOCK" "$BUNDLE_INVENTORY" \
    || fail "包内完整 Dock 文件或资源与清单不符"

KNOWN_MODIFIED=0
case "$CURRENT_SHA" in
    "$FIRST_EXPERIMENT_SHA"|"$SECOND_EXPERIMENT_SHA"|"$FOURTH_EXPERIMENT_SHA"|"$FIFTH_EXPERIMENT_SHA"|"$SIXTH_EXPERIMENT_SHA"|"$SEVENTH_EXPERIMENT_SHA"|"$EIGHTH_EXPERIMENT_SHA"|"$NINTH_EXPERIMENT_SHA"|"$NEW_SHA") KNOWN_MODIFIED=1 ;;
esac
if [ "$KNOWN_MODIFIED" = 0 ]; then
    codesign --verify --deep --no-strict -R='anchor apple' "$CURRENT" \
        || fail "目标 Dock 不是可验证的原版或已知项目版本"
fi

CU="$(stat -f%Su /dev/console 2>/dev/null)"
[[ -n "$CU" && "$CU" != root && "$CU" != loginwindow && "$CU" != _mbsetupuser ]] \
    || fail "请在目标用户的桌面登录后安装"
USER_UID="$(id -u "$CU")" || fail "无法读取桌面用户 UID"
USER_HOME="$(dscl . -read "/Users/$CU" NFSHomeDirectory | sed 's/^NFSHomeDirectory: //')"
[[ "$USER_HOME" = /* && -d "$USER_HOME" ]] || fail "无法读取桌面用户目录"

# Package contents supply Launchpad. A fresh target only needs its normal system
# Dock: preserve that exact bundle here, without expecting a preinstalled port.
[ ! -L "$BACKUP_DIR" ] && [ ! -L "$ORIGINAL" ] && [ ! -L "$BACKUP_MANIFEST" ] \
    || fail "备份路径不能是符号链接"
mkdir -p "$BACKUP_DIR" || fail "无法创建备份目录"
if [ -d "$ORIGINAL" ]; then
    if [ -f "$BACKUP_MANIFEST" ]; then
        "$BUNDLE_HELPER" --verify "$ORIGINAL" "$BACKUP_MANIFEST" \
            || fail "本机原始备份清单、系统版本或完整文件校验失败"
    else
        # Migrate only the known original from older project installers. Unknown
        # unlabelled backups are never treated as a fresh machine's original.
        ORIGINAL_SHA="$(shasum -a 256 "$ORIGINAL/Contents/MacOS/Dock" | awk '{print $1}')"
        ORIGINAL_INFO_SHA="$(shasum -a 256 "$ORIGINAL/Contents/Info.plist" | awk '{print $1}')"
        [ "$ORIGINAL_SHA" = "$EXPECTED_SHA" ] \
            && [ "$ORIGINAL_INFO_SHA" = df5a816eb4136b81c281ecbc4fe910cf82fbc572268219ae950c569a3ac5c2ab ] \
            || fail "已有无清单备份不是已知原版，保留备份并中止"
        codesign --verify --deep --no-strict -R='anchor apple' "$ORIGINAL" \
            || fail "旧版原始备份签名校验失败"
        "$BUNDLE_HELPER" --create "$ORIGINAL" "$BACKUP_MANIFEST" \
            || fail "无法为旧版原始备份创建完整清单"
    fi
    echo "已验证并保留目标电脑原始备份: $ORIGINAL"
else
    [ ! -e "$ORIGINAL" ] && [ ! -e "$BACKUP_MANIFEST" ] || fail "已有不完整备份，请先检查备份目录"
    [ "$KNOWN_MODIFIED" = 0 ] || fail "当前为项目修改版但原始备份丢失，无法创建可靠还原点"
    BACKUP_STAGE="$BACKUP_DIR/Dock.app.orig.pending-$$"
    BACKUP_RECORD_STAGE="$BACKUP_STAGE.manifest.plist"
    if ! ditto "$CURRENT" "$BACKUP_STAGE"; then
        fail "首次安装备份失败，系统 Dock 尚未替换"
    fi
    if ! "$BUNDLE_HELPER" --create "$BACKUP_STAGE" "$BACKUP_RECORD_STAGE" \
        || ! "$BUNDLE_HELPER" --verify "$CURRENT" "$BACKUP_RECORD_STAGE"; then
        fail "首次安装完整备份校验失败，暂存文件保留: $BACKUP_STAGE"
    fi
    mv "$BACKUP_STAGE" "$ORIGINAL" || fail "无法提交本机 Dock 备份"
    if ! mv "$BACKUP_RECORD_STAGE" "$BACKUP_MANIFEST"; then
        mv "$ORIGINAL" "$BACKUP_STAGE" 2>/dev/null || true
        fail "无法提交本机备份清单，暂存备份保留: $BACKUP_STAGE"
    fi
    echo "首次安装已完整备份目标电脑 Dock: $ORIGINAL"
fi
RASTER_STATE="$USER_HOME/Library/Application Support/LaunchpadRestore/RenderBackend/original.plist"
RASTER_ATTEMPT_STATE="$RASTER_STATE"
if [ -e "$RASTER_STATE" ] || [ -L "$RASTER_STATE" ]; then
    # Preserve entry values separately on reinstallation. A retained original
    # backup must not prevent recovery from a failed later installation.
    RASTER_ATTEMPT_STATE="${RASTER_STATE%/*}/attempt-$$.plist"
fi
as_desktop_user() { launchctl asuser "$USER_UID" /usr/bin/sudo -H -u "$CU" "$@"; }
restore_attempt_raster_state() {
    as_desktop_user "$RASTER_HELPER" --restore "$RASTER_ATTEMPT_STATE" \
        || echo "本次安装前的位图后端设置未能自动恢复，备份保留于: $RASTER_ATTEMPT_STATE"
}
apply_raster_state() {
    as_desktop_user "$RASTER_HELPER" --apply "$RASTER_ATTEMPT_STATE" || return 1
    if [ "$RASTER_ATTEMPT_STATE" != "$RASTER_STATE" ]; then
        as_desktop_user "$RASTER_HELPER" --apply "$RASTER_STATE" || return 1
    fi
}

DEV="$(diskutil info -plist / | plutil -extract DeviceIdentifier raw - 2>/dev/null)"
if [[ "$DEV" =~ ^(disk[0-9]+s[0-9]+)s[0-9]+$ ]]; then
    ROOTDEV="${BASH_REMATCH[1]}"
else
    ROOTDEV="$DEV"
fi
[[ "$ROOTDEV" =~ ^disk[0-9]+s[0-9]+$ ]] || fail "无法识别当前启动系统的 APFS 卷"
echo "根卷: /dev/$ROOTDEV"
mkdir "$MNT" || fail "无法创建专用系统卷挂载目录"
mount -o nobrowse -t apfs "/dev/$ROOTDEV" "$MNT" || fail "挂载系统卷失败"
MOUNTED=1

TARGET="$MNT/System/Library/CoreServices/Dock.app"
STAGED="$TARGET.native-stage-$$"
PREVIOUS="$TARGET.native-previous-$$"
[ -d "$TARGET" ] && [ ! -L "$TARGET" ] || fail "系统卷 Dock 缺失或不是普通目录"
[ ! -e "$STAGED" ] && [ ! -L "$STAGED" ] && [ ! -e "$PREVIOUS" ] && [ ! -L "$PREVIOUS" ] \
    || fail "暂存目录已存在，拒绝覆盖"
if ! ditto "$NEW_DOCK" "$STAGED"; then
    fail "暂存候选 Dock 失败"
fi
chown -R root:wheel "$STAGED" && chmod -R 755 "$STAGED" || fail "暂存 Dock 权限设置失败"
codesign --verify --strict "$STAGED" || fail "暂存完整 Dock 的签名校验失败"
[ "$(shasum -a 256 "$STAGED/Contents/MacOS/Dock" | awk '{print $1}')" = "$NEW_SHA" ] \
    || fail "暂存 Dock 的哈希校验失败"
"$BUNDLE_HELPER" --verify-bundle "$STAGED" "$BUNDLE_INVENTORY" \
    || fail "暂存完整 Dock 文件或资源校验失败"
SWAP_ACTIVE=1
mv "$TARGET" "$PREVIOUS" || fail "无法保留安装前的系统 Dock"
mv "$STAGED" "$TARGET" || fail "切换 Dock 失败，将尝试恢复安装前版本"
RASTER_TOUCHED=1
if ! apply_raster_state; then
    fail "无法切换 Dock 位图后端，未创建候选启动快照"
fi
if ! bless --mount "$MNT" --bootefi --create-snapshot; then
    fail "快照重建未报告成功，将尝试恢复系统卷与本次安装前的偏好"
fi
SNAPSHOT_CREATED=1
SWAP_ACTIVE=0
RASTER_TOUCHED=0
echo "快照已重建，候选版本: $(defaults read "$TARGET/Contents/Info.plist" LPRNativeExperimentVersion 2>/dev/null)"
echo "Dock SHA-256: $(shasum -a 256 "$TARGET/Contents/MacOS/Dock" | awk '{print $1}')"
echo "位图后端设置用户: $CU; 原始设置备份: $RASTER_STATE"
if [ "$RASTER_ATTEMPT_STATE" != "$RASTER_STATE" ]; then
    rm -f "$RASTER_ATTEMPT_STATE"
fi
rm -rf "$PREVIOUS" || echo "安装成功，安装前的临时副本仍保留于: $PREVIOUS"
if umount "$MNT" 2>/dev/null || umount -f "$MNT" 2>/dev/null; then
    MOUNTED=0
fi
echo "===== 安装完成，重启后生效 ====="
exit 0
