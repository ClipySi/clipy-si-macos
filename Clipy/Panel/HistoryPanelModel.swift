//
//  HistoryPanelModel.swift
//  ClipySi — Apple Silicon rewrite
//
//  Observable state for the unified FloatingPanel's SwiftUI body: clipboard history AND
//  snippets in ONE paged List, plus a scope (All / History / Snippets), keyboard selection, and the
//  paging cursor. The controller refills both row sets (and the per-open paging config) each time the
//  panel opens (a snapshot at open). Folder-header rows are display-only — skipped by selection,
//  numbering, and navigation. AppKit/SwiftUI-bound → `@MainActor`.
//

import Foundation
import Observation

@MainActor
@Observable
final class HistoryPanelModel {
    /// Which kinds of rows the panel currently shows. `.all` lists history first, then snippets.
    enum Scope: Hashable, CaseIterable { case all, history, snippets }

    /// History clip rows (newest-first), already decrypted + masked. Plus snippet rows (folder headers +
    /// enabled snippets). The two are kept apart so scope can pick a subset without rebuilding.
    var historyRows: [PanelRow] = []
    var snippetRows: [PanelRow] = []
    /// The active scope (reset to `.all` on each open). `⌘1/⌘2/⌘3` set it via `setScope`.
    var scope: Scope = .all
    /// The active category filter chip (reset to `.all` on each open and when entering the
    /// Snippets scope — snippets carry no content kind).
    var category: PanelCategory = .all
    /// Whether the category chips row under the search field is shown (the filter toggle button).
    /// Per-open reset, like scope/search.
    var isFilterBarOpen = false
    /// Whether the side preview pane is expanded. A persisted preference: the controller
    /// loads it from UserDefaults on each show and saves it on toggle — deliberately NOT touched by
    /// `reset()` (preview size is a steady user taste, unlike the per-open scope/search/category).
    var isPreviewExpanded = false
    /// The side the preview pane is RENDERED on — the controller resolves the user preference +
    /// the edge-flip rule against the screen (FloatingPanelLayout.resolvedPreviewSide) on every
    /// open/toggle, so the view just renders whatever this says.
    var previewSide: PanelPreviewSide = .right
    /// The live search query. Matched against the masked clip `title` (C3) and the plaintext snippet
    /// title via `PanelSearch.filterCombined`. Empty ⇒ classic, unfiltered. The view two-way binds this.
    var searchText = ""
    /// The highlighted row's id (a *selectable* row — never a folder header). `Return` pastes it.
    var selection: RowID?
    /// Bumped on every `show()` so the view can re-drive list focus (panel reused across opens).
    var openToken = 0
    /// Whether the management overlay (Settings/About/Edit Snippets/History/Clear/Quit) is showing
    /// over the list. Opened by the gear button or ⌘M; Esc closes it without closing the
    /// panel. Cleared on every `reset()` so a fresh open never starts with the overlay up.
    var isManagementOpen = false
    /// DEBUG-only focus PoC readout (history-panel design §2.5); display is gated by `#if DEBUG`.
    var focusProbe: PanelFocusProbe?

    // MARK: - Paging config (set per-open from settings)

    var itemsPerPage = 10
    var currentPage = 0
    var startWithZero = false
    var markedWithNumbers = true

    // MARK: - Derived

    /// Whether the user has any snippets — drives showing the scope chips (hidden when there are none,
    /// so a snippet-free profile sees today's history-only panel).
    var hasSnippets: Bool { !snippetRows.isEmpty }

    /// Total selectable items per scope, for the tab-bar count badges. Totals (not the filtered/visible
    /// count) so the badges read as "how many items live in each bucket"; `historyRows` are all clips
    /// (selectable), `snippetRows` interleave non-selectable folder headers so those are excluded.
    var historyCount: Int { historyRows.count }
    var snippetCount: Int { snippetRows.lazy.filter(\.isSelectable).count }
    var allCount: Int { historyCount + snippetCount }

    /// Nothing to show at all (no history and no snippets) — distinct from "no search results".
    var isEmpty: Bool { historyRows.isEmpty && snippetRows.isEmpty }

    /// Which empty state (if any) the list region should show — `.none` while rows are visible.
    /// Precedence when several narrows are active at once: the search query is the user's most
    /// recent/most specific act, then the category chip, then the scope (§2.2).
    enum EmptyState: Equatable {
        case none
        case searchNoResults(query: String)
        case categoryNoMatches(PanelCategory)
        case snippetsCTA
        case noHistory
    }

