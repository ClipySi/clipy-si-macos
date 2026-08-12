//
//  HistoryPanelReconcileTests.swift
//  ClipyTests
//
//  M-UI.11 P3: the head-observation reconcile brings an OPEN panel back in line with the DB —
//  deleted rows drop out (nothing stale stays selectable — the P3 exit rule), the page, parked
//  page move, and selection survive where they resolve, narrowing states re-hydrate instead of
//  prefix-committing, a reconcile during the first read defers until its commit, and a FAILED
//  re-read never wipes live rows. The warm-open path is HistoryPanelWarmOpenTests. Real
//  panel/model/service against PerfFixture corpora; tests await the exposed task handles.
//  Count/Bool-shaped assertions (plan v2 §3.2).
//

import AppKit
import Foundation
import SQLiteData
import Testing

@testable import Clipy

@MainActor
@Suite struct HistoryPanelReconcileTests {

    private func makeContext(warmCache: HistoryWarmCache? = nil)
        -> (controller: HistoryPanelController, settings: AppSettings) {
        let defaults = UserDefaults(suiteName: "HistoryPanelReconcileTests-\(UUID().uuidString)")!
        DefaultsKeys.registerDefaults(in: defaults)
        defaults.set(100, forKey: DefaultsKeys.maxHistorySize)
        let settings = AppSettings(defaults: defaults)
        let coordinator = ClipSelectionCoordinator(model: MenuModel(settings: settings))
        let controller = HistoryPanelController(coordinator: coordinator, warmCache: warmCache)
        return (controller, settings)
    }

    // MARK: - Reconcile (§5.5; exit rule: nothing stale stays selectable)

