//
//  HistoryExporter.swift
//  ClipySi — Apple Silicon rewrite
//
//  The testable core of the History Manager's "Export" action: decrypt the whole history and
//  serialize the plain-text items to JSON. `EncryptedBlobStore.read` returns the decrypted bytes, so
//  the output file is UNENCRYPTED — the view warns before writing (design §5 R2). Only plain-text
//  clips are exported (`primaryType == string`, the same rule SnippetMaker uses); non-text and
//  unreadable clips are skipped and counted, never silently dropped (the caller reports the count).
//
//  No content is logged here: a read/decode failure increments the skip count rather than logging the
//  offending clip, so plaintext never reaches os_log (security-guidance.md §5).
//

import AppKit
import Foundation
import SQLiteData

struct HistoryExporter {
    @Dependency(\.date) private var date
    private let clips = ClipRepository()
    private let blobStore: EncryptedBlobStore

    init(blobStore: EncryptedBlobStore) {
        self.blobStore = blobStore
    }

    /// Builds the JSON export of every plain-text history item (newest first), plus the exported /
    /// skipped counts for the caller's result alert.
    func export() throws -> HistoryExportResult {
        var items: [Item] = []
        var skipped = 0
        for clip in try clips.clips() {
            if let item = item(for: clip) { items.append(item) } else { skipped += 1 }
        }
        let payload = Payload(version: HistoryExportResult.formatVersion,
                              exportedAt: Int(date.now.timeIntervalSince1970),
                              items: items)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return HistoryExportResult(data: try encoder.encode(payload),
                                   exportedCount: items.count,
                                   skippedCount: skipped)
    }

    /// One export record, or nil for a non-text / unreadable clip (skipped, not exported).
    private func item(for clip: Clip) -> Item? {
        guard clip.primaryType == NSPasteboard.PasteboardType.string.rawValue else { return nil }
        guard let bytes = try? blobStore.read(id: clip.dataPath),
              let text = String(bytes: bytes, encoding: .utf8) else { return nil }
        return Item(createdAt: Int(clip.createdAt.timeIntervalSince1970),
                    type: clip.primaryType,
                    app: clip.sourceBundle,
                    pinned: clip.isPinned,
                    text: text)
    }

    private struct Payload: Encodable {
        let version: Int
        let exportedAt: Int
        let items: [Item]
    }

    private struct Item: Encodable {
        let createdAt: Int
        let type: String
        let app: String?
        let pinned: Bool
        let text: String
    }
}

/// The result of an export: the encoded JSON plus what was exported vs. skipped (so the History
/// Manager can report "Exported N items (K skipped)" and feed `data` to the file panel).
struct HistoryExportResult: Equatable {
    /// The `version` field written into the JSON, so an importer can branch on format.
    static let formatVersion = 1

    let data: Data
    let exportedCount: Int
    let skippedCount: Int
}
