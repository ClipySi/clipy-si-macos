//
//  HistoryManagerStore.swift
//  ClipySi — Apple Silicon rewrite
//
//  M-UI.11 P5: the History Manager's state machine — the replacement for the view's 500-row
//  eager-decrypt window. Holds ONE page of display-ready rows (50 + nothing else decrypted),
//  pages the filtered/sorted live history by keyset cursor through the shared
//  `HistoryReadService`, and runs text search as a progressive scan over the whole live set.
//  A GRDB observation on the clips table drives reconciliation while the window is open
//  (HistoryManagerStore+Reads.swift), so delete/capture/pin land without the view owning a
//  `@FetchAll`.
//
//  Paging: `pageCursors[i]` is the cursor that produced page `i` (page 0 ⇒ nil). Next pushes
//  the continuation cursor; Previous re-fetches from the remembered position — cursors are
//  VALUES in the sort order, so they stay meaningful when rows are inserted or deleted between
//  moves (the P2 keyset property). While searching, pages are slices of the cumulative match
//  set instead, and the same footer controls drive `pageIndex`.
//
//  Guard rails (the P3/P4 lessons plus this phase's review):
//  - `loadGeneration` invalidates page commits; EVERY paging reset bumps it, so a pre-search
//    or pre-narrowing page read can never land on the new state.
//  - `scanGeneration` is the scan identity — an Int token, NOT the request value: restarting
//    with a value-equal request (revert typing, silent reconcile) must not let the replaced
//    task's epilogue clobber the live task's slot.
//  - `isActive` gates reconciliation: `teardown()` retires the store, so a straggler
//    reconcile Task scheduled before the window closed can never re-decrypt rows after it.
//  - Screen lock (D4): nothing decrypted survives behind the lock — rows and matches are
//    purged, reconciliation pauses, unlock rebuilds.
//

import Foundation
import Observation
import OSLog
import SQLiteData // re-exports swift-dependencies (@Dependency)

@MainActor
@Observable
final class HistoryManagerStore {
    /// Fixed manager page size (plan v2 §5.6) — independent of the panel's items-per-page.
    static let pageSize = 50

    // MARK: - Dependencies (all @ObservationIgnored — none is display state)

    @ObservationIgnored let readService: HistoryReadService
    /// The settings source `DisplayPolicy.current` resolves from — injectable so tests pin
    /// the mask policy against an isolated defaults suite.
    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored @Dependency(\.defaultDatabase) var database

    // MARK: - Table state (internal setters ONLY for the +Reads extension split)

    /// The current page of the (non-searching) table — the ONLY decrypted rows resident
    /// outside an active search.
    var pageRows: [HistoryClipRow] = []
    var pageIndex = 0
    /// Live rows matching the current metadata filter (the page-math denominator).
    var filteredCount = 0
    /// The last read failed AND there is nothing good to show (a failed read never wipes
    /// live rows — the P3 lesson).
    var loadFailed = false
    /// At least one read has committed since activation — gates the initial-loading overlay
    /// so a reopen never flashes "No History"/"No Results" while the first read runs.
    var hasLoaded = false
    var selection: Clip.ID?

    // MARK: - Facets

    /// Type display labels, sorted — the Type menu.
    var availableTypes: [String] = []
    /// Non-empty source bundles, sorted — the App menu.
    var availableApps: [String] = []
    /// One display label can cover several raw `primaryType` values — the SQL filter needs
    /// the raws back.
    @ObservationIgnored var typeRawsByLabel: [String: [String]] = [:]

    // MARK: - Query state (view-bound)

    var searchText = "" {
        didSet { searchTextChanged() }
    }
    var typeFilter: String? {
        didSet { if typeFilter != oldValue { narrowingChanged() } }
    }
    var appFilter: String? {
        didSet { if appFilter != oldValue { narrowingChanged() } }
    }
    private(set) var sort = ManagerSort.newestFirst

    // MARK: - Scan state

    var isScanning = false
    var scanProcessed = 0
    var scanTotal = 0
    var scanMatches: [HistoryClipRow] = []

