//
//  FloatingPanel.swift
//  ClipySi — Apple Silicon rewrite
//
//  The non-activating NSPanel shell for the rich/search history browser (DESIGN.md §4.2 /
//  history-panel design §2.1). `.nonactivatingPanel` is load-bearing: the panel can become key to
//  receive keyboard navigation WITHOUT activating this (.accessory) app, so the previously-frontmost
//  app stays the paste target (history-panel design §2.5). AppKit-bound → `@MainActor`.
//

import AppKit

@MainActor
final class FloatingPanel: NSPanel {
    /// Invoked when the user presses Esc (AppKit routes Esc to `cancelOperation(_:)` on the key
    /// window). The controller orders the panel out.
    var onCancel: (() -> Void)?

    /// The panel's translucent backing (Golden Gate alignment): the `.popover` material —
    /// the idiom every transient anchored surface uses — blurred against whatever is BEHIND the
    /// window. On macOS 26+ the same material renders in its refreshed style (and tracks the macOS
    /// 27 transparency slider) with no availability gate. True Liquid Glass lensing would be
    /// `NSGlassEffectView` (26+) — deliberately deferred to the Xcode-27 stage for evaluation.
    private let surface = NSVisualEffectView()

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        // Dismissal is driven explicitly by the controller (outside-click monitor + Esc), not by app
        // deactivation — a non-activating accessory app never really "deactivates" the way a regular
        // app does, so relying on `hidesOnDeactivate` here would be unreliable.
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false   // we explicitly makeKey for keyboard navigation
        isMovableByWindowBackground = false
        // Movable, but ONLY via an explicit drag: the top grab bar starts `performDrag(with:)`
        // (a no-op when `isMovable` is false), while `isMovableByWindowBackground = false` keeps
        // body clicks from dragging — the content fills under the hidden titlebar, so background
        // dragging would fight the search field (drag bar; previously fully immovable).
        isMovable = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        isReleasedWhenClosed = false     // reused across opens (same policy as Settings/About windows)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        animationBehavior = .utilityWindow
        // Material surface: the effect view is the window's root view; the window itself goes
        // clear/non-opaque so the behind-window blur is what shows. The `.titled` frame keeps
        // masking the content to the system corner radius, and the window shadow stays.
        surface.material = .popover
        surface.blendingMode = .behindWindow
        surface.state = .active
        contentView = surface
        isOpaque = false
        backgroundColor = .clear
    }

    /// Install the SwiftUI content over the material surface, pinned to its edges. Replaces the
    /// `contentViewController =` path — assigning a content view controller would swap the effect
    /// view out of the window root. Safe-area + first-responder behavior are unchanged (the hosted
    /// view sits at the exact geometry the content view controller's view used to occupy).
    func installContent(_ view: NSView) {
        // Idempotent (review): a repeat call replaces the content instead of silently stacking a
        // second pinned subview (+ constraints) over the first.
        surface.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            view.topAnchor.constraint(equalTo: surface.topAnchor),
            view.bottomAnchor.constraint(equalTo: surface.bottomAnchor)
        ])
    }

    // Required so the panel can hold keyboard focus for navigation/search…
    override var canBecomeKey: Bool { true }
    // …without ever becoming the app's main window (which would activate the app and steal frontmost).
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
