//
//  PanelPagingTests.swift
//  ClipyTests
//
//  Pure paging + number-key math for the history FloatingPanel (history-panel design §3.2/§4.3) and
//  the model's page navigation. No window needed.
//

import Foundation
import Testing
@testable import Clipy

@Suite struct PanelPagingTests {
    // MARK: - pageCount

    @Test func pageCountIsAtLeastOneEvenWhenEmpty() {
        #expect(PanelPaging.pageCount(rowCount: 0, itemsPerPage: 10) == 1)
    }

    @Test func pageCountRoundsUp() {
        #expect(PanelPaging.pageCount(rowCount: 10, itemsPerPage: 10) == 1)
        #expect(PanelPaging.pageCount(rowCount: 11, itemsPerPage: 10) == 2)
        #expect(PanelPaging.pageCount(rowCount: 20, itemsPerPage: 10) == 2)
        #expect(PanelPaging.pageCount(rowCount: 21, itemsPerPage: 10) == 3)
        #expect(PanelPaging.pageCount(rowCount: 5, itemsPerPage: 20) == 1)
    }

    // MARK: - clampPage

    @Test func clampPageBoundsIntoValidRange() {
        // 25 rows @ 10/page → pages 0,1,2.
        #expect(PanelPaging.clampPage(-1, rowCount: 25, itemsPerPage: 10) == 0)
        #expect(PanelPaging.clampPage(0, rowCount: 25, itemsPerPage: 10) == 0)
        #expect(PanelPaging.clampPage(2, rowCount: 25, itemsPerPage: 10) == 2)
        #expect(PanelPaging.clampPage(99, rowCount: 25, itemsPerPage: 10) == 2)
    }

    // MARK: - range

    @Test func rangeSlicesEachPage() {
        #expect(PanelPaging.range(page: 0, rowCount: 25, itemsPerPage: 10) == 0..<10)
        #expect(PanelPaging.range(page: 1, rowCount: 25, itemsPerPage: 10) == 10..<20)
        #expect(PanelPaging.range(page: 2, rowCount: 25, itemsPerPage: 10) == 20..<25) // last partial page
    }

    @Test func rangeIsEmptyForNoRows() {
        #expect(PanelPaging.range(page: 0, rowCount: 0, itemsPerPage: 10) == 0..<0)
    }

    @Test func rangeClampsOutOfBoundsPage() {
        #expect(PanelPaging.range(page: 99, rowCount: 25, itemsPerPage: 10) == 20..<25)
    }

    // MARK: - numberKey (1-9,0 / 0-9, only first 10 rows)

    @Test func numberKeyStartAtOne() {
        #expect(PanelPaging.numberKey(pageLocalIndex: 0, startWithZero: false) == "1")
        #expect(PanelPaging.numberKey(pageLocalIndex: 8, startWithZero: false) == "9")
        #expect(PanelPaging.numberKey(pageLocalIndex: 9, startWithZero: false) == "0") // 10th row → "0"
        #expect(PanelPaging.numberKey(pageLocalIndex: 10, startWithZero: false) == nil) // 11th+ → no key
        #expect(PanelPaging.numberKey(pageLocalIndex: -1, startWithZero: false) == nil)
    }

    @Test func numberKeyStartAtZero() {
        #expect(PanelPaging.numberKey(pageLocalIndex: 0, startWithZero: true) == "0")
        #expect(PanelPaging.numberKey(pageLocalIndex: 9, startWithZero: true) == "9")
        #expect(PanelPaging.numberKey(pageLocalIndex: 10, startWithZero: true) == nil)
    }

    @Test func numberKeysAreUniqueAcrossTheFirstTenRows() {
        for startWithZero in [true, false] {
            let keys = (0..<10).compactMap { PanelPaging.numberKey(pageLocalIndex: $0, startWithZero: startWithZero) }
            #expect(keys.count == 10)
            #expect(Set(keys).count == 10) // no collisions
        }
    }

    // MARK: - displayNumber

    @Test func displayNumberMatchesStartIndex() {
        #expect(PanelPaging.displayNumber(pageLocalIndex: 0, startWithZero: false) == 1)
        #expect(PanelPaging.displayNumber(pageLocalIndex: 9, startWithZero: false) == 10)
        #expect(PanelPaging.displayNumber(pageLocalIndex: 0, startWithZero: true) == 0)
        #expect(PanelPaging.displayNumber(pageLocalIndex: 9, startWithZero: true) == 9)
    }
}

@MainActor
@Suite struct HistoryPanelModelPagingTests {
    private func rows(_ count: Int) -> [PanelRow] {
        (0..<count).map { .clip(UUID(), title: "row\($0)") }
    }

    @Test func resetGoesToFirstPageAndHighlightsTop() {
        let model = HistoryPanelModel()
        model.itemsPerPage = 10
        let all = rows(25)
        model.reset(historyRows: all, snippetRows: [])
        #expect(model.currentPage == 0)
        #expect(model.visibleRows.map(\.id) == all.prefix(10).map(\.id))
        #expect(model.selection == all.first?.id)
        #expect(model.pageCount == 3)
    }

    @Test func resetKeepsThePreviewExpandedPreference() {
        // isPreviewExpanded is a persisted user preference: unlike scope/search/category it
        // must survive reset() — the controller alone loads/saves it around each show.
        let model = HistoryPanelModel()
        model.isPreviewExpanded = true
        model.reset(historyRows: rows(3), snippetRows: [])
        #expect(model.isPreviewExpanded)
    }

    @Test func pageNavigationClampsAndMovesSelection() {
        let model = HistoryPanelModel()
        model.itemsPerPage = 10
        let all = rows(25)
        model.reset(historyRows: all, snippetRows: [])

        model.nextPage()
        #expect(model.currentPage == 1)
        #expect(model.visibleRows.first?.id == all[10].id)
        #expect(model.selection == all[10].id) // selection follows the page

        model.nextPage(); model.nextPage() // clamp at last page (2)
        #expect(model.currentPage == 2)
        #expect(model.visibleRows.count == 5)

        model.previousPage(); model.previousPage(); model.previousPage() // clamp at 0
        #expect(model.currentPage == 0)
    }

    @Test func numberKeyResolvesWithinTheVisiblePage() {
        let model = HistoryPanelModel()
        model.itemsPerPage = 10
        model.startWithZero = false
        let all = rows(25)
        model.reset(historyRows: all, snippetRows: [])
        #expect(model.row(forNumberKey: "1")?.id == all[0].id)
        #expect(model.row(forNumberKey: "0")?.id == all[9].id) // "0" → 10th row of the page

        model.nextPage() // page 2 → number keys map to rows 10..19
        #expect(model.row(forNumberKey: "1")?.id == all[10].id)
        #expect(model.row(forNumberKey: "0")?.id == all[19].id)
    }
}
