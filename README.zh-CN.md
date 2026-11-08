# 无限遥控器 · Infinite Remote

[官网](https://szhjia.github.io/infinite-remote-website/zh/) · [English version](README.md)

通过独立安装的遥控器型号包操作 macOS 和所选应用。首个适配型号是小米蓝牙遥控器 2 Pro（`2717:32B8`）。支持 macOS 14 起，macOS 26 及以上使用系统的 Liquid Glass 工具栏控件。

GitHub 仓库为 `szhjia/infinite-remote-app`。

## v0.0.4 版本

从 [GitHub Releases](https://github.com/szhjia/infinite-remote-app/releases/tag/v0.0.4) 下载 DMG，打开后把无限遥控器拖进「应用程序」。安装包适用于运行 macOS 14 或更高版本的 Apple 芯片 Mac。签名详见[发布说明](RELEASE_NOTES.md)。运行 `./scripts/package-release.sh` 可生成 ZIP 归档。

旧版用户需先手动覆盖安装一次，之后可在应用菜单或状态栏菜单选择「检查更新…」。

## 使用

1. 启动 `dist/Infinite Remote.app`。新安装不内置真实遥控器型号。首次引导依次介绍添加型号、输入监控、辅助功能和连接检查，任一步都可跳过，之后可从「设置」重新打开。界面跟随系统语言，其他语言回退到英语。
2. 打开侧栏「资源库」，从可用订阅源添加型号，或点「导入 ZIP…」直接选择本地 ZIP，也支持已解压的型号文件夹。ZIP 无需提前解压。已安装型号显示在侧栏，未连接时也能选择，离线仍可使用。
3. 在 macOS 蓝牙设置配对遥控器，并选择已安装的对应型号。先授予「辅助功能」，如果应用仍无法读取按键，再单独授予「输入监控」。授权后回到应用重新检查，按系统提示重新打开应用。
4. 在对应行选择单击、双击或长按动作，再点「保存」。不能识别的信号可选中对应行，从「恢复默认」旁菜单选择「手动校准当前键」。型号提供的默认动作可另存为命名配置；用户映射和校准记录独立于资源保存。
5. 工具栏可暂停响应，工作台标题栏控制浮动遥控器模型。模型左上角或右键菜单可以打开或关闭工作台。工作台首次打开后，菜单栏图标会出现，可以分别恢复两个窗口。诊断会显示按下与松开，期间暂停应用自身的配置动作。
6. 在「设置 → 多媒体设置」选择最多九个本机应用。使用小米包默认映射时，直播键打开选择器，左右移动、确定打开、返回关闭。「恢复默认」旁菜单提供个人配置选择、导入和导出。

「设置」独立管理 HTTPS 订阅源。刷新只检查目录，添加和更新需明确点击。同一型号只能由原来源提供更高 release 更新，本地 ZIP 导入也归属于本地来源，其他来源不能覆盖。移除订阅不删除已安装型号；刷新失败时保留上次成功目录。

应用预配置官方源地址 `https://raw.githubusercontent.com/szhjia/infinite-remote-hub/main/catalog.json`。官方公开源独立提供目录、型号 ZIP 和图片，可在资源库中刷新并安装，无需等待应用更新。本地 ZIP 导入独立可用，应用构建不会自动发布资源。

以下默认动作来自小米 v2 型号包：

| 实体键 | 默认动作 |
| --- | --- |
| 电源 | 短按关闭支持 DDC/CI 电源控制的外接屏，并把内置屏亮度降至最低。再按先恢复内置屏亮度，再尝试打开外接屏。长按立即锁定屏幕 |
| 语音 | Codex 听写 |
| 方向 | ↑ ↓ ← → |
| 确定 | Return |
| 返回 | Esc |
| 主页 | 激活型号指定的目标应用（初始为 Codex） |
| 音量加减 | 调整系统音量 |
| 菜单 | 打开正在运行的应用切换器 |
| 直播 | 媒体应用选择器 |

在 ChatGPT 设置中将「听写快捷键」设为 F5。如果「点按一次听写」已绑定回车，解除该绑定。聚焦 Codex 输入框，按住遥控器麦克风键说话，松开后等文字进入输入框。可把「确定」配置为「⌘Return」以发送转写。F5 由 ChatGPT 直接接收，无限遥控器的暂停和诊断模式只影响无限遥控器自己的动作。

「选择系统快捷键」只读取 macOS 当前启用的组合。可在系统设置中调整组合，再回到无限遥控器刷新选择。没有分配动作的音量等按键可继续由 macOS 自己处理。无限遥控器监听非独占 HID，配置动作可能和遥控器原有系统行为并行。

配置保存在 `~/Library/Application Support/RemoteDesk/configuration.json`。从旧版迁移时，应用在同目录保留原配置备份。

## 开发与构建

使用带 Swift 6 的 Xcode 或命令行工具：

```sh
swift build
swift test
./scripts/build-app.sh
open "dist/Infinite Remote.app"
```

构建脚本生成本机架构的应用包。默认使用临时签名，二进制变动后 macOS 可能会重新要求输入监控和辅助功能授权。需要反复调试实体遥控器时，可先用 `security find-identity -v -p codesigning` 查看钥匙串里的签名身份，再用同一个 Apple Development 身份构建：

```sh
REMOTEDESK_SIGNING_IDENTITY='Apple Development: 你的证书名称' ./scripts/build-app.sh
```

也可以把 `security find-identity` 显示的证书指纹单独写入 `dist/.signing-identity`，供本机后续构建使用。显式设置的环境变量优先。

换用固定签名后，首次运行时重新授权。后续开发构建继续使用同一签名身份和应用标识。[平台与输入边界](docs/architecture.md)。

## 遥控器型号包

在工作台中间栏打开「显示设备说明」可查看机身引线。点击机身或引线标签可定位到按键配置，点击 NFC 标记可查看触碰位置及硬件说明。

「资源库 → 导入 ZIP…」接受本地 ZIP 或型号文件夹，资源复制到 `~/Library/Application Support/RemoteDesk/RemoteModels/`。小米型号源文件、说明和协议由独立 Remote Hub 仓库维护；正式应用不内置真实型号，旧版 v1 资源只作为测试夹具保留。

- `manifest.json` v2 声明稳定型号及设备 ID、三段数字 `release`、型号/品牌/简介/硬件说明的本地化文字、可选包内品牌 PNG、默认动作、目标应用 bundle ID 和输入行为。英语为必需回退，中文跟随系统语言；仍兼容读取 v1 包。
- `layout.json` 声明 PNG 尺寸、可见机身矩形、按键名称、热区和硬件说明锚点。中心和宽高为相对整张 PNG 的归一化坐标，原点在左上；支持椭圆、矩形与扇区。手势标记提供 `-double`/`-long` 动作槽；更新不能移除已被配置引用的槽。
- `inputs.json` 将 HID collection/page/usage 信号映射到实体键，可附加 report/value/array 规则；用户校准优先。默认动作和型号行为来自经过校验的声明，不由运行时品牌分支决定。
- ZIP 只含一个型号根目录及其资源。安装先校验路径、图片、跨文件引用和动作声明；订阅下载还核对哈希、型号和版本，并检查来源归属及设备冲突。失败更新保留已安装包与用户配置。

可使用独立 hub 的 `export-source --output PATH` 显式生成 `catalog.json`、`packages/` 和 `assets/`，之后再发布订阅。应用构建不读取兄弟仓库，也不发布导出文件。
[小米 2 Pro 手机说明](docs/xiaomi-2-pro-guide.md) 包含机身图、配对步骤和排障说明，可作为 NFC 打开说明页的目标。NFC 说明针对遥控器硬件。无限遥控器当前未接入原装 NFC 标签。验证「碰一碰打开设备说明」时，可先用手机只读检查原装标签，再用独立可移除的标签写入设备说明的 HTTPS 链接，并分别验证手机读取和 Mac 输入诊断。

## Star 历史

[![Star History Chart](https://api.star-history.com/svg?repos=szhjia/infinite-remote-app&type=Date)](https://star-history.com/#szhjia/infinite-remote-app&Date)

## 许可证

Copyright (C) 2026 Infinite Remote contributors.

本项目采用 [GNU 通用公共许可证第 3 版或（由你选择）任何更新版本](LICENSE)（`GPL-3.0-or-later`）。允许商业使用；对外分发本软件或衍生作品时，必须遵守 GPL 关于对应源码和相同授权的要求。

第三方组件和素材保留其原有许可证。见内置的 [Tabler 许可证声明](Sources/RemoteDesk/Resources/LICENSE-Tabler.txt)。
