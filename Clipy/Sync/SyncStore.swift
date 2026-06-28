//
//  SyncStore.swift
//  ClipySi — Apple Silicon rewrite
//
//  Typed access to the sync state tables: the device HLC clock + push cursor (`syncMeta`,
//  key-value) and the applied-record set (`syncApplied`). Pure storage — no merge logic (that is
//  the Rust core's) and no I/O beyond the database. The engine calls the `…(in:)` variants inside
//  its own `database.write {}` so state advances atomically with the applies (crash-safe replay);
//  the argument-less variants are conveniences for reads and tests.
//

import ClipySiCore
import Foundation
import SQLiteData

struct SyncStore {
    @Dependency(\.defaultDatabase) private var database

    private enum Keys {
        static let hlcState = "hlcState"        // JSON {"wallMillis":Int64,"counter":UInt32,"node":String}
        static let lastPushedAt = "lastPushedAt" // unix seconds, as String
    }

    private struct HlcStateJSON: Codable {
        var wallMillis: Int64
        var counter: UInt32
        var node: String
    }

    // MARK: - HLC clock

    /// The device's last issued/merged HLC stamp, or nil before first sync.
    func hlcState(in db: Database) throws -> HlcFfi? {
        guard let raw = try value(forKey: Keys.hlcState, in: db),
              let data = raw.data(using: .utf8),
              let state = try? JSONDecoder().decode(HlcStateJSON.self, from: data)
        else { return nil }
        return HlcFfi(wallMillis: state.wallMillis, counter: state.counter, node: state.node)
    }

    func setHlcState(_ hlc: HlcFfi, in db: Database) throws {
        let state = HlcStateJSON(wallMillis: hlc.wallMillis, counter: hlc.counter, node: hlc.node)
        let json = String(data: try JSONEncoder().encode(state), encoding: .utf8) ?? "{}"
        try setValue(json, forKey: Keys.hlcState, in: db)
    }

    func hlcState() throws -> HlcFfi? {
        try database.read { try hlcState(in: $0) }
    }

    // MARK: - Push cursor

    /// `updatedAt` high-water mark of the last completed push (unix seconds; 0 = never pushed).
    /// Push scans `updatedAt >= cursor` — inclusive, so same-second writes are re-pushed and
    /// absorbed by the idempotent merge.
    func lastPushedAt(in db: Database) throws -> Int {
        Int(try value(forKey: Keys.lastPushedAt, in: db) ?? "") ?? 0
    }

    func setLastPushedAt(_ seconds: Int, in db: Database) throws {
        try setValue(String(seconds), forKey: Keys.lastPushedAt, in: db)
    }

    // MARK: - Applied set

    func applied(recordID: String, in db: Database) throws -> SyncAppliedRecord? {
        try SyncAppliedRecord.where { $0.recordID.eq(recordID) }.fetchOne(db)
    }

    /// Upsert one applied-set entry (insert or overwrite the stamp/deleted state).
    func markApplied(recordID: String, hlc: HlcFfi, deleted: Bool, in db: Database) throws {
        try SyncAppliedRecord.delete().where { $0.recordID.eq(recordID) }.execute(db)
        try SyncAppliedRecord.insert {
            SyncAppliedRecord(
                recordID: recordID,
                hlcWall: Int(hlc.wallMillis),
                hlcCounter: Int(hlc.counter),
                hlcNode: hlc.node,
                deleted: deleted
            )
        }.execute(db)
    }

    func appliedRecordIDs(in db: Database) throws -> Set<String> {
        Set(try SyncAppliedRecord.select(\.recordID).fetchAll(db))
    }

    func appliedEntries() throws -> [SyncAppliedRecord] {
        try database.read { db in try SyncAppliedRecord.fetchAll(db) }
    }

    /// One-shot convenience: upsert an applied-set entry in its own transaction.
    func recordApplied(recordID: String, hlc: HlcFfi, deleted: Bool) throws {
        try database.write { db in
            try markApplied(recordID: recordID, hlc: hlc, deleted: deleted, in: db)
        }
    }

