//
//  PanelSearchTests.swift
//  ClipyTests
//
//  Pure search over the history FloatingPanel's masked rows (history-panel design §4.1 / C3) plus the
//  model's search→paging re-base. The C3 cases are the security-load-bearing ones: a fully masked
//  secret must NOT be findable, and only the disclosed prefix/suffix characters of a partially masked
//  secret may match. No window/database needed — synthetic rows only (never a real copied secret).
//

import Foundation
import Testing
@testable import Clipy

@Suite struct PanelSearchTests {
    private func row(_ title: String, isSecret: Bool = false, decryptFailed: Bool = false) -> PanelRow {
        .clip(UUID(), title: title, isSecret: isSecret, decryptFailed: decryptFailed)
    }
    private func header(_ title: String) -> PanelRow { .folderHeader(UUID(), title: title) }
    private func snippet(_ title: String) -> PanelRow { .snippet(UUID(), title: title) }

    // MARK: - Basic matching (mirrors HistoryFilter semantics)

    @Test func emptyQueryReturnsEveryRowUnchanged() {
        let rows = [row("alpha"), row("beta"), row("gamma")]
        #expect(PanelSearch.filter(rows, query: "").map(\.id) == rows.map(\.id))
        #expect(PanelSearch.filter(rows, query: "   ").map(\.id) == rows.map(\.id)) // whitespace-only ⇒ all
    }

    @Test func filtersToRowsContainingTheTerm() {
        let rows = [row("apple pie"), row("banana bread"), row("apple tart")]
        let hits = PanelSearch.filter(rows, query: "apple")
        #expect(hits.map(\.title) == ["apple pie", "apple tart"])
    }

    @Test func matchIsCaseAndDiacriticInsensitive() {
        let rows = [row("Café Society"), row("plain text")]
        #expect(PanelSearch.filter(rows, query: "cafe").map(\.title) == ["Café Society"])
        #expect(PanelSearch.filter(rows, query: "SOCIETY").map(\.title) == ["Café Society"])
    }

    @Test func preservesOriginalOrderOfMatches() {
        let rows = [row("x1"), row("y"), row("x2"), row("x3")]
        #expect(PanelSearch.filter(rows, query: "x").map(\.title) == ["x1", "x2", "x3"])
    }

    @Test func noMatchYieldsEmpty() {
        #expect(PanelSearch.filter([row("a"), row("b")], query: "zzz").isEmpty)
    }

    // MARK: - C3 — search runs over the MASKED title only (no plaintext leak path)

    @Test func fullyMaskedSecretIsNotSearchableByItsPlaintext() {
        // A `.full` masked secret renders as bullets; its plaintext never reaches the row title.
        let secret = row("●●●●●●●●", isSecret: true)
        let normal = row("my notes")
        let rows = [secret, normal]
        // The (synthetic) underlying plaintext can't be found because it isn't in the haystack.
        #expect(PanelSearch.filter(rows, query: "hunter2").isEmpty)
        #expect(PanelSearch.filter(rows, query: "sk-live").isEmpty)
        // The bullets themselves also don't accidentally match a normal query.
        #expect(PanelSearch.filter(rows, query: "notes").map(\.id) == [normal.id])
    }

    @Test func partiallyMaskedSecretMatchesOnlyDisclosedCharacters() {
        // A prefix2/suffix4 masked token like "sk●●●●●●3a9f" discloses only "sk" + "3a9f".
        let token = row("sk●●●●●●3a9f", isSecret: true)
        let rows = [token, row("unrelated")]
        #expect(PanelSearch.filter(rows, query: "sk").map(\.id) == [token.id])   // disclosed prefix matches
        #expect(PanelSearch.filter(rows, query: "3a9f").map(\.id) == [token.id]) // disclosed suffix matches
        #expect(PanelSearch.filter(rows, query: "secret").isEmpty)               // masked middle never matches
    }

    // MARK: - filterCombined (header-aware)

    @Test func combinedEmptyQueryReturnsEverythingUnchanged() {
        let rows = [row("clip"), header("Greetings"), snippet("hello")]
        #expect(PanelSearch.filterCombined(rows, query: "").map(\.id) == rows.map(\.id))
    }

    @Test func combinedKeepsAFolderHeaderOnlyWhenAChildMatches() {
        let rows = [
            row("apple clip"),
            header("Fruit"), snippet("apple snippet"), snippet("banana"),
            header("Empty"), snippet("nothing here")
        ]
        let hits = PanelSearch.filterCombined(rows, query: "apple")
        // The clip + the Fruit header + its one matching snippet survive; the Empty folder (no match) and
        // its header are dropped, and the non-matching "banana" snippet is dropped.
        #expect(hits.map(\.title) == ["apple clip", "Fruit", "apple snippet"])
    }

