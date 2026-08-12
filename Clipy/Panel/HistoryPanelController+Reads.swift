//
//  HistoryPanelController+Reads.swift
//  ClipySi — Apple Silicon rewrite
//
//  The controller's paged-read surface (M-UI.11 P2/P3), split from
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
        hydrationTask?.cancel()
        hydrationTask = nil
        reconcileTask?.cancel()
        reconcileTask = nil
    }

    /// The model parked a sequential page move on rows beyond the loaded prefix: fetch the next
    /// keyset page and append. One fetch at a time — `goToPage` re-fires after each append if
    /// the user is still ahead of the prefix. Cancellation is generation-based: `cancelReads`
    /// is always followed by a generation bump, so a stale task simply never commits (and never
    /// touches the controller's task/cursor state — it might already belong to a newer open).
    func loadNextHistoryPage() {
        // Mutual exclusion with hydration: a page fetched while the full window is being read
        // would land AFTER completeWindow and try to append onto a finished window (review).
        // Same for an in-flight reconcile (P3): it is about to REPLACE the prefix this append
        // would extend — the reconcile's own goToPage re-parks and re-fires if still needed.
        guard pageTask == nil, hydrationTask == nil, reconcileTask == nil,
              let request = pageRequest, let cursor = windowCursor else { return }
        let generation = readGeneration
        let loaded = model.historyRows.count
        pageTask = Task { [weak self] in
            guard let self else { return }
            let result = await readService.nextPage(after: cursor, loadedCount: loaded, request)
            guard generation == readGeneration else { return }
            pageTask = nil
            // Hydration can still have completed the window in the same generation while this
            // page was in flight — the append is then moot and the cursor stays retired; a
            // resurrected cursor would break the prefix invariant (review).
            guard !model.historyWindowComplete else { return }
            windowCursor = result.nextCursor
            model.appendHistoryPage(result.rows, windowComplete: result.nextCursor == nil)
        }
    }

    /// A narrowing input (search / category / chips) needs the COMPLETE capped window — the P2
    /// interim path (P4: progressive scan). The model may re-fire while the need persists; the
    /// in-flight task coalesces those. Off-main, generation-guarded like every read.
    ///
    /// A FAILED read still commits here (P2's degrade-to-empty: "no results"): there is no
    /// good window to preserve, and skipping would leave the hydration spinner up forever
    /// (the model re-requests only on input changes).
    func hydrateWindow() {
        guard hydrationTask == nil, let request = pageRequest else { return }
        startHydration(request, generation: readGeneration, discardFailure: false)
    }

    /// The one hydration runner (initial + reconcile — P3 review folded the duplicate).
    /// `discardFailure`: the reconcile path must NOT replace live rows with a failed read's
    /// empty result (a transient DB error would blank the open panel as a false "no history");
    /// the initial hydration keeps P2's commit-anyway contract — see `hydrateWindow`.
    private func startHydration(_ request: HistoryReadService.PageRequest, generation: UInt64,
                                discardFailure: Bool) {
        hydrationTask = Task { [weak self] in
            guard let self else { return }
            let result = await readService.fullWindow(request)
            guard generation == readGeneration else { return }
            hydrationTask = nil
            guard !(discardFailure && result.failed) else { return }
            windowCursor = nil
            model.completeWindow(result.rows, totalCount: result.totalCount)
        }
    }

    /// The head observation saw a write land (M-UI.11 P3 §5.5) — bring an OPEN panel back in
    /// line with the DB. Hidden panels need nothing: the warm cache is already updated, and the
    /// next show serves it.
    func reconcileFromObservation() {
        guard isVisible else { return }
        scheduleReconcile()
    }

    /// One reconcile pass over the current open (P3): generation-bump so every in-flight read
    /// of the pre-write state dies uncommitted, then re-read what the CURRENT view state needs —
    /// the full window while a narrowing is active (its filtered rows must be recomputed over
    /// complete data), the loaded prefix otherwise. Both commits re-serve the same visual state
    /// (page, selection) from fresh data; deleted rows drop out, so nothing stale stays
    /// selectable (the P3 exit rule).
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
        if model.isNarrowingHistory {
            // Re-hydrate silently: `completeWindow` swaps the rows under the active
            // search/category state without the blank/ProgressView flash of a first hydration.
            // discardFailure: a failed re-read must keep the rows the user is looking at.
            startHydration(request, generation: generation, discardFailure: true)
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
                // A narrowing began while this prefix was in flight: the hydration owns the
                // next commit — a prefix without that context must not replace its window
                // (the model's reconcilePrefix guards the same states; defense in depth).
                guard hydrationTask == nil else { return }
                windowCursor = result.nextCursor
                model.reconcilePrefix(result.rows, totalCount: result.totalCount,
                                      windowComplete: result.nextCursor == nil)
            }
        }
    }
}
