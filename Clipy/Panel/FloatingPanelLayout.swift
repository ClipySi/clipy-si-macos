//
//  FloatingPanelLayout.swift
//  ClipySi — Apple Silicon rewrite
//
//  Pure geometry for the history FloatingPanel: where to place its top-left corner so it pops up at
//  the cursor but stays fully on the screen the cursor is on. Pure value math (no AppKit window), so
//  it is unit-tested without a display (history-panel design §2.3). Screen coordinates are AppKit's
//  bottom-left origin, matching `NSEvent.mouseLocation` / `NSWindow.setFrameTopLeftPoint`.
//

import CoreGraphics

/// Which side of the panel's main column the preview pane sits on. Raw values are the persisted
/// `DefaultsKeys.panelPreviewSide` strings (Settings → General → Appearance; default right).
enum PanelPreviewSide: String, CaseIterable, Sendable {
    case right, left

    var opposite: PanelPreviewSide { self == .right ? .left : .right }
}

enum FloatingPanelLayout {
    /// Default panel content size WITHOUT the preview pane. Width is comfortable for one-line clip
    /// previews; height holds the grab bar + search field + the scope tabs + a page of rows + the
    /// footer. Grew with the layout: 360×420 → 380×460 → 380×540 (spacing) →
    /// 380×570 (118pt preview pane, tuned for minimal slack) → 380×452 when the preview became
    /// fully hide/show (570 minus the old 118pt pane) → 380×460 for the grab-bar layout
    /// row (16pt strip above the search field replacing 8pt of its old top padding) → 340×460 when
    /// the preview moved beside the list (the list column slimmed so the pane gets the room;
    /// 300 truncated titles too hard — user-tuned back up to 340).
    /// This is the BASE only: the band auto-fit below corrects the window at runtime
    /// so a full page of rows always fits (semantic fonts + the optional chips row made hand-tuned
    /// heights unreliable).
    static let defaultSize = CGSize(width: 340, height: 460)

    /// Preview-pane width (fully hidden ⇄ a 420pt rich pane — no half-collapsed strip). The pane
    /// sits BESIDE the main column (right by default, Settings-switchable), so the window grows by
    /// exactly this much horizontally and the LIST band (rows per page) is untouched. Was a 240pt
    /// bottom pane; the split is deliberately preview-heavy (340pt list / 420pt pane —
    /// the list is a picker, the pane is where you read).
    static func previewWidth(expanded: Bool) -> CGFloat { expanded ? 420 : 0 }

    /// The panel content size for a preview state: the base (no-preview) size plus exactly the
    /// pane's width (340 / 760 wide, height unchanged), so the paging/row math never changes with
    /// the preview.
    static func size(previewExpanded: Bool) -> CGSize {
        CGSize(width: defaultSize.width + previewWidth(expanded: previewExpanded),
               height: defaultSize.height)
    }

    /// Which side the preview pane should ACTUALLY open on: the preferred side when its drawing
    /// area fits the screen, the opposite side when it doesn't AND flipping is enabled AND the
    /// opposite side actually has the room (otherwise flipping would just trade one overflow for
    /// another — the origin clamp shifting the whole panel is the better fallback). `mainColumnX`
    /// is the main column's left edge in screen coordinates (the cursor/anchor x at open, the
    /// standing column edge on toggle). Pure — unit-tested without a display.
    static func resolvedPreviewSide(preferred: PanelPreviewSide,
                                    flipEnabled: Bool,
                                    mainColumnX: CGFloat,
                                    previewWidth: CGFloat,
                                    visibleFrame: CGRect) -> PanelPreviewSide {
        guard flipEnabled, previewWidth > 0 else { return preferred }
        let fits: (PanelPreviewSide) -> Bool = { side in
            switch side {
            case .right: return mainColumnX + defaultSize.width + previewWidth <= visibleFrame.maxX
            case .left: return mainColumnX - previewWidth >= visibleFrame.minX
            }
        }
        if fits(preferred) || !fits(preferred.opposite) { return preferred }
        return preferred.opposite
    }

    // MARK: - List-band auto-fit

    /// Row spacing of the list page (the LazyVStack spacing in HistoryPanelView — shared so the
    /// band math stays in lockstep with the actual layout).
    static let listRowSpacing: CGFloat = 2

    /// Total vertical padding around a page of rows inside the list band (6pt above + 6pt below).
    static let listBandPadding: CGFloat = 12

    /// The band height that fits a FULL page: `rowCount` rows of the MEASURED `rowHeight` plus
    /// inter-row spacing and the band padding. Pure — unit-tested without a display.
    static func listBandHeight(rowHeight: CGFloat, rowCount: Int) -> CGFloat {
        guard rowCount > 0 else { return 0 }
        return rowHeight * CGFloat(rowCount)
            + listRowSpacing * CGFloat(rowCount - 1)
            + listBandPadding
    }

    /// Slack the band may keep before the auto-fit reclaims it. ASYMMETRIC on purpose: a short
    /// band clips the last row (always fix), while a few px of surplus is invisible — and text
    /// row heights jitter ±1–2px with window size, so a symmetric deadband ping-pongs the window
    /// forever (reproduced in PanelBandFitTests as a 486⇄488 oscillation).
    static let listBandShrinkSlack: CGFloat = 6

    /// The whole-pixel window-height correction that makes a measured list band fit a full page
    /// ("常に itemsPerPage 行" — user requirement). Grows whenever the band is more than a pixel
    /// short; shrinks only past `listBandShrinkSlack` (hysteresis, see above); 0 for degenerate
    /// inputs (no rows measured yet).
    static func listBandDelta(measuredBandHeight: CGFloat, rowHeight: CGFloat, rowCount: Int) -> CGFloat {
        guard rowCount > 0, rowHeight > 0 else { return 0 }
        let shortfall = listBandHeight(rowHeight: rowHeight, rowCount: rowCount) - measuredBandHeight
        if shortfall > 1 { return shortfall.rounded(.up) }
        if shortfall < -listBandShrinkSlack { return shortfall.rounded(.toNearestOrAwayFromZero) }
        return 0
    }

    /// The panel's top-left origin so its frame sits at `mouseLocation` but is clamped to stay entirely
    /// within `visibleFrame`. `setFrameTopLeftPoint` interprets the point as the frame's TOP-left, so
    /// the bottom edge is `y - height`. Pure — no side effects, fully testable.
    static func originTopLeft(mouseLocation: CGPoint, panelSize: CGSize, visibleFrame: CGRect) -> CGPoint {
        var originX = mouseLocation.x
        var originY = mouseLocation.y

        // Horizontal: keep the right edge on-screen first, then guard the left (a panel wider than the
        // screen pins to the left rather than hiding its start).
        if originX + panelSize.width > visibleFrame.maxX { originX = visibleFrame.maxX - panelSize.width }
        if originX < visibleFrame.minX { originX = visibleFrame.minX }

        // Vertical: top-left y is the frame's TOP. Keep the bottom (y - height) above minY, then guard
        // the top edge (a panel taller than the screen pins to the top).
        if originY - panelSize.height < visibleFrame.minY { originY = visibleFrame.minY + panelSize.height }
        if originY > visibleFrame.maxY { originY = visibleFrame.maxY }

        return CGPoint(x: originX, y: originY)
    }
}
