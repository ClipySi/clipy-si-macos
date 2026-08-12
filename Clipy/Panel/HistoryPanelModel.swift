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
//  M-UI.11 P2 (show-first + keyset): `historyRows` is no longer always the whole capped window.
//  A fresh open goes through `beginLoading` (shell up, list EMPTY, paste dead) and then
//  `commitFirstPage` — after which the rows are a sequential PREFIX of the window and paging
//  math runs on `historyWindowTotal`. Sequential page moves past the prefix park on
//  `pendingPage` and ask the controller for more via `onNeedsMoreHistory`; narrowing inputs
//  (search / category / chips) can't be answered from a prefix, so they hold a blank list and
//  request the complete window via `onNeedsWindowHydration` (P2 interim — P4 replaces that with
//  a progressive scan). Legacy `reset` still commits a complete window in one call (tests, and
//  any caller that already has every row).
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

    // MARK: - Windowed history (M-UI.11 P2)

    // The three window-state fields below are internal-settable only for the mutation extension
    // split (HistoryPanelModel+Mutations.swift); nothing outside the model's own mutations may
    // write them.

    /// True from `beginLoading` until `commitFirstPage`/`completeWindow`: the shell is up but the
    /// row set is indeterminate, so the derived tier stays EMPTY — nothing to select, number, or
    /// paste (§3.1: loading must not let Return/digits fire on unconfirmed rows). Mutated only
    /// inside the batch mutations, so it needs no didSet of its own.
    var isLoadingFirstRows = false
    /// False while `historyRows` is a sequential PREFIX of the capped live window (normal paged
    /// browsing); true when it holds everything this open can show (legacy `reset`, a hydrated
    /// window, or an exhausted walk). Narrowing requires a complete window.
    var historyWindowComplete = true
    /// Live clips in the capped window (`min(live count, maxHistorySize)`) — the paging/badge
    /// total while the rows are a prefix. Meaningless (and unused) once `historyWindowComplete`;
    /// the forwarders switch to `historyRows.count` there.
    var historyWindowTotal = 0

    /// Sequential paging wants rows beyond the loaded prefix: the controller fetches the next
    /// keyset page (from its cursor) and replies via `appendHistoryPage`. Fired from `goToPage`.
    @ObservationIgnored var onNeedsMoreHistory: (() -> Void)?
    /// A narrowing input (search / category / chips) needs the COMPLETE capped window: the
    /// controller fetches it off-main and replies via `completeWindow`. May fire repeatedly
    /// while the need persists — the controller coalesces in-flight requests.
    @ObservationIgnored var onNeedsWindowHydration: (() -> Void)?
    /// The page a blocked `goToPage` is waiting to land on (§5.3: the visible page holds until
    /// the rows exist — never a seam of misplaced rows). Applied by `appendHistoryPage`.
    /// Internal only for the mutation extension split — treat as private.
    @ObservationIgnored var pendingPage: Int?

    // MARK: - Derived snapshot

    /// The derived list state. Stored (and observable, so `body` re-renders on rebuild); the
    /// forwarders below keep the pre-P1 property surface intact for the view and the tests.
    /// Internal (not private) only for the mutation extension split
    /// (HistoryPanelModel+Mutations.swift, a lint file-length measure) — not API.
    struct DerivedState {
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
        /// A narrowing input is waiting on the complete window (M-UI.11 P2): the list renders
        /// blank — partial matches over a prefix must never pose as results (§3.1).
        var isHydratingWindow = false
    }

    private(set) var derived = DerivedState()
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
    /// Internal only for the mutation extension split — never call from outside the model.
    func withBatchedInputs(_ mutate: () -> Void) {
        isBatchingInputs = true
        mutate()
        isBatchingInputs = false
        rebuildFilteredTier()
    }

    /// The O(rows) tier: scope → (classify if needed) → category → search, plus chip counts while
    /// the chips row is shown. Ends by rebuilding the page tier (the slice depends on the result).
    private func rebuildFilteredTier() {
        filteredRebuildCount += 1
        // Loading shell (P2): the HISTORY row set is indeterminate — the history-bearing scopes
        // render nothing (nothing to select, number, or paste). The snippets scope falls through
        // and stays fully live: its rows arrived synchronously with the shell and the history
        // commit cannot change them, so a fast "⌘⇧B then digit" paste keeps working, and the
        // scope-tab badges keep their real snippet counts (review).
        if isLoadingFirstRows && scope != .snippets {
            var next = DerivedState()
            next.snippetSelectableCount = snippetRows.count(where: \.isSelectable)
            derived = next
            return
        }
        var next = DerivedState()
        next.snippetSelectableCount = snippetRows.count(where: \.isSelectable)
        // A narrowing input over a PREFIX window can't produce trustworthy rows or counts —
        // hold a blank list and ask for the complete window (P2 interim; P4: progressive scan).
        // Callback last: it only spawns the controller's fetch task, never mutates the model
        // synchronously. The snippets scope never hydrates: its rows are always complete and
        // history plays no part in its results (review).
        if (isSearching || isCategoryFiltering || showsFilterBar) && !historyWindowComplete
            && scope != .snippets {
            next.isHydratingWindow = true
            derived = next
            onNeedsWindowHydration?()
            return
        }
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

    /// The paging denominator: the loaded (filtered) rows once the window is complete; the
    /// scope's TOTAL rendered rows (capped live count + snippet rows incl. headers) while it is
    /// a prefix — the footer must show the real page count even though only the walked pages are
    /// materialized. A prefix is by construction un-narrowed (narrowing hydrates first), so the
    /// filtered set equals the scoped set there.
    func effectiveRowCount(loaded: Int) -> Int {
        guard !historyWindowComplete else { return loaded }
        switch scope {
        case .history: return historyWindowTotal
        case .all: return historyWindowTotal + snippetRows.count
        case .snippets: return snippetRows.count
        }
    }

    /// The O(page) tier: slice the current page out of the filtered rows, resolve its
    /// classification (glyphs/preview), and precompute the number maps.
    private func rebuildPageTier() {
        var next = derived
        next.pageCount = PanelPaging.pageCount(rowCount: effectiveRowCount(loaded: next.filteredRows.count),
                                               itemsPerPage: itemsPerPage)
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
    /// While the window is a prefix (P2), the history badge shows the WINDOW total, not the loaded
    /// prefix — the bucket's size doesn't shrink because only one page is materialized.
    var historyCount: Int { historyWindowComplete ? historyRows.count : historyWindowTotal }
    var snippetCount: Int { derived.snippetSelectableCount }
    var allCount: Int { historyCount + snippetCount }

    /// A narrowing input is waiting on the complete window (blank list, no counts) — P2 interim.
    var isHydratingWindow: Bool { derived.isHydratingWindow }

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
        // Loading/hydrating (P2): the row set is unknown, so no empty state is truthful — the
        // list region stays blank rather than flashing "No history" / "No results".
        guard !isLoadingFirstRows && !derived.isHydratingWindow else { return .none }
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
        // A prefix window has no exact counts to offer (P2): the chips render without badges
        // (a partial count posing as exact would break §3.1) until hydration completes.
        guard historyWindowComplete else { return [:] }
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
}
