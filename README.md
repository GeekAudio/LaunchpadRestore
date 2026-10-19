# LaunchpadRestore

把 macOS 26 上被砍掉的**原生启动台（Launchpad）**找回来。

> **一句话原理**：macOS 26.0 的 `Dock.app`（版本 `2419`）里还完整保留着老启动台的界面代码，
> 26.1 之后被苹果删掉了。**只替换 `Dock.app` 就能恢复**——不需要关闭 SIP、不需要降级系统、
> 不需要替换 Spotlight 或 Apps。

---

## 效果

恢复后是原生的启动台，不是第三方仿制品：

- 全屏图标网格，左右翻页
- 拖拽排序、拖拽建文件夹
- 文件夹翻页
- 按 `F4` 或点 Dock 最左边的图标唤起
- 应用列表和你的原有布局来自系统本身

---

## 安装

1. 下载 [`pkg/LaunchpadRestore-Install.pkg`](pkg/LaunchpadRestore-Install.pkg)
2. 双击 → 输入登录密码 → **重启**

> 包未签名。如果提示「无法验证开发者」：**右键点 pkg → 打开 → 再点「打开」**。
>
> 或者用命令行：
> ```bash
> sudo installer -pkg LaunchpadRestore-Install.pkg -target /
> ```

重启后点 Dock 最左边的图标（或按 `F4`）就是老启动台。

---

## 还原

双击 [`pkg/LaunchpadRestore-Rollback.pkg`](pkg/LaunchpadRestore-Rollback.pkg) → 输入密码 → 重启。

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

`postinstall` 脚本（[`scripts/postinstall-install.sh`](scripts/postinstall-install.sh)）执行四步：

1. 用 `ditto` 备份当前 `Dock.app` → `/Library/Application Support/LaunchpadRestore/`
2. 动态定位系统卷（`disk` 编号会变，不能写死），以 `-o nobrowse` 挂到 `/System/Volumes/Update/mnt1`
3. 替换 `mnt1/System/Library/CoreServices/Dock.app` 为 26.0 版（`2419`）
4. `bless --mount ... --bootefi --create-snapshot` 重建系统快照

> 第 4 步是关键：macOS 11+ 的系统卷是只读快照，**不重建快照则改动不会生效**。

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

## 出问题怎么办

如果重启后 Dock 崩溃 / 黑屏 / 没有桌面：

1. 长按电源键关机，开机按住 `Cmd+R` 进恢复模式
2. 菜单栏「实用工具」→「终端」
3. 把备份换回去（卷名换成你的系统盘名）：

```bash
cp -R "/Volumes/Macintosh HD/Library/Application Support/LaunchpadRestore/Dock.app.orig" \
      "/Volumes/Macintosh HD/System/Library/CoreServices/Dock.app"
```

4. 重启

---

## 已知取舍

`Dock.app` 版本 `2419` 是 26.0 的，比 26.7.1 落后 7 个小版本，缺少 26.1–26.7 的 Dock 修复。
目前实测未发现异常，但个别 26.x 新增的 Dock 特性可能缺失。

如果你手上有更接近的新版本（比如 26.5、26.6 的 `Dock.app`，且仍保留启动台代码），
可以用 [`scripts/build-pkg.sh`](scripts/build-pkg.sh) 自行打包。

---

## 为什么不是「放一个 Launchpad.app」

这条路试过，走不通。26 的 `Launchpad.app` 只有 **99 KB**，它只是个触发器——发一条
`com.apple.launchpad.toggle` 就退出，**界面完全由 Dock 绘制**。所以：

- 放 `Launchpad.app` → 进程启动即退，Dock 无反应
- 改 bundle id → 无效
- 改 `com.apple.dock showSpotlightBasedLaunchpad` 偏好 → Dock 根本不读这个键
- 只写 `SpotlightPlus` FeatureFlag → 无效（`Apps.app` 没声明 `LSRequiredFeatureFlags`，开关没有作用对象）

详见 [`docs/原理.md`](docs/原理.md)。

---

## 免责声明

- 本工具修改系统文件（`/System/Library/CoreServices/Dock.app`），**操作有风险**，请自行备份重要数据。
- `Dock.app` 版权归 **Apple Inc.** 所有。本仓库仅为个人学习与研究用途分发，请在 24 小时内删除，
  或改用自己从系统安装包中提取的文件。
- 使用本工具造成的任何后果由使用者自行承担。

## License

脚本部分：[MIT](LICENSE)
