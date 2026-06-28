//
//  UpdaterService.swift
//  ClipySi — Apple Silicon rewrite
//
//  Owns the Sparkle updater (SPUStandardUpdaterController) and exposes a thin, observable surface to
//  the Updates pane. Mirrors the original `AppDelegate` wiring (read the persisted kCPY settings,
//  configure the updater, clear any stale feed override) with two deliberate changes:
//
//  * EdDSA only — the feed URL + public key live in Info.plist (SUFeedURL / SUPublicEDKey); legacy
//    DSA is dropped.
//  * The updater is always *started*; the "automatically check" intent drives
//    `automaticallyChecksForUpdates` rather than whether the updater runs at all. The original gated
//    starting the updater on the toggle, which also disabled the manual "Check Now" — here Check Now
//    works regardless.
//
//  Conforms to `SPUStandardUserDriverDelegate` to opt into Sparkle's Gentle Reminders (less intrusive
//  scheduled-update prompts — DESIGN.md §4).
//

import Foundation
import Observation
import OSLog
import Sparkle

@MainActor
@Observable
final class UpdaterService: NSObject, SPUStandardUserDriverDelegate {
    private static let logger = Logger(subsystem: "io.github.ponponusa.clipysi", category: "update")

    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    /// Mirrors of the updater's KVO-backed state so SwiftUI re-renders when Sparkle updates them.
    private(set) var lastUpdateCheckDate: Date?
    private(set) var canCheckForUpdates = false

    /// - Parameters:
    ///   - automaticallyChecks: the persisted `kCPYEnableAutomaticCheckKey` intent.
    ///   - checkInterval: the persisted `kCPYUpdateCheckIntervalKey`, in seconds.
    init(automaticallyChecks: Bool, checkInterval: TimeInterval) {
        super.init()

        // Build the controller without auto-starting so we can configure the updater and install
        // ourselves as the user-driver delegate (Gentle Reminders) before it begins its cycle.
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
        self.controller = controller

        let updater = controller.updater
        updater.automaticallyChecksForUpdates = automaticallyChecks
        updater.updateCheckInterval = checkInterval
        // The feed URL is authoritative in Info.plist; drop any stale per-user override.
        updater.clearFeedURLFromUserDefaults()

        // KVO-bridge the two properties the Updates pane shows live. We read the Sendable
        // `change.newValue` rather than the object's property: `SPUUpdater` is `@MainActor`-isolated,
        // so touching it inside this nonisolated `@Sendable` KVO closure would be unsafe. Then hop to
        // the main actor to mutate the observable mirrors.
        observations = [
            updater.observe(\.lastUpdateCheckDate, options: [.initial, .new]) { [weak self] _, change in
                // `change.newValue` is `Date??`; flatMap collapses the outer optional to `Date?`.
                let date = change.newValue.flatMap { $0 }
                Task { @MainActor in self?.lastUpdateCheckDate = date }
            },
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
                guard let can = change.newValue else { return }
                Task { @MainActor in self?.canCheckForUpdates = can }
            }
        ]

        controller.startUpdater()
    }

    // MARK: - Pane actions

    /// User-initiated check ("Check for Updates Now…"). Shows Sparkle's standard UI.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Pushes the persisted auto-check intent into the running updater (called from the pane's toggle).
    func setAutomaticallyChecks(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
    }

    /// Pushes a new check interval (seconds) into the running updater (called from the pane's picker).
    func setCheckInterval(seconds: Int) {
        controller.updater.updateCheckInterval = TimeInterval(seconds)
    }

    // MARK: - SPUStandardUserDriverDelegate

    /// Opt into Gentle Reminders: scheduled-update prompts are shown less intrusively.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}