    @Test func reconcileDropsADeletedRowFromTheOpenPanel() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 47)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
            $0.date = .constant(Make.epoch) // soft delete stamps deletedAt/updatedAt
        } operation: {
            let (controller, _) = makeContext()
            defer { controller.hide() }
            controller.open()
            await controller.openTask?.value

            // Delete a row that is ON the visible page (History Manager / sync could do this).
            guard case let .clip(deletedID) = controller.model.historyRows[3].id else {
                Issue.record("history rows must be clip rows")
                return
            }
            _ = try ClipRepository().delete(id: deletedID, soft: true)

            controller.reconcileFromObservation()
            await controller.reconcileTask?.value
            #expect(controller.model.historyCount == 46)
            let stillListed = controller.model.historyRows.contains { $0.id == .clip(deletedID) }
            #expect(!stillListed)
            let selectionStillResolves = controller.model.selectedRow != nil
            #expect(selectionStillResolves)
        }
    }

    @Test func reconcileKeepsThePageAndSelectionWhileTheCountRebases() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 47)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
            $0.date = .constant(Make.epoch) // soft delete stamps deletedAt/updatedAt
        } operation: {
            let (controller, _) = makeContext()
            defer { controller.hide() }
            controller.open()
            await controller.openTask?.value
            controller.model.nextPage() // parks + fetches page 2
            await controller.pageTask?.value
            #expect(controller.model.currentPage == 1)
            let selectionBefore = controller.model.selection

            // Delete the OLDEST live row — far outside the loaded prefix, so the visible rows
            // are untouched; only the totals must re-base.
            let oldest = try ClipRepository().recentClips(limit: 1, ascending: true).first
            let oldestID = try #require(oldest?.id)
            _ = try ClipRepository().delete(id: oldestID, soft: true)

            controller.reconcileFromObservation()
            await controller.reconcileTask?.value
            #expect(controller.model.currentPage == 1)
            #expect(controller.model.historyCount == 46)
            let selectionSurvived = controller.model.selection == selectionBefore
            #expect(selectionSurvived)
        }
    }

    @Test func reconcileWhileNarrowingRestartsTheScan() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 47)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
            $0.date = .constant(Make.epoch) // soft delete stamps deletedAt/updatedAt
        } operation: {
            let (controller, _) = makeContext()
            defer { controller.hide() }
            controller.open()
            await controller.openTask?.value
            controller.model.searchText = "e" // narrows → the progressive scan serves it (P4)
            await controller.scanTask?.value
            #expect(!controller.model.isScanningHistory)

            guard case let .clip(deletedID) = controller.model.filteredRows[0].id else {
                Issue.record("scan matches must be clip rows")
                return
            }
            _ = try ClipRepository().delete(id: deletedID, soft: true)

            controller.reconcileFromObservation()
            // A narrowed prefix panel RE-SCANS (its matches need fresh window data); the
            // parallel prefix refresh must never commit over the scan's result set — the
            // matches stay scan-owned while the prefix re-bases underneath.
            let usedScan = controller.scanTask != nil
            #expect(usedScan)
            await controller.reconcileTask?.value
            await controller.scanTask?.value
            #expect(controller.model.historyCount == 46)
            let deletedStillListed = controller.model.filteredRows.contains { $0.id == .clip(deletedID) }
            #expect(!deletedStillListed)
        }
    }

    @Test func reconcileDuringTheFirstReadDefersUntilItsCommit() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 47)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
            $0.date = .constant(Make.epoch) // soft delete stamps deletedAt/updatedAt
        } operation: {
            let (controller, _) = makeContext()
            defer { controller.hide() }
            controller.open()
            // The observation fires while the first page is still in flight: nothing may race
            // the open — one deferred pass runs after its commit instead.
            controller.reconcileFromObservation()
            let racedTheOpen = controller.reconcileTask != nil
            #expect(!racedTheOpen)

            await controller.openTask?.value
            let deferredPassRan = controller.reconcileTask != nil
            #expect(deferredPassRan)
            await controller.reconcileTask?.value
            #expect(controller.model.historyCount == 47)
            let pageServed = controller.model.visibleRows.count == controller.model.itemsPerPage
            #expect(pageServed)
        }
    }

    @Test func aHiddenPanelIgnoresReconcileRequests() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 12)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
        } operation: {
            let (controller, _) = makeContext()
            controller.open()
            await controller.openTask?.value
            controller.hide()

            controller.reconcileFromObservation()
            let spawnedWork = controller.reconcileTask != nil || controller.scanTask != nil
            #expect(!spawnedWork)
        }
    }

    // MARK: - Review fixes (P3 adversarial review)

    @Test func aFailedReconcileReadNeverWipesTheOpenPanel() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 47)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
        } operation: {
            let (controller, _) = makeContext()
            defer { controller.hide() }
            controller.open()
            await controller.openTask?.value
            let servedRows = controller.model.historyRows.count
            #expect(servedRows == 10)

            // Kill the DB: every read from here on throws — the exact transient-failure shape
            // whose empty result must NOT be committed over live rows (review).
            try corpus.database.close()
            controller.reconcileFromObservation()
            await controller.reconcileTask?.value
            #expect(controller.model.historyRows.count == servedRows)
            #expect(controller.model.historyCount == 47)
            let selectionSurvived = controller.model.selectedRow != nil
            #expect(selectionSurvived)
        }
    }

    @Test func aFailedSilentRescanKeepsTheMatches() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 47)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
        } operation: {
            let (controller, _) = makeContext()
            defer { controller.hide() }
            controller.open()
            await controller.openTask?.value
            controller.model.searchText = "e"
            await controller.scanTask?.value
            let matchesBefore = controller.model.filteredRows.count
            #expect(matchesBefore > 0)

            try corpus.database.close()
            controller.reconcileFromObservation()
            await controller.scanTask?.value
            // The failed silent re-scan was discarded — the matches on screen stand.
            #expect(controller.model.filteredRows.count == matchesBefore)
            #expect(!controller.model.isScanningHistory)
        }
    }

    @Test func reconcileCompletesAParkedPageMove() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 47)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
        } operation: {
            let (controller, _) = makeContext()
            defer { controller.hide() }
            controller.open()
            await controller.openTask?.value

            // Park a page-forward move, then let a reconcile cancel the fetch serving it: the
            // user's keypress must survive the reconcile, not be swallowed (review).
            controller.model.nextPage()
            #expect(controller.model.currentPage == 0) // parked, not moved
            controller.reconcileFromObservation()
            await controller.reconcileTask?.value
            // The reconcile re-targeted the parked move; its own goToPage re-parked and
            // re-fired the fetch (the reconcile task no longer blocks it).
            await controller.pageTask?.value
            #expect(controller.model.currentPage == 1)
        }
    }

    @Test func lockPurgeDropsTheDecryptedRowsWithTheHide() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 12)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
        } operation: {
            let (controller, _) = makeContext()
            controller.open()
            await controller.openTask?.value
            #expect(!controller.model.historyRows.isEmpty)

            controller.purgeForScreenLock()
            #expect(!controller.isVisible)
            // D4: no decrypted display titles survive behind the lock — hide() alone would
            // keep the loaded window resident in the model.
            let rowsPurged = controller.model.historyRows.isEmpty
            #expect(rowsPurged)
            let selectionCleared = controller.model.selection == nil
            #expect(selectionCleared)
        }
    }

    @Test func snippetsScopeNarrowingPagesOverTheFilteredRows() {
        let model = HistoryPanelModel()
        let folder = SnippetFolder(id: UUID(), title: "folder", sortOrder: 0)
        var snippetRows: [PanelRow] = [.folderHeader(folder.id, title: folder.title)]
        for index in 0..<13 {
            snippetRows.append(.snippet(UUID(), title: index < 2 ? "match \(index)" : "other \(index)"))
        }
        let historyRows = (0..<25).map { PanelRow.clip(UUID(), title: "clip \($0)") }
        // A PREFIX window (windowComplete false) with the snippets scope narrowed: the page
        // count must come from the FILTERED snippet rows, not the scope's unfiltered total —
        // the phantom extra pages re-rendered the same rows and stomped the highlight (review).
        model.beginLoading(snippetRows: snippetRows, scope: .snippets)
        model.commitFirstPage(historyRows: historyRows, totalCount: 25, windowComplete: false)
        model.searchText = "match"
        #expect(model.filteredRows.count == 3) // 2 matches + their folder header (header-aware)
        #expect(model.pageCount == 1)
        model.nextPage()
        #expect(model.currentPage == 0)
    }

    @Test func reconcileUnderANarrowingAlsoRefreshesThePrefix() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 47)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
            $0.date = .constant(Make.epoch) // soft delete stamps deletedAt/updatedAt
        } operation: {
            let (controller, _) = makeContext()
            defer { controller.hide() }
            controller.open()
            await controller.openTask?.value
            controller.model.searchText = "e"
            await controller.scanTask?.value

            // Delete a row that sits in the LOADED PREFIX (not just the match set): clearing
            // the search must not resurface it (review — the P3 exit rule, regressed when the
            // whole-window swap was removed).
            guard case let .clip(deletedID) = controller.model.historyRows[0].id else {
                Issue.record("history rows must be clip rows")
                return
            }
            _ = try ClipRepository().delete(id: deletedID, soft: true)

            controller.reconcileFromObservation()
            await controller.reconcileTask?.value
            await controller.scanTask?.value
            let prefixStillHoldsDeleted = controller.model.historyRows.contains { $0.id == .clip(deletedID) }
            #expect(!prefixStillHoldsDeleted)

            controller.model.searchText = ""
            controller.model.searchTextDidChange()
            let listedAfterClearing = controller.model.filteredRows.contains { $0.id == .clip(deletedID) }
            #expect(!listedAfterClearing)
            #expect(controller.model.historyCount == 46)
        }
    }

    // MARK: - Model guard (defense in depth with the controller's ordering guards)

    @Test func reconcilePrefixIsIgnoredWhileAPrefixNarrowingIsActive() {
        let model = HistoryPanelModel()
        model.onNeedsWindowScan = { }
        model.beginLoading(snippetRows: [])
        let rows = (0..<10).map { PanelRow.clip(UUID(), title: "row \($0)") }
        model.commitFirstPage(historyRows: rows, totalCount: 40, windowComplete: false)
        model.searchText = "row"
        model.searchTextDidChange()

        // The scan owns a narrowed PREFIX window: a prefix commit without that context must
        // never replace it. (A narrowed COMPLETE window accepts the commit — the rows ARE the
        // whole window and the rebuild re-applies the narrowing in-memory; P4.)
        model.reconcilePrefix([], totalCount: 0, windowComplete: true)
        #expect(model.historyRows.count == 10)
        #expect(!model.historyWindowComplete)
    }
}