    var emptyState: EmptyState {
        guard filteredRows.isEmpty else { return .none }
        // A truly-empty bucket outranks the narrows: "no results, try a different search" (or a
        // Clear Filter button) is dead-end advice when the scope held nothing to begin with — the
        // snippets CTA / onboarding card are the only useful guidance there (adversarial review).
        if scope == .snippets && snippetRows.isEmpty { return .snippetsCTA }
        if scopedRows.isEmpty { return .noHistory }
        if isSearching { return .searchNoResults(query: searchText.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if isCategoryFiltering { return .categoryNoMatches(category) }
        if scope == .snippets { return .snippetsCTA }
        return .noHistory
    }

    /// The rows in the active scope, before search. `.all` = history first, then snippets.
    var scopedRows: [PanelRow] {
        switch scope {
        case .all: return historyRows + snippetRows
        case .history: return historyRows
        case .snippets: return snippetRows
        }
    }

    /// `scopedRows` narrowed by the category chip, then by the live `searchText` (header-aware; C3
    /// over masked clip titles). Chain: scope → category → search. Signposted per recomputation —
    /// SwiftUI re-runs this full-array pipeline inside body/update (M-UI.11 P0 baseline; P1
    /// replaces it with a stored snapshot).
    var filteredRows: [PanelRow] {
        PanelSignpost.measure(.searchFilter, rows: historyRows.count + snippetRows.count) {
            PanelSearch.filterCombined(PanelFilter.filter(scopedRows, category: category), query: searchText)
        }
    }

    /// Per-category counts for the filter chips' badges: over the current scope's rows AFTER the
    /// live search (but before the category itself), so a badge never promises N items that the
    /// active query then narrows to zero (adversarial review). Signposted per recomputation — a
    /// second full-array pass on top of `filteredRows` today (M-UI.11 P0 baseline).
    var categoryCounts: [PanelCategory: Int] {
        PanelSignpost.measure(.categoryCounts, rows: historyRows.count + snippetRows.count) {
            PanelFilter.counts(PanelSearch.filterCombined(scopedRows, query: searchText))
        }
    }

    /// True when a non-All category chip is narrowing the rows (drives the toggle's active tint and
    /// the filtered-empty state).
    var isCategoryFiltering: Bool { category != .all }

    /// Whether the category chips row is actually on screen: open AND not in the Snippets scope
    /// (snippets carry no content kind). Drives both rendering and the chips' focus-chain slot.
    var showsFilterBar: Bool { isFilterBarOpen && scope != .snippets }

    var pageCount: Int { PanelPaging.pageCount(rowCount: filteredRows.count, itemsPerPage: itemsPerPage) }

    /// True when a search query is narrowing the result (drives the "No results" empty state).
    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The rows on the current page (within the filtered set; may include folder headers).
    var visibleRows: [PanelRow] {
        let filtered = filteredRows
        let range = PanelPaging.range(page: currentPage, rowCount: filtered.count, itemsPerPage: itemsPerPage)
        return Array(filtered[range])
    }

    /// The first *selectable* (non-header) row on the visible page — the default highlight target and
    /// the target when the search field hands focus down to the list.
    var firstSelectableVisibleRow: PanelRow? { visibleRows.first(where: \.isSelectable) }
    var firstSelectableVisibleID: RowID? { firstSelectableVisibleRow?.id }

    /// The selectable (non-header) rows on the current page, in order — the targets for ↑/↓ navigation.
    /// The panel drives arrow-key movement through these explicitly (it no longer relies on a SwiftUI
    /// `List(selection:)`, whose native arrow handling was unreliable in the non-activating panel).
    var selectableVisibleRows: [PanelRow] { visibleRows.filter(\.isSelectable) }

    /// The currently highlighted row (always within the visible page).
    var selectedRow: PanelRow? {
        guard let selection else { return nil }
        return visibleRows.first { $0.id == selection }
    }

    /// True when the highlight is on the first selectable visible row — the condition for a bare `↑` to
    /// jump up out of the list (to the scope tabs) rather than move the highlight.
    var selectionIsAtVisibleTop: Bool {
        guard let selection, let topID = firstSelectableVisibleID else { return true }
        return selection == topID
    }

    /// True when the highlight is on the last selectable visible row — the condition for a bare `↓` to
    /// roll onto the next page rather than clamp at the bottom of the current page.
    var selectionIsAtVisibleBottom: Bool {
        guard let selection, let bottomID = selectableVisibleRows.last?.id else { return true }
        return selection == bottomID
    }

    // MARK: - Mutations

    /// Refills both row sets for a fresh open: clears any prior search, resets to page 0, and highlights
    /// the top selectable row. `requestedScope` lets a caller open straight onto a scope (e.g. the snippet
    /// hotkey → `.snippets`); it falls back to `.all` when that scope would be empty.
    func reset(historyRows: [PanelRow], snippetRows: [PanelRow], scope requestedScope: Scope = .all) {
        self.historyRows = historyRows
        self.snippetRows = snippetRows
        self.scope = (requestedScope == .snippets && snippetRows.isEmpty) ? .all : requestedScope
        searchText = ""
        category = .all
        isFilterBarOpen = false
        currentPage = 0
        selection = firstSelectableVisibleID
        isManagementOpen = false
        openToken &+= 1
    }

    /// Switch the category chip and re-base to page 0 + top selectable row, keeping scope and query.
    func setCategory(_ newCategory: PanelCategory) {
        guard newCategory != category else { return }
        category = newCategory
        currentPage = 0
        selection = firstSelectableVisibleID
    }

    /// Re-base paging/selection after the query changes: page 0 of the new result set, top selectable row.
    func searchTextDidChange() {
        currentPage = 0
        selection = firstSelectableVisibleID
    }

    /// Switch scope (⌘1/⌘2/⌘3) and re-base to page 0 + top selectable row, keeping the query.
    /// Entering the Snippets scope clears the category filter (snippets carry no content kind —
    /// any non-All chip would blank the list confusingly; the chips row is hidden there too).
    func setScope(_ newScope: Scope) {
        guard newScope != scope else { return }
        scope = newScope
        if newScope == .snippets {
            category = .all
        }
        currentPage = 0
        selection = firstSelectableVisibleID
    }

    /// Move to `page` (clamped) and highlight that page's top selectable row.
    func goToPage(_ page: Int) {
        currentPage = PanelPaging.clampPage(page, rowCount: filteredRows.count, itemsPerPage: itemsPerPage)
        selection = firstSelectableVisibleID
    }

    func nextPage() { goToPage(currentPage + 1) }
    func previousPage() { goToPage(currentPage - 1) }

    /// Move the highlight to the next selectable row on the page (clamped at the bottom). No-op when the
    /// page has no selectable rows. ↓ in the list.
    func selectNext() {
        let rows = selectableVisibleRows
        guard !rows.isEmpty else { return }
        guard let current = selection, let index = rows.firstIndex(where: { $0.id == current }) else {
            selection = rows.first?.id
            return
        }
        selection = rows[min(index + 1, rows.count - 1)].id
    }

    /// Move the highlight to the previous selectable row. Returns `false` when already at the top selectable
    /// row (so the caller hands focus up to the search field); ↑ in the list.
    @discardableResult
    func selectPrevious() -> Bool {
        let rows = selectableVisibleRows
        guard !rows.isEmpty else { return false }
        guard let current = selection, let index = rows.firstIndex(where: { $0.id == current }) else {
            selection = rows.first?.id
            return true
        }
        guard index > 0 else { return false }
        selection = rows[index - 1].id
        return true
    }

    /// The visible *selectable* row bound to the pressed number key (`"1"`…`"9"`, `"0"`), if any. Folder
    /// headers are skipped, so digits index the selectable rows (clip or snippet) of the page in order.
    func row(forNumberKey key: String) -> PanelRow? {
        var selectableIndex = 0
        for row in visibleRows where row.isSelectable {
            if PanelPaging.numberKey(pageLocalIndex: selectableIndex, startWithZero: startWithZero) == key {
                return row
            }
            selectableIndex += 1
        }
        return nil
    }

    /// The "N." prefix number to display for `row`, or `nil` for a header / when numbering is off / past
    /// the first 10 selectable rows. Numbering counts only selectable rows (folder headers don't consume
    /// a digit), so the shown number always matches the key that pastes it.
    func displayNumber(for row: PanelRow) -> Int? {
        guard markedWithNumbers, row.isSelectable else { return nil }
        var selectableIndex = 0
        for candidate in visibleRows where candidate.isSelectable {
            if candidate.id == row.id {
                guard selectableIndex < PanelPaging.maxNumberKeys else { return nil }
                return PanelPaging.displayNumber(pageLocalIndex: selectableIndex, startWithZero: startWithZero)
            }
            selectableIndex += 1
        }
        return nil
    }
}
