#!/bin/bash
# 修复 Launchpad 图标空白 —— image_cache 里存了 818 字节白图时重注入正确图标
#
# 背景：老版 Dock(2419) 对新格式图标（Assets.car 的 IconGroup）首次渲染可能失败，
#       往 ~/.../com.apple.dock.launchpad/db 的 image_cache 写一张 128x128 纯白 PNG(818B)。
#       图标资源本身没坏，只是缓存脏了。
#
# 用法：./fix-launchpad-icon.sh <App.app> [更多 App.app ...]
#       ./fix-launchpad-icon.sh --scan          # 只列出所有白图条目，不修改
#
set -euo pipefail

if [ $# -lt 1 ]; then
  /usr/bin/sed -n '2,12p' "$0"
  exit 1
fi

# ---------- 定位启动台数据库（路径含随机 hash，不能写死） ----------
DB=""
for d in /var/folders/*/*/0/com.apple.dock.launchpad/db; do
  [ -f "$d/db" ] && DB="$d" && break
done
if [ -z "$DB" ]; then
  echo "✗ 找不到启动台数据库 /var/folders/*/*/0/com.apple.dock.launchpad/db" >&2
  exit 1
fi
echo "数据库: $DB/db"

# ---------- --scan：只诊断 ----------
if [ "$1" = "--scan" ]; then
  echo
  echo "=== 疑似白图条目（正常 40–59 KB，异常 818 字节）==="
  /usr/bin/sqlite3 -header -column "$DB/db" "
    select a.item_id, a.title, length(i.image_data) as big
    from apps a join image_cache i on i.item_id = a.item_id
    where length(i.image_data) < 5000
    order by big asc;"
  echo
  echo "=== 全部条目大小分布 ==="
  /usr/bin/sqlite3 -header -column "$DB/db" "
    select length(image_data) as big, count(*) as cnt
    from image_cache group by big order by cnt desc limit 5;"
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ---------- 生成图标（规格必须匹配：big 128x128 16-bit，mini 30x30 8-bit） ----------
cat > "$TMP/gen.swift" <<'SWIFT'
import AppKit

func makePNG(appPath: String, px: Int, bits: Int, out: String) {
    let img = NSWorkspace.shared.icon(forFile: appPath)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: bits, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    img.draw(in: NSRect(x: 0, y: 0, width: px, height: px),
             from: NSRect(origin: .zero, size: img.size),
             operation: .sourceOver, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()
    if let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: out))
    }
}
let args = CommandLine.arguments
if args.count >= 3 {
    let app = args[1], prefix = args[2]
    makePNG(appPath: app, px: 128, bits: 16, out: "\(prefix)_big.png")
    makePNG(appPath: app, px: 30,  bits: 8,  out: "\(prefix)_mini.png")
}
SWIFT

# ---------- 逐个 app 生成 + 收集 SQL ----------
SQL="$TMP/fix.sql"
: > "$SQL"
COUNT=0
for APP in "$@"; do
  if [ ! -d "$APP" ]; then
    echo "⚠ 跳过（路径不存在）: $APP"
    continue
  fi
  BID=$(defaults read "$APP/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || true)
  if [ -z "$BID" ]; then
    echo "⚠ 跳过（读不到 CFBundleIdentifier）: $APP"
    continue
  fi
  ID=$(/usr/bin/sqlite3 "$DB/db" "select item_id from apps where bundleid='$BID' limit 1;")
  if [ -z "$ID" ]; then
    echo "⚠ 跳过（启动台里没有这个 app，先在启动台里打开一次）: $BID"
    continue
  fi

  PREFIX="$TMP/icon_$ID"
  /usr/bin/swift "$TMP/gen.swift" "$APP" "$PREFIX" 2>/dev/null || true
  if [ ! -f "${PREFIX}_big.png" ] || [ ! -f "${PREFIX}_mini.png" ]; then
    echo "⚠ 跳过（图标生成失败）: $APP"
    continue
  fi

  BIG=$(/usr/bin/stat -f%z "${PREFIX}_big.png")
  MINI=$(/usr/bin/stat -f%z "${PREFIX}_mini.png")
  echo "✓ $BID  item_id=$ID  big=${BIG}B  mini=${MINI}B"
  echo "delete from image_cache where item_id=$ID;" >> "$SQL"
  echo "insert into image_cache (item_id,size_big,size_mini,image_data,image_data_mini) values ($ID,128,30,readfile('${PREFIX}_big.png'),readfile('${PREFIX}_mini.png'));" >> "$SQL"
  COUNT=$((COUNT + 1))
done

if [ "$COUNT" -eq 0 ]; then
  echo "✗ 没有可修复的条目"
  exit 1
fi

# ---------- 写库（必须先停 Dock，它持有连接） ----------
echo
echo "重启 Dock 并写入 $COUNT 条缓存…"
killall Dock 2>/dev/null || true
sleep 1
/usr/bin/sqlite3 "$DB/db" ".timeout 8000" < "$SQL"
sleep 3

# ---------- 验证 ----------
echo
echo "=== 写入结果 ==="
/usr/bin/sqlite3 -header -column "$DB/db" "
  select a.title, length(i.image_data) as big, length(i.image_data_mini) as mini
  from apps a join image_cache i on i.item_id = a.item_id
  where length(i.image_data) > 0 order by a.item_id desc limit 5;"

echo
echo "完成。打开启动台查看；若仍是白图，等 Dock 完全起来后重跑本脚本。"
