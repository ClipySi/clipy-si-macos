//
//  HistoryManagerStoreSearchTests.swift
//  ClipyTests
//
//  M-UI.11 P5: the store's search lifecycle — the 100 ms debounce and its interactions with
//  reconciles (a silent restart must never swallow the user's pending scan), stamp/generation
//  guarding across value-equal restarts, search-mode paging over the cumulative matches,
//  silent-failure retention, and the shrink clamp. Split from HistoryManagerStoreTests for
//  the lint body-length budget.
//

import Foundation
import SQLiteData
import Testing

@testable import Clipy

@MainActor
private func makeStore() -> HistoryManagerStore {
    let store = HistoryManagerStore(
        readService: HistoryReadService(),
        settings: AppSettings(defaults: UserDefaults(suiteName: "manager-search-tests-\(UUID())")!))
    store.isActive = true // tests drive reconcile() directly, without run()
    return store
}

@MainActor
private func settleLoad(_ store: HistoryManagerStore) async {
    await store.loadTask?.value
}

@MainActor
private func settleScan(_ store: HistoryManagerStore) async {
    await store.scanDebounceTask?.value
    await store.scanTask?.value
}

@MainActor
@Suite struct HistoryManagerStoreSearchTests {

    @Test func searchScansProgressivelyAndWhitespaceEditsNeverRestart() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 300)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
            $0.date = .constant(Make.epoch)
        } operation: {
            let store = makeStore()
            await store.reconcile()
            store.searchText = "note"
            #expect(store.isScanning) // progress shows from the first keystroke
            await settleScan(store)
            #expect(!store.isScanning)
            let settled = store.scanMatches.count
            #expect(settled > 0)
            #expect(store.displayedRows.count == min(settled, HistoryManagerStore.pageSize))
            #expect(store.displayedTotal == settled)

            // A whitespace edit normalizes to the same query: no debounce, no restart.
            store.searchText = "note "
            #expect(store.scanDebounceTask == nil)
            #expect(store.scanTask == nil)
            #expect(store.scanMatches.count == settled)

            // Clearing returns to the paged table.
            store.searchText = ""
            await settleLoad(store)
            #expect(!store.isSearching)
            #expect(store.scanMatches.isEmpty)
            #expect(store.pageRows.count == 50)
        }
    }

    @Test func searchModePagingWalksTheMatches() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 300)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
            $0.date = .constant(Make.epoch)
        } operation: {
            let store = makeStore()
            await store.reconcile()
            store.searchText = "note"
            await settleScan(store)
            let matches = store.scanMatches
            #expect(matches.count > HistoryManagerStore.pageSize) // multi-page result set

            store.goToNextPage()
            #expect(store.pageIndex == 1)
            let pageSize = HistoryManagerStore.pageSize
            let secondPage = Array(matches[pageSize..<min(2 * pageSize, matches.count)])
            #expect(store.displayedRows.map(\.id) == secondPage.map(\.id))
            #expect(store.selection == nil)

            while store.canGoNext { store.goToNextPage() }
            #expect(store.pageIndex == store.lastPageIndex)
            #expect(!store.displayedRows.isEmpty)

            store.goToPreviousPage()
            #expect(store.pageIndex == store.lastPageIndex - 1)
            #expect(store.displayedRows.count == pageSize)
        }
    }

    @Test func aStaleScanNeverRendersAfterTheQueryChanges() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 300)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
            $0.date = .constant(Make.epoch)
        } operation: {
            let store = makeStore()
            await store.reconcile()
            store.searchText = "note"
            await store.scanDebounceTask?.value // scan for "note" is now in flight
            store.searchText = "invoice"        // replaced before it settles
            await settleScan(store)
            // Only the replacement scan's matches may render: what's on screen must equal a
            // clean scan of the store's OWN active request — a stale wholesale commit from
            // the replaced scan would differ.
            let isReplacementScan = store.activeScanRequest?.query == "invoice"
            #expect(isReplacementScan)
            var reference: Set<UUID> = []
            if let request = store.activeScanRequest {
                for await update in store.readService.managerScan(request, finalOnly: true) {
                    reference = Set(update.matches.map(\.id))
                }
            }
            let rendersOnlyTheReplacement = Set(store.scanMatches.map(\.id)) == reference
            #expect(rendersOnlyTheReplacement)
            #expect(!store.isScanning)
        }
    }

    /// Reverting the query to the scan that is already active/settled must keep it — not
    /// wipe the board and re-walk the corpus (review: "foo" → "foob" → "foo").
    @Test func revertingToTheActiveQueryKeepsTheScan() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 300)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
            $0.date = .constant(Make.epoch)
        } operation: {
            let store = makeStore()
            await store.reconcile()
            store.searchText = "note"
            await settleScan(store)
            let settled = store.scanMatches.count
            let generation = store.scanGeneration

            store.searchText = "notex" // pending restart armed
            store.searchText = "note"  // …and netted back before the debounce fired
            #expect(store.scanDebounceTask == nil)
            #expect(store.scanGeneration == generation) // no restart happened
            #expect(store.scanMatches.count == settled)
            #expect(!store.isScanning)
        }
    }

    /// A reconcile inside the debounce window must defer — not swallow the user's scan with
    /// a silent one (review: the frozen `isScanning` bar with no re-run path).
    @Test func aReconcileDuringTheDebounceDefersAndTheUserScanStillRuns() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 300)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
            $0.date = .constant(Make.epoch)
        } operation: {
            let store = makeStore()
            await store.reconcile()
            store.searchText = "note"
            #expect(store.isScanning)
            await store.reconcile() // lands inside the 100 ms debounce
            #expect(store.pendingReconcile) // deferred — the debounce survives
            #expect(store.scanDebounceTask != nil)
            await settleScan(store)
            #expect(!store.isScanning) // the user's own scan ran and settled
            #expect(!store.scanMatches.isEmpty)
            await store.scanTask?.value // let the drained reconcile's silent pass settle too
            #expect(!store.isScanning)
        }
    }

    @Test func silentRescanRefreshesSettledMatchesWithoutProgress() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 60)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
            $0.date = .constant(Make.epoch)
        } operation: {
            let store = makeStore()
            await store.reconcile()
            store.searchText = "note"
            await settleScan(store)
            let before = store.scanMatches.count
            try ManagerFixture.insert(corpus.database, title: "another note lands", second: 10_000)
            await store.reconcile() // searching + matches on screen → silent re-scan
            #expect(!store.isScanning) // the progress UI never came back for the silent pass
            await store.scanTask?.value
            #expect(store.scanMatches.count == before + 1)
            #expect(!store.isScanning)
        }
    }

    /// A failed SILENT re-scan keeps the visible matches (the P3 never-wipe rule, scan side).
    @Test func aFailedSilentRescanKeepsTheMatches() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 60)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
            $0.date = .constant(Make.epoch)
        } operation: {
            let store = makeStore()
            await store.reconcile()
            store.searchText = "note"
            await settleScan(store)
            let settled = store.scanMatches.count
            #expect(settled > 0)
            try corpus.database.close()
            await store.reconcile()
            await store.scanTask?.value
            #expect(store.scanMatches.count == settled) // never wiped by the failed pass
            #expect(!store.isScanning)
            #expect(store.scanTask == nil)
        }
    }

    /// A silent re-scan that SHRINKS the matches below the current page clamps `pageIndex`.
    @Test func pageIndexClampsWhenASilentRescanShrinksTheMatches() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 300)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
            $0.date = .constant(Make.epoch)
        } operation: {
            let store = makeStore()
            await store.reconcile()
            store.searchText = "note"
            await settleScan(store)
            while store.canGoNext { store.goToNextPage() }
            let deepPage = store.pageIndex
            #expect(deepPage > 0)

            // Hard-delete most of the matched rows, keeping fewer than one page's worth.
            let repo = ClipRepository()
            for row in store.scanMatches.dropFirst(10) {
                try repo.delete(id: row.id, soft: false)
            }
            await store.reconcile()
            await store.scanTask?.value
            #expect(store.scanMatches.count == 10)
            #expect(store.pageIndex == 0)
            #expect(!store.displayedRows.isEmpty)
        }
    }
}
