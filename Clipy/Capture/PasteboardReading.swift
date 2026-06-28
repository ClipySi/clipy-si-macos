//
//  PasteboardReading.swift
//  ClipySi — Apple Silicon rewrite
//
//  Abstraction over the system pasteboard so `PasteboardMonitor` can be unit-tested with a stub
//  (the real `NSPasteboard.general` is never touched in tests — security-guidance.md §10).
//
//  Reading is split so content is only read when we actually intend to record (R1): the monitor
//  checks `typeIdentifiers()` for privacy markers first, and calls `readContents()` (which
//  touches the data) only for recordable clips.
//

import AppKit

@MainActor
protocol PasteboardReading {
    var changeCount: Int { get }
    /// Declared type identifiers only — cheap, and read before any content (R1 gate input).
    func typeIdentifiers() -> [String]
    /// Reads the actual content. Call only after the privacy gate allows recording.
    func readContents() -> PasteboardContents
}

@MainActor
final class SystemPasteboard: PasteboardReading {
    private let pasteboard: NSPasteboard

    init(_ pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int { pasteboard.changeCount }

    func typeIdentifiers() -> [String] {
        (pasteboard.types ?? []).map(\.rawValue)
    }

    func readContents() -> PasteboardContents {
        let types = pasteboard.types ?? []
        var dataByType: [String: Data] = [:]
        for type in types where !type.rawValue.hasPrefix("org.nspasteboard.") {
            // Skip the marker types themselves; read only real content representations.
            if let data = pasteboard.data(forType: type) {
                dataByType[type.rawValue] = data
            }
        }
        let source = pasteboard.string(forType: NSPasteboard.PasteboardType(PrivacyMarkers.source))
        return PasteboardContents(
            changeCount: pasteboard.changeCount,
            typeIdentifiers: types.map(\.rawValue),
            dataByType: dataByType,
            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            sourceBundleID: source
        )
    }
}
