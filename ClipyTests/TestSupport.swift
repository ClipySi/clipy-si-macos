//
//  TestSupport.swift
//  ClipyTests
//
//  Shared helpers: a fresh in-memory database (running the real v1 migration) and value
//  factories. Tests inject the database via swift-dependencies so repositories pick it up
//  through `@Dependency(\.defaultDatabase)` — no on-disk file, no system permissions.
//

import Foundation
import SQLiteData
@testable import Clipy

enum TestDatabase {
    /// A private in-memory database with the production schema (v1 migration) applied.
    /// FK enforcement is on (GRDB default), so ON DELETE CASCADE behaves as in production.
    static func make() throws -> any DatabaseWriter {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue)
        return queue
    }
}

enum Make {
    /// A deterministic instant (whole seconds, to match the integer `createdAt` column).
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    static func clip(title: String = "title",
                     contentHash: String = UUID().uuidString,
                     createdAt: Date = epoch,
                     isPinned: Bool = false) -> Clip {
        // The repository treats `titleCipher` as opaque Data, so these tests use the plaintext
        // bytes as a stand-in (real AES-GCM encryption is exercised by the capture/cipher tests).
        Clip(
            id: UUID(),
            contentHash: contentHash,
            titleCipher: Data(title.utf8),
            primaryType: "public.utf8-plain-text",
            createdAt: createdAt,
            isPinned: isPinned,
            dataPath: "/tmp/\(UUID().uuidString).data",
            thumbnailID: nil,
            sourceBundle: nil
        )
    }
}

extension Clip {
    /// Decodes the stand-in plaintext stored in `titleCipher` by `Make.clip` (test-only).
    var testTitle: String? { String(data: titleCipher, encoding: .utf8) }
}
