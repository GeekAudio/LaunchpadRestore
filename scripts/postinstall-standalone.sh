#!/bin/bash
# Installer script for the independent app and optional rollback of Dock 2419.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="/var/log/launchpadrestore.log"
exec >>"$LOG" 2>&1
echo "===== $(date '+%Y-%m-%d %H:%M:%S') 独立启动台迁移开始 ====="

CONSOLE_USER="$(stat -f%Su /dev/console 2>/dev/null || true)"
if [ -n "$CONSOLE_USER" ] && [ "$CONSOLE_USER" != "root" ] && [ -x /usr/bin/python3 ]; then
    if /usr/bin/sudo -H -u "$CONSOLE_USER" /usr/bin/python3 "$SCRIPT_DIR/import-native-layout.py"; then
        echo "已为 $CONSOLE_USER 导入原生启动台布局"
    else
        echo "布局未自动导入；原生数据库未修改，可在登录后手动运行导入脚本"
    fi
else
    echo "没有可用的登录用户或 Python 3；跳过自动布局导入"
fi

CURRENT_VERSION="$(defaults read /System/Library/CoreServices/Dock.app/Contents/Info.plist CFBundleVersion 2>/dev/null || true)"
if [ "$CURRENT_VERSION" = "2419" ]; then
    echo "发现移植版 Dock 2419，开始恢复本机原版备份"
    "$SCRIPT_DIR/postinstall-rollback.sh"
else
    echo "当前 Dock 为 ${CURRENT_VERSION:-未知版本}；不替换系统 Dock"
fi

echo "===== 独立启动台迁移完成 ====="
