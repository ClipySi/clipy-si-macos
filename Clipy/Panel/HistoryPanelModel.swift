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
//  M-UI.11 P1: the derived list state (filter chain, page slice, number maps, chip counts) is a
//  STORED snapshot rebuilt exactly once per input mutation — never inside `body`. Two tiers keep
//  the work proportional to the change: the filtered tier walks the row sets (scope → category →
//  search) when rows/scope/category/query change; the page tier only re-slices the current page
//  when the cursor or page size moves. Code classification is resolved lazily through
//  `PanelClassificationCache` — for the visible page always, and for ALL scoped rows only when a
//  title-dependent category (.text/.code) or the chip counts actually need verdicts.
//

import Foundation
import Observation

@MainActor
@Observable
final class HistoryPanelModel {
    /// Which kinds of rows the panel currently shows. `.all` lists history first, then snippets.
    enum Scope: Hashable, CaseIterable { case all, history, snippets }

    // MARK: - Inputs (every didSet rebuilds the derived snapshot exactly once; the multi-field
    // mutations below batch through `withBatchedInputs` so one user action = one rebuild)

    // Scalar inputs carry a cheap equality guard: Swift fires didSet on same-value re-assignment
    // too (settings stamps at open, bindings re-writing an unchanged query), and an equal input
    // cannot change the derived state. The row ARRAYS deliberately have no guard — comparing
    // thousands of rows would cost more than the rebuild they'd save, and reset() batches them.

    /// History clip rows (newest-first), already decrypted + masked — but NOT yet code-classified
    /// (`needsCodeClassification`; the snapshot resolves lazily). Plus snippet rows (folder headers +
    /// enabled snippets). The two are kept apart so scope can pick a subset without rebuilding.
    var historyRows: [PanelRow] = [] { didSet { inputsDidChange() } }
    var snippetRows: [PanelRow] = [] { didSet { inputsDidChange() } }
    /// The active scope (reset to `.all` on each open). `⌘1/⌘2/⌘3` set it via `setScope`.
    var scope: Scope = .all { didSet { if oldValue != scope { inputsDidChange() } } }
    /// The active category filter chip (reset to `.all` on each open and when entering the
    /// Snippets scope — snippets carry no content kind).
    var category: PanelCategory = .all { didSet { if oldValue != category { inputsDidChange() } } }
    /// Whether the category chips row under the search field is shown (the filter toggle button).
    /// Per-open reset, like scope/search. An input: chip counts are computed only while it is open.
    var isFilterBarOpen = false { didSet { if oldValue != isFilterBarOpen { inputsDidChange() } } }
    /// The live search query. Matched against the masked clip `title` (C3) and the plaintext snippet
    /// title via `PanelSearch.filterCombined`. Empty ⇒ classic, unfiltered. The view two-way binds this.
    var searchText = "" { didSet { if oldValue != searchText { inputsDidChange() } } }
    /// The request's resolved display policy — part of every classification-cache key. Swapped in
    /// atomically WITH the rows by `reset(…, policy:)`; a standalone assignment still rebuilds so
    /// no caller can leave the snapshot keyed against a policy the rows weren't built under.
    var displayPolicy = DisplayPolicy(maskEnabled: false, maskStyleRaw: "full",
                                      classifierAlgorithmVersion: CodeClassifier.algorithmVersion) {
        didSet { if oldValue != displayPolicy { inputsDidChange() } }
    }

    /// Whether the side preview pane is expanded. A persisted preference: the controller
    /// loads it from UserDefaults on each show and saves it on toggle — deliberately NOT touched by
    /// `reset()` (preview size is a steady user taste, unlike the per-open scope/search/category).
    var isPreviewExpanded = false
    /// The side the preview pane is RENDERED on — the controller resolves the user preference +
    /// the edge-flip rule against the screen (FloatingPanelLayout.resolvedPreviewSide) on every
    /// open/toggle, so the view just renders whatever this says.
    var previewSide: PanelPreviewSide = .right
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

    var itemsPerPage = 10 { didSet { if oldValue != itemsPerPage { pageDidChange() } } }
    var currentPage = 0 { didSet { if oldValue != currentPage { pageDidChange() } } }
    var startWithZero = false { didSet { if oldValue != startWithZero { pageDidChange() } } }
    var markedWithNumbers = true

