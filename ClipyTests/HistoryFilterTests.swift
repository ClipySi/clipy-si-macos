//
//  HistoryFilterTests.swift
//  ClipyTests
//
//  Pure pipeline tests for the History Manager's display-only filter/search/sort. No database and no
//  cipher: `HistoryClipRow` only reads the decrypted `ClipDisplay` + plaintext `Clip` metadata, so the
//  rows are built directly. Verifies that filtering/searching/sorting narrow/reorder the rows without
//  mutating the input (the History Manager never mutates history except via delete — design Q1).
//

import AppKit
import Foundation
import Testing
@testable import Clipy

@Suite struct HistoryFilterTests {
    /// Builds a display row directly from a synthetic clip + display (string type → preview == title).
    private func row(_ preview: String,
                     type: NSPasteboard.PasteboardType = .string,
                     app: String? = nil,
                     pinned: Bool = false,
                     at offset: TimeInterval = 0) -> HistoryClipRow {
        var clip = Make.clip(createdAt: Make.epoch.addingTimeInterval(offset), isPinned: pinned)
        clip.primaryType = type.rawValue
        clip.sourceBundle = app
        let display = ClipDisplay(id: clip.id, title: preview, primaryType: type.rawValue,
                                  isColorCode: false, decryptFailed: false)
        return HistoryClipRow(clip: clip, display: display)
    }

    // MARK: - Default ordering

    @Test func emptyQueryReturnsAllNewestFirst() {
        let rows = [row("oldest", at: 0), row("newest", at: 200), row("middle", at: 100)]
        let result = HistoryFilter.apply(HistoryQuery(), to: rows)
        #expect(result.map(\.preview) == ["newest", "middle", "oldest"])
    }

    // MARK: - Search

    @Test func searchMatchesPreviewCaseAndDiacriticInsensitive() {
        let rows = [row("Hello World", at: 2), row("café latte", at: 1), row("unrelated", at: 0)]

        var query = HistoryQuery()
        query.searchText = "hello"
        #expect(HistoryFilter.apply(query, to: rows).map(\.preview) == ["Hello World"])

        query.searchText = "CAFE" // case + diacritic insensitive
        #expect(HistoryFilter.apply(query, to: rows).map(\.preview) == ["café latte"])

        query.searchText = "zzz"
        #expect(HistoryFilter.apply(query, to: rows).isEmpty)
    }

    @Test func blankSearchReturnsEverything() {
        let rows = [row("a", at: 1), row("b", at: 0)]
        var query = HistoryQuery()
        query.searchText = "   \n\t "
        #expect(HistoryFilter.apply(query, to: rows).count == 2)
    }

    // MARK: - Filters

    @Test func typeFilterRestrictsToMatchingType() {
        let rows = [row("text one", at: 2),
                    row("an image", type: .tiff, at: 1),
                    row("text two", at: 0)]
        var query = HistoryQuery()
        query.typeDisplay = "Image"
        let result = HistoryFilter.apply(query, to: rows)
        #expect(result.count == 1)
        #expect(result.first?.typeDisplay == "Image")
    }

    @Test func appFilterRestrictsToMatchingApp() {
        let rows = [row("from writer", app: "com.example.Writer", at: 2),
                    row("from browser", app: "com.example.Browser", at: 1),
                    row("no app", at: 0)]
        var query = HistoryQuery()
        query.appDisplay = "com.example.Writer"
        let result = HistoryFilter.apply(query, to: rows)
        #expect(result.map(\.preview) == ["from writer"])
    }

    @Test func filtersAndSearchAreAndedTogether() {
        let rows = [row("invoice draft", app: "com.example.Writer", at: 3),
                    row("invoice final", app: "com.example.Browser", at: 2),
                    row("recipe", app: "com.example.Writer", at: 1)]
        var query = HistoryQuery()
        query.appDisplay = "com.example.Writer"
        query.searchText = "invoice"
        #expect(HistoryFilter.apply(query, to: rows).map(\.preview) == ["invoice draft"])
    }

    // MARK: - Sort

    @Test func sortByPreviewAscendingThenDescending() {
        let rows = [row("banana", at: 0), row("apple", at: 1), row("cherry", at: 2)]

        var query = HistoryQuery()
        query.sort = [KeyPathComparator(\HistoryClipRow.preview, order: .forward)]
        #expect(HistoryFilter.apply(query, to: rows).map(\.preview) == ["apple", "banana", "cherry"])

        query.sort = [KeyPathComparator(\HistoryClipRow.preview, order: .reverse)]
        #expect(HistoryFilter.apply(query, to: rows).map(\.preview) == ["cherry", "banana", "apple"])
    }

    @Test func sortByDateAscending() {
        let rows = [row("newest", at: 200), row("oldest", at: 0), row("middle", at: 100)]
        var query = HistoryQuery()
        query.sort = [KeyPathComparator(\HistoryClipRow.createdAt, order: .forward)]
        #expect(HistoryFilter.apply(query, to: rows).map(\.preview) == ["oldest", "middle", "newest"])
    }

    // MARK: - Purity / metadata

    @Test func applyDoesNotMutateInput() {
        let rows = [row("z", at: 0), row("a", at: 1)]
        let snapshot = rows.map(\.id)
        var query = HistoryQuery()
        query.sort = [KeyPathComparator(\HistoryClipRow.preview, order: .forward)]
        _ = HistoryFilter.apply(query, to: rows)
        #expect(rows.map(\.id) == snapshot)
    }

    @Test func isActiveReflectsFiltersAndSearchButNotSort() {
        #expect(HistoryQuery().isActive == false)

        var sortedOnly = HistoryQuery()
        sortedOnly.sort = [KeyPathComparator(\HistoryClipRow.preview, order: .forward)]
        #expect(sortedOnly.isActive == false)

        var searching = HistoryQuery()
        searching.searchText = "x"
        #expect(searching.isActive)

        var typed = HistoryQuery()
        typed.typeDisplay = "Text"
        #expect(typed.isActive)

        var apped = HistoryQuery()
        apped.appDisplay = "com.example.App"
        #expect(apped.isActive)
    }
}
