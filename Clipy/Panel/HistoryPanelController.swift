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
    /// Internal (not private) so the P2 controller tests can observe commits; production access
    /// stays confined to this type and the view it hosts.
    let model = HistoryPanelModel()
    private let coordinator: ClipSelectionCoordinator
    /// The off-MainActor history read path (M-UI.11 P2): keyset pages + the interim full-window
    /// fetch for search/category. All DB/decrypt/mask work for the panel goes through it.
    /// Internal only for the reads extension split (HistoryPanelController+Reads.swift).
    let readService: HistoryReadService
    /// Monotonic read generation, bumped on every show AND hide: an in-flight read commits only
    /// into the open it was started for — a hidden or re-opened panel drops late results (§5.2).
    /// Internal only for the reads extension split.
    var readGeneration: UInt64 = 0
    // The paged-read state below is internal (not private) ONLY for the reads extension split
    // (HistoryPanelController+Reads.swift, a lint file-length measure) and the tests that await
    // the task handles — treat it as private to these two files.

    /// The open's page-query contract (page size, cap, sort, policy), resolved once per show.
    var pageRequest: HistoryReadService.PageRequest?
    /// The keyset continuation after the loaded prefix; nil once the capped window is exhausted.
    var windowCursor: ClipPageCursor?
    /// The first-page read of the current open. Tests await it for a deterministic commit —
    /// the PanelPreviewContentProvider.pendingLoad pattern.
    var openTask: Task<Void, Never>?
    /// The in-flight next-page / full-window fetches; at most one each (requests coalesce).
    var pageTask: Task<Void, Never>?
    var hydrationTask: Task<Void, Never>?
    /// The in-flight reconcile read (M-UI.11 P3): re-serves the loaded prefix from current data
    /// after the head observation saw a write land under the open panel.
    var reconcileTask: Task<Void, Never>?
    /// A reconcile request arrived while the open's first read was still in flight — run one
    /// deferred pass right after its commit (closes the write-lands-during-openPage race).
    var pendingReconcile = false
    /// The warm-open store (M-UI.11 P3), kept current by `HistoryHeadObserver`. Nil (tests,
    /// missing wiring) simply means every open is cold — behavior-identical to P2.
    private let warmCache: HistoryWarmCache?
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
         blobStore: EncryptedBlobStore? = nil,
         readService: HistoryReadService = HistoryReadService(),
         warmCache: HistoryWarmCache? = nil) {
        self.coordinator = coordinator
        self.readService = readService
        self.warmCache = warmCache
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
        // The model's paged-window callbacks (M-UI.11 P2): sequential paging past the loaded
        // prefix, and hydration when a narrowing input needs the complete window.
        model.onNeedsMoreHistory = { [weak self] in self?.loadNextHistoryPage() }
        model.onNeedsWindowHydration = { [weak self] in self?.hydrateWindow() }
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
        // M-UI.11 P2 show-first: the shell (panel window + snippet rows + loading list) orders
        // front synchronously with NO history DB/decrypt work on this path; the first keyset
        // page is fetched on `HistoryReadService` and committed as ONE generation-guarded model
        // snapshot. `openToShell` closes at makeKey; `openToFirstRows` closes at that commit.
        let openToShell = PanelSignpost.begin(.openToShell)
        let openToFirstRows = PanelSignpost.begin(.openToFirstRows)

        // Snapshot the paste target (DEBUG focus PoC) BEFORE we touch the panel.
        #if DEBUG
        let before = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        #endif
        onWillShow?() // PasteService.captureFrontmost() — must run before the panel takes key (§2.2)

        // Apply the per-open paging config and enter the loading shell. `beginLoading` clears the
        // previous open's rows (nothing stale is selectable), swaps the display policy in
        // atomically with that clear (the P1 cache-poisoning rule), and bumps openToken to
        // re-drive list focus (panel reuse). The policy is resolved ONCE for the whole open.
        let config = coordinator.panelSettings
        // ONE construction shared with the head observer (coordinator.pageRequest =
        // PageRequest.current) so the warm cache's signature always matches an open's (P3).
        let request = coordinator.pageRequest
        let policy = request.policy
        model.itemsPerPage = config.itemsPerPage
        model.startWithZero = config.startWithZero
        model.markedWithNumbers = config.markedWithNumbers
        let snippetRows = PanelSignpost.measure(.snippetRowsBuild) { coordinator.snippetRows() }
        model.beginLoading(snippetRows: snippetRows, scope: scope, policy: policy)

        // Apply the persisted preview-pane preference before positioning, so the cursor clamp math
        // sees the size the panel will actually open at (expanded panels near a screen edge must
        // be shifted inward by the FULL width).
        model.isPreviewExpanded = UserDefaults.standard.bool(forKey: DefaultsKeys.panelPreviewExpanded)
        var openSize = FloatingPanelLayout.size(previewExpanded: model.isPreviewExpanded)
        openSize.height += listBandAdjustment // band auto-fit carries across opens
        panel.setContentSize(openSize)

        position(anchorPoint: anchorPoint)
        panel.makeKeyAndOrderFront(nil)
        // Push first responder into the hosted SwiftUI content so it can receive key events (arrow/Return).
        panel.makeFirstResponder(hosting.view)
        PanelSignpost.end(.openToShell, openToShell, rows: snippetRows.count)

        // First-page read. The unstructured Task inherits the MainActor, so everything below the
        // awaited actor call is a plain MainActor mutation; the generation guard drops the commit
        // when the panel was hidden or re-shown while the read ran. The preview payload kicks off
        // only after the commit — the selection doesn't exist before it.
        cancelReads()
        readGeneration &+= 1
        let generation = readGeneration
        pageRequest = request
        windowCursor = nil
        pendingReconcile = false
        if let warm = warmCache?.snapshot(matching: request) {
            // M-UI.11 P3 warm open (§5.1): the observer-maintained head commits in the SAME
            // turn as the shell — no DB/decrypt work anywhere on this path, and paste is live
            // immediately (selection, numbering, and page state settle in this one commit).
            windowCursor = warm.nextCursor
            let rowCount = warm.rows.count + snippetRows.count
            PanelSignpost.measure(.modelCommit, rows: rowCount) {
                model.commitFirstPage(historyRows: warm.rows,
                                      totalCount: warm.totalCount,
                                      windowComplete: warm.windowComplete)
            }
            PanelSignpost.end(.openToFirstRows, openToFirstRows, rows: rowCount)
            if model.isPreviewExpanded {
                previewProvider.request(model.selectedRow)
            }
            // §5.1's background revision check: the observation keeps the cache current, but a
            // write can land between its last fire and this open — re-read the served prefix
            // off-main and silently re-commit if it drifted.
            scheduleReconcile()
        } else {
            openTask = Task { [weak self] in
                guard let self else { return }
                let result = await readService.openPage(request)
                guard generation == readGeneration else { return }
                windowCursor = result.nextCursor
                let rowCount = result.rows.count + snippetRows.count
                PanelSignpost.measure(.modelCommit, rows: rowCount) {
                    self.model.commitFirstPage(historyRows: result.rows,
                                               totalCount: result.totalCount,
                                               windowComplete: result.nextCursor == nil)
                }
                PanelSignpost.end(.openToFirstRows, openToFirstRows, rows: rowCount)
                if model.isPreviewExpanded {
                    previewProvider.request(model.selectedRow)
                }
                // A head change arrived mid-read: one deferred reconcile now that the first
                // page is committed (the read that just landed may predate that write).
                if pendingReconcile { scheduleReconcile() }
            }
        }

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
        // Cancel in-flight reads and invalidate their generation: a hidden panel never receives
        // a late commit (M-UI.11 P2 §5.2), and the next show starts a fresh generation anyway.
        cancelReads()
        readGeneration &+= 1
        // Destroy decrypted preview payloads with the panel (security rule: nothing decoded
        // outlives the open).
        previewProvider.clear()
        panel.orderOut(nil)
    }

    /// Screen lock (M-UI.11 P3, D4): hide AND drop the model's decrypted rows. `hide()` alone
    /// keeps the loaded window's display titles — raw plaintext with masking off — resident
    /// behind the lock; the warm cache purges itself (HistoryHeadObserver), and this closes
    /// the strictly larger exposure one object away from it.
    func purgeForScreenLock() {
        hide()
        model.purgeHistoryRows()
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