    @Test func combinedHeaderEmittedOnceForMultipleMatchingChildren() {
        let rows = [header("Greetings"), snippet("hi there"), snippet("hi again"), snippet("bye")]
        let hits = PanelSearch.filterCombined(rows, query: "hi")
        #expect(hits.map(\.title) == ["Greetings", "hi there", "hi again"]) // header once, then both matches
    }

    @Test func combinedC3MaskedClipStillNotFindableByPlaintext() {
        // C3 holds in the combined path too: a fully-masked clip can't be found by its (synthetic) secret.
        let rows = [row("●●●●●●", isSecret: true), header("F"), snippet("my note")]
        #expect(PanelSearch.filterCombined(rows, query: "hunter2").isEmpty)
        #expect(PanelSearch.filterCombined(rows, query: "note").map(\.title) == ["F", "my note"])
    }
}

@MainActor
@Suite struct HistoryPanelModelSearchTests {
    private func rows(_ titles: [String]) -> [PanelRow] {
        titles.map { .clip(UUID(), title: $0) }
    }

    @Test func searchNarrowsVisibleRowsAndResetsToFirstPage() {
        let model = HistoryPanelModel()
        model.itemsPerPage = 10
        let all = rows((0..<25).map { "row\($0)" })
        model.reset(historyRows: all, snippetRows: [])
        model.nextPage() // move off page 0 first
        #expect(model.currentPage == 1)

        model.searchText = "row1" // matches row1, row10..row19, row21..row24? no — "row1": row1,row10-19 → 11 rows
        model.searchTextDidChange()
        #expect(model.currentPage == 0)                       // re-based to page 0
        #expect(model.filteredRows.allSatisfy { $0.title.contains("row1") })
        #expect(model.selection == model.visibleRows.first?.id) // highlight on the new top row
    }

    @Test func numberKeyAndPagingOperateOverTheFilteredSet() {
        let model = HistoryPanelModel()
        model.itemsPerPage = 10
        model.startWithZero = false
        // 12 "apple" rows interleaved with noise; filter should yield exactly the apples in order.
        var titles: [String] = []
        for index in 0..<12 { titles.append("apple\(index)"); titles.append("noise\(index)") }
        let all = rows(titles)
        model.reset(historyRows: all, snippetRows: [])

        model.searchText = "apple"
        model.searchTextDidChange()
        #expect(model.filteredRows.count == 12)
        #expect(model.pageCount == 2)                                   // 12 / 10 → 2 pages
        #expect(model.row(forNumberKey: "1")?.title == "apple0")        // page 0, key "1"
        #expect(model.row(forNumberKey: "0")?.title == "apple9")        // page 0, 10th row → "0"

        model.nextPage()
        #expect(model.visibleRows.map(\.title) == ["apple10", "apple11"]) // page 1 = remaining apples
        #expect(model.row(forNumberKey: "1")?.title == "apple10")
    }

    @Test func noMatchClearsSelectionAndReportsSearching() {
        let model = HistoryPanelModel()
        model.reset(historyRows: rows(["alpha", "beta"]), snippetRows: [])
        model.searchText = "zzz"
        model.searchTextDidChange()
        #expect(model.visibleRows.isEmpty)
        #expect(model.selection == nil)     // nothing to highlight
        #expect(model.selectedRow == nil)
        #expect(model.isSearching)          // drives the "No results" empty state
        #expect(!model.historyRows.isEmpty)        // distinct from a truly empty history
    }

    @Test func resetClearsAnyPriorSearch() {
        let model = HistoryPanelModel()
        model.reset(historyRows: rows(["alpha", "beta", "gamma"]), snippetRows: [])
        model.searchText = "alpha"
        model.searchTextDidChange()
        #expect(model.visibleRows.count == 1)

        model.reset(historyRows: rows(["x", "y"]), snippetRows: []) // a fresh open
        #expect(model.searchText.isEmpty)   // search cleared ⇒ classic/unfiltered
        #expect(model.visibleRows.count == 2)
        #expect(!model.isSearching)
    }

    @Test func selectionIsAtVisibleTopGuardsTheUpArrowJump() {
        let model = HistoryPanelModel()
        model.itemsPerPage = 10
        let all = rows((0..<5).map { "r\($0)" })
        model.reset(historyRows: all, snippetRows: [])
        #expect(model.selectionIsAtVisibleTop)           // reset highlights the top row
        model.selection = model.visibleRows[2].id
        #expect(!model.selectionIsAtVisibleTop)          // mid-list → bare ↑ should move the highlight
        model.selection = nil
        #expect(model.selectionIsAtVisibleTop)           // no selection → treat as top (allow jump)
    }

    // MARK: - Combined history + snippets, scope, header skipping

