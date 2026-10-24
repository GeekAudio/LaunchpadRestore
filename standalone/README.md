# 独立启动台源码

本目录基于 [Lunchpad](https://github.com/arichyx/lunchpad) 的
`05bda1c6fe6cbe306ed01157487401f12794ca9c` 版本，按 MIT 许可收录。
原作者版权和许可见 [LICENSE.upstream](LICENSE.upstream)。

此 App 作为独立进程运行，不替换系统 Dock。项目另提供
`scripts/import-native-layout.py`，将旧启动台的页面顺序和文件夹结构
导入该 App 的本地数据库。打包脚本根据
`Packaging/generate-icon.swift` 生成项目自己的图标；上游图标
许可尚未确认，因此未收录。

构建命令：`./scripts/build-standalone-app.sh`（从仓库根目录执行）。
