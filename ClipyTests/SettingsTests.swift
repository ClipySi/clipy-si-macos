//
//  SettingsTests.swift
//  ClipyTests
//
//  The settings read layer reads UserDefaults under the verbatim original keys with the
//  original registered defaults, so an existing user's preferences carry over.
//

import Foundation
import Testing
@testable import Clipy

@Suite struct SettingsTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "ClipySiTests-\(UUID().uuidString)")!
    }

    @Test func registerDefaultsSeedsOriginalCompatibleValues() {
        let defaults = freshDefaults()
        DefaultsKeys.registerDefaults(in: defaults)

        #expect(defaults.integer(forKey: DefaultsKeys.maxHistorySize) == 30)
        #expect(defaults.bool(forKey: DefaultsKeys.copySameHistory))
        #expect(defaults.bool(forKey: DefaultsKeys.overwriteSameHistory))
        // Retained-for-migration key (its UI/accessor retired): guard that it is still
        // seeded so a future "dead key" cleanup doesn't silently drop a value an old profile may hold.
        #expect(defaults.integer(forKey: DefaultsKeys.numberOfItemsPlaceInsideFolder) == 10)
        #expect(defaults.integer(forKey: DefaultsKeys.showStatusItem) == 1)
        #expect(defaults.bool(forKey: DefaultsKeys.menuItemsTitleStartWithZero) == false)
    }

    @Test func appSettingsReadsRegisteredThenUserValues() {
        let defaults = freshDefaults()
        DefaultsKeys.registerDefaults(in: defaults)

        #expect(AppSettings(defaults: defaults).maxHistorySize == 30)
        #expect(AppSettings(defaults: defaults).copySameHistory)

        defaults.set(7, forKey: DefaultsKeys.maxHistorySize)
        defaults.set(false, forKey: DefaultsKeys.copySameHistory)

        #expect(AppSettings(defaults: defaults).maxHistorySize == 7)
        #expect(AppSettings(defaults: defaults).copySameHistory == false)
    }

    @Test func menuAndBetaGettersReadRegisteredDefaults() {
        let defaults = freshDefaults()
        DefaultsKeys.registerDefaults(in: defaults)
        let settings = AppSettings(defaults: defaults)

        // Menu
        #expect(settings.menuItemsAreMarkedWithNumbers)
        #expect(settings.showToolTipOnMenuItem)
        #expect(settings.maxLengthOfToolTip == 200)
        #expect(settings.showImageInTheMenu)
        #expect(settings.showColorPreviewInTheMenu)
        #expect(settings.showIconInTheMenu)
        #expect(settings.menuIconSize == 16)
        // Beta
        #expect(settings.pastePlainText)
        #expect(settings.pastePlainTextModifier == 0)
        #expect(settings.deleteHistory == false)
        #expect(settings.pasteAndDeleteHistory == false)
    }

    @Test func pasteGettersReadRegisteredDefaults() {
        let defaults = freshDefaults()
        DefaultsKeys.registerDefaults(in: defaults)

        #expect(AppSettings(defaults: defaults).inputPasteCommand)
        // Rewrite-only, ON out of the box: a pasted clip returns to the top of the history.
        #expect(AppSettings(defaults: defaults).moveClipToTopOnPaste)

        defaults.set(false, forKey: DefaultsKeys.moveClipToTopOnPaste)
        #expect(AppSettings(defaults: defaults).moveClipToTopOnPaste == false)
    }

    @Test func storeTypesDefaultToEnabledAndRespectExplicitDisable() {
        let defaults = freshDefaults()
        DefaultsKeys.registerDefaults(in: defaults)

        let seeded = AppSettings(defaults: defaults)
        for token in DefaultsKeys.storeTypeTokens {
            #expect(seeded.shouldStore(typeToken: token))
        }

        defaults.set(["String": false], forKey: DefaultsKeys.storeTypes)
        let edited = AppSettings(defaults: defaults)
        #expect(edited.shouldStore(typeToken: "String") == false)
        #expect(edited.shouldStore(typeToken: "PDF")) // absent token → enabled
    }
}