    /// Finish publishing one live record: persist its syncHash + state, mark it applied, and
    /// advance the device clock — atomically.
    func completePush(clipID: Clip.ID, hlc: HlcFfi, syncHash: String) throws {
        try database.write { db in
            try Clip.update {
                $0.syncHash = #bind(syncHash)
                $0.syncState = "synced"
            }
            .where { $0.id.eq(clipID) }
            .execute(db)
            try markApplied(recordID: clipID.uuidString.lowercased(), hlc: hlc, deleted: false, in: db)
            try setHlcState(hlc, in: db)
        }
    }

    /// Finish publishing one tombstone: mark applied-deleted + advance the clock, atomically.
    func completeTombstonePush(clipID: Clip.ID, hlc: HlcFfi) throws {
        try database.write { db in
            try markApplied(recordID: clipID.uuidString.lowercased(), hlc: hlc, deleted: true, in: db)
            try setHlcState(hlc, in: db)
        }
    }

    /// Merge a received stamp into the persisted device clock (one-shot).
    func mergeClock(_ hlc: HlcFfi) throws {
        try database.write { db in
            try setHlcState(hlc, in: db)
        }
    }

    // MARK: - Atomic applies (one transaction per record → crash-safe replay via the applied set)

    /// Apply an incoming live record: insert the (locally re-encrypted) clip + its representation
    /// rows and advance the applied set, atomically. Blobs are written by the engine BEFORE this
    /// (a crash in between leaves orphan ciphertext files, same as the capture pattern).
    func applyRemoteInsert(
        _ clip: Clip,
        representations: [ClipRepresentation],
        hlc: HlcFfi
    ) throws {
        try database.write { db in
            try Clip.insert { clip }.execute(db)
            for representation in representations {
                try ClipRepresentation.insert { representation }.execute(db)
            }
            try markApplied(recordID: clip.id.uuidString.lowercased(), hlc: hlc, deleted: false, in: db)
        }
    }

    /// Apply an incoming tombstone to a known live clip: wipe + soft-delete the row and advance the
    /// applied set, atomically. Returns the blob paths for the engine to GC.
    func applyRemoteTombstone(clipID: Clip.ID, hlc: HlcFfi, deletedAt: Date) throws -> [String] {
        try database.write { db in
            let clipPath = try Clip.where { $0.id.eq(clipID) }.fetchOne(db)?.dataPath
            let repPaths = try ClipRepresentation.where { $0.clipID.eq(clipID) }.select(\.dataPath).fetchAll(db)
            try Clip.update {
                $0.deletedAt = #bind(deletedAt)
                $0.updatedAt = #bind(deletedAt)
                $0.titleCipher = #bind(Data())
            }
            .where { $0.id.eq(clipID) }
            .execute(db)
            try ClipRepresentation.delete().where { $0.clipID.eq(clipID) }.execute(db)
            try markApplied(recordID: clipID.uuidString.lowercased(), hlc: hlc, deleted: true, in: db)
            return [clipPath].compactMap { $0 } + repPaths
        }
    }

    /// Record an unknown record's tombstone without applying anything (MergeAction
    /// `.recordTombstoneOnly`) — the transport-race zombie guard: a late-arriving live file for
    /// this id will be seen as applied-deleted and skipped.
    func recordTombstoneOnly(recordID: String, hlc: HlcFfi) throws {
        try database.write { db in
            try markApplied(recordID: recordID, hlc: hlc, deleted: true, in: db)
        }
    }

    /// Drop ALL sync state (applied set, clock, cursors). Used when the device joins a DIFFERENT
    /// vault (folder switch / recreated vault.json) — the old state must not leak into it.
    func wipeAll() throws {
        try database.write { db in
            try SyncAppliedRecord.delete().execute(db)
            try SyncMetaRow.delete().execute(db)
        }
    }

    // MARK: - Raw key-value

    private func value(forKey key: String, in db: Database) throws -> String? {
        try SyncMetaRow.where { $0.key.eq(key) }.fetchOne(db)?.value
    }

    private func setValue(_ value: String, forKey key: String, in db: Database) throws {
        try SyncMetaRow.delete().where { $0.key.eq(key) }.execute(db)
        try SyncMetaRow.insert { SyncMetaRow(key: key, value: value) }.execute(db)
    }
}
