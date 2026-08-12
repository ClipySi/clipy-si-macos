//
//  HistoryPanelController+Reads.swift
//  ClipySi — Apple Silicon rewrite
//
//  The controller's paged-read surface (M-UI.11 P2/P3/P4), split from
//  HistoryPanelController.swift for the file/type length budget. Same type, same rules: every
//  read is generation-guarded (`cancelReads` is always followed by a generation bump), and the
//  members marked "internal only for the reads extension split" over there are effectively
//  private to these two files (plus the tests that await the task handles).
//

import AppKit

extension HistoryPanelController {
    func cancelReads() {
        openTask?.cancel()
        openTask = nil
        pageTask?.cancel()
        pageTask = nil
        scanTask?.cancel()
        scanTask = nil
        scanDebounceTask?.cancel()
        scanDebounceTask = nil
        reconcileTask?.cancel()
        reconcileTask = nil
    }

    /// The model parked a sequential page move on rows beyond the loaded prefix: fetch the next
    /// keyset page and append. One fetch at a time — `goToPage` re-fires after each append if
    /// the user is still ahead of the prefix. Cancellation is generation-based: `cancelReads`
    /// is always followed by a generation bump, so a stale task simply never commits (and never
    /// touches the controller's task/cursor state — it might already belong to a newer open).
    func loadNextHistoryPage() {
        // Mutual exclusion with an in-flight reconcile (P3): it is about to REPLACE the prefix
        // this append would extend — the reconcile's own goToPage re-parks and re-fires if
        // still needed. (A running scan never parks a page move — narrowed states page over
        // the matches they already hold.)
        guard pageTask == nil, reconcileTask == nil,
              let request = pageRequest, let cursor = windowCursor else { return }
        let generation = readGeneration
        let loaded = model.historyRows.count
        pageTask = Task { [weak self] in
            guard let self else { return }
            let result = await readService.nextPage(after: cursor, loadedCount: loaded, request)
            guard generation == readGeneration else { return }
            pageTask = nil
            // The window can have been completed in the same generation while this page was in
            // flight — the append is then moot and the cursor stays retired; a resurrected
            // cursor would break the prefix invariant (review).
            guard !model.historyWindowComplete else { return }
            windowCursor = result.nextCursor
            model.appendHistoryPage(result.rows, windowComplete: result.nextCursor == nil)
        }
    }

    // MARK: - Progressive scan (M-UI.11 P4)

    /// The model needs scan results for its current narrowing (fired on every rebuild of that
    /// state). Coalesced by request: one scan — running or settled, including failed (which
    /// must not loop) — serves each distinct (query, category, counts, page-contract) tuple.
    /// A model that no longer holds current-stamp results (e.g. the narrowing was cleared and
    /// re-entered) re-runs even an identical request. QUERY edits debounce (D5: keystrokes
    /// must not each cancel and restart a full decrypt walk); every other narrowing change —
    /// first entry, chips, category — scans immediately.
    func startScanIfNeeded() {
        guard let request = pageRequest else { return }
        let desired = desiredScanRequest(request)
        let fresh = model.scanContext == model.currentScanContext
        if desired == scanRequest && (scanTask != nil || fresh) { return }
        if let current = scanRequest, current.query != desired.query,
           current.category == desired.category, current.needsCounts == desired.needsCounts,
           current.base == desired.base {
            scheduleDebouncedScan()
            return
        }
        scanDebounceTask?.cancel()
        scanDebounceTask = nil
        restartScan(desired, silent: false)
    }

