#!/bin/bash
# 安装：把 Dock.app 换成 26.0 版(2419)，让原生启动台回来
# 通用版：动态备份【目标机器】当前的 Dock，不依赖内置备份，可跨机器使用
# 由 Installer 以 root 执行；日志 /var/log/launchpadrestore.log

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
[ -d "$SCRIPT_DIR/Dock.app" ] || SCRIPT_DIR="$(pwd)"
NEW_DOCK="$SCRIPT_DIR/Dock.app"
BACKUP_DIR="/Library/Application Support/LaunchpadRestore"
MNT="/System/Volumes/Update/mnt1"
LOG="/var/log/launchpadrestore.log"
CUR_DOCK="/System/Library/CoreServices/Dock.app"

exec >>"$LOG" 2>&1
echo "===== $(date '+%Y-%m-%d %H:%M:%S') 安装开始 ====="

fail() { echo "失败: $*"; echo "===== 中止 ====="; exit 0; }

# 图标自检 agent —— 布置 + 清理用户级重复副本
# Dock 2419 渲染图标偶发失败时会写一张 818 字节全透明 PNG，界面上表现为
# 「图标消失」。agent 每次登录后 20 秒扫一遍，有空图标才补，没有就静默退出。
setup_agent() {
    AGENT="/Library/LaunchAgents/com.geekaudio.launchpadiconfix.plist"
    if [ ! -f "$AGENT" ]; then
        echo "★ 图标自检 agent 缺失（不影响启动台，只是空图标需要手动修）"
        return 0
    fi
    chown root:wheel "$AGENT" 2>/dev/null
    chmod 644 "$AGENT" 2>/dev/null
    echo "图标自检 agent 已就位（下次登录自动生效）: $AGENT"

    # 用户之前若手动跑过 --install-agent，会有份用户级副本，清掉避免跑两份
    CU="$(stat -f%Su /dev/console 2>/dev/null)"
    if [ -n "$CU" ] && [ "$CU" != "root" ]; then
        CH="$(dscl . -read "/Users/$CU" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')"
        UID_N="$(id -u "$CU" 2>/dev/null)"
        if [ -n "$CH" ] && [ -f "$CH/Library/LaunchAgents/com.geekaudio.launchpadiconfix.plist" ]; then
            launchctl asuser "$UID_N" launchctl bootout "gui/$UID_N/com.geekaudio.launchpadiconfix" 2>/dev/null
            rm -f "$CH/Library/LaunchAgents/com.geekaudio.launchpadiconfix.plist"
            echo "已移除用户级重复 agent（避免跑两份）"
        fi
    fi
}

[ -d "$NEW_DOCK" ] || fail "payload 缺失: $NEW_DOCK"

CUR_VER="$(defaults read "$CUR_DOCK/Contents/Info.plist" CFBundleVersion 2>/dev/null)"
TGT_VER="$(defaults read "$NEW_DOCK/Contents/Info.plist" CFBundleVersion 2>/dev/null)"
echo "当前 Dock: ${CUR_VER:-未知}  目标 Dock: ${TGT_VER:-未知}"
echo "系统: $(sw_vers -productVersion) ($(uname -m))"

# 已经是目标版本 -> 只补 agent，其余跳过（幂等）
# ★ 必须在这里也调 setup_agent：已经装过 2419 的机器重装 pkg 会走到这个分支，
#   不补的话 agent 永远装不上（payload 里的文件 Installer 已经放好了，但用户级副本清理和日志会缺）
if [ -n "$CUR_VER" ] && [ "$CUR_VER" = "$TGT_VER" ]; then
    echo "当前已是目标版本，无需替换"
    setup_agent
    echo "===== 跳过 ====="
    exit 0
fi

# 1) 动态备份【本机】当前 Dock（不是包里带的）
mkdir -p "$BACKUP_DIR"
if [ ! -d "$BACKUP_DIR/Dock.app.orig" ]; then
    if ditto "$CUR_DOCK" "$BACKUP_DIR/Dock.app.orig"; then
        echo "已备份本机 Dock($CUR_VER) -> $BACKUP_DIR/Dock.app.orig"
    else
        fail "备份失败，为安全起见不继续"
    fi
else
    echo "备份已存在，保留（如需重新备份先删除 $BACKUP_DIR/Dock.app.orig）"
fi

# 2) 定位系统卷（disk 编号会变，动态取）
DEV="$(diskutil info -plist / | plutil -extract DeviceIdentifier raw - 2>/dev/null)"
if [[ "$DEV" =~ ^(disk[0-9]+s[0-9]+)s[0-9]+$ ]]; then
    ROOTDEV="${BASH_REMATCH[1]}"     # 根是快照，取父卷
else
    ROOTDEV="$DEV"
fi
echo "根卷: /dev/$ROOTDEV"

# 3) 挂载为可写
mkdir -p "$MNT"
mount | grep -q " $MNT " && umount "$MNT" 2>/dev/null
mount -o nobrowse -t apfs "/dev/$ROOTDEV" "$MNT" || fail "挂载失败"

# 4) 替换 Dock.app
TARGET="$MNT/System/Library/CoreServices/Dock.app"
rm -rf "$TARGET"
if ! ditto "$NEW_DOCK" "$TARGET"; then
    umount "$MNT" 2>/dev/null
    fail "复制失败（原 Dock 已备份，可还原）"
fi
chown -R root:wheel "$TARGET"
chmod -R 755 "$TARGET"
echo "已替换为版本: $(defaults read "$TARGET/Contents/Info.plist" CFBundleVersion 2>/dev/null)"

# 4.5) 写入 FeatureFlag —— 必须做
#      SpotlightPlus=false 让系统关掉新版面板，Dock 2419 才会画老启动台。
#      少了这一步：Dock 换成 2419 了，但点图标毫无反应（踩过）。
mkdir -p /Library/Preferences/FeatureFlags/Domain
if defaults write /Library/Preferences/FeatureFlags/Domain/SpotlightUI.plist SpotlightPlus -dict Enabled -bool false; then
    echo "FeatureFlag 已写入 (SpotlightPlus=false)"
else
    echo "★ FeatureFlag 写入失败，启动台可能不出现"
fi

# 5) 重建系统快照（不重建则不生效）
if bless --mount "$MNT" --bootefi --create-snapshot; then
    echo "快照已重建"
else
    echo "★ 快照重建失败，改动可能不生效"
fi

# 6) 卸载
umount "$MNT" 2>/dev/null || umount -f "$MNT" 2>/dev/null

# 7) 图标自检 agent
setup_agent

echo "===== 安装完成，重启后生效 ====="
exit 0
