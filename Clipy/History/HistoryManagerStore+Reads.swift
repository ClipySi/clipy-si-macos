//
//  HistoryManagerStore+Reads.swift
//  ClipySi — Apple Silicon rewrite
//
//  M-UI.11 P5: the store's read/observe half — the observation loop `run()` (whose initial
//  yield IS the initial load), page reloads, the search-scan lifecycle, and reconciliation.
//
//  Reconcile discipline (the P3/P4 lessons, manager edition):
//  - A reconcile never runs concurrently with itself, a page load, a scan, OR a pending
//    search debounce — it defers (`pendingReconcile`) and drains when the in-flight work
//    settles. Deferring behind the debounce matters: a silent restart racing the user's
//    pending restart would swallow it (review: a frozen `isScanning` with no re-run path).
//  - A failed read/scan never wipes live rows; a failed SILENT scan re-arms a delayed retry
//    so the write that triggered it is eventually reflected.
//  - While searching, a write triggers a silent (`finalOnly`) re-scan ONLY when settled
//    matches are on screen to preserve; an empty board scans visibly (progress, not a
//    silent "no results" lie — the reopen/unlock case).
//  - Commits are guarded by `loadGeneration` (page path) or `scanGeneration` (scan path);
//    anything that changes what should be visible bumps them.
//
//  The observation watches the clips TABLE as a region — not a value fetch — because manager
//  columns that no other observed value covers (`isPinned`) must fire too. Bursts conflate:
//  the stream buffers only the newest element and a short pause precedes every non-initial
//  reconcile, so an import of 1,000 rows costs a couple of reconciles, not 1,000 (review:
//  the unbounded default replays every commit).
//

import Foundation
import GRDB // explicit product link: ValueObservation/Table are not re-exported by SQLiteData
import SQLiteData

