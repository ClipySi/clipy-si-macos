//
//  ClipySiNotifications.swift
//  ClipySi — Apple Silicon rewrite
//
//  In-process notifications used to deliver Settings-pane *side effects* to the AppKit core.
//  A `@Shared(.appStorage)` write makes the new value visible everywhere, but it does NOT run an
//  action (install/remove the status item, (un)register the login item, start/stop the screenshot
//  observer). The pane posts one of these; AppDelegate observes and performs the effect. See the
//  design §1.3 / §6 (delta 5).
//

import Foundation

extension Notification.Name {
    /// Posted by the General pane when the status-bar icon style (`kCPYPrefShowStatusItemKey`)
    /// changes, so AppDelegate can install or remove the `NSStatusItem` live.
    static let clipySiStatusItemStyleChanged = Notification.Name("io.github.ponponusa.clipysi.statusItemStyleChanged")

    /// Posted by the Shortcuts pane after the user records or clears a global hotkey (the new combo
    /// is already written to `HotKeyStore`), so AppDelegate re-registers the Magnet hotkeys live.
    static let clipySiHotKeysChanged = Notification.Name("io.github.ponponusa.clipysi.hotKeysChanged")

    /// Posted by the Type pane when the screenshot auto-import toggle (`observeScreenshot`) changes,
    /// so AppDelegate starts/stops the Screeen observer live.
    static let clipySiObserveScreenshotChanged = Notification.Name("io.github.ponponusa.clipysi.observeScreenshotChanged")

    /// Posted by the General pane's "Relaunch Now" button after the user changes the display
    /// language (the override is already written to UserDefaults), so AppDelegate relaunches — the
    /// bundle's localization is resolved only at process start.
    static let clipySiLanguageChanged = Notification.Name("io.github.ponponusa.clipysi.languageChanged")

    /// Posted by the Diagnostics pane / consent window when the collection level
    /// (`clipyDiagnosticsLevel`) changes, so AppDelegate (un)subscribes the MetricKit crash receiver
    /// live — subscribe at `.minimal`+, unsubscribe at `.none`.
    static let clipySiDiagnosticsLevelChanged = Notification.Name("io.github.ponponusa.clipysi.diagnosticsLevelChanged")
}
