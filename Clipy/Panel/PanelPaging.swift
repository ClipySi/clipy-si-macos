//
//  PanelPaging.swift
//  ClipySi — Apple Silicon rewrite
//
//  Pure paging + number-key math for the history FloatingPanel (history-panel design §3.2 / §4.3).
//  The panel shows `itemsPerPage` rows at a time; ←/→ flip pages; the first 10 rows of a page get a
//  number key (1-9,0 or 0-9 with start-at-zero) for one-press paste. Kept free of AppKit/SwiftUI so
//  the edge cases (page boundaries, the 10→0 key, start-at-zero) are unit-tested without a window.
//

import Foundation

enum PanelPaging {
    /// At most the first 10 rows of a page are number-key candidates (one digit each).
    static let maxNumberKeys = 10

    /// Number of pages for `rowCount` rows at `itemsPerPage`. Always ≥ 1 (an empty history is one
    /// empty page), so page 0 is always valid.
    static func pageCount(rowCount: Int, itemsPerPage: Int) -> Int {
        let perPage = max(1, itemsPerPage)
        return max(1, (rowCount + perPage - 1) / perPage)
    }

    /// Clamps a page index into `0 ..< pageCount`.
    static func clampPage(_ page: Int, rowCount: Int, itemsPerPage: Int) -> Int {
        let lastPage = pageCount(rowCount: rowCount, itemsPerPage: itemsPerPage) - 1
        return min(max(0, page), lastPage)
    }

    /// The half-open row index range shown on `page` (empty `0..<0` when there are no rows).
    static func range(page: Int, rowCount: Int, itemsPerPage: Int) -> Range<Int> {
        let perPage = max(1, itemsPerPage)
        let clamped = clampPage(page, rowCount: rowCount, itemsPerPage: itemsPerPage)
        let start = clamped * perPage
        let end = min(start + perPage, rowCount)
        guard start < end else { return 0..<0 }
        return start..<end
    }

    /// The one-press number key for the row at `pageLocalIndex` (0-based within the visible page), or
    /// `nil` for rows past the first 10. Start-at-1: 1,2,…,9,0. Start-at-zero: 0,1,…,9. No collisions
    /// (this deliberately does NOT reuse `MenuNumbering.keyEquivalent`, whose 11th-item value collides
    /// under start-at-zero — the panel never needs an 11th key because it pages instead).
    static func numberKey(pageLocalIndex index: Int, startWithZero: Bool) -> String? {
        guard index >= 0, index < maxNumberKeys else { return nil }
        if startWithZero { return "\(index)" }            // 0,1,…,9
        return index == maxNumberKeys - 1 ? "0" : "\(index + 1)" // 1,2,…,9,0
    }

    /// The displayed "N." list number for the row at `pageLocalIndex` (start-at-1 → 1-based, else 0-based).
    static func displayNumber(pageLocalIndex index: Int, startWithZero: Bool) -> Int {
        MenuNumbering.firstIndex(startWithZero: startWithZero) + index
    }
}
