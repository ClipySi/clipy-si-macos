//
//  LanguagePreference.swift
//  ClipySi — Apple Silicon rewrite
//
//  The in-app language override behind the status menu's "Language" submenu. The app is localized
//  via `Localizable.xcstrings` and normally follows the system language; this lets the user pin a
//  specific language regardless of the OS setting.
//
//  The actual switch is done with the standard per-app `AppleLanguages` UserDefaults override, which
//  macOS reads at process start — so a change only takes effect on the **next launch** (the bundle's
//  localization is resolved once, at launch). The menu action therefore relaunches the app
//  (`AppDelegate.relaunchForLanguageChange`). We also store our own `languageOverride` marker as the
//  UI source of truth (which item gets the checkmark), independent of any per-app language the user
//  might set in System Settings.
//
//  Pure/Foundation-only (no AppKit) so the read/write logic is unit-testable with an injected
//  `UserDefaults` suite.
//

import Foundation

/// A language the app is localized into, labeled with its autonym (the language's own name) so a
/// user who can't read the current UI language can still find theirs.
struct AppLanguage: Identifiable, Hashable, Sendable {
    /// The `.lproj` / BCP-47 code, matching `Localizable.xcstrings` and `knownRegions`.
    let code: String
    /// The language's name in its own script (shown verbatim in the menu, never translated).
    let autonym: String

    var id: String { code }
}

enum LanguagePreference {
    /// The languages the app ships translations for, in display order (English first), each labeled
    /// with its autonym. Must stay in sync with `Localizable.xcstrings` / the project's `knownRegions`.
    static let supported: [AppLanguage] = [
        AppLanguage(code: "en", autonym: "English"),
        AppLanguage(code: "ja", autonym: "日本語"),
        AppLanguage(code: "zh-Hans", autonym: "简体中文"),
        AppLanguage(code: "es", autonym: "Español"),
        AppLanguage(code: "hi", autonym: "हिन्दी"),
        AppLanguage(code: "de", autonym: "Deutsch"),
        AppLanguage(code: "ar", autonym: "العربية"),
        AppLanguage(code: "fr", autonym: "Français"),
        AppLanguage(code: "id", autonym: "Bahasa Indonesia"),
        AppLanguage(code: "ru", autonym: "Русский"),
        AppLanguage(code: "pt-BR", autonym: "Português (Brasil)"),
        AppLanguage(code: "ko", autonym: "한국어"),
        AppLanguage(code: "bn", autonym: "বাংলা"),
        AppLanguage(code: "it", autonym: "Italiano")
    ]

    /// macOS's per-app language override key.
    static let appleLanguagesKey = "AppleLanguages"
    /// Our own marker (the UI source of truth); absent = follow the system language.
    static let overrideKey = "languageOverride"

    static func isSupported(_ code: String) -> Bool {
        supported.contains { $0.code == code }
    }

    /// The selected override code, or `nil` when following the system language (no override, or a
    /// stored code we no longer ship).
    static func currentOverride(defaults: UserDefaults) -> String? {
        guard let code = defaults.string(forKey: overrideKey), isSupported(code) else { return nil }
        return code
    }

    /// Persists the override (`nil` = follow the system) so it takes effect on the next launch.
    /// Writes both our UI marker and the real `AppleLanguages` override macOS reads at startup.
    /// An unsupported code is treated as "follow the system".
    static func setOverride(_ code: String?, defaults: UserDefaults) {
        if let code, isSupported(code) {
            defaults.set(code, forKey: overrideKey)
            defaults.set([code], forKey: appleLanguagesKey)
        } else {
            defaults.removeObject(forKey: overrideKey)
            defaults.removeObject(forKey: appleLanguagesKey)
        }
    }
}
