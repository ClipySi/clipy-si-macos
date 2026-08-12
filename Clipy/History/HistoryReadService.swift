//
//  HistoryReadService.swift
//  ClipySi — Apple Silicon rewrite
//
//  M-UI.11 P2: the panel's off-MainActor history read path. `show()` orders the shell first,
//  then asks this actor for the first keyset page — DB fetch, AES-GCM decrypt, and mask
//  evaluation all run on the actor's executor, and the controller commits the result to the
//  model in ONE generation-guarded MainActor snapshot (a hide/re-show drops late results).
//  Sequential page moves continue from the returned cursor. The search/category/chip-counts
//  path still reads the whole capped window (the P2 interim — P4 replaces it with a
//  cancellable progressive scan), but off the MainActor too.
//
//  Isolation: everything here is Sendable value types — `ClipRepository`,
//  `ClipDisplayBuilder`, and the ciphers/maskers they hold are non-isolated structs, and
//  `Clip`/`PanelRow`/`DisplayPolicy` are Sendable. No SwiftUI/AppKit objects cross the
//  boundary (plan v2 §4.1). Signposts (`historyFetch`/`historyDecryptMask`) fire from the
//  actor's executor; `OSSignposter` is thread-safe.
//

import Foundation
import OSLog

actor HistoryReadService {
    /// The page-query contract for one open: resolved ONCE on the MainActor (settings + display
    /// policy) and carried through every fetch of that open, so sort, cap, and mask policy can't
    /// shear between the pages of a single request (§4.1).
    struct PageRequest: Sendable, Equatable {
        let pageSize: Int
        /// The normalized history cap (`AppSettings.maxHistorySize`, clamped on read — P1).
        let historyLimit: Int
        /// Oldest-first when `historySortNewestFirst` is off. Existing window semantics kept:
        /// ascending serves the OLDEST `historyLimit` rows, exactly as `recentClips` always has.
        let ascending: Bool
        let policy: DisplayPolicy

        /// The contract under CURRENT settings — the same values `show()` resolves from
        /// `panelSettings` + `DisplayPolicy.current()`, so a warm snapshot built by the head
        /// observer (M-UI.11 P3) carries a signature an open can actually match.
        static func current(settings: AppSettings = AppSettings()) -> PageRequest {
            PageRequest(pageSize: settings.historyPanelItemsPerPage,
                        historyLimit: settings.maxHistorySize,
                        ascending: !settings.historySortNewestFirst,
                        policy: .current(settings: settings))
        }
    }

    /// One reply. `rows` are display-ready (decrypted + masked; code classification stays
    /// lazy — P1). Row COUNTS only ever reach logs/signposts, never row content (§3.2).
    struct PageResult: Sendable {
        let rows: [PanelRow]
        /// Where the next sequential page continues; nil when the capped window is exhausted.
        let nextCursor: ClipPageCursor?
        /// Live clips in the capped window — `min(COUNT(*), historyLimit)`, read in the SAME
        /// transaction as the rows on the open/prefix/window paths. Sequential `nextPage` reads
        /// skip the count (the model keeps its window totals; P3 review): there it is only the
        /// served-so-far lower bound, and the model's `max()` re-base makes that safe.
        let totalCount: Int
        /// The read FAILED (DB error): `rows` is empty because nothing could be read, not
        /// because the history is empty. A cold open still degrades to the empty shell (the P2
        /// contract — there is no good state to lose), but reconcile commits must skip instead
        /// of wiping live rows with a false "no history" (P3 review).
        var failed = false
    }

    private let clips = ClipRepository()
    private let displayBuilder = ClipDisplayBuilder()

    private static let log = Logger(subsystem: "io.github.ponponusa.clipysi", category: "history-read")

    /// The first page of an open, plus the window total the model's paging math needs.
    func openPage(_ request: PageRequest) -> PageResult {
        page(after: nil, loadedCount: 0, budget: request.pageSize, request)
    }

    /// The first `rowCount` rows of the window in one read — the P3 reconcile path (re-serve
    /// the loaded prefix from current data after the head observation saw a write land) and the
    /// warm open's background verification. Same contract as a page read, just a wider budget.
    func openPrefix(rowCount: Int, _ request: PageRequest) -> PageResult {
        page(after: nil, loadedCount: 0, budget: rowCount, request)
    }

    /// The next sequential page after `cursor`. `loadedCount` rows are already committed, so
    /// the remaining budget under `historyLimit` caps this fetch.
    func nextPage(after cursor: ClipPageCursor, loadedCount: Int, _ request: PageRequest) -> PageResult {
        page(after: cursor, loadedCount: loadedCount, budget: request.pageSize, request)
    }

    /// Turn the head observation's raw fetch into warm-cache rows (M-UI.11 P3): decrypt + mask
    /// up to `rowCap` rows on this actor's executor — never on the observation's reader or the
    /// MainActor. `head.headClips` should hold `rowCap + 1` rows; the extra row only proves
    /// has-more and is not decrypted, mirroring the page sentinel.
    func warmRows(from head: HistoryHeadState, _ request: PageRequest, rowCap: Int) -> PageResult {
        let total = min(head.liveCount, request.historyLimit)
        let budget = max(0, min(rowCap, request.historyLimit))
        return result(fetched: head.headClips, budget: budget, loadedCount: 0,
                      total: total, request: request)
    }

    /// The whole capped window — the interim basis for search, category filters, and chip
    /// counts (P4 replaces this with a progressive scan; P2 only moves it off the MainActor).
    /// Cost equals the pre-P2 open (`recentClips` + decrypt + mask), paid only when the user
    /// actually narrows.
    func fullWindow(_ request: PageRequest) -> PageResult {
        do {
            let clipRows = try PanelSignpost.measureCounted(.historyFetch) {
                try clips.recentClips(limit: request.historyLimit, ascending: request.ascending)
            }
            let rows = buildRows(clipRows, policy: request.policy)
            return PageResult(rows: rows, nextCursor: nil, totalCount: rows.count)
        } catch {
            Self.log.error("history window read failed: \(error.localizedDescription, privacy: .public)")
            return PageResult(rows: [], nextCursor: nil, totalCount: 0, failed: true)
        }
    }

    // MARK: - Private

    /// A DB failure degrades to an empty page (logged), mirroring `MenuModel.history` — the
    /// panel shows its empty state rather than throwing into the open pipeline. The result is
    /// flagged `failed` so the reconcile paths can refuse to commit it (see PageResult).
    private func page(after cursor: ClipPageCursor?, loadedCount: Int, budget: Int,
                      _ request: PageRequest) -> PageResult {
        do {
            let budget = max(0, min(budget, request.historyLimit - loadedCount))
            guard budget > 0 else {
                return PageResult(rows: [], nextCursor: nil, totalCount: loadedCount)
            }
            // `budget + 1`: the extra row is the has-more sentinel, never served. The head
            // read fetches rows + count in ONE transaction (a write between two reads would
            // shear the total against the rows — P3 review); a sequential page skips the
            // count entirely — its caller never commits totals.
            let total: Int
            let fetched: [Clip]
            if let cursor {
                fetched = try PanelSignpost.measureCounted(.historyFetch) {
                    try clips.livePage(after: cursor, limit: budget + 1, ascending: request.ascending)
                }
                total = loadedCount + min(fetched.count, budget)
            } else {
                // measure (not measureCounted): the combined fetch returns a tuple, so the
                // interval carries the duration; the served row count still reaches signposts
                // through the decrypt-mask stage.
                let head = try PanelSignpost.measure(.historyFetch) {
                    try clips.livePageWithCount(after: nil, limit: budget + 1,
                                                ascending: request.ascending)
                }
                fetched = head.page
                total = min(head.liveCount, request.historyLimit)
            }
            return result(fetched: fetched, budget: budget, loadedCount: loadedCount,
                          total: total, request: request)
        } catch {
            Self.log.error("history page read failed: \(error.localizedDescription, privacy: .public)")
            return PageResult(rows: [], nextCursor: nil, totalCount: 0, failed: true)
        }
    }

    /// Shared tail of every windowed read: serve `budget` rows, treat the extra fetched row as
    /// the has-more sentinel (present but never decrypted), and derive the continuation cursor
    /// from the last served row's `(createdAt, id)` values. `request.historyLimit` caps the
    /// walk: once `loadedCount` + this read reaches it, the window is exhausted regardless of
    /// what else is in the table.
    private func result(fetched: [Clip], budget: Int, loadedCount: Int, total: Int,
                        request: PageRequest) -> PageResult {
        let pageClips = Array(fetched.prefix(budget))
        let hasMore = fetched.count > budget && loadedCount + pageClips.count < request.historyLimit
        let rows = buildRows(pageClips, policy: request.policy)
        let nextCursor = hasMore
            ? pageClips.last.map { ClipPageCursor(createdAt: $0.createdAt, id: $0.id) }
            : nil
        return PageResult(rows: rows, nextCursor: nextCursor, totalCount: total)
    }

    private func buildRows(_ clipRows: [Clip], policy: DisplayPolicy) -> [PanelRow] {
        PanelSignpost.measure(.historyDecryptMask, rows: clipRows.count) {
            displayBuilder.displays(of: clipRows, policy: policy).map(PanelRowBuilder.historyRow(for:))
        }
    }
}
