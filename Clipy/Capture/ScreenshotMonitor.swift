//
//  ScreenshotMonitor.swift
//  ClipySi — Apple Silicon rewrite
//
//  Watches for new screenshot files via Screeen (a Spotlight `NSMetadataQuery` over the Desktop) and
//  hands each one to the capture pipeline as TIFF data. Mirrors the original's `ScreenShotObserver`
//  wiring; the store/encrypt/exclude/dedupe decisions happen in `CaptureService` via the synthetic
//  pasteboard built by `ScreenshotCapture` (design §3.8). Gated by the Beta `observeScreenshot`
//  toggle — AppDelegate flips `isEnabled` live (§6 delta 5).
//
//  Screeen's `ScreenShotObserverDelegate` is a non-isolated `@objc optional` protocol, so under
//  Swift 6 a `@MainActor` type cannot satisfy its requirement with a `@MainActor` method. The
//  delegate method is therefore `nonisolated`; since Screeen's NSMetadataQuery delivers on the main
//  thread, we resolve the file there and assert main-actor isolation (`MainActor.assumeIsolated`)
//  before handing off — the same shape as the KeyHolder bridge.
//

import AppKit
import Screeen

@MainActor
final class ScreenshotMonitor: NSObject {
    private let observer = ScreenShotObserver()
    private let onScreenshot: @MainActor (Data) -> Void
    private var started = false

    /// `onScreenshot` receives the detected screenshot's TIFF data on the main actor.
    init(onScreenshot: @escaping @MainActor (Data) -> Void) {
        self.onScreenshot = onScreenshot
        super.init()
        observer.delegate = self
    }

    /// Enables/disables detection. Starts the underlying Spotlight query lazily on first enable
    /// (matching the original — `start()` once), then just toggles `isEnabled` thereafter.
    var isEnabled: Bool {
        get { observer.isEnabled }
        set {
            observer.isEnabled = newValue
            if newValue && !started {
                started = true
                observer.start()
            }
        }
    }
}

extension ScreenshotMonitor: ScreenShotObserverDelegate {
    // `ScreenShotObserverDelegate` is non-isolated, but Screeen's NSMetadataQuery delivers this on the
    // main thread; resolve the file → TIFF (Sendable `Data`) here, then assert main-actor isolation to
    // hand off. (Same shape as the KeyHolder bridge — a @MainActor conformer can't satisfy a
    // non-isolated delegate directly under Swift 6.)
    nonisolated func screenShotObserver(_ observer: ScreenShotObserver, addedItem item: NSMetadataItem) {
        guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
              let image = NSImage(contentsOfFile: path),
              let tiff = image.tiffRepresentation else { return }
        MainActor.assumeIsolated { onScreenshot(tiff) }
    }
}
