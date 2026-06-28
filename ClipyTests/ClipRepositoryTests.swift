//
//  ClipRepositoryTests.swift
//  ClipyTests
//

import Foundation
import SQLiteData
import Testing
@testable import Clipy

@Suite struct ClipRepositoryTests {

    @Test func addsAndCountsAndOrdersNewestFirst() throws {
        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
        } operation: {
            let repo = ClipRepository()
            try repo.add(Make.clip(title: "old", createdAt: Make.epoch))
            try repo.add(Make.clip(title: "new", createdAt: Make.epoch.addingTimeInterval(10)))

            #expect(try repo.count() == 2)
            #expect(try repo.clips().map(\.testTitle) == ["new", "old"])
        }
    }

    @Test func createdAtRoundTripsAsWholeSeconds() throws {
        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
        } operation: {
            let repo = ClipRepository()
            let when = Date(timeIntervalSince1970: 1_700_000_123)
            let clip = Make.clip(createdAt: when)
            try repo.add(clip)
            #expect(try repo.clip(id: clip.id)?.createdAt == when)
        }
    }

    // MARK: - Dedupe (original two-flag semantics)

    @Test func ingestDefaultMovesDuplicateToTop() throws {
        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
        } operation: {
            let repo = ClipRepository()
            let first = Make.clip(contentHash: "H", createdAt: Make.epoch)
            try #require(try repo.ingest(first, copySameHistory: true, overwriteSameHistory: true) != nil)

            let again = Make.clip(contentHash: "H", createdAt: Make.epoch.addingTimeInterval(60))
            let id = try repo.ingest(again, copySameHistory: true, overwriteSameHistory: true)

            // Same row reused (no duplicate), timestamp bumped to the newer copy.
            #expect(id == first.id)
            #expect(try repo.count() == 1)
            #expect(try repo.clip(id: first.id)?.createdAt == Make.epoch.addingTimeInterval(60))
        }
    }

    @Test func ingestCopySameHistoryFalseDropsDuplicate() throws {
        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
        } operation: {
            let repo = ClipRepository()
            let first = Make.clip(contentHash: "H", createdAt: Make.epoch)
            try repo.ingest(first, copySameHistory: true, overwriteSameHistory: true)

            let again = Make.clip(contentHash: "H", createdAt: Make.epoch.addingTimeInterval(60))
            let id = try repo.ingest(again, copySameHistory: false, overwriteSameHistory: true)

            #expect(id == nil)
            #expect(try repo.count() == 1)
            // Dropped entirely: the existing entry is NOT moved to the top.
            #expect(try repo.clip(id: first.id)?.createdAt == Make.epoch)
        }
    }

    @Test func ingestOverwriteFalseKeepsDuplicateRows() throws {
        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
        } operation: {
            let repo = ClipRepository()
            try repo.ingest(Make.clip(contentHash: "H"), copySameHistory: true, overwriteSameHistory: false)
            try repo.ingest(Make.clip(contentHash: "H"), copySameHistory: true, overwriteSameHistory: false)
            #expect(try repo.count() == 2)
        }
    }

    // MARK: - Delete / trim

    @Test func deletesOneAndAll() throws {
        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
        } operation: {
            let repo = ClipRepository()
            let clipA = Make.clip(title: "a")
            try repo.add(clipA)
            try repo.add(Make.clip(title: "b"))

            try repo.delete(id: clipA.id)
            #expect(try repo.count() == 1)

            try repo.deleteAll()
            #expect(try repo.count() == 0)
        }
    }

    @Test func trimKeepsNewestNonPinnedAndAllPinned() throws {
        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
        } operation: {
            let repo = ClipRepository()
            // 5 non-pinned at t=0..4, plus one old pinned clip at t=-100.
            for index in 0..<5 {
                try repo.add(Make.clip(title: "n\(index)", createdAt: Make.epoch.addingTimeInterval(Double(index))))
            }
            let pinned = Make.clip(title: "pin", createdAt: Make.epoch.addingTimeInterval(-100), isPinned: true)
            try repo.add(pinned)

            try repo.trim(maxHistorySize: 3)

            let titles = try repo.clips().compactMap(\.testTitle)
            // Newest 3 non-pinned kept (n4,n3,n2); n1,n0 dropped; pinned always kept.
            #expect(Set(titles) == ["n4", "n3", "n2", "pin"])
            #expect(try repo.clip(id: pinned.id) != nil)
        }
    }

    @Test func deleteCascadesToRepresentations() throws {
        let db = try TestDatabase.make()
        try withDependencies {
            $0.defaultDatabase = db
        } operation: {
            let repo = ClipRepository()
            let clip = Make.clip()
            try repo.add(clip)
            try db.write { database in
                try ClipRepresentation.insert {
                    ClipRepresentation(clipID: clip.id, uttype: "public.utf8-plain-text",
                                       dataPath: "/tmp/rep.data", byteSize: 12)
                }.execute(database)
            }
            #expect(try db.read { try ClipRepresentation.fetchCount($0) } == 1)

            try repo.delete(id: clip.id)
            #expect(try db.read { try ClipRepresentation.fetchCount($0) } == 0)
        }
    }

    @Test func deleteReturnsPrimaryAndRepresentationBlobPathsForGC() throws {
        let db = try TestDatabase.make()
        try withDependencies {
            $0.defaultDatabase = db
        } operation: {
            let repo = ClipRepository()
            let clip = Make.clip()
            try repo.add(clip)
            try db.write { database in
                try ClipRepresentation.insert {
                    ClipRepresentation(clipID: clip.id, uttype: "public.rtf",
                                       dataPath: "/tmp/rep.data", byteSize: 3)
                }.execute(database)
            }
            // Both the primary blob and the representation blob must be returned so the caller GCs
            // them (cascade removes the row, not the on-disk ciphertext).
            #expect(Set(try repo.delete(id: clip.id)) == [clip.dataPath, "/tmp/rep.data"])
        }
    }

    @Test func setPinnedAndMoveToTop() throws {
        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
        } operation: {
            let repo = ClipRepository()
            let clip = Make.clip(createdAt: Make.epoch)
            try repo.add(clip)

            try repo.setPinned(true, id: clip.id)
            #expect(try repo.clip(id: clip.id)?.isPinned == true)

            try repo.moveToTop(id: clip.id, date: Make.epoch.addingTimeInterval(500))
            #expect(try repo.clip(id: clip.id)?.createdAt == Make.epoch.addingTimeInterval(500))
        }
    }
}
