---
name: infinite-remote-release
description: 为 Infinite Remote macOS App 重新打包、签名、提交 Apple 公证、发布 GitHub Release 或验收公开下载。适用于这个 App 的 DMG/ZIP 交付及版本重启，不处理型号包发布或日常开发构建。
---

# 发布 Infinite Remote

在工作区的 `app/` 仓库执行；官网在独立的 `website/` 仓库，型号包维护源是 `remote-hub/`。分别确认仓库和工作目录。

## 先确定要交付的版本

- 先确认本次要交付的改动及验收项（尤其是用户要求的新界面）。检查工作树和暂存区，包含未跟踪文件；逐项确认发布范围内的改动都已进候选提交。发现遗漏先补齐；有无关改动就保留在原工作树，另在干净工作树发布，不能靠藏起改动让检查通过。用户只要本地测试包时可使用当前未提交改动，但需注明来源。
- 经授权提交、推送后，记录审阅过的**完整源码 SHA**。公开发行时，它必须与干净工作树的 `HEAD`、GitHub 上 `szhjia/infinite-remote-app` 的实时 `main` 一致。即使显示版本相同，也不能沿用旧提交、旧候选包或已安装副本。GitHub `main` 有新提交时重新核对发布范围、测试并打包。
- 从 `scripts/Info.plist` 读取并核对产品版本、内部构建号、Bundle ID；从二进制读取架构。常规发布递增构建号；版本和构建号重置只按用户明确指示执行。重置后已有同名标签是单独的决策，删除 Release 不删除、不重指标签。
- 用户已持续授权本技能在 Infinite Remote 发布流程中自动把待发布的签名产物上传到 Apple 公证服务，无需逐次询问。只要求本地打包时，在本地验证后停下；GitHub 发布或删除、推送标签、官网部署及卸载本机 App 各自按授权执行。卸载只移除明确指定的应用包；配对、配置、权限和用户数据不随包清除。

## 打包与签名

1. 公开 DMG（包括 Sparkle）的唯一打包入口是 `bash scripts/package-public-dmg.sh <完整源码 SHA>`。通过环境变量 `REMOTEDESK_SIGNING_IDENTITY` 显式指定本机的 **Developer ID Application** 身份。脚本打包前后都检查工作树、HEAD 和实时 GitHub `main`；仅导出该提交的已跟踪文件，在全新临时目录以锁定的依赖运行默认并发测试、编译和签名，再将本次 DMG 输出到新的候选目录。任何一步失败都停下处理，不绕开入口、重用旧包或把失败结果标为可发布。
2. 本地测试包可先运行 `bash scripts/build-app.sh`，再运行 `bash scripts/package-dmg.sh "dist/Infinite Remote.app" [DMG 输出路径]`。此底层脚本只封装明确指定的 App，不编译源码。 `bash scripts/package-release.sh` 可生成本地 ZIP 和 SHA-256；若额外公开 ZIP，必须从本次正式候选 DMG 取出同一个带源码 SHA 的签名 App，按下文公证和装订后压缩。
3. 只读挂载本次 DMG。用 `plutil -extract InfiniteRemoteSourceCommit raw "<挂载后的 App>/Contents/Info.plist"` 核对包内签名的源码 SHA，核对版本、构建号、架构、证书团队和 Bundle ID。用 `codesign --verify --strict --deep <App>`、`codesign --verify --verbose <DMG>` 和 `hdiutil verify <DMG>` 检查签名和镜像；确认 Developer ID、Hardened Runtime 和安全时间戳。用 Finder 查看淡紫背景和向右循环移动的箭头，确认 App 在左侧、指向 `/Applications` 的快捷方式在右侧。用本次包中的 App 实测本次改动，尤其是用户要求的界面或行为；已安装副本不能代验。

## Apple 公证与首次打开

- 公证的是待分发的确切产物；先公证和验收，再发布 GitHub。使用 `xcrun notarytool submit <DMG> --keychain-profile <profile> --output-format json`。本机已用过的 profile 名为 `infinite-remote-notary`；先确认当前环境可用，凭证留在钥匙串。记录提交 ID，用 `notarytool info` 或有界的 `notarytool wait` 跟踪。只有 `Accepted` 才算通过；失败查该 ID 的 `notarytool log`，避免重复提交同一文件。
- 对 DMG 执行 `xcrun stapler staple` 和 `xcrun stapler validate`。若也分发 ZIP，从本次 DMG 取出同一签名的 App，验证是否能取得 App 自己的票据；拿不到就单独公证 ZIP。ZIP 不能直接装订：装订 App 后重新压缩。票据装订后再生成最终的 SHA-256，后续不重签、不修改已公证的可执行内容。
- 验证最终包：签名、票据、校验和；在 Gatekeeper 开启的环境用 `spctl --assess --type execute --verbose=4 <App>` 验证从最终包取出的 App。尽量在干净环境从真实下载包首次打开，核对版本及本次改动；不要清除隔离属性或降低系统保护来取得通过。签名通过、Apple 接受、票据验证通过、Gatekeeper 通过、首次打开通过分别记录。

## GitHub 与官网

- 在已授权发布时，再查 GitHub `main` 和发布标签最终指向的提交（附注标签需解引用）。它们必须和候选 DMG 内签名的源码 SHA 一致。任何不一致都停止；不能拿旧标签挂新代码。将最终 DMG/ZIP 和各自 SHA-256 上传至 `szhjia/infinite-remote-app` 的目标 Release。重新从 GitHub 下载，比较实际下载文件与本地产物的 SHA-256；验证 Release、标签提交和附件名。
- Sparkle 更新使用同一个已公证、已装订的 DMG。从与 `Package.swift` 中锁定版本一致的 [Sparkle 官方发行包](https://github.com/sparkle-project/Sparkle/releases)取出工具，执行 `SPARKLE_BIN_DIR=/absolute/path/to/bin ./scripts/generate-appcast.sh <final.dmg> RELEASE_NOTES.md`。脚本用登录钥匙串中的 `infinite-remote` 账户签名，并将签名后的清单写入 `dist/appcast.xml`。保留更新签名私钥的加密离线备份，签名后保持 DMG 和 XML 的原始字节。
- 待 Release 附件已公开且下载校验通过，把生成的 XML 原样复制到独立官网仓库的 `public/appcast.xml`。官网发布后核对线上清单和本地字节一致，再用低一个构建号的、已接入 Sparkle 的安装副本走一次检查、下载、安装、重启。核对新构建号、按键映射、辅助功能及输入监控授权。首个内置 Sparkle 的版本由旧版用户手动覆盖安装。
- 如需删除 Releases，先列出确切目标和附件；按授权删除指定 Release，并查询 GitHub API 验证剩余已发布条目。是否保留备份以用户指示为准，不把删除 Release 当成删除标签。
- 官网 `website/src/lib/release.ts` 单独维护版本、构建号与资产 URL。先保证新附件公开可下载，再按授权更新部署；从公开官网走一遍下载链接。若旧链接已失效且官网未更新，单独报告。
- 每次交付总结注明源码 SHA（以及是否包含未提交改动）、版本/构建号/架构、最终文件和 SHA-256、公证提交 ID 与结果、首次打开与公开下载的实测结果。遇到可复用的新差异，把有效修正补进本技能，不记录凭证、临时路径或一时的发布状态。

Apple 参考：[公证要求](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)、[公证流程和票据装订](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)、[分发打包和验证](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)。
