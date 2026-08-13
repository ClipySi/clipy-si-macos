//
//  HistoryManagerScanTests.swift
//  ClipyTests
//
//  M-UI.11 P5: the manager's progressive search — parity with an in-memory reference over the
//  same predicate (`PanelSearch.matchesTitle` over the FULL searchable title), matches already
//  ordered by the requested sort (incl. the metadata-sort merge), SQL filter push-down,
//  placeholder search semantics, cumulative updates, boundary settling, `finalOnly`, and the
//  failure report. Count/Bool-shaped assertions only (plan v2 §3.2).
//

import Foundation
import SQLiteData
import Testing

@testable import Clipy

@Suite struct HistoryManagerScanTests {

    private func makeRequest(query: String, filter: ManagerRowFilter = .none,
                             sort: ManagerSort = .newestFirst,
                             pageSize: Int = 50) -> HistoryReadService.ManagerScanRequest {
        HistoryReadService.ManagerScanRequest(
            base: HistoryReadService.ManagerRequest(
                pageSize: pageSize, filter: filter, sort: sort,
                policy: DisplayPolicy(maskEnabled: false, maskStyleRaw: "full",
                                      classifierAlgorithmVersion: CodeClassifier.algorithmVersion)),
            query: query)
    }

    private func finalUpdate(of service: HistoryReadService,
                             _ request: HistoryReadService.ManagerScanRequest,
                             finalOnly: Bool = false) async -> HistoryReadService.ManagerScanUpdate? {
        var last: HistoryReadService.ManagerScanUpdate?
        for await update in service.managerScan(request, finalOnly: finalOnly) {
            last = update
        }
        return last
    }

    /// Reference: every filtered live row through the SAME searchable-title predicate.
    private func referenceMatchIDs(_ database: any DatabaseWriter, filter: ManagerRowFilter,
                                   query: String) throws -> Set<UUID> {
        let clips = try database.read { db in
            try ClipRepository.managerFetch(db, filter: filter, sort: .newestFirst,
                                            after: nil, limit: 1_000_000)
        }
        let displays = ClipDisplayBuilder().displays(
            of: clips, policy: DisplayPolicy(maskEnabled: false, maskStyleRaw: "full",
                                             classifierAlgorithmVersion: CodeClassifier.algorithmVersion))
        let term = PanelSearch.normalize(query)
        return Set(displays.filter {
            PanelSearch.matchesTitle(HistoryClipRow.searchableTitle(for: $0), term: term)
        }.map(\.id))
    }

