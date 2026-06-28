//
//  ClipRepository.swift
//  ClipySi — Apple Silicon rewrite
//
//  All clipboard-history writes go through this repository (`database.write {}`),
//  reads through `database.read {}`. The dedupe policy here replicates the original
//  Clipy two-flag behavior (copySameHistory / overwriteSameHistory); the original's
//  ground truth is ClipService.save (repos/Clipy/.../Services/ClipService.swift) and
//  DataCleanService (trimming). See DESIGN.md §4.3 and the README feature matrix.
//
//  Live, auto-updating reads for the UI/menu use `@FetchAll` directly in the view layer;
//  this type is the imperative write/read path used by capture and tests.
//

import Foundation
import SQLiteData

struct ClipRepository {
    @Dependency(\.defaultDatabase) private var database
    @Dependency(\.date) private var date

    // MARK: - Reads
    //
    // Every user-facing read filters `deletedAt IS NULL`: a soft-deleted (tombstoned) row stays in
    // the DB until sync distributes the deletion, but must never surface as a ghost row in the
    // menu/panel/history. Engine-facing reads that DO want tombstones are
    // explicit (`tombstones()`).

    /// All live clips, newest first (by `createdAt`).
    func clips() throws -> [Clip] {
        try database.read { db in
            try Clip.where { $0.deletedAt.is(nil) }.order { $0.createdAt.desc() }.fetchAll(db)
        }
    }

    /// The newest (or, when `ascending` is true, oldest) `limit` live clips by `createdAt`. The
    /// menu flips to ascending when `reorderClipsAfterPasting` is off, matching the original's
    /// sort-direction flip (MenuManager.swift:281).
    func recentClips(limit: Int, ascending: Bool = false) throws -> [Clip] {
        // SQLite treats `LIMIT -1` as "no limit", so a negative cap would fetch the whole history
        // (which the menu would then decrypt). Clamp non-negative, mirroring `trim`'s `>= 0` guard.
        let cap = max(0, limit)
        return try database.read { db in
            // `.asc()` / `.desc()` are distinct opaque query types, so they can't share a `?:`.
            if ascending {
                return try Clip.where { $0.deletedAt.is(nil) }
                    .order { $0.createdAt.asc() }.limit(cap).fetchAll(db)
            } else {
                return try Clip.where { $0.deletedAt.is(nil) }
                    .order { $0.createdAt.desc() }.limit(cap).fetchAll(db)
            }
        }
    }

    func clip(id: Clip.ID) throws -> Clip? {
        try database.read { db in
            try Clip.where { $0.id.eq(id) }.where { $0.deletedAt.is(nil) }.fetchOne(db)
        }
    }

    /// The most recent live clip whose content matches `contentHash`, if any.
    func latestClip(forContentHash contentHash: String) throws -> Clip? {
        try database.read { db in
            try Clip
                .where { $0.contentHash.eq(contentHash) }
                .where { $0.deletedAt.is(nil) }
                .order { $0.createdAt.desc() }
                .fetchOne(db)
        }
    }

    /// Number of live clips.
    func count() throws -> Int {
        try database.read { db in
            try Clip.where { $0.deletedAt.is(nil) }.fetchCount(db)
        }
    }

    // MARK: - Sync-engine reads (tombstones are intentionally visible here)

    /// Soft-deleted rows awaiting tombstone distribution (push) or local purge.
    func tombstones() throws -> [Clip] {
        try database.read { db in
            try Clip.where { $0.deletedAt.isNot(nil) }.fetchAll(db)
        }
    }

