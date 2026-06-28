//
//  PanelSearch.swift
//  ClipySi — Apple Silicon rewrite
//
//  Pure text search for the history FloatingPanel (history-panel design §4.1 / C3). Mirrors the
//  History Manager's `HistoryFilter` text match — locale-aware `localizedStandardContains`, whitespace-
//  trimmed, empty query ⇒ all rows — but runs over `PanelRow`. Crucially the haystack is `PanelRow.title`,
//  which is the *masked* `displayTitle` (built by `ClipSelectionCoordinator.historyRows()` via
//  `ClipSelectionCoordinator.displayBody`), so a `maskStyle = .full` secret renders as ●●● and can't match,
//  and only the disclosed `prefix2`/`suffix4` characters are searchable. The raw decrypted title never
//  reaches this filter (the §9 leakage guarantee). Kept free of AppKit/SwiftUI so the C3 behavior is
//  unit-tested without a window.
//

import Foundation

enum PanelSearch {
    /// The selectable rows matching `query`, in their original order. An empty (or whitespace-only) query
    /// returns every row unchanged. Matching is over the masked `title` only. Use this for a flat
    /// (clip-only) list; for the unified clip+snippet list use `filterCombined` so folder headers are
    /// retained only when a child matches.
    static func filter(_ rows: [PanelRow], query: String) -> [PanelRow] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return rows }
        // Locale-aware contains: case-, diacritic- and width-insensitive (matches HistoryFilter / Finder).
        return rows.filter { $0.title.localizedStandardContains(term) }
    }

    /// Header-aware filter for the unified history+snippet list: clip and snippet rows match by
    /// title (`localizedStandardContains`); a folder-header row is kept only when at least one of the
    /// snippet rows that follow it survives. An empty query returns the rows unchanged. Clip titles are
    /// the masked `displayTitle` (C3) — the raw secret is never part of the haystack.
    static func filterCombined(_ rows: [PanelRow], query: String) -> [PanelRow] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return rows }
        var result: [PanelRow] = []
        var pendingHeader: PanelRow? // emitted lazily when its first child survives
        for row in rows {
            switch row.kind {
            case .folderHeader:
                pendingHeader = row
            case .clip, .snippet:
                guard row.title.localizedStandardContains(term) else { continue }
                if let header = pendingHeader {
                    result.append(header)
                    pendingHeader = nil
                }
                result.append(row)
            }
        }
        return result
    }
}
