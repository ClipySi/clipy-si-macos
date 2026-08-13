//
//  V4MigrationTests.swift
//  ClipyTests
//
//  The v4 migration adds the partial live-page index (M-UI.11 P2 keyset pagination) and DROPS
//  the v1 `clips_createdAt` index (Decision Gate D8): every live read that orders or filters by
//  `createdAt` also filters `deletedAt IS NULL`, so the partial index subsumes it, and keeping
//  both would double the per-capture index write for no reader. These tests pin both facts —
//  the real upgrade path (populated v3 DB → v4) and the `EXPLAIN QUERY PLAN` of every read
//  shape the panel/manager/count paths rely on, so a regression to a table scan cannot land
//  silently. Plan output contains index/table names only — no row content reaches test output
//  (plan v2 §3.2; count-shaped assertions).
//

import Foundation
import GRDB
import SQLiteData
import Testing

@testable import Clipy

@Suite struct V4MigrationTests {

    private func indexNames(_ db: Database) throws -> Set<String> {
        Set(try String.fetchAll(
            db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'clips'"))
    }

    @Test func v3ToV4SwapsTheCreatedAtIndexForThePartialLiveIndex() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v3_sync_state")
        // One live row and one tombstone inserted under the v3 schema (which still carries the
        // v1 index) — the swap must preserve both and keep the live read filtering.
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO "clips"
                ("id","contentHash","titleCipher","primaryType","createdAt","updatedAt","deletedAt",
                 "isPinned","isColorCode","dataPath","recordVersion","syncState","syncEligible","isSensitive")
                VALUES
                (?, 'live', ?, 'public.utf8-plain-text', 1700000000, 1700000000, NULL, 0, 0, '/tmp/a', 1, 'local', 1, 0),
                (?, 'dead', ?, 'public.utf8-plain-text', 1700000000, 1700000001, 1700000001, 0, 0, '/tmp/b', 1, 'local', 1, 0)
                """,
                arguments: ["11111111-1111-1111-1111-111111111111", Data("t".utf8),
                            "22222222-2222-2222-2222-222222222222", Data()]
            )
        }
        let before = try queue.read { db in try indexNames(db) }
        #expect(before.contains("clips_createdAt"))
        #expect(!before.contains("clips_live_createdAt_id"))

        try AppDatabase.migrator.migrate(queue) // applies v4_live_page_index

        let after = try queue.read { db in try indexNames(db) }
        #expect(after.contains("clips_live_createdAt_id"))
        #expect(!after.contains("clips_createdAt"))
        // Both rows survive; the live read serves exactly the live one.
        let totalRows = try queue.read { db in try Clip.fetchCount(db) }
        #expect(totalRows == 2)
        let liveRows = try queue.read { db in
            try Clip.where { $0.deletedAt.is(nil) }.fetchCount(db)
        }
        #expect(liveRows == 1)
    }

    /// D8 evidence: every `createdAt`-ordered live read (window head, ascending flip, keyset
    /// page) and the live count are served by the partial index after v4 — no table scan.
    /// Captured from the REAL repository calls via the connection trace, then EXPLAINed, so the
    /// pinned plans can't drift from the production SQL.
    @Test func liveReadShapesUseThePartialIndexAfterV4() throws {
        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
        } operation: {
            @Dependency(\.defaultDatabase) var database
            try database.write { db in
                for index in 0..<8 {
                    var clip = Make.clip(title: "row \(index)", contentHash: "d8-\(index)",
                                         createdAt: Make.epoch.addingTimeInterval(TimeInterval(index / 4)))
                    if index % 4 == 3 { clip.deletedAt = Make.epoch }
                    try Clip.insert { clip }.execute(db)
                }
            }
            let repository = ClipRepository()
            let captured = CapturedSQL()
            try database.write { db in
                db.trace(options: .statement) { event in
                    if case let .statement(statement) = event {
                        captured.append(statement.expandedSQL)
                    }
                }
            }
            _ = try repository.recentClips(limit: 5)                   // newest-first window head
            _ = try repository.recentClips(limit: 5, ascending: true)  // oldest-first flip
            _ = try repository.count()                                 // live count
            _ = try repository.livePage(after: ClipPageCursor(createdAt: Make.epoch, id: UUID()),
                                        limit: 5)                      // keyset continuation
            try database.write { db in db.trace(options: .statement, nil) }

            let selects = captured.statements.filter { $0.hasPrefix("SELECT") }
            #expect(selects.count == 4)
            let plans = try database.read { db in
                try selects.map { sql in
                    try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(sql)")
                        .compactMap { $0["detail"] as String? }
                        .joined(separator: " | ")
                }
            }
            for plan in plans {
                print("d8-eqp detail=\(plan)")
            }
            let plansOnLiveIndex = plans.count { $0.contains("clips_live_createdAt_id") }
            #expect(plansOnLiveIndex == plans.count)
            let tableScans = plans.count { $0.contains("SCAN clips") && !$0.contains("USING") }
            #expect(tableScans == 0)
        }
    }

    /// P6 evidence: trim's stale query (the only OFFSET query in the app) walks the partial
    /// live index in index order — no sort step, no table scan — so the bounded shape that
    /// replaced the fetch-everything trim can't silently regress to materializing the history.
    @Test func trimStaleQueryUsesThePartialIndexAfterV4() throws {
        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
        } operation: {
            @Dependency(\.defaultDatabase) var database
            try database.write { db in
                for index in 0..<8 {
                    var clip = Make.clip(title: "row \(index)", contentHash: "p6-\(index)",
                                         createdAt: Make.epoch.addingTimeInterval(TimeInterval(index / 4)))
                    if index % 4 == 3 { clip.deletedAt = Make.epoch }
                    try Clip.insert { clip }.execute(db)
                }
            }
            let repository = ClipRepository()
            let captured = CapturedSQL()
            try database.write { db in
                db.trace(options: .statement) { event in
                    if case let .statement(statement) = event {
                        // `sql`, not `expandedSQL`: LIMIT/OFFSET are bound (`?`), and a bound
                        // LIMIT is opaque to the planner where a literal `-1` is not — EXPLAIN
                        // must see the form SQLite actually prepared, or the pin proves the
                        // wrong statement. (Also keeps the OFFSET filter data-independent.)
                        captured.append(statement.sql)
                    }
                }
            }
            _ = try repository.trim(maxHistorySize: 2) // 6 live → 4 stale (exercises the query)
            try database.write { db in db.trace(options: .statement, nil) }

            let staleSelects = captured.statements.filter { $0.hasPrefix("SELECT") && $0.contains("OFFSET") }
            #expect(staleSelects.count == 1)
            let staleSQL = try #require(staleSelects.first)
            let plan = try database.read { db in
                // Re-bind the values trim bound (LIMIT -1 OFFSET 2) so the plan is taken under
                // the executed statement's exact conditions.
                try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(staleSQL)", arguments: [-1, 2])
                    .compactMap { $0["detail"] as String? }
                    .joined(separator: " | ")
            }
            print("p6-eqp detail=\(plan)")
            #expect(plan.contains("clips_live_createdAt_id"))
            #expect(!plan.contains("TEMP B-TREE"), "the stale walk must ride the index order, not sort")
        }
    }

    /// Trace sink — the trace callback is `@Sendable`, so the captured statements live in a
    /// reference box (appends happen serially on the test's single DB connection).
    private final class CapturedSQL: @unchecked Sendable {
        private(set) var statements: [String] = []

        func append(_ sql: String) { statements.append(sql) }
    }
}
