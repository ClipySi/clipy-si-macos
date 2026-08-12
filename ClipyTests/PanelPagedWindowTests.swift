//
//  PanelPagedWindowTests.swift
//  ClipyTests
//
//  M-UI.11 P2: the model's windowed-history contract. A fresh open passes through the loading
//  shell (history-bearing scopes blank — nothing selectable or pasteable; the snippets scope
//  stays live on its confirmed rows), commits the first page as ONE snapshot, then treats
//  `historyRows` as a sequential prefix: paging past it parks and asks for more; narrowing
//  (search / category chips) holds a scanning state and asks for the complete window — a
//  partial match or a prefix-derived count must never pose as exact (plan v2 §3.1/§5.2/§5.3).
//  Post-review hardening: parked page moves die with their context, late appends never land on
//  a completed window, appends dedupe mutation-moved rows, and async commits preserve a
//  surviving selection. Synthetic rows; count-shaped assertions only (§3.2 — no row values in
//  failure output).
//

import Foundation
import Testing

@testable import Clipy

@MainActor
@Suite struct PanelPagedWindowTests {

    private func clipRows(_ range: Range<Int>, prefix: String = "row") -> [PanelRow] {
        range.map { PanelRow.clip(UUID(), title: "\(prefix) \($0)") }
    }

    private func snippetRows(count: Int) -> [PanelRow] {
        var rows: [PanelRow] = [.folderHeader(UUID(), title: "Folder")]
        for index in 0..<count {
            rows.append(.snippet(UUID(), title: "snippet \(index)"))
        }
        return rows
    }

    // MARK: - Loading shell

    @Test func loadingShellDisablesSelectionNumbersAndPaste() {
        let model = HistoryPanelModel()
        model.beginLoading(snippetRows: snippetRows(count: 3))
        #expect(model.isLoadingFirstRows)
        let shellIsBlank = model.visibleRows.isEmpty
        #expect(shellIsBlank)
        let hasSelectedRow = model.selectedRow != nil
        #expect(!hasSelectedRow)
        let hasSelection = model.selection != nil
        #expect(!hasSelection)
        let digitResolves = model.row(forNumberKey: "1") != nil
        #expect(!digitResolves)
        // No lying empty state while the row set is indeterminate — the list band stays blank.
        #expect(model.emptyState == .none)
        // The snippet-side badges stay real through the shell (review): only history is unknown.
        #expect(model.snippetCount == 3)
    }

    @Test func loadingShellKeepsSnippetsScopeLive() {
        let model = HistoryPanelModel()
        model.beginLoading(snippetRows: snippetRows(count: 3), scope: .snippets)
        // Snippet rows arrived synchronously with the shell and the history commit can't change
        // them — a fast "⌘⇧B then digit" paste must keep working through the read (review).
        #expect(model.visibleRows.count == 4) // header + 3 snippets
        let hasSelection = model.selection != nil
        #expect(hasSelection)
        let digitResolves = model.row(forNumberKey: "1") != nil
        #expect(digitResolves)
        #expect(model.emptyState == .none)
    }

    @Test func loadingShellIgnoresHistoryPageMoves() {
        let model = HistoryPanelModel()
        model.beginLoading(snippetRows: snippetRows(count: 15)) // 16 rendered rows in .all
        model.nextPage()
        // A pre-commit cursor move would slice a seam page (snippets where history belongs)
        // out of the committed rows (review) — the shell ignores history-scope page moves.
        #expect(model.currentPage == 0)
        model.commitFirstPage(historyRows: clipRows(0..<10), totalCount: 40, windowComplete: false)
        #expect(model.currentPage == 0)
        #expect(model.visibleRows.count == 10)
    }

    // MARK: - First page commit

    @Test func commitFirstPageSettlesRowsNumbersAndSelectionInOneRebuild() {
        let model = HistoryPanelModel()
        model.beginLoading(snippetRows: [])
        let rebuildsBefore = model.filteredRebuildCount
        let page = clipRows(0..<10)
        model.commitFirstPage(historyRows: page, totalCount: 40, windowComplete: false)
        #expect(model.filteredRebuildCount == rebuildsBefore + 1)
        #expect(!model.isLoadingFirstRows)
        #expect(model.visibleRows.count == 10)
        let selectionIsPageTop = model.selection == page.first?.id
        #expect(selectionIsPageTop)
        let digitResolves = model.row(forNumberKey: "1") != nil
        #expect(digitResolves)
        // Paging math runs on the WINDOW total, not the loaded prefix.
        #expect(model.pageCount == 4)
        #expect(model.historyCount == 40)
    }