    // MARK: - Internals (treat as private to the store's two files)

    @ObservationIgnored var pageCursors: [ManagerPageCursor?] = [nil]
    @ObservationIgnored var nextCursor: ManagerPageCursor?
    @ObservationIgnored var loadTask: Task<Void, Never>?
    @ObservationIgnored var loadGeneration = 0
    @ObservationIgnored var scanTask: Task<Void, Never>?
    @ObservationIgnored var scanDebounceTask: Task<Void, Never>?
    /// The live scan's identity token (see the header) — bumped on every restart/cancel.
    @ObservationIgnored var scanGeneration = 0
    /// The request identity used for keystroke coalescing (query equality), NOT for commit
    /// guarding — that's `scanGeneration`'s job.
    @ObservationIgnored var activeScanRequest: HistoryReadService.ManagerScanRequest?
    @ObservationIgnored var pendingScanQuery: String?
    @ObservationIgnored var reconcileRunning = false
    @ObservationIgnored var pendingReconcile = false
    @ObservationIgnored var lastPolicy: DisplayPolicy?
    /// True between `run()` start and `teardown()` — a reconcile scheduled before the window
    /// closed must no-op instead of re-decrypting rows into a closed window.
    @ObservationIgnored var isActive = false
    @ObservationIgnored var isScreenLocked = false
    /// Suppresses the query-state didSet cascades while `teardown()` resets the fields.
    @ObservationIgnored var isResetting = false
    /// Test hook: fired after every completed reconcile pass.
    @ObservationIgnored var onDidReconcile: (() -> Void)?

    static let log = Logger(subsystem: "io.github.ponponusa.clipysi", category: "history-manager")

    init(readService: HistoryReadService, settings: AppSettings = AppSettings()) {
        self.readService = readService
        self.settings = settings
    }

    // MARK: - Derived

    /// A (normalized) query is active — the table shows scan matches instead of page rows.
    var isSearching: Bool { !PanelSearch.normalize(searchText).isEmpty }

    var displayedRows: [HistoryClipRow] {
        guard isSearching else { return pageRows }
        let start = min(pageIndex * Self.pageSize, scanMatches.count)
        let end = min(start + Self.pageSize, scanMatches.count)
        return Array(scanMatches[start..<end])
    }

    /// What the footer's "N items" means right now: the filtered live count, or the (still
    /// growing) match count while searching.
    var displayedTotal: Int { isSearching ? scanMatches.count : filteredCount }

    var lastPageIndex: Int { max(0, displayedTotal - 1) / Self.pageSize }

    var canGoPrevious: Bool { pageIndex > 0 }

    var canGoNext: Bool {
        isSearching
            ? (pageIndex + 1) * Self.pageSize < scanMatches.count
            : nextCursor != nil
    }

    var isFilterActive: Bool { isSearching || typeFilter != nil || appFilter != nil }

    /// No live rows at all (facets are unfiltered, so an empty Type list ⇔ empty history) —
    /// drives the "No History" empty state and the Clear All/export enablement.
    var historyIsEmpty: Bool { availableTypes.isEmpty }

    var selectedRow: HistoryClipRow? {
        guard let selection else { return nil }
        return displayedRows.first { $0.id == selection }
    }

    // MARK: - User actions

    func goToNextPage() {
        if isSearching {
            guard canGoNext else { return }
            pageIndex += 1
            selection = nil
            return
        }
        guard let cursor = nextCursor, loadTask == nil else { return }
        moveToPage(pageIndex + 1, cursor: cursor)
    }

    func goToPreviousPage() {
        guard pageIndex > 0 else { return }
        if isSearching {
            pageIndex -= 1
            selection = nil
            return
        }
        // The bounds re-check matters: a reconcile's walk-back can shorten the remembered
        // cursor trail while the on-screen pageIndex still shows the old position.
        guard loadTask == nil, pageIndex - 1 < pageCursors.count else { return }
        moveToPage(pageIndex - 1, cursor: pageCursors[pageIndex - 1])
    }

