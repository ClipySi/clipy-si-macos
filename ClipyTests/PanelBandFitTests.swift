//
//  PanelBandFitTests.swift
//  ClipyTests
//
//  The list-band auto-fit, exercised end-to-end: the real HistoryPanelView hosted in a
//  real FloatingPanel, with the band-fit callback wired to a SYNCHRONOUS window resize — the
//  adversarial consumer. The view MUST deliver its reports outside the layout transaction
//  (deferred + coalesced in `proposeListBandFit`): when a report fired from inside the geometry
//  callbacks, the synchronous `setFrame` nested a layout pass inside a layout pass and crashed
//  the app the moment the chips row toggled (user-reported; this test reproduced it).
//

import AppKit
import SwiftUI
import Testing
@testable import Clipy

@MainActor
@Suite struct PanelBandFitTests {
    @Test func chipsToggleResizesTheWindowWithoutCrashing() {
        let model = HistoryPanelModel()
        let rows = (0..<30).map { PanelRow.clip(UUID(), title: "row \($0)") }
        model.reset(historyRows: rows, snippetRows: [])

        let panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: FloatingPanelLayout.defaultSize))
        let view = HistoryPanelView(
            model: model,
            onSelect: { _ in },
            onCancel: {},
            onListBandDelta: { delta in
                // Synchronous resize on purpose: if a report ever fires from inside the layout
                // pass again, this nests layout-in-layout and crashes the test process.
                var frame = panel.frame
                frame.size.height += delta
                panel.setFrame(frame, display: true)
            })
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = []
        panel.installContent(hosting.view)
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }

        // Let the initial layout, the deferred band-fit reports, and the resizes CONVERGE — this
        // is also the anti-oscillation regression: without the shrink hysteresis the fit
        // ping-ponged ±2px forever and `settle` would time out at an unstable height.
        settle(panel)
        let baseHeight = panel.frame.height

        // The user's crash repro: show the category chips row. The chrome grows, so the auto-fit
        // must grow the window to keep a full page of rows — without crashing.
        model.isFilterBarOpen = true
        settle(panel)
        #expect(panel.frame.height > baseHeight)

        // Hiding the chips hands the height back (within the fit's shrink hysteresis).
        model.isFilterBarOpen = false
        settle(panel)
        #expect(abs(panel.frame.height - baseHeight) <= FloatingPanelLayout.listBandShrinkSlack + 2)
    }

    /// Pump the main run loop until the window height holds still. A fixed 1s warm-up first: the
    /// initial geometry callbacks can lag the window's first display by over half a second in the
    /// headless test session, and declaring "stable" before the first report ever lands would
    /// assert against the unfitted height. Then require a sustained quiet period (~0.3s) within a
    /// ~3s budget — an oscillating fit (the hysteresis regression) never goes quiet and fails the
    /// assertions above.
    private func settle(_ panel: FloatingPanel) {
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        var stableTicks = 0
        for _ in 0..<60 {
            let before = panel.frame.height
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            stableTicks = panel.frame.height == before ? stableTicks + 1 : 0
            if stableTicks >= 6 { return }
        }
    }
}
