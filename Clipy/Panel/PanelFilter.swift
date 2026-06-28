//
//  PanelFilter.swift
//  ClipySi — Apple Silicon rewrite
//
//  The category filter for the unified panel: a pure mapping from the filter chips
//  (All / Text / Code / Links / Images / Files / Colors) onto `PanelRow.ContentKind`. Categories
//  apply to CLIP rows only — snippets carry no content kind, so any non-All category hides the
//  snippet rows (and their folder headers). Pure functions; the model composes this between the
//  scope and the search stages.
//

import Foundation

/// One filter chip. Order = display order in the chips row.
enum PanelCategory: CaseIterable, Hashable, Sendable {
    case all, text, code, links, images, files, colors

    /// Whether a row survives this category. `.all` passes everything (incl. snippet rows).
    func matches(_ row: PanelRow) -> Bool {
        if self == .all { return true }
        guard case .clip = row.kind else { return false } // non-All: clips only
        switch self {
        case .all: return true
        case .text: return row.contentKind == .text
        case .code: return row.contentKind == .code
        case .links: return row.contentKind == .url
        case .images: return row.contentKind == .image
        case .files: return row.contentKind == .file || row.contentKind == .pdf
        case .colors: return row.contentKind == .color
        }
    }

    /// The chip's SF Symbol (mirrors the row/preview glyph mapping).
    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .text: return "text.alignleft"
        case .code: return "curlybraces"
        case .links: return "link"
        case .images: return "photo"
        case .files: return "doc"
        case .colors: return "eyedropper.halffull"
        }
    }
}

enum PanelFilter {
    /// `rows` narrowed to `category`. `.all` returns the input unchanged (no re-allocation churn).
    static func filter(_ rows: [PanelRow], category: PanelCategory) -> [PanelRow] {
        guard category != .all else { return rows }
        return rows.filter { category.matches($0) }
    }

    /// Count per category over `rows` (the chips' badges). Computed in one pass.
    static func counts(_ rows: [PanelRow]) -> [PanelCategory: Int] {
        var counts: [PanelCategory: Int] = [:]
        for category in PanelCategory.allCases {
            counts[category] = 0
        }
        for row in rows where row.isSelectable { // folder headers aren't items — don't badge them
            for category in PanelCategory.allCases where category.matches(row) {
                counts[category, default: 0] += 1
            }
        }
        return counts
    }
}
