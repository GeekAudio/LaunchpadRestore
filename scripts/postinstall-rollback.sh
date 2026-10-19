#!/bin/bash
# 还原：把 Dock.app 换回原版（安装时自动备份的版本）
# 由 Installer 以 root 执行；日志 /var/log/launchpadrestore.log

set -uo pipefail

BACKUP_DIR="/Library/Application Support/LaunchpadRestore"
ORIG_DOCK="$BACKUP_DIR/Dock.app.orig"
MNT="/System/Volumes/Update/mnt1"
LOG="/var/log/launchpadrestore.log"

exec >>"$LOG" 2>&1
echo "===== $(date '+%Y-%m-%d %H:%M:%S') 还原开始 ====="

fail() { echo "失败: $*"; echo "===== 中止 ====="; exit 0; }

if [ ! -d "$ORIG_DOCK" ]; then
    fail "找不到原版备份: $ORIG_DOCK（可能从未安装过，或备份已被删除）"
fi

echo "备份版本: $(defaults read "$ORIG_DOCK/Contents/Info.plist" CFBundleVersion 2>/dev/null)"

# 定位系统卷
DEV="$(diskutil info -plist / | plutil -extract DeviceIdentifier raw - 2>/dev/null)"
if [[ "$DEV" =~ ^(disk[0-9]+s[0-9]+)s[0-9]+$ ]]; then
    ROOTDEV="${BASH_REMATCH[1]}"
else
    ROOTDEV="$DEV"
fi
echo "根卷: /dev/$ROOTDEV"

mkdir -p "$MNT"
mount | grep -q " $MNT " && umount "$MNT" 2>/dev/null
mount -o nobrowse -t apfs "/dev/$ROOTDEV" "$MNT" || fail "挂载失败"

TARGET="$MNT/System/Library/CoreServices/Dock.app"
rm -rf "$TARGET"
if ! ditto "$ORIG_DOCK" "$TARGET"; then
    umount "$MNT" 2>/dev/null
    fail "复制失败"
fi
chown -R root:wheel "$TARGET"
chmod -R 755 "$TARGET"
echo "已还原为版本: $(defaults read "$TARGET/Contents/Info.plist" CFBundleVersion 2>/dev/null)"

# 删除 FeatureFlag —— 必须做
#   SpotlightPlus=false 是给 Dock 2419 用的（关新面板走老启动台）。
#   原版 Dock 只会画新版面板，flag 还在就会导致「点图标毫无反应」（踩过）。
if [ -f /Library/Preferences/FeatureFlags/Domain/SpotlightUI.plist ]; then
    rm -f /Library/Preferences/FeatureFlags/Domain/SpotlightUI.plist && echo "FeatureFlag 已删除"
else
    echo "FeatureFlag 不存在，跳过"
fi

if bless --mount "$MNT" --bootefi --create-snapshot; then
    echo "快照已重建"
else
    echo "★ 快照重建失败，改动可能不生效"
fi

umount "$MNT" 2>/dev/null || umount -f "$MNT" 2>/dev/null

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

echo "===== 还原完成，重启后生效 ====="
exit 0
