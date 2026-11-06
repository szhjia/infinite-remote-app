# Xcode 和 Codex 的 macOS 界面评审流程

## 已配置和验证

- Xcode 27.0（27A266a），项目为 Swift Package，活动 Scheme 是 `Infinite Remote-Package`，目标为 `My Mac`。
- Xcode → Settings → Intelligence → Model Context Protocol 已允许外部 Agent。使用 Apple 官方桥接命令注册 Codex 后，`codex mcp get xcode` 显示启用、stdio、`xcrun mcpbridge`。
- 已验证 MCP 初始化、工具列表及 `XcodeOpenWorkspace`。后者返回当前 app 目录、Scheme 和 My Mac。继续调用 `RenderPreview` 时，Xcode 弹出了对测试客户端的访问许可，MCP 截图调用未返回图片。新 Codex 会话首次调用时，如 Xcode 询问是否允许当前 Codex 客户端，应在 Xcode 中核对客户端和项目后处理。
- 最初的 [246 × 156 PNG](assets/xcode-workspace-brand.png) 只渲染了 `WorkspaceBrand()`，用于验证导出。当前预览渲染与应用相同的 `Workspace`，已从 Xcode 导出 [首次使用](assets/xcode-first-run.png) 和 [遥控器工作台](assets/xcode-remote-workspace.png)，均为 2600 × 1496。独立设置窗口、媒体预览等跨窗口交互另用打包副本验证。

## 在 Codex 中调用 Xcode

从 Codex 开启新会话读取已写入的 MCP 配置。Xcode 打开本仓库的 `Package.swift` 或 app 文件夹。可直接给 Codex 以下任务：

> 使用 xcode MCP 打开 /Users/kimi/product/infinite-remote/app，确认目标是 My Mac。使用 RenderPreview 预览 Sources/RemoteDesk/WorkspacePreview.swift 并返回截图路径。若此项目的 MCP 预览无法渲染，报告 Xcode 返回的错误，使用 Xcode Canvas 的兼容预览及 Export Preview Screenshot。

Apple 官方的配置命令，可用于在另一台开发机上复现。

```sh
codex mcp add xcode -- xcrun mcpbridge
codex mcp get xcode
```

- [Apple · Giving external agents access to Xcode](https://developer.apple.com/documentation/xcode/giving-external-agents-access-to-xcode)

## 使用 Canvas 快速对照静态界面

1. 在 Xcode 打开 [WorkspacePreview.swift](../../Sources/RemoteDesk/WorkspacePreview.swift)，开启 Canvas 并刷新。选择「首次使用」或「遥控器工作台」。后一项使用测试型号包和模拟的监听状态。
2. 当前 SwiftPM executable 的默认预览会报告需要 `ENABLE_DEBUG_DYLIB=YES`。在本工作区已用 **Editor → Canvas → Use Legacy Previews Execution** 跑通，刷新后可查看画布。
3. 用 **Editor → Canvas → Export Preview Screenshot** 保存 PNG。修改外观或示例数据后分别导出，以便并排评审。
4. 后续页面改造时，再为待安装、已连接未监听、诊断和有草稿等状态补 Debug 示例。通过现有依赖注入入口给权限和 HID 固定状态，应用设置用独立数据目录。
5. 如果后续需要稳定使用新版预览引擎或 CI 快照，可评估单独的 macOS App 预览宿主，复用真实视图和开发示例数据。Apple 的新版布局默认面向满足调试构建条件的 bundled executable target。

- [Apple · Adding previews to your interface files](https://developer.apple.com/documentation/xcode/adding-previews-to-your-interface-files)
- [Apple · Understanding build product layout changes in Xcode](https://developer.apple.com/documentation/xcode/understanding-build-product-layout-changes)

## 用 Mac 原生窗口验收交互

预览适合快速检查布局、语言、外观和单页状态。本项目的菜单栏、AppKit 浮窗、焦点、系统权限、蓝牙和实体按键使用实际 macOS 窗口验收。用独立 Bundle ID 和 `INFINITE_REMOTE_DATA_DIR` 运行 QA 包，配合 Codex 电脑工具逐步操作和截屏。权限、硬件触发、锁屏或媒体启动等验证在对应测试条件下单独执行。Xcode → Open Developer Tool → Accessibility Inspector 可直接检查运行中的 macOS App。

- [Apple · Accessibility Inspector](https://developer.apple.com/documentation/accessibility/accessibility-inspector)
