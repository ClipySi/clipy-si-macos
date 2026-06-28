//
//  StoreTypeSettingsTests.swift
//  ClipyTests
//
//  The Type-pane store model: tokens default to enabled, a write persists in the plist-dictionary
//  format capture reads, and flipping one/two tokens leaves the rest intact (no read-modify-write
//  loss — design §6 delta 8).
//

import Foundation
import Testing
@testable import Clipy

@MainActor
@Suite struct StoreTypeSettingsTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "ClipySiStoreTypes-\(UUID().uuidString)")!
    }

    @Test func absentTokensDefaultToEnabled() {
        let store = StoreTypeSettings(defaults: freshDefaults())
        for token in DefaultsKeys.storeTypeTokens {
            #expect(store.isEnabled(token) == true)
        }
    }

    @Test func disablingOneTokenPersistsAndLeavesOthersEnabled() {
        let defaults = freshDefaults()
        let store = StoreTypeSettings(defaults: defaults)

        store.setEnabled(false, for: "PDF")

        #expect(store.isEnabled("PDF") == false)
        for token in DefaultsKeys.storeTypeTokens where token != "PDF" {
            #expect(store.isEnabled(token) == true)
        }
        // Persisted as a dictionary the capture layer reads via AppSettings.
        let settings = AppSettings(defaults: defaults)
        #expect(settings.shouldStore(typeToken: "PDF") == false)
        #expect(settings.shouldStore(typeToken: "RTF") == true)
    }

    @Test func togglingTwoTokensPreservesTheOtherFive() {
        let defaults = freshDefaults()
        let store = StoreTypeSettings(defaults: defaults)

        store.setEnabled(false, for: "TIFF")
        store.setEnabled(false, for: "URL")

        // A fresh model reading the same store sees exactly those two off.
        let reread = StoreTypeSettings(defaults: defaults)
        #expect(reread.isEnabled("TIFF") == false)
        #expect(reread.isEnabled("URL") == false)
        for token in ["String", "RTF", "RTFD", "PDF", "Filenames"] {
            #expect(reread.isEnabled(token) == true)
        }
    }

    @Test func toleratesNSNumberBackedBools() {
        let defaults = freshDefaults()
        defaults.set(["PDF": NSNumber(value: false)], forKey: DefaultsKeys.storeTypes)
        let store = StoreTypeSettings(defaults: defaults)
        #expect(store.isEnabled("PDF") == false)
    }
}
