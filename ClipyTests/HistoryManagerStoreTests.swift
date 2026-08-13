//
//  HistoryManagerStoreTests.swift
//  ClipyTests
//
//  M-UI.11 P5: the manager store's state machine — cursor-stack paging, narrowing resets,
//  reconciliation (deletes, clamping, facet-vanish fallback, failed reads never wiping, the
//  defer/drain protocol), lifecycle (teardown, straggler reconciles, screen lock), and the
//  observation loop (a pin-only UPDATE must fire it — the region watch, not a value fetch).
//  Tests drive the store's methods directly for determinism and await its exposed task
//  handles; the `run()` tests poll with a bounded timeout because GRDB delivers on its own
//  queue. Search-lifecycle coverage lives in HistoryManagerStoreSearchTests.
//

import Foundation
import SQLiteData
import Testing

@testable import Clipy

@MainActor
private func makeStore() -> HistoryManagerStore {
    let store = HistoryManagerStore(
        readService: HistoryReadService(),
        settings: AppSettings(defaults: UserDefaults(suiteName: "manager-store-tests-\(UUID())")!))
    store.isActive = true // tests drive reconcile() directly, without run()
    return store
}

/// Await the store's in-flight page load, if any.
@MainActor
private func settleLoad(_ store: HistoryManagerStore) async {
    await store.loadTask?.value
}

/// Await the debounce, then the scan it starts.
@MainActor
private func settleScan(_ store: HistoryManagerStore) async {
    await store.scanDebounceTask?.value
    await store.scanTask?.value
}

@MainActor
@Suite struct HistoryManagerStoreTests {