    // MARK: - Derived snapshot

    /// The derived list state. Stored (and observable, so `body` re-renders on rebuild); the
    /// forwarders below keep the pre-P1 property surface intact for the view and the tests.
    private struct DerivedState {
        var filteredRows: [PanelRow] = []
        var visibleRows: [PanelRow] = []
        var selectableVisibleRows: [PanelRow] = []
        var pageCount = 1
        var numberByRowID: [RowID: Int] = [:]
        var rowByNumberKey: [String: PanelRow] = [:]
        var snippetSelectableCount = 0
        /// nil while the chips row is hidden — nothing on screen needs counts then; the
        /// `categoryCounts` forwarder computes on demand for off-screen callers (tests).
        var categoryCounts: [PanelCategory: Int]?
    }

    private var derived = DerivedState()
    /// Suppresses per-didSet rebuilds while a multi-field mutation (reset/setScope/…) runs; the
    /// mutation rebuilds once at the end.
    @ObservationIgnored private var isBatchingInputs = false
    /// How many filtered-tier rebuilds have run — the P1 exit criterion's test hook ("one input
    /// change ⇒ one snapshot recomputation"). Not rendered anywhere.
    @ObservationIgnored private(set) var filteredRebuildCount = 0
    /// Lazily-resolved `CodeClassifier` verdicts (see PanelClassificationCache). Internal so the
    /// P1 tests can pin the hit/miss contract. (`let` — @Observable never tracks constants.)
    let classificationCache = PanelClassificationCache()

    private func inputsDidChange() {
        guard !isBatchingInputs else { return }
        rebuildFilteredTier()
    }

    private func pageDidChange() {
        guard !isBatchingInputs else { return }
        rebuildPageTier()
    }

    /// Runs `mutate` with per-didSet rebuilds suppressed, then rebuilds the filtered tier once.
    private func withBatchedInputs(_ mutate: () -> Void) {
        isBatchingInputs = true
        mutate()
        isBatchingInputs = false
        rebuildFilteredTier()
    }

    /// The O(rows) tier: scope → (classify if needed) → category → search, plus chip counts while
    /// the chips row is shown. Ends by rebuilding the page tier (the slice depends on the result).
    private func rebuildFilteredTier() {
        filteredRebuildCount += 1
        var next = DerivedState()
        next.snippetSelectableCount = snippetRows.count(where: \.isSelectable)
        let scoped = scopedRows
        // Verdicts are needed up front ONLY for a title-dependent category or the chip counts;
        // otherwise the page tier classifies just the visible slice.
        let needsVerdicts = category == .text || category == .code || showsFilterBar
        let rows = needsVerdicts ? classificationCache.resolve(scoped, policy: displayPolicy) : scoped
        next.filteredRows = PanelSignpost.measure(.searchFilter, rows: rows.count) {
            PanelSearch.filterCombined(PanelFilter.filter(rows, category: category), query: searchText)
        }
        if showsFilterBar {
            next.categoryCounts = PanelSignpost.measure(.categoryCounts, rows: rows.count) {
                PanelFilter.counts(PanelSearch.filterCombined(rows, query: searchText))
            }
        }
        derived = next
        rebuildPageTier()
    }

    /// The O(page) tier: slice the current page out of the filtered rows, resolve its
    /// classification (glyphs/preview), and precompute the number maps.
    private func rebuildPageTier() {
        var next = derived
        next.pageCount = PanelPaging.pageCount(rowCount: next.filteredRows.count, itemsPerPage: itemsPerPage)
        let range = PanelPaging.range(page: currentPage, rowCount: next.filteredRows.count, itemsPerPage: itemsPerPage)
        let visible = classificationCache.resolve(Array(next.filteredRows[range]), policy: displayPolicy)
        next.visibleRows = visible
        next.selectableVisibleRows = visible.filter(\.isSelectable)
        var numberByRowID: [RowID: Int] = [:]
        var rowByNumberKey: [String: PanelRow] = [:]
        for (index, row) in next.selectableVisibleRows.prefix(PanelPaging.maxNumberKeys).enumerated() {
            if let key = PanelPaging.numberKey(pageLocalIndex: index, startWithZero: startWithZero) {
                rowByNumberKey[key] = row
            }
            numberByRowID[row.id] = PanelPaging.displayNumber(pageLocalIndex: index, startWithZero: startWithZero)
        }
        next.numberByRowID = numberByRowID
        next.rowByNumberKey = rowByNumberKey
        derived = next
    }