extension HistoryManagerStore {
    /// The window's lifetime loop — run from the view's `.task`, cancelled when the window
    /// closes. Subscribes to defaults changes (mask policy) and the screen-lock pair (D4),
    /// then observes the clips table; the observation's initial yield performs the initial
    /// load.
    func run() async {
        isActive = true
        let defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleDefaultsChange() }
        }
        let distributed = DistributedNotificationCenter.default()
        let lockObserver = distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleScreenLock() }
        }
        let unlockObserver = distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleScreenUnlock() }
        }
        defer {
            NotificationCenter.default.removeObserver(defaultsObserver)
            distributed.removeObserver(lockObserver)
            distributed.removeObserver(unlockObserver)
            teardown()
        }
        let observation = ValueObservation.tracking(region: GRDB.Table("clips")) { _ in }
        var isInitialYield = true
        while !Task.isCancelled {
            do {
                for try await _ in observation.values(in: database,
                                                      bufferingPolicy: .bufferingNewest(1)) {
                    guard !Task.isCancelled else { return }
                    if isInitialYield {
                        isInitialYield = false
                    } else {
                        // Conflate write bursts: later commits coalesce into the single
                        // buffered element while we pause, so sustained writes cost one
                        // bounded reconcile per window, not one per commit.
                        try? await Task.sleep(for: .milliseconds(200))
                        guard !Task.isCancelled else { return }
                    }
                    await reconcile()
                }
                return
            } catch {
                guard !Task.isCancelled else { return }
                // A dead observation can't keep the table honest — surface the error state
                // only if there's nothing good on screen, then retry (the P3 observer rule:
                // dying for good would end reconciliation for the window's lifetime).
                Self.log.error("manager observation failed: \(error.localizedDescription, privacy: .public)")
                loadFailed = pageRows.isEmpty && scanMatches.isEmpty
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    // MARK: - Screen lock (D4)

    /// Nothing decrypted survives behind the lock: purge rows/matches, pause reconciliation.
    /// Query and filter state stay — unlock rebuilds the same view. Internal so tests drive
    /// the transition directly.
    func handleScreenLock() {
        isScreenLocked = true
        purgeDecryptedState()
    }

    func handleScreenUnlock() {
        isScreenLocked = false
        scheduleReconcile()
    }

    // MARK: - Reconcile

    func reconcile() async {
        guard isActive, !isScreenLocked else { return }
        if reconcileRunning || scanTask != nil || loadTask != nil || scanDebounceTask != nil {
            pendingReconcile = true
            return
        }
        reconcileRunning = true
        defer {
            reconcileRunning = false
            onDidReconcile?()
        }
        if isSearching {
            // Silent only when there are settled matches to keep on screen; an empty board
            // (reopen, unlock, first pass) scans visibly instead of hiding behind finalOnly.
            restartScan(silent: !scanMatches.isEmpty)
            await refreshFacetsAndCount()
        } else {
            await reloadCurrentPage(generation: bumpGeneration(), includeFacets: true)
        }
        drainPendingReconcile()
    }

    func scheduleReconcile() {
        Task { await self.reconcile() }
    }

    func drainPendingReconcile() {
        if pendingReconcile {
            pendingReconcile = false
            scheduleReconcile()
        }
    }

    /// Any defaults write lands here — only a display-policy change matters. Everything
    /// on screen was built under the OLD policy, so this restarts visibly (progress) and
    /// never silently keeps stale masked/unmasked rows up (review). Internal so tests drive
    /// the guard deterministically (the notification itself is environment-dependent under
    /// the sandboxed test host).
    func handleDefaultsChange() {
        guard isActive, DisplayPolicy.current(settings: settings) != lastPolicy else { return }
        if isSearching {
            restartScan(silent: false)
            scheduleLoad() // the page rows behind the search are stale under the new policy too
        } else {
            scheduleReconcile()
        }
    }

    // MARK: - Page loads

    func bumpGeneration() -> Int {
        loadGeneration += 1
        return loadGeneration
    }

    /// Narrowing (filter/sort) or search-exit changed what page 0 means: reset and reload, or
    /// hand off to the scan when a query is active.
    func narrowingChanged() {
        guard !isResetting else { return }
        resetPaging()
        if isSearching {
            restartScan(silent: false)
        } else {
            scheduleLoad()
        }
    }

    func scheduleLoad() {
        let generation = bumpGeneration()
        // Facets only on the FIRST load — they are unfiltered, so a narrowing/search-exit
        // reload can't change them, and reconciles refresh them anyway (review: two DISTINCT
        // full-table scans were riding every reload).
        let includeFacets = availableTypes.isEmpty
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            await self?.reloadCurrentPage(generation: generation, includeFacets: includeFacets)
            guard let self, self.loadGeneration == generation else { return }
            self.loadTask = nil
            self.drainPendingReconcile()
        }
    }

    /// Re-serve the current page from current data — the open/reconcile/narrowing read. Walks
    /// back toward page 0 when the remembered position no longer yields rows (trailing pages
    /// deleted). Counts and facets ride the same transaction as the rows. The cursor trail is
    /// mutated LOCALLY and committed with the rows — the shared `pageCursors` must never
    /// shrink under a user click mid-walk (review: an index crash on Previous).
    func reloadCurrentPage(generation: Int, includeFacets: Bool) async {
        var cursors = pageCursors
        var index = min(pageIndex, cursors.count - 1)
        let request = currentRequest()
        let options: ManagerReadOptions = includeFacets ? [.count, .facets] : [.count]
        while !Task.isCancelled {
            let result = await readService.managerPage(after: cursors[index], options: options, request)
            guard loadGeneration == generation else { return }
            if result.failed {
                loadFailed = pageRows.isEmpty
                return
            }
            loadFailed = false
            if result.rows.isEmpty, index > 0 {
                index -= 1
                cursors.removeLast()
                continue
            }
            pageRows = result.rows
            hasLoaded = true
            pageIndex = index
            pageCursors = Array(cursors.prefix(index + 1))
            nextCursor = result.nextCursor
            filteredCount = result.filteredCount ?? filteredCount
            // Facets LAST: clearing a vanished Type/App selection cascades into a fresh
            // narrowing reload, and that load must supersede this commit, not race it.
            if let facets = result.facets { commitFacets(facets) }
            return
        }
    }

    /// One sequential page move (Next/Previous). No count/facet read — the store keeps its
    /// committed totals; reconciliation refreshes them on the next write.
    func moveToPage(_ targetIndex: Int, cursor: ManagerPageCursor?) {
        selection = nil
        let generation = bumpGeneration()
        let request = currentRequest()
        loadTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.readService.managerPage(after: cursor, options: [], request)
            guard self.loadGeneration == generation else { return }
            self.commitPageMove(result, cursor: cursor, targetIndex: targetIndex)
            self.loadTask = nil
            self.drainPendingReconcile()
        }
    }

    private func commitPageMove(_ result: HistoryReadService.ManagerPageResult,
                                cursor: ManagerPageCursor?, targetIndex: Int) {
        guard !result.failed else { return } // stay on the current page
        if result.rows.isEmpty {
            // Raced a delete: the target page no longer exists. Forward: there is no next
            // page after all. Backward to an empty history: the reconcile that follows the
            // delete rebuilds page 0.
            if targetIndex > pageIndex { nextCursor = nil }
            return
        }
        pageRows = result.rows
        pageIndex = targetIndex
        pageCursors = Array(pageCursors.prefix(targetIndex))
        pageCursors.append(cursor)
        nextCursor = result.nextCursor
    }

    /// Rows-free facet + count refresh (search-mode reconcile): a zero-size page carries the
    /// aggregates without decrypting anything.
    private func refreshFacetsAndCount() async {
        let base = currentRequest()
        let request = HistoryReadService.ManagerRequest(pageSize: 0, filter: base.filter,
                                                        sort: base.sort, policy: base.policy)
        let result = await readService.managerPage(after: nil, options: [.count, .facets], request)
        guard !result.failed else { return }
        filteredCount = result.filteredCount ?? filteredCount
        if let facets = result.facets { commitFacets(facets) }
    }

    func commitFacets(_ facets: HistoryReadService.ManagerFacets) {
        var byLabel: [String: [String]] = [:]
        for raw in facets.typeRawValues {
            byLabel[HistoryClipRow.typeDisplay(for: raw), default: []].append(raw)
        }
        typeRawsByLabel = byLabel
        availableTypes = byLabel.keys.sorted()
        availableApps = facets.apps.filter { !$0.isEmpty }.sorted()
        // A selection whose facet vanished falls back to "all" — the didSet reload supersedes
        // whatever commit is in progress (facets are committed last for exactly this reason).
        if let type = typeFilter, !availableTypes.contains(type) { typeFilter = nil }
        if let app = appFilter, !availableApps.contains(app) { appFilter = nil }
    }

    // MARK: - Search scan

    func searchTextChanged() {
        guard !isResetting else { return }
        let term = PanelSearch.normalize(searchText)
        if term.isEmpty {
            scanDebounceTask?.cancel()
            scanDebounceTask = nil
            pendingScanQuery = nil
            guard activeScanRequest != nil || !scanMatches.isEmpty else {
                // A stray keystroke armed only the debounce — no scan ever ran. Keep the
                // page, the selection, and the loaded state untouched.
                isScanning = false
                drainPendingReconcile()
                return
            }
            cancelScan()
            resetPaging()
            scheduleLoad()
            return
        }
        // Whitespace edits normalize to the pending/active query — never a restart (P4).
        guard term != (pendingScanQuery ?? activeScanRequest?.query) else { return }
        if pendingScanQuery != nil, term == activeScanRequest?.query {
            // The edits netted back to the active scan ("foo" → "foob" → "foo"): drop the
            // pending restart and keep the scan/results that already exist.
            scanDebounceTask?.cancel()
            scanDebounceTask = nil
            pendingScanQuery = nil
            if scanTask == nil { isScanning = false }
            drainPendingReconcile()
            return
        }
        pendingScanQuery = term
        isScanning = true // the view shows progress from the first keystroke, not post-debounce
        scanDebounceTask?.cancel()
        scanDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100)) // D5 query debounce
            guard !Task.isCancelled, let self else { return }
            self.scanDebounceTask = nil
            self.pendingScanQuery = nil
            self.restartScan(silent: false)
        }
    }

    /// Start (or restart) the scan under the CURRENT request. `silent` is the reconcile mode:
    /// the visible settled matches stay up until the fresh settled set lands; a user-facing
    /// restart clears the board and shows progress. A SILENT restart never touches the
    /// pending debounce — the user's restart must win.
    func restartScan(silent: Bool) {
        let term = PanelSearch.normalize(searchText)
        guard !term.isEmpty else { return }
        if !silent {
            scanDebounceTask?.cancel()
            scanDebounceTask = nil
        }
        scanTask?.cancel()
        scanGeneration += 1
        let generation = scanGeneration
        let request = HistoryReadService.ManagerScanRequest(base: currentRequest(), query: term)
        activeScanRequest = request
        if !silent {
            isScanning = true
            scanMatches = []
            scanProcessed = 0
            scanTotal = 0
            resetPaging()
        }
        scanTask = Task { [weak self] in
            guard let self else { return }
            for await update in self.readService.managerScan(request, finalOnly: silent) {
                guard !Task.isCancelled, self.scanGeneration == generation else { break }
                self.applyScan(update, silent: silent)
                if update.isSettled {
                    if silent, update.failed { self.scheduleScanRetry(generation) }
                    break
                }
            }
            // The token (not the request value) owns the slot: a cancelled task whose
            // request happens to EQUAL the replacement's must not clear the live handle.
            guard self.scanGeneration == generation else { return }
            self.scanTask = nil
            self.drainPendingReconcile()
        }
    }

    private func applyScan(_ update: HistoryReadService.ManagerScanUpdate, silent: Bool) {
        if silent {
            // finalOnly yields exactly one settled update; a failed silent pass never wipes
            // the good matches on screen (the retry is armed by the caller).
            guard update.isSettled, !update.failed else { return }
            scanMatches = update.matches
            scanProcessed = update.processed
            scanTotal = update.total
            hasLoaded = true
            isScanning = false // stale-progress hygiene: settled content is on screen now
            pageIndex = min(pageIndex, lastPageIndex)
            return
        }
        scanMatches = update.matches
        scanProcessed = update.processed
        scanTotal = update.total
        hasLoaded = true
        // Settling covers failure too: partial matches stay up and the progress UI stops —
        // a frozen bar with no re-run path is the P4 silent-fail lesson.
        if update.isSettled { isScanning = false }
    }

    /// A failed SILENT re-scan means the triggering write is not yet reflected — re-arm one
    /// delayed retry (the observation-retry cadence) unless a newer scan took over.
    private func scheduleScanRetry(_ generation: Int) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, self.isActive, !self.isScreenLocked,
                  self.scanGeneration == generation, self.isSearching else { return }
            self.scheduleReconcile()
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        scanGeneration += 1
        activeScanRequest = nil
        isScanning = false
        scanMatches = []
        scanProcessed = 0
        scanTotal = 0
    }
}