    @Test func reconcileLoadsFirstPageCountAndFacets() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 120)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
            $0.date = .constant(Make.epoch)
        } operation: {
            let store = makeStore()
            #expect(!store.hasLoaded)
            await store.reconcile()
            #expect(store.hasLoaded)
            #expect(store.pageRows.count == 50)
            #expect(store.filteredCount == 120)
            #expect(store.lastPageIndex == 2)
            #expect(!store.availableTypes.isEmpty)
            #expect(store.canGoNext)
            #expect(!store.canGoPrevious)
            #expect(!store.historyIsEmpty)
        }
    }

    @Test func anEmptyHistoryOpensIntoTheEmptyStateWithoutFailure() async throws {
        let database = try TestDatabase.make()
        try await withDependencies {
            $0.defaultDatabase = database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
            $0.date = .constant(Make.epoch)
        } operation: {
            let store = makeStore()
            await store.reconcile()
            #expect(store.hasLoaded)
            #expect(store.pageRows.isEmpty)
            #expect(store.filteredCount == 0)
            #expect(store.historyIsEmpty)
            #expect(!store.loadFailed)
            #expect(!store.canGoNext)
            #expect(store.pageCursors.count == 1)
        }
    }

    @Test func nextAndPreviousWalkTheCursorStack() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 120)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
            $0.date = .constant(Make.epoch)
        } operation: {
            let store = makeStore()
            await store.reconcile()
            let firstPageIDs = store.pageRows.map(\.id)

            store.goToNextPage()
            store.goToNextPage() // second click while loading must be swallowed, not double-advance
            await settleLoad(store)
            #expect(store.pageIndex == 1)
            #expect(store.pageCursors.count == 2)
            #expect(store.pageRows.count == 50)
            let secondPageIDs = store.pageRows.map(\.id)
            #expect(Set(secondPageIDs).isDisjoint(with: firstPageIDs))

            store.goToNextPage()
            await settleLoad(store)
            #expect(store.pageIndex == 2)
            #expect(store.pageRows.count == 20)
            #expect(!store.canGoNext)

            store.goToPreviousPage()
            await settleLoad(store)
            #expect(store.pageIndex == 1)
            let backIDs = store.pageRows.map(\.id)
            #expect(backIDs == secondPageIDs)
        }
    }

    @Test func aDeletedNextPageEndsForwardPagingInstead() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 60)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
            $0.date = .constant(Make.epoch)
        } operation: {
            let store = makeStore()
            await store.reconcile()
            // Hard-delete everything beyond page 0 WITHOUT letting a reconcile run first —
            // the held cursor must degrade to "no next page", never a wrong page.
            let repo = ClipRepository()
            let beyond = try await corpus.database.read { db in
                try ClipRepository.fetchLive(db, after: nil, limit: 100, ascending: false)
                    .dropFirst(50).map(\.id)
            }
            for id in beyond { try repo.delete(id: id, soft: false) }
            store.goToNextPage()
            await settleLoad(store)
            #expect(store.pageIndex == 0)
            #expect(store.pageRows.count == 50)
            #expect(!store.canGoNext)
        }
    }

    @Test func sortChangeResetsToPageZeroAndReorders() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 120)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
            $0.date = .constant(Make.epoch)
        } operation: {
            let store = makeStore()
            await store.reconcile()
            store.goToNextPage()
            await settleLoad(store)
            #expect(store.pageIndex == 1)

            // App descending: the corpus's only named bundle sorts ahead of the blank rows.
            store.apply(tableSort: [KeyPathComparator(\HistoryClipRow.sourceBundleDisplay,
                                                      order: .reverse)])
            await settleLoad(store)
            #expect(store.pageIndex == 0)
            #expect(store.sort == ManagerSort(key: .app, ascending: false))
            #expect(store.pageRows.first?.sourceBundleDisplay.isEmpty == false)
        }
    }

    @Test func sortAloneNeverActivatesTheFilterAffordances() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 30)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
            $0.date = .constant(Make.epoch)
        } operation: {
            let store = makeStore()
            await store.reconcile()
            store.apply(tableSort: [KeyPathComparator(\HistoryClipRow.pinnedDisplay, order: .reverse)])
            await settleLoad(store)
            #expect(!store.isFilterActive)
        }
    }

    @Test func typeFilterNarrowsThroughTheLabelMapping() async throws {
        let database = try ManagerFixture.mixedCorpus()
        try await withDependencies {
            $0.defaultDatabase = database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
            $0.date = .constant(Make.epoch)
        } operation: {
            let store = makeStore()
            await store.reconcile()
            #expect(store.availableTypes.contains("Image"))
            store.typeFilter = "Image"
            await settleLoad(store)
            #expect(store.pageRows.count == 8) // 24 rows, type cycle of 3
            #expect(store.filteredCount == 8)
            let allImages = store.pageRows.allSatisfy { $0.typeDisplay == "Image" }
            #expect(allImages)
            #expect(store.isFilterActive)
        }
    }

    @Test func deleteReconcilesTheCurrentPageAndCount() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 60)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
            $0.date = .constant(Make.epoch)
        } operation: {
            let store = makeStore()
            await store.reconcile()
            let victim = store.pageRows[0].id
            try ClipRepository().delete(id: victim, soft: false)
            await store.reconcile()
            #expect(store.filteredCount == 59)
            let stillShown = store.pageRows.contains { $0.id == victim }
            #expect(!stillShown)
            #expect(store.pageRows.count == 50) // the page refills from the rows behind it
        }
    }

    @Test func pruneRowRemovesTheDeletedRowImmediately() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 60)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
            $0.date = .constant(Make.epoch)
        } operation: {
            let store = makeStore()
            await store.reconcile()
            let victim = store.pageRows[0].id
            store.selection = victim
            store.pruneRow(victim) // the view's optimistic path, before the DB write lands
            let stillShown = store.pageRows.contains { $0.id == victim }
            #expect(!stillShown)
            #expect(store.filteredCount == 59)
            #expect(store.selection == nil)
        }
    }

    @Test func deletingTheTrailingPageClampsBack() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 60)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
            $0.date = .constant(Make.epoch)
        } operation: {
            let store = makeStore()
            await store.reconcile()
            store.goToNextPage()
            await settleLoad(store)
            #expect(store.pageIndex == 1)
            let repo = ClipRepository()
            for row in store.pageRows { // wipe page 1 entirely
                try repo.delete(id: row.id, soft: false)
            }
            await store.reconcile()
            #expect(store.pageIndex == 0)
            #expect(store.pageRows.count == 50)
            #expect(store.filteredCount == 50)
            #expect(!store.canGoNext)
        }
    }

    @Test func aFailedReloadNeverWipesLiveRows() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 60)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
            $0.date = .constant(Make.epoch)
        } operation: {
            let store = makeStore()
            await store.reconcile()
            try corpus.database.close()
            await store.reconcile()
            #expect(store.pageRows.count == 50)
            #expect(!store.loadFailed) // rows are still good — no error state over live data
        }
    }

    @Test func aVanishedTypeFacetClearsItsFilter() async throws {
        let database = try ManagerFixture.mixedCorpus()
        try await withDependencies {
            $0.defaultDatabase = database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
            $0.date = .constant(Make.epoch)
        } operation: {
            let store = makeStore()
            await store.reconcile()
            store.typeFilter = "Image"
            await settleLoad(store)
            let repo = ClipRepository()
            let imageIDs = try await database.read { db in
                try ClipRepository.managerFetch(
                    db, filter: ManagerRowFilter(primaryTypes: [ManagerFixture.image]),
                    sort: .newestFirst, after: nil, limit: 100).map(\.id)
            }
            for id in imageIDs {
                try repo.delete(id: id, soft: false)
            }
            await store.reconcile()
            await settleLoad(store) // the facet-clear cascade reloads without the filter
            #expect(store.typeFilter == nil)
            #expect(store.pageRows.count == 16)
        }
    }

    /// The defer/drain protocol: a reconcile arriving while a page move is in flight must not
    /// run concurrently — and must not be lost either.
    @Test func aReconcileDuringAPageMoveDefersAndDrains() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 120)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
            $0.date = .constant(Make.epoch)
        } operation: {
            let store = makeStore()
            await store.reconcile()
            let victim = store.pageRows[0].id
            try ClipRepository().delete(id: victim, soft: false)

            store.goToNextPage() // loadTask now occupies the slot
            await store.reconcile()
            #expect(store.pendingReconcile) // deferred, not dropped, not run concurrently

            await withCheckedContinuation { continuation in
                store.onDidReconcile = { [weak store] in
                    store?.onDidReconcile = nil
                    continuation.resume()
                }
            } // the load's tail drains the deferred reconcile
            #expect(store.filteredCount == 119)
        }
    }
}

