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
        // A late append must never land on a completed window: hydration can replace the prefix
        // while a page fetch is in flight, and appending on top would duplicate rows and flip
        // the window back to prefix bookkeeping (review). The controller guards too — this is
        // defense in depth.
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
            goToPage(page)
        }
    }

    /// Replace the prefix with the COMPLETE capped window (the `onNeedsWindowHydration` reply).
    /// Deliberately preserves the narrowing inputs that requested it — search text, category,
    /// chips — and only re-bases the page/selection into the (now trustworthy) filtered rows.
    func completeWindow(_ rows: [PanelRow], totalCount: Int) {
        let previousSelection = selection
        withBatchedInputs {
            isLoadingFirstRows = false
            historyRows = rows
            historyWindowTotal = max(totalCount, rows.count)
            historyWindowComplete = true
        }
        pendingPage = nil
        goToPage(currentPage)
        // A hydration that raced a cleared narrowing must not stomp a highlight the user still
        // has — keep it when the selected row survived onto the current page (review).
        if let surviving = survivingSelection(previousSelection) {
            selection = surviving
        }
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
        if !historyWindowComplete && scope != .snippets {
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
