//
//  HistoryReadService+Scan.swift
//  ClipySi — Apple Silicon rewrite
//
//  M-UI.11 P4: the progressive scan behind search, title-dependent categories, and the chips'
//  exact counts — the replacement for P2's interim whole-window hydration. The scan walks the
//  capped live window through the SAME `page()` machinery every other read uses (one
//  keyset/cap/total contract — P4 review), decrypting + masking on this actor's executor,
//  matching with the SAME predicates the in-memory tier uses (`PanelSearch.matches` over the
//  MASKED title — §3.2; `PanelCategory.matches`), and streaming CUMULATIVE match sets so
//  consumers can conflate updates without losing rows. The window's front is scanned first, so
//  the first page of matches settles early and stays stable while the tail streams in (§5.4).
//
//  Counts (§4.5): when the chips row is open, the same pass tallies per-category counts over
//  the query-surviving rows — exact only on the final update; partial counts never leave the
//  actor as anything but `nil` (§3.1). Title-dependent membership (.text/.code) resolves
//  through the shared `CodeVerdictMemo` (this actor's instance), so re-scans of an unchanged
//  history skip the ~220 µs/row classifier cost.
//
//  EVERY walk ends with a settled update — `complete` on exhaustion (including an empty
//  window or a wall exactly on a batch boundary) or `failed` on a DB error (P4 review: a
//  missing terminal update left the panel scanning forever). Cancellation is cooperative per
//  batch, with a yield between batches so this actor stays responsive to page/warm reads.
//

import Foundation

extension HistoryReadService {
    /// One progressive-scan request: the open's page contract plus the narrowing inputs the
    /// scan filters by. `query` is NORMALIZED (`PanelSearch.normalize`) by the maker —
    /// request equality is coalescing identity, and a whitespace edit must not read as a new
    /// scan. Equatable — the controller coalesces by comparing whole requests.
    struct ScanRequest: Sendable, Equatable {
        let base: PageRequest
        let query: String
        let category: PanelCategory
        /// The chips row is open: tally exact per-category counts in the same pass.
        let needsCounts: Bool
    }

    /// One progress update. `matches` is the CUMULATIVE match set in window order — a dropped
    /// intermediate update loses nothing. `counts` is non-nil only on the final (complete)
    /// update: a partial count must never pose as exact (§3.1).
    struct ScanUpdate: Sendable {
        let matches: [PanelRow]
        let processed: Int
        let total: Int
        let counts: [PanelCategory: Int]?
        let complete: Bool
        /// A DB error ended the walk early. `matches` holds what was scanned; the consumer
        /// decides whether partial results stay up (user-facing scan) or are discarded
        /// (silent reconcile re-scan).
        let failed: Bool

        /// The walk is over — no further update follows this one.
        var isSettled: Bool { complete || failed }
    }

    /// D5: batch size 128 — cancel latency ~2 ms of work per batch at the measured
    /// decrypt+mask cost, far inside the 16 ms input budget.
    static let scanBatchSize = 128
    /// After the first pages have settled on screen, intermediate yields thin out to one per
    /// this many batches (P4 review: a cumulative yield per batch is an O(n²/batch) copy tail
    /// and a MainActor rebuild each, for a footer-progress-only change).
    static let scanYieldStride = 8

    /// Start a progressive scan of the capped live window. The stream buffers only the newest
    /// update (cumulative matches make conflation lossless); it finishes after the settled
    /// (`complete`/`failed`) update, or when the consumer cancels. `finalOnly` is the silent
    /// reconcile's mode: intermediate payloads are never even built — one settled update.
    /// `nonisolated`: this only builds the stream — the walk hops onto the actor's executor.
    nonisolated func scanWindow(_ request: ScanRequest, finalOnly: Bool = false) -> AsyncStream<ScanUpdate> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                await self.runScan(request, finalOnly: finalOnly, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Private

    private func runScan(_ request: ScanRequest, finalOnly: Bool,
                         continuation: AsyncStream<ScanUpdate>.Continuation) async {
        let term = PanelSearch.normalize(request.query) // defensive — the maker normalizes
        let needsVerdicts = request.needsCounts
            || request.category == .text || request.category == .code
        var matches: [PanelRow] = []
        var counts: [PanelCategory: Int] = [:]
        if request.needsCounts {
            for category in PanelCategory.allCases { counts[category] = 0 }
        }
        var processed = 0
        var total = 0
        var cursor: ClipPageCursor?
        var batchIndex = 0
        while !Task.isCancelled {
            let result = page(after: cursor, loadedCount: processed,
                              budget: Self.scanBatchSize, request.base)
            if result.failed {
                continuation.yield(ScanUpdate(matches: matches, processed: processed,
                                              total: total, counts: nil,
                                              complete: false, failed: true))
                break
            }
            if batchIndex == 0 { total = result.totalCount }
            processed += result.rows.count
            for row in result.rows {
                let resolved = needsVerdicts ? scanVerdicts.resolve(row, policy: request.base.policy) : row
                // The SAME predicate chain as the in-memory tier: the normalized query over
                // the MASKED title, then the category. Counts tally the query-surviving rows
                // BEFORE the category cut (the badge semantics: what each chip would show).
                guard PanelSearch.matches(resolved, term: term) else { continue }
                if request.needsCounts {
                    for category in PanelCategory.allCases where category.matches(resolved) {
                        counts[category, default: 0] += 1
                    }
                }
                if request.category.matches(resolved) {
                    matches.append(resolved)
                }
            }
            cursor = result.nextCursor
            let exhausted = result.nextCursor == nil
            // First pages yield per batch (§5.4 early delivery); the settled tail thins out.
            let dueYield = batchIndex < 2 || batchIndex % Self.scanYieldStride == 0
            if exhausted || (!finalOnly && dueYield) {
                continuation.yield(ScanUpdate(matches: matches, processed: min(processed, total),
                                              total: total,
                                              counts: exhausted && request.needsCounts ? counts : nil,
                                              complete: exhausted, failed: false))
            }
            if exhausted { break }
            batchIndex += 1
            // Keep the actor fair: page/warm reads interleave between batches.
            await Task.yield()
        }
        continuation.finish()
    }
}
