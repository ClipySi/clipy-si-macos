//
//  HistoryPanelModel+Mutations.swift
//  ClipySi — Apple Silicon rewrite
//
//  The model's mutation surface (open commits, paged-window bookkeeping, scope/category/query
//  re-bases, selection/paging moves), split from HistoryPanelModel.swift for the file/type
//  length budget. Same type, same rules: every multi-field mutation batches through
//  `withBatchedInputs` (one rebuild per user action), and members marked "internal only for
//  the mutation extension split" over there are effectively private to these two files.
//

import Foundation

extension HistoryPanelModel {
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
            isLoadingFirstRows = false
            historyWindowComplete = true
            historyWindowTotal = historyRows.count
            self.historyRows = historyRows
            self.snippetRows = snippetRows
            self.scope = (requestedScope == .snippets && snippetRows.isEmpty) ? .all : requestedScope
            searchText = ""
            category = .all
            isFilterBarOpen = false
            currentPage = 0
        }
        pendingPage = nil
        selection = firstSelectableVisibleID
        isManagementOpen = false
        openToken &+= 1
    }

    /// Start a fresh open in the loading-shell state (M-UI.11 P2 show-first): snippets are known
    /// (bounded sync fetch), history is in flight on the read service. Clears the previous
    /// open's rows so nothing stale is ever selectable, swapping the policy atomically with that
    /// clear (the P1 cache-poisoning rule). The list renders EMPTY — no selection, no numbers,
    /// no paste — until `commitFirstPage`.
    func beginLoading(snippetRows: [PanelRow], scope requestedScope: Scope = .all,
                      policy: DisplayPolicy? = nil) {
        withBatchedInputs {
            if let policy { displayPolicy = policy }
            isLoadingFirstRows = true
            historyWindowComplete = false
            historyWindowTotal = 0
            historyRows = []
            // A stale stamp would let this open's identical query render the PREVIOUS open's
            // matches as settled results (the loading-shell rebuild skips the narrowing-cleared
            // sweep) — P4 review.
            clearScanResults()
            self.snippetRows = snippetRows
            scope = (requestedScope == .snippets && snippetRows.isEmpty) ? .all : requestedScope
            searchText = ""
            category = .all
            isFilterBarOpen = false
            currentPage = 0
        }
        pendingPage = nil
        // nil for the (blank) history-bearing scopes; the snippets scope is live through the
        // shell, so its top row highlights immediately (review).
        selection = firstSelectableVisibleID
        isManagementOpen = false
        openToken &+= 1
    }

    /// Commit the open's first history page in ONE snapshot: rows, window totals, selection,
    /// numbering, and page state all settle together (§5.2 — Return/digits act on a confirmed
    /// set or not at all). `windowComplete` is true when the walk already exhausted the capped
    /// window (small histories).
    func commitFirstPage(historyRows: [PanelRow], totalCount: Int, windowComplete: Bool) {
        let previousSelection = selection
        withBatchedInputs {
            isLoadingFirstRows = false
            self.historyRows = historyRows
            historyWindowTotal = max(totalCount, historyRows.count)
            historyWindowComplete = windowComplete
        }
        // The snippets scope was live through the shell — a selection the user already moved
        // survives the commit; everything else lands on the page top (one confirmed snapshot).
        selection = survivingSelection(previousSelection) ?? firstSelectableVisibleID
    }

    /// `candidate` when it still resolves to a selectable row on the current visible page —
    /// the "don't stomp the user's highlight" rule for async commits (review).
    private func survivingSelection(_ candidate: RowID?) -> RowID? {
        guard let candidate,
              derived.visibleRows.contains(where: { $0.id == candidate && $0.isSelectable }) else {
            return nil
        }
        return candidate
    }

    /// Append the next sequential page (the `onNeedsMoreHistory` reply), then complete any
    /// navigation parked on `pendingPage` (§5.3 — the visible page held until its rows existed).
    func appendHistoryPage(_ rows: [PanelRow], windowComplete: Bool) {
        // A late append must never land on a completed window: another commit can finish the
        // window while a page fetch is in flight, and appending on top would duplicate rows
        // and flip the window back to prefix bookkeeping (review). The controller guards too —
        // this is defense in depth.
        guard !historyWindowComplete else {
            pendingPage = nil
            return
        }
        // Keyset pages walk LIVE data by cursor VALUES: a row whose createdAt was rewritten
        // mid-walk (dedupe re-copy, paste move-to-top) can re-enter a later page. Dropping ids
        // the prefix already holds keeps the window duplicate-free (P2 exit: no duplication
        // under mutation races); the moved row keeps its original slot until the next open.
        let known = Set(historyRows.map(\.id))
        let fresh = rows.filter { !known.contains($0.id) }
        withBatchedInputs {
            historyRows.append(contentsOf: fresh)
            historyWindowTotal = max(historyWindowTotal, historyRows.count)
            historyWindowComplete = windowComplete
        }
        if let page = pendingPage {
            pendingPage = nil
            // A narrowing began while this fetch was in flight (⌘F leaves no other clear
            // point): the parked move belongs to the UN-narrowed context — completing it now
            // would jump the narrowed match list and re-seat the selection (P4 review).
            if !isNarrowingHistory { goToPage(page) }
        }
    }

    /// Apply one progressive-scan update (M-UI.11 P4; the controller's generation-guarded
    /// commit). Returns `false` when the update no longer has a narrowing to serve — the
    /// controller cancels the walk (the stamp already guarantees nothing stale renders; the
    /// refusal just stops wasted decrypt work). One rebuild per update; the cumulative match
    /// set arrives in window order, so the visible first page settles with the earliest
    /// batches and later updates only ever extend the tail. A FAILED update settles with what
    /// it has — partial matches, no counts, no stuck progress.
    @discardableResult
    func applyScanUpdate(_ update: HistoryReadService.ScanUpdate, context: ScanContext) -> Bool {
        guard isNarrowingHistory, !historyWindowComplete, !isLoadingFirstRows else { return false }
        let previousSelection = selection
        withBatchedInputs {
            scanMatches = update.matches
            scanCounts = update.failed ? nil : update.counts
            scanContext = context
            scanProgress = update.isSettled ? nil : (update.processed, update.total)
            // The scan's first read carries the window total from its own transaction — the
            // scope-tab badge tracks the DB even while the narrowing hides the prefix. Taken
            // verbatim (no max() with the prefix length — P4 review): a shrunken window's
            // smaller truth must not be hidden by a stale larger prefix, which the reconcile's
            // parallel prefix refresh re-bases anyway. A failed update carries no trustworthy
            // total.
            if !update.failed { historyWindowTotal = update.total }
        }
        // First results claim the top row; later updates keep whatever the user moved to.
        selection = survivingSelection(previousSelection) ?? firstSelectableVisibleID
        return true
    }

    /// The silent re-scan died with the on-screen results still UNSETTLED (a mid-stream scan
    /// was cancelled for it, then the re-read failed): keep what's shown, stop advertising
    /// progress — a frozen progress bar with no retry path is the alternative (P4 review).
    /// The next narrowing edit or head change re-scans.
    func settleScanAsFailed() {
        guard scanProgress != nil else { return }
        withBatchedInputs {
            scanProgress = nil
        }
    }

    /// Refresh the loaded prefix UNDERNEATH a displayed narrowing (M-UI.11 P4 review): the
    /// scan owns the visible result set, but the prefix must track deletions too — otherwise
    /// clearing the search would resurface rows that no longer exist (the P3 exit rule; P2's
    /// whole-window swap used to cover this). The visible matches, page, and selection are
    /// untouched — the narrowing branch rebuilds from the scan state, not from these rows.
    func refreshPrefixUnderNarrowing(_ rows: [PanelRow], totalCount: Int, windowComplete: Bool) {
        guard !isLoadingFirstRows, isNarrowingHistory, !historyWindowComplete else { return }
        withBatchedInputs {
            historyRows = rows
            historyWindowTotal = max(totalCount, rows.count)
            historyWindowComplete = windowComplete
        }
    }

    /// Replace the loaded prefix with a fresh read of the same range (M-UI.11 P3): the head
    /// observation saw a write land under the OPEN panel, and the controller re-read the prefix
    /// from current data. Deleted rows drop out (nothing stale stays selectable — the P3 exit
    /// rule), moved/new rows re-slot, and the count re-bases; the user's page, parked page
    /// move, and selection survive wherever they still resolve. Narrowing commits belong to
    /// the hydration path (`completeWindow`) — a prefix built without the search/category
    /// context must never replace a narrowed window, so those states are skipped here (defense
    /// in depth with the controller's own ordering guards).
    ///
    func reconcilePrefix(_ rows: [PanelRow], totalCount: Int, windowComplete: Bool) {
        guard !isLoadingFirstRows else { return }
        // A narrowing over a PREFIX window is the scan's to reconcile (a fresh silent scan) —
        // this prefix has no such context. Over a COMPLETE window the commit is safe and
        // needed: the rows ARE the whole window, and the rebuild re-applies the narrowing
        // in-memory (P4).
        if isNarrowingHistory && !historyWindowComplete { return }
        // A parked page move is the user's live navigation, not stale context: the reconcile
        // cancelled the fetch that was serving it (and the append that would complete it), so
        // re-target it against the fresh window — goToPage re-clamps, and re-parks/fetches if
        // the rows still don't reach it. Dropping it would swallow the keypress (P3 review).
        let target = pendingPage ?? currentPage
        // An unchanged prefix needs no commit: the common no-drift verify after a warm open
        // would otherwise force a full derived-tier rebuild and list diff per open.
        if rows == historyRows && windowComplete == historyWindowComplete
            && max(totalCount, rows.count) == historyWindowTotal {
            if pendingPage != nil {
                pendingPage = nil
                goToPage(target)
            }
            return
        }
        let previousSelection = selection
        withBatchedInputs {
            historyRows = rows
            historyWindowTotal = max(totalCount, rows.count)
            historyWindowComplete = windowComplete
        }
        pendingPage = nil
        goToPage(target)
        if let surviving = survivingSelection(previousSelection) {
            selection = surviving
        }
    }

    /// Screen lock (D4): drop every decrypted history row — the prefix AND any scan matches —
    /// with masking off they are raw plaintext, and `hide()` alone would keep them resident
    /// behind the lock. Snippets are user-authored plaintext and stay. Not `beginLoading`:
    /// there is no open being staged; the next `show()` rebuilds whatever it needs.
    func purgeHistoryRows() {
        withBatchedInputs {
            historyRows = []
            historyWindowTotal = 0
            historyWindowComplete = true
            clearScanResults()
        }
        pendingPage = nil
        selection = nil
    }

    /// Close the chips row, clearing any active category, in ONE rebuild (the funnel toggle-off /
    /// ⌘F-off path — `isFilterBarOpen = false` followed by `setCategory(.all)` would walk the rows
    /// twice). A closed bar must never keep narrowing the list.
    func closeFilterBar() {
        guard isFilterBarOpen else { return }
        pendingPage = nil // a parked page move belongs to the context it was requested in (review)
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
        pendingPage = nil // a parked page move belongs to the context it was requested in (review)
        withBatchedInputs {
            category = newCategory
            currentPage = 0
        }
        selection = firstSelectableVisibleID
    }

    /// Re-base paging/selection after the query changes: page 0 of the new result set, top selectable row.
    /// (The query's own didSet already rebuilt the filtered tier.)
    func searchTextDidChange() {
        pendingPage = nil // a parked page move belongs to the context it was requested in (review)
        currentPage = 0
        selection = firstSelectableVisibleID
    }

    /// Switch scope (⌘1/⌘2/⌘3) and re-base to page 0 + top selectable row, keeping the query.
    /// Entering the Snippets scope clears the category filter (snippets carry no content kind —
    /// any non-All chip would blank the list confusingly; the chips row is hidden there too).
    func setScope(_ newScope: Scope) {
        guard newScope != scope else { return }
        pendingPage = nil // a parked page move belongs to the context it was requested in (review)
        withBatchedInputs {
            scope = newScope
            if newScope == .snippets {
                category = .all
            }
            currentPage = 0
        }
        selection = firstSelectableVisibleID
    }

    /// Move to `page` (clamped) and highlight that page's top selectable row. While the window
    /// is a prefix (P2), a page whose history portion isn't materialized yet PARKS instead of
    /// moving — the current page stays visible (§5.3), `onNeedsMoreHistory` fetches, and
    /// `appendHistoryPage` completes the move. Never renders a seam of misplaced rows.
    func goToPage(_ page: Int) {
        // Loading shell: the history-bearing scopes have no confirmed pages to move to, and a
        // pre-commit cursor move would slice a seam page (snippets where history rows belong)
        // out of the freshly committed rows (review). Snippets pages stay navigable — final data.
        if isLoadingFirstRows && scope != .snippets { return }
        let clampCount = historyWindowComplete
            ? derived.filteredRows.count
            : effectiveRowCount(loaded: derived.filteredRows.count)
        let target = PanelPaging.clampPage(page, rowCount: clampCount, itemsPerPage: itemsPerPage)
        // Narrowed states never park (P4): the scan delivers every match without being asked,
        // and the snippets scope is always fully materialized — only an un-narrowed
        // history-bearing prefix pages by fetching.
        if !historyWindowComplete && scope != .snippets && !isNarrowingHistory {
            let neededHistory = min((target + 1) * itemsPerPage, historyWindowTotal)
            if historyRows.count < neededHistory {
                pendingPage = target
                onNeedsMoreHistory?()
                return
            }
        }
        currentPage = target
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
