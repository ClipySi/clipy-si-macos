//
//  CanonicalPayload.swift
//  ClipySi — Apple Silicon rewrite
//
//  The exact byte layout hashed into a clip's `contentHash`: every representation's type identifier
//  (in capture priority order) joined by "\n", then each representation's raw data appended. Capture
//  and history import MUST build this identically, so an imported clip dedupes against an
//  identically-captured one (design §2.2 — otherwise the same content gets two different HMACs and
//  dedupe never fires). Pure, so both paths share one source of truth.
//

import AppKit
import Foundation

enum CanonicalPayload {
    static func make(_ representations: [(typeID: String, data: Data)]) -> Data {
        var payload = Data(representations.map(\.typeID).joined(separator: "\n").utf8)
        for representation in representations {
            payload.append(representation.data)
        }
        return payload
    }

    /// Capture's type-priority order (CaptureService.storeTypeOrder), shared so the sync codec
    /// can rebuild the SAME representation ordering from DB rows — otherwise an identically
    /// captured multi-rep clip would hash differently across devices and cross-device dedupe
    /// (`syncHash`) would never fire.
    static let typePriority: [String] = [
        NSPasteboard.PasteboardType.string.rawValue,
        NSPasteboard.PasteboardType.rtf.rawValue,
        NSPasteboard.PasteboardType.rtfd.rawValue,
        NSPasteboard.PasteboardType.pdf.rawValue,
        NSPasteboard.PasteboardType.fileURL.rawValue,
        NSPasteboard.PasteboardType.URL.rawValue,
        NSPasteboard.PasteboardType.tiff.rawValue
    ]

    /// Sorts representations into the canonical hashing order (priority index; unknown types last,
    /// by type id for determinism).
    static func sortedForHashing(
        _ representations: [(typeID: String, data: Data)]
    ) -> [(typeID: String, data: Data)] {
        representations.sorted { lhs, rhs in
            let lhsRank = typePriority.firstIndex(of: lhs.typeID) ?? typePriority.count
            let rhsRank = typePriority.firstIndex(of: rhs.typeID) ?? typePriority.count
            return lhsRank == rhsRank ? lhs.typeID < rhs.typeID : lhsRank < rhsRank
        }
    }
}
