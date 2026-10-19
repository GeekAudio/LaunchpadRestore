#!/bin/bash
# 从源码重新构建 pkg
#
# 用法：
#   ./build-pkg.sh /path/to/Dock.app
#
# 说明：需要一个仍然保留老启动台界面代码的 Dock.app。
#       macOS 26.0 的版本是 2419；26.1 及以后被苹果删掉了界面层。
#       可以从 macOS 26.0 的安装器/系统卷里提取：
#         /System/Library/CoreServices/Dock.app

set -euo pipefail

DOCK_SRC="${1:-}"
if [ -z "$DOCK_SRC" ] || [ ! -d "$DOCK_SRC" ]; then
    echo "用法: $0 /path/to/Dock.app"
    exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

VER="$(defaults read "$DOCK_SRC/Contents/Info.plist" CFBundleVersion 2>/dev/null || echo unknown)"
echo "源 Dock.app 版本: $VER"

# --- 组装 scripts 目录 ---
mkdir -p "$BUILD/scripts-install" "$BUILD/scripts-rollback"
ditto "$DOCK_SRC" "$BUILD/scripts-install/Dock.app"
cp "$HERE/postinstall-install.sh"  "$BUILD/scripts-install/postinstall"
cp "$HERE/postinstall-rollback.sh" "$BUILD/scripts-rollback/postinstall"
chmod +x "$BUILD/scripts-install/postinstall" "$BUILD/scripts-rollback/postinstall"

# --- payload：只放数据卷里的一个占位文件 ---
# 注意：payload 绝对不能写系统宗卷，否则 Installer 会报
#       "软件包正尝试将内容安装到系统宗卷" 并中止，postinstall 不会执行。
mkdir -p "$BUILD/payload/Library/Application Support/LaunchpadRestore"
printf 'LaunchpadRestore 备份目录，请勿删除。\n' \
    > "$BUILD/payload/Library/Application Support/LaunchpadRestore/README.txt"

mkdir -p "$ROOT/pkg"

echo "构建安装包..."
pkgbuild --root "$BUILD/payload" \
         --scripts "$BUILD/scripts-install" \
         --identifier com.geekaudio.launchpadrestore.install \
         --version "$VER" \
         --install-location / \
         "$ROOT/pkg/LaunchpadRestore-Install.pkg"

echo "构建还原包..."
pkgbuild --root "$BUILD/payload" \
         --scripts "$BUILD/scripts-rollback" \
         --identifier com.geekaudio.launchpadrestore.rollback \
         --version "$VER" \
         --install-location / \
         "$ROOT/pkg/LaunchpadRestore-Rollback.pkg"

echo
ls -lh "$ROOT/pkg/"*.pkg
echo
echo "完成。"