    private struct SnippetSet { let header: PanelRow; let helloRow: PanelRow; let byeRow: PanelRow }
    private func snippetSet() -> SnippetSet {
        SnippetSet(header: .folderHeader(UUID(), title: "Greetings"),
                   helloRow: .snippet(UUID(), title: "hello"),
                   byeRow: .snippet(UUID(), title: "bye"))
    }

    @Test func scopeAllListsHistoryThenSnippetsAndSelectsTopHistory() {
        let model = HistoryPanelModel()
        model.itemsPerPage = 20
        let history = rows(["c0", "c1"])
        let snip = snippetSet()
        model.reset(historyRows: history, snippetRows: [snip.header, snip.helloRow, snip.byeRow])
        #expect(model.hasSnippets)
        #expect(model.visibleRows.map(\.title) == ["c0", "c1", "Greetings", "hello", "bye"])
        #expect(model.selection == history.first?.id) // top selectable = first history clip, not a header
    }

    @Test func numberKeysAndDisplayNumbersSkipFolderHeaders() {
        let model = HistoryPanelModel()
        model.itemsPerPage = 20
        model.startWithZero = false
        let snip = snippetSet()
        model.reset(historyRows: rows(["c0"]), snippetRows: [snip.header, snip.helloRow, snip.byeRow])
        // Selectable order: c0(1), hello(2), bye(3); the header consumes no digit and has no number.
        #expect(model.row(forNumberKey: "1")?.title == "c0")
        #expect(model.row(forNumberKey: "2")?.title == "hello")
        #expect(model.row(forNumberKey: "3")?.title == "bye")
        #expect(model.displayNumber(for: snip.header) == nil) // header: no number
        #expect(model.displayNumber(for: snip.helloRow) == 2)        // first snippet = 2nd selectable
    }

    @Test func setScopeNarrowsToHistoryOrSnippets() {
        let model = HistoryPanelModel()
        model.itemsPerPage = 20
        let snip = snippetSet()
        model.reset(historyRows: rows(["c0", "c1"]), snippetRows: [snip.header, snip.helloRow, snip.byeRow])

        model.setScope(.history)
        #expect(model.visibleRows.map(\.title) == ["c0", "c1"])
        model.setScope(.snippets)
        #expect(model.visibleRows.map(\.title) == ["Greetings", "hello", "bye"])
        #expect(model.selection == snip.helloRow.id) // top selectable in snippets scope = first snippet
    }

    @Test func resetToSnippetsScopeFallsBackToAllWhenNoSnippets() {
        let model = HistoryPanelModel()
        model.reset(historyRows: rows(["c0"]), snippetRows: [], scope: .snippets)
        #expect(model.scope == .all)       // requested snippets but none exist → fall back
        #expect(!model.hasSnippets)
    }

    @Test func resetClearsTheManagementOverlay() {
        // A fresh open must never start with the management overlay up (review #1 — the overlay state
        // is cleared on every open so it can't leak across presentations).
        let model = HistoryPanelModel()
        model.isManagementOpen = true
        model.reset(historyRows: rows(["a"]), snippetRows: [])
        #expect(!model.isManagementOpen)
    }

    // MARK: - Arrow-key selection movement (drives the custom keyboard list, replacing native List nav)

    @Test func selectNextMovesDownSkippingHeadersAndClampsAtBottom() {
        let model = HistoryPanelModel()
        model.itemsPerPage = 20
        let snip = snippetSet()
        model.reset(historyRows: rows(["c0", "c1"]), snippetRows: [snip.header, snip.helloRow, snip.byeRow])
        // Selectable order: c0, c1, hello, bye (the "Greetings" header is skipped).
        #expect(model.selection == model.historyRows.first?.id) // starts on c0
        model.selectNext()
        #expect(model.selection == model.historyRows[1].id)     // c1
        model.selectNext()
        #expect(model.selection == snip.helloRow.id)            // hello (header skipped)
        model.selectNext()
        #expect(model.selection == snip.byeRow.id)              // bye
        model.selectNext()
        #expect(model.selection == snip.byeRow.id)              // clamped at the last selectable row
    }

    @Test func selectPreviousMovesUpAndReportsTop() {
        let model = HistoryPanelModel()
        model.itemsPerPage = 20
        let snip = snippetSet()
        model.reset(historyRows: rows(["c0"]), snippetRows: [snip.header, snip.helloRow, snip.byeRow])
        // Selectable order: c0, hello, bye. Jump to the last, then walk back up.
        model.selection = snip.byeRow.id
        #expect(model.selectPrevious() == true)
        #expect(model.selection == snip.helloRow.id)            // bye → hello
        #expect(model.selectPrevious() == true)
        #expect(model.selection == model.historyRows.first?.id) // hello → c0 (header skipped)
        #expect(model.selectPrevious() == false)                // at the top → caller hands focus to search
        #expect(model.selection == model.historyRows.first?.id) // selection unchanged when already at top
    }
}
