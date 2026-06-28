//
//  PanelPreviewProviderTests.swift
//  ClipyTests
//
//  The rich preview's lazy loader and its SECURITY rules: a masked-secret (or
//  decrypt-failed) row must NEVER reach the loader (zero blob decode — reveal is AuthGate-only),
//  textual kinds never load, the per-open cache is tiny (LRU ≤5), and clear() (the controller's
//  hide() hook) destroys everything decoded. Synthetic rows + a recording fake loader only.
//

import AppKit
import Testing
@testable import Clipy

/// Records loader invocations across the @Sendable boundary.
private actor LoaderLog {
    /// Every clip id the loader was asked to resolve, in order.
    private(set) var calls: [UUID] = []

    func record(_ id: UUID) { calls.append(id) }
}

@MainActor
@Suite struct PanelPreviewProviderTests {
    /// A tiny valid PNG (2×2), generated in-process — no fixture file, no real clipboard content.
    private static func tinyPNG() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    private func makeProvider(log: LoaderLog,
                              payload: PanelPreviewContentProvider.LoadedPayload? = .fileInfo(byteSize: 10))
        -> PanelPreviewContentProvider {
        PanelPreviewContentProvider { id, _ in
            await log.record(id)
            return payload
        }
    }

    private func imageRow(_ id: UUID, isSecret: Bool = false, decryptFailed: Bool = false) -> PanelRow {
        .clip(id, title: "(Image)", isSecret: isSecret, decryptFailed: decryptFailed, contentKind: .image)
    }

    @Test func maskedSecretRowNeverReachesTheLoader() async {
        let log = LoaderLog()
        let provider = makeProvider(log: log)
        provider.request(imageRow(UUID(), isSecret: true))
        provider.request(imageRow(UUID(), decryptFailed: true))
        // No pending task may even have been scheduled for gated rows.
        #expect(provider.pendingLoad == nil)
        #expect(await log.calls.isEmpty)
    }

    @Test func textualKindsNeverLoad() async {
        let log = LoaderLog()
        let provider = makeProvider(log: log)
        let id = UUID()
        provider.request(.clip(id, title: "hello"))
        provider.request(.clip(id, title: "let x = 1", contentKind: .code, codeLanguage: "Swift"))
        provider.request(.clip(id, title: "https://example.test", contentKind: .url))
        provider.request(.clip(id, title: "#aabbcc", contentKind: .color))
        provider.request(.snippet(UUID(), title: "sig"))
        #expect(provider.pendingLoad == nil)
        #expect(await log.calls.isEmpty)
    }

    @Test func imageRowLoadsCachesAndDeduplicates() async {
        let log = LoaderLog()
        let meta = PanelPreviewContentProvider.ImageMeta(pixelWidth: 1, pixelHeight: 1, byteSize: 8)
        let provider = makeProvider(log: log, payload: .imageData(Self.tinyPNG(), meta: meta))
        let id = UUID()
        let row = imageRow(id)
        provider.request(row)
        await provider.pendingLoad?.value
        guard case .image(_, let resolvedMeta) = provider.content(for: row) else {
            Issue.record("expected a resolved image thumbnail")
            return
        }
        #expect(resolvedMeta == meta) // the original-image facts ride along with the thumbnail
        // A second request for the cached row schedules nothing.
        provider.request(row)
        #expect(provider.pendingLoad == nil)
        let calls = await log.calls
        #expect(calls == [id])
    }

    @Test func undecodableImageDataResolvesNothing() async {
        let log = LoaderLog()
        let provider = makeProvider(log: log, payload: .imageData(Data("not an image".utf8), meta: nil))
        let row = imageRow(UUID())
        provider.request(row)
        await provider.pendingLoad?.value
        #expect(provider.content(for: row) == nil)
    }

    @Test func clearDestroysEverythingDecoded() async {
        let log = LoaderLog()
        let provider = makeProvider(log: log, payload: .imageData(Self.tinyPNG(), meta: nil))
        let row = imageRow(UUID())
        provider.request(row)
        await provider.pendingLoad?.value
        #expect(provider.content(for: row) != nil)
        provider.clear() // the controller's hide() hook
        #expect(provider.content(for: row) == nil)
        #expect(provider.resolved.isEmpty)
        #expect(provider.pendingLoad == nil)
    }

    @Test func cacheEvictsTheOldestBeyondTheLimit() async {
        let log = LoaderLog()
        let provider = makeProvider(log: log) // fileInfo payload — no image decode needed
        var rows: [PanelRow] = []
        for _ in 0..<(PanelPreviewContentProvider.cacheLimit + 1) {
            let row = PanelRow.clip(UUID(), title: "(PDF)", contentKind: .pdf)
            rows.append(row)
            provider.request(row)
            await provider.pendingLoad?.value
        }
        #expect(provider.resolved.count == PanelPreviewContentProvider.cacheLimit)
        #expect(provider.content(for: rows.first) == nil) // oldest evicted
        #expect(provider.content(for: rows.last) != nil)
    }

    @Test func reRequestCancelsThePriorPendingLoad() async {
        let log = LoaderLog()
        let provider = makeProvider(log: log)
        let first = imageRow(UUID())
        let second = PanelRow.clip(UUID(), title: "(PDF)", contentKind: .pdf)
        provider.request(first)
        provider.request(second) // selection moved on before the debounce fired
        await provider.pendingLoad?.value
        let calls = await log.calls
        #expect(!calls.contains(first.clipID ?? UUID()))
        #expect(provider.content(for: second) != nil)
    }
}

private extension PanelRow {
    var clipID: UUID? {
        if case .clip(let id) = id { return id }
        return nil
    }
}
