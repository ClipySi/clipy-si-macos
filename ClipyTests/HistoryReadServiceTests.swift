//
//  HistoryReadServiceTests.swift
//  ClipyTests
//
//  M-UI.11 P2: the off-MainActor read path's page contract — pageSize + sentinel fetches,
//  cursor walks across same-second collisions in both sort directions, the history cap,
//  tombstone exclusion, and the P2 exit criterion that a normal open's fetch/decrypt volume
//  does NOT grow with the corpus (30 → 5,000 rows). The corpus comes from PerfFixture (real
//  AES-GCM ciphertexts, 4 rows per second, 10% interleaved tombstones). Count-shaped
//  assertions only — no titles or ids in failure output (plan v2 §3.2).
//

import Foundation
import GRDB
import SQLiteData
import Testing

@testable import Clipy

@Suite struct HistoryReadServiceTests {

    /// Trace sink for the fetch-shape test — the trace callback is `@Sendable`; appends happen
    /// serially on the fixture's single DB connection.
    private final class CapturedSQL: @unchecked Sendable {
        private(set) var statements: [String] = []

        func append(_ sql: String) { statements.append(sql) }
    }

    /// Counts mask evaluations — every successfully decrypted title is masked exactly once, so
    /// this probes "how many titles did the read touch". `@unchecked`: bumped only on the
    /// service actor's executor; read after the awaits complete.
    private final class EvaluationCounter: @unchecked Sendable {
        private(set) var count = 0

        func increment() { count += 1 }
    }

    private func makeRequest(pageSize: Int = 10, limit: Int = 100,
                             ascending: Bool = false) -> HistoryReadService.PageRequest {
        HistoryReadService.PageRequest(
            pageSize: pageSize,
            historyLimit: limit,
            ascending: ascending,
            policy: DisplayPolicy(maskEnabled: false, maskStyleRaw: "full",
                                  classifierAlgorithmVersion: CodeClassifier.algorithmVersion))
    }

