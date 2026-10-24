#!/bin/bash
# Manual, readonly capture while a Launchpad icon is still blank.
set -euo pipefail
umask 077

TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_BUILD="$TASK_ROOT/native/.build"
TASK_SOURCE="$TASK_ROOT/native/launchpad-icon-audit.m"
TASK_BINARY="$TASK_BUILD/launchpad-icon-audit"
TASK_LOGS="$HOME/Library/Logs/LaunchpadRestore/Icons"
[ "$(id -u)" -ne 0 ] || { echo '请以桌面用户运行，不要使用 sudo。' >&2; exit 1; }
mkdir -p "$TASK_BUILD" "$TASK_LOGS"
if [ ! -x "$TASK_BINARY" ] || [ "$TASK_SOURCE" -nt "$TASK_BINARY" ]; then
    TASK_TEMP="$(mktemp "$TASK_BUILD/icon-audit.XXXXXX")"
    trap 'rm -f "$TASK_TEMP"' EXIT
    xcrun clang -O2 -fobjc-arc -Wall -Wextra -Werror -framework Foundation \
        -framework CoreGraphics -framework ImageIO -lsqlite3 \
        "$TASK_SOURCE" -o "$TASK_TEMP"
    chmod 700 "$TASK_TEMP"
    mv "$TASK_TEMP" "$TASK_BINARY"
fi
TASK_CAPTURE="$(mktemp -d "$TASK_LOGS/$(date -u '+%Y%m%dT%H%M%SZ').XXXXXX")"
echo '正在只读记录当前图标缓存…'
date -u '+%Y-%m-%dT%H:%M:%SZ' > "$TASK_CAPTURE/time.txt"
"$TASK_BINARY" --all > "$TASK_CAPTURE/icons.json"
{
    sw_vers
    /usr/libexec/PlistBuddy -c 'Print :LPRNativeExperimentVersion' \
        /System/Library/CoreServices/Dock.app/Contents/Info.plist 2>/dev/null || true
    shasum -a 256 /System/Library/CoreServices/Dock.app/Contents/MacOS/Dock
    ps -axo pid,lstart,comm | /usr/bin/grep '/Dock.app/Contents/MacOS/Dock$' || true
} > "$TASK_CAPTURE/runtime.txt"
TASK_HELPER='/Library/Application Support/LaunchpadRestore/ca-render-backend'
if [ -x "$TASK_HELPER" ]; then
    "$TASK_HELPER" --status > "$TASK_CAPTURE/render-backend.json" 2> "$TASK_CAPTURE/render-backend-errors.txt" || true
fi
# Keep the log query limited to Launchpad's own icon and visibility messages.
/usr/bin/log show --last 5m --style ndjson --info \
    --predicate 'process == "Dock" AND subsystem == "com.apple.dock" AND category == "launchpad" AND (eventMessage CONTAINS[c] "image" OR eventMessage CONTAINS[c] "ISCreate" OR eventMessage CONTAINS[c] "visible")' \
    > "$TASK_CAPTURE/launchpad.ndjson" 2> "$TASK_CAPTURE/log-errors.txt" || true
echo "记录已保存：$TASK_CAPTURE"
echo 'icons.json 会列出具体应用和实际像素检查结果。此操作不修改图标或重启 Dock。'
