//
//  HistoryScanTests.swift
//  ClipyTests
//
//  M-UI.11 P4: the progressive scan's contracts — masked-title search semantics (identical to
//  the in-memory tier), category membership and exact counts from one pass (exact only on the
//  final update — §3.1), cumulative window-ordered updates across batch boundaries, the
//  history cap, cooperative cancellation, and the failure report. PerfFixture corpora (real
//  AES-GCM, same-second collisions, interleaved tombstones); count/Bool-shaped assertions
//  (plan v2 §3.2).
//

import Foundation
import SQLiteData
import Testing

@testable import Clipy

@Suite struct HistoryScanTests {

    private func makeRequest(query: String, category: PanelCategory = .all,
                             needsCounts: Bool = false, limit: Int = 100,
                             pageSize: Int = 10) -> HistoryReadService.ScanRequest {
        HistoryReadService.ScanRequest(
            base: HistoryReadService.PageRequest(
                pageSize: pageSize, historyLimit: limit, ascending: false,
                policy: DisplayPolicy(maskEnabled: false, maskStyleRaw: "full",
                                      classifierAlgorithmVersion: CodeClassifier.algorithmVersion)),
            query: query, category: category, needsCounts: needsCounts)
    }

    private func finalUpdate(of service: HistoryReadService,
                             _ request: HistoryReadService.ScanRequest) async -> HistoryReadService.ScanUpdate? {
        var last: HistoryReadService.ScanUpdate?
        for await update in service.scanWindow(request) {
            last = update
        }
        return last
    }

    @Test func scanSearchMatchesTheInMemoryTierExactly() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 47)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
        } operation: {
            let service = HistoryReadService()
            let request = makeRequest(query: "note")
            // The reference: the whole window through the same masked-title predicate the
            // model's in-memory tier uses.
            var walked: [PanelRow] = []
            var cursor: ClipPageCursor?
            while true {
                let page = await service.openPrefix(rowCount: 100, request.base)
                walked = page.rows
                cursor = page.nextCursor
                if cursor == nil { break }
            }
            let expected = PanelSearch.filter(walked, query: "note").map(\.id)

            let final = await finalUpdate(of: service, request)
            #expect(final?.complete == true)
            let scanAgrees = final?.matches.map(\.id) == expected
            #expect(scanAgrees)
            #expect(final?.total == 47)
            #expect(final?.processed == 47)
        }
    }

    @Test func countsAreExactAndFinalOnly() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 300)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
        } operation: {
            let service = HistoryReadService()
            let request = makeRequest(query: "", needsCounts: true, limit: 1_000)
            var sawIntermediateCounts = false
            var final: HistoryReadService.ScanUpdate?
            for await update in service.scanWindow(request) {
                if !update.complete && update.counts != nil { sawIntermediateCounts = true }
                final = update
            }
            // §3.1: a partial count never leaves the actor; the final one is exact.
            #expect(!sawIntermediateCounts)
            #expect(final?.complete == true)
            let allCategoriesCounted = final?.counts?.keys.count == PanelCategory.allCases.count
            #expect(allCategoriesCounted)
            // Every selectable live row matches .all — the .all count is the window itself.
            #expect(final?.counts?[.all] == 300)
        }
    }

    @Test func updatesAreCumulativeAndWindowOrderedAcrossBatches() async throws {
        // 300 live rows = 3 scan batches: cross-batch cursor + cumulative growth get exercised.
        let corpus = try PerfFixture.makeCorpus(liveCount: 300)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
        } operation: {
            let service = HistoryReadService()
            var previous: [RowID] = []
            var updates = 0
            for await update in service.scanWindow(makeRequest(query: "", limit: 1_000)) {
                updates += 1
                let ids = update.matches.map(\.id)
                // Cumulative: every earlier update is a strict prefix of the later ones — a
                // conflated (dropped) intermediate update can never lose rows.
                let extendsPrevious = Array(ids.prefix(previous.count)) == previous
                #expect(extendsPrevious)
                previous = ids
            }
            #expect(updates >= 1)
            #expect(previous.count == 300)
            let uniqueCount = Set(previous).count
            #expect(uniqueCount == 300)
        }
    }

    @Test func theScanStopsAtTheHistoryCap() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 47)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
        } operation: {
            let service = HistoryReadService()
            let final = await finalUpdate(of: service, makeRequest(query: "", limit: 20))
            #expect(final?.complete == true)
            #expect(final?.matches.count == 20)
            #expect(final?.total == 20)
        }
    }

    @Test func breakingOutOfTheStreamCancelsTheWalk() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 300)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
        } operation: {
            let service = HistoryReadService()
            var firstObservedCount = 0
            for await update in service.scanWindow(makeRequest(query: "", limit: 1_000)) {
                firstObservedCount = update.matches.count
                break // AsyncStream.onTermination cancels the walking task
            }
            // Leaving mid-stream neither hangs nor loses the walk's cancellation. The count
            // observed is whatever update conflation delivered first — under scheduler delay
            // that can already be a later batch, so only its presence is asserted here
            // (progressiveness is pinned by updatesAreCumulativeAndWindowOrderedAcrossBatches).
            #expect(firstObservedCount > 0)
        }
    }

    @Test func aWindowExactlyOnABatchBoundaryStillSettles() async throws {
        // 256 = 2 × scanBatchSize: the wall lands exactly on a batch boundary — the walk must
        // still end with a COMPLETE update (review: a missing terminal update left the panel
        // scanning forever with the coalescer refusing to re-run).
        let corpus = try PerfFixture.makeCorpus(liveCount: 256)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
        } operation: {
            let service = HistoryReadService()
            let final = await finalUpdate(of: service, makeRequest(query: "", limit: 1_000))
            #expect(final?.complete == true)
            #expect(final?.matches.count == 256)
        }
    }

    @Test func anEmptyWindowSettlesImmediately() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 0)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
        } operation: {
            let service = HistoryReadService()
            let final = await finalUpdate(of: service, makeRequest(query: "note"))
            #expect(final?.complete == true)
            #expect(final?.matches.isEmpty == true)
            #expect(final?.total == 0)
        }
    }

    @Test func finalOnlyModeYieldsExactlyOneSettledUpdate() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 300)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
        } operation: {
            let service = HistoryReadService()
            var updates = 0
            var sawUnsettled = false
            for await update in service.scanWindow(makeRequest(query: "", limit: 1_000),
                                                   finalOnly: true) {
                updates += 1
                if !update.isSettled { sawUnsettled = true }
            }
            // The silent-reconcile mode: no intermediate payloads are even built.
            #expect(updates == 1)
            #expect(!sawUnsettled)
        }
    }

    @Test func aFailedScanReportsFailureWithPartialMatches() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 47)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
        } operation: {
            let service = HistoryReadService()
            try corpus.database.close()
            let final = await finalUpdate(of: service, makeRequest(query: ""))
            #expect(final?.failed == true)
            #expect(final?.complete == false)
        }
    }
}
