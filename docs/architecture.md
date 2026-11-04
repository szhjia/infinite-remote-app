# 平台边界

Mac 首版用 SwiftUI + SwiftPM，无外部依赖。硬件监听和应用动作各有独立入口，配置模型不依赖任何 macOS UI 或设备 API。

```text
macOS 蓝牙配对 → IOHIDManager → InputEdges → InputCode
                                               ↓
                                      选中设备的实体键位
                                               ↓
                                    当前 Agent 对应的动作
                                               ↓
                                      NSWorkspace / Quartz
```

- 使用非独占的 [IOHIDManager 输入回调](https://developer.apple.com/documentation/iokit/1438367-iohidmanagerregisterinputvalueca)，只匹配系统已连接的蓝牙 HID。用户明确选择输入设备后才处理它的按键；设备拔除清理按下状态。
- 持久化的设备标识由厂商、产品、设备名和可用的序列号组成；无序列号的同型号同名设备可能无法区分。按键信号用应用集合、Usage Page、Usage、Report ID 与激活值表示。端点 ID 和 element cookie 只用于进程内检测按下沿。
- 系统确认存在小米 2 Pro 对应的 `2717:32B8` 时，首次选中它会默认展示 13 键模板。当前机器读取到的 HID 描述符有一组键盘输入和三组厂商报告。键位模板来自说明书，具体物理键通过真实信号录入。
- 学习模式消费第一个有效按下沿并保存，不运行 Agent 动作。同一信号重新录入到另一个键位时从原键位移除。无冲突时多个 Agent 可共享同一物理映射。
- 普通快捷键使用目标进程的 PID，不向当前任意窗口广播。ChatGPT Chat Bar 是例外：按 [OpenAI 文档](https://help.openai.com/en/articles/9295241-accessing-the-launcher-chatgpt-macos-app) 向系统发送 ⌥Space，并先检查支持 Chat Bar 的应用已运行。macOS 将读取键盘与发送快捷键的权限分开。
- Windows 版建议用 WinUI 3 构建窗口、托盘与设置，用 Raw Input 的设备句柄和 HID Usage 录入信号、使用系统 API 启动程序。快捷键需要 Windows 单独处理焦点、权限与键码，不能直接复制 Mac 的发送方式。版本化 JSON 可作为交换约定，设备指纹、目标应用路径和键码需在目标平台确认或替换。
