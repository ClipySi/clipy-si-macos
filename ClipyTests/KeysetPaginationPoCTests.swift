//
//  KeysetPaginationPoCTests.swift
//  ClipyTests
//
//  M-UI.11 P2 §4.3 PoC — pins how `(createdAt, id)` keyset pagination is expressed on the
//  pinned SQLiteData 1.6.2 / swift-structured-queries 0.31.1 / GRDB 7.11.0 stack:
//
//  1. StructuredQueries has no row-value comparison in its builder (scalar operators only),
//     so the candidates are the expanded OR form (pure builder) and a `#sql` row-value
//     predicate. Both run here against the same corpus and must agree page for page.
//  2. Binds must round-trip the STORED representation: `createdAt` is INTEGER unix seconds
//     (`Date.UnixTimeRepresentation`), `id` is TEXT in UUID's default bind form. A wrong bind
//     representation would silently mis-order same-second groups, so the corpus forces four
//     rows per second — that failure mode cannot pass these walks.
//  3. EXPLAIN QUERY PLAN records whether the planned partial live index serves each form
//     (the D8 input: drop/retain of the v1 `clips_createdAt` index).
//  4. `ValueObservation` can start/cancel from a non-View context. The app links only the
//     SQLiteData product and SQLiteData does not re-export `ValueObservation`, so this file's
//     `import GRDB` also proves whether the transitive module resolves in this project.
//

import Foundation
import GRDB
import SQLiteData
import Testing

@testable import Clipy

@Suite struct KeysetPaginationPoCTests {
    /// The two candidate keyset predicate forms under evaluation.
    enum KeysetForm: String, CaseIterable {
        case expandedOr
        case sqlRowValue
    }

    private struct Cursor {
        let createdAt: Date
        let id: UUID
    }

    // MARK: - Corpus

    /// 23 live clips, four per `createdAt` second, with tombstones interleaved on the same
    /// seconds so a leaked filter or a mis-ordered tie-break corrupts some page.
    private func makeCorpus(liveCount: Int = 23) throws -> any DatabaseWriter {
        let database = try TestDatabase.make()
        try database.write { db in
            for index in 0..<liveCount {
                var clip = Make.clip(
                    title: "live \(index)",
                    contentHash: "poc-live-\(index)",
                    createdAt: Make.epoch.addingTimeInterval(TimeInterval(index / 4))
                )
                clip.updatedAt = clip.createdAt
                try Clip.insert { clip }.execute(db)
            }
            for index in 0..<(liveCount / 4) {
                var dead = Make.clip(
                    title: "",
                    contentHash: "poc-dead-\(index)",
                    createdAt: Make.epoch.addingTimeInterval(TimeInterval(index))
                )
                dead.titleCipher = Data()
                dead.updatedAt = dead.createdAt
                dead.deletedAt = Make.epoch
                try Clip.insert { dead }.execute(db)
            }
        }
        return database
    }

    // MARK: - Page fetch (both forms, both directions)

