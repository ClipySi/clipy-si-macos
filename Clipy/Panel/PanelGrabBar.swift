//
//  PanelGrabBar.swift
//  ClipySi — Apple Silicon rewrite
//
//  The iOS-home-indicator-style grab bar at the panel's very top: a thin, full-width
//  strip whose drag moves the whole panel (`NSWindow.performDrag(with:)` — the native window
//  drag, so Spaces/screen-edge behavior is correct), with a small centered capsule as the visual
//  cue. A REAL layout row above the search field (an overlay sank into the field's safe-area
//  band — user feedback), so it owns its own 16pt. Mouse-only by design: not focusable, not part
//  of the `search ↕ scope ↕ list` keyboard chain.
//

import AppKit
import SwiftUI

struct PanelGrabBar: View {
    var body: some View {
        PanelWindowDragArea()
            .overlay {
                Capsule()
                    .fill(.tertiary)
                    .frame(width: 36, height: 5)
                    .allowsHitTesting(false) // the drag area underneath owns the mouse
            }
            .frame(height: 16)
            .frame(maxWidth: .infinity)
    }
}

/// An NSView that hands its mouse-down to the window as a native window drag. Requires the
/// window's `isMovable == true` (`performDrag` is documented as a no-op otherwise) — FloatingPanel
/// enables it while keeping `isMovableByWindowBackground` off.
private struct PanelWindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}
