//
//  HistoryReadService+Manager.swift
//  ClipySi — Apple Silicon rewrite
//
//  M-UI.11 P5: the History Manager's read path on the SAME actor the panel reads through — one
//  executor serializes every decrypt/mask in the app. A page read serves 50 display-ready rows
//  of the filtered, sorted live history (metadata narrowing and sort pushed down to SQL —
//  ClipRepository+Manager.swift); ONLY the served rows are decrypted, the has-more sentinel is
//  fetched raw. That retires the 500-row eager window: open cost is a page, not the corpus.
//
//  Text search is a progressive scan over the WHOLE live set (no manager cap — plan v2 §5.6),
//  mirroring the panel's P4 scan: date-ordered keyset walk (the partial index), metadata
//  filters applied in SQL so non-matching rows are never decrypted, the shared
//  `PanelSearch.matchesTitle` predicate over the FULL searchable title (masked displayTitle or
//  type placeholder — truncation is display-only), cumulative match sets so conflation is
//  lossless, and a guaranteed settled (`complete`/`failed`) update on every exit path (the P4
//  batch-boundary lesson). Matches stream already ordered by the requested sort: date sorts
//  fall out of the walk direction; metadata sorts merge each batch into the cumulative set
//  under the SAME total order the SQL push-down produces (`ManagerSort.areInOrder`).
//

import Foundation

extension HistoryReadService {
    /// The manager's page-read contract: narrowing, sort, and mask policy resolved ONCE on the
    /// MainActor and carried through every fetch it parents, so a Privacy toggle mid-read can't
    /// shear pages (the P2 §4.1 rule, manager edition).
    struct ManagerRequest: Sendable, Equatable {
        let pageSize: Int
        let filter: ManagerRowFilter
        let sort: ManagerSort
        let policy: DisplayPolicy
    }

    /// The Type/App menu inputs: raw distinct values of the whole live set (the store maps
    /// types to display labels).
    struct ManagerFacets: Sendable, Equatable {
        let typeRawValues: [String]
        let apps: [String]
    }

    /// One manager page reply. Rows are display-ready `HistoryClipRow`s (decrypted + masked on
    /// the actor); counts/facets are present only when the read asked for them.
    struct ManagerPageResult: Sendable {
        let rows: [HistoryClipRow]
        /// Where the next sequential page continues; nil when the filtered set is exhausted.
        let nextCursor: ManagerPageCursor?
        let filteredCount: Int?
        let facets: ManagerFacets?
        /// The read FAILED (DB error) — `rows` is empty because nothing could be read. The
        /// store must not wipe live rows with it (the P3 reconcile lesson).
        var failed = false
    }

    /// One manager scan request. `query` is NORMALIZED (`PanelSearch.normalize`) and non-empty
    /// by contract — request equality is the store's coalescing/stamp identity.
    struct ManagerScanRequest: Sendable, Equatable {
        let base: ManagerRequest
        let query: String
    }

    /// One scan progress update. `matches` is CUMULATIVE and already in `base.sort` order — a
    /// dropped intermediate update loses nothing.
    struct ManagerScanUpdate: Sendable {
        let matches: [HistoryClipRow]
        let processed: Int
        /// The filtered live-set size (the scan's denominator), read with the first batch.
        let total: Int
        let complete: Bool
        let failed: Bool

        /// The walk is over — no further update follows this one.
        var isSettled: Bool { complete || failed }
    }

    /// One page of the manager table. `.count` re-reads the filtered count in the same
    /// transaction as the rows (open and reconcile reads); sequential page moves skip it — the
    /// store keeps its committed total. `.facets` refreshes the Type/App menus.
    func managerPage(after cursor: ManagerPageCursor?, options: ManagerReadOptions,
                     _ request: ManagerRequest) -> ManagerPageResult {
        do {
            let data = try PanelSignpost.measure(.managerFetch) {
                try clips.managerPage(filter: request.filter, sort: request.sort, after: cursor,
                                      limit: request.pageSize + 1, options: options)
            }
            let served = Array(data.page.prefix(request.pageSize))
            let hasMore = data.page.count > request.pageSize
            let rows = buildManagerRows(served, policy: request.policy)
            return ManagerPageResult(
                rows: rows,
                nextCursor: hasMore ? served.last.map { clip in
                    ManagerPageCursor(sortValue: request.sort.cursorValue(of: clip),
                                      createdAt: clip.createdAt, id: clip.id)
                } : nil,
                filteredCount: data.filteredCount,
                facets: data.typeRawValues.map {
                    ManagerFacets(typeRawValues: $0, apps: data.apps ?? [])
                })
        } catch {
            Self.log.error("manager page read failed: \(error.localizedDescription, privacy: .public)")
            return ManagerPageResult(rows: [], nextCursor: nil, filteredCount: nil,
                                     facets: nil, failed: true)
        }
    }

