# LaunchpadRestore

把 macOS 26 上被砍掉的**原生启动台（Launchpad）**找回来。

**[⬇️ 下载最新版](../../releases/latest)** · [原理说明](docs/原理.md) · [构建方法](scripts/build-pkg.sh) · [图标变空](#图标变空) · [布局恢复默认](#布局乱了--恢复默认顺序)

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

1. 从 [Releases](../../releases/latest) 下载 `LaunchpadRestore-Install.pkg`
2. 双击 → 输入登录密码 → 安装器最后一步点 **「重新启动」**

> 包未签名。如果提示「无法验证开发者」：**右键点 pkg → 打开 → 再点「打开」**。
>
> 或者用命令行：
> ```bash
> sudo installer -pkg LaunchpadRestore-Install.pkg -target /
> ```
>
> **v1.2 及更早的包有个小 bug**：装完最后一屏显示「完成」而不是「重新启动」。
> 原因是 Distribution 里 `onConclusion` 写成了小写连字符的 `require-restart`，
> 而 Installer 只认 PascalCase 的 `RequireRestart`，不认识的值静默按 `None` 处理。
> **不影响安装结果，手动重启一样生效**；新包已修（`scripts/build-pkg.sh` 第 6 步自检会比对具体值）。

重启后点 Dock 第二个图标（或按 `F4`）就是老启动台。

> 安装包还会顺带装一个**图标自检**：Dock 2419 偶尔会把某个图标渲染成空图，
> 自检会在每次登录后自动补回来，不用你操心。详见 [图标变空](#图标变空)。

---

## 还原

从 [Releases](../../releases/latest) 下载 `LaunchpadRestore-Rollback.pkg` → 双击 → 输入密码 → 安装器最后一步点 **「重新启动」**。

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

**已经是目标版本时安装包会自动跳过替换**，但**仍会补装图标自检**，重复双击无害。

---

## 它具体做了什么

`postinstall` 脚本（[`scripts/postinstall-install.sh`](scripts/postinstall-install.sh)）执行六步：

1. 用 `ditto` 备份当前 `Dock.app` → `/Library/Application Support/LaunchpadRestore/`
2. 动态定位系统卷（`disk` 编号会变，不能写死），以 `-o nobrowse` 挂到 `/System/Volumes/Update/mnt1`
3. 替换 `mnt1/System/Library/CoreServices/Dock.app` 为 26.0 版（`2419`）
4. 写入 `SpotlightPlus=false`，让 2419 走旧启动台界面
5. `bless --mount ... --bootefi --create-snapshot` 重建系统快照
6. 装一个登录自检 `agent`（`/Library/LaunchAgents/com.geekaudio.launchpadiconfix.plist`），
   每次登录后自动把「变空的图标」补回来 —— 见 [图标变空](#图标变空)

> 第 5 步是关键：macOS 11+ 的系统卷是只读快照，**不重建快照则改动不会生效**。
>
> 两个 pkg 都把 Installer 结尾设为 **「重新启动」**；还原包会先恢复本机备份 Dock、
> 移除 `SpotlightPlus` 开关和图标自检 agent，再提示重启。

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

## 图标变空

个别 app 的图标在启动台里**整个不见了**（不是白方块，是彻底看不见）。App 没丢，是启动台的图标缓存里
存了一张 **128×128 全透明 PNG**。

**判据**：正常缓存条目是 12–60 KB 的 PNG，空图条目固定 **818 字节**。查一下就知道哪些 app 中招：

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
./scripts/fix-launchpad-icon.sh --scan                     # 只诊断，列出空图条目
./scripts/fix-launchpad-icon.sh --fix-all                  # 自动扫出全部空图并逐个修复
./scripts/fix-launchpad-icon.sh /Applications/1401.app     # 修指定 app
```

脚本做的事：按缓存的原生规格重新生成图标写回去，再重启 Dock 刷新界面。

- 大图 **128×128 16-bit RGBA**、小图 **30×30 8-bit RGBA** —— 16-bit 这点容易漏，普通 PNG 默认是 8-bit
- 写库顺序见下一节，**别先杀 Dock**

### 为什么会空 / 能不能一次修好

`image_cache` 里那张 818 字节的图，解出来是 **128×128 全透明 RGBA**（像素全是 `(0,0,0,0)`）——
所以界面上不是「白方块」，而是**整个图标消失**。

**成因**：`2419` 的 Dock 给启动台渲染图标时偶发失败（多半是解码超时），失败就往 `image_cache`
写这张全透明图当占位。图标资源本身没坏，App 条目也还在。**失败是随机的**——同一台机器重建缓存时，
每次中招的 App 可能换一批，所以表现成「重启后随机少几个图标」。

> 实测旁证：`1401.icns` 有 **1.86 MB**（含一个 940 KB 的 1024px 表示），而正常系统 App 的
> `.icns` 只有 35–50 KB。图标越「重」，越容易在并发渲染时超时。

**能不能一次修好**：能，但要分清两件事——

1. **缓存可写且长期保留**。实测：Dock 运行时写入正确图标，扛过 Dock 重启、扛过十几秒观察，
   不会被冲掉。所以注入是有效的。
2. **但注入后若 Dock 再渲染一次该条目，仍可能再落一张空图**（系统更新、App 更新、清缓存）。
   所以它治的是「当前这次」，不是「永远不复发」。

### ⚠️ 必须避开的坑：先写库，再重启 Dock

老版本脚本是 `killall Dock` → 写库，**这个顺序是错的**，会撞车：新 Dock 起来时正在渲染图标，
对渲染失败的条目立刻写入 818，把刚写进去的正确图标盖掉——表现为「注入成功但复查还是 818」，
非常容易被误判成「这个图标根本修不了」。

正确顺序：**Dock 运行时写库 → 再 `killall Dock` 刷新界面**。数据库是 WAL 模式，
Dock 持有连接也能并发写，不需要停它。

### 想不复发：装登录自检

**用安装包装的，这一步已经自动做了**——安装包会把 agent 装到
`/Library/LaunchAgents/com.geekaudio.launchpadiconfix.plist`，重启后第一次登录就生效。

手动装（脚本方式，装到当前用户）：

```bash
./scripts/fix-launchpad-icon.sh --install-agent     # 装
./scripts/fix-launchpad-icon.sh --uninstall-agent   # 卸
```

每次登录后 20 秒自动跑 `--fix-all`：扫到空图标才动手，没有就静默退出
（不重启 Dock、不闪屏）。日志 `~/Library/Logs/LaunchpadIconFix.log`
（安装包装的写 `/tmp/launchpadiconfix.log`）。

> 手动装的**下次登录**才加载。想马上启用：
> `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.geek.launchpadiconfix.plist`
>
> 两种别同时装，会跑两份；安装包的 postinstall 会自动清掉用户级那份。

### 从源头降低复发率（仅限自己的 App）

把 App 的 `.icns` 减肥：只留 16/32/128/256/512 的表示，删掉 1024px（`ic10`）。
图标越轻，2419 渲染越不容易超时。系统 App 的图标在只读签名卷上，改它要重建系统快照，不值得。

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

> ⚠️ 也别**反复** `killall Dock`。实测连续杀掉重启多次后，Dock 会把内存里的半成品模型刷回数据库，
> 出现 `HOLDINGPAGE` 被塞进 35 项、`ordering` 重复（两个 `16.`）这种半乱状态。
> 真乱了就重跑一次 `./reset-launchpad-layout.sh` 重新生成，别手动去修 `ordering`。

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
