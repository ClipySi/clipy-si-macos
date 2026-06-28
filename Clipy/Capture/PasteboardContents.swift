//
//  PasteboardContents.swift
//  ClipySi — Apple Silicon rewrite
//
//  A Sendable snapshot of what is on a pasteboard at one `changeCount`. The live reader builds
//  this from `NSPasteboard.general` on the main actor; `CaptureService` and tests consume it,
//  so the security-critical capture logic is exercised without ever touching the real
//  pasteboard (security-guidance.md §10 / R7).
//

import Foundation

struct PasteboardContents: Sendable {
    /// The pasteboard's `changeCount` when this snapshot was taken.
    var changeCount: Int
    /// All declared type identifiers — inspected for privacy markers BEFORE content is read (R1).
    var typeIdentifiers: [String]
    /// Raw bytes per type identifier that were actually read.
    var dataByType: [String: Data]
    /// Bundle id of the frontmost app when the copy happened (for the exclude-app gate).
    var frontmostBundleID: String?
    /// `org.nspasteboard.source` bundle id, if the writer declared one.
    var sourceBundleID: String?

    init(changeCount: Int,
         typeIdentifiers: [String],
         dataByType: [String: Data],
         frontmostBundleID: String? = nil,
         sourceBundleID: String? = nil) {
        self.changeCount = changeCount
        self.typeIdentifiers = typeIdentifiers
        self.dataByType = dataByType
        self.frontmostBundleID = frontmostBundleID
        self.sourceBundleID = sourceBundleID
    }

    /// UTF-8 text for a type, if present.
    func string(forType type: String) -> String? {
        dataByType[type].flatMap { String(data: $0, encoding: .utf8) }
    }
}
