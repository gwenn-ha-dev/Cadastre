import Foundation

/// The two languages Cadastre speaks, and how it picks one.
///
/// There is no resource bundle to look strings up in — the program is a single
/// self-contained binary that is both the app and the command-line tool, and a
/// terminal launch has no `.lproj` to find. So every user-facing string is
/// written in place, in both languages, through `tr(en:fr:)`. It is more
/// verbose than a key table and much harder to leave a string untranslated.
///
/// Resolution order: `--lang`, then `CADASTRE_LANG`, then the preference set
/// from the app menu, then the system's preferred language. English is the
/// fallback for anything that is not French.
enum Language: String, CaseIterable {
    case en, fr

    var name: String {
        switch self {
        case .en: return "English"
        case .fr: return "Français"
        }
    }

    /// The locale used for dates and number formatting in this language.
    var locale: Locale {
        Locale(identifier: self == .fr ? "fr_FR" : "en_US")
    }
}

enum L10n {
    static let preferenceKey = "language"

    static var language: Language = detect()

    static func detect() -> Language {
        let environment = ProcessInfo.processInfo.environment
        if let forced = environment["CADASTRE_LANG"], let parsed = Language(rawValue: forced.lowercased()) {
            return parsed
        }
        if let stored = UserDefaults.standard.string(forKey: preferenceKey),
           let parsed = Language(rawValue: stored) {
            return parsed
        }
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.lowercased().hasPrefix("fr") ? .fr : .en
    }

    /// Remember a choice made from the app menu. Takes effect at next launch —
    /// every control in the window was built with the previous language.
    static func store(_ language: Language) {
        UserDefaults.standard.set(language.rawValue, forKey: preferenceKey)
    }

    /// Byte units follow the language: macOS itself shows « Go » in French
    /// and "GB" in English, and a French window full of "GB" reads as a
    /// half-finished translation.
    static var byteUnits: [String] {
        language == .fr ? ["o", "ko", "Mo", "Go", "To", "Po"] : ["B", "kB", "MB", "GB", "TB", "PB"]
    }

    static var decimalSeparator: String { language == .fr ? "," : "." }

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
        let formatter = NumberFormatter()
        formatter.locale = language.locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

/// Pick the string for the current language. English first, French second,
/// everywhere — the order is part of the convention, so a call site reads the
/// same in every file.
@inline(__always)
func tr(en: String, fr: String) -> String {
    L10n.language == .fr ? fr : en
}

/// Same, with `String(format:)` arguments applied.
func tr(en: String, fr: String, _ arguments: CVarArg...) -> String {
    String(format: L10n.language == .fr ? fr : en, locale: L10n.language.locale, arguments: arguments)
}
