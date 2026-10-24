# LaunchpadRestore

在 macOS 26 上提供可分页、可整理文件夹的启动台。

> **当前预发布 v1.4：完整原生启动台 2427.6.10**。仅支持 macOS 26.7.1（25G241）、Intel / x86_64，
> 携带完整 Dock 及资源，不要求目标预装旧启动台或 OCLP。第九版的分辨率修复已获本机成功反馈。
> 独立 `Lunchpad.app` 作为另一种实现保留；它与 Apple 原生启动台的交互不同。

**[完整原生包 v1.4](https://github.com/GeekAudio/LaunchpadRestore/releases/tag/v1.4)** · [原理说明](docs/原理.md) · [旧版构建方法](scripts/build-pkg.sh) · [图标变空](#图标变空) · [布局恢复默认](#布局乱了--恢复默认顺序)

> 安装包放在 [v1.4 预发布](https://github.com/GeekAudio/LaunchpadRestore/releases/tag/v1.4) 附件中，不进 git 历史。

## 完整原生安装包（2427.6.10）

下载 [完整分发 ZIP](https://github.com/GeekAudio/LaunchpadRestore/releases/download/v1.4/LaunchpadRestore-Native2427-Full-2427.6.10.zip)，内含安装、卸载和中文说明。

- 单独下载：[安装包 Install](https://github.com/GeekAudio/LaunchpadRestore/releases/download/v1.4/LaunchpadRestore-Native2427-Install-2427.6.10.pkg)
- 单独下载：[卸载还原包 Uninstall](https://github.com/GeekAudio/LaunchpadRestore/releases/download/v1.4/LaunchpadRestore-Native2427-Uninstall-2427.6.10.pkg)

**v1.4 标记为预发布**：尚未在另一台未安装 OCLP 的电脑上实际验证首次安装；重启后首次打开时
偶见两个空白图标、反复开关后恢复的问题也尚未修复。

完整包包含 468 个 Dock 文件、图像资源、插件和 XPC 辅助程序，以及渲染设置和备份校验工具。
首次安装会备份**目标电脑自己的 Dock**；目标不需要先存在 `Dock.app.orig`。
卸载只使用这台电脑保存的原始备份。截图中“还原本机原版 Dock”属于卸载用途，安装启动台请选择 Install。

软件包 2427.6.10 改进分发和首次安装流程，Dock 主程序与当前成功运行的第九版逐字节相同。
系统需已关闭 Authenticated Root，并具有运行重新签名系统程序的代码签名策略；
本包不会调整 SIP、AMFI、EFI 或驱动。普通 Mac 默认安全配置下不能直接替换系统 Dock。
支持范围仍限于上述系统 build 和架构，尚未在另一台未安装 OCLP 的电脑上实际安装验证。

构建与包内清单见 [完整安装包构建](docs/完整安装包构建.md)。

## 独立启动台

本目录保留独立方案源码供参考；v1.4 发布附件只包含完整原生包。

独立 App 基于 MIT 许可的 [Lunchpad](https://github.com/arichyx/lunchpad)，
提供分页、文件夹、拖拽排序、搜索、触控板手势和可配置快捷键。
它与系统原版 Dock 分别运行，不修改系统 Dock 的显示器处理。
此界面是独立实现，不是 Apple 旧启动台的二进制界面。

从源码构建当前机器架构的 App 和迁移安装包：

```bash
./scripts/build-standalone-app.sh
./scripts/build-standalone-pkg.sh
```

构建产物为 `pkg/Lunchpad.zip`（内含 App）和
`pkg/LaunchpadRestore-Standalone-Migrate.pkg`。
双击迁移安装包后，它会把 App 放到 `/Applications`，尝试将旧启动台的
应用顺序与文件夹导入独立 App 的本地数据库；如果当前运行的是 Dock 2419，
还会从本机备份恢复原版 Dock，并要求重新启动。原生数据库保持只读。

重新启动后打开 `/Applications/Lunchpad.app` 即显示启动台；默认按 `Control-Shift-Space`
或点菜单栏九宫格图标显示启动台。快捷键和触控板手势可在 App 设置里调整。
页面容量会随屏幕大小调整，因此导入时保留相对顺序和文件夹结构，
不保证每页分界与旧 Dock 完全相同。

如果自动导入因当前布局数据库已存在而跳过，退出独立 App 后手动运行：

```bash
./scripts/import-native-layout.py --force
```

`--force` 会先备份现有独立布局，再替换；原生布局数据库始终只读。
独立 App 的源码和上游许可见 [standalone/](standalone/README.md)。

---

## 原生入口实验版（仅本机 macOS 26.7.1 x86_64）

静态检查显示 Dock 2427.6 仍包含旧启动台的 `Springboard` 等界面类，
但显示入口固定转向新版“应用”，启动时也不再创建旧界面的
`LPSpringboard` 实例。第一版实验包只修改入口分流；重启后 Dock 正常，
但原生启动台没有出现。第二版由 `scripts/build-native-entry-pkg.sh` 从本机原版备份生成，
恢复旧路径的实例创建和入口分流。第四版跳过显示器变化后的即时布局，但用户实测仍会闪退。
第五版把 `LPApp information gathering` 的最大并发限制为 1，但用户安装并重启后仍闪退。
第六版关闭旧启动台继承的背景模糊，用户安装并重启后仍以相同的 NVMTL IOSurface 写回越界路径闪退。
第七版只绕过旧启动台继承的 `Springboard.displayChanged` 回调，避免显示器重配置时更新旧窗口与图层。
用户已安装第七版并重启，14:47 的新报告仍在相同的 NVMTL IOSurface 写回路径崩溃。
检查后发现 `Springboard.scaleFactorChanged` 仍会把新缩放系数传给 Dock 的 `setScaleFactor:`。
第八版只跳过这个 setter，保留显示变化回调；分辨率切换后图标缩放可能暂时沿用旧值。
用户安装第八版并重启后仍在同一 NVMTL 写回路径崩溃。

第九版恢复原始显示与缩放回调，在启动 Dock 前为其应用域设置 `CAEnableMetalWhippet=false`，
让 CoreAnimation 的客户端位图绘制采用软件后端。已在独立的 IOSurface 绘制进程中通过调试器
确认由 Metal 切换到 `CA::OGL::SWContext`；原生图像压力测试和配置回滚测试通过。
2026-10-24 用户安装第九版并重启后，确认本次分辨率切换不再崩溃。该结果限于当前机器与本次验证；
位图生成可能增加 CPU 工作量。另收到启动初期两个图标短暂空白、反复开关后恢复的反馈，正在单独调查。

第九版历史本机构建产物为 `pkg/LaunchpadRestore-Native2427-2427.6.9.pkg` 和
`pkg/LaunchpadRestore-Native2427-Rollback.pkg`，未随 v1.4 发布。新安装请使用上方 2427.6.10 完整包。
上述历史包都要求重启；回滚包从
`/Library/Application Support/LaunchpadRestore/Dock.app.orig` 恢复本机原版。
安装器还会备份当前桌面用户的原始渲染设置，回滚时按原始存在性和值恢复；原设置备份为
`~/Library/Application Support/LaunchpadRestore/RenderBackend/original.plist`。
构建脚本严格核对本机系统版本、架构和原版 Dock 二进制哈希，不能用于其他版本。

---

## 旧版原生 Dock 移植方案

以下为 [v1.3 历史版本](https://github.com/GeekAudio/LaunchpadRestore/releases/tag/v1.3) 的 Dock 2419 方案，
不适用于本次 2427.6.10 完整包。Dock 2419 在本机 macOS 26.7.1 上已确认存在分辨率切换崩溃。

> **旧方案原理**：macOS 26.0 的 `Dock.app`（版本 `2419`）默认显示老启动台。
> 26.7.1 的 Dock 仍包含相关界面类，但显示入口固定转到新版“应用”界面。
> **只替换 `Dock.app` 就能恢复**——不需要关闭 SIP、不需要降级系统、
> 不需要替换 Spotlight 或 Apps。

---

## 旧方案效果

恢复后是原生的启动台，不是第三方仿制品：

- 全屏图标网格，左右翻页
- 拖拽排序、拖拽建文件夹
- 文件夹翻页
- 按 `F4` 或点 Dock **第二个图标**唤起
- 应用列表和你的原有布局来自系统本身

---

## 旧方案安装

1. 从 [v1.3 历史发布](https://github.com/GeekAudio/LaunchpadRestore/releases/tag/v1.3) 下载 [LaunchpadRestore-Install.pkg](https://github.com/GeekAudio/LaunchpadRestore/releases/download/v1.3/LaunchpadRestore-Install.pkg)
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

## 旧方案还原（v1.3 / Dock 2419）

从 [v1.3 历史发布](https://github.com/GeekAudio/LaunchpadRestore/releases/tag/v1.3) 下载 [LaunchpadRestore-Rollback.pkg](https://github.com/GeekAudio/LaunchpadRestore/releases/download/v1.3/LaunchpadRestore-Rollback.pkg) → 双击 → 输入密码 → 安装器最后一步点 **「重新启动」**。

安装时会**自动备份这台机器自己的 `Dock.app`** 到：

```
/Library/Application Support/LaunchpadRestore/Dock.app.orig
```

所以还原时换回的是**这台机器的原版**，不会串版本。这个目录别删。

---

## 旧方案兼容性（v1.3 / Dock 2419）

| 项目 | 要求 |
|---|---|
| 系统 | macOS **26.0 – 26.7**；26.7.1 的原生启动台仍处于实验修复验证阶段 |
| CPU | Intel `x86_64` / Apple Silicon `arm64e`（`Dock.app` 是通用二进制） |
| 前提 | `csrutil authenticated-root` 为 `disabled`（黑苹果 / OCLP 环境通常已满足） |
| 不需要 | 关闭 SIP、替换 Spotlight、替换 Apps、降级系统 |

**已经是目标版本时安装包会自动跳过替换**，但**仍会补装图标自检**，重复双击无害。

**已知兼容故障（26.7.1）**：恢复旧启动台后切换分辨率会使 Dock 闪退。原版 Dock 2427.6
在同机同驱动下正常。第五至第八版的缓解均未阻止崩溃。
第九版改用 Dock 应用自己的软件位图后端，2026-10-24 用户重启后确认本次分辨率切换正常；
启动初期短暂空白图标的反馈仍在调查。
排查记录见 [分辨率切换崩溃](docs/分辨率切换崩溃.md)。

---

## 旧方案具体做了什么

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

## 旧方案：系统更新后

每次 macOS 更新都会把 `Dock.app` 换回新版，启动台会消失。
**更新完重新双击安装包即可。**

如果系统跨了大版本（比如 26.x → 27.x），建议先删掉旧备份让安装包重新备份：

```bash
sudo rm -rf "/Library/Application Support/LaunchpadRestore/Dock.app.orig"
```

---

## 图标变空

先检查实际图像，不能仅凭 PNG 文件小就判为空图。当前原生 2427.6.9 的反馈是：
启动初期两个图标暂时空白，反复开关后恢复。2026-10-24 检查时，104 个应用的
208 张大、小图都有可见像素，没有持久空图；这不能排除启动当时的短暂问题。

下次仍空白时，可双击仓库内的 `scripts/diagnose-launchpad-icons.command`。它会立即记录全部
图标的像素检查、当前版本和最近 5 分钟的启动台相关日志，保存到
`~/Library/Logs/LaunchpadRestore/Icons/`；不需要先记住应用名称。
若缓存检查正常而界面仍空白，还需要当时的画面或应用名称才能定位具体显示项。

也可单独编译只读检查工具：

```bash
xcrun clang -fobjc-arc -Wall -Wextra -framework Foundation -framework CoreGraphics \
  -framework ImageIO -lsqlite3 native/launchpad-icon-audit.m -o /tmp/launchpad-icon-audit
/tmp/launchpad-icon-audit
```

输出 JSON 区分缺失、无法解码、完全透明和有可见像素；`--all` 可列出所有条目。
工具通过 `getconf DARWIN_USER_DIR` 定位当前用户的数据库，以只读事务检查真实 alpha，
不会写库或重启 Dock。最好在空白仍存在时运行。说明和隔离测试见
[native/launchpad-icon-audit.md](native/launchpad-icon-audit.md)。

仓库旧的 `fix-launchpad-icon.sh` 面向 Dock 2419：按压缩大小筛选、写图标缓存并重启 Dock。
其 `<5000` 字节阈值只是启发式判断，小而有效的图标也可能被选中，不能用于确认
本次 2427.6.9 的短暂空白。当前原生实验包没有部署该旧登录自检。

---

## 切换分辨率后 Dock 闪退（原生启动台实验版）

本机对照结果：原版 Dock 2427.6 在同一显卡驱动下切换分辨率正常；接入旧版
`Springboard` 启动台后，无论启动台开着还是关闭，切换分辨率都会使 Dock 闪退。
崩溃线程落在 `NVMTLDriver` 的 IOSurface 回写路径，但单看线程栈不能证明驱动是根因；
原生 Dock 对照正常，因此修复从本项目接入的启动台行为入手，不修改驱动。

崩溃时 `LPApp information gathering` 正通过 IconServices 获取图标，Dock 的 GPU 完成队列
同时在 NVMTL 的 IOSurface 回写路径崩溃。第四版跳过显示器变化后的布局，第五版限制图标采集并发，
第六版关闭背景模糊，第七版绕过旧启动台继承的 `Springboard.displayChanged` 回调，均未阻止崩溃。
第八版跳过 `Springboard.scaleFactorChanged` 中的 `setScaleFactor:` 调用，也已验证失败。
2026-10-24 用户安装第九版并重启后，确认本次分辨率切换不再闪退。第九版使用 Dock 应用自己的
软件位图后端，保留原生显示变化处理和动画；启动初期短暂空白图标的反馈仍在调查。详见
[分辨率切换崩溃记录](docs/分辨率切换崩溃.md)。

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
旧版 Dock 2419 已确认存在分辨率切换崩溃；其他 26.x 新增的 Dock 特性也可能缺失。

新版 Dock 2427.6 仍含有 `Springboard` 等旧界面类，但默认入口被固定到新版界面，
启动时也不再创建旧界面实例。第六版关闭背景模糊、第七版绕过显示变化回调、第八版跳过
`setScaleFactor:` 调用后仍闪退。

---

## 免责声明

- 本工具修改系统文件（`/System/Library/CoreServices/Dock.app`），**操作有风险**，请自行备份重要数据。
- `Dock.app` 版权归 **Apple Inc.** 所有。本仓库仅为个人学习与研究用途分发，请在 24 小时内删除，
  或改用自己从系统安装包中提取的文件。
- 使用本工具造成的任何后果由使用者自行承担。

## License

脚本部分：[MIT](LICENSE)
