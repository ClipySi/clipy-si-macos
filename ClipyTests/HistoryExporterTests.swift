//
//  HistoryExporterTests.swift
//  ClipyTests
//
//  The pure core of the History Manager's "Export" action: whole-history → plaintext JSON,
//  with non-text / unreadable clips skipped + counted (never silently dropped). The save panel,
//  plaintext-warning dialog, and result alert are run-app verified, not here.
//

import AppKit
import CryptoKit
import Foundation
import SQLiteData
import Testing
@testable import Clipy

@Suite struct HistoryExporterTests {
    private static let key = SymmetricKey(data: Data(repeating: 0x3E, count: 32))
    private var cipher: HistoryCipher { HistoryCipher(key: Self.key) }

    private func freshDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "ClipySiExport-\(UUID().uuidString)")!
        DefaultsKeys.registerDefaults(in: defaults)
        return defaults
    }

    private func capture(_ contents: PasteboardContents, into blob: EncryptedBlobStore) throws {
        let service = CaptureService(settings: AppSettings(defaults: freshDefaults()), blobStore: blob)
        _ = try service.capture(contents)
    }

    private func textContents(_ body: String, app: String? = nil) -> PasteboardContents {
        let stringType = NSPasteboard.PasteboardType.string.rawValue
        return PasteboardContents(changeCount: 1, typeIdentifiers: [stringType],
                                  dataByType: [stringType: Data(body.utf8)],
                                  frontmostBundleID: nil, sourceBundleID: app)
    }

    /// Parses the export JSON into (top-level object, items array) without force-casts.
    private func parse(_ data: Data) throws -> (object: [String: Any], items: [[String: Any]]) {
        let parsed = try JSONSerialization.jsonObject(with: data)
        let object = try #require(parsed as? [String: Any])
        let items = try #require(object["items"] as? [[String: Any]])
        return (object, items)
    }

    @Test func exportsTextItemsWithMetadata() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipySiExport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
            $0.historyCipher = cipher
            $0.date = .constant(Make.epoch)
        } operation: {
            let blob = EncryptedBlobStore(directory: dir)
            try capture(textContents("first body", app: "com.example.A"), into: blob)
            try capture(textContents("second body", app: "com.example.B"), into: blob)
            // Pin one clip so the exported `pinned` flag is exercised (capture always starts unpinned).
            let repo = ClipRepository()
            let allClips = try repo.clips()
            let pinnedID = try #require(allClips.first?.id)
            try repo.setPinned(true, id: pinnedID)

            let result = try HistoryExporter(blobStore: blob).export()
            #expect(result.exportedCount == 2)
            #expect(result.skippedCount == 0)

            let (object, items) = try parse(result.data)
            #expect(object["version"] as? Int == HistoryExportResult.formatVersion)
            #expect(object["exportedAt"] as? Int == Int(Make.epoch.timeIntervalSince1970))
            #expect(items.count == 2)
            #expect(Set(items.compactMap { $0["text"] as? String }) == ["first body", "second body"])
            #expect(Set(items.compactMap { $0["app"] as? String }) == ["com.example.A", "com.example.B"])
            #expect(items.allSatisfy { ($0["createdAt"] as? Int) == Int(Make.epoch.timeIntervalSince1970) })
            #expect(items.contains { ($0["pinned"] as? Bool) == true })
        }
    }

    @Test func skipsNonTextClips() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipySiExport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
            $0.historyCipher = cipher
            $0.date = .constant(Make.epoch)
        } operation: {
            let blob = EncryptedBlobStore(directory: dir)
            try capture(textContents("keep me"), into: blob)
            let tiff = NSPasteboard.PasteboardType.tiff.rawValue
            try capture(PasteboardContents(changeCount: 1, typeIdentifiers: [tiff],
                                           dataByType: [tiff: Data([0x4D, 0x4D, 0x00, 0x2A])],
                                           frontmostBundleID: nil, sourceBundleID: nil), into: blob)

            let result = try HistoryExporter(blobStore: blob).export()
            #expect(result.exportedCount == 1)
            #expect(result.skippedCount == 1)

            let (_, items) = try parse(result.data)
            #expect(items.count == 1)
            #expect(items.first?["text"] as? String == "keep me")
        }
    }

    @Test func skipsUnreadableBlob() throws {
        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
            $0.date = .constant(Make.epoch)
        } operation: {
            // A string clip whose `dataPath` points at a file that isn't in the store → read fails →
            // skipped (not exported, not crashed).
            try ClipRepository().add(Make.clip(title: "orphan"))
            let result = try HistoryExporter(blobStore: EncryptedBlobStore(directory: FileManager.default.temporaryDirectory))
                .export()
            #expect(result.exportedCount == 0)
            #expect(result.skippedCount == 1)

            let (_, items) = try parse(result.data)
            #expect(items.isEmpty)
        }
    }

    @Test func emptyHistoryExportsEmptyItems() throws {
        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
            $0.date = .constant(Make.epoch)
        } operation: {
            let result = try HistoryExporter(blobStore: EncryptedBlobStore(directory: FileManager.default.temporaryDirectory))
                .export()
            #expect(result.exportedCount == 0)
            #expect(result.skippedCount == 0)

            let (object, items) = try parse(result.data)
            #expect(items.isEmpty)
            #expect(object["version"] as? Int == HistoryExportResult.formatVersion)
        }
    }
}
