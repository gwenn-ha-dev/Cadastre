import Foundation
import CadastreStrings

/// The two languages Cadastre speaks, and how it picks one.
///
/// Every user-facing string is looked up in `Resources/Localizable.xcstrings`,
/// the one table that holds both languages (charter §6). The key is the English
/// phrase itself, so a call site reads `tr("Measure a folder")`.
///
/// The catalogue is embedded in the binary rather than shipped as `.lproj`
/// tables: the program is a single executable that is both the app and the
/// command-line tool, and a terminal launch has no bundle to look strings up
/// in. The bundle still declares `en` and `fr` (`CFBundleLocalizations`) and
/// carries the permission prompts in `<lang>.lproj/InfoPlist.strings`.
///
/// Resolution order: `--lang`, then `CADASTRE_LANG`, then the system's
/// preferred languages — the first of English or French found there, as macOS
/// itself picks among the localisations an app ships. There is no setting in
/// the app. English is the fallback.
enum Language: String, CaseIterable {
    case en, fr

    /// The locale used for dates and numbers. The system's own when it speaks
    /// this language (an en_GB Mac keeps its day-month order), a plain one of
    /// this language otherwise — `--lang en` on a French Mac stays English.
    var locale: Locale {
        if Locale.current.language.languageCode?.identifier == rawValue { return Locale.current }
        return Locale(identifier: self == .fr ? "fr_FR" : "en_US")
    }
}

enum L10n {
    nonisolated(unsafe) static var language: Language = detect()

    static func detect() -> Language {
        let environment = ProcessInfo.processInfo.environment
        if let forced = environment["CADASTRE_LANG"], let parsed = Language(rawValue: forced.lowercased()) {
            return parsed
        }
        let available = Language.allCases.map(\.rawValue)
        let chosen = Bundle.preferredLocalizations(from: available, forPreferences: Locale.preferredLanguages).first
        return chosen.flatMap(Language.init(rawValue:)) ?? .en
    }

    /// French values by English key, read once from the embedded catalogue.
    private static let french: [String: String] = {
        struct Catalog: Decodable {
            struct Entry: Decodable { let localizations: [String: Localization]? }
            struct Localization: Decodable { let stringUnit: Unit? }
            struct Unit: Decodable { let value: String }
            let strings: [String: Entry]
        }
        guard let catalog = try? JSONDecoder().decode(Catalog.self, from: StringCatalog.data) else { return [:] }
        var table: [String: String] = [:]
        for (key, entry) in catalog.strings {
            if let value = entry.localizations?["fr"]?.stringUnit?.value { table[key] = value }
        }
        return table
    }()

    static func lookup(_ key: String) -> String {
        language == .fr ? (french[key] ?? key) : key
    }

    /// Byte units follow the language: macOS itself shows « Go » in French
    /// and "GB" in English, and a French window full of "GB" reads as a
    /// half-finished translation.
    static var byteUnits: [String] {
        [tr("B"), tr("kB"), tr("MB"), tr("GB"), tr("TB"), tr("PB")]
    }

    /// A date formatter that follows the chosen language rather than the
    /// system locale, so `--lang en` on a French Mac stays English throughout.
    static func dateFormatter(template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    /// Thousands grouping for counts: 262 000 reads, 262000 does not.
    static func count(_ value: Int) -> String {
        value.formatted(.number.locale(language.locale))
    }
}

/// The string for `key` — its English text — in the current language.
@inline(__always)
func tr(_ key: String) -> String {
    L10n.lookup(key)
}

/// Same, with `String(format:)` arguments applied.
func tr(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L10n.lookup(key), locale: L10n.language.locale, arguments: arguments)
}
