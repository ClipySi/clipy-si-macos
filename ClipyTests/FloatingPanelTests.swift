//
//  FloatingPanelTests.swift
//  ClipyTests
//
//  Locks in the FloatingPanel *configuration* that guarantees the panel can hold keyboard focus
//  WITHOUT activating this (.accessory) app — the property the frontmost-preservation PoC depends on
//  (history-panel design §2.5). NSPanel is an AppKit model object, so this builds headlessly (no
//  display) like the NSMenu tests. The live behavioral confirmation (frontmost actually preserved on
//  a real desktop) is a run-app / dogfood check — the DEBUG readout + os_log surface it there.
//

import AppKit
import SwiftUI
import Testing
@testable import Clipy

@MainActor
@Suite struct FloatingPanelTests {
    private func makePanel() -> FloatingPanel {
        FloatingPanel(contentRect: NSRect(origin: .zero, size: FloatingPanelLayout.defaultSize))
    }

    @Test func isNonActivatingSoItDoesNotStealAppActivation() {
        let panel = makePanel()
        // `.nonactivatingPanel` is the load-bearing flag: becoming key does not activate the owning app,
        // so the previously-frontmost app stays the paste target.
        #expect(panel.styleMask.contains(.nonactivatingPanel))
    }

    @Test func canBecomeKeyButNotMain() {
        let panel = makePanel()
        // Key = can receive keyboard navigation/search. Not main = never becomes the app's main window
        // (which would activate the app). Together: focusable popup without activation.
        #expect(panel.canBecomeKey)
        #expect(panel.canBecomeMain == false)
    }

    @Test func floatsAboveOrdinaryWindows() {
        let panel = makePanel()
        #expect(panel.isFloatingPanel)
        #expect(panel.level == .floating)
        #expect(panel.hidesOnDeactivate == false) // dismissal is controller-driven (outside click + Esc)
        #expect(panel.isReleasedWhenClosed == false) // reused across opens
    }

    @Test func movableOnlyViaAnExplicitDrag() {
        let panel = makePanel()
        // The grab bar's `performDrag(with:)` is documented as a no-op when `isMovable` is false,
        // so it must be on — while background dragging stays off (the content overlaps the hidden
        // titlebar, and a body click must never start a window move). Drag bar.
        #expect(panel.isMovable)
        #expect(panel.isMovableByWindowBackground == false)
    }

    @Test func materialSurfaceIsTheWindowRoot() {
        let panel = makePanel()
        // The popover-material effect view backs the whole panel; the window itself is
        // clear/non-opaque so the behind-window blur shows. Installed content must land ON the
        // surface (not replace it).
        let surface = panel.contentView as? NSVisualEffectView
        #expect(surface?.material == .popover)
        #expect(surface?.blendingMode == .behindWindow)
        #expect(panel.isOpaque == false)
        #expect(panel.backgroundColor == .clear)
        let content = NSView()
        panel.installContent(content)
        #expect(content.superview === surface)
    }

    @Test func escRoutesToOnCancel() {
        let panel = makePanel()
        var cancelled = false
        panel.onCancel = { cancelled = true }
        panel.cancelOperation(nil) // AppKit sends this to the key window on Esc
        #expect(cancelled)
    }

    @Test func panelContentDoesNotCollapseBelowDefaultSize() {
        // Regression: `NSHostingController` sizes the panel window to the SwiftUI *fitting* size. Without
        // a size floor, the narrow search field + empty state collapse it to a ~76×160 sliver — the panel
        // "opens" but is too small to see. Empty history is the worst case (no wide List to hold the
        // width). The hosted content must report a fitting size at least the panel's default.
        let model = HistoryPanelModel() // no rows
        let hosting = NSHostingController(
            rootView: HistoryPanelView(model: model, onSelect: { _ in }, onCancel: {}))
        hosting.view.layoutSubtreeIfNeeded()
        let fitting = hosting.view.fittingSize
        #expect(fitting.width >= FloatingPanelLayout.defaultSize.width)
        #expect(fitting.height >= FloatingPanelLayout.defaultSize.height)
    }
}
