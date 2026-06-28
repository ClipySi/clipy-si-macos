//
//  HistoryFilter.swift
//  ClipySi — Apple Silicon rewrite
//
//  Display-only filter/search/sort for the History Manager. The pipeline runs entirely
//  in memory over the already-decrypted `HistoryClipRow`s of the loaded window — it NEVER reads or
//  writes the database (the only mutation in the History Manager is delete; see the design, Q1).
//  Text search must live here rather than in SQL because the preview is stored as an AES-GCM
//  ciphertext (`Clip.titleCipher`); only the decrypted `HistoryClipRow.preview` is searchable.
//

import Foundation

/// The current filter/search/sort selection for the History table. Pure value type so the pipeline
/// is testable without a database or view.
struct HistoryQuery: Equatable {
    /// Free-text query matched against the decrypted preview (locale-aware, case/diacritic-insensitive).
    var searchText: String = ""
    /// Exact match against `HistoryClipRow.typeDisplay`; `nil` means "all types".
    var typeDisplay: String?
    /// Exact match against `HistoryClipRow.sourceBundleDisplay`; `nil` means "all apps".
    var appDisplay: String?
    /// Column sort order (driven by the SwiftUI `Table` header). Defaults to newest-first by date.
    var sort: [KeyPathComparator<HistoryClipRow>] = HistoryQuery.defaultSort

    /// Newest-first by capture time — the History Manager's natural order and the table's initial sort.
    static let defaultSort = [KeyPathComparator(\HistoryClipRow.createdAt, order: .reverse)]

    /// True when any filter or search narrows the result (used to show the "clear" affordance and the
    /// filtered empty state). Sort alone does not count as active.
    var isActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || typeDisplay != nil
            || appDisplay != nil
    }
}

enum HistoryFilter {
    /// Returns the rows to display: filtered by type/app, matched against the search text, then sorted.
    /// Pure — no database access, no mutation of `rows`.
    static func apply(_ query: HistoryQuery, to rows: [HistoryClipRow]) -> [HistoryClipRow] {
        let term = query.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = rows.filter { row in
            if let type = query.typeDisplay, row.typeDisplay != type { return false }
            if let app = query.appDisplay, row.sourceBundleDisplay != app { return false }
            // Locale-aware contains: case-, diacritic- and width-insensitive, matching Finder-style search.
            if !term.isEmpty, !row.preview.localizedStandardContains(term) { return false }
            return true
        }
        return query.sort.isEmpty ? filtered : filtered.sorted(using: query.sort)
    }
}
