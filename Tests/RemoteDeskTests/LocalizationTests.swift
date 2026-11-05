import Foundation
import Testing
@testable import RemoteDesk

struct LocalizationTests {
    @Test func languageSelectionUsesSupportedSystemPreferencesAndEnglishFallback() {
        #expect(L10n.language(preferredLanguages: ["zh-Hans-CN", "en-US"]) == "zh")
        #expect(L10n.language(preferredLanguages: ["zh-Hant-TW"]) == "zh")
        #expect(L10n.language(preferredLanguages: ["en-GB", "zh-Hans"]) == "en")
        #expect(L10n.language(preferredLanguages: ["fr-FR", "zh-CN"]) == "zh")
        #expect(L10n.language(preferredLanguages: ["fr-FR"]) == "en")
        #expect(L10n.language(preferredLanguages: []) == "en")
    }

    @Test func packagedStringsResolveWithoutMainBundleLocalization() {
        #expect(L10n.tr("保存", locale: Locale(identifier: "en-US")) == "Save")
        #expect(L10n.tr("保存", locale: Locale(identifier: "zh-Hans")) == "保存")
        #expect(L10n.tr("查看硬件说明", locale: Locale(identifier: "en")) == "View Hardware Details")
        #expect(L10n.tr("窗口置顶", locale: Locale(identifier: "zh-TW")) == "窗口置顶")
        #expect(L10n.tr("取消", locale: Locale(identifier: "fr-FR")) == "Cancel")
        #expect(L10n.tr("unknown.localization.key", locale: Locale(identifier: "en")) == "unknown.localization.key")
    }

    @Test func dynamicMessagesKeepValuesAndUseSelectedLanguage() {
        let en = Locale(identifier: "en")
        let zh = Locale(identifier: "zh-Hans")
        #expect(L10n.format("已选 %@ / %@", locale: en, "2", "8") == "Selected 2 / 8")
        #expect(L10n.format("已选 %@ / %@", locale: zh, "2", "8") == "已选 2 / 8")
        #expect(L10n.format("无法打开%@：%@", locale: en, "50% 音乐", "Error") == "Could not open 50% 音乐: Error")
        #expect(L10n.format("%@ · 定位", locale: zh, "电源") == "电源 · 定位")
    }

    @Test func translationTablesHaveCompleteParityAndEnglishText() throws {
        func table(_ language: String) throws -> [String: String] {
            let folder = try #require(L10n.resourceBundle.url(forResource: language, withExtension: "lproj"))
            let data = try Data(contentsOf: folder.appendingPathComponent("Localizable.strings"))
            return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        }
        let english = try table("en")
        let chinese = try table("zh-Hans")
        #expect(!english.isEmpty)
        #expect(Set(english.keys) == Set(chinese.keys))
        for (key, value) in english {
            #expect(!value.isEmpty)
            #expect(!value.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) })
            #expect(value.components(separatedBy: "%@").count == key.components(separatedBy: "%@").count)
        }
        #expect(L10n.tr("添加你的第一个遥控器", locale: Locale(identifier: "en")) == "Add Your First Remote")
        #expect(L10n.tr("资源包校验失败，请刷新订阅源后重试。", locale: Locale(identifier: "en")) == "Package verification failed. Refresh the subscription source and try again.")
    }

}
