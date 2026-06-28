//
//  FloatingPanelLayoutTests.swift
//  ClipyTests
//
//  Pure geometry for the history FloatingPanel's cursor placement — clamps the popup so it stays
//  fully on the screen the cursor is on (history-panel design §2.3). No display needed.
//

import CoreGraphics
import Testing
@testable import Clipy

@Suite struct FloatingPanelLayoutTests {
    // A 1000×800 screen with origin at (0, 0); panel is 360×420 (the default size).
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let size = CGSize(width: 360, height: 420)

    @Test func placesTopLeftAtCursorWhenFullyOnScreen() {
        // Cursor well inside: top-left == cursor (frame fits, no clamping).
        let origin = FloatingPanelLayout.originTopLeft(
            mouseLocation: CGPoint(x: 300, y: 600), panelSize: size, visibleFrame: screen)
        #expect(origin == CGPoint(x: 300, y: 600))
    }

    @Test func clampsRightEdge() {
        // Cursor near the right edge: x pulled left so x + width == maxX.
        let origin = FloatingPanelLayout.originTopLeft(
            mouseLocation: CGPoint(x: 900, y: 600), panelSize: size, visibleFrame: screen)
        #expect(origin.x == 640) // maxX(1000) - width(360); literal avoids a Swift Testing inference quirk
        #expect(origin.y == 600)
    }

    @Test func clampsLeftEdgeWhenPanelWiderThanScreen() {
        let narrow = CGRect(x: 0, y: 0, width: 200, height: 800) // narrower than the 360 panel
        let origin = FloatingPanelLayout.originTopLeft(
            mouseLocation: CGPoint(x: 150, y: 600), panelSize: size, visibleFrame: narrow)
        #expect(origin.x == 0) // pinned to the left rather than hiding the start
    }

    @Test func clampsBottomEdge() {
        // Cursor low: bottom (y - height) would go below minY, so y is raised to minY + height.
        let origin = FloatingPanelLayout.originTopLeft(
            mouseLocation: CGPoint(x: 300, y: 100), panelSize: size, visibleFrame: screen)
        #expect(origin.y == 420) // minY(0) + height(420)
        #expect(origin.x == 300)
    }

    @Test func clampsTopEdgeWhenPanelTallerThanScreen() {
        let shortScreen = CGRect(x: 0, y: 0, width: 1000, height: 300) // shorter than the 420 panel
        let origin = FloatingPanelLayout.originTopLeft(
            mouseLocation: CGPoint(x: 300, y: 290), panelSize: size, visibleFrame: shortScreen)
        #expect(origin.y == 300) // pinned to the top edge (maxY)
    }

    @Test func respectsNonZeroScreenOrigin() {
        // A second display offset to the right: clamping uses minX/maxX, not 0.
        let right = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        let origin = FloatingPanelLayout.originTopLeft(
            mouseLocation: CGPoint(x: 1950, y: 600), panelSize: size, visibleFrame: right)
        #expect(origin.x == 1640) // maxX(2000) - width(360)
    }

    // MARK: - Preview expand/collapse sizing (a SIDE pane since the right/left placement)

    @Test func previewSizeIsBasePlusExactlyThePaneWidth() {
        let hidden = FloatingPanelLayout.size(previewExpanded: false)
        let shown = FloatingPanelLayout.size(previewExpanded: true)
        // Hidden = the base (no-preview) size — the pane is FULLY hidden, no half-collapsed strip
        // — and the window delta == the pane's width (height untouched), so the list band (rows
        // per page) is untouched by the toggle.
        #expect(FloatingPanelLayout.previewWidth(expanded: false) == 0)
        #expect(hidden == FloatingPanelLayout.defaultSize)
        #expect(shown.height == hidden.height)
        #expect(shown.width - hidden.width == FloatingPanelLayout.previewWidth(expanded: true))
        #expect(shown.width == 760) // the 340pt list column + the 420pt rich pane
    }

    @Test func expandingNearTheRightEdgeShiftsThePanelLeftNotOffScreen() {
        // With the edge flip OFF the controller re-clamps with the main column's top-left as the
        // desired point. Near the right edge the wider frame would spill past maxX, so the whole
        // panel is pulled left by the overshoot.
        let expanded = FloatingPanelLayout.size(previewExpanded: true)
        let origin = FloatingPanelLayout.originTopLeft(
            mouseLocation: CGPoint(x: 900, y: 600), panelSize: expanded, visibleFrame: screen)
        #expect(origin.x == 240) // maxX(1000) - width(760)
        #expect(origin.y == 600)
    }

    // MARK: - Preview side resolution (right by default, edge flip to the side that has room)