    private func fetchPage(_ db: Database,
                           form: KeysetForm,
                           after cursor: Cursor?,
                           ascending: Bool,
                           limit: Int) throws -> [Clip] {
        let base = Clip.where { $0.deletedAt.is(nil) }
        switch (form, ascending, cursor) {
        case (_, false, .none):
            return try base
                .order { ($0.createdAt.desc(), $0.id.desc()) }
                .limit(limit)
                .fetchAll(db)
        case (_, true, .none):
            return try base
                .order { ($0.createdAt.asc(), $0.id.asc()) }
                .limit(limit)
                .fetchAll(db)
        case let (.expandedOr, false, .some(cursor)):
            return try base
                .where {
                    $0.createdAt.lt(#bind(cursor.createdAt))
                        .or($0.createdAt.eq(#bind(cursor.createdAt)).and($0.id.lt(#bind(cursor.id))))
                }
                .order { ($0.createdAt.desc(), $0.id.desc()) }
                .limit(limit)
                .fetchAll(db)
        case let (.expandedOr, true, .some(cursor)):
            return try base
                .where {
                    $0.createdAt.gt(#bind(cursor.createdAt))
                        .or($0.createdAt.eq(#bind(cursor.createdAt)).and($0.id.gt(#bind(cursor.id))))
                }
                .order { ($0.createdAt.asc(), $0.id.asc()) }
                .limit(limit)
                .fetchAll(db)
        case let (.sqlRowValue, false, .some(cursor)):
            return try base
                .where {
                    #sql("""
                    (\($0.createdAt), \($0.id)) < \
                    (\(#bind(cursor.createdAt, as: Date.UnixTimeRepresentation.self)), \(#bind(cursor.id, as: UUID.self)))
                    """)
                }
                .order { ($0.createdAt.desc(), $0.id.desc()) }
                .limit(limit)
                .fetchAll(db)
        case let (.sqlRowValue, true, .some(cursor)):
            return try base
                .where {
                    #sql("""
                    (\($0.createdAt), \($0.id)) > \
                    (\(#bind(cursor.createdAt, as: Date.UnixTimeRepresentation.self)), \(#bind(cursor.id, as: UUID.self)))
                    """)
                }
                .order { ($0.createdAt.asc(), $0.id.asc()) }
                .limit(limit)
                .fetchAll(db)
        }
    }

    private func walkPages(_ database: any DatabaseWriter,
                           form: KeysetForm,
                           ascending: Bool,
                           pageSize: Int) throws -> [[UUID]] {
        var pages: [[UUID]] = []
        var cursor: Cursor?
        while pages.count < 64 {
            let fetched = try database.read { db in
                try fetchPage(db, form: form, after: cursor, ascending: ascending, limit: pageSize + 1)
            }
            let page = Array(fetched.prefix(pageSize))
            if page.isEmpty { break }
            pages.append(page.map(\.id))
            if fetched.count <= pageSize { break }
            let last = page[page.count - 1]
            cursor = Cursor(createdAt: last.createdAt, id: last.id)
        }
        return pages
    }

    private func expectedOrder(_ database: any DatabaseWriter, ascending: Bool) throws -> [UUID] {
        try database.read { db in
            if ascending {
                return try Clip.where { $0.deletedAt.is(nil) }
                    .order { ($0.createdAt.asc(), $0.id.asc()) }
                    .fetchAll(db).map(\.id)
            } else {
                return try Clip.where { $0.deletedAt.is(nil) }
                    .order { ($0.createdAt.desc(), $0.id.desc()) }
                    .fetchAll(db).map(\.id)
            }
        }
    }

    // MARK: - Tests

    @Test(arguments: KeysetForm.allCases, [false, true])
    func keysetWalkMatchesTheTwoKeyOrderWithoutDuplicateOrMiss(form: KeysetForm, ascending: Bool) throws {
        let database = try makeCorpus()
        let pages = try walkPages(database, form: form, ascending: ascending, pageSize: 5)
        // Count-shaped assertions: no row identity in failure output (plan v2 §3.2).
        let pageCounts = pages.map(\.count)
        #expect(pageCounts == [5, 5, 5, 5, 3])
        let walked = pages.flatMap { $0 }
        let uniqueWalkedCount = Set(walked).count
        #expect(uniqueWalkedCount == 23)
        let matchesExpectedOrder = try walked == expectedOrder(database, ascending: ascending)
        #expect(matchesExpectedOrder)
    }

    @Test(arguments: [false, true])
    func bothFormsProduceIdenticalPages(ascending: Bool) throws {
        let database = try makeCorpus()
        let expanded = try walkPages(database, form: .expandedOr, ascending: ascending, pageSize: 5)
        let rowValue = try walkPages(database, form: .sqlRowValue, ascending: ascending, pageSize: 5)
        let formsAgree = expanded == rowValue
        #expect(formsAgree)
    }

    @Test func storedIDTextIsTheLowercasedUUIDForm() throws {
        let database = try TestDatabase.make()
        let clip = Make.clip(title: "casing probe")
        try database.write { db in try Clip.insert { clip }.execute(db) }
        let stored = try database.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM clips LIMIT 1")
        }
        let storedMatchesLowercasedCanonicalForm = stored == clip.id.uuidString.lowercased()
        #expect(storedMatchesLowercasedCanonicalForm)
    }

    /// Captures the SQL each form actually emits, EXPLAINs it against the v4 partial live index
    /// (present via the production migrator in `TestDatabase.make()`), and prints the plan lines
    /// (index/table names only — no row content) for the P2 report.
    @Test func partialLiveIndexAppearsInTheKeysetQueryPlan() throws {
        let database = try makeCorpus()
        let cursor = Cursor(createdAt: Make.epoch.addingTimeInterval(3), id: UUID())
        var plansByForm: [KeysetForm: [String]] = [:]
        for form in KeysetForm.allCases {
            let plan = try database.read { db -> [String] in
                var capturedSQL: [String] = []
                db.trace(options: .statement) { event in
                    if case let .statement(statement) = event {
                        capturedSQL.append(statement.expandedSQL)
                    }
                }
                _ = try fetchPage(db, form: form, after: cursor, ascending: false, limit: 6)
                db.trace(options: .statement, nil)
                guard let keysetSQL = capturedSQL.last else { return [] }
                return try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(keysetSQL)")
                    .compactMap { $0["detail"] as String? }
            }
            plansByForm[form] = plan
            for line in plan {
                print("poc-eqp form=\(form.rawValue) detail=\(line)")
            }
        }
        // Both forms must at least be served by the partial live index; whether the access is a
        // seek (SEARCH) or a scan-of-index decides which form P2 adopts — recorded via the
        // printed lines above and asserted for the row-value form, SQLite's documented
        // scrolling-window shape.
        let rowValueUsesLiveIndex = (plansByForm[.sqlRowValue] ?? [])
            .contains { $0.contains("clips_live_createdAt_id") }
        #expect(rowValueUsesLiveIndex)
        let expandedPlanCount = (plansByForm[.expandedOr] ?? []).count
        #expect(expandedPlanCount > 0)
    }

    @Test func valueObservationStartsAndCancelsFromANonViewContext() async throws {
        let database = try TestDatabase.make()
        let observation = ValueObservation.tracking { db in
            try Clip.where { $0.deletedAt.is(nil) }.fetchCount(db)
        }
        var received: [Int] = []
        for try await liveCount in observation.values(in: database) {
            received.append(liveCount)
            if received.count == 1 {
                try await database.write { db in
                    try Clip.insert { Make.clip(title: "observed") }.execute(db)
                }
            }
            if received.count == 2 { break }
        }
        // Breaking out of the loop cancels the observation (AsyncValueObservation contract).
        #expect(received == [0, 1])
    }
}
