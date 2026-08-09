//
//  HistoryPanelController.swift
//  ClipySi — Apple Silicon rewrite
//
//  Owns the history FloatingPanel and its presentation lifecycle: refill the list, pop up at the
//  cursor, dismiss on an outside click or Esc, and — crucially — snapshot the frontmost app BEFORE
//  the panel takes key so the paste service keeps the right paste target (history-panel design
//  §2.2/§2.5). Selection (click/Return) routes through `ClipSelectionCoordinator` (auth-gated paste).
//  AppKit-bound → `@MainActor`. Search + paging arrive in later slices.
//

import AppKit
import OSLog
import SwiftUI

@MainActor
final class HistoryPanelController {
    private let panel: FloatingPanel
    private let hosting: NSHostingController<HistoryPanelView>
    private let model = HistoryPanelModel()
    private let coordinator: ClipSelectionCoordinator
    /// Lazy image/file payload loading for the rich preview. Cleared on every hide so no
    /// decrypted thumbnail outlives the panel being on screen.
    private let previewProvider: PanelPreviewContentProvider
    private var clickMonitor: Any?
    /// Window-height correction so a FULL page of rows always fits the list band (auto-fit):
    /// semantic fonts and the optional chips row made the hand-tuned base height
    /// unreliable. Resolved ABSOLUTELY from each view report against the current frame (not
    /// accumulated), so transient mid-animation reports converge on one target.
    private var listBandAdjustment: CGFloat = 0
    /// Re-entrancy latch: our own `setFrame` triggers layout, which re-fires the view's band
    /// measurements synchronously — those echoes are dropped.
    private var isApplyingPanelSize = false
    /// Which side the preview pane occupies in the window's CURRENT frame — nil while the pane is
    /// collapsed. The resize math needs it to recover the main column's standing left edge (a
    /// left-side pane shifts the window edge, not the list), so toggling/collapsing keeps the list
    /// in place.
    private var appliedPaneSide: PanelPreviewSide?

    #if DEBUG
    private static let log = Logger(subsystem: "io.github.ponponusa.clipysi", category: "panel")
    #endif

    /// Invoked just before the panel is shown — AppDelegate wires this to `PasteService.captureFrontmost()`
    /// so the paste target is snapshotted before our panel takes key (history-panel design §2.2).
    var onWillShow: (() -> Void)?

    /// The chosen clip's paste action — AppDelegate wires this to `PasteService.paste(clipID:)`. Forwarded
    /// to the coordinator, which applies the masked-secret auth gate first.
    var onSelectClip: ((Clip.ID) -> Void)? {
        get { coordinator.onSelectClip }
        set { coordinator.onSelectClip = newValue }
    }

    /// The chosen snippet's paste action — AppDelegate wires this to `PasteService.paste(snippetID:)`.
    /// Snippets are plaintext, so the coordinator does not gate them.
    var onSelectSnippet: ((Snippet.ID) -> Void)? {
        get { coordinator.onSelectSnippet }
        set { coordinator.onSelectSnippet = newValue }
    }

    // The management-overlay actions (gear/⌘M). AppDelegate wires these to the same handlers the NSMenu
    // used; the controller hides the panel before invoking each (a window must open in front of the
    // floating panel). `onQuit` is `NSApp.terminate`, applied in `makeActions` (no callback needed).
    var onOpenSettings: (() -> Void)?
    var onOpenAbout: (() -> Void)?
    var onOpenSnippetEditor: (() -> Void)?
    var onOpenHistoryManager: (() -> Void)?
    var onClearHistory: (() -> Void)?

