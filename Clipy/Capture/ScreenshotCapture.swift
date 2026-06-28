//
//  ScreenshotCapture.swift
//  ClipySi — Apple Silicon rewrite
//
//  Turns a detected screenshot into a synthetic single-`TIFF` `PasteboardContents` so it flows
//  through the SAME `CaptureService.capture` gates as a real copy — exclude-app, store-type "TIFF",
//  dedupe, history cap, and encryption-at-rest all apply for free. This is the §6-delta-10 handoff
//  seam: NOT a parallel image-ingest that would bypass the exclude gate (the original's bug,
//  `ClipService.create(with:image:)`). A screenshot file carries no NSPasteboard privacy marker, so
//  marker protection is structurally inapplicable here — exclude + encryption are what apply (§6
//  delta 11), which is exactly what routing through `capture` provides.
//

import AppKit

enum ScreenshotCapture {
    static let tiffType = NSPasteboard.PasteboardType.tiff.rawValue

    /// The synthetic snapshot fed to `CaptureService.capture`. `changeCount` is synthetic (screenshots
    /// aren't pasteboard-polled; `CaptureService` doesn't read it) and there are no marker type ids,
    /// so the privacy gate returns `.record` and the real decision is exclude + store-type + dedupe.
    static func pasteboardContents(tiff: Data, frontmostBundleID: String?) -> PasteboardContents {
        PasteboardContents(
            changeCount: 0,
            typeIdentifiers: [tiffType],
            dataByType: [tiffType: tiff],
            frontmostBundleID: frontmostBundleID,
            sourceBundleID: nil
        )
    }
}
