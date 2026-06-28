//
//  AppDelegate+Diagnostics.swift
//  ClipySi — Apple Silicon rewrite
//
//  The MetricKit crash-receiver wiring + the first-run Welcome flow. Split out of
//  AppDelegate (like AppDelegate+History.swift) to keep the main class focused. The Welcome window
//  uses the same AppKit-window-we-own path as About/Settings — an accessory (LSUIElement) app has no
//  reliable responder-chain target for a SwiftUI scene. All onboarding defaults are safe (diagnostics
//  OFF, Accessibility optional), so dismissing at any step is fine.
//

import AppKit
import SwiftUI

extension AppDelegate {
    /// Create the MetricKit crash receiver and subscribe to match the current level (no-op at `.none`).
    func startDiagnostics() {
        let receiver = CrashDiagnosticsReceiver()
        crashReceiver = receiver
        receiver.updateSubscription(for: AppSettings().diagnosticsLevel)
    }

    /// The Diagnostics pane / Welcome flow changed the level; (un)subscribe MetricKit to match.
    @objc
    func diagnosticsLevelChanged() {
        crashReceiver?.updateSubscription(for: AppSettings().diagnosticsLevel)
    }

    /// On first launch only, present the Welcome flow. Gated by a one-shot flag (like `hotKeysSeeded`)
    /// so dismissing it doesn't re-show next launch.
    func presentWelcomeIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: DefaultsKeys.didOnboard) else { return }
        defaults.set(true, forKey: DefaultsKeys.didOnboard)
        openWelcome()
    }

    func openWelcome() {
        // Titled window, so `appWindowWillClose` restores `.accessory` via the own-window count
        // when it closes.
        activateAsRegular()
        if welcomeWindow == nil {
            let root = WelcomeView(onFinish: { [weak self] in self?.welcomeWindow?.close() })
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.title = String(localized: "Welcome to ClipySi", comment: "Welcome window title")
            window.styleMask = [.titled, .closable]
            window.setContentSize(WelcomeLayout.size)
            window.isReleasedWhenClosed = false
            window.center()
            welcomeWindow = window
        }
        welcomeWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
