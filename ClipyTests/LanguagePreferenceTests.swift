//
//  LanguagePreferenceTests.swift
//  ClipyTests
//
//  The in-app language override behind the status menu's "Language" submenu: the shipped-language
//  list, default-to-system behavior, and the AppleLanguages + marker round-trip.
//
//  Note: tests run under `-testLanguage en`, which injects `AppleLanguages=(en)` into the *argument*
//  domain — higher precedence than any suite domain — so `array(forKey: "AppleLanguages")` is
//  shadowed. We assert against the suite's persistent domain (what `setOverride` actually writes),
//  which the argument domain does not shadow. Production reads it at launch with no such argument.
//

import Foundation
import Testing
@testable import Clipy

@Suite struct LanguagePreferenceTests {
    /// A throwaway defaults suite (so a test never touches the real app domain) plus its name, needed
    /// to read the persistent domain directly.
    private func freshDefaults(_ configure: (UserDefaults) -> Void = { _ in }) -> (defaults: UserDefaults, name: String) {
        let name = "LanguagePref-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        configure(defaults)
        return (defaults, name)
    }

    /// The `AppleLanguages` value actually persisted to the suite (not shadowed by the argument domain).
    private func storedAppleLanguages(_ defaults: UserDefaults, _ name: String) -> [String]? {
        defaults.persistentDomain(forName: name)?[LanguagePreference.appleLanguagesKey] as? [String]
    }

    @Test func shippedLanguagesMatchTheCatalog() {
        let codes = LanguagePreference.supported.map(\.code)
        #expect(codes.first == "en")                    // English source first
        #expect(codes.count == 14)                      // en + 13 translated
        for code in ["ja", "zh-Hans", "es", "hi", "de", "ar", "fr", "id", "ru", "pt-BR", "ko", "bn", "it"] {
            #expect(codes.contains(code))
        }
        #expect(Set(codes).count == codes.count)        // no duplicates
        #expect(LanguagePreference.supported.allSatisfy { !$0.autonym.isEmpty })
    }

    @Test func defaultsToSystemWhenUnset() {
        let (defaults, _) = freshDefaults()
        #expect(LanguagePreference.currentOverride(defaults: defaults) == nil)
    }

    @Test func setOverridePersistsMarkerAndAppleLanguages() {
        let (defaults, name) = freshDefaults()
        LanguagePreference.setOverride("ja", defaults: defaults)
        #expect(LanguagePreference.currentOverride(defaults: defaults) == "ja")
        #expect(storedAppleLanguages(defaults, name) == ["ja"])
    }

    @Test func selectingSystemClearsBothMarkers() {
        let (defaults, name) = freshDefaults { LanguagePreference.setOverride("de", defaults: $0) }
        LanguagePreference.setOverride(nil, defaults: defaults)
        #expect(LanguagePreference.currentOverride(defaults: defaults) == nil)
        #expect(storedAppleLanguages(defaults, name) == nil)
    }

    @Test func unsupportedCodeIsTreatedAsSystem() {
        let (defaults, name) = freshDefaults()
        LanguagePreference.setOverride("xx-Fake", defaults: defaults)
        #expect(LanguagePreference.currentOverride(defaults: defaults) == nil)
        #expect(storedAppleLanguages(defaults, name) == nil)
    }
}