    // MARK: - Sequential paging over the prefix

    @Test func pageMovePastThePrefixParksUntilTheAppendArrives() {
        let model = HistoryPanelModel()
        var moreRequests = 0
        model.onNeedsMoreHistory = { moreRequests += 1 }
        model.beginLoading(snippetRows: [])
        model.commitFirstPage(historyRows: clipRows(0..<10), totalCount: 25, windowComplete: false)

        model.nextPage()
        // §5.3: the visible page holds until the rows exist — no seam of misplaced rows.
        #expect(model.currentPage == 0)
        #expect(moreRequests == 1)

        let nextPage = clipRows(10..<20)
        model.appendHistoryPage(nextPage, windowComplete: false)
        #expect(model.currentPage == 1)
        let selectionIsPageTop = model.selection == nextPage.first?.id
        #expect(selectionIsPageTop)
        #expect(model.historyCount == 25)
        #expect(model.pageCount == 3)
    }

    @Test func parkedPageMoveIsDroppedWhenTheContextChanges() {
        let model = HistoryPanelModel()
        var moreRequests = 0
        model.onNeedsMoreHistory = { moreRequests += 1 }
        model.beginLoading(snippetRows: snippetRows(count: 12)) // snippets span 2 pages
        model.commitFirstPage(historyRows: clipRows(0..<10), totalCount: 25, windowComplete: false)

        model.nextPage() // parks page 1 and fires the fetch
        #expect(moreRequests == 1)
        model.setScope(.snippets)
        // The append lands AFTER the scope switch: the parked move belonged to the old context
        // and must not jump the snippets view to a history page number (review).
        model.appendHistoryPage(clipRows(10..<20), windowComplete: false)
        #expect(model.scope == .snippets)
        #expect(model.currentPage == 0)
    }

    @Test func historyScopePagingUsesTheWindowTotal() {
        let model = HistoryPanelModel()
        model.beginLoading(snippetRows: snippetRows(count: 5)) // 6 rendered rows
        model.commitFirstPage(historyRows: clipRows(0..<10), totalCount: 20, windowComplete: false)
        // .all spans history total + snippet rows; .history must use the history total alone.
        #expect(model.pageCount == 3) // ceil((20 + 6) / 10)
        model.setScope(.history)
        #expect(model.pageCount == 2) // ceil(20 / 10)
        #expect(model.historyCount == 20)
    }

    @Test func snippetsScopePagingNeverParksOnTheHistoryPrefix() {
        let model = HistoryPanelModel()
        var moreRequests = 0
        model.onNeedsMoreHistory = { moreRequests += 1 }
        model.beginLoading(snippetRows: snippetRows(count: 12)) // 13 rendered rows
        model.commitFirstPage(historyRows: clipRows(0..<10), totalCount: 100, windowComplete: false)

        model.setScope(.snippets)
        model.nextPage()
        // Snippets are fully materialized — their pages must not wait on history fetches.
        #expect(model.currentPage == 1)
        #expect(moreRequests == 0)
    }

    // MARK: - Append integrity (post-review)

    @Test func lateAppendAfterHydrationIsIgnored() {
        let model = HistoryPanelModel()
        model.onNeedsWindowHydration = { }
        model.beginLoading(snippetRows: [])
        model.commitFirstPage(historyRows: clipRows(0..<10), totalCount: 40, windowComplete: false)
        model.searchText = "row"
        model.searchTextDidChange()
        model.completeWindow(clipRows(0..<40), totalCount: 40)

        // A page fetch that raced the hydration must not append onto the finished window —
        // that would duplicate rows and flip the window back to prefix bookkeeping (review).
        model.appendHistoryPage(clipRows(100..<110), windowComplete: false)
        #expect(model.historyRows.count == 40)
        #expect(model.historyWindowComplete)
    }

    @Test func appendDropsRowsAlreadyInThePrefix() {
        let model = HistoryPanelModel()
        model.beginLoading(snippetRows: [])
        let page0 = clipRows(0..<10)
        model.commitFirstPage(historyRows: page0, totalCount: 25, windowComplete: false)
        // A dedupe re-copy / paste move-to-top rewrites createdAt mid-walk, so a served row can
        // re-enter a later keyset page — the append must drop ids the prefix already holds.
        let overlapping = [page0[9]] + clipRows(10..<19)
        model.appendHistoryPage(overlapping, windowComplete: false)
        #expect(model.historyRows.count == 19)
        let uniqueRowCount = Set(model.historyRows.map(\.id)).count
        #expect(uniqueRowCount == 19)
    }

    // MARK: - Narrowing / hydration

