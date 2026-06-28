//
//  PanelStyle.swift
//  ClipySi — Apple Silicon rewrite
//
//  Shared visual constants for the unified FloatingPanel. The panel's *accent* (active scope tab
//  + row-selection fill) is user-chosen — see `PanelAccent` — and threaded in as a `Color`, deliberately
//  INDEPENDENT of the system accent so the panel reads the same on every machine. The constants here are
//  the accent-independent bits (the on-selection foregrounds + the highlight corner radius).
//

import SwiftUI

enum PanelStyle {
    /// Foreground on top of a filled selection — white reads cleanly on every accent's fill.
    static let selectedForeground = Color.white

    /// Secondary foreground on a selected row (number, glyph) — slightly dimmed white. Kept as a
    /// fixed white in the token audit: HIG's "content on a filled tint" is the white
    /// hierarchy, and the selection fill underneath is always the opaque accent.
    static let selectedSecondaryForeground = Color.white.opacity(0.85)

    /// Corner radius of the row-selection highlight.
    static let selectionCornerRadius: CGFloat = 7

    /// Darkening layered over the accent in the row-selection fill: the system
    /// palette's light-mode green/teal/orange are too bright for white-on-fill (~2.1–2.6:1); a
    /// uniform shade restores ≥3:1 on every accent in both appearances while keeping the white
    /// foreground — Apple's own filled-selection convention.
    static let selectionShade = Color.black.opacity(0.25)
}