    @Test func keepsThePreferredSideWhenItFits() {
        // Main column at x=300 (base 340 wide): right pane ends at 940 ≤ 1000 — fits, no flip.
        let side = FloatingPanelLayout.resolvedPreviewSide(
            preferred: .right, flipEnabled: true,
            mainColumnX: 300, previewWidth: 300, visibleFrame: screen)
        #expect(side == .right)
    }

    @Test func flipsToTheLeftWhenTheRightEdgeHasNoRoom() {
        // Main column at x=500: right pane would end at 1140 > 1000, while the left side has the
        // full 300pt (500 − 300 ≥ 0) → flip.
        let side = FloatingPanelLayout.resolvedPreviewSide(
            preferred: .right, flipEnabled: true,
            mainColumnX: 500, previewWidth: 300, visibleFrame: screen)
        #expect(side == .left)
    }

    @Test func flipsToTheRightWhenTheLeftEdgeHasNoRoom() {
        // Main column at x=100: a left pane would start at −200 < 0; the right side fits.
        let side = FloatingPanelLayout.resolvedPreviewSide(
            preferred: .left, flipEnabled: true,
            mainColumnX: 100, previewWidth: 300, visibleFrame: screen)
        #expect(side == .right)
    }

    @Test func staysOnThePreferredSideWhenFlippingIsDisabled() {
        // Same no-room-on-the-right geometry as the flip test, but the setting is OFF → keep
        // right (the origin clamp shifts the whole panel inward instead).
        let side = FloatingPanelLayout.resolvedPreviewSide(
            preferred: .right, flipEnabled: false,
            mainColumnX: 500, previewWidth: 300, visibleFrame: screen)
        #expect(side == .right)
    }

    @Test func staysOnThePreferredSideWhenNeitherSideFits() {
        // A screen narrower than main+pane on either side: flipping would just trade one overflow
        // for another, so the preferred side wins and the clamp handles the rest.
        let narrow = CGRect(x: 0, y: 0, width: 500, height: 800)
        let side = FloatingPanelLayout.resolvedPreviewSide(
            preferred: .right, flipEnabled: true,
            mainColumnX: 60, previewWidth: 300, visibleFrame: narrow)
        #expect(side == .right)
    }

    @Test func collapsedPaneNeverFlips() {
        // previewWidth 0 (pane hidden): the preference comes straight back even at the very edge.
        let side = FloatingPanelLayout.resolvedPreviewSide(
            preferred: .left, flipEnabled: true,
            mainColumnX: 0, previewWidth: 0, visibleFrame: screen)
        #expect(side == .left)
    }

    // MARK: - List-band auto-fit (a full page of rows must always fit)

    @Test func listBandHeightFitsAFullPage() {
        // 10 rows × 32 + 9 gaps × 2 + 12 band padding.
        #expect(FloatingPanelLayout.listBandHeight(rowHeight: 32, rowCount: 10) == 350)
        #expect(FloatingPanelLayout.listBandHeight(rowHeight: 32, rowCount: 0) == 0)
    }

    @Test func listBandDeltaGrowsShrinksAndDeadbands() {
        // Band too short by half a row (9 of 10 rows visible) → grow.
        #expect(FloatingPanelLayout.listBandDelta(measuredBandHeight: 334, rowHeight: 32, rowCount: 10) == 16)
        // Chips row hidden again → the band is way too tall → shrink it back.
        #expect(FloatingPanelLayout.listBandDelta(measuredBandHeight: 384, rowHeight: 32, rowCount: 10) == -34)
        // Sub-pixel measurement jitter stays inside the deadband (no window oscillation).
        #expect(FloatingPanelLayout.listBandDelta(measuredBandHeight: 350.4, rowHeight: 32, rowCount: 10) == 0)
        // HYSTERESIS: a small surplus is kept (row heights jitter ±2px with window size — a
        // symmetric deadband ping-ponged the window 486⇄488 forever)…
        #expect(FloatingPanelLayout.listBandDelta(measuredBandHeight: 352, rowHeight: 32, rowCount: 10) == 0)
        #expect(FloatingPanelLayout.listBandDelta(measuredBandHeight: 356, rowHeight: 32, rowCount: 10) == 0)
        // …while a shortfall past one pixel ALWAYS grows (a clipped row is the bug), rounding up.
        #expect(FloatingPanelLayout.listBandDelta(measuredBandHeight: 347.5, rowHeight: 32, rowCount: 10) == 3)
        // Degenerate inputs (nothing measured / no page) never move the window.
        #expect(FloatingPanelLayout.listBandDelta(measuredBandHeight: 350, rowHeight: 0, rowCount: 10) == 0)
        #expect(FloatingPanelLayout.listBandDelta(measuredBandHeight: 350, rowHeight: 32, rowCount: 0) == 0)
    }
}
