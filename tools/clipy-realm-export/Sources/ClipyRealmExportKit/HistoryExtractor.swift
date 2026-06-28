//
//  HistoryExtractor.swift
//  ClipyRealmExportKit
//
//  Reads the original Clipy history (Realm + per-clip `.data` archives) and produces the ClipySi
//  History Manager JSON (format), text-only. Safety: the original `default.realm` is copied
//  (body only) to a temp dir before opening, and every `.data` is read-only + secure-decoded; the
//  originals are never written. No clip text is ever logged — only counts.
//

import Foundation
import RealmSwift

public struct HistoryExtractor {
    public struct Options {
        /// The original meta DB, e.g. ~/Library/Application Support/com.clipy-app.Clipy/default.realm
        public var realmURL: URL
        /// Where the per-clip `.data` blobs live, e.g. ~/Library/Application Support/Clipy
        public var dataDirectory: URL

        public init(realmURL: URL, dataDirectory: URL) {
            self.realmURL = realmURL
            self.dataDirectory = dataDirectory
        }
    }

    public struct Summary: Equatable {
        public let exported: Int
        public let skipped: Int
    }

    public init() {}

    /// Builds the JSON for every text clip in the realm, plus exported/skipped counts. `now` stamps
    /// `exportedAt` (injected so tests are deterministic).
    public func export(options: Options, now: Date) throws -> (data: Data, summary: Summary) {
        let (items, skipped) = try readItems(options: options)
        let file = ExportFile(exportedAt: Int(now.timeIntervalSince1970), items: items)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try encoder.encode(file), Summary(exported: items.count, skipped: skipped))
    }

    private func readItems(options: Options) throws -> (items: [ExportItem], skipped: Int) {
        let tempDir = try copyRealmBody(at: options.realmURL)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Read everything into value types here, so the realm/temp copy can be torn down on return.
        var items: [ExportItem] = []
        var skipped = 0
        let realm = try openClipRealm(at: tempDir.appendingPathComponent("default.realm"))
        for clip in realm.objects(CPYClip.self) {
            guard let dataURL = resolveDataURL(clip.dataPath, in: options.dataDirectory),
                  let archived = try? Data(contentsOf: dataURL),
                  let text = ClipDataDecoder.plainText(fromArchivedData: archived) else {
                skipped += 1 // non-text / missing / undecodable — never log the clip
                continue
            }
            items.append(ExportItem(createdAt: clip.updateTime, text: text))
        }
        return (items, skipped)
    }

    /// Copies ONLY the realm body to a fresh 0700 temp dir (NOT the `.lock`/`.management`/`.note`
    /// sidecars), so we never open or mutate the original — even while the product app is running.
    private func copyRealmBody(at url: URL) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipy-realm-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.copyItem(at: url, to: tempDir.appendingPathComponent("default.realm"))
        return tempDir
    }

    private func openClipRealm(at url: URL) throws -> Realm {
        // The original's on-disk schema has advanced past the 7 in repos/Clipy (e.g. v1.2.1 ships
        // schemaVersion 9), and the file may also be in an OLDER Realm file format (it was written by
        // RealmSwift 10.x). So we must NOT pin a fixed/lower schemaVersion — Realm would reject the file
        // as an impossible "downgrade" ("unsupported version (N) and cannot be upgraded"). Instead read
        // the file's own schema version and open ONE above it, read-write on the throwaway copy, so
        // Realm both upgrades the file format and drops the columns we don't model. The empty
        // migrationBlock is correct because we only read dataHash/dataPath/updateTime — stable across
        // every Clipy schema. objectTypes limits the schema to CPYClip.
        let onDiskVersion = try schemaVersionAtURL(url)
        let config = Realm.Configuration(
            fileURL: url,
            schemaVersion: onDiskVersion + 1,
            migrationBlock: { _, _ in },
            objectTypes: [CPYClip.self]
        )
        return try Realm(configuration: config)
    }

    /// The clip's `.data` file: its stored absolute `dataPath` if present, else the same basename in
    /// the known data directory (the store may have moved between machines/releases).
    private func resolveDataURL(_ dataPath: String, in dataDirectory: URL) -> URL? {
        guard !dataPath.isEmpty else { return nil }
        let direct = URL(fileURLWithPath: dataPath)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        let byBasename = dataDirectory.appendingPathComponent(direct.lastPathComponent)
        if FileManager.default.fileExists(atPath: byBasename.path) { return byBasename }
        return nil
    }
}
