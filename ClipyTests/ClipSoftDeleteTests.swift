//
//  ClipSoftDeleteTests.swift
//  ClipyTests
//
//  Soft delete (tombstoning) and the deletedAt read filters: a tombstoned row must never
//  surface as a ghost in any user-facing read, trim must ignore tombstones, and the SyncStore
//  apply paths must be atomic with the applied set.
//

import ClipySiCore
import Foundation
import SQLiteData
import Testing
@testable import Clipy

@Suite struct ClipSoftDeleteTests {
    private static let node = "00000000-0000-0000-0000-000000000001"

    private func run(_ body: (ClipRepository, SyncStore) throws -> Void) throws {
        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
            $0.date = .constant(Make.epoch)
        } operation: {
            try body(ClipRepository(), SyncStore())
        }
    }

    @Test func softDeleteHidesFromAllUserReadsButKeepsRow() throws {
        try run { repo, _ in
            let clip = Make.clip(title: "secret", contentHash: "h1")
            try repo.add(clip)
            let paths = try repo.delete(id: clip.id, soft: true)
            #expect(paths == [clip.dataPath], "blob paths still returned for immediate GC")

            // Every user-facing read hides the tombstone…
            #expect(try repo.clips().isEmpty)
            #expect(try repo.recentClips(limit: 10).isEmpty)
            #expect(try repo.clip(id: clip.id) == nil)
            #expect(try repo.latestClip(forContentHash: "h1") == nil)
            #expect(try repo.count() == 0)
            // …but the engine still sees it, wiped and stamped.
            let tombs = try repo.tombstones()
            #expect(tombs.count == 1)
            #expect(tombs.first?.titleCipher == Data(), "content wiped on soft delete")
            #expect(tombs.first?.deletedAt == Make.epoch)
            #expect(tombs.first?.updatedAt == Make.epoch)
        }
    }

    @Test func hardDeleteStillRemovesTheRow() throws {
        try run { repo, _ in
            let clip = Make.clip()
            try repo.add(clip)
            let paths = try repo.delete(id: clip.id, soft: false)
            #expect(paths == [clip.dataPath])
            #expect(try repo.tombstones().isEmpty, "hard delete leaves no tombstone")
            #expect(try repo.count() == 0)
        }
    }

    @Test func softDeleteAllTombstonesEveryLiveRow() throws {
        try run { repo, _ in
            try repo.add(Make.clip(contentHash: "a"))
            try repo.add(Make.clip(contentHash: "b"))
            let paths = try repo.deleteAll(soft: true)
            #expect(paths.count == 2)
            #expect(try repo.count() == 0)
            #expect(try repo.tombstones().count == 2)
        }
    }

    @Test func trimIgnoresTombstonesAndPurgeRemovesThem() throws {
        try run { repo, _ in
            let keep = Make.clip(contentHash: "keep", createdAt: Make.epoch.addingTimeInterval(10))
            let tomb = Make.clip(contentHash: "tomb")
            try repo.add(keep)
            try repo.add(tomb)
            _ = try repo.delete(id: tomb.id, soft: true)

            // maxHistorySize 1 with one live + one tombstone: nothing to trim (tombstone not counted).
            #expect(try repo.trim(maxHistorySize: 1).isEmpty)
            #expect(try repo.tombstones().count == 1)

            // purge removes the tombstone row; a live row is untouched by purge.
            try repo.purgeTombstone(id: tomb.id)
            #expect(try repo.tombstones().isEmpty)
            try repo.purgeTombstone(id: keep.id)
            #expect(try repo.clip(id: keep.id) != nil, "purge must never remove a live row")
        }
    }

    @Test func pushCandidatesScanIsInclusiveAndLiveOnly() throws {
        try run { repo, _ in
            var old = Make.clip(contentHash: "old")
            old.updatedAt = Make.epoch.addingTimeInterval(-100)
            var fresh = Make.clip(contentHash: "fresh")
            fresh.updatedAt = Make.epoch
            var tomb = Make.clip(contentHash: "tomb")
            tomb.updatedAt = Make.epoch
            try repo.add(old)
            try repo.add(fresh)
            try repo.add(tomb)
            _ = try repo.delete(id: tomb.id, soft: true)

            let candidates = try repo.pushCandidates(updatedAtAtLeast: Make.epoch)
            #expect(candidates.map(\.id) == [fresh.id], "inclusive >= cursor, live rows only")
        }
    }

    /// Re-copying content that was soft-deleted must produce a NEW clip. The tombstone keeps its
    /// `contentHash` until the engine purges it (up to the 35d retention), so a dedupe lookup that
    /// sees tombstones would hand the capture back the tombstone's id — and the capture would
    /// vanish: every user-facing read filters `deletedAt IS NULL`.
    @Test func recopyingSoftDeletedContentInsertsANewLiveClip() throws {
        try run { repo, _ in
            let original = Make.clip(title: "phoenix", contentHash: "same")
            try repo.add(original)
            _ = try repo.delete(id: original.id, soft: true)
            #expect(try repo.count() == 0)

            let recopied = Make.clip(title: "phoenix", contentHash: "same")
            let storedID = try repo.ingest(recopied, copySameHistory: true, overwriteSameHistory: true)

            #expect(storedID == recopied.id, "a new row, not the tombstone's id")
            #expect(try repo.count() == 1, "the re-copy is visible in the history")
            #expect(try repo.clip(id: recopied.id)?.testTitle == "phoenix")
            #expect(try repo.tombstones().map(\.id) == [original.id], "tombstone untouched")
        }
    }

    /// Same hole on the drop path: with `copySameHistory` off, a tombstone match returned nil and
    /// the capture was thrown away.
    @Test func recopyingSoftDeletedContentIsNotDroppedAsADuplicate() throws {
        try run { repo, _ in
            let original = Make.clip(contentHash: "same")
            try repo.add(original)
            _ = try repo.delete(id: original.id, soft: true)

            let recopied = Make.clip(contentHash: "same")
            #expect(try repo.ingest(recopied, copySameHistory: false, overwriteSameHistory: true) == recopied.id)
            #expect(try repo.count() == 1)
        }
    }

    /// The dedupe behaviour against LIVE rows is unchanged.
    @Test func recopyingLiveContentStillMovesTheExistingRowToTheTop() throws {
        try run { repo, _ in
            let first = Make.clip(contentHash: "same", createdAt: Make.epoch)
            try repo.add(first)
            var again = Make.clip(contentHash: "same")
            again.createdAt = Make.epoch.addingTimeInterval(60)

            #expect(try repo.ingest(again, copySameHistory: true, overwriteSameHistory: true) == first.id)
            #expect(try repo.count() == 1, "still exactly one row")
            #expect(try repo.clip(id: first.id)?.createdAt == Make.epoch.addingTimeInterval(60))
        }
    }

    @Test func applyRemoteInsertAndTombstoneAdvanceAppliedSetAtomically() throws {
        try run { repo, store in
            @Dependency(\.defaultDatabase) var database
            let clip = Make.clip(contentHash: "remote")
            let hlc = HlcFfi(wallMillis: 1_000, counter: 0, node: Self.node)

            try store.applyRemoteInsert(clip, representations: [], hlc: hlc)
            #expect(try repo.clip(id: clip.id) != nil)
            let applied = try database.read { db in try store.applied(recordID: clip.id.uuidString.lowercased(), in: db) }
            #expect(applied?.deleted == false)

            let tombHlc = HlcFfi(wallMillis: 2_000, counter: 0, node: Self.node)
            let paths = try store.applyRemoteTombstone(clipID: clip.id, hlc: tombHlc, deletedAt: Make.epoch)
            #expect(paths == [clip.dataPath])
            #expect(try repo.clip(id: clip.id) == nil, "tombstoned row hidden from reads")
            let after = try database.read { db in try store.applied(recordID: clip.id.uuidString.lowercased(), in: db) }
            #expect(after?.deleted == true)

            // Unknown tombstone is recorded without touching clips (zombie guard).
            try store.recordTombstoneOnly(recordID: "11111111-1111-1111-1111-111111111111", hlc: tombHlc)
            let ghost = try database.read { db in
                try store.applied(recordID: "11111111-1111-1111-1111-111111111111", in: db)
            }
            #expect(ghost?.deleted == true)
            #expect(try repo.count() == 0)
        }
    }
}
