import Foundation

/// Resolves the app's packaged strings, including when launched directly through SwiftPM.
enum L10n {
    static var resourceBundle: Bundle { .module }
    static var language: String { language(preferredLanguages: Locale.preferredLanguages) }
    static var locale: Locale { Locale(identifier: language == "zh" ? "zh-Hans" : "en") }

    static func language(preferredLanguages: [String]) -> String {
        for identifier in preferredLanguages {
            let code = Locale(identifier: identifier).language.languageCode?.identifier
            if code == "zh" { return "zh" }
            if code == "en" { return "en" }
        }
        return "en"
    }

    static func tr(_ key: String) -> String { tr(key, locale: locale) }

    static func tr(_ key: String, locale: Locale) -> String {
        let language = locale.language.languageCode?.identifier == "zh" ? "zh-Hans" : "en"
        guard let path = resourceBundle.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: tr(key), locale: locale, arguments: arguments)
    }

    static func format(_ key: String, locale: Locale, _ arguments: CVarArg...) -> String {
        String(format: tr(key, locale: locale), locale: locale, arguments: arguments)
    }
}