    /// `blobStore` powers the rich preview's lazy image/file loading; nil (tests) keeps the
    /// inert provider, which never decrypts anything.
    init(coordinator: ClipSelectionCoordinator = ClipSelectionCoordinator(),
         blobStore: EncryptedBlobStore? = nil) {
        self.coordinator = coordinator
        previewProvider = blobStore.map(PanelPreviewContentProvider.live(blobStore:)) ?? .inert
        panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: FloatingPanelLayout.defaultSize))
        hosting = NSHostingController(
            rootView: HistoryPanelView(model: model, onSelect: { _ in }, onCancel: {}))
        // The controller is the ONLY authority over the window's size (init rect, show()'s
        // setContentSize, applyPreviewSize's animated setFrame). Default sizingOptions let the
        // hosting controller ALSO push SwiftUI's min/fitting size onto the window as an AppKit
        // constraint — which can fight the preview-toggle animation (review: a post-animation
        // snap past the setFrame target). Empty options end that feedback entirely; the view's
        // own minHeight floor still shapes the CONTENT layout.
        hosting.sizingOptions = []
        // Over the panel's material surface, NOT as contentViewController — that would
        // replace the NSVisualEffectView as the window's root view.
        panel.installContent(hosting.view)
        panel.onCancel = { [weak self] in self?.handleCancel() }
        // Reassign now that `self` is fully initialized so the row + management callbacks can reach the
        // controller. `makeActions` reads the on* callbacks lazily (at click time), so AppDelegate can
        // wire them after construction.
        hosting.rootView = HistoryPanelView(
            model: model,
            onSelect: { [weak self] row in self?.select(row) },
            onCancel: { [weak self] in self?.handleCancel() },
            actions: makeActions(),
            onTogglePreview: { [weak self] in self?.togglePreview() },
            previewProvider: previewProvider,
            onListBandDelta: { [weak self] delta in self?.fitListBand(reportedDelta: delta) })
    }

    /// Apply a band-fit report from the view: the band wants to be `delta` taller (10
    /// rows must fit) — convert that into an ABSOLUTE adjustment over the layout's base height
    /// using the panel's CURRENT content height, so a report computed from a transient
    /// mid-animation frame still lands on the same final target instead of compounding.
    private func fitListBand(reportedDelta delta: CGFloat) {
        guard !isApplyingPanelSize else { return }
        let current = panel.contentRect(forFrameRect: panel.frame).size.height
        // The side preview pane changes the window's WIDTH only, so the band base is always the
        // default height.
        let base = FloatingPanelLayout.defaultSize.height
        let target = current + delta - base
        guard abs(target - listBandAdjustment) >= 1 else { return }
        listBandAdjustment = target
        applyPanelSize(animated: false)
    }

    /// Show/hide the preview pane (footer toggle / ⌘P): flip the model state, persist the preference
    /// (NOT per-open — preview visibility is a steady user taste), and resize the panel window in
    /// place so the main column keeps its size and place; only the pane appears/disappears. NOT
    /// animated: SwiftUI inserts/removes the pane in the current transaction while an animated
    /// `setFrame` lags behind it, which read as the main column stretching (user-reported) — the
    /// instant resize lands both in the same frame. Showing kicks off the highlighted row's
    /// payload; hiding destroys everything decoded (a hidden preview holds no decrypted thumbnails).
    private func togglePreview() {
        model.isPreviewExpanded.toggle()
        UserDefaults.standard.set(model.isPreviewExpanded, forKey: DefaultsKeys.panelPreviewExpanded)
        if model.isPreviewExpanded {
            previewProvider.request(model.selectedRow)
        } else {
            previewProvider.clear()
        }
        applyPanelSize(animated: false)
    }

    /// Resize the panel for the current preview state + the band-fit adjustment, keeping the MAIN
    /// COLUMN's top-left anchored (the pane grows/shrinks sideways from it — a left-side pane moves
    /// the window edge, never the list) and re-clamping to the screen so expanding near an edge
    /// shifts the panel inward instead of spilling off-screen. Re-resolves the pane's side first
    /// (preference + edge flip), so a toggle near the screen edge opens on the side that has room.
    private func applyPanelSize(animated: Bool) {
        isApplyingPanelSize = true
        defer { isApplyingPanelSize = false }
        let expandedPaneWidth = FloatingPanelLayout.previewWidth(expanded: true)
        let mainColumnX = panel.frame.minX + (appliedPaneSide == .left ? expandedPaneWidth : 0)
        let visibleFrame = (panel.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let side = resolvePreviewSide(mainColumnX: mainColumnX, visibleFrame: visibleFrame)
        var contentSize = FloatingPanelLayout.size(previewExpanded: model.isPreviewExpanded)
        contentSize.height += listBandAdjustment
        let frameSize = panel.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize)).size
        let pane = model.isPreviewExpanded && side == .left ? expandedPaneWidth : 0
        let topLeft = CGPoint(x: mainColumnX - pane, y: panel.frame.maxY)
        let clamped = FloatingPanelLayout.originTopLeft(
            mouseLocation: topLeft,
            panelSize: frameSize,
            visibleFrame: visibleFrame)
        let frame = NSRect(x: clamped.x, y: clamped.y - frameSize.height,
                           width: frameSize.width, height: frameSize.height)
        appliedPaneSide = model.isPreviewExpanded ? side : nil
        panel.setFrame(frame, display: true, animate: animated)
    }

    /// Resolve which side the preview pane renders on for the current preference + edge-flip
    /// setting, write it into the model (the view renders from there), and return it. With the
    /// pane collapsed the preferred side comes straight back (it still drives the footer glyph).
    private func resolvePreviewSide(mainColumnX: CGFloat, visibleFrame: CGRect) -> PanelPreviewSide {
        let defaults = UserDefaults.standard
        let preferred = PanelPreviewSide(
            rawValue: defaults.string(forKey: DefaultsKeys.panelPreviewSide) ?? "") ?? .right
        let side = FloatingPanelLayout.resolvedPreviewSide(
            preferred: preferred,
            flipEnabled: defaults.bool(forKey: DefaultsKeys.panelPreviewEdgeFlip),
            mainColumnX: mainColumnX,
            previewWidth: FloatingPanelLayout.previewWidth(expanded: model.isPreviewExpanded),
            visibleFrame: visibleFrame)
        model.previewSide = side
        return side
    }

    /// Esc handling: while the management overlay is up, Esc closes ONLY the overlay (the panel stays);
    /// otherwise it dismisses the panel. Routing this through the controller — not just the overlay's own
    /// `.onKeyPress` — guarantees the "Esc closes overlay only" invariant even if the overlay card hasn't
    /// won key focus, since `FloatingPanel.cancelOperation` would otherwise hide the whole panel (review #1).
    private func handleCancel() {
        if model.isManagementOpen {
            model.isManagementOpen = false
        } else {
            hide()
        }
    }

    /// Build the management-overlay actions. Each hides the panel first (a window must open in front of
    /// the floating panel, and the overlay shouldn't linger), then invokes the wired app handler.
    private func makeActions() -> PanelActions {
        PanelActions(
            editSnippets: { [weak self] in self?.runManagement { self?.onOpenSnippetEditor?() } },
            openHistory: { [weak self] in self?.runManagement { self?.onOpenHistoryManager?() } },
            openSettings: { [weak self] in self?.runManagement { self?.onOpenSettings?() } },
            openAbout: { [weak self] in self?.runManagement { self?.onOpenAbout?() } },
            clearHistory: { [weak self] in self?.runManagement { self?.onClearHistory?() } },
            quit: { [weak self] in self?.runManagement { NSApp.terminate(nil) } })
    }

    /// Hide the panel, then run the action. Hiding first dismisses the overlay and frees the floating
    /// panel so a Settings/About/Snippet/History window (or the Clear-History alert) appears in front.
    private func runManagement(_ body: @escaping () -> Void) {
        hide()
        body()
    }

    var isVisible: Bool { panel.isVisible }

    /// Toggle at the cursor with the unified (All) scope — the history hotkey (⌃⌘V). A second press
    /// while visible dismisses it.
    func toggle() {
        if isVisible { hide() } else { show(scope: .all, anchorPoint: nil) }
    }

    /// Open at the cursor with the given scope (the ⌘⇧V "main" and ⌘⇧B "snippets" hotkeys). Always
    /// shows (does not toggle), matching the original's hotkey-opens-the-menu behavior.
    func open(scope: HistoryPanelModel.Scope = .all) {
        show(scope: scope, anchorPoint: nil)
    }

    /// Toggle anchored just below the status-item button — the status-bar left click. A second click
    /// while visible dismisses it (so the status item feels like a toggle).
    func open(from button: NSStatusBarButton) {
        if isVisible { hide() } else { show(scope: .all, anchorPoint: anchorPoint(for: button)) }
    }

    /// Present the panel: snapshot the paste target, refill rows for `scope`, position (at `anchorPoint`
    /// if given, else the cursor), take key without activating the app, and start the outside-click
    /// monitor. `anchorPoint` is a screen point used as the panel's top-left (the status item's bottom-left).
    private func show(scope: HistoryPanelModel.Scope, anchorPoint: CGPoint?) {
        // M-UI.11 P0 baseline: the whole open is synchronous today, so first-rows and shell end
        // back to back — the two intervals exist to show that gap opening up once show-first lands.
        let openToShell = PanelSignpost.begin(.openToShell)
        let openToFirstRows = PanelSignpost.begin(.openToFirstRows)

        // Snapshot the paste target (DEBUG focus PoC) BEFORE we touch the panel.
        #if DEBUG
        let before = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        #endif
        onWillShow?() // PasteService.captureFrontmost() — must run before the panel takes key (§2.2)

        // Apply the per-open paging config, then refill from a fresh history snapshot. `reset` returns
        // to page 0, highlights the top row, and bumps openToken to re-drive list focus (panel reuse).
        // The display policy is resolved ONCE for the whole open (M-UI.11 P1) and swapped in WITH
        // the rows inside reset — a separate stamp would resolve the previous open's rows under the
        // new policy and poison the classification cache (review).
        let config = coordinator.panelSettings
        let policy = DisplayPolicy.current()
        model.itemsPerPage = config.itemsPerPage
        model.startWithZero = config.startWithZero
        model.markedWithNumbers = config.markedWithNumbers
        let historyRows = coordinator.historyRows(policy: policy)
        let snippetRows = PanelSignpost.measure(.snippetRowsBuild) { coordinator.snippetRows() }
        let rowCount = historyRows.count + snippetRows.count
        PanelSignpost.measure(.modelCommit, rows: rowCount) {
            model.reset(historyRows: historyRows, snippetRows: snippetRows, scope: scope, policy: policy)
        }
        PanelSignpost.end(.openToFirstRows, openToFirstRows, rows: rowCount)

        // Apply the persisted preview-pane preference before positioning, so the cursor clamp math
        // sees the size the panel will actually open at (expanded panels near a screen edge must
        // be shifted inward by the FULL width).
        model.isPreviewExpanded = UserDefaults.standard.bool(forKey: DefaultsKeys.panelPreviewExpanded)
        var openSize = FloatingPanelLayout.size(previewExpanded: model.isPreviewExpanded)
        openSize.height += listBandAdjustment // band auto-fit carries across opens
        panel.setContentSize(openSize)

        // Kick off the rich preview's payload for the row highlighted at open (selection changes
        // re-request from the view's onChange). A hidden pane loads — decrypts — nothing.
        if model.isPreviewExpanded {
            previewProvider.request(model.selectedRow)
        }

        position(anchorPoint: anchorPoint)
        panel.makeKeyAndOrderFront(nil)
        // Push first responder into the hosted SwiftUI content so it can receive key events (arrow/Return).
        panel.makeFirstResponder(hosting.view)
        PanelSignpost.end(.openToShell, openToShell, rows: rowCount)

        #if DEBUG
        // Focus PoC (§2.5): did taking key steal frontmost? With `.nonactivatingPanel` it should not.
        // Bundle ids are not secret, so logging them is safe; readable from `log stream` when the panel
        // is excluded from a filtered screenshot. NOTE: `frontmostApplication` updates asynchronously,
        // so this synchronous before/after read is INDICATIVE, not authoritative — the definitive check
        // is whether a real selection pastes into the target during a run-app test.
        let after = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let probe = PanelFocusProbe(before: before, after: after)
        model.focusProbe = probe
        Self.log.info("""
            focus PoC: before=\(before ?? "nil", privacy: .public) \
            after=\(after ?? "nil", privacy: .public) \
            preserved=\(probe.preserved, privacy: .public)
            """)
        #endif

        installClickMonitor()
    }

    func hide() {
        removeClickMonitor()
        // Destroy decrypted preview payloads with the panel (security rule: nothing decoded
        // outlives the open).
        previewProvider.clear()
        panel.orderOut(nil)
    }

    // MARK: - Private

    /// Paste the chosen row and dismiss. Hides first so the panel doesn't linger over the (async) auth
    /// dialog; the coordinator applies the masked-secret gate before invoking the paste callback.
    private func select(_ row: PanelRow) {
        hide()
        Task { await coordinator.select(row) }
    }

    /// Position the panel so the MAIN COLUMN's top-left sits at `anchorPoint` (a screen point) when
    /// given, else at the cursor, clamped to the containing screen's visible frame so it never
    /// spills off-screen. Resolves the preview pane's side for this open first (preference + edge
    /// flip against that screen); a left-side pane extends the window leftward of the anchor.
    private func position(anchorPoint: CGPoint?) {
        let point = anchorPoint ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? .zero
        let side = resolvePreviewSide(mainColumnX: point.x, visibleFrame: visibleFrame)
        let pane = model.isPreviewExpanded && side == .left
            ? FloatingPanelLayout.previewWidth(expanded: true) : 0
        appliedPaneSide = model.isPreviewExpanded ? side : nil
        let origin = FloatingPanelLayout.originTopLeft(
            mouseLocation: CGPoint(x: point.x - pane, y: point.y),
            panelSize: panel.frame.size,
            visibleFrame: visibleFrame)
        panel.setFrameTopLeftPoint(origin)
    }

    /// The status-item button's bottom-left in screen coordinates — used as the panel's top-left so it
    /// hangs just below the menu-bar item. Falls back to the cursor if the button has no window yet.
    private func anchorPoint(for button: NSStatusBarButton) -> CGPoint {
        guard let window = button.window else { return NSEvent.mouseLocation }
        let inScreen = window.convertToScreen(button.convert(button.bounds, to: nil))
        return CGPoint(x: inScreen.minX, y: inScreen.minY)
    }

    private func installClickMonitor() {
        removeClickMonitor()
        // Dismiss on a click outside the panel. Global monitors fire only for events delivered to OTHER
        // apps (so this is normally already "outside"), but we rect-test defensively to match design
        // §2.4 and never self-dismiss on the panel's own resize/title regions. We hop to the main actor
        // with a Task rather than `assumeIsolated`: unlike Magnet (ActionQueue.main) or Screeen, global
        // event monitors do not contractually guarantee main-thread delivery, so `assumeIsolated` would
        // be an unsound trap.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            let clickLocation = NSEvent.mouseLocation
            Task { @MainActor in
                guard let self, !self.panel.frame.contains(clickLocation) else { return }
                self.hide()
            }
        }
    }

    private func removeClickMonitor() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }
}
