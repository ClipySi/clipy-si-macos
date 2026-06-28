//
//  HistoryImporterTests.swift
//  ClipyTests
//
//  The pure core of the History Manager's "Import" action: JSON history file → encrypted
//  store, idempotent (dedupe via the SAME HMAC capture uses), text-only, per-item isolation, with
//  malformed / unsupported-version rejection. The file picker + result alert are run-app verified.
//

import AppKit
import CryptoKit
import Foundation
import SQLiteData
import Testing
@testable import Clipy

@Suite struct HistoryImporterTests {
    private static let key = SymmetricKey(data: Data(repeating: 0x91, count: 32))
    private var cipher: HistoryCipher { HistoryCipher(key: Self.key) }

    private func freshDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "ClipySiImport-\(UUID().uuidString)")!
        DefaultsKeys.registerDefaults(in: defaults)
        return defaults
    }

    private func json(_ items: String, version: Int = 1) -> Data {
        Data("""
        { "version": \(version), "exportedAt": 1700000000, "items": [\(items)] }
        """.utf8)
    }

    private func item(_ text: String, createdAt: Int = 1_700_000_000,
                      app: String = "null", pinned: Bool = false) -> String {
        """
        { "createdAt": \(createdAt), "type": "public.utf8-plain-text", "app": \(app), "pinned": \(pinned), "text": "\(text)" }
        """
    }

    /// The stored clip whose decrypted title equals `title` (clips carry encrypted titles).
    private func clip(titled title: String) throws -> Clip? {
        try ClipRepository().clips().first {
            (try? cipher.open($0.titleCipher)).flatMap { String(bytes: $0, encoding: .utf8) } == title
        }
    }

    private func content(of clip: Clip, blob: EncryptedBlobStore) throws -> String {
        String(bytes: try blob.read(id: clip.dataPath), encoding: .utf8) ?? ""
    }

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ClipySiImport-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func importsTextItemsIntoStore() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
            $0.historyCipher = cipher
        } operation: {
            let blob = EncryptedBlobStore(directory: dir)
            let data = json([item("alpha", createdAt: 1_700_000_000, app: "\"com.a\"", pinned: true),
                             item("beta", createdAt: 1_700_000_100)].joined(separator: ","))

            let (result, importedIDs) = try HistoryImporter(blobStore: blob).importItems(from: data)
            #expect(result == HistoryImportResult(imported: 2, skipped: 0, failed: 0))
            #expect(importedIDs.count == 2) // ids of the new clips, for a possible cancel-rollback

            let storedCount = try ClipRepository().clips().count
            #expect(storedCount == 2)

            let alpha = try #require(try clip(titled: "alpha"))
            let beta = try #require(try clip(titled: "beta"))
            let alphaContent = try content(of: alpha, blob: blob)
            let betaContent = try content(of: beta, blob: blob)
            #expect(alphaContent == "alpha")
            #expect(betaContent == "beta")
            #expect(alpha.isPinned)
            #expect(alpha.sourceBundle == "com.a")
            #expect(alpha.createdAt == Date(timeIntervalSince1970: 1_700_000_000))
            #expect(!beta.isPinned)
            #expect(beta.sourceBundle == nil)
        }
    }

    @Test func reimportingTheSameFileSkipsDuplicates() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
            $0.historyCipher = cipher
        } operation: {
            let blob = EncryptedBlobStore(directory: dir)
            let data = json([item("one"), item("two")].joined(separator: ","))
            let importer = HistoryImporter(blobStore: blob)

            let (first, firstIDs) = try importer.importItems(from: data)
            #expect(first == HistoryImportResult(imported: 2, skipped: 0, failed: 0))
            #expect(firstIDs.count == 2)

            let (second, secondIDs) = try importer.importItems(from: data)
            #expect(second == HistoryImportResult(imported: 0, skipped: 2, failed: 0)) // idempotent
            #expect(secondIDs.isEmpty) // nothing newly inserted → nothing to roll back

            let count = try ClipRepository().clips().count
            #expect(count == 2) // no duplicates
        }
    }

    @Test func deletingImportedIDsRollsBackThatImportOnly() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
            $0.historyCipher = cipher
        } operation: {
            let blob = EncryptedBlobStore(directory: dir)
            let importer = HistoryImporter(blobStore: blob)

            // Baseline: one clip that must NOT be lost on rollback.
            _ = try importer.importItems(from: json(item("keep")))

            // A second import adds two new clips; its ids are what "Cancel" rolls back.
            let (result, importedIDs) = try importer.importItems(
                from: json([item("roll1"), item("roll2")].joined(separator: ",")))
            #expect(result.imported == 2)
            let afterImport = try ClipRepository().clips().count
            #expect(afterImport == 3)

            // Cancel == delete exactly those ids (+ GC blobs), mirroring AppDelegate.resolveHistoryOverflow.
            let repo = ClipRepository()
            for id in importedIDs {
                for path in try repo.delete(id: id) { try? blob.delete(id: path) }
            }

            // The baseline clip survives; the rolled-back ones are gone.
            let remaining = try repo.clips()
            #expect(remaining.count == 1)
            let keep = try clip(titled: "keep")
            let rolledBack = try clip(titled: "roll1")
            #expect(keep != nil)
            #expect(rolledBack == nil)
        }
    }

    @Test func importDedupesAgainstACapturedClip() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
            $0.historyCipher = cipher
            $0.date = .constant(Make.epoch)
        } operation: {
            let blob = EncryptedBlobStore(directory: dir)
            // Capture "shared" the normal way, then import a file containing the same text. The shared
            // CanonicalPayload must make both hash identically, so the import is skipped as a duplicate.
            let stringType = NSPasteboard.PasteboardType.string.rawValue
            let capture = CaptureService(settings: AppSettings(defaults: freshDefaults()), blobStore: blob)
            _ = try capture.capture(PasteboardContents(changeCount: 1, typeIdentifiers: [stringType],
                                                       dataByType: [stringType: Data("shared".utf8)],
                                                       frontmostBundleID: nil, sourceBundleID: nil))

            let (result, _) = try HistoryImporter(blobStore: blob).importItems(from: json(item("shared")))
            #expect(result == HistoryImportResult(imported: 0, skipped: 1, failed: 0))

            let count = try ClipRepository().clips().count
            #expect(count == 1) // still just the captured clip
        }
    }

    @Test func skipsEmptyTextItems() throws {
        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
            $0.historyCipher = cipher
        } operation: {
            let blob = EncryptedBlobStore(directory: FileManager.default.temporaryDirectory)
            let (result, _) = try HistoryImporter(blobStore: blob).importItems(from: json(item("")))
            #expect(result == HistoryImportResult(imported: 0, skipped: 1, failed: 0))

            let isEmpty = try ClipRepository().clips().isEmpty
            #expect(isEmpty)
        }
    }

    @Test func rejectsUnsupportedVersion() throws {
        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
            $0.historyCipher = cipher
        } operation: {
            let blob = EncryptedBlobStore(directory: FileManager.default.temporaryDirectory)
            #expect(throws: HistoryImporter.ImportError.unsupportedVersion(2)) {
                try HistoryImporter(blobStore: blob).importItems(from: json(item("x"), version: 2))
            }
        }
    }

    @Test func rejectsMalformedJSON() throws {
        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
            $0.historyCipher = cipher
        } operation: {
            let blob = EncryptedBlobStore(directory: FileManager.default.temporaryDirectory)
            #expect(throws: HistoryImporter.ImportError.malformed) {
                try HistoryImporter(blobStore: blob).importItems(from: Data("not json".utf8))
            }
        }
    }

    @Test func exportThenImportRoundTrips() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
            $0.historyCipher = cipher
            $0.date = .constant(Make.epoch)
        } operation: {
            let blob = EncryptedBlobStore(directory: dir)
            let stringType = NSPasteboard.PasteboardType.string.rawValue
            let capture = CaptureService(settings: AppSettings(defaults: freshDefaults()), blobStore: blob)
            _ = try capture.capture(PasteboardContents(changeCount: 1, typeIdentifiers: [stringType],
                                                       dataByType: [stringType: Data("round trip".utf8)],
                                                       frontmostBundleID: nil, sourceBundleID: "com.example"))

            let exported = try HistoryExporter(blobStore: blob).export()
            #expect(exported.exportedCount == 1)

            // Re-import the exported bytes into a fresh, empty store: the item comes back decryptable.
            try withDependencies {
                $0.defaultDatabase = try TestDatabase.make()
                $0.historyCipher = cipher
            } operation: {
                let (result, _) = try HistoryImporter(blobStore: blob).importItems(from: exported.data)
                #expect(result == HistoryImportResult(imported: 1, skipped: 0, failed: 0))

                let roundTripped = try #require(try clip(titled: "round trip"))
                let body = try content(of: roundTripped, blob: blob)
                #expect(body == "round trip")
            }
        }
    }
}
