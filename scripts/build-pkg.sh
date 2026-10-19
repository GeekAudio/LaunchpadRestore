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

# --- 1. 组装 scripts 目录（Dock.app 放这里，不放 payload）---
mkdir -p "$BUILD/scripts-install" "$BUILD/scripts-rollback"
ditto "$DOCK_SRC" "$BUILD/scripts-install/Dock.app"
cp "$HERE/postinstall-install.sh"  "$BUILD/scripts-install/postinstall"
cp "$HERE/postinstall-rollback.sh" "$BUILD/scripts-rollback/postinstall"
chmod +x "$BUILD/scripts-install/postinstall" "$BUILD/scripts-rollback/postinstall"

# --- 2. payload：只放数据卷里的占位文件 ---
# 注意：payload 绝对不能写系统宗卷，否则 Installer 会报
#       "软件包正尝试将内容安装到系统宗卷" 并中止，postinstall 不会执行。
mkdir -p "$BUILD/payload/Library/Application Support/LaunchpadRestore"
printf 'LaunchpadRestore 备份目录，请勿删除。\n' \
    > "$BUILD/payload/Library/Application Support/LaunchpadRestore/README.txt"

mkdir -p "$ROOT/pkg"

# --- 3. pkgbuild 组件包 ---
# 注意：用 case 而不是 ${kind^}（那是 bash 4+ 语法，macOS 自带 bash 3.2 不支持）
for kind in install rollback; do
    case "$kind" in
        install)  name="Install" ;;
        rollback) name="Rollback" ;;
    esac
    pkgbuild --root "$BUILD/payload" \
             --scripts "$BUILD/scripts-$kind" \
             --identifier "com.geekaudio.launchpadrestore.$kind" \
             --version "$VER" \
             --install-location / \
             "$BUILD/LaunchpadRestore-$name-Component.pkg" >/dev/null
    echo "组件包: LaunchpadRestore-$name-Component.pkg"
done

# --- 4. distribution XML：让安装器最后一步显示「重新启动」而不是「完成」 ---
gen_dist() {
    local kind="$1" title="$2" comp="$3"
    cat > "$BUILD/dist-$kind.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="1">
    <title>$title</title>
    <organization>com.geekaudio</organization>
    <domains enable_localSystem="true"/>
    <options customize="never" require-scripts="false" hostArchitectures="x86_64,arm64"/>
    <pkg-ref id="com.geekaudio.launchpadrestore.$kind"/>
    <choices-outline>
        <line choice="default">
            <line choice="com.geekaudio.launchpadrestore.$kind"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="com.geekaudio.launchpadrestore.$kind" visible="false">
        <pkg-ref id="com.geekaudio.launchpadrestore.$kind"/>
    </choice>
    <pkg-ref id="com.geekaudio.launchpadrestore.$kind" version="$VER" onConclusion="require-restart">$comp</pkg-ref>
</installer-gui-script>
EOF
}

gen_dist install  "安装原生启动台" "LaunchpadRestore-Install-Component.pkg"
gen_dist rollback "还原原版启动台" "LaunchpadRestore-Rollback-Component.pkg"

# --- 5. productbuild 最终包 ---
cd "$BUILD"
productbuild --distribution dist-install.xml  --package-path . "$ROOT/pkg/LaunchpadRestore-Install.pkg"  >/dev/null
productbuild --distribution dist-rollback.xml --package-path . "$ROOT/pkg/LaunchpadRestore-Rollback.pkg" >/dev/null

echo
ls -lh "$ROOT/pkg/"*.pkg

# --- 6. 自检：确认 onConclusion 生效 ---
echo
for f in "$ROOT/pkg/"*.pkg; do
    tmp="$(mktemp -d)"
    pkgutil --expand "$f" "$tmp" >/dev/null 2>&1
    if grep -q 'onConclusion="require-restart"' "$tmp/Distribution" 2>/dev/null; then
        echo "OK  $(basename "$f")  安装完成显示「重新启动」"
    else
        echo "FAIL $(basename "$f")  onConclusion 缺失"
    fi
    rm -rf "$tmp"
done
