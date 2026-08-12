//
//  HistoryWarmCache.swift
//  ClipySi — Apple Silicon rewrite
//
//  M-UI.11 P3: the panel's warm-open store — the display-ready HEAD of the history window
//  (first rows + continuation cursor), kept current between opens by `HistoryHeadObserver` so
//  `show()` can commit first rows in the SAME turn as the shell, with no DB/decrypt work on
//  that path (plan v2 §5.1).
//
//  Deliberately `@MainActor`-owned, not an actor (an adaptation of §4.1 recorded in the P3
//  report): the P2 prefix-walk model keeps every previously-visited page materialized in the
//  model, so a current/previous/next page LRU would cache nothing an open can't already serve —
//  what earns the warm open is the window HEAD surviving across opens. And serving it
//  synchronously from `show()` requires MainActor access; the decrypt/mask work that BUILDS a
//  snapshot stays on the `HistoryReadService` actor (§3.3 — the MainActor only swaps results).
//
//  Security (§3.2/§4.4): rows hold masked display titles — with masking OFF that equals the raw
//  title, so the cache is treated as secret-bearing plaintext: process memory only, hard row +
//  byte caps, purged on screen lock (D4: kept across panel hides — the lock purge bounds the
//  exposure window, and hide-purging would forfeit the warm open entirely).
//

import Foundation

@MainActor
final class HistoryWarmCache {
    /// One warm open, ready to commit: the head rows under `request`'s policy/sort/cap, the
    /// keyset continuation after them, and the window total the paging math needs.
    struct Snapshot {
        let rows: [PanelRow]
        /// Where a sequential page walk continues after `rows`; nil when the capped window is
        /// already exhausted (small histories).
        let nextCursor: ClipPageCursor?
        let totalCount: Int
        /// The page-query contract the rows were built under — the cache's validity signature.
        /// Any change to page size, cap, sort, mask policy, or classifier version makes the
        /// stored snapshot unmatchable (§4.4 invalidation), with no flag bookkeeping to forget.
        let request: HistoryReadService.PageRequest

        var windowComplete: Bool { nextCursor == nil }
    }

    /// §4.4 sizing: up to 3 resident pages of the head, hard-capped at 63 rows (the
    /// `itemsPerPage = 20` + sentinel basis). D2 records the choice.
    static func rowCap(pageSize: Int) -> Int { min(3 * max(1, pageSize), 63) }

    /// §4.4: 4 MiB ceiling on the display strings held for warm opens. Estimated as UTF-8
    /// title bytes + a fixed per-row overhead (D2 — adjust from measurement, not speculation).
    static let byteCap = 4 * 1024 * 1024
    private static let perRowOverhead = 64

    private(set) var stored: Snapshot?

    /// The snapshot for THIS open, or nil when none/stale: an open may only serve rows built
    /// under its own page-query contract — a differing signature is a cold open, never a
    /// "close enough" hit.
    func snapshot(matching request: HistoryReadService.PageRequest) -> Snapshot? {
        guard let stored, stored.request == request else { return nil }
        return stored
    }

    /// Store the freshest head, enforcing the row/byte bounds. A snapshot truncated by a bound
    /// re-derives its continuation cursor from the last KEPT row, so a warm open served from it
    /// pages on seamlessly.
    func store(_ snapshot: Snapshot) {
        stored = Self.bounded(snapshot)
    }

    /// Drop everything (screen lock, settings change, observation failure). The next open is
    /// cold; the observer refills on its next fire.
    func purge() {
        stored = nil
    }

    /// Apply the row cap and byte cap. Internal (not private) so the bounds are testable
    /// without staging an observer.
    static func bounded(_ snapshot: Snapshot) -> Snapshot? {
        let rowCap = rowCap(pageSize: snapshot.request.pageSize)
        var kept = 0
        var bytes = 0
        for row in snapshot.rows.prefix(rowCap) {
            bytes += row.title.utf8.count + perRowOverhead
            if bytes > byteCap { break }
            kept += 1
        }
        guard kept < snapshot.rows.count else { return snapshot }
        // A truncated snapshot must still hold at least one FULL page: committing a shorter
        // prefix as page 0 of an incomplete window would let snippet rows fill the page's
        // history slots (the §5.3 seam — digits would paste snippets posing as history),
        // because page 0 counts as materialized and nothing re-fetches. Possible in practice:
        // the capture cap is 10,000 CHARACTERS, so grapheme-heavy titles can cross the byte
        // cap within one page. Serve nothing — a cold open is slower but correct.
        guard kept >= snapshot.request.pageSize else { return nil }
        let rows = Array(snapshot.rows.prefix(kept))
        // Truncation makes the window a strict prefix: the continuation cursor moves back to
        // the last kept row's (createdAt, id). A kept row missing those values cannot happen
        // for service-built rows (PanelRowBuilder always stamps them) — if it ever does, the
        // snapshot is unserveable and is dropped rather than stored with a wrong cursor.
        guard let last = rows.last else { return nil }
        guard case let .clip(clipID) = last.id, let createdAt = last.createdAt else { return nil }
        return Snapshot(rows: rows,
                        nextCursor: ClipPageCursor(createdAt: createdAt, id: clipID),
                        totalCount: snapshot.totalCount,
                        request: snapshot.request)
    }
}