    /// The query changed: coalesce the burst, then re-derive and start ONE scan for wherever
    /// the query settled (D5: 80–120 ms; 100 ms). Everything is re-checked at fire time — the
    /// narrowing may have cleared or the panel hidden while the debounce ran.
    private func scheduleDebouncedScan() {
        scanDebounceTask?.cancel()
        scanDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self, !Task.isCancelled else { return }
            scanDebounceTask = nil
            guard isVisible, let request = pageRequest,
                  model.isNarrowingHistory, !model.historyWindowComplete else { return }
            let desired = desiredScanRequest(request)
            let fresh = model.scanContext == model.currentScanContext
            guard !(desired == scanRequest && (scanTask != nil || fresh)) else { return }
            restartScan(desired, silent: false)
        }
    }

    /// The scan request for the model's CURRENT narrowing. The query is normalized here —
    /// request equality is the coalescing identity, and "note " must equal "note" everywhere
    /// (P4 review: an untrimmed request re-walked the whole window per whitespace keystroke).
    func desiredScanRequest(_ request: HistoryReadService.PageRequest) -> HistoryReadService.ScanRequest {
        HistoryReadService.ScanRequest(base: request,
                                       query: PanelSearch.normalize(model.searchText),
                                       category: model.category,
                                       needsCounts: model.showsFilterBar)
    }

    /// Replace the running walk (if any) with a fresh one. `silent` is the reconcile mode: the
    /// rows on screen stay up untouched until the fresh COMPLETE set lands — intermediate
    /// updates are never even produced (`finalOnly`), and a failure keeps the old rows (the
    /// P3 failed-read rule) but SETTLES a still-scanning display so its progress can't freeze
    /// with no retry path (P4 review). A user-facing scan streams every update; a failure
    /// presents the partial matches as settled.
    func restartScan(_ request: HistoryReadService.ScanRequest, silent: Bool) {
        scanTask?.cancel()
        scanGeneration &+= 1
        let thisScan = scanGeneration
        scanRequest = request
        let generation = readGeneration
        let context = HistoryPanelModel.ScanContext(
            query: request.query, // already normalized (desiredScanRequest)
            category: request.category,
            needsCounts: request.needsCounts)
        scanTask = Task { [weak self] in
            guard let self else { return }
            for await update in readService.scanWindow(request, finalOnly: silent) {
                guard generation == readGeneration, thisScan == scanGeneration else { return }
                if silent && update.failed {
                    model.settleScanAsFailed()
                    break
                }
                // The narrowing was cleared under the walk: nothing stale can render (the
                // stamp guards that) — stopping just ends the wasted decrypt work.
                guard model.applyScanUpdate(update, context: context) else { break }
            }
            guard thisScan == scanGeneration else { return }
            scanTask = nil
        }
    }

    // MARK: - Reconcile (M-UI.11 P3)

    /// The head observation saw a write land (§5.5) — bring an OPEN panel back in line with
    /// the DB. Hidden panels need nothing: the warm cache is already updated, and the next
    /// show serves it.
    func reconcileFromObservation() {
        guard isVisible else { return }
        scheduleReconcile()
    }

    /// One reconcile pass over the current open: generation-bump so every in-flight read of
    /// the pre-write state dies uncommitted, then re-read what the CURRENT view state needs —
    /// a fresh silent scan while a narrowing runs over a prefix window, the loaded prefix (or
    /// the complete window, same read) otherwise. Both commits re-serve the same visual state
    /// (page, selection) from fresh data; deleted rows drop out, so nothing stale stays
    /// selectable (the P3 exit rule). Internal (not private) for the split: the warm open's
    /// background verification and the cold open's deferred pass enter here too.
    func scheduleReconcile() {
        guard isVisible, let request = pageRequest else { return }
        // The open's first read is still in flight; its commit runs one deferred pass (the
        // in-flight read may or may not include the write this reconcile is answering).
        if model.isLoadingFirstRows {
            pendingReconcile = true
            return
        }
        pendingReconcile = false
        cancelReads()
        readGeneration &+= 1
        let generation = readGeneration
        if model.isNarrowingHistory && !model.historyWindowComplete {
            // The scan owns this state: re-run it silently — the matches on screen stand
            // until the fresh complete set replaces them in one commit. The prefix UNDER the
            // narrowing refreshes in parallel (P4 review): it must track deletions too, or
            // clearing the search would resurface rows that no longer exist.
            restartScan(desiredScanRequest(request), silent: true)
            let rowCount = max(model.historyRows.count, request.pageSize)
            reconcileTask = Task { [weak self] in
                guard let self else { return }
                let result = await readService.openPrefix(rowCount: rowCount, request)
                guard generation == readGeneration else { return }
                reconcileTask = nil
                guard !result.failed else { return }
                windowCursor = result.nextCursor
                model.refreshPrefixUnderNarrowing(result.rows, totalCount: result.totalCount,
                                                  windowComplete: result.nextCursor == nil)
            }
        } else {
            let rowCount = max(model.historyRows.count, request.pageSize)
            reconcileTask = Task { [weak self] in
                guard let self else { return }
                let result = await readService.openPrefix(rowCount: rowCount, request)
                guard generation == readGeneration else { return }
                reconcileTask = nil
                // A failed read must not pose as an empty history: the whole point of this
                // commit is replacing LIVE rows, so there is good state to lose (unlike the
                // cold open's degrade-to-empty). Skip; the next observation fire retries.
                guard !result.failed else { return }
                // A prefix-window narrowing began while this read was in flight: the scan owns
                // that commit now (the model's reconcilePrefix guards the same state; defense
                // in depth).
                guard scanTask == nil else { return }
                windowCursor = result.nextCursor
                model.reconcilePrefix(result.rows, totalCount: result.totalCount,
                                      windowComplete: result.nextCursor == nil)
            }
        }
    }
}
