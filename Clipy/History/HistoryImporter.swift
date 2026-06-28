//
//  HistoryImporter.swift
//  ClipySi — Apple Silicon rewrite
//
//  The testable core of the History Manager's "Import" action: read the JSON history format
//  this app exports and ingest each text item into the encrypted store. This is also the
//  migration interchange: the (non-shipped) Realm→JSON extractor emits the SAME format, so the app
//  itself stays Realm-free — it only ever reads JSON.
//
//  Idempotent: each item is keyed-HMAC hashed via the SAME `CanonicalPayload` capture uses, then
//  ingested with `copySameHistory: false`, so a clip whose content already exists is SKIPPED (no
//  duplicate, no reordering) — re-importing the same file is a no-op. Per-item isolation: a single
//  bad item is counted as `failed` and the rest still import (no content is logged, only counts).
//

import AppKit
import Foundation
import SQLiteData

struct HistoryImporter {
    @Dependency(\.historyCipher) private var cipher
    private let clips = ClipRepository()
    private let blobStore: EncryptedBlobStore

    init(blobStore: EncryptedBlobStore) {
        self.blobStore = blobStore
    }

    enum ImportError: Error, Equatable {
        case malformed
        case unsupportedVersion(Int)
    }

    /// Decodes the JSON and ingests every text item, returning how many were imported vs. skipped
    /// (empty or duplicate) vs. failed, plus the ids of the clips that were newly inserted (so the
    /// caller can roll the import back — e.g. if the user cancels the over-limit prompt). Throws only
    /// for a file that isn't a valid history export (malformed JSON, or a `version` this build doesn't
    /// understand); individual item errors are isolated into the `failed` count.
    func importItems(from data: Data) throws -> (result: HistoryImportResult, importedIDs: [Clip.ID]) {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw ImportError.malformed
        }
        guard payload.version == HistoryExportResult.formatVersion else {
            throw ImportError.unsupportedVersion(payload.version)
        }

        var importedIDs: [Clip.ID] = []
        var skipped = 0, failed = 0
        for item in payload.items {
            do {
                switch try ingest(item) {
                case .imported(let id): importedIDs.append(id)
                case .skipped: skipped += 1
                }
            } catch {
                failed += 1 // per-item isolation; never log the offending content
            }
        }
        return (HistoryImportResult(imported: importedIDs.count, skipped: skipped, failed: failed), importedIDs)
    }

    private enum Ingested { case imported(Clip.ID), skipped }

    private func ingest(_ item: Item) throws -> Ingested {
        let text = item.text
        guard !text.isEmpty else { return .skipped } // mirror capture's empty-string guard

        let stringType = NSPasteboard.PasteboardType.string.rawValue
        let titlePreview = String(text.prefix(10_000)) // matches capture's title truncation
        let textData = Data(text.utf8)
        let titleCipher = try cipher.seal(Data(titlePreview.utf8))
        let contentHash = cipher.contentHash(CanonicalPayload.make([(stringType, textData)]))

        // Write the blob first, then ingest; if the content already exists (copySameHistory: false →
        // skip), GC the now-orphaned blob so import leaves no stray ciphertext.
        let path = try blobStore.write(textData)
        let clip = Clip(
            id: UUID(),
            contentHash: contentHash,
            titleCipher: titleCipher,
            primaryType: stringType,
            createdAt: Date(timeIntervalSince1970: TimeInterval(item.createdAt)),
            isPinned: item.pinned,
            isColorCode: ColorCode.isColorCode(titlePreview),
            dataPath: path,
            thumbnailID: nil,
            sourceBundle: item.app
        )
        let storedID = try clips.ingest(clip, representations: [],
                                        copySameHistory: false, overwriteSameHistory: false)
        guard let storedID else {
            try? blobStore.delete(id: path)
            return .skipped
        }
        return .imported(storedID)
    }

    private struct Payload: Decodable {
        let version: Int
        let items: [Item]
    }

    /// The text-only fields the importer reads. `type` is intentionally ignored — this format is
    /// text-only, so every item is stored as plain text (and hashed as such for dedupe).
    private struct Item: Decodable {
        let createdAt: Int
        let app: String?
        let pinned: Bool
        let text: String
    }
}

/// The result of an import: how many items were newly imported vs. skipped (empty / duplicate) vs.
/// failed (a per-item error), so the History Manager can report it.
struct HistoryImportResult: Equatable {
    let imported: Int
    let skipped: Int
    let failed: Int
}

/// The outcome handed back to the History Manager view: a per-item summary on success (plus, when the
/// import pushed the history past the max-history setting, the info the overflow prompt needs), or an
/// already-localized message when the file itself can't be imported (missing store / malformed /
/// unsupported version). Lets AppDelegate own the blob store + error wording while the view renders.
enum HistoryImportOutcome: Equatable {
    case success(HistoryImportResult, overflow: HistoryImportOverflow?)
    case failure(message: String)
}

/// Describes an import that left the history above the max-history setting, so the view can ask the
/// user whether to raise the limit or drop the oldest items. Computed by AppDelegate (it owns the
/// clip count + setting); the actual resolution runs back through `HistoryImportOverflowResolution`.
struct HistoryImportOverflow: Equatable {
    /// Total clips in the store right after the import (existing + newly imported).
    let totalAfterImport: Int
    /// The current `maxHistorySize` setting the total now exceeds.
    let currentLimit: Int
    /// The limit to offer ("Increase to …") — a 10-unit value above `totalAfterImport`.
    let suggestedLimit: Int
}

/// The user's answer to the overflow prompt: raise the cap so everything fits, keep the cap and let the
/// oldest items beyond it be deleted, or cancel — which rolls the just-imported clips back out.
enum HistoryImportOverflowResolution: Equatable {
    case increaseLimit(Int)
    case removeOldest
    case cancelImport
}
