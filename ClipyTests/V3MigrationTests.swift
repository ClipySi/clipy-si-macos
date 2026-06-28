//
//  V3MigrationTests.swift
//  ClipyTests
//
//  The v3 migration adds the sync state tables (syncMeta / syncApplied) WITHOUT touching
//  clips, and SyncStore round-trips the device HLC clock, push cursor, and applied set. Like
//  V2MigrationTests this exercises the real upgrade path (v2 DB → v3) rather than the DEBUG erase.
//

import ClipySiCore
import Foundation
import SQLiteData
import Testing
@testable import Clipy

@Suite struct V3MigrationTests {

    @Test func v2ToV3PreservesClipsAndAddsTables() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v2_sync_meta")
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO "clips"
                ("id","contentHash","titleCipher","primaryType","createdAt","updatedAt",
                 "isPinned","isColorCode","dataPath","recordVersion","syncState","syncEligible","isSensitive")
                VALUES (?, ?, ?, ?, ?, ?, 0, 0, ?, 1, 'local', 1, 0)
                """,
                arguments: ["22222222-2222-2222-2222-222222222222", "h", Data("t".utf8),
                            "public.utf8-plain-text", 1_700_000_000, 1_700_000_000, "/tmp/x"]
            )
        }
        try AppDatabase.migrator.migrate(queue) // applies v3_sync_state

        let survived = try queue.read { db in
            try Clip.where { $0.contentHash.eq("h") }.fetchOne(db)
        }
        #expect(survived != nil, "v2 row must survive v3")
        // The new tables exist and are usable.
        try queue.write { db in
            try SyncMetaRow.insert { SyncMetaRow(key: "k", value: "v") }.execute(db)
            try SyncAppliedRecord.insert {
                SyncAppliedRecord(recordID: "r1", hlcWall: 1, hlcCounter: 0, hlcNode: "n")
            }.execute(db)
        }
        let meta = try queue.read { db in try SyncMetaRow.where { $0.key.eq("k") }.fetchOne(db) }
        #expect(meta?.value == "v")
    }

    @Test func syncStoreRoundTripsHlcCursorAndAppliedSet() throws {
        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
        } operation: {
            let store = SyncStore()
            @Dependency(\.defaultDatabase) var database

            let node = "00000000-0000-0000-0000-000000000001"
            try database.write { db in
                #expect(try store.hlcState(in: db) == nil)
                #expect(try store.lastPushedAt(in: db) == 0)

                try store.setHlcState(HlcFfi(wallMillis: 1_700_000_000_123, counter: 7, node: node), in: db)
                try store.setLastPushedAt(1_700_000_000, in: db)
                try store.markApplied(
                    recordID: "r1",
                    hlc: HlcFfi(wallMillis: 5, counter: 1, node: node),
                    deleted: false, in: db
                )
            }

            try database.read { db in
                let hlc = try #require(try store.hlcState(in: db))
                #expect(hlc.wallMillis == 1_700_000_000_123)
                #expect(hlc.counter == 7)
                #expect(hlc.node == node)
                #expect(try store.lastPushedAt(in: db) == 1_700_000_000)
                let applied = try #require(try store.applied(recordID: "r1", in: db))
                #expect(applied.deleted == false)
                #expect(try store.appliedRecordIDs(in: db) == ["r1"])
            }

            // Upsert flips the deleted flag (tombstone recording).
            try database.write { db in
                try store.markApplied(
                    recordID: "r1",
                    hlc: HlcFfi(wallMillis: 9, counter: 0, node: node),
                    deleted: true, in: db
                )
            }
            let after = try database.read { db in try store.applied(recordID: "r1", in: db) }
            #expect(after?.deleted == true)
            #expect(after?.hlcWall == 9)
        }
    }
}
