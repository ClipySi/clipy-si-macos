//
//  HistoryManagerPagingTests.swift
//  ClipyTests
//
//  M-UI.11 P5: the manager's SQL read surface — sort push-down (date/app/type/pinned, both
//  directions), keyset continuation across equal sort values and same-second collisions,
//  metadata filters, facets, the date-order parity with `fetchLive`, and the P5 exit criterion
//  that an open decrypts one page + nothing else. Count/Bool-shaped assertions only (plan v2
//  §3.2).
//

import AppKit
import Foundation
import SQLiteData
import Testing

@testable import Clipy

/// Shared corpus builder for the manager tests: rows with controlled type/app/pin metadata,
/// sealed with the perf fixture's real AES-GCM cipher.
enum ManagerFixture {
    static let text = NSPasteboard.PasteboardType.string.rawValue
    static let image = NSPasteboard.PasteboardType.tiff.rawValue

    @discardableResult
    static func insert(_ database: any DatabaseWriter, title: String,
                       type: String = text, app: String? = nil, pinned: Bool = false,
                       second: Int, deleted: Bool = false) throws -> Clip {
        var clip = Clip(
            id: UUID(),
            contentHash: UUID().uuidString,
            titleCipher: deleted ? Data() : try PerfFixture.cipher.seal(Data(title.utf8)),
            primaryType: type,
            createdAt: Make.epoch.addingTimeInterval(TimeInterval(second)),
            isPinned: pinned,
            dataPath: "/nonexistent/\(UUID().uuidString).data",
            thumbnailID: nil,
            sourceBundle: app)
        clip.updatedAt = clip.createdAt
        if deleted { clip.deletedAt = Make.epoch }
        try database.write { db in try Clip.insert { clip }.execute(db) }
        return clip
    }

    /// 24 rows cycling through apps (incl. NULL and ''), types, pins — with every fourth pair
    /// sharing one `createdAt` second so tie-breaks are always exercised.
    static func mixedCorpus() throws -> any DatabaseWriter {
        let database = try TestDatabase.make()
        let apps: [String?] = [nil, "", "com.example.alpha", "com.example.beta"]
        let types = [text, image, NSPasteboard.PasteboardType.pdf.rawValue]
        for index in 0..<24 {
            try insert(database, title: "row \(index)",
                       type: types[index % types.count],
                       app: apps[index % apps.count],
                       pinned: index % 5 == 0,
                       second: index / 2) // pairs share a second
        }
        return database
    }

    static let allSorts: [ManagerSort] = [
        ManagerSort(key: .date, ascending: false), ManagerSort(key: .date, ascending: true),
        ManagerSort(key: .app, ascending: false), ManagerSort(key: .app, ascending: true),
        ManagerSort(key: .type, ascending: false), ManagerSort(key: .type, ascending: true),
        ManagerSort(key: .pinned, ascending: false), ManagerSort(key: .pinned, ascending: true)
    ]

    /// Runs its work exactly once — a mid-scan mutation trigger for hooks that fire per row
    /// (`@unchecked`: the mask evaluator runs serially on the read actor's executor).
    final class FireOnce: @unchecked Sendable {
        private var fired = false

        func fire(_ work: () -> Void) {
            guard !fired else { return }
            fired = true
            work()
        }
    }
}

@Suite struct HistoryManagerPagingTests {

    private func makeRequest(pageSize: Int = 50, filter: ManagerRowFilter = .none,
                             sort: ManagerSort = .newestFirst) -> HistoryReadService.ManagerRequest {
        HistoryReadService.ManagerRequest(
            pageSize: pageSize, filter: filter, sort: sort,
            policy: DisplayPolicy(maskEnabled: false, maskStyleRaw: "full",
                                  classifierAlgorithmVersion: CodeClassifier.algorithmVersion))
    }

    /// Walk every page of `request` through the service and return the concatenation.
    private func allPages(of service: HistoryReadService,
                          _ request: HistoryReadService.ManagerRequest) async -> [HistoryClipRow] {
        var rows: [HistoryClipRow] = []
        var cursor: ManagerPageCursor?
        for _ in 0..<100 {
            let page = await service.managerPage(after: cursor, options: cursor == nil ? .count : [], request)
            rows += page.rows
            guard let next = page.nextCursor else { return rows }
            cursor = next
        }
        return rows
    }

    /// EVERY sort key × direction: paging in small steps visits exactly the rows one big fetch
    /// returns, in the same order — no skips, no duplicates across equal-value boundaries
    /// (apps and types repeat; pins are binary; pairs share createdAt seconds).
    @Test func pagedWalksMatchTheSingleFetchUnderEverySort() async throws {
        let database = try ManagerFixture.mixedCorpus()
        try await withDependencies {
            $0.defaultDatabase = database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
        } operation: {
            let service = HistoryReadService()
            for sort in ManagerFixture.allSorts {
                let paged = await allPages(of: service, makeRequest(pageSize: 5, sort: sort))
                let whole = await allPages(of: service, makeRequest(pageSize: 100, sort: sort))
                #expect(paged.count == 24)
                let sameOrder = paged.map(\.id) == whole.map(\.id)
                #expect(sameOrder, "sort \(sort) paged walk diverged from the single fetch")
                let pairwiseOrdered = zip(paged, paged.dropFirst()).allSatisfy { earlier, later in
                    !sort.areInOrder(later, earlier) // later never strictly precedes earlier
                }
                #expect(pairwiseOrdered, "sort \(sort) violated its own comparator")
            }
        }
    }