/// Lifecycle: teardown, straggler reconciles, screen lock, and the `run()` observation loop.
@MainActor
@Suite struct HistoryManagerStoreLifecycleTests {

    @Test func teardownDropsRowsAndQueryStateAndRetiresTheStore() async throws {
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
            store.teardown()
            #expect(store.pageRows.isEmpty)
            #expect(store.scanMatches.isEmpty)
            #expect(store.pageIndex == 0)
            #expect(store.searchText.isEmpty) // a stale query must not greet the next open
            #expect(!store.hasLoaded)

            // A straggler reconcile scheduled before the close must NOT re-decrypt rows
            // into the retired store (review: the privacy contract of teardown).
            await store.reconcile()
            #expect(store.pageRows.isEmpty)
            #expect(store.scanMatches.isEmpty)
        }
    }

    @Test func screenLockPurgesAndUnlockRebuilds() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 60)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
            $0.date = .constant(Make.epoch)
        } operation: {
            let store = makeStore()
            await store.reconcile()
            #expect(store.pageRows.count == 50)

            store.handleScreenLock()
            #expect(store.pageRows.isEmpty) // D4: nothing decrypted survives behind the lock
            #expect(store.scanMatches.isEmpty)
            await store.reconcile() // writes behind the lock must not rebuild anything
            #expect(store.pageRows.isEmpty)

            store.handleScreenUnlock()
            await store.reconcile()
            #expect(store.pageRows.count == 50)
        }
    }

    /// The observation-loop integration test: `run()`'s initial yield loads page 0, and a
    /// PIN-ONLY update — which changes no observed value a count fetch would see — must still
    /// reconcile (the store watches the table REGION, not a value). Bounded polling: GRDB
    /// delivers on its own queue, so there is no task handle to await.
    @Test func runObservesWritesIncludingPinOnlyUpdates() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 30)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
            $0.date = .constant(Make.epoch)
        } operation: {
            let store = makeStore()
            let runner = Task { await store.run() }
            defer { runner.cancel() }
            var spins = 0
            while store.pageRows.isEmpty, spins < 500 {
                try await Task.sleep(for: .milliseconds(10))
                spins += 1
            }
            #expect(store.pageRows.count == 30)

            let target = store.pageRows[0].id
            try ClipRepository().setPinned(true, id: target)
            spins = 0
            while store.pageRows.first?.isPinned != true, spins < 500 {
                try await Task.sleep(for: .milliseconds(10))
                spins += 1
            }
            #expect(store.pageRows.first?.isPinned == true)
        }
    }

    /// A display-policy change (Privacy pane) must reconcile the open window; an unrelated
    /// defaults write must not. The guard is driven directly — the notification delivery
    /// itself is environment-dependent under the sandboxed test host.
    @Test func aMaskPolicyChangeTriggersAReconcile() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 30)
        let suite = UserDefaults(suiteName: "manager-policy-tests-\(UUID())")!
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
            $0.date = .constant(Make.epoch)
        } operation: {
            let settings = AppSettings(defaults: suite)
            let store = HistoryManagerStore(readService: HistoryReadService(),
                                            settings: settings)
            store.isActive = true
            await store.reconcile() // seeds lastPolicy
            #expect(store.pageRows.count == 30)

            var reconciles = 0
            store.onDidReconcile = { reconciles += 1 }
            store.handleDefaultsChange() // no policy delta → must not reconcile
            for _ in 0..<20 { await Task.yield() }
            #expect(reconciles == 0)

            // Flip to the OPPOSITE of the current value: the test host app registers its
            // defaults into the process-wide NSRegistrationDomain, so even a fresh suite
            // reads maskSecretsInMenu=true — writing `true` would be a zero-delta no-op
            // and the continuation below would never resume.
            suite.set(!settings.maskSecretsInMenu, forKey: DefaultsKeys.maskSecretsInMenu)
            await withCheckedContinuation { continuation in
                store.onDidReconcile = { [weak store] in
                    reconciles += 1
                    store?.onDidReconcile = nil
                    continuation.resume()
                }
                store.handleDefaultsChange()
            }
            #expect(reconciles == 1)
        }
    }
}
