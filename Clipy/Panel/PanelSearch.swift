//
//  PanelSearch.swift
//  ClipySi — Apple Silicon rewrite
//
//  Pure text search for the history FloatingPanel (history-panel design §4.1 / C3), and — via
//  `matchesTitle` — the one predicate the History Manager's scan shares (M-UI.11 P5): locale-aware
//  `localizedStandardContains`, whitespace-trimmed, empty query ⇒ all rows. Crucially the panel haystack is `PanelRow.title`,
//  which is the *masked* `displayTitle` (built by `ClipSelectionCoordinator.historyRows()` via
//  `ClipSelectionCoordinator.displayBody`), so a `maskStyle = .full` secret renders as ●●● and can't match,
//  and only the disclosed `prefix2`/`suffix4` characters are searchable. The raw decrypted title never
//  reaches this filter (the §9 leakage guarantee). Kept free of AppKit/SwiftUI so the C3 behavior is
//  unit-tested without a window.
//

import Foundation

enum PanelSearch {
    /// THE query normalization — whitespace-trimmed; empty means "no narrowing". Every holder
    /// of a query identity (the model's scan stamp, the controller's scan request, this
    /// filter) normalizes through here, so "note" and "note " can never count as different
    /// searches anywhere (M-UI.11 P4 review: a drifted trim site either re-scans a whole
    /// window for a whitespace keystroke or coalesces two distinct queries).
    static func normalize(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// THE single-title match — locale-aware contains (case-, diacritic- and width-insensitive;
    /// matches Finder). `term` must already be normalized. Every text search in the app funnels
    /// through this one predicate: the panel's in-memory tier and progressive scan (M-UI.11
    /// P4) via `matches(_:term:)`, and the History Manager's scan over its searchable titles
    /// (M-UI.11 P5) — so no two search surfaces can disagree on what "contains" means.
    static func matchesTitle(_ title: String, term: String) -> Bool {
        term.isEmpty || title.localizedStandardContains(term)
    }

    /// The panel's single-row match — the masked `title` only (§9 leakage guarantee).
    static func matches(_ row: PanelRow, term: String) -> Bool {
        matchesTitle(row.title, term: term)
    }

    /// The selectable rows matching `query`, in their original order. An empty (or whitespace-only) query
    /// returns every row unchanged. Use this for a flat (clip-only) list; for the unified
    /// clip+snippet list use `filterCombined` so folder headers are retained only when a child matches.
    static func filter(_ rows: [PanelRow], query: String) -> [PanelRow] {
        let term = normalize(query)
        guard !term.isEmpty else { return rows }
        return rows.filter { matches($0, term: term) }
    }

    /// Header-aware filter for the unified history+snippet list: clip and snippet rows match by
    /// title; a folder-header row is kept only when at least one of the snippet rows that
    /// follow it survives. An empty query returns the rows unchanged. Clip titles are the
    /// masked `displayTitle` (C3) — the raw secret is never part of the haystack.
    static func filterCombined(_ rows: [PanelRow], query: String) -> [PanelRow] {
        let term = normalize(query)
        guard !term.isEmpty else { return rows }
        var result: [PanelRow] = []
        var pendingHeader: PanelRow? // emitted lazily when its first child survives
        for row in rows {
            switch row.kind {
            case .folderHeader:
                pendingHeader = row
            case .clip, .snippet:
                guard matches(row, term: term) else { continue }
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