    /// The manager's date order is the SAME total order the panel serves (`fetchLive`) — the
    /// two query bodies must never drift (the P3 one-query-body lesson, pinned as parity).
    @Test func dateSortParityWithFetchLive() throws {
        let database = try ManagerFixture.mixedCorpus()
        try withDependencies {
            $0.defaultDatabase = database
        } operation: {
            for ascending in [false, true] {
                let managerIDs = try database.read { db in
                    try ClipRepository.managerFetch(
                        db, filter: .none,
                        sort: ManagerSort(key: .date, ascending: ascending),
                        after: nil, limit: 100).map(\.id)
                }
                let panelIDs = try database.read { db in
                    try ClipRepository.fetchLive(db, after: nil, limit: 100,
                                                 ascending: ascending).map(\.id)
                }
                #expect(managerIDs == panelIDs)
            }
        }
    }

    /// NULL and '' apps display identically (""), so the app sort must keep them adjacent and
    /// the cursor must not lose rows crossing that seam — ORDER BY and the cursor predicate
    /// share one `coalesce(sourceBundle, '')` expression.
    @Test func appSortKeepsNilAndEmptyBundlesAdjacentAcrossPages() async throws {
        let database = try TestDatabase.make()
        try await withDependencies {
            $0.defaultDatabase = database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
        } operation: {
            for index in 0..<6 { // 3 NULL + 3 '' rows interleaved in time
                try ManagerFixture.insert(database, title: "blank \(index)",
                                          app: index % 2 == 0 ? nil : "", second: index)
            }
            for index in 0..<4 {
                try ManagerFixture.insert(database, title: "named \(index)",
                                          app: "com.example.app", second: 10 + index)
            }
            let service = HistoryReadService()
            let sort = ManagerSort(key: .app, ascending: true)
            let rows = await allPages(of: service, makeRequest(pageSize: 2, sort: sort))
            #expect(rows.count == 10)
            // Ascending: the 6 blank-display rows (NULL + '') first, the named ones after.
            let blanksFirst = rows.prefix(6).allSatisfy { $0.sourceBundleDisplay.isEmpty }
                && rows.dropFirst(6).allSatisfy { !$0.sourceBundleDisplay.isEmpty }
            #expect(blanksFirst)
            #expect(Set(rows.map(\.id)).count == 10)
        }
    }

    @Test func metadataFiltersCompose() throws {
        let database = try ManagerFixture.mixedCorpus()
        try withDependencies {
            $0.defaultDatabase = database
        } operation: {
            let repo = ClipRepository()
            let filter = ManagerRowFilter(primaryTypes: [ManagerFixture.text],
                                          sourceBundle: "com.example.alpha")
            let data = try repo.managerPage(filter: filter, sort: .newestFirst, after: nil,
                                            limit: 100, options: .count)
            // mixedCorpus: type cycles %3, app cycles %4 → indices ≡ 0 (mod 3) and ≡ 2 (mod 4):
            // 6, 18 — two rows.
            #expect(data.page.count == 2)
            #expect(data.filteredCount == 2)
            let allMatch = data.page.allSatisfy {
                $0.primaryType == ManagerFixture.text && $0.sourceBundle == "com.example.alpha"
            }
            #expect(allMatch)
        }
    }

    @Test func facetsAreDistinctLiveAndExcludeNullApps() throws {
        let database = try ManagerFixture.mixedCorpus()
        try withDependencies {
            $0.defaultDatabase = database
        } operation: {
            // A tombstone with a type/app no live row has — must not become a facet.
            try ManagerFixture.insert(database, title: "", type: "public.rtf",
                                      app: "com.example.dead", second: 99, deleted: true)
            let repo = ClipRepository()
            let data = try repo.managerPage(filter: .none, sort: .newestFirst, after: nil,
                                            limit: 1, options: .facets)
            #expect(data.typeRawValues?.count == 3)
            #expect(data.typeRawValues?.contains("public.rtf") == false)
            // NULL apps are excluded at the query; '' survives to the store (which drops it).
            #expect(data.apps?.contains("com.example.alpha") == true)
            #expect(data.apps?.contains("com.example.dead") == false)
        }
    }

    /// The P5 exit criterion: opening the manager decrypts/masks ONE page — the sentinel row
    /// and the rest of a 5,000-row corpus are never touched.
    @Test func openDecryptsOnePageRegardlessOfCorpusSize() async throws {
        final class EvaluationCounter: @unchecked Sendable {
            private(set) var count = 0

            func increment() { count += 1 }
        }

        let corpus = try PerfFixture.makeCorpus(liveCount: 5_000)
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
            let result = await service.managerPage(after: nil, options: [.count, .facets], makeRequest())
            #expect(result.rows.count == 50)
            #expect(result.filteredCount == 5_000)
            #expect(result.nextCursor != nil)
            #expect(result.facets != nil)
        }
        #expect(counter.count == 50)
    }

    @Test func aFailedPageReadFlagsFailed() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 10)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
        } operation: {
            let service = HistoryReadService()
            try corpus.database.close()
            let result = await service.managerPage(after: nil, options: .count, makeRequest())
            #expect(result.failed)
            #expect(result.rows.isEmpty)
        }
    }
}
