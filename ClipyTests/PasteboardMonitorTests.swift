//
//  PasteboardMonitorTests.swift
//  ClipyTests
//

import AppKit
import Foundation
import Testing
@testable import Clipy

@MainActor
private final class StubPasteboard: PasteboardReading {
    var changeCount = 0
    var types: [String] = []
    var dataByType: [String: Data] = [:]
    var frontmost: String?
    var source: String?
    private(set) var readContentsCallCount = 0

    func typeIdentifiers() -> [String] { types }

    func readContents() -> PasteboardContents {
        readContentsCallCount += 1
        return PasteboardContents(
            changeCount: changeCount,
            typeIdentifiers: types,
            dataByType: dataByType,
            frontmostBundleID: frontmost,
            sourceBundleID: source
        )
    }
}

@MainActor
private final class Collector {
    var contents: [PasteboardContents] = []
}

@Suite @MainActor struct PasteboardMonitorTests {
    private let stringType = NSPasteboard.PasteboardType.string.rawValue

    private func makeMonitor(_ pasteboard: StubPasteboard) -> (PasteboardMonitor, Collector) {
        let collector = Collector()
        let monitor = PasteboardMonitor(pasteboard: pasteboard) { collector.contents.append($0) }
        return (monitor, collector)
    }

    @Test func capturesWhenChangeCountAdvances() {
        let pasteboard = StubPasteboard()
        pasteboard.changeCount = 1
        pasteboard.types = [stringType]
        let (monitor, collector) = makeMonitor(pasteboard) // baselines lastChangeCount = 1

        pasteboard.changeCount = 2
        monitor.poll()

        #expect(collector.contents.count == 1)
    }

    @Test func ignoresUnchangedPasteboard() {
        let pasteboard = StubPasteboard()
        pasteboard.changeCount = 4
        pasteboard.types = [stringType]
        let (monitor, collector) = makeMonitor(pasteboard)

        monitor.poll() // changeCount still 4

        #expect(collector.contents.isEmpty)
    }

    @Test func transientChangeSkipsWithoutReadingContent() {
        let pasteboard = StubPasteboard()
        pasteboard.types = [stringType, PrivacyMarkers.transient]
        let (monitor, collector) = makeMonitor(pasteboard) // baseline 0

        pasteboard.changeCount = 1
        monitor.poll()

        #expect(collector.contents.isEmpty)
        #expect(pasteboard.readContentsCallCount == 0) // R1: content never read
    }

    @Test func markSeenSuppressesSelfWrite() {
        let pasteboard = StubPasteboard()
        pasteboard.types = [stringType]
        let (monitor, collector) = makeMonitor(pasteboard)

        pasteboard.changeCount = 9 // we just wrote (a paste)
        monitor.markSeen()
        monitor.poll()

        #expect(collector.contents.isEmpty)
    }
}
