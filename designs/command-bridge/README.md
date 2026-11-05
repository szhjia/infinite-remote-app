# RemoteDesk · Command Bridge

左侧是带圆孔的实体按键，右侧是命令箭头。macOS 使用蓝紫色底板，Windows 使用透明底和同样的标记，并提供浅色与深色主题配色。小尺寸版扩大圆孔和两部分之间的留白。监听状态使用箭头，暂停状态使用双竖线，macOS 的未监听状态使用横线。

## macOS

- `macOS/RemoteDesk.icns` 包含 16、32、128、256、512 pt 的 1× 和 2× 图像，可用作应用包图标。`RemoteDesk-1024.png` 是透明底大图，`App/` 提供独立的 16 和 32 px PNG。
- `macOS/MenuBar/` 提供监听、暂停、未监听三种状态的 20×18 pt 菜单栏模板，包含 SVG 源文件和 1×、2× PNG。三种状态共用实底圆角矩形，遥控器和状态符号以透明镂空呈现。可在 `menu-bar-comparison.png` 查看 Dock 与菜单栏图形的浅色和深色对照。
- `macOS/UI/` 提供 16 和 24 pt 的 1×、2× 功能模板图像。`@2x` 前的名称与 1× 一致。

## Windows

- `Windows/RemoteDesk.ico` 是通用应用图标，另外提供 `RemoteDesk-light.ico` 和 `RemoteDesk-dark.ico`。每个 ICO 包含 16、20、24、32、40、48、64、96、128 和 256 px。`Source/` 包含三个对应的 SVG 母版，精调的小尺寸版本见导出的 PNG。
- `Windows/Tray/` 提供监听、暂停在浅色和深色任务栏上的 ICO，各含 16、20、24、32、40、48 和 64 px。同目录保留 16 和 32 px PNG 供检查或单独使用。
- `Windows/WinUI/` 提供 AppList 的默认、浅色和深色目标尺寸 PNG，以及 AppList、MedTile 和 StoreLogo 的基础图与 100%、200%、400% 缩放资源。实际打包时由应用清单引用所用资源。[Microsoft 图标资源命名](https://learn.microsoft.com/en-us/windows/apps/design/iconography/app-icon-construction)
- `Windows/UI/` 提供同一套功能图标的 24×24 SVG。单色路径使用 `currentColor`，可在接入时绑定前景色或在导入前替换成所需色值。

## 功能图标

| 文件名 | 用途 |
| --- | --- |
| `device` | 遥控器设备 |
| `profiles` | Agent 方案 |
| `mapping` | 按键映射 |
| `learn` | 录入实体按键 |
| `diagnostics` | 按键信号诊断 |
| `run` | 试运行 |

功能图标选自 Tabler Icons v3.46.0，MIT 许可附在两套资源的 `UI/` 目录中。[Tabler Icons 许可](https://tabler.io/license)

## 像素检查

在 `preview-16-32.png` 中以 100% 查看实际的 16 和 32 px 应用图标，同时查看 3× 最近邻放大图。菜单栏预览使用实际导出的 1× 和 2× 图像。浅、深两种底色下均检查了圆孔、箭头间距和暂停双竖线。

`.icns` 已通过 macOS `iconutil` 解包检查。Windows `.ico` 已逐帧解码检查尺寸和透明通道。Windows 任务栏实机验收留待应用接入时进行。
