//
//  HistoryPanelControllerTests.swift
//  ClipyTests
//
//  M-UI.11 P2: the controller's show-first pipeline end to end — shell up with the list
//  loading, the first keyset page committed off-main as one snapshot, hide() dropping a late
//  commit (generation guard), sequential paging fetching on demand, and search hydrating the
//  full capped window. Uses the real panel/model/service against a PerfFixture corpus; tests
//  await the exposed task handles (the PanelPreviewContentProvider.pendingLoad pattern), so
//  nothing here sleeps or polls. Count-shaped assertions (plan v2 §3.2).
//

import AppKit
import Foundation
import SQLiteData
import Testing

@testable import Clipy

@MainActor
@Suite struct HistoryPanelControllerTests {

    /// A controller wired to an isolated defaults suite (panel settings must not leak in from
    /// the machine) with a generous history cap so the fixtures below stay un-truncated.
    private func makeController() -> HistoryPanelController {
        let defaults = UserDefaults(suiteName: "HistoryPanelControllerTests-\(UUID().uuidString)")!
        DefaultsKeys.registerDefaults(in: defaults)
        defaults.set(100, forKey: DefaultsKeys.maxHistorySize)
        let coordinator = ClipSelectionCoordinator(model: MenuModel(settings: AppSettings(defaults: defaults)))
        return HistoryPanelController(coordinator: coordinator)
    }

    @Test func openShowsTheShellFirstThenCommitsOneKeysetPage() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 47)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
        } operation: {
            let controller = makeController()
            defer { controller.hide() }
            controller.open()
            // Shell state: panel is up, list is loading, nothing selectable or pasteable.
            // Count/Bool-shaped assertions: a failure must never dump rows (§3.2).
            #expect(controller.isVisible)
            #expect(controller.model.isLoadingFirstRows)
            let shellHasSelection = controller.model.selectedRow != nil
            #expect(!shellHasSelection)
            let shellDigitResolves = controller.model.row(forNumberKey: "1") != nil
            #expect(!shellDigitResolves)

            await controller.openTask?.value
            #expect(!controller.model.isLoadingFirstRows)
            #expect(controller.model.visibleRows.count == controller.model.itemsPerPage)
            #expect(controller.model.historyCount == 47)
            let committedSelection = controller.model.selectedRow != nil
            #expect(committedSelection)
        }
    }

    @Test func hideDropsTheLateFirstPageCommit() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 47)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
        } operation: {
            let controller = makeController()
            controller.open()
            let lateOpen = controller.openTask
            controller.hide()
            await lateOpen?.value
            // The generation guard dropped the commit: no rows appeared after the panel closed.
            #expect(controller.model.isLoadingFirstRows)
            let rowsStayedEmpty = controller.model.historyRows.isEmpty
            #expect(rowsStayedEmpty)
        }
    }

    @Test func hideDropsALatePageAppend() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 47)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
        } operation: {
            let controller = makeController()
            controller.open()
            await controller.openTask?.value
            let pageSize = controller.model.itemsPerPage

            controller.model.nextPage() // parks and starts the page fetch
            let latePage = controller.pageTask
            controller.hide()
            await latePage?.value
            // The generation guard dropped the append — no rows or page moves after close.
            #expect(controller.model.historyRows.count == pageSize)
            #expect(controller.model.currentPage == 0)
        }
    }

    @Test func hideDropsALateScan() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 47)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
        } operation: {
            let controller = makeController()
            controller.open()
            await controller.openTask?.value
            let pageSize = controller.model.itemsPerPage

            controller.model.searchText = "note"
            controller.model.searchTextDidChange() // the progressive scan starts
            let lateScan = controller.scanTask
            controller.hide()
            await lateScan?.value
            // The generation guard dropped every update — prefix untouched, nothing committed.
            #expect(controller.model.historyRows.count == pageSize)
            #expect(!controller.model.historyWindowComplete)
            let matchesCommitted = !controller.model.scanMatches.isEmpty
            #expect(!matchesCommitted)
        }
    }

    @Test func sequentialPagingFetchesOnDemand() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 47)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
        } operation: {
            let controller = makeController()
            defer { controller.hide() }
            controller.open()
            await controller.openTask?.value
            let pageSize = controller.model.itemsPerPage
            #expect(controller.model.historyRows.count == pageSize)

            controller.model.nextPage()
            // The park fired the controller's fetch synchronously; await its commit.
            await controller.pageTask?.value
            #expect(controller.model.currentPage == 1)
            #expect(controller.model.historyRows.count == 2 * pageSize)
            let ghostRows = controller.model.historyRows.count(where: \.decryptFailed)
            #expect(ghostRows == 0)
        }
    }

    @Test func searchScansProgressivelyAndKeepsTheQuery() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 47)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
        } operation: {
            let controller = makeController()
            defer { controller.hide() }
            controller.open()
            await controller.openTask?.value

            controller.model.searchText = "note"
            controller.model.searchTextDidChange()
            #expect(controller.model.isScanningHistory)
            await controller.scanTask?.value
            #expect(!controller.model.isScanningHistory)
            // P4: the scan serves the matches BESIDE the prefix — the window is never
            // materialized wholesale, and the loaded prefix survives for when the search clears.
            #expect(controller.model.historyRows.count == controller.model.itemsPerPage)
            #expect(!controller.model.historyWindowComplete)
            #expect(controller.model.searchText == "note")
            let searchHasMatches = !controller.model.filteredRows.isEmpty
            #expect(searchHasMatches)
        }
    }

    @Test func aReopenedPanelNeverServesThePreviousOpensScan() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 47)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
        } operation: {
            let controller = makeController()
            defer { controller.hide() }
            controller.open()
            await controller.openTask?.value
            controller.model.searchText = "note"
            controller.model.searchTextDidChange()
            await controller.scanTask?.value
            let firstOpenMatches = controller.model.filteredRows.count
            #expect(firstOpenMatches > 0)
            controller.hide()

            // Re-open and retype the SAME query: the previous open's stamp and request record
            // must not present its stale matches as settled, nor suppress the fresh scan
            // (review: both survived a hide before this fix).
            controller.open()
            await controller.openTask?.value
            controller.model.searchText = "note"
            controller.model.searchTextDidChange()
            let freshScanStarted = controller.scanTask != nil
            #expect(freshScanStarted)
            await controller.scanTask?.value
            #expect(!controller.model.isScanningHistory)
            #expect(controller.model.filteredRows.count == firstOpenMatches)
        }
    }

    @Test func aWhitespaceQueryEditNeverRestartsASettledScan() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 47)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
        } operation: {
            let controller = makeController()
            defer { controller.hide() }
            controller.open()
            await controller.openTask?.value
            controller.model.searchText = "note"
            controller.model.searchTextDidChange()
            await controller.scanTask?.value
            #expect(!controller.model.isScanningHistory)

            // "note " normalizes to "note": the settled result set stands — no new walk, no
            // flicker back into the scanning presentation (review).
            controller.model.searchText = "note "
            controller.model.searchTextDidChange()
            let restarted = controller.scanTask != nil || controller.scanDebounceTask != nil
            #expect(!restarted)
            #expect(!controller.model.isScanningHistory)
        }
    }
}