    /// Start a progressive search of the filtered live set. The stream buffers only the newest
    /// update (cumulative matches make conflation lossless); it finishes after the settled
    /// update, or when the consumer cancels. `finalOnly` is the silent reconcile's mode.
    /// `nonisolated`: this only builds the stream — the walk hops onto the actor's executor.
    nonisolated func managerScan(_ request: ManagerScanRequest,
                                 finalOnly: Bool = false) -> AsyncStream<ManagerScanUpdate> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                await self.runManagerScan(request, finalOnly: finalOnly, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Private

    private func runManagerScan(_ request: ManagerScanRequest, finalOnly: Bool,
                                continuation: AsyncStream<ManagerScanUpdate>.Continuation) async {
        let term = PanelSearch.normalize(request.query) // defensive — the maker normalizes
        // The walk itself is always the date-keyset order (the indexed seek). A date sort
        // streams matches in final order directly; metadata sorts merge each batch below.
        let sort = request.base.sort
        let walkSort = ManagerSort(key: .date, ascending: sort.key == .date && sort.ascending)
        var matches: [HistoryClipRow] = []
        // A row whose `createdAt` is bumped mid-walk (moveToTop, re-copy dedupe) can be
        // re-encountered by an ASCENDING walk — without this, `scanMatches` would hold the
        // same id twice (duplicate `Identifiable` rows in the Table; review).
        var matchedIDs = Set<UUID>()
        var processed = 0
        var total = 0
        var cursor: ManagerPageCursor?
        var batchIndex = 0
        while !Task.isCancelled {
            let data: ManagerPageData
            do {
                data = try clips.managerPage(filter: request.base.filter, sort: walkSort,
                                             after: cursor, limit: Self.scanBatchSize + 1,
                                             options: batchIndex == 0 ? .count : [])
            } catch {
                Self.log.error("manager scan read failed: \(error.localizedDescription, privacy: .public)")
                continuation.yield(ManagerScanUpdate(matches: matches, processed: processed,
                                                     total: total, complete: false, failed: true))
                break
            }
            if batchIndex == 0 { total = data.filteredCount ?? 0 }
            let served = Array(data.page.prefix(Self.scanBatchSize))
            processed += served.count
            // Decrypt + mask the batch (the search needs every title), match on the FULL
            // searchable title, then keep only the (display-truncated) matching rows.
            let displays = PanelSignpost.measure(.managerDecryptMask, rows: served.count) {
                displayBuilder.displays(of: served, policy: request.base.policy)
            }
            var fresh: [HistoryClipRow] = []
            for (clip, display) in zip(served, displays)
            where !matchedIDs.contains(clip.id)
                && PanelSearch.matchesTitle(HistoryClipRow.searchableTitle(for: display), term: term) {
                matchedIDs.insert(clip.id)
                fresh.append(HistoryClipRow(clip: clip, display: display))
            }
            if sort.key == .date {
                matches.append(contentsOf: fresh) // walk order IS the requested order
            } else if !fresh.isEmpty {
                matches = Self.merge(matches, fresh.sorted(by: sort.areInOrder), by: sort)
            }
            let hasMore = data.page.count > Self.scanBatchSize
            cursor = hasMore ? served.last.map { clip in
                ManagerPageCursor(sortValue: .none, createdAt: clip.createdAt, id: clip.id)
            } : nil
            let exhausted = !hasMore
            // First batches yield per batch (early first page); the settled tail thins out —
            // the P4 stride, same rationale.
            let dueYield = batchIndex < 2 || batchIndex % Self.scanYieldStride == 0
            if exhausted || (!finalOnly && dueYield) {
                // Rows added mid-walk can push `processed` past the count read with batch 0 —
                // lift the denominator, never clamp the numerator (the bar may finish early,
                // but progress never runs backwards or past 100%).
                continuation.yield(ManagerScanUpdate(matches: matches, processed: processed,
                                                     total: max(total, processed),
                                                     complete: exhausted, failed: false))
            }
            if exhausted { break }
            batchIndex += 1
            // Keep the actor fair: panel reads interleave between batches.
            await Task.yield()
        }
        continuation.finish()
    }

    private func buildManagerRows(_ clipRows: [Clip], policy: DisplayPolicy) -> [HistoryClipRow] {
        PanelSignpost.measure(.managerDecryptMask, rows: clipRows.count) {
            zip(clipRows, displayBuilder.displays(of: clipRows, policy: policy))
                .map { HistoryClipRow(clip: $0, display: $1) }
        }
    }

    /// Merge two arrays that are each sorted under `sort` into one — the scan's cumulative
    /// match set stays in SQL push-down order without re-sorting the whole set per batch.
    private static func merge(_ left: [HistoryClipRow], _ right: [HistoryClipRow],
                              by sort: ManagerSort) -> [HistoryClipRow] {
        var merged: [HistoryClipRow] = []
        merged.reserveCapacity(left.count + right.count)
        var leftIndex = 0
        var rightIndex = 0
        while leftIndex < left.count, rightIndex < right.count {
            if sort.areInOrder(right[rightIndex], left[leftIndex]) {
                merged.append(right[rightIndex])
                rightIndex += 1
            } else {
                merged.append(left[leftIndex])
                leftIndex += 1
            }
        }
        merged.append(contentsOf: left[leftIndex...])
        merged.append(contentsOf: right[rightIndex...])
        return merged
    }
}
