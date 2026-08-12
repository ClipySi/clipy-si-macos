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

    @Test func lateAppendOntoACompleteWindowIsIgnored() {
        let model = HistoryPanelModel()
        model.beginLoading(snippetRows: [])
        model.commitFirstPage(historyRows: clipRows(0..<40), totalCount: 40, windowComplete: true)

        // A page fetch that raced the window's completion must not append onto it — that would
        // duplicate rows and flip the window back to prefix bookkeeping (review).
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

    // MARK: - Narrowing / progressive scan (M-UI.11 P4)

    @Test func narrowingOverAPrefixStreamsScanResults() {
        let model = HistoryPanelModel()
        var scanRequests = 0
        model.onNeedsWindowScan = { scanRequests += 1 }
        model.beginLoading(snippetRows: [])
        model.commitFirstPage(historyRows: clipRows(0..<10, prefix: "note"),
                              totalCount: 40, windowComplete: false)

        model.searchText = "note 3"
        model.searchTextDidChange()
        // Before the first update: scanning state, no untruthful empty state, a scan request.
        #expect(model.isScanningHistory)
        let preScanResults = model.filteredRows.isEmpty
        #expect(preScanResults)
        #expect(model.emptyState == .none)
        #expect(scanRequests >= 1)

        // Partial matches render LIVE (still scanning — no exact totals promised).
        let context = model.currentScanContext
        let partial = [clipRows(3..<4, prefix: "note 3 partial")[0]]
        model.applyScanUpdate(HistoryReadService.ScanUpdate(
            matches: partial, processed: 20, total: 40, counts: nil,
            complete: false, failed: false), context: context)
        #expect(model.filteredRows.count == 1)
        #expect(model.isScanningHistory)
        let progressKnown = model.visibleScanProgress != nil
        #expect(progressKnown)

        // Completion settles the result set: "note 3" matches "note 3" and "note 30"…"note 39".
        let matches = clipRows(0..<40, prefix: "note").filter { $0.title.contains("note 3") }
        model.applyScanUpdate(HistoryReadService.ScanUpdate(
            matches: matches, processed: 40, total: 40, counts: nil,
            complete: true, failed: false), context: context)
        #expect(!model.isScanningHistory)
        #expect(model.searchText == "note 3")
        #expect(model.filteredRows.count == 11)
        #expect(model.emptyState == .none)
        // The prefix underneath was never touched — clearing the search returns to it.
        #expect(model.historyRows.count == 10)
    }

    @Test func chipCountsOverAPrefixStayHiddenUntilTheScanCompletes() {
        let model = HistoryPanelModel()
        var scanRequests = 0
        model.onNeedsWindowScan = { scanRequests += 1 }
        model.beginLoading(snippetRows: [])
        model.commitFirstPage(historyRows: clipRows(0..<10), totalCount: 40, windowComplete: false)

        model.isFilterBarOpen = true
        // A prefix has no exact counts to offer — the chips render without badges (§3.1).
        #expect(model.isScanningHistory)
        let chipsHaveNoCounts = model.categoryCounts.isEmpty
        #expect(chipsHaveNoCounts)
        #expect(scanRequests >= 1)

        // Mid-scan counts never surface (§3.1) …
        let context = model.currentScanContext
        model.applyScanUpdate(HistoryReadService.ScanUpdate(
            matches: clipRows(0..<20), processed: 20, total: 40, counts: nil,
            complete: false, failed: false), context: context)
        let midScanCounts = model.categoryCounts.isEmpty
        #expect(midScanCounts)
        // … exact ones do, with the final update.
        model.applyScanUpdate(HistoryReadService.ScanUpdate(
            matches: clipRows(0..<40), processed: 40, total: 40, counts: [.text: 40],
            complete: true, failed: false), context: context)
        #expect(!model.isScanningHistory)
        #expect(model.categoryCounts[.text] == 40)
    }

    @Test func snippetsScopeSearchDoesNotScan() {
        let model = HistoryPanelModel()
        var scanRequests = 0
        model.onNeedsWindowScan = { scanRequests += 1 }
        model.beginLoading(snippetRows: snippetRows(count: 3))
        model.commitFirstPage(historyRows: clipRows(0..<10), totalCount: 40, windowComplete: false)

        // Snippet titles are complete and history plays no part in their results — a snippets-
        // scope search must answer immediately, never blanking confirmed rows (review).
        model.setScope(.snippets)
        model.searchText = "snippet 1"
        model.searchTextDidChange()
        #expect(!model.isScanningHistory)
        #expect(scanRequests == 0)
        let hasSnippetMatches = !model.filteredRows.isEmpty
        #expect(hasSnippetMatches)

        // Back in a history-bearing scope the same query DOES need the scan.
        model.setScope(.all)
        #expect(model.isScanningHistory)
        #expect(scanRequests == 1)
    }

    @Test func aLateScanUpdateAfterClearingTheNarrowingIsRefused() {
        let model = HistoryPanelModel()
        model.onNeedsWindowScan = { }
        model.beginLoading(snippetRows: [])
        let page0 = clipRows(0..<10)
        model.commitFirstPage(historyRows: page0, totalCount: 40, windowComplete: false)
        model.selectNext() // the user moved the highlight off the top row

        model.isFilterBarOpen = true // the scan is requested
        let context = model.currentScanContext
        model.closeFilterBar()       // …and the user clears the narrowing before it reports
        // The late update must be refused — nothing may disturb the restored prefix view.
        let accepted = model.applyScanUpdate(HistoryReadService.ScanUpdate(
            matches: clipRows(10..<40), processed: 40, total: 40, counts: nil,
            complete: true, failed: false), context: context)
        #expect(!accepted)
        let selectionSurvived = model.selection == page0[1].id
        #expect(selectionSurvived)
        #expect(model.historyRows.count == 10)
    }

    @Test func aLandingAppendNeverCompletesAParkedMoveUnderANarrowing() {
        let model = HistoryPanelModel()
        var moreRequests = 0
        model.onNeedsMoreHistory = { moreRequests += 1 }
        model.onNeedsWindowScan = { }
        model.beginLoading(snippetRows: [])
        model.commitFirstPage(historyRows: clipRows(0..<10), totalCount: 40, windowComplete: false)
        model.nextPage() // parks pendingPage = 1, fires the fetch
        #expect(moreRequests == 1)

        // ⌘F begins a narrowing while the fetch is in flight — the parked move now belongs to
        // a dead context (review: completing it would jump the narrowed match list).
        model.isFilterBarOpen = true
        model.appendHistoryPage(clipRows(10..<20), windowComplete: false)
        #expect(model.currentPage == 0)
        let parkCleared = model.pendingPage == nil
        #expect(parkCleared)
    }

    @Test func settledAllScopeCountsIncludeTheSnippetTail() {
        let model = HistoryPanelModel()
        model.onNeedsWindowScan = { }
        model.beginLoading(snippetRows: snippetRows(count: 3))
        model.commitFirstPage(historyRows: clipRows(0..<10), totalCount: 40, windowComplete: false)
        model.isFilterBarOpen = true

        // The scan counts history clips only; the .all badge must still count the snippet
        // items it lists, exactly as the complete-window path does (review).
        model.applyScanUpdate(HistoryReadService.ScanUpdate(
            matches: clipRows(0..<40), processed: 40, total: 40,
            counts: [.all: 40, .text: 40], complete: true, failed: false),
            context: model.currentScanContext)
        #expect(model.categoryCounts[.all] == 43)
        #expect(model.categoryCounts[.text] == 40)
        #expect(model.filteredRows.count == 44) // 40 clips + header + 3 snippets
    }

    @Test func settleScanAsFailedUnfreezesAScanningDisplay() {
        let model = HistoryPanelModel()
        model.onNeedsWindowScan = { }
        model.beginLoading(snippetRows: [])
        model.commitFirstPage(historyRows: clipRows(0..<10), totalCount: 300, windowComplete: false)
        model.searchText = "row"
        model.searchTextDidChange()
        model.applyScanUpdate(HistoryReadService.ScanUpdate(
            matches: clipRows(0..<5), processed: 128, total: 300,
            counts: nil, complete: false, failed: false),
            context: model.currentScanContext)
        #expect(model.isScanningHistory)

        // The silent re-scan died mid-stream (review): the display settles with what it has —
        // no frozen progress bar with no retry path.
        model.settleScanAsFailed()
        #expect(!model.isScanningHistory)
        #expect(model.filteredRows.count == 5)
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
