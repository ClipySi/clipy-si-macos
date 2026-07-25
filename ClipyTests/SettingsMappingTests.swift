//
//  SettingsMappingTests.swift
//  ClipyTests
//
//  The pure General-pane mappings: max-history clamp, sort-order popup ↔ reorder Bool, and the
//  status-bar icon-style clamp. These are the genuinely new logic (the `@Shared`
//  bindings just re-assert original-compatible keys), so they're the unit-tested surface.
//

import Testing
@testable import Clipy

@Suite struct SettingsMappingTests {
    // MARK: - Max history clamp

    @Test func clampsMaxHistoryToAtLeastOne() {
        #expect(SettingsMapping.clampMaxHistorySize(0) == 1)
        #expect(SettingsMapping.clampMaxHistorySize(-5) == 1)
        #expect(SettingsMapping.clampMaxHistorySize(1) == 1)
        #expect(SettingsMapping.clampMaxHistorySize(30) == 30)
    }

    @Test func clampsMaxHistoryToCeiling() {
        // A value typed past the Stepper's bound (the TextField accepts any Int) is capped at 100_000.
        #expect(SettingsMapping.clampMaxHistorySize(100_000) == 100_000)
        #expect(SettingsMapping.clampMaxHistorySize(100_001) == 100_000)
        #expect(SettingsMapping.clampMaxHistorySize(999_999_999) == 100_000)
    }

    // MARK: - Suggested limit after an import overflow

    @Test func suggestedHistoryLimitIsNextMultipleOfTenStrictlyAboveTotal() {
        #expect(SettingsMapping.suggestedHistoryLimit(forTotal: 60) == 70)
        #expect(SettingsMapping.suggestedHistoryLimit(forTotal: 61) == 70)
        #expect(SettingsMapping.suggestedHistoryLimit(forTotal: 69) == 70)
        #expect(SettingsMapping.suggestedHistoryLimit(forTotal: 70) == 80) // strictly above, so 70 → 80
        #expect(SettingsMapping.suggestedHistoryLimit(forTotal: 55) == 60)
    }

    @Test func suggestedHistoryLimitHandlesSmallAndClampedTotals() {
        #expect(SettingsMapping.suggestedHistoryLimit(forTotal: 0) == 10)
        #expect(SettingsMapping.suggestedHistoryLimit(forTotal: 3) == 10)
        // Past the ceiling the suggestion is clamped to the max-history bound.
        #expect(SettingsMapping.suggestedHistoryLimit(forTotal: 100_000) == 100_000)
        #expect(SettingsMapping.suggestedHistoryLimit(forTotal: 99_995) == 100_000)
    }

    // MARK: - Sort-order popup ↔ newest-first Bool

    @Test func sortOrderIndexMatchesAppKitBoolBridging() {
        // false ⇒ index 0 ("Date Created"), true ⇒ index 1 ("Last Used").
        #expect(SettingsMapping.sortOrderIndex(newestFirst: false) == 0)
        #expect(SettingsMapping.sortOrderIndex(newestFirst: true) == 1)
    }

    @Test func sortBoolFromIndexIsInverseOfSortOrderIndex() {
        #expect(SettingsMapping.sortNewestFirst(fromIndex: 0) == false)
        #expect(SettingsMapping.sortNewestFirst(fromIndex: 1) == true)
        // Round-trips both ways.
        for value in [true, false] {
            let index = SettingsMapping.sortOrderIndex(newestFirst: value)
            #expect(SettingsMapping.sortNewestFirst(fromIndex: index) == value)
        }
    }

    // MARK: - Generic range clamp (used by IntFieldRow for the Menu-pane numeric fields)

    @Test func clampReappliesTheLowerBound() {
        // Inline count's range starts at 0 (it may be empty); the others start at 1.
        #expect(SettingsMapping.clamp(-3, to: 0...100) == 0)
        #expect(SettingsMapping.clamp(0, to: 0...100) == 0)
        #expect(SettingsMapping.clamp(0, to: 1...100) == 1)
        #expect(SettingsMapping.clamp(-10, to: 1...1000) == 1)
    }

    @Test func clampReappliesTheUpperBound() {
        // A value typed past the Stepper's bound (the TextField accepts any Int) is capped.
        #expect(SettingsMapping.clamp(101, to: 0...100) == 100)
        #expect(SettingsMapping.clamp(999_999, to: 1...1000) == 1000)
        #expect(SettingsMapping.clamp(20_000, to: 1...10_000) == 10_000)
    }

    @Test func clampPassesThroughInRangeValues() {
        #expect(SettingsMapping.clamp(7, to: 0...100) == 7)
        #expect(SettingsMapping.clamp(1, to: 1...100) == 1)
        #expect(SettingsMapping.clamp(200, to: 1...1000) == 200)
    }

    // MARK: - Status-bar icon-style clamp

    @Test func passesThroughValidStatusItemStyles() {
        #expect(SettingsMapping.clampStatusItemStyle(0) == 0)
        #expect(SettingsMapping.clampStatusItemStyle(1) == 1)
        #expect(SettingsMapping.clampStatusItemStyle(2) == 2)
    }

    @Test func fallsBackToDefaultForOutOfRangeStatusItemStyle() {
        #expect(SettingsMapping.clampStatusItemStyle(3) == 1)
        #expect(SettingsMapping.clampStatusItemStyle(-1) == 1)
        #expect(SettingsMapping.clampStatusItemStyle(99) == 1)
    }

    @Test func statusItemImageNameMapsStylesToDistinctTemplateGlyphs() {
        // None hides the item; Black/White select the filled vs outline glyph (both template).
        #expect(SettingsMapping.statusItemImageName(forStyle: 0) == nil)
        #expect(SettingsMapping.statusItemImageName(forStyle: 1) == "StatusBarIconFilled")
        #expect(SettingsMapping.statusItemImageName(forStyle: 2) == "StatusBarIconOutline")
        // Black and White must be visibly different — the regression was both resolving identically.
        #expect(SettingsMapping.statusItemImageName(forStyle: 1)
                != SettingsMapping.statusItemImageName(forStyle: 2))
    }

    @Test func statusItemImageNameClampsOutOfRangeToFilledDefault() {
        #expect(SettingsMapping.statusItemImageName(forStyle: 3) == "StatusBarIconFilled")
        #expect(SettingsMapping.statusItemImageName(forStyle: -1) == "StatusBarIconFilled")
    }
}