    /// Map the SwiftUI `Table` sort selection onto the SQL push-down keys. While a SETTLED
    /// search is showing, the resident matches are simply re-sorted in memory — they carry
    /// the raw sort-key mirrors for exactly this, and a full re-decrypt walk would be waste.
    func apply(tableSort: [KeyPathComparator<HistoryClipRow>]) {
        guard let mapped = Self.managerSort(from: tableSort), mapped != sort else { return }
        sort = mapped
        if isSearching, scanTask == nil, !isScanning {
            scanMatches.sort(by: sort.areInOrder)
            pageIndex = 0
            selection = nil
            return
        }
        narrowingChanged()
    }

    func clearFilters() {
        // Each didSet no-ops when unchanged, so this triggers at most one rebuild per axis.
        searchText = ""
        typeFilter = nil
        appFilter = nil
    }

    /// Optimistic local removal for a delete issued FROM this window — the row disappears
    /// immediately instead of waiting out a full silent re-scan; the reconcile that follows
    /// the DB write converges the rest (counts, cursors, facets).
    func pruneRow(_ id: Clip.ID) {
        pageRows.removeAll { $0.id == id }
        scanMatches.removeAll { $0.id == id }
        if filteredCount > 0 { filteredCount -= 1 }
        if selection == id { selection = nil }
    }

    /// Optimistic local clear for the Clear All action.
    func pruneAllRows() {
        pageRows = []
        scanMatches = []
        scanProcessed = 0
        scanTotal = 0
        filteredCount = 0
        resetPaging()
    }

    static func managerSort(from comparators: [KeyPathComparator<HistoryClipRow>]) -> ManagerSort? {
        guard let first = comparators.first else { return nil }
        let ascending = first.order == .forward
        if first.keyPath == \HistoryClipRow.createdAt {
            return ManagerSort(key: .date, ascending: ascending)
        }
        if first.keyPath == \HistoryClipRow.sourceBundleDisplay {
            return ManagerSort(key: .app, ascending: ascending)
        }
        if first.keyPath == \HistoryClipRow.typeDisplay {
            return ManagerSort(key: .type, ascending: ascending)
        }
        if first.keyPath == \HistoryClipRow.pinnedDisplay {
            return ManagerSort(key: .pinned, ascending: ascending)
        }
        return nil
    }

    // MARK: - Request assembly (shared with +Reads)

    func currentRequest() -> HistoryReadService.ManagerRequest {
        let policy = DisplayPolicy.current(settings: settings)
        lastPolicy = policy
        return HistoryReadService.ManagerRequest(
            pageSize: Self.pageSize,
            filter: ManagerRowFilter(primaryTypes: typeFilter.flatMap { typeRawsByLabel[$0] },
                                     sourceBundle: appFilter),
            sort: sort,
            policy: policy)
    }

    /// Reset to page 0 AND invalidate any in-flight page read — every caller that resets
    /// paging is changing what a page means, so a pre-reset commit must never land.
    func resetPaging() {
        pageIndex = 0
        pageCursors = [nil]
        nextCursor = nil
        selection = nil
        loadTask?.cancel()
        loadTask = nil
        loadGeneration += 1
    }

    /// Cancel everything and drop every decrypted row AND the query state — the window
    /// closed (`run()` ended). The 500-row window kept its rows resident across closes; the
    /// store does not, and a stale query must not greet the next open with a silent scan.
    func teardown() {
        isActive = false
        purgeDecryptedState()
        isResetting = true
        searchText = ""
        typeFilter = nil
        appFilter = nil
        isResetting = false
        pendingReconcile = false
    }

    /// Drop decrypted rows and cancel all read work (teardown and screen lock — D4 — share
    /// this). Query/filter state is left to the caller.
    func purgeDecryptedState() {
        loadTask?.cancel()
        loadTask = nil
        scanDebounceTask?.cancel()
        scanDebounceTask = nil
        scanTask?.cancel()
        scanTask = nil
        scanGeneration += 1
        activeScanRequest = nil
        pendingScanQuery = nil
        isScanning = false
        scanMatches = []
        scanProcessed = 0
        scanTotal = 0
        pageRows = []
        hasLoaded = false
        resetPaging()
    }
}