    /// Live clips modified at or after `cursor` — the push scan. Inclusive (`>=`) so same-second
    /// writes are re-pushed and absorbed by the idempotent merge.
    func pushCandidates(updatedAtAtLeast cursor: Date) throws -> [Clip] {
        try database.read { db in
            try Clip
                .where { $0.deletedAt.is(nil) }
                .where { $0.updatedAt.gte(#bind(cursor)) }
                .order { $0.updatedAt.asc() }
                .fetchAll(db)
        }
    }

    /// A live clip already carrying this cross-device dedupe hash (set at push), if any —
    /// the `live_duplicate_sync_hash` input to merge_decide.
    func liveClip(forSyncHash syncHash: String) throws -> Clip? {
        try database.read { db in
            try Clip
                .where { $0.syncHash.eq(syncHash) }
                .where { $0.deletedAt.is(nil) }
                .fetchOne(db)
        }
    }

    /// Tombstoned rows carrying this dedupe hash — the `tombstoned_duplicate` input (the engine
    /// resolves their stamps via the applied set).
    func tombstonedClips(forSyncHash syncHash: String) throws -> [Clip] {
        try database.read { db in
            try Clip
                .where { $0.syncHash.eq(syncHash) }
                .where { $0.deletedAt.isNot(nil) }
                .fetchAll(db)
        }
    }

    // MARK: - Writes

    /// Inserts a clip verbatim (no dedupe). Capture should normally use ``ingest`` so the
    /// user's dedupe settings are honored.
    func add(_ clip: Clip) throws {
        try database.write { db in
            try Clip.insert { clip }.execute(db)
        }
    }

    /// Captures `clip`, applying the original's two-flag dedupe semantics, and returns the id
    /// of the resulting row (existing or new), or `nil` if the clip was dropped as a duplicate.
    ///
    /// Mirrors ClipService.save:
    /// - `copySameHistory == false` and an identical clip already exists → drop it (no insert,
    ///   no reordering), matching the original's early `return`.
    /// - otherwise, if an identical clip exists and `overwriteSameHistory == true` → update the
    ///   existing row's timestamp in place, moving it to the top of the history.
    /// - otherwise (no duplicate, or `overwriteSameHistory == false`) → insert a new distinct row.
    ///
    /// Defaults of both flags are `true`, so the default behavior is "identical re-copy moves the
    /// existing entry to the top".
    @discardableResult
    func ingest(_ clip: Clip,
                representations: [ClipRepresentation] = [],
                copySameHistory: Bool,
                overwriteSameHistory: Bool) throws -> Clip.ID? {
        try database.write { db in
            let existing = try Clip
                .where { $0.contentHash.eq(clip.contentHash) }
                .order { $0.createdAt.desc() }
                .fetchOne(db)

            if let existing {
                if !copySameHistory {
                    return nil
                }
                if overwriteSameHistory {
                    // A re-copy is a modification: bump both the order key (createdAt) and the
                    // sync "last modified" (updatedAt) so sync sees the change. (design §3.1.)
                    try Clip
                        .update {
                            $0.createdAt = #bind(clip.createdAt)
                            $0.updatedAt = #bind(clip.updatedAt)
                        }
                        .where { $0.id.eq(existing.id) }
                        .execute(db)
                    return existing.id
                }
            }

            try Clip.insert { clip }.execute(db)
            for representation in representations {
                try ClipRepresentation.insert { representation }.execute(db)
            }
            return clip.id
        }
    }

    /// The secondary representations of a clip (the primary lives in `Clip.dataPath` / `primaryType`).
    /// Used by the paste service to restore every captured UTType.
    func representations(forClipID id: Clip.ID) throws -> [ClipRepresentation] {
        try database.read { db in
            try ClipRepresentation.where { $0.clipID.eq(id) }.fetchAll(db)
        }
    }

    /// Moves a clip to the top of the history by bumping its timestamp (used after a paste when
    /// `reorderClipsAfterPasting` is enabled). Bumps `updatedAt` too so the reorder is a visible
    /// modification for sync (design §3.1).
    func moveToTop(id: Clip.ID, date: Date) throws {
        try database.write { db in
            try Clip.update {
                $0.createdAt = #bind(date)
                $0.updatedAt = #bind(date)
            }
            .where { $0.id.eq(id) }
            .execute(db)
        }
    }

    func setPinned(_ pinned: Bool, id: Clip.ID) throws {
        try database.write { db in
            try Clip.update { $0.isPinned = pinned }.where { $0.id.eq(id) }.execute(db)
        }
    }

    /// Sets the `isSensitive` UX hint for a clip (used by the one-time backfill of rows captured
    /// before capture-time secret detection). Not a sync gate — see IsSensitiveBackfill.
    func setSensitive(_ isSensitive: Bool, id: Clip.ID) throws {
        try database.write { db in
            try Clip.update { $0.isSensitive = isSensitive }.where { $0.id.eq(id) }.execute(db)
        }
    }

    /// Deletes one clip and returns every on-disk blob path to GC — the primary `Clip.dataPath` plus
    /// each secondary representation's `dataPath` (the repository is storage-only and doesn't own the
    /// blob store). Returns an empty array if no such clip existed.
    ///
    /// `soft` selects the strategy and defaults to the live sync setting, so the existing call
    /// sites stay unchanged: sync ON tombstones the row (content wiped,
    /// metadata kept until the deletion is distributed); sync OFF hard-deletes as before. Tests
    /// pass `soft:` explicitly.
    @discardableResult
    func delete(id: Clip.ID, soft: Bool = AppSettings().syncEnabled) throws -> [String] {
        try database.write { db in
            guard let clip = try Clip.where { $0.id.eq(id) }.fetchOne(db) else { return [] }
            let repPaths = try ClipRepresentation.where { $0.clipID.eq(id) }.select(\.dataPath).fetchAll(db)
            if soft {
                try softDeleteRow(id: id, in: db)
            } else {
                try Clip.delete().where { $0.id.eq(id) }.execute(db)
            }
            return [clip.dataPath] + repPaths
        }
    }

    /// Deletes every live clip (the "Clear History" action) and returns all blob paths (primary +
    /// representation) for GC. With `soft` (sync ON) each row becomes a tombstone; already-soft-
    /// deleted rows are left for the engine to purge.
    @discardableResult
    func deleteAll(soft: Bool = AppSettings().syncEnabled) throws -> [String] {
        try database.write { db in
            let live = try Clip.where { $0.deletedAt.is(nil) }.fetchAll(db)
            let liveIDs = live.map(\.id)
            let repPaths = try ClipRepresentation.where { $0.clipID.in(liveIDs) }.select(\.dataPath).fetchAll(db)
            if soft {
                for id in liveIDs {
                    try softDeleteRow(id: id, in: db)
                }
            } else {
                try Clip.delete().where { $0.id.in(liveIDs) }.execute(db)
            }
            return live.map(\.dataPath) + repPaths
        }
    }

    /// Tombstones one row in place: stamp `deletedAt`/`updatedAt`, blank the content fields
    /// (the caller GCs the blobs immediately — a tombstone is metadata only, design §5.4),
    /// and drop the representation rows. The row itself stays until the engine purges it.
    private func softDeleteRow(id: Clip.ID, in db: Database) throws {
        let now = date.now
        try Clip.update {
            $0.deletedAt = #bind(now)
            $0.updatedAt = #bind(now)
            $0.titleCipher = #bind(Data())
        }
        .where { $0.id.eq(id) }
        .execute(db)
        try ClipRepresentation.delete().where { $0.clipID.eq(id) }.execute(db)
    }

    /// Hard-removes a tombstoned row once its deletion has been distributed (engine GC). No-op for
    /// live rows — purging must never bypass the soft-delete path.
    func purgeTombstone(id: Clip.ID) throws {
        try database.write { db in
            try Clip.delete()
                .where { $0.id.eq(id) }
                .where { $0.deletedAt.isNot(nil) }
                .execute(db)
        }
    }

    /// Enforces the history cap. Keeps the newest `maxHistorySize` non-pinned clips (by
    /// `createdAt`) and deletes the rest; pinned clips are always kept and do not count toward
    /// the limit (pinning is new — the original had no pins). Returns the deleted clips'
    /// `dataPath`s so the caller can delete their blobs (no orphaned ciphertext). Unlike the
    /// original, which trims only on a timer and on clear-all, the capture layer decides when to
    /// call this.
    @discardableResult
    func trim(maxHistorySize: Int) throws -> [String] {
        guard maxHistorySize >= 0 else { return [] }
        return try database.write { db in
            // Live rows only: trim is LOCAL eviction (no tombstone — design §5.5; syncApplied
            // prevents re-import), and tombstoned rows are the engine's to purge, not trim's.
            let newestFirst = try Clip
                .where { !$0.isPinned }
                .where { $0.deletedAt.is(nil) }
                .order { $0.createdAt.desc() }
                .fetchAll(db)
            let stale = Array(newestFirst.dropFirst(maxHistorySize))
            guard !stale.isEmpty else { return [] }
            let staleIDs = stale.map(\.id)
            let repPaths = try ClipRepresentation.where { $0.clipID.in(staleIDs) }.select(\.dataPath).fetchAll(db)
            try Clip.delete().where { $0.id.in(staleIDs) }.execute(db)
            return stale.map(\.dataPath) + repPaths
        }
    }
}
