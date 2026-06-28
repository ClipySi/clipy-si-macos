//
//  HistoryExtractorTests.swift
//  ClipyRealmExportKitTests
//
//  Verifies the extractor against SYNTHETIC fixtures (a temp Realm + `.data` archives built in the
//  original's keyed-archive shape) — no real user data. Covers secure-decode of text vs image-only
//  vs corrupt archives, and the full Realm → JSON path including skip counting.
//

import Foundation
import RealmSwift
import Testing
@testable import ClipyRealmExportKit

@Suite struct HistoryExtractorTests {
    private static let epoch = 1_700_000_000

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipy-realm-export-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Builds a `.data` archive in the original Clipy shape: root class name "CPYClipData", keys
    /// `types` + `stringValue` (the shim is reused as the encoder, mapped to that class name).
    private func makeDataArchive(types: [String], stringValue: String) -> Data {
        let shim = CPYClipDataShim(types: types, stringValue: stringValue)
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.setClassName(ClipDataDecoder.archivedClassName, for: CPYClipDataShim.self)
        archiver.encode(shim, forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    /// Creates a realm at a fresh path with the given clips; returns its URL (the Realm instance is
    /// released when this returns, so the extractor opens a clean copy).
    private func makeRealm(in dir: URL, clips: [(dataHash: String, dataPath: String, updateTime: Int)]) throws -> URL {
        let url = dir.appendingPathComponent("default.realm")
        let config = Realm.Configuration(fileURL: url, schemaVersion: 7, objectTypes: [CPYClip.self])
        let realm = try Realm(configuration: config)
        try realm.write {
            for spec in clips {
                let clip = CPYClip()
                clip.dataHash = spec.dataHash
                clip.dataPath = spec.dataPath
                clip.updateTime = spec.updateTime
                realm.add(clip)
            }
        }
        return url
    }

    private func parse(_ data: Data) throws -> (object: [String: Any], items: [[String: Any]]) {
        let parsed = try JSONSerialization.jsonObject(with: data)
        let object = try #require(parsed as? [String: Any])
        let items = try #require(object["items"] as? [[String: Any]])
        return (object, items)
    }

    // MARK: - Secure decode

    @Test func decodesPlainTextFromArchive() {
        let data = makeDataArchive(types: ["public.utf8-plain-text"], stringValue: "hello world")
        #expect(ClipDataDecoder.plainText(fromArchivedData: data) == "hello world")
    }

    @Test func imageOnlyArchiveYieldsNoText() {
        // No stringValue (image-bearing clip) → not text → nil. The `image` key is never decoded.
        let data = makeDataArchive(types: ["public.tiff"], stringValue: "")
        #expect(ClipDataDecoder.plainText(fromArchivedData: data) == nil)
    }

    @Test func corruptArchiveYieldsNoTextWithoutCrashing() {
        #expect(ClipDataDecoder.plainText(fromArchivedData: Data("not an archive".utf8)) == nil)
    }

    // MARK: - Full extraction

    @Test func exportsTextClipsFromRealm() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dataDir = dir.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        let firstData = dataDir.appendingPathComponent("a.data")
        let secondData = dataDir.appendingPathComponent("b.data")
        try makeDataArchive(types: ["public.utf8-plain-text"], stringValue: "first").write(to: firstData)
        try makeDataArchive(types: ["public.utf8-plain-text"], stringValue: "second").write(to: secondData)

        let realmURL = try makeRealm(in: dir, clips: [
            (dataHash: "h1", dataPath: firstData.path, updateTime: Self.epoch),
            (dataHash: "h2", dataPath: secondData.path, updateTime: Self.epoch + 100)
        ])

        let options = HistoryExtractor.Options(realmURL: realmURL, dataDirectory: dataDir)
        let (json, summary) = try HistoryExtractor().export(options: options,
                                                            now: Date(timeIntervalSince1970: TimeInterval(Self.epoch)))
        #expect(summary == HistoryExtractor.Summary(exported: 2, skipped: 0))

        let (object, items) = try parse(json)
        #expect(object["version"] as? Int == historyExportFormatVersion)
        #expect(object["exportedAt"] as? Int == Self.epoch)
        #expect(items.count == 2)
        #expect(Set(items.compactMap { $0["text"] as? String }) == ["first", "second"])
        #expect(items.allSatisfy { ($0["type"] as? String) == plainTextTypeIdentifier })
        #expect(items.contains { ($0["createdAt"] as? Int) == Self.epoch + 100 })
    }

    @Test func skipsMissingAndImageOnlyClips() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dataDir = dir.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        let textData = dataDir.appendingPathComponent("ok.data")
        let imageData = dataDir.appendingPathComponent("img.data")
        try makeDataArchive(types: ["public.utf8-plain-text"], stringValue: "keep").write(to: textData)
        try makeDataArchive(types: ["public.tiff"], stringValue: "").write(to: imageData)

        let realmURL = try makeRealm(in: dir, clips: [
            (dataHash: "ok", dataPath: textData.path, updateTime: Self.epoch),
            (dataHash: "img", dataPath: imageData.path, updateTime: Self.epoch),
            (dataHash: "gone", dataPath: dataDir.appendingPathComponent("missing.data").path, updateTime: Self.epoch)
        ])

        let options = HistoryExtractor.Options(realmURL: realmURL, dataDirectory: dataDir)
        let (json, summary) = try HistoryExtractor().export(options: options, now: Date(timeIntervalSince1970: 0))
        #expect(summary == HistoryExtractor.Summary(exported: 1, skipped: 2))

        let (_, items) = try parse(json)
        #expect(items.count == 1)
        #expect(items.first?["text"] as? String == "keep")
    }

    @Test func resolvesDataByBasenameWhenAbsolutePathMoved() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dataDir = dir.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        // The blob exists in dataDir under its basename, but the realm's stored absolute path is stale.
        try makeDataArchive(types: ["public.utf8-plain-text"], stringValue: "moved").write(
            to: dataDir.appendingPathComponent("c.data"))
        let realmURL = try makeRealm(in: dir, clips: [
            (dataHash: "h", dataPath: "/old/machine/path/c.data", updateTime: Self.epoch)
        ])

        let options = HistoryExtractor.Options(realmURL: realmURL, dataDirectory: dataDir)
        let (json, summary) = try HistoryExtractor().export(options: options, now: Date(timeIntervalSince1970: 0))
        #expect(summary == HistoryExtractor.Summary(exported: 1, skipped: 0))
        let (_, items) = try parse(json)
        #expect(items.first?["text"] as? String == "moved")
    }
}
