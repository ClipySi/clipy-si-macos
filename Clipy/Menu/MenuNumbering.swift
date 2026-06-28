//
//  MenuNumbering.swift
//  ClipySi — Apple Silicon rewrite
//
//  Pure, `Sendable` port of the original `MenuManager`'s numbering/title arithmetic
//  (`repos/Clipy/Clipy/Sources/Managers/MenuManager.swift`). Kept free of AppKit and
//  `UserDefaults` so the fiddly edge cases are unit-testable without a display:
//    • list numbering start (0 vs 1),
//    • the optional "N. " prefix,
//    • the first-line + UTF-16 title trim.
//
//  Used by the snippet section of the status menu and (for the numbering start) by the history
//  FloatingPanel's `PanelPaging`. The history-specific helpers (⌘N key equivalents, per-folder
//  `listNumber` wrap, "lo - hi" folder labels) were retired with the NSMenu history rendering
//  — the panel pages instead of using inline/folder groups.
//

import Foundation

enum MenuNumbering {
    /// Original `shortenSymbol`, appended when a title is trimmed.
    static let shortenSymbol = "..."

    /// `firstIndexOfMenuItems()` — list numbering starts at 0 or 1 (MenuManager.swift:464-466).
    static func firstIndex(startWithZero: Bool) -> Int {
        startWithZero ? 0 : 1
    }

    /// `menuItemTitle` (MenuManager.swift:207-209): optional "N. " prefix.
    static func menuItemTitle(_ title: String, listNumber: Int, markedWithNumbers: Bool) -> String {
        markedWithNumbers ? "\(listNumber). \(title)" : title
    }

    /// `trimTitle` (MenuManager.swift:240-260): trim surrounding whitespace/newlines, keep only the
    /// **first line**, then cap to `maxLength` **UTF-16** units, replacing the tail with "…".
    /// `maxLength` is floored at `shortenSymbol.count` so the cap can never go negative.
    static func trimTitle(_ title: String?, maxLength: Int) -> String {
        guard let title else { return "" }
        let theString = title.trimmingCharacters(in: .whitespacesAndNewlines) as NSString

        var lineStart = 0, lineEnd = 0, contentsEnd = 0
        theString.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
                               for: NSRange(location: 0, length: 0))
        var titleString = (lineEnd == theString.length) ? theString as String
                                                        : theString.substring(to: contentsEnd)

        var cap = maxLength
        if cap < shortenSymbol.count { cap = shortenSymbol.count }
        if titleString.utf16.count > cap {
            titleString = (titleString as NSString).substring(to: cap - shortenSymbol.count) + shortenSymbol
        }
        return titleString
    }
}
