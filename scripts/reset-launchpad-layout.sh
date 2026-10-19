#!/bin/bash
#
# reset-launchpad-layout.sh — 把启动台布局重置为系统默认顺序
#
# 适用：macOS 26（Tahoe）上通过 Dock.app 回退恢复的原生启动台。
#       macOS 15 及更早同样适用（数据库路径不同，脚本会自动定位）。
#
# 用法：
#   ./reset-launchpad-layout.sh --dump           # 只打印当前布局，不改动
#   ./reset-launchpad-layout.sh --dry-run        # 演练，不做任何写入
#   ./reset-launchpad-layout.sh                  # 备份 → 删库 → 重启 Dock
#   ./reset-launchpad-layout.sh --restore DIR    # 从备份目录还原布局
#   ./reset-launchpad-layout.sh --list-backups   # 列出已有备份
#
set -euo pipefail

# ---------------------------------------------------------------- 定位数据库

# macOS 26：数据库在 $TMPDIR 的同级 0/ 目录下，不在 ~/Library/Application Support/Dock/
# （该目录在 26 上已不存在）。hash 每台机器不同，绝不可写死。
resolve_dbdir() {
    local dir=""

    # 首选：问正在运行的 Dock 进程要真实路径（最可靠，跨版本通吃）
    local dock_pid
    dock_pid=$(pgrep -x Dock 2>/dev/null | head -1 || true)
    if [ -n "$dock_pid" ]; then
        dir=$(lsof -p "$dock_pid" 2>/dev/null \
              | /usr/bin/awk '/com\.apple\.dock\.launchpad\/db\/db$/ {print $NF}' \
              | head -1 || true)
        [ -n "$dir" ] && dir=$(dirname "$dir")
    fi

    # 次选：由用户临时目录推导（/var/folders/<hash>/T/ → /var/folders/<hash>/0/）
    if [ -z "$dir" ] || [ ! -d "$dir" ]; then
        local tmp
        tmp=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)
        if [ -n "$tmp" ]; then
            local cand
            cand="$(echo "$tmp" | sed 's|/T/$|/0/com.apple.dock.launchpad/db|')"
            [ -d "$cand" ] && dir="$cand"
        fi
    fi

    # 末选：老路径（macOS 15 及更早）
    if [ -z "$dir" ] || [ ! -d "$dir" ]; then
        for cand in "$HOME/Library/Application Support/Dock"; do
            [ -d "$cand" ] && dir="$cand"
        done
    fi

    printf '%s' "$dir"
}

DBDIR=$(resolve_dbdir)

if [ -z "$DBDIR" ] || [ ! -d "$DBDIR" ]; then
    echo "✗ 找不到启动台数据库目录。" >&2
    echo "  排查：先打开一次启动台，再运行 lsof -p \$(pgrep -x Dock) | grep launchpad" >&2
    exit 1
fi

DB="$DBDIR/db"
BACKUP_ROOT="$HOME/Library/Application Support/LaunchpadLayoutBackup"

# ---------------------------------------------------------------- 只读功能

dump_layout() {
    [ -f "$DB" ] || { echo "✗ 数据库不存在：$DB" >&2; exit 1; }

    # items.type: 1=根 2=文件夹 3=页面 4/5=应用
    # 可见顺序 = items.ordering（rowid 不是显示顺序！）
    # uuid='HOLDINGPAGE' 是内部占位节点，不是可见空页，不要当成布局问题
    echo "数据库：$DB"
    sqlite3 "$DB" "select '应用 '||count(*) from apps;"
    sqlite3 "$DB" "select '条目 '||count(*) from items;"

    local page
    for page in $(sqlite3 "$DB" "select rowid from items where parent_id=1 order by ordering;"); do
        local n
        n=$(sqlite3 "$DB" "select count(*) from items where parent_id=$page;")
        [ "$n" -eq 0 ] && continue
        echo ""
        echo "── 第 $page 页（$n 项）──"
        sqlite3 "$DB" "
            select i.ordering || '. ' ||
                   case when a.title is not null then a.title
                        when g.title is not null and g.title <> '' then '📁 ' || g.title
                        else '[' || i.type || ']' end
            from items i
            left join apps a on a.item_id = i.rowid
            left join groups g on g.item_id = i.rowid
            where i.parent_id = $page
            order by i.ordering;" | sed 's/^/  /'
    done
}

