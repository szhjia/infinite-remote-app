---
name: infinite-remote-release
description: 为 Infinite Remote macOS App 重新打包、签名、提交 Apple 公证、发布 GitHub Release 或验收公开下载。适用于这个 App 的 DMG/ZIP 交付及版本重启，不处理型号包发布或日常开发构建。
---

# 发布 Infinite Remote

在工作区的 `app/` 仓库执行；官网在独立的 `website/` 仓库，型号包维护源是 `remote-hub/`。分别确认仓库和工作目录。

## 先确定要交付的版本

- 核对本地分支、HEAD、远端目标分支、工作树差异和标签。记录产物来自哪个提交、是否包含未提交的改动。用户要求用当前改动做本地包时可直接打包；公开发布前核对标签实际指向产物源码，不能拿旧标签挂新代码。
- 从 `scripts/Info.plist` 读取并核对产品版本、内部构建号、Bundle ID；从二进制读取架构。常规发布递增构建号；版本和构建号重置只按用户明确指示执行。重置后已有同名标签是单独的决策，删除 Release 不删除、不重指标签。
- 用户已持续授权本技能在 Infinite Remote 发布流程中自动把待发布的签名产物上传到 Apple 公证服务，无需逐次询问。只要求本地打包时，在本地验证后停下；GitHub 发布或删除、推送标签、官网部署及卸载本机 App 各自按授权执行。卸载只移除明确指定的应用包；配对、配置、权限和用户数据不随包清除。

## 打包与签名

1. 运行 `swift test`，确认交付源码通过。若外层沙箱只阻止 SwiftPM 启动自己的构建沙箱，可用 `swift test --disable-sandbox` 重新验证。测试失败时不要把产物标为可发布。
2. 用 `scripts/build-app.sh` 构建 App。制作 DMG 时运行 `scripts/package-dmg.sh [App 路径 [DMG 输出路径]]`，默认读取 `dist/Infinite Remote.app`，按版本、构建号和架构命名。脚本以 `scripts/dmg-assets/installer-template.dmg` 保留 0.0.2 build 3 的原始窗口布局，原位写入 `installation-arrow.gif` 以保留 Finder 对背景的引用。交付前只读挂载并在 Finder 打开，确认淡紫背景上的箭头循环向右移动，左侧为 App，右侧为指向 `/Applications` 的快捷方式。ZIP 及其 SHA-256 由 `scripts/package-release.sh` 生成。
3. 对公开发行使用本机可用的 **Developer ID Application** 签名身份，核对证书团队和 Bundle ID。开发用签名或 `dist/.signing-identity` 不能直接作为发布证据。用 Hardened Runtime 和安全时间戳签名 App，再用该签名身份打包 DMG。核对包内的版本、构建号、架构和改动；用 `codesign --verify --strict --deep <App>`、`codesign --verify --verbose <DMG>` 和 `hdiutil verify <DMG>` 分别检查签名和镜像。已有已安装 App 或旧 `dist` 产物不能代替本次验收。

## Apple 公证与首次打开

- 公证的是待分发的确切产物；先公证和验收，再发布 GitHub。使用 `xcrun notarytool submit <DMG> --keychain-profile <profile> --output-format json`。本机已用过的 profile 名为 `infinite-remote-notary`；先确认当前环境可用，凭证留在钥匙串。记录提交 ID，用 `notarytool info` 或有界的 `notarytool wait` 跟踪。只有 `Accepted` 才算通过；失败查该 ID 的 `notarytool log`，避免重复提交同一文件。
- 对 DMG 执行 `xcrun stapler staple` 和 `xcrun stapler validate`。ZIP 不能直接装订；如也分发 ZIP，先取得并验证 ZIP 所含 App 的公证票据，装订 App 后重新压缩。若同时分发 DMG 和 ZIP，可以先公证 App 的 ZIP、装订 App 并重打 ZIP，再用该 App 制作并公证最终 DMG；也可先公证 DMG，再检查同一签名 App 是否能取到自己的票据。拿不到 App 票据就单独公证 ZIP。票据装订后再生成最终的 SHA-256，后续不重签、不修改已公证的可执行内容。
- 验证最终包：签名、票据、校验和；在 Gatekeeper 开启的环境用 `spctl --assess --type execute --verbose=4 <App>` 验证从最终包取出的 App。尽量在干净环境从真实下载包首次打开，核对版本及本次改动；不要清除隔离属性或降低系统保护来取得通过。签名通过、Apple 接受、票据验证通过、Gatekeeper 通过、首次打开通过分别记录。

## GitHub 与官网

- 在已授权发布时，把已核对的源码标签、最终 DMG/ZIP 和各自 SHA-256 上传至 `szhjia/infinite-remote-app` 的目标 Release。重新从 GitHub 下载，比较实际下载文件与本地产物的 SHA-256；验证 Release、标签提交和附件名。
- Sparkle 更新使用同一个已公证、已装订的 DMG。从与 `Package.swift` 中锁定版本一致的 [Sparkle 官方发行包](https://github.com/sparkle-project/Sparkle/releases)取出工具，执行 `SPARKLE_BIN_DIR=/absolute/path/to/bin ./scripts/generate-appcast.sh <final.dmg> RELEASE_NOTES.md`。脚本用登录钥匙串中的 `infinite-remote` 账户签名，并将签名后的清单写入 `dist/appcast.xml`。保留更新签名私钥的加密离线备份，签名后保持 DMG 和 XML 的原始字节。
- 待 Release 附件已公开且下载校验通过，把生成的 XML 原样复制到独立官网仓库的 `public/appcast.xml`。官网发布后核对线上清单和本地字节一致，再用低一个构建号的、已接入 Sparkle 的安装副本走一次检查、下载、安装、重启。核对新构建号、按键映射、辅助功能及输入监控授权。首个内置 Sparkle 的版本由旧版用户手动覆盖安装。
- 如需删除 Releases，先列出确切目标和附件；按授权删除指定 Release，并查询 GitHub API 验证剩余已发布条目。是否保留备份以用户指示为准，不把删除 Release 当成删除标签。
- 官网 `website/src/lib/release.ts` 单独维护版本、构建号与资产 URL。先保证新附件公开可下载，再按授权更新部署；从公开官网走一遍下载链接。若旧链接已失效且官网未更新，单独报告。
- 每次交付总结注明源码 SHA（以及是否包含未提交改动）、版本/构建号/架构、最终文件和 SHA-256、公证提交 ID 与结果、首次打开与公开下载的实测结果。遇到可复用的新差异，把有效修正补进本技能，不记录凭证、临时路径或一时的发布状态。

Apple 参考：[公证要求](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)、[公证流程和票据装订](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)、[分发打包和验证](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)。