    @Test func scanMatchesTheInMemoryReferenceExactly() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 300)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
        } operation: {
            let service = HistoryReadService()
            let expected = try referenceMatchIDs(corpus.database, filter: .none, query: "note")
            let final = await finalUpdate(of: service, makeRequest(query: "note"))
            #expect(final?.complete == true)
            #expect(final?.total == 300)
            #expect(final?.processed == 300)
            let scanAgrees = final.map { Set($0.matches.map(\.id)) == expected } ?? false
            #expect(scanAgrees)
        }
    }

    /// Metadata sorts stream matches already merged into SQL push-down order — the settled set
    /// is pairwise-ordered under the request's own comparator AND equals the reference set.
    /// The 300-row corpus makes every scan span MULTIPLE 128-row batches, so the cumulative
    /// cross-batch merge is what's under test (review: a 24-row corpus only ever merged into
    /// an empty accumulator, and a plain append would have passed).
    @Test func matchesArriveInTheRequestedSortOrderAcrossBatches() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 300)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
        } operation: {
            let service = HistoryReadService()
            let expected = try referenceMatchIDs(corpus.database, filter: .none, query: "note")
            for sort in ManagerFixture.allSorts {
                let request = makeRequest(query: "note", sort: sort)
                let final = await finalUpdate(of: service, request)
                #expect(final?.complete == true)
                let matches = final?.matches ?? []
                let pairwiseOrdered = zip(matches, matches.dropFirst()).allSatisfy { earlier, later in
                    !sort.areInOrder(later, earlier)
                }
                #expect(pairwiseOrdered, "sort \(sort) scan output out of order")
                let sameSet = Set(matches.map(\.id)) == expected
                #expect(sameSet)
            }
        }
    }

    /// Byte-order collation parity where it actually bites: NFC and NFD app names are EQUAL
    /// under Swift's canonical `==` but DISTINCT, non-adjacent groups under SQLite BINARY —
    /// the scan's merged order must equal the paged SQL order anyway.
    @Test func scanOrderMatchesThePagedOrderForNormalizationVariantAppNames() async throws {
        let database = try TestDatabase.make()
        try await withDependencies {
            $0.defaultDatabase = database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
        } operation: {
            let nfc = "com.caf\u{E9}.app"          // é as one scalar (C3 A9)
            let nfd = "com.cafe\u{301}.app"        // e + combining acute (65 CC 81)
            let mid = "com.cafz.app"               // sorts BETWEEN the two under BINARY
            for index in 0..<9 {
                try ManagerFixture.insert(database, title: "note \(index)",
                                          app: [nfc, nfd, mid][index % 3], second: index)
            }
            let service = HistoryReadService()
            let sort = ManagerSort(key: .app, ascending: true)
            let final = await finalUpdate(of: service, makeRequest(query: "note", sort: sort))
            var pagedIDs: [UUID] = []
            var cursor: ManagerPageCursor?
            repeat {
                let page = await service.managerPage(
                    after: cursor, options: [],
                    HistoryReadService.ManagerRequest(pageSize: 2, filter: .none, sort: sort,
                                                      policy: makeRequest(query: "").base.policy))
                pagedIDs += page.rows.map(\.id)
                cursor = page.nextCursor
            } while cursor != nil
            let scanAgreesWithPages = final?.matches.map(\.id) == pagedIDs
            #expect(scanAgreesWithPages)
        }
    }

    /// An ASCENDING date walk can re-encounter a row whose `createdAt` was bumped mid-scan
    /// (moveToTop / re-copy dedupe) — the match set must stay duplicate-free (review: a
    /// doubled `Identifiable` id is undefined Table behavior, not mere staleness).
    @Test func anAscendingScanNeverDuplicatesARowBumpedMidWalk() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 300)
        let oldestNoteID = try await corpus.database.read { db in
            try ClipRepository.fetchLive(db, after: nil, limit: 1, ascending: true).first?.id
        }
        let bumped = ManagerFixture.FireOnce()
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = MaskingService(evaluate: { title in
                // Mid-walk (during the first batch's mask pass), bump the oldest row far
                // past the wall — the ascending walk will meet it again near the end.
                bumped.fire {
                    if let oldestNoteID {
                        try? ClipRepository().moveToTop(id: oldestNoteID,
                                                        date: Make.epoch.addingTimeInterval(10_000))
                    }
                }
                return MaskingResult(isSecret: false, display: title)
            })
            $0.date = .constant(Make.epoch)
        } operation: {
            let service = HistoryReadService()
            let request = makeRequest(query: "", sort: ManagerSort(key: .date, ascending: true))
            let final = await finalUpdate(of: service, request)
            #expect(final?.complete == true)
            let ids = final?.matches.map(\.id) ?? []
            #expect(Set(ids).count == ids.count) // no duplicate identities, ever
        }
    }

    /// Filter push-down: rows cut by metadata never reach decrypt — and "image" finds image
    /// rows through their placeholder title, exactly as the 500-row window's in-memory search
    /// did (the placeholder IS the searchable title for non-text clips).
    @Test func metadataFilterPushdownAndPlaceholderSearch() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 100) // 4 tiff rows (index % 25 == 3)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
        } operation: {
            let service = HistoryReadService()
            let filtered = makeRequest(query: "image",
                                       filter: ManagerRowFilter(primaryTypes: [ManagerFixture.image]))
            let final = await finalUpdate(of: service, filtered)
            #expect(final?.complete == true)
            #expect(final?.total == 4) // the filtered set, not the corpus
            #expect(final?.matches.count == 4)

            // Unfiltered, the same query still finds exactly the image rows via placeholders.
            let unfiltered = await finalUpdate(of: service, makeRequest(query: "image"))
            #expect(unfiltered?.total == 100)
            #expect(unfiltered?.matches.count == 4)
        }
    }

    @Test func aNeedleBeyondThePreviewCapStillMatches() async throws {
        let database = try TestDatabase.make()
        try await withDependencies {
            $0.defaultDatabase = database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
        } operation: {
            let long = String(repeating: "padding ", count: 100) + "needle"
            try ManagerFixture.insert(database, title: long, second: 0)
            try ManagerFixture.insert(database, title: "short row", second: 1)
            let service = HistoryReadService()
            let final = await finalUpdate(of: service, makeRequest(query: "needle"))
            #expect(final?.matches.count == 1)
            // The stored row is display-truncated; the match ran on the full title.
            #expect(final?.matches.first?.preview.count == HistoryClipRow.previewDisplayCap)
            let previewHoldsNeedle = final?.matches.first?.preview.contains("needle") ?? true
            #expect(!previewHoldsNeedle)
        }
    }

    @Test func updatesAreCumulativeUnderTheDateSort() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 300)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
        } operation: {
            let service = HistoryReadService()
            var previous: [UUID] = []
            var updates = 0
            for await update in service.managerScan(makeRequest(query: "")) {
                updates += 1
                let ids = update.matches.map(\.id)
                let extendsPrevious = Array(ids.prefix(previous.count)) == previous
                #expect(extendsPrevious)
                previous = ids
            }
            #expect(updates >= 1)
            #expect(previous.count == 300)
            #expect(Set(previous).count == 300)
        }
    }

    @Test func aWindowExactlyOnABatchBoundaryStillSettles() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 256) // 2 × scanBatchSize
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
        } operation: {
            let service = HistoryReadService()
            let final = await finalUpdate(of: service, makeRequest(query: ""))
            #expect(final?.complete == true)
            #expect(final?.matches.count == 256)
        }
    }

    @Test func anEmptyFilteredSetSettlesImmediately() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 40)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
        } operation: {
            let service = HistoryReadService()
            let request = makeRequest(query: "note",
                                      filter: ManagerRowFilter(sourceBundle: "com.example.absent"))
            let final = await finalUpdate(of: service, request)
            #expect(final?.complete == true)
            #expect(final?.total == 0)
            #expect(final?.matches.isEmpty == true)
        }
    }

    @Test func finalOnlyYieldsExactlyOneSettledUpdate() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 300)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
        } operation: {
            let service = HistoryReadService()
            var updates = 0
            var sawUnsettled = false
            for await update in service.managerScan(makeRequest(query: ""), finalOnly: true) {
                updates += 1
                if !update.isSettled { sawUnsettled = true }
            }
            #expect(updates == 1)
            #expect(!sawUnsettled)
        }
    }

    @Test func aFailedScanReportsFailure() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 40)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
        } operation: {
            let service = HistoryReadService()
            try corpus.database.close()
            let final = await finalUpdate(of: service, makeRequest(query: "note"))
            #expect(final?.failed == true)
            #expect(final?.complete == false)
        }
    }
}