list_backups() {
    if [ ! -d "$BACKUP_ROOT" ]; then
        echo "（还没有备份）"
        return
    fi
    ls -1 "$BACKUP_ROOT"
}

# ---------------------------------------------------------------- 还原

restore_backup() {
    local src="$1"
    if [ ! -f "$src/db" ]; then
        echo "✗ 备份无效（缺 db 文件）：$src" >&2
        exit 1
    fi
    echo "还原自：$src"
    # 同样先删再杀：让新 Dock 从备份文件重新加载，而不是继续用内存里的旧模型
    rm -f "$DBDIR/db" "$DBDIR/db-shm" "$DBDIR/db-wal"
    cp -p "$src/db" "$DBDIR/db"
    [ -f "$src/db-wal" ] && cp -p "$src/db-wal" "$DBDIR/db-wal"
    [ -f "$src/db-shm" ] && cp -p "$src/db-shm" "$DBDIR/db-shm"
    killall Dock 2>/dev/null || true
    sleep 6
    echo "✓ 已还原"
}

# ---------------------------------------------------------------- 主流程

MODE="reset"
RESTORE_FROM=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dump)         MODE="dump" ;;
        --dry-run)      MODE="dry" ;;
        --list-backups) MODE="list" ;;
        --restore)      MODE="restore"; RESTORE_FROM="${2:-}"; shift ;;
        -h|--help)      sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "未知参数：$1（-h 查看用法）" >&2; exit 1 ;;
    esac
    shift
done

case "$MODE" in
    dump)  dump_layout; exit 0 ;;
    list)  list_backups; exit 0 ;;
    restore)
        [ -n "$RESTORE_FROM" ] || { echo "✗ --restore 需要备份目录" >&2; exit 1; }
        restore_backup "$RESTORE_FROM"
        exit 0 ;;
esac

# ---- 重置 ----

if [ ! -f "$DB" ]; then
    echo "✗ 数据库不存在：$DB" >&2
    exit 1
fi

STAMP=$(date +%Y%m%d-%H%M%S)
BAK="$BACKUP_ROOT/$STAMP"

echo "数据库：$DB"
echo "备份到：$BAK"

if [ "$MODE" = "dry" ]; then
    echo ""
    echo "[演练] 将要执行："
    echo "  1) mkdir -p \"$BAK\" && cp -p db db-shm db-wal → 备份"
    echo "  2) rm -f \"$DBDIR\"/db{,-shm,-wal}"
    echo "  3) killall Dock"
    echo ""
    echo "当前布局："
    dump_layout
    exit 0
fi

mkdir -p "$BAK"
# 三个文件必须一起备份：db-wal 里可能还有未 checkpoint 的布局数据
cp -p "$DBDIR/db"       "$BAK/db"
[ -f "$DBDIR/db-wal" ] && cp -p "$DBDIR/db-wal" "$BAK/db-wal"
[ -f "$DBDIR/db-shm" ] && cp -p "$DBDIR/db-shm" "$BAK/db-shm"

if ! shasum -a 256 "$BAK/db" "$DBDIR/db" | /usr/bin/awk '{print $1}' | uniq | wc -l | grep -q '^1$'; then
    echo "✗ 备份校验失败（哈希不一致），中止" >&2
    exit 1
fi
echo "✓ 备份完成并校验通过"

# 关键顺序：先 unlink，再杀 Dock。
# 反过来的话 launchd 会立刻把 Dock 拉起来并重建数据库，删除就白做了。
# 先 unlink 时旧 Dock 手里是已解链的 inode，它的写入不会落回磁盘。
rm -f "$DBDIR/db" "$DBDIR/db-shm" "$DBDIR/db-wal"
echo "✓ 已移除旧数据库"

killall Dock 2>/dev/null || true
echo "… 等待 Dock 重建"

# 等新库出现（最多 30 秒）
i=0
while [ $i -lt 30 ]; do
    [ -f "$DB" ] && break
    sleep 1
    i=$((i + 1))
done

if [ ! -f "$DB" ]; then
    echo "✗ Dock 没有重建数据库，请手动重启一次 Dock：killall Dock" >&2
    exit 1
fi

sleep 6
echo "✓ 重建完成"
echo ""
dump_layout

echo ""
echo "回滚：$0 --restore \"$BAK\""