    @Test func narrowingOverAPrefixHydratesBeforeShowingResults() {
        let model = HistoryPanelModel()
        var hydrationRequests = 0
        model.onNeedsWindowHydration = { hydrationRequests += 1 }
        model.beginLoading(snippetRows: [])
        model.commitFirstPage(historyRows: clipRows(0..<10, prefix: "note"),
                              totalCount: 40, windowComplete: false)

        model.searchText = "note 3"
        model.searchTextDidChange()
        // Partial matches over a prefix must never pose as results (§3.1): scanning state, no
        // no-results state, and a hydration request instead.
        #expect(model.isHydratingWindow)
        let hydrationHoldsResults = model.filteredRows.isEmpty
        #expect(hydrationHoldsResults)
        #expect(model.emptyState == .none)
        #expect(hydrationRequests >= 1)

        // The reply preserves the narrowing inputs and applies them to the full window:
        // "note 3" matches "note 3" and "note 30"..."note 39".
        model.completeWindow(clipRows(0..<40, prefix: "note"), totalCount: 40)
        #expect(!model.isHydratingWindow)
        #expect(model.searchText == "note 3")
        #expect(model.filteredRows.count == 11)
        #expect(model.emptyState == .none)
    }

    @Test func chipCountsOverAPrefixStayHiddenUntilHydration() {
        let model = HistoryPanelModel()
        var hydrationRequests = 0
        model.onNeedsWindowHydration = { hydrationRequests += 1 }
        model.beginLoading(snippetRows: [])
        model.commitFirstPage(historyRows: clipRows(0..<10), totalCount: 40, windowComplete: false)

        model.isFilterBarOpen = true
        // A prefix has no exact counts to offer — the chips render without badges (§3.1).
        #expect(model.isHydratingWindow)
        let chipsHaveNoCounts = model.categoryCounts.isEmpty
        #expect(chipsHaveNoCounts)
        #expect(hydrationRequests >= 1)

        model.completeWindow(clipRows(0..<40), totalCount: 40)
        #expect(!model.isHydratingWindow)
        #expect(model.categoryCounts[.text] == 40)
    }

    @Test func snippetsScopeSearchDoesNotHydrate() {
        let model = HistoryPanelModel()
        var hydrationRequests = 0
        model.onNeedsWindowHydration = { hydrationRequests += 1 }
        model.beginLoading(snippetRows: snippetRows(count: 3))
        model.commitFirstPage(historyRows: clipRows(0..<10), totalCount: 40, windowComplete: false)

        // Snippet titles are complete and history plays no part in their results — a snippets-
        // scope search must answer immediately, never blanking confirmed rows (review).
        model.setScope(.snippets)
        model.searchText = "snippet 1"
        model.searchTextDidChange()
        #expect(!model.isHydratingWindow)
        #expect(hydrationRequests == 0)
        let hasSnippetMatches = !model.filteredRows.isEmpty
        #expect(hasSnippetMatches)

        // Back in a history-bearing scope the same query DOES need the window.
        model.setScope(.all)
        #expect(model.isHydratingWindow)
        #expect(hydrationRequests == 1)
    }

    @Test func completeWindowKeepsASurvivingSelection() {
        let model = HistoryPanelModel()
        model.onNeedsWindowHydration = { }
        model.beginLoading(snippetRows: [])
        let page0 = clipRows(0..<10)
        model.commitFirstPage(historyRows: page0, totalCount: 40, windowComplete: false)
        model.selectNext() // the user moved the highlight off the top row

        model.isFilterBarOpen = true // hydration starts (blank list; selection value survives)
        model.closeFilterBar()       // …and the user clears the narrowing before it lands
        // The late completeWindow must not stomp a highlight that still resolves (review).
        model.completeWindow(page0 + clipRows(10..<40), totalCount: 40)
        let selectionSurvived = model.selection == page0[1].id
        #expect(selectionSurvived)
    }

    // MARK: - Legacy reset

    @Test func resetRestoresTheCompleteWindowContract() {
        let model = HistoryPanelModel()
        model.beginLoading(snippetRows: [])
        model.commitFirstPage(historyRows: clipRows(0..<10), totalCount: 40, windowComplete: false)

        let rows = clipRows(0..<12)
        model.reset(historyRows: rows, snippetRows: [])
        #expect(model.historyWindowComplete)
        #expect(!model.isLoadingFirstRows)
        #expect(model.historyCount == 12)
        #expect(model.pageCount == 2)
        let selectionIsTop = model.selection == rows.first?.id
        #expect(selectionIsTop)
    }
}
