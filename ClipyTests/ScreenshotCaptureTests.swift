//
//  ScreenshotCaptureTests.swift
//  ClipyTests
//
//  The screenshot → capture handoff: a detected screenshot becomes a synthetic single-TIFF
//  `PasteboardContents` that flows through the real `CaptureService` gates — so it's encrypted at
//  rest, honors the exclude list, and respects the "TIFF" store-type, exactly like a real copy
//  (design §3.8 / §6 delta 10). The live Screeen `NSMetadataQuery` is run-app. Never touches
//  NSPasteboard.general or the real Keychain.
//

import AppKit
import CryptoKit
import Foundation
import SQLiteData
import Testing
@testable import Clipy

@Suite struct ScreenshotCaptureTests {
    private static let testKey = SymmetricKey(data: Data(repeating: 0x07, count: 32))

    /// A small but valid TIFF payload (2×2 RGBA), standing in for a screenshot file's image data.
    private static let sampleTIFF: Data = {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        return rep.tiffRepresentation!
    }()

    private func run(
        configure: (UserDefaults) -> Void = { _ in },
        body: (CaptureService, ClipRepository, EncryptedBlobStore) throws -> Void
    ) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipySiShot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = UserDefaults(suiteName: "ClipySiShot-\(UUID().uuidString)")!
        DefaultsKeys.registerDefaults(in: defaults)
        configure(defaults)

        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
            $0.historyCipher = HistoryCipher(key: Self.testKey)
            $0.date = .constant(Make.epoch)
        } operation: {
            let blob = EncryptedBlobStore(directory: dir)
            let service = CaptureService(settings: AppSettings(defaults: defaults), blobStore: blob)
            try body(service, ClipRepository(), blob)
        }
    }

    @Test func buildsSingleTiffSnapshotWithoutPrivacyMarker() {
        let contents = ScreenshotCapture.pasteboardContents(tiff: Self.sampleTIFF, frontmostBundleID: "com.x.app")
        #expect(contents.typeIdentifiers == [NSPasteboard.PasteboardType.tiff.rawValue])
        #expect(contents.dataByType[NSPasteboard.PasteboardType.tiff.rawValue] == Self.sampleTIFF)
        #expect(contents.frontmostBundleID == "com.x.app")
        // No NSPasteboard privacy-marker type is present, so the capture marker gate passes (§6 d11).
        #expect(PrivacyMarkers.decision(forTypeIdentifiers: contents.typeIdentifiers) == .record)
    }

    @Test func capturesScreenshotAsEncryptedTiffClip() throws {
        try run { service, repo, blob in
            let contents = ScreenshotCapture.pasteboardContents(tiff: Self.sampleTIFF, frontmostBundleID: nil)
            let outcome = try service.capture(contents)
            guard case .stored = outcome else { Issue.record("expected .stored, got \(outcome)"); return }

            let clip = try #require(try repo.clips().first)
            #expect(clip.primaryType == NSPasteboard.PasteboardType.tiff.rawValue)
            // Encrypted at rest: the on-disk blob is ciphertext that decrypts back to the TIFF bytes.
            let decrypted = try blob.read(id: clip.dataPath)
            #expect(decrypted == Self.sampleTIFF)
            #expect(clip.titleCipher != Data("[TIFF]".utf8))
        }
    }

    @Test func honorsExcludeListForScreenshots() throws {
        try run { service, _, _ in
            try ExcludeAppRepository().add(bundleIdentifier: "com.secret.vault", name: "Vault")
            let contents = ScreenshotCapture.pasteboardContents(tiff: Self.sampleTIFF, frontmostBundleID: "com.secret.vault")
            let outcome = try service.capture(contents)
            #expect(outcome == .skippedExcludedApp)
        }
    }

    @Test func respectsDisabledTiffStoreType() throws {
        // Routing through CaptureService means the Type-pane "TIFF" toggle applies (unlike the
        // original's create(with:image:), which bypassed store-types).
        try run(configure: { $0.set(["TIFF": false], forKey: DefaultsKeys.storeTypes) }, body: { service, _, _ in
            let contents = ScreenshotCapture.pasteboardContents(tiff: Self.sampleTIFF, frontmostBundleID: nil)
            let outcome = try service.capture(contents)
            #expect(outcome == .skippedNoStorableType)
        })
    }
}