    // MARK: - Derived (read surface — forwarders into the stored snapshot)

    /// Whether the user has any snippets — drives showing the scope chips (hidden when there are none,
    /// so a snippet-free profile sees today's history-only panel).
    var hasSnippets: Bool { !snippetRows.isEmpty }

    /// Total selectable items per scope, for the tab-bar count badges. Totals (not the filtered/visible
    /// count) so the badges read as "how many items live in each bucket"; `historyRows` are all clips
    /// (selectable), `snippetRows` interleave non-selectable folder headers so those are excluded.
    var historyCount: Int { historyRows.count }
    var snippetCount: Int { derived.snippetSelectableCount }
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
        if scopedRowsAreEmpty { return .noHistory }
        if isSearching { return .searchNoResults(query: searchText.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if isCategoryFiltering { return .categoryNoMatches(category) }
        if scope == .snippets { return .snippetsCTA }
        return .noHistory
    }

    /// The rows in the active scope, before search. `.all` = history first, then snippets.
    /// Assembled on demand (the snapshot rebuild is its only hot caller).
    var scopedRows: [PanelRow] {
        switch scope {
        case .all: return historyRows + snippetRows
        case .history: return historyRows
        case .snippets: return snippetRows
        }
    }

    /// `scopedRows.isEmpty` without building the concatenated array (checked from `emptyState` in body).
    private var scopedRowsAreEmpty: Bool {
        switch scope {
        case .all: return historyRows.isEmpty && snippetRows.isEmpty
        case .history: return historyRows.isEmpty
        case .snippets: return snippetRows.isEmpty
        }
    }

    /// `scopedRows` narrowed by the category chip, then by the live `searchText` (header-aware; C3
    /// over masked clip titles). Chain: scope → category → search. Stored — rebuilt once per input
    /// change, never in body (M-UI.11 P1).
    var filteredRows: [PanelRow] { derived.filteredRows }

    /// Per-category counts for the filter chips' badges: over the current scope's rows AFTER the
    /// live search (but before the category itself), so a badge never promises N items that the
    /// active query then narrows to zero (adversarial review). Precomputed while the chips row is
    /// shown; the fallback computes on demand for off-screen callers (body never takes that path).
    var categoryCounts: [PanelCategory: Int] {
        if let counts = derived.categoryCounts { return counts }
        let rows = classificationCache.resolve(scopedRows, policy: displayPolicy)
        return PanelFilter.counts(PanelSearch.filterCombined(rows, query: searchText))
    }

    /// True when a non-All category chip is narrowing the rows (drives the toggle's active tint and
    /// the filtered-empty state).
    var isCategoryFiltering: Bool { category != .all }

    /// Whether the category chips row is actually on screen: open AND not in the Snippets scope
    /// (snippets carry no content kind). Drives both rendering and the chips' focus-chain slot.
    var showsFilterBar: Bool { isFilterBarOpen && scope != .snippets }

    var pageCount: Int { derived.pageCount }

    /// True when a search query is narrowing the result (drives the "No results" empty state).
    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The rows on the current page (within the filtered set; may include folder headers), already
    /// code-classified for their glyphs/preview.
    var visibleRows: [PanelRow] { derived.visibleRows }

    /// The first *selectable* (non-header) row on the visible page — the default highlight target and
    /// the target when the search field hands focus down to the list.
    var firstSelectableVisibleRow: PanelRow? { derived.selectableVisibleRows.first }
    var firstSelectableVisibleID: RowID? { firstSelectableVisibleRow?.id }

    /// The selectable (non-header) rows on the current page, in order — the targets for ↑/↓ navigation.
    /// The panel drives arrow-key movement through these explicitly (it no longer relies on a SwiftUI
    /// `List(selection:)`, whose native arrow handling was unreliable in the non-activating panel).
    var selectableVisibleRows: [PanelRow] { derived.selectableVisibleRows }

    /// The currently highlighted row (always within the visible page).
    var selectedRow: PanelRow? {
        guard let selection else { return nil }
        return derived.visibleRows.first { $0.id == selection }
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
        guard let selection, let bottomID = derived.selectableVisibleRows.last?.id else { return true }
        return selection == bottomID
    }

    // MARK: - Mutations

    /// Refills both row sets for a fresh open: clears any prior search, resets to page 0, and highlights
    /// the top selectable row. `requestedScope` lets a caller open straight onto a scope (e.g. the snippet
    /// hotkey → `.snippets`); it falls back to `.all` when that scope would be empty.
    ///
    /// `policy` swaps in ATOMICALLY with the rows (nil keeps the current one). Stamping the policy
    /// separately before the rows would resolve the PREVIOUS open's rows — titles masked under the
    /// old policy — into cache entries keyed by the new policy, and the poisoned verdicts would
    /// then hit for the new rows (review, P1).
    func reset(historyRows: [PanelRow], snippetRows: [PanelRow], scope requestedScope: Scope = .all,
               policy: DisplayPolicy? = nil) {
        withBatchedInputs {
            if let policy { displayPolicy = policy }
            self.historyRows = historyRows
            self.snippetRows = snippetRows
            self.scope = (requestedScope == .snippets && snippetRows.isEmpty) ? .all : requestedScope
            searchText = ""
            category = .all
            isFilterBarOpen = false
            currentPage = 0
        }
        selection = firstSelectableVisibleID
        isManagementOpen = false
        openToken &+= 1
    }

    /// Close the chips row, clearing any active category, in ONE rebuild (the funnel toggle-off /
    /// ⌘F-off path — `isFilterBarOpen = false` followed by `setCategory(.all)` would walk the rows
    /// twice). A closed bar must never keep narrowing the list.
    func closeFilterBar() {
        guard isFilterBarOpen else { return }
        let hadCategory = category != .all
        withBatchedInputs {
            isFilterBarOpen = false
            if hadCategory {
                category = .all
                currentPage = 0
            }
        }
        if hadCategory { selection = firstSelectableVisibleID }
    }

    /// Switch the category chip and re-base to page 0 + top selectable row, keeping scope and query.
    func setCategory(_ newCategory: PanelCategory) {
        guard newCategory != category else { return }
        withBatchedInputs {
            category = newCategory
            currentPage = 0
        }
        selection = firstSelectableVisibleID
    }

    /// Re-base paging/selection after the query changes: page 0 of the new result set, top selectable row.
    /// (The query's own didSet already rebuilt the filtered tier.)
    func searchTextDidChange() {
        currentPage = 0
        selection = firstSelectableVisibleID
    }

    /// Switch scope (⌘1/⌘2/⌘3) and re-base to page 0 + top selectable row, keeping the query.
    /// Entering the Snippets scope clears the category filter (snippets carry no content kind —
    /// any non-All chip would blank the list confusingly; the chips row is hidden there too).
    func setScope(_ newScope: Scope) {
        guard newScope != scope else { return }
        withBatchedInputs {
            scope = newScope
            if newScope == .snippets {
                category = .all
            }
            currentPage = 0
        }
        selection = firstSelectableVisibleID
    }

    /// Move to `page` (clamped) and highlight that page's top selectable row.
    func goToPage(_ page: Int) {
        currentPage = PanelPaging.clampPage(page, rowCount: derived.filteredRows.count, itemsPerPage: itemsPerPage)
        selection = firstSelectableVisibleID
    }

    func nextPage() { goToPage(currentPage + 1) }
    func previousPage() { goToPage(currentPage - 1) }

    /// Move the highlight to the next selectable row on the page (clamped at the bottom). No-op when the
    /// page has no selectable rows. ↓ in the list.
    func selectNext() {
        let rows = derived.selectableVisibleRows
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
        let rows = derived.selectableVisibleRows
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
        derived.rowByNumberKey[key]
    }

    /// The "N." prefix number to display for `row`, or `nil` for a header / when numbering is off / past
    /// the first 10 selectable rows. Numbering counts only selectable rows (folder headers don't consume
    /// a digit), so the shown number always matches the key that pastes it.
    func displayNumber(for row: PanelRow) -> Int? {
        guard markedWithNumbers else { return nil }
        return derived.numberByRowID[row.id]
    }
}
