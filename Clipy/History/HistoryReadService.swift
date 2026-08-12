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
    }

    /// One reply. `rows` are display-ready (decrypted + masked; code classification stays
    /// lazy — P1). Row COUNTS only ever reach logs/signposts, never row content (§3.2).
    struct PageResult: Sendable {
        let rows: [PanelRow]
        /// Where the next sequential page continues; nil when the capped window is exhausted.
        let nextCursor: ClipPageCursor?
        /// Live clips in the capped window — `min(COUNT(*), historyLimit)` at fetch time.
        let totalCount: Int
    }

    private let clips = ClipRepository()
    private let displayBuilder = ClipDisplayBuilder()

    private static let log = Logger(subsystem: "io.github.ponponusa.clipysi", category: "history-read")

    /// The first page of an open, plus the window total the model's paging math needs.
    func openPage(_ request: PageRequest) -> PageResult {
        page(after: nil, loadedCount: 0, request)
    }

    /// The next sequential page after `cursor`. `loadedCount` rows are already committed, so
    /// the remaining budget under `historyLimit` caps this fetch.
    func nextPage(after cursor: ClipPageCursor, loadedCount: Int, _ request: PageRequest) -> PageResult {
        page(after: cursor, loadedCount: loadedCount, request)
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
            return PageResult(rows: [], nextCursor: nil, totalCount: 0)
        }
    }

    // MARK: - Private

    /// A DB failure degrades to an empty page (logged), mirroring `MenuModel.history` — the
    /// panel shows its empty state rather than throwing into the open pipeline.
    private func page(after cursor: ClipPageCursor?, loadedCount: Int, _ request: PageRequest) -> PageResult {
        do {
            let total = try min(clips.count(), request.historyLimit)
            let budget = max(0, min(request.pageSize, request.historyLimit - loadedCount))
            guard budget > 0 else { return PageResult(rows: [], nextCursor: nil, totalCount: total) }
            // `budget + 1`: the extra row is the has-more sentinel, never served.
            let fetched = try PanelSignpost.measureCounted(.historyFetch) {
                try clips.livePage(after: cursor, limit: budget + 1, ascending: request.ascending)
            }
            let pageClips = Array(fetched.prefix(budget))
            let hasMore = fetched.count > budget && loadedCount + pageClips.count < request.historyLimit
            let rows = buildRows(pageClips, policy: request.policy)
            let nextCursor = hasMore
                ? pageClips.last.map { ClipPageCursor(createdAt: $0.createdAt, id: $0.id) }
                : nil
            return PageResult(rows: rows, nextCursor: nextCursor, totalCount: total)
        } catch {
            Self.log.error("history page read failed: \(error.localizedDescription, privacy: .public)")
            return PageResult(rows: [], nextCursor: nil, totalCount: 0)
        }
    }

    private func buildRows(_ clipRows: [Clip], policy: DisplayPolicy) -> [PanelRow] {
        PanelSignpost.measure(.historyDecryptMask, rows: clipRows.count) {
            displayBuilder.displays(of: clipRows, policy: policy).map(PanelRowBuilder.historyRow(for:))
        }
    }
}
