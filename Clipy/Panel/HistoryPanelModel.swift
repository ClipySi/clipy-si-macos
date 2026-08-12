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
//  `pendingPage` and ask the controller for more via `onNeedsMoreHistory`. Legacy `reset`
//  still commits a complete window in one call (tests, and any caller that already has every
//  row).
//
//  M-UI.11 P4 (progressive scan): narrowing inputs (search / category / chips) over a prefix
//  window are served by the read service's batched scan — matches stream into `scanMatches`
//  (independent of `historyRows`, so clearing the narrowing returns to the prefix, and a
//  100k-row history never materializes wholesale — §12), stamped with the inputs they were
//  filtered by; the rebuild shows only current-stamp matches, so a rapid query replacement can
//  never flash the previous query's rows. Partial matches render live; exact counts and the
//  snippet tail (.all scope, §4.6) join on completion.
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
    /// Opening it BEGINS a narrowing (the counts scan), so a parked page move — which belongs
    /// to the un-narrowed context — is discarded here like every other narrowing entry (P4
    /// review: a landing page fetch would otherwise jump the narrowed match list).
    var isFilterBarOpen = false {
        didSet {
            if oldValue != isFilterBarOpen {
                pendingPage = nil
                inputsDidChange()
            }
        }
    }
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

    /// True from `beginLoading` until `commitFirstPage`: the shell is up but the
    /// row set is indeterminate, so the derived tier stays EMPTY — nothing to select, number, or
    /// paste (§3.1: loading must not let Return/digits fire on unconfirmed rows). Mutated only
    /// inside the batch mutations, so it needs no didSet of its own.
    var isLoadingFirstRows = false
    /// False while `historyRows` is a sequential PREFIX of the capped live window (normal paged
    /// browsing); true when it holds everything this open can show (legacy `reset`, a small
    /// history, or an exhausted walk). Narrowing over a prefix runs the progressive scan;
    /// over a complete window it filters in memory.
    var historyWindowComplete = true
    /// Live clips in the capped window (`min(live count, maxHistorySize)`) — the paging/badge
    /// total while the rows are a prefix. Meaningless (and unused) once `historyWindowComplete`;
    /// the forwarders switch to `historyRows.count` there.
    var historyWindowTotal = 0

    /// Sequential paging wants rows beyond the loaded prefix: the controller fetches the next
    /// keyset page (from its cursor) and replies via `appendHistoryPage`. Fired from `goToPage`.
    @ObservationIgnored var onNeedsMoreHistory: (() -> Void)?
    /// A narrowing over a PREFIX window needs the progressive scan's results (M-UI.11 P4).
    /// Fired on EVERY rebuild that needs them — the controller coalesces by comparing scan
    /// requests, so repeated fires while one scan serves the same inputs are free.
    @ObservationIgnored var onNeedsWindowScan: (() -> Void)?
    /// The page a blocked `goToPage` is waiting to land on (§5.3: the visible page holds until
    /// the rows exist — never a seam of misplaced rows). Applied by `appendHistoryPage`.
    /// Internal only for the mutation extension split — treat as private.
    @ObservationIgnored var pendingPage: Int?

    // MARK: - Progressive scan (M-UI.11 P4)

    /// What one scan's results were filtered by. Stamped onto `scanMatches` when the
    /// controller commits an update; the rebuild SHOWS those matches only while the stamp
    /// equals the current inputs — a rapid query replacement can therefore never render the
    /// previous query's rows, even for one frame (§8.1 stale-result rule).
    struct ScanContext: Equatable, Sendable {
        let query: String
        let category: PanelCategory
        let needsCounts: Bool
    }

    /// The narrowing inputs the CURRENT rebuild filters by. Query identity normalizes through
    /// `PanelSearch.normalize` — the ONE rule every stamp/request maker shares.
    var currentScanContext: ScanContext {
        ScanContext(query: PanelSearch.normalize(searchText),
                    category: category, needsCounts: showsFilterBar)
    }

    // Scan results live OUTSIDE the derived tier (plain storage, no didSet): only
    // `applyScanUpdate` writes them, batching its own rebuild. They are separate from
    // `historyRows` — the prefix survives underneath, so clearing the narrowing returns to it
    // without a re-fetch, and a 100k-row history never materializes wholesale (§12).
    @ObservationIgnored var scanMatches: [PanelRow] = []
    @ObservationIgnored var scanCounts: [PanelCategory: Int]?
    @ObservationIgnored var scanContext: ScanContext?
    /// Progress of the stamped scan: (processed, total) while scanning; nil once settled —
    /// complete, or failed (a failed scan presents its partial matches as-is, with no counts
    /// and no stuck progress; the controller refuses to re-run the same failed request).
    @ObservationIgnored var scanProgress: (processed: Int, total: Int)?

    /// Drop every scan artifact — results, counts, stamp, progress. Called when the narrowing
    /// clears (dead weight; masked-off plaintext), on a fresh open (`beginLoading` — a stale
    /// stamp must not render the previous open's results as settled: P4 review), and behind
    /// the screen lock (`purgeHistoryRows`, D4). ONE helper — the reset sites must never
    /// drift apart (a missed field is a D4 leak). Internal only for the mutation split.
    func clearScanResults() {
        scanMatches = []
        scanCounts = nil
        scanContext = nil
        scanProgress = nil
    }

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
        /// The progressive scan is filling this narrowing's results (M-UI.11 P4): partial
        /// matches ARE shown as they arrive, but no exact totals — the footer swaps its pager
        /// for progress, and the chip badges stay hidden (§3.1).
        var isScanningHistory = false
        /// (processed, total) for the footer's progress readout; nil once complete/failed.
        var scanProgress: (processed: Int, total: Int)?
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
        // A narrowing over a PREFIX window is served by the progressive scan (M-UI.11 P4):
        // matches stream in and are SHOWN as they arrive (window order — the first page
        // settles early and stays stable), but only matches stamped with the CURRENT inputs;
        // a query edit renders empty (+ scanning) until its own scan reports, never the
        // previous query's rows. Counts surface only when exact (§3.1). §4.6: snippet matches
        // join AFTER the history scan completes — the .all order (history first) never
        // reshuffles mid-scan. Callback last: it only pokes the controller's coalescer.
        if isNarrowingHistory && !historyWindowComplete {
            let fresh = scanContext == currentScanContext
            let complete = fresh && scanProgress == nil
            next.filteredRows = fresh ? scanMatches : []
            if complete {
                let snippetTail = scope == .all
                    ? PanelSearch.filterCombined(
                        PanelFilter.filter(snippetRows, category: category), query: searchText)
                    : []
                next.filteredRows += snippetTail
                if showsFilterBar {
                    // Snippets carry no content kind but ARE items: the All badge counts them,
                    // exactly as the complete-window path's PanelFilter.counts over scopedRows
                    // does (P4 review — the two paths must promise the same numbers).
                    var counts = scanCounts ?? [:]
                    counts[.all, default: 0] += snippetTail.count(where: \.isSelectable)
                    next.categoryCounts = counts
                }
            } else {
                next.isScanningHistory = true
                next.scanProgress = fresh ? scanProgress : nil
            }
            derived = next
            rebuildPageTier()
            onNeedsWindowScan?()
            return
        }
        // Narrowing cleared: drop the dead scan results now — with masking off they are
        // display plaintext, and the stamp already guarantees they could never render again.
        clearScanResults()
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
    /// materialized. Narrowed states page over what is actually loaded: scan matches ARE the
    /// result set (M-UI.11 P4 — the footer shows progress, not a final page count, while the
    /// scan runs), and the snippets scope filters rows that are always complete — either way
    /// the unfiltered total would page a narrowed list into phantom pages (P3 review).
    func effectiveRowCount(loaded: Int) -> Int {
        guard !historyWindowComplete else { return loaded }
        if isNarrowingHistory { return loaded }
        switch scope {
        case .history: return historyWindowTotal
        case .all: return historyWindowTotal + snippetRows.count
        case .snippets: return loaded
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

    /// The progressive scan is still filling the current narrowing's results (M-UI.11 P4):
    /// partial matches are on screen, no exact totals yet.
    var isScanningHistory: Bool { derived.isScanningHistory }
    /// The footer's progress readout while scanning; nil otherwise.
    var visibleScanProgress: (processed: Int, total: Int)? { derived.scanProgress }

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
        // Loading/scanning: the result set is not settled, so no empty state is truthful — the
        // list region shows its loading/scanning presentation rather than flashing "No
        // history" / "No results" that the next batch could contradict.
        guard !isLoadingFirstRows && !derived.isScanningHistory else { return .none }
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
        // A prefix window has no exact counts to offer: the chips render without badges (a
        // partial count posing as exact would break §3.1) until the scan reports exact ones.
        guard historyWindowComplete else { return [:] }
        let rows = classificationCache.resolve(scopedRows, policy: displayPolicy)
        return PanelFilter.counts(PanelSearch.filterCombined(rows, query: searchText))
    }

    /// True when a non-All category chip is narrowing the rows (drives the toggle's active tint and
    /// the filtered-empty state).
    var isCategoryFiltering: Bool { category != .all }

    /// A narrowing input is active over HISTORY rows — search, category chip, or the open chips
    /// row (whose counts need verdicts over everything); the snippets scope narrows only
    /// snippets, whose rows are always complete. THE one predicate behind "this state needs the
    /// complete window": the filtered tier runs the scan on it, `reconcilePrefix` refuses
    /// prefix commits under it, and the controller routes reconciles to a fresh scan by it —
    /// one truth, three consumers (P3 review: three hand-written copies drifted immediately).
    var isNarrowingHistory: Bool {
        (isSearching || isCategoryFiltering || showsFilterBar) && scope != .snippets
    }

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
