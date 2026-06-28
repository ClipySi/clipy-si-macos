//
//  V2MigrationTests.swift
//  ClipyTests
//
//  Exercises the REAL v1→v2 ALTER path (foundation freeze), not the DEBUG
//  `eraseDatabaseOnSchemaChange` shortcut: migrate a fresh DB up to v1 only, insert a v1-shaped
//  row, then apply v2 and assert the row survives with its existing values intact and the new
//  columns backfilled to their defaults. If v2 were to erase rather than migrate, the row would
//  vanish and `#require` would fail — so this also guards against an unexpected erase.
//

import Foundation
import SQLiteData
import Testing
@testable import Clipy

@Suite struct V2MigrationTests {

    /// Seconds since 1970 used for the seeded v1 row.
    private static let createdAtSeconds = 1_700_000_000

    private func makeV1ThenInsertRow() throws -> any DatabaseWriter {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v1_create")
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO "clips"
                ("id","contentHash","titleCipher","primaryType","createdAt",
                 "isPinned","isColorCode","dataPath","thumbnailID","sourceBundle")
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    "11111111-1111-1111-1111-111111111111", "abc", Data("hi".utf8),
                    "public.utf8-plain-text", Self.createdAtSeconds, 0, 0, "/tmp/x", nil, nil
                ]
            )
        }
        return queue
    }

    @Test func v1ToV2PreservesRowAndBackfillsDefaults() throws {
        let queue = try makeV1ThenInsertRow()
        try AppDatabase.migrator.migrate(queue) // applies v2_sync_meta

        let fetched = try queue.read { db in
            try Clip.where { $0.contentHash.eq("abc") }.fetchOne(db)
        }
        let migrated = try #require(fetched, "the seeded v1 row must survive the v2 migration (not be erased)")

        let createdAt = Date(timeIntervalSince1970: TimeInterval(Self.createdAtSeconds))
        #expect(migrated.createdAt == createdAt)        // existing value untouched
        #expect(migrated.updatedAt == createdAt)        // backfilled to createdAt
        #expect(migrated.contentHash == "abc")          // dedupe input preserved
        #expect(migrated.recordVersion == 1)
        #expect(migrated.syncState == "local")
        #expect(migrated.syncEligible == true)
        #expect(migrated.isSensitive == false)
        #expect(migrated.deletedAt == nil)
        #expect(migrated.originDeviceID == nil)         // pre-sync rows have no origin device
        #expect(migrated.syncHash == nil)
    }

    /// After migration, a re-copy of the same content still dedupes — the migration must not change
    /// `contentHash` (adversarial review migration #6). Drives the real `ClipRepository.ingest`.
    @Test func dedupeStillFiresAcrossMigration() throws {
        let queue = try makeV1ThenInsertRow()
        try AppDatabase.migrator.migrate(queue)

        try withDependencies {
            $0.defaultDatabase = queue
        } operation: {
            let repo = ClipRepository()
            #expect(try repo.count() == 1)
            // Same contentHash as the seeded row → overwrite-to-top, no new row.
            let again = Make.clip(contentHash: "abc", createdAt: Make.epoch.addingTimeInterval(60))
            let storedID = try repo.ingest(again, copySameHistory: true, overwriteSameHistory: true)
            #expect(try repo.count() == 1, "duplicate must not insert a second row")
            #expect(storedID == UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        }
    }
}
