# 遥控台 · RemoteDesk

在 macOS 上用蓝牙遥控器切换和操作 Coding Agent。首版为「小米蓝牙遥控器 2 Pro」提供与说明书一致的 13 键布局；其他被系统识别为蓝牙 HID 的遥控器可从通用布局开始录入。

## 使用

1. 双击 `dist/RemoteDesk.app`（macOS 14 或更新版本）。在系统蓝牙设置配对遥控器。
2. 从设备菜单选择「小米蓝牙语音遥控器」。本机枚举的型号编号为 `2717:32B8`。如果提示「已连接 · 未监听」，设备已经配对，按键读取仍未开启。
3. 在应用左侧选择「开启输入监控」，在系统设置允许 RemoteDesk。返回应用。若 macOS 提示重新打开，请退出再打开。
4. 点击图上的「确定」，点「录入按键」，按一下遥控器的确定键。绿色圆点代表已录入。每个需要使用的键录一次。
5. 选左侧的 Agent，为键位配置动作，或使用「试运行」先确认动作有效。快捷键动作需要额外开启「辅助功能」。
6. 关掉主窗口后菜单栏仍可恢复窗口、暂停遥控或退出。暂停时可打开「按键诊断」观察信号；诊断窗口内也不会触发动作。

| 方案 | 默认动作 | 可配置内容 |
| --- | --- | --- |
| ChatGPT | 确定键打开 ChatGPT 网页 | 可选择桌面应用、配置网页地址；支持已有桌面 Chat Bar 的 ⌥Space 动作 |
| Codex | 主页新建对话（⌘N），确定发送当前草稿（⌘Return），返回停止生成（Esc） | 选择安装位置，按 Codex 设置调整快捷键 |
| Cursor | 确定键打开桌面应用 | 选择安装位置，录入当前版本的快捷键 |
| Claude Code · 终端 | 确定键打开终端 | 先在所选终端中运行 Claude Code，再按需录入终端快捷键 |
| 自定义 | 无 | 自行选择目标应用、网页和快捷键 |

小米布局的菜单键默认切换到下一个 Agent；可在各方案内修改或删除。通用布局的第一个键继承各预置方案的打开动作。实体信号保存在遥控器配置中，动作保存在 Agent 方案中；修改其中一项不需要重新设置另一项。配置文件位于 `~/Library/Application Support/RemoteDesk/configuration.json`。

使用 Codex 三键前，分别录入「主页」「确定」「返回」，选择 Codex 方案并开启遥控台的「辅助功能」权限。返回键沿用 Codex 对 Esc 的处理，若出现停止确认，再按一次返回。升级时，已存在的原始 Codex 方案会获得这三个动作，用户自定义过的方案会原样保留。

当前读取的是 macOS 公开的 HID 按键信号。遥控器原本的系统行为仍可能同时生效；红外键、厂商自定义音频报告和麦克风音频不在此版范围内。界面上有键位不代表该键一定向 Mac 上报，使用「按键诊断」确认。应用只对选中的蓝牙 HID 处理按键信号，不需要账号或 API Key。

## 开发与构建

安装带 Swift 6 的 Xcode 或命令行工具：

```sh
swift test
./scripts/build-app.sh
open dist/RemoteDesk.app
```

构建脚本生成本机架构、临时签名的应用包，供当前 Mac 使用。

- `RemoteCore`：设备标识、按键信号、按下沿、Agent 方案和版本化配置，只有 Foundation 依赖。
- `RemoteDesk`：SwiftUI 设置与菜单栏、IOKit HID 监听、NSWorkspace 与 Quartz 动作。
- Windows 的输入端建议使用 [Raw Input](https://learn.microsoft.com/en-us/windows/win32/inputdev/raw-input)，外壳可用 WinUI 3。延续设备 → 按键 → 方案 → 动作的数据结构，按平台重录物理键和快捷键。参见 [平台边界](docs/architecture.md)。