    @Test func openPageServesOnePageAndTheWindowTotal() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 47)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
        } operation: {
            let service = HistoryReadService()
            let result = await service.openPage(makeRequest())
            #expect(result.rows.count == 10)
            #expect(result.totalCount == 47)
            let hasMorePages = result.nextCursor != nil
            #expect(hasMorePages)
        }
    }

    /// Review: the exit criterion is about what the open FETCHES, not just what it serves —
    /// pin the SQL shape: the page SELECT carries `LIMIT pageSize + 1` (the sentinel), and no
    /// clips SELECT in the open is unbounded.
    @Test func openPageFetchesOnlyThePagePlusSentinelFromTheDB() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 47)
        let captured = CapturedSQL()
        try await corpus.database.write { db in
            db.trace(options: .statement) { event in
                if case let .statement(statement) = event {
                    captured.append(statement.expandedSQL)
                }
            }
        }
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
        } operation: {
            _ = await HistoryReadService().openPage(makeRequest(pageSize: 10, limit: 100))
        }
        try await corpus.database.write { db in db.trace(options: .statement, nil) }

        let clipSelects = captured.statements.filter { $0.hasPrefix("SELECT") && $0.contains("clips") }
        let pageFetchHasSentinelLimit = clipSelects.contains { $0.contains("LIMIT 11") }
        #expect(pageFetchHasSentinelLimit)
        let unboundedSelects = clipSelects.count { !$0.lowercased().contains("count(") && !$0.contains("LIMIT") }
        #expect(unboundedSelects == 0)
    }

    @Test(arguments: [false, true])
    func sequentialWalkMatchesTheWindowOrderWithoutDuplicateOrMiss(ascending: Bool) async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 47)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
        } operation: {
            let service = HistoryReadService()
            let request = makeRequest(ascending: ascending)
            var result = await service.openPage(request)
            var walked = result.rows
            var hops = 0
            while let cursor = result.nextCursor, hops < 32 {
                hops += 1
                result = await service.nextPage(after: cursor, loadedCount: walked.count, request)
                walked += result.rows
            }
            #expect(walked.count == 47)
            let uniqueWalkedCount = Set(walked.map(\.id)).count
            #expect(uniqueWalkedCount == 47)
            // Tombstones interleave the same seconds — a filter leak would surface them as
            // decrypt-failed ghosts (their titleCipher is wiped) or inflate the counts.
            let ghostRows = walked.count(where: \.decryptFailed)
            #expect(ghostRows == 0)
            // The walk and an unfiltered scan must agree row for row — same total order
            // (`(createdAt, id)`), or the scan's matches would reshuffle against the pages.
            var scanIDs: [RowID] = []
            let scanRequest = HistoryReadService.ScanRequest(base: request, query: "",
                                                             category: .all, needsCounts: false)
            for await update in service.scanWindow(scanRequest) where update.complete {
                scanIDs = update.matches.map(\.id)
            }
            let walkMatchesScanOrder = walked.map(\.id) == scanIDs
            #expect(walkMatchesScanOrder)
        }
    }

    @Test func theWalkStopsAtTheHistoryCap() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 47)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
        } operation: {
            let service = HistoryReadService()
            let request = makeRequest(pageSize: 10, limit: 25)
            let first = await service.openPage(request)
            #expect(first.rows.count == 10)
            #expect(first.totalCount == 25)
            let firstCursor = try #require(first.nextCursor)
            let second = await service.nextPage(after: firstCursor, loadedCount: 10, request)
            #expect(second.rows.count == 10)
            let secondCursor = try #require(second.nextCursor)
            let third = await service.nextPage(after: secondCursor, loadedCount: 20, request)
            // The cap truncates the final page and ends the walk — 47 live rows never leak past 25.
            #expect(third.rows.count == 5)
            let walkEnded = third.nextCursor == nil
            #expect(walkEnded)
        }
    }

    /// Review (P2 exit: no page loss/duplication under mutation races): a capture that lands
    /// mid-walk must neither duplicate nor drop the rows that existed at open — the new row
    /// simply waits for the next open (snapshot semantics; P3 reconciles live).
    @Test func aMidWalkCaptureNeitherDropsNorDuplicatesTheOpenRows() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 47)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
        } operation: {
            let service = HistoryReadService()
            let request = makeRequest()
            var result = await service.openPage(request)
            var walked = result.rows

            // A capture arrives between pages, newer than everything served so far.
            var newcomer = Make.clip(title: "mid-walk capture", contentHash: "mid-walk",
                                     createdAt: Make.epoch.addingTimeInterval(10_000))
            newcomer.updatedAt = newcomer.createdAt
            try ClipRepository().add(newcomer)

            var hops = 0
            while let cursor = result.nextCursor, hops < 32 {
                hops += 1
                result = await service.nextPage(after: cursor, loadedCount: walked.count, request)
                walked += result.rows
            }
            #expect(walked.count == 47)
            let uniqueWalkedCount = Set(walked.map(\.id)).count
            #expect(uniqueWalkedCount == 47)
            let newcomerServed = walked.contains { $0.id == .clip(newcomer.id) }
            #expect(!newcomerServed)
        }
    }

    /// Review: a `moveToTop` (paste / dedupe re-copy) of an UNSERVED row mid-walk jumps that
    /// row ahead of the cursor — it goes stale for this open (served on the next one), but no
    /// OTHER row may be dropped and nothing may duplicate. (The ascending-walk re-serve case is
    /// deduped at the model — `PanelPagedWindowTests.appendDropsRowsAlreadyInThePrefix`.)
    @Test func aMoveToTopMidWalkAffectsOnlyTheMovedRow() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 47)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
        } operation: {
            let repository = ClipRepository()
            let openOrder = try repository.recentClips(limit: 100).map(\.id)
            let service = HistoryReadService()
            let request = makeRequest()
            var result = await service.openPage(request)
            var walked = result.rows

            // Move a not-yet-served row (position 20) to the top between pages.
            let movedID = openOrder[20]
            try repository.moveToTop(id: movedID, date: Make.epoch.addingTimeInterval(9_999))

            var hops = 0
            while let cursor = result.nextCursor, hops < 32 {
                hops += 1
                result = await service.nextPage(after: cursor, loadedCount: walked.count, request)
                walked += result.rows
            }
            #expect(walked.count == 46)
            let uniqueWalkedCount = Set(walked.map(\.id)).count
            #expect(uniqueWalkedCount == 46)
            let movedRowServed = walked.contains { $0.id == .clip(movedID) }
            #expect(!movedRowServed)
        }
    }

    @Test func openFetchAndDecryptDoNotGrowWithTheCorpus() async throws {
        // The P2 exit criterion: 30 → 5,000 rows, a normal open still fetches and decrypts one
        // page (pageSize rows; the +1 sentinel is fetched but never decrypted — decrypt/mask
        // run on the served page only).
        for liveCount in [30, 5_000] {
            let corpus = try PerfFixture.makeCorpus(liveCount: liveCount)
            let counter = EvaluationCounter()
            try await withDependencies {
                $0.defaultDatabase = corpus.database
                $0.historyCipher = PerfFixture.cipher
                $0.maskingService = MaskingService(evaluate: { title in
                    counter.increment()
                    return MaskingResult(isSecret: false, display: title)
                })
            } operation: {
                let service = HistoryReadService()
                let result = await service.openPage(makeRequest(pageSize: 10, limit: 100_000))
                #expect(result.rows.count == 10)
                #expect(result.totalCount == liveCount)
            }
            #expect(counter.count == 10)
        }
    }
}
