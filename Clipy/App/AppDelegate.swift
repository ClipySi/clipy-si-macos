//
//  AppDelegate.swift
//  ClipySi — Apple Silicon rewrite
//
//  Owns the AppKit core: accessory activation, the status-bar item and its NSMenu, pasteboard
//  monitoring + capture, global hotkeys, CGEvent paste injection, the SMAppService login-item
//  reconcile, and Screeen screenshot auto-import. Settings-pane side effects arrive via the
//  `.clipy*Changed` notifications (see DESIGN.md §4).
//

import AppKit
import OSLog
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // `internal` (not private) so the `AppDelegate+History.swift` extension can use them.
    static let logger = Logger(subsystem: "io.github.ponponusa.clipysi", category: "capture")

    var statusItem: NSStatusItem? // internal: the status-item wiring lives in AppDelegate+StatusItem
    private var pasteboardMonitor: PasteboardMonitor?
    var blobStore: EncryptedBlobStore?
    private var menuController: StatusMenuController?
    private var hotKeyService: HotKeyService?
    private var pasteService: PasteService?
    private var captureService: CaptureService?
    private var screenshotMonitor: ScreenshotMonitor?
    private var updaterService: UpdaterService?
    private var settingsWindow: NSWindow?
    private var snippetEditorWindow: NSWindow?
    private var historyManagerWindow: NSWindow?
    private var aboutWindow: NSWindow?
    /// The non-activating history browser popped by the history hotkey. Replaces the NSMenu
    /// history popup for ⌃⌘V; the status-item menu still lists history.
    var historyPanel: HistoryPanelController? // internal: reached from AppDelegate+StatusItem
    // `internal` (not private) so the `AppDelegate+Diagnostics.swift` extension can use them.
    var welcomeWindow: NSWindow?

    /// Body-free, level-gated diagnostics. The shared `.live` instance (the same one DI returns);
    /// `record` is a no-op until the user opts in via the Welcome flow / Diagnostics pane.
    let diagnostics = DiagnosticsRecorder.live
    /// MetricKit crash receiver. Subscribes only at `.minimal`+; created at launch. `internal`
    /// for the `AppDelegate+Diagnostics.swift` extension.
    var crashReceiver: CrashDiagnosticsReceiver?

    // The clips inserted by the last import that triggered the over-limit prompt, kept so "Cancel" can
    // roll exactly those back out (they aren't necessarily the newest by date — imported timestamps are
    // the originals). Set only while that prompt is up; consumed by `resolveHistoryOverflow`. `internal`
    // for the `AppDelegate+History.swift` extension; also read by `appWindowWillClose`.
    var pendingImportedIDs: [Clip.ID] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Seed UserDefaults registration-domain defaults (original-compatible keys) before
        // anything reads a setting. See DefaultsKeys.
        DefaultsKeys.registerDefaults()

        // Menu-bar-only agent. LSUIElement in Info.plist hides the Dock icon at
        // launch; this makes the policy explicit at runtime as well.
        NSApp.setActivationPolicy(.accessory)

        // The encrypted blob store backs both capture (write) and the menu's clear-history GC.
        // If it can't be created we still bring up the menu so the user can quit / open settings.
        let blobStore = try? EncryptedBlobStore.live()
        if blobStore == nil {
            AppDelegate.logger.error("blob store unavailable; capture + history GC disabled")
            diagnostics.record(.error(.capture, .ioFailure))
        }
        self.blobStore = blobStore

        // The controller is just the Clear-History confirm flow (the .clearHistory hotkey
        // and the panel's management overlay call it); the panel wires Settings/About/Snippet/History
        // directly to this AppDelegate.
        let controller = StatusMenuController(model: MenuModel(), blobStore: blobStore)
        menuController = controller

        refreshStatusItem()
        reconcileLoginItem()
        startUpdater()
        observeSettingsSideEffects()
        startHotKeys(controller: controller)
        if let blobStore {
            startCapture(blobStore: blobStore)
            startPaste(blobStore: blobStore, controller: controller)
            startScreenshotObserver()
        }

        // One-shot, off the main thread: flag `isSensitive` on clips captured before secret detection
        // was wired into capture (UX hint only; sync re-checks at upload). Idempotent.
        Task.detached(priority: .utility) {
            IsSensitiveBackfill().runIfNeeded()
        }

        // Local-folder sync: resume if enabled (with the opt-in Keychain key it unlocks
        // without a prompt; otherwise the Sync pane shows the locked state).
        SyncCoordinator.shared.refresh()

        diagnostics.record(.launched)
        startDiagnostics()
        presentWelcomeIfNeeded()
    }

    // MARK: - Paste

    private func startPaste(blobStore: EncryptedBlobStore, controller: StatusMenuController) {
        let service = PasteService(blobStore: blobStore,
                                   markSeen: { [weak self] in self?.pasteboardMonitor?.markSeen() })
        pasteService = service

        // The history hotkey opens the FloatingPanel. Snapshot the paste target before the
        // panel takes key (same role as the NSMenu's onMenuWillOpen), so a later selection pastes into
        // the app that was frontmost — not into our panel.
        let panel = HistoryPanelController(blobStore: blobStore)
        panel.onWillShow = { [weak service] in service?.captureFrontmost() }
        panel.onSelectClip = { [weak service] id in service?.paste(clipID: id) }
        // Snippet picks paste their plaintext content via the same gated path. The masked-
        // secret AuthGate is NOT applied here — it lives only on the clip path inside the coordinator —
        // because snippets are user-authored plaintext, never detected secrets.
        panel.onSelectSnippet = { [weak service] id in service?.paste(snippetID: id) }
        // The panel's management overlay (gear/⌘M) reuses the same handlers as the NSMenu's Manage
        // submenu; the controller hides the panel before each so windows/alerts come forward.
        panel.onOpenSettings = { [weak self] in self?.openSettings() }
        panel.onOpenAbout = { [weak self] in self?.openAbout() }
        panel.onOpenSnippetEditor = { [weak self] in self?.openSnippetEditor() }
        panel.onOpenHistoryManager = { [weak self] in self?.openHistoryManager() }
        panel.onClearHistory = { [weak controller] in controller?.confirmAndClearHistory() }
        historyPanel = panel

        // Prompt for Accessibility once at launch (no-op if already trusted) so the first paste works.
        // On the very first run the Welcome flow owns this ask (its Accessibility step), so we don't
        // prompt before the window appears — otherwise the system prompt would precede onboarding.
        if UserDefaults.standard.bool(forKey: DefaultsKeys.didOnboard) {
            _ = AccessibilityService().isTrusted(prompt: true)
        }
    }

    // MARK: - Hotkeys

    private func startHotKeys(controller: StatusMenuController) {
        let service = HotKeyService()
        service.onTrigger = { [weak self, weak controller] type in
            switch type {
            // Every popup hotkey opens the one unified panel (the NSMenu is retired).
            case .mainMenu: self?.historyPanel?.open()                // ⌘⇧V → unified panel (All scope)
            case .history: self?.historyPanel?.toggle()               // ⌃⌘V → toggle the unified panel (All)
            case .snippet: self?.historyPanel?.open(scope: .snippets) // ⌘⇧B → unified panel, Snippets scope
            case .clearHistory: controller?.confirmAndClearHistory()  // unchanged (own confirm alert)
            }
        }
        service.registerAll()
        hotKeyService = service
    }

    // MARK: - Login item

    /// Reconciles the stored `loginItem` intent with the real SMAppService registration at launch:
    /// if the user wants login-at-launch but the OS has it `.notRegistered`, (re)register. Runs every
    /// launch so a dropped registration self-heals (matching the original's `reflectLoginItemState`),
    /// without nagging — a successful register lands on `.enabled`, and `.requiresApproval` is left for
    /// the user to resolve in System Settings (the General pane surfaces that hint). The interactive
    /// toggle lives in the General pane.
    private func reconcileLoginItem() {
        let service = LoginItemService.live
        guard LoginItemService.shouldAutoRegister(
            intent: UserDefaults.standard.bool(forKey: DefaultsKeys.loginItem),
            status: service.status
        ) else { return }
        do {
            try service.setEnabled(true)
        } catch {
            AppDelegate.logger.error("login item auto-register failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Updates

    /// Brings up the Sparkle updater, seeded from the persisted kCPY settings. The updater always
    /// starts; the auto-check intent drives `automaticallyChecksForUpdates` (so manual "Check Now"
    /// works even with auto-check off). The interval is clamped to a known choice to guard against a
    /// corrupt persisted value. Settings registration-domain defaults were seeded above.
    private func startUpdater() {
        let defaults = UserDefaults.standard
        let auto = defaults.bool(forKey: DefaultsKeys.enableAutomaticCheck)
        let interval = UpdateMapping.normalizedInterval(defaults.integer(forKey: DefaultsKeys.updateCheckInterval))
        updaterService = UpdaterService(automaticallyChecks: auto, checkInterval: TimeInterval(interval))
    }

    // MARK: - Capture

    private func startCapture(blobStore: EncryptedBlobStore) {
        let capture = CaptureService(settings: AppSettings(), blobStore: blobStore)
        captureService = capture
        let monitor = PasteboardMonitor(pasteboard: SystemPasteboard()) { contents in
            do {
                _ = try capture.capture(contents)
            } catch {
                AppDelegate.logger.error(
                    "capture failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        monitor.start()
        pasteboardMonitor = monitor
    }

    // MARK: - Screenshot auto-import

    /// Owns the Screeen observer; enabled per the Beta `observeScreenshot` setting. Detected
    /// screenshots route through `CaptureService` so the same exclude/store-type/dedupe/encryption
    /// gates apply (design §3.8 / §6 delta 10) — not a parallel ingest.
    private func startScreenshotObserver() {
        let monitor = ScreenshotMonitor(onScreenshot: { [weak self] tiff in
            self?.captureScreenshot(tiff: tiff)
        })
        monitor.isEnabled = AppSettings().observeScreenshot
        screenshotMonitor = monitor
    }

    private func captureScreenshot(tiff: Data) {
        guard let captureService else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let contents = ScreenshotCapture.pasteboardContents(tiff: tiff, frontmostBundleID: frontmost)
        do {
            _ = try captureService.capture(contents)
        } catch {
            AppDelegate.logger.error("screenshot capture failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Settings side-effects

    private func observeSettingsSideEffects() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(statusItemStyleChanged),
                           name: .clipySiStatusItemStyleChanged, object: nil)
        center.addObserver(self, selector: #selector(hotKeysChanged),
                           name: .clipySiHotKeysChanged, object: nil)
        center.addObserver(self, selector: #selector(observeScreenshotChanged),
                           name: .clipySiObserveScreenshotChanged, object: nil)
        center.addObserver(self, selector: #selector(languageChanged),
                           name: .clipySiLanguageChanged, object: nil)
        center.addObserver(self, selector: #selector(diagnosticsLevelChanged),
                           name: .clipySiDiagnosticsLevelChanged, object: nil)
        // Restore the accessory regime when the last titled app window closes (see openSettings).
        center.addObserver(self, selector: #selector(appWindowWillClose(_:)),
                           name: NSWindow.willCloseNotification, object: nil)
    }

    @objc
    private func statusItemStyleChanged() {
        refreshStatusItem()
    }

    @objc
    private func hotKeysChanged() {
        // The Shortcuts pane already wrote the new combo to HotKeyStore; re-register everything
        // (idempotent unregister-then-register) so the change takes effect without a relaunch.
        hotKeyService?.registerAll()
    }

    @objc
    private func observeScreenshotChanged() {
        // The Type pane wrote the new value; start/stop the Screeen observer to match (lazy start
        // on first enable; thereafter just toggles detection).
        screenshotMonitor?.isEnabled = AppSettings().observeScreenshot
    }

    @objc
    private func languageChanged() {
        // The General pane already wrote the AppleLanguages override; relaunch so the bundle
        // re-resolves its localization at process start.
        relaunchForLanguageChange()
    }

    @objc
    private func appWindowWillClose(_ note: Notification) {
        // The Settings scene is the only titled window we open (the SnippetEditor window arrives
        // later; this same count-our-own-windows logic will cover it). When the last titled, visible
        // window is closing, drop back to `.accessory` so no Dock icon lingers. We count windows we
        // own rather than matching the Settings window by title/identifier (design §6 delta 9).
        let closing = note.object as? NSWindow
        // Closing the History window while the over-limit import prompt is still up counts as cancel:
        // roll the just-imported clips back out, so an un-answered prompt never silently keeps them.
        if closing === historyManagerWindow, !pendingImportedIDs.isEmpty {
            resolveHistoryOverflow(.cancelImport)
        }
        let stillOpen = NSApp.windows.contains {
            $0 !== closing && $0.isVisible && $0.styleMask.contains(.titled)
        }
        if !stillOpen {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - Actions

    // `internal` (not private) so the `AppDelegate+Diagnostics.swift` extension can call it.
    /// Promote to a regular (Dock-visible) app so a titled window can show and take focus. An
    /// LSUIElement app's Dock tile is created lazily on this promotion and does NOT pick up the
    /// in-process `applicationIconImage` automatically — for a freshly built (LaunchServices-uncached)
    /// app it can come up generic/blank. Re-asserting the bundle icon forces the tile to show our
    /// logo. Idempotent; the matching demotion back to `.accessory` is in `appWindowWillClose`.
    func activateAsRegular() {
        NSApp.setActivationPolicy(.regular)
        if let icon = NSImage(named: NSImage.applicationIconName) {
            NSApp.applicationIconImage = icon
        }
    }

    @objc
    func openSettings() { // internal: the status-item fallback menu opens Settings too
        // Host the Settings UI in an AppKit window we own — the same proven path as the snippet
        // editor below. The SwiftUI `Settings` scene + `showSettingsWindow:` responder action does
        // NOT reliably open from an accessory (LSUIElement) app on current macOS: right after the
        // `.accessory`→`.regular` switch the selector finds no target in the responder chain, so the
        // window silently never appears. An AppKit window we drive directly avoids that. It's titled,
        // so `appWindowWillClose` restores `.accessory` via the own-window count (design §1.2).
        diagnostics.record(.featureUsed(.settings))
        activateAsRegular()
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsRootView()))
            window.title = String(localized: "Settings", comment: "Settings window title")
            // Fixed-but-resizable size. We deliberately do NOT use `NSHostingController.sizingOptions
            // = .preferredContentSize`: the panes differ in size (the Excluded Apps List vs the Form
            // panes), so letting the host resize the window when a tab changes throws an Auto Layout
            // constraint exception mid-display-cycle and aborts. A fixed content size + .resizable
            // lets each pane lay out within the window instead.
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(SettingsLayout.windowContentSize)
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc
    private func openAbout() {
        // The About window (carved out of the former Settings "Updates" tab) follows the same
        // AppKit-window-we-own path as Settings/SnippetEditor — an accessory (LSUIElement) app has no
        // reliable responder-chain target for a SwiftUI scene. It's titled, so `appWindowWillClose`
        // restores `.accessory` via the own-window count when it (and the others) close. The live
        // updater is injected so the update controls show last-checked / version and drive "Check
        // Now"; `.environment` takes an optional Observable, so nil leaves them inert.
        activateAsRegular()
        if aboutWindow == nil {
            let root = AboutView().environment(updaterService)
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.title = String(localized: "About ClipySi", comment: "About window title / status menu item")
            // Fixed content size + no resize: a single fixed view, so letting the host drive sizing
            // would risk the same mid-cycle Auto Layout exception documented in openSettings.
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(AboutLayout.windowContentSize)
            window.isReleasedWhenClosed = false
            window.center()
            aboutWindow = window
        }
        aboutWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc
    private func openSnippetEditor() {
        // An agent app has no always-present SwiftUI scene to drive `openWindow`, so host the editor
        // in an AppKit window we own (reused across opens). It's a titled window, so `appWindowWillClose`
        // restores `.accessory` when it (and Settings) close — the same own-window-count path.
        diagnostics.record(.featureUsed(.snippets))
        activateAsRegular()
        if snippetEditorWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SnippetEditorView()))
            window.title = String(localized: "Snippets", comment: "Snippet editor window title")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 820, height: 480))
            window.isReleasedWhenClosed = false // keep the instance so reopening is cheap
            window.center()
            snippetEditorWindow = window
        }
        snippetEditorWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc
    private func openHistoryManager() {
        // Same AppKit-window path as Settings/Snippets. The History Manager is copy-only, so no frontmost paste target
        // is captured here; auto-paste gets its own target-selection path in a later feature flag.
        diagnostics.record(.featureUsed(.history))
        activateAsRegular()
        if historyManagerWindow == nil {
            let view = HistoryManagerView(
                onCopy: { [weak self] id in self?.pasteService?.copyOnly(clipID: id) },
                onDelete: { [weak self] id in self?.pasteService?.delete(clipID: id) },
                onClearAll: { [weak self] in self?.pasteService?.deleteAll() },
                onSnippetize: { [weak self] id, folderID in self?.snippetize(clipID: id, intoFolder: folderID) },
                onBuildExport: { [weak self] in self?.buildHistoryExport() },
                onImport: { [weak self] data in self?.importHistory(from: data) ?? .failure(message: "") },
                onResolveImportOverflow: { [weak self] resolution in self?.resolveHistoryOverflow(resolution) }
            )
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = String(localized: "History", comment: "History manager window title")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 980, height: 600))
            window.isReleasedWhenClosed = false
            window.center()
            historyManagerWindow = window
        }
        historyManagerWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Converts a history clip into a snippet in `folderID` (History Manager "Snippetize").
    /// Needs the live blob store (the clip's content is an encrypted blob), so it runs here rather
    /// than in the view. Beeps if the clip isn't snippetizable (non-text / undecryptable) or fails.
    private func snippetize(clipID: Clip.ID, intoFolder folderID: SnippetFolder.ID) {
        guard let blobStore else { NSSound.beep(); return }
        do {
            if try SnippetMaker(blobStore: blobStore).snippetize(clipID: clipID, intoFolder: folderID) == nil {
                NSSound.beep()
            }
        } catch {
            NSSound.beep()
            AppDelegate.logger.error("snippetize failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Language

    /// A persisted language change (via the status menu's "Language" submenu) only takes effect at
    /// process start — the bundle's localization is resolved once, at launch — so applying it means
    /// relaunching. Spawns a detached shell that waits for this process to exit, then reopens the app
    /// (a clean single-instance handoff, so two clipboard monitors never run at once), and terminates.
    private func relaunchForLanguageChange() {
        let bundlePath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // pid/bundlePath are passed as positional args ($1/$2) rather than interpolated into the
        // script body, so an unusual install path cannot break or inject into the shell command.
        task.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; exec /usr/bin/open \"$2\"", "relaunch", String(pid), bundlePath]
        do {
            try task.run()
        } catch {
            AppDelegate.logger.error("relaunch for language change failed: \(error.localizedDescription, privacy: .public)")
        }
        NSApp.terminate(nil)
    }
}
