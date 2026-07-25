//
//  ScreenshotMonitor.swift
//  ClipySi — Apple Silicon rewrite
//
//  Watches for new screenshot files via Screeen (a Spotlight `NSMetadataQuery` over the folder
//  macOS saves screenshots to) and hands each one to the capture pipeline as TIFF data. Mirrors the
//  original's `ScreenShotObserver` wiring; the store/encrypt/exclude/dedupe decisions happen in
//  `CaptureService` via the synthetic pasteboard built by `ScreenshotCapture` (design §3.8). Gated
//  by the Beta `observeScreenshot` toggle — AppDelegate flips `isEnabled` live (§6 delta 5).
//
//  The scope comes from `ScreenshotLocation`, not from Screeen's no-argument initializer, which
//  hardcodes `~/Desktop` and therefore sees nothing once the user moves the save folder. Screeen
//  applies `searchScopes` only in its initializer, so re-scoping means replacing the observer; a
//  fresh query cannot replay screenshots already on disk, because Screeen reports
//  `NSMetadataQueryDidUpdate` only and ignores the initial gather.
//
//  Screeen's `ScreenShotObserverDelegate` is a non-isolated `@objc optional` protocol, so under
//  Swift 6 a `@MainActor` type cannot satisfy its requirement with a `@MainActor` method. The
//  delegate method is therefore `nonisolated`; since Screeen's NSMetadataQuery delivers on the main
//  thread, we resolve the file there and assert main-actor isolation (`MainActor.assumeIsolated`)
//  before handing off — the same shape as the KeyHolder bridge.
//

import AppKit
import OSLog
import Screeen

@MainActor
final class ScreenshotMonitor: NSObject {
    private nonisolated static let log = Logger(subsystem: "io.github.ponponusa.clipysi", category: "capture")

    private let onScreenshot: @MainActor (Data) -> Void
    private let resolveSearchPaths: @MainActor () -> [String]
    private var observer: ScreenShotObserver?
    private var enabled = false

    /// The directories the live query is scoped to. Empty means nothing is being watched.
    private(set) var watchedDirectoryPaths: [String] = []

    /// Whether a query exists at all. Distinct from `isEnabled`: an enabled monitor whose save
    /// folder cannot be resolved watches nothing, rather than falling back to an unscoped query.
    var isWatching: Bool { observer != nil }

    /// `onScreenshot` receives the detected screenshot's TIFF data on the main actor.
    /// `resolveSearchPaths` is the seam tests use to stand in for the system save location.
    init(resolveSearchPaths: @escaping @MainActor () -> [String] = { ScreenshotLocation.currentSearchDirectoryPaths() },
         onScreenshot: @escaping @MainActor (Data) -> Void) {
        self.resolveSearchPaths = resolveSearchPaths
        self.onScreenshot = onScreenshot
        super.init()
    }

    /// Enables/disables detection. The underlying query is created lazily on first enable and kept
    /// alive across a disable (detection is just gated), matching the original.
    var isEnabled: Bool {
        get { enabled }
        set {
            enabled = newValue
            if newValue { rescopeIfNeeded() }
            observer?.isEnabled = newValue
        }
    }

    /// Re-reads the save location and re-scopes the query if it moved. Idempotent and cheap when
    /// nothing changed. macOS posts no notification for this setting, so AppDelegate calls it on
    /// the signal it does have — see `screenshotLocationMayHaveChanged`.
    func refreshSearchPaths() {
        guard enabled else { return }
        rescopeIfNeeded()
    }

    private func rescopeIfNeeded() {
        let paths = resolveSearchPaths()
        guard paths != watchedDirectoryPaths || (observer == nil && !paths.isEmpty) else { return }

        // Drop the old observer first: Screeen's deinit stops its query, so the previous scope is
        // gone before the new one starts.
        observer?.delegate = nil
        observer = nil
        watchedDirectoryPaths = paths

        guard !paths.isEmpty else {
            // Deliberately not falling back to `ScreenShotObserver()`: an empty scope list is an
            // unscoped query over the whole Spotlight index, not a Desktop fallback.
            Self.log.error("screenshot save location unresolved; auto-import idle")
            return
        }

        let observer = ScreenShotObserver(searchDirectoryPaths: paths)
        observer.delegate = self
        observer.isEnabled = enabled
        self.observer = observer
        observer.start()
    }
}

extension ScreenshotMonitor: ScreenShotObserverDelegate {
    // `ScreenShotObserverDelegate` is non-isolated, but Screeen's NSMetadataQuery delivers this on the
    // main thread; resolve the file → TIFF (Sendable `Data`) here, then assert main-actor isolation to
    // hand off. (Same shape as the KeyHolder bridge — a @MainActor conformer can't satisfy a
    // non-isolated delegate directly under Swift 6.)
    nonisolated func screenShotObserver(_ observer: ScreenShotObserver, addedItem item: NSMetadataItem) {
        guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { return }
        guard let image = NSImage(contentsOfFile: path), let tiff = image.tiffRepresentation else {
            // Usually a Files-and-Folders TCC denial (Desktop/Documents/Downloads all need consent)
            // or a format NSImage can't decode. Say so instead of importing nothing in silence; the
            // path is user content, so it is not logged.
            Self.log.error("screenshot detected but unreadable; auto-import skipped")
            return
        }
        MainActor.assumeIsolated { onScreenshot(tiff) }
    }
}
