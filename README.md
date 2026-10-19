# LaunchpadRestore

把 macOS 26 上被砍掉的**原生启动台（Launchpad）**找回来。

**[⬇️ 下载最新版](../../releases/latest)** · [原理说明](docs/原理.md) · [构建方法](scripts/build-pkg.sh) · [图标空白](#图标空白) · [布局恢复默认](#布局乱了--恢复默认顺序)

> 安装包体积较大，放在 [Releases](../../releases/latest) 里，不进 git 历史。

> **一句话原理**：macOS 26.0 的 `Dock.app`（版本 `2419`）里还完整保留着老启动台的界面代码，
> 26.1 之后被苹果删掉了。**只替换 `Dock.app` 就能恢复**——不需要关闭 SIP、不需要降级系统、
> 不需要替换 Spotlight 或 Apps。

---

## 效果

恢复后是原生的启动台，不是第三方仿制品：

- 全屏图标网格，左右翻页
- 拖拽排序、拖拽建文件夹
- 文件夹翻页
- 按 `F4` 或点 Dock **第二个图标**唤起
- 应用列表和你的原有布局来自系统本身

---

## 安装

1. 从 [Releases](../../releases/latest) 下载 `LaunchpadRestore-Install.pkg`（本地名 `安装.pkg`）
2. 双击 → 输入登录密码 → 安装器最后一步点 **「重新启动」**

> 包未签名。如果提示「无法验证开发者」：**右键点 pkg → 打开 → 再点「打开」**。
>
> 或者用命令行：
> ```bash
> sudo installer -pkg 安装.pkg -target /
> ```

重启后点 Dock 第二个图标（或按 `F4`）就是老启动台。

---

## 还原

从 [Releases](../../releases/latest) 下载 `LaunchpadRestore-Rollback.pkg`（本地名 `还原.pkg`）→ 双击 → 输入密码 → 安装器最后一步点 **「重新启动」**。

安装时会**自动备份这台机器自己的 `Dock.app`** 到：

```
/Library/Application Support/LaunchpadRestore/Dock.app.orig
```

所以还原时换回的是**这台机器的原版**，不会串版本。这个目录别删。

---

## 兼容性

| 项目 | 要求 |
|---|---|
| 系统 | macOS **26.0 – 26.7**（26.7.1 实测通过） |
| CPU | Intel `x86_64` / Apple Silicon `arm64e`（`Dock.app` 是通用二进制） |
| 前提 | `csrutil authenticated-root` 为 `disabled`（黑苹果 / OCLP 环境通常已满足） |
| 不需要 | 关闭 SIP、替换 Spotlight、替换 Apps、降级系统 |

**已经是目标版本时安装包会自动跳过**，重复双击无害。

---

## 它具体做了什么

`postinstall` 脚本（[`scripts/postinstall-install.sh`](scripts/postinstall-install.sh)）执行五步：

1. 用 `ditto` 备份当前 `Dock.app` → `/Library/Application Support/LaunchpadRestore/`
2. 动态定位系统卷（`disk` 编号会变，不能写死），以 `-o nobrowse` 挂到 `/System/Volumes/Update/mnt1`
3. 替换 `mnt1/System/Library/CoreServices/Dock.app` 为 26.0 版（`2419`）
4. 写入 `SpotlightPlus=false`，让 2419 走旧启动台界面
5. `bless --mount ... --bootefi --create-snapshot` 重建系统快照

> 第 5 步是关键：macOS 11+ 的系统卷是只读快照，**不重建快照则改动不会生效**。
>
> 两个 pkg 都把 Installer 结尾设为 **「重新启动」**；还原包会先恢复本机备份 Dock 并移除 `SpotlightPlus` 开关，再提示重启。

日志：`/var/log/launchpadrestore.log`

---

## 系统更新后

每次 macOS 更新都会把 `Dock.app` 换回新版，启动台会消失。
**更新完重新双击安装包即可。**

如果系统跨了大版本（比如 26.x → 27.x），建议先删掉旧备份让安装包重新备份：

```bash
sudo rm -rf "/Library/Application Support/LaunchpadRestore/Dock.app.orig"
```

---

## 图标空白

个别 app 在启动台里显示成**白方块**。这不是图标丢了，是启动台的图标缓存里存了一张 128×128 的白图。

**判据**：正常缓存条目是 40–59 KB 的 PNG，白图条目固定 **818 字节**。查一下就知道哪些 app 中招：

```bash
DB=$(echo /var/folders/*/*/0/com.apple.dock.launchpad/db)
sqlite3 -header -column "$DB/db" "
  select a.item_id, a.title, length(i.image_data) as big
  from apps a join image_cache i on i.item_id = a.item_id
  where length(i.image_data) < 5000;"
```

> macOS 26 里启动台数据库**不在** `~/Library/Application Support/Dock/`（该目录已不存在），
> 而在 `/var/folders/<hash>/0/com.apple.dock.launchpad/db`。hash 每台机器不同，不要写死。

**修复**：

```bash
./scripts/fix-launchpad-icon.sh --scan                               # 只诊断，列出白图条目
./scripts/fix-launchpad-icon.sh /System/Applications/VoiceMemos.app  # 修复指定 app
```

脚本做的事：按缓存的原生规格重新生成图标写回去，再重启 Dock。

- 大图 **128×128 16-bit RGBA**、小图 **30×30 8-bit RGBA** —— 16-bit 这点容易漏，普通 PNG 默认是 8-bit
- 写库前必须先 `killall Dock` 释放数据库连接，否则会被占用
- 写入后等几秒复查长度没被覆盖回 818 才算成功

**为什么会出现**：`2419` 的 Dock 渲染新格式图标（`Assets.car` 里的 `IconGroup` 变体）时可能超时失败，
直接落一张白图。清图标缓存或系统更新后可能复发，重跑脚本即可。

---

## 布局乱了 / 恢复默认顺序

图标顺序被打乱、拖出来的文件夹翻页翻乱，想回到刚装系统时的排列：

```bash
./scripts/reset-launchpad-layout.sh --dump    # 先看当前布局（只读，不动任何东西）
./scripts/reset-launchpad-layout.sh           # 备份 → 删库 → 重启 Dock
```

脚本先把三个数据库文件备份到 `~/Library/Application Support/LaunchpadLayoutBackup/<时间戳>/`
（`--list-backups` 列出来），校验哈希后再重建。

重建结果是 Apple 原厂布局：**第一页系统 App（App Store → 系统设置）+「其他」「游戏」两个文件夹，
第二页第三方 App**。

> ⚠️ 自定义文件夹、拖拽排序会一起丢——这就是「恢复默认」的含义。
> 反悔用 `./scripts/reset-launchpad-layout.sh --restore "<备份目录>"` 原样装回去。

### 别再用 `ResetLaunchPad`

```bash
defaults write com.apple.dock ResetLaunchPad -bool true && killall Dock
```

这条流传很广的命令**在 26 的 Dock 上无效**。实测过程：flag 写进去 → `killall Dock` → 重启后
`defaults read com.apple.dock ResetLaunchPad` **仍然是 `1`**（说明 Dock 根本没读它），
数据库 mtime 不变、条目数不变。26 版 Dock 里这个重置分支已经不存在了。

### 正确顺序：先删库，再杀 Dock

```bash
killall Dock                  # ✗ 先杀：launchd 立刻把 Dock 拉起来并重建库，后面的删除白做
rm -f db db-shm db-wal        # ✓ 先删：旧 Dock 持有的是已解链 inode，写入不落回磁盘
killall Dock                  #   新 Dock 找不到库，从零生成
```

顺序反了会得到一个**半新半旧**的库：老文件夹还在、页面编号错乱（实测出现过孤儿页面）。

### 数据库结构（判断布局问题用）

布局本体在 `items` 表。**`rowid` 不是显示顺序，`ordering` 才是**——直接按 rowid 排序会得出
「顺序完全没变」的错误结论。

| 字段 | 含义 |
|---|---|
| `type` | `1`=根 `2`=文件夹 `3`=页面 `4`/`5`=应用 |
| `parent_id` | 父节点。根节点固定 `rowid=1` |
| `ordering` | 同级内的显示位置 |
| `uuid='HOLDINGPAGE'` | 内部占位节点，**不是**可见的空页，别当 bug 去修 |

一眼看布局：

```bash
./scripts/reset-launchpad-layout.sh --dump
```

---

## 已知取舍

`Dock.app` 版本 `2419` 是 26.0 的，比 26.7.1 落后 7 个小版本，缺少 26.1–26.7 的 Dock 修复。
目前实测未发现异常，但个别 26.x 新增的 Dock 特性可能缺失。

如果你手上有更接近的新版本（比如 26.5、26.6 的 `Dock.app`，且仍保留启动台代码），
可以用 [`scripts/build-pkg.sh`](scripts/build-pkg.sh) 自行打包。

---

## 免责声明

- 本工具修改系统文件（`/System/Library/CoreServices/Dock.app`），**操作有风险**，请自行备份重要数据。
- `Dock.app` 版权归 **Apple Inc.** 所有。本仓库仅为个人学习与研究用途分发，请在 24 小时内删除，
  或改用自己从系统安装包中提取的文件。
- 使用本工具造成的任何后果由使用者自行承担。

## License

脚本部分：[MIT](LICENSE)
