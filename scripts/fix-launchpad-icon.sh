#!/bin/bash
# 修复 Launchpad 图标变空 —— image_cache 里存了 818 字节全透明空图时重注入正确图标
#
# 背景：老版 Dock(2419) 对新格式图标（Assets.car 的 IconGroup）首次渲染可能失败，
#       往 ~/.../com.apple.dock.launchpad/db 的 image_cache 写一张 128x128 纯白 PNG(818B)。
#       图标资源本身没坏，只是缓存脏了。
#
# 用法：./fix-launchpad-icon.sh <App.app> [更多 App.app ...]
#       ./fix-launchpad-icon.sh --scan           # 只列出所有空图条目，不修改
#       ./fix-launchpad-icon.sh --fix-all        # 自动扫出全部空图条目并逐个修复
#       ./fix-launchpad-icon.sh --install-agent  # 装登录自检（每次登录自动跑 --fix-all）
#       ./fix-launchpad-icon.sh --uninstall-agent
#
# 成因：Dock(2419) 给启动台渲染图标时会偶发失败（多半是解码超时），失败时往
#       image_cache 写一张 128x128 全透明 PNG（正好 818 字节）当占位。图标资源没坏，
#       只是缓存里是空图，界面上就表现为「这个 App 图标消失了」。
#       ★ 失败是随机的：同一台机器每次重建缓存，中招的 App 可能换一批。
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

# ---------- 登录自检 agent ----------
AGENT_LABEL="com.geek.launchpadiconfix"
AGENT_DIR="$HOME/Library/Application Support/LaunchpadRestore"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"

case "${1:-}" in
  --install-agent)
    mkdir -p "$AGENT_DIR" "$HOME/Library/LaunchAgents"
    cp "$0" "$AGENT_DIR/fix-launchpad-icon.sh"
    chmod +x "$AGENT_DIR/fix-launchpad-icon.sh"
    cat > "$AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$AGENT_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$AGENT_DIR/fix-launchpad-icon.sh</string>
        <string>--agent</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>StandardOutPath</key><string>$HOME/Library/Logs/LaunchpadIconFix.log</string>
    <key>StandardErrorPath</key><string>$HOME/Library/Logs/LaunchpadIconFix.log</string>
</dict>
</plist>
PLIST
    launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST" 2>/dev/null || true
    echo "✓ 已安装登录自检：$AGENT_PLIST"
    echo "  脚本副本：$AGENT_DIR/fix-launchpad-icon.sh"
    echo "  日志：~/Library/Logs/LaunchpadIconFix.log"
    echo "  没有空图时不会重启 Dock，不会闪屏。"
    exit 0 ;;
  --uninstall-agent)
    launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
    rm -f "$AGENT_PLIST" "$AGENT_DIR/fix-launchpad-icon.sh"
    echo "✓ 已卸载登录自检"
    exit 0 ;;
  --agent)
    # 等 Dock 起来、图标渲染完再动手，避免撞车
    sleep 20
    set -- --fix-all ;;
esac

# ---------- --scan：只诊断 ----------
if [ "$1" = "--scan" ]; then
  echo
  echo "=== 疑似空图条目（正常 12–60 KB，异常 818 字节）==="
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

# ---------- --fix-all：扫出全部空图条目，反查路径后走正常流程 ----------
if [ "$1" = "--fix-all" ]; then
  echo
  echo "=== 扫描空图条目 ==="
  IDS=$(/usr/bin/sqlite3 "$DB/db" "
    select a.bundleid from apps a join image_cache i on i.item_id = a.item_id
    where length(i.image_data) < 5000;")
  if [ -z "$IDS" ]; then
    echo "没有空图条目，无需修复。"
    exit 0
  fi

  PATHS=()
  for BID in $IDS; do
    # 用 Spotlight 反查 app 路径，排除废纸篓里的副本
    P=$(/usr/bin/mdfind "kMDItemCFBundleIdentifier == '$BID'" 2>/dev/null \
        | /usr/bin/grep -v '^/Users/.*/\.Trash/' \
        | /usr/bin/grep '\.app$' | head -1 || true)
    if [ -n "$P" ] && [ -d "$P" ]; then
      echo "  ✓ $BID → $P"
      PATHS+=("$P")
    else
      echo "  ⚠ $BID 找不到 .app 路径，跳过"
    fi
  done

  if [ ${#PATHS[@]} -eq 0 ]; then
    echo "✗ 没有可修复的条目"
    exit 1
  fi
  echo
  set -- "${PATHS[@]}"
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

# ---------- 写库 ----------
# ★★ 顺序铁律：必须在 Dock 运行时写库，写完再重启 Dock。
#    反过来（先 killall Dock 再写）会撞车：新 Dock 起来时正在渲染图标，
#    对渲染失败的条目会立刻写入 818 字节空图，把刚写进去的正确图标盖掉——
#    表现为「注入成功但复查还是 818」，很容易误判成「这个图标修不了」。
#    数据库是 WAL 模式，Dock 持有连接也能并发写，不需要停它。
echo
echo "写入 $COUNT 条缓存（Dock 保持运行）…"
/usr/bin/sqlite3 "$DB/db" ".timeout 15000" < "$SQL"
sleep 2

echo "重启 Dock 让界面重新读缓存…"
killall Dock 2>/dev/null || true
sleep 10

# ---------- 验证 ----------
echo
echo "等 Dock 起来重新渲染…"
sleep 10

echo "=== 复查：仍为空的条目 ==="
REMAIN=$(/usr/bin/sqlite3 -header -column "$DB/db" "
  select a.title, length(i.image_data) as big
  from apps a join image_cache i on i.item_id = a.item_id
  where length(i.image_data) < 5000;")
if [ -z "$REMAIN" ]; then
  echo "  无 —— 全部修复成功"
else
  echo "$REMAIN"
  echo
  echo "⚠ 上面这些是「不可修」类：Dock(2419) 渲染它们的图标必然失败，"
  echo "  注入的正确缓存会在 Dock 启动后被覆盖回 818 字节。重跑也无效。"
fi

echo
echo "完成。打开启动台查看。"
