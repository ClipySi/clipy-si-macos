//
//  SettingsMapping.swift
//  ClipySi — Apple Silicon rewrite
//
//  Pure, view-independent mappings between the original-compatible UserDefaults values and the
//  Settings UI controls. These are the genuinely new logic in the Settings panes (the raw
//  `@Shared(.appStorage)` round-trips just re-assert keys), so they live here as testable
//  functions rather than inline in a SwiftUI `View`. See the design §4 / §6 (delta 16).
//
//  Original references: the General pane bound `kCPYPrefReorderClipsAfterPasting` (a Bool) to an
//  NSPopUpButton `selectedIndex`, relying on AppKit's Bool↔Int bridging (false=0 "Date Created",
//  true=1 "Last Used"); `kCPYPrefShowStatusItemKey` is an Int 0/1/2; `kCPYPrefMaxHistorySizeKey`
//  had a number formatter with a minimum of 1.
//

import Foundation

enum SettingsMapping {
    // MARK: - Generic range clamp for free-form numeric fields
    //
    // Every Settings numeric field is a TextField (accepts any Int) paired with a bounded Stepper.
    // The Stepper's `range` bounds only its own +/- buttons; a value typed straight into the
    // TextField bypasses it. So after an edit we re-apply BOTH bounds of the field's declared range —
    // the lower bound is the original's number-formatter minimum, the upper bound matches the Stepper.

    static func clamp(_ raw: Int, to range: ClosedRange<Int>) -> Int {
        min(range.upperBound, max(range.lowerBound, raw))
    }

    // MARK: - Max history size (clamp into 1...100_000)
    //
    // Lower bound matches the original's number-formatter minimum of 1; the upper bound (matching the
    // GeneralPane Stepper) caps what a free-form TextField edit can persist, so a typed 999_999_999
    // can't disable history trimming (CaptureService) and let the encrypted DB grow unbounded.

    static let minHistorySize = 1
    static let maxHistorySize = 100_000

    static func clampMaxHistorySize(_ raw: Int) -> Int {
        clamp(raw, to: minHistorySize...maxHistorySize)
    }

    // MARK: - History panel items-per-page (clamp into 5...20)
    //
    // Shared between the MenuPane field (Stepper bound) and AppSettings (read-side defense), so a value
    // written by an older build or hand-edited defaults can't make the panel show 0 or a huge page.

    static let historyPanelItemsPerPageRange = 5...20

    static func clampHistoryPanelItemsPerPage(_ raw: Int) -> Int {
        clamp(raw, to: historyPanelItemsPerPageRange)
    }

    /// When an import pushes the history above the cap, the limit to offer the user: the smallest
    /// multiple of 10 strictly greater than `total` (so existing + imported clips all fit, with a
    /// little headroom), clamped into the allowed range. e.g. 60 → 70, 61 → 70, 70 → 80.
    static func suggestedHistoryLimit(forTotal total: Int) -> Int {
        let nextMultipleOfTen = (max(0, total) / 10 + 1) * 10
        return clampMaxHistorySize(nextMultipleOfTen)
    }

    // MARK: - Sort history order popup ↔ newest-first Bool
    //
    // Popup index 0 = "Date Created", 1 = "Last Used". The stored value is the Bool
    // `historySortNewestFirst` (true ⇒ newest `createdAt` first ⇒ "Last Used"), reproducing the
    // original's Bool-as-selectedIndex binding. It is purely a *display order* — moving a pasted
    // clip back to the top is the separate `moveClipToTopOnPaste` switch (DefaultsKeys/PasteService).

    static func sortOrderIndex(newestFirst: Bool) -> Int {
        newestFirst ? 1 : 0
    }

    static func sortNewestFirst(fromIndex index: Int) -> Bool {
        index == 1
    }

    // Menu-pane numeric fields (inline count, items-per-folder, title length, tooltip length,
    // thumbnail width/height) no longer need bespoke clamps: `IntFieldRow` clamps each to its own
    // declared range via `clamp(_:to:)`, whose lower bound encodes the original's formatter minimum
    // (0 for the inline count — it may be empty — and 1 for the rest).

    // MARK: - Status-bar icon style (0 = None, 1 = Black, 2 = White)
    //
    // Tolerate a corrupt/out-of-range stored Int by falling back to the registered default (1),
    // mirroring how the rest of the settings layer clamps raw values (see `clamp(_:to:)`).

    static let statusItemStyleRange = 0...2
    static let defaultStatusItemStyle = 1

    static func clampStatusItemStyle(_ raw: Int) -> Int {
        statusItemStyleRange.contains(raw) ? raw : defaultStatusItemStyle
    }

    /// Asset-catalog image name for the menu-bar status item, or `nil` when the item should be hidden.
    /// Mirrors the original's two distinct *template* glyphs: style 1 ("Black") = the filled
    /// glyph, style 2 ("White") = the outline glyph (the original's `statusbar_menu_black`
    /// was a filled clipboard, `statusbar_menu_white` an outline one; both are template images, so
    /// the menu bar tints them for light/dark — the Black/White choice selects the *shape*, not the
    /// colour). Out-of-range falls back to the filled default, matching `clampStatusItemStyle`.
    static func statusItemImageName(forStyle raw: Int) -> String? {
        switch clampStatusItemStyle(raw) {
        case 0: return nil
        case 2: return "StatusBarIconOutline"  // outline — legacy "white"
        default: return "StatusBarIconFilled"  // filled — legacy "black" (and the default)
        }
    }
}
