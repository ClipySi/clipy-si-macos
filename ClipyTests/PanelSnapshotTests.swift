//
//  PanelSnapshotTests.swift
//  ClipyTests
//
//  M-UI.11 P1: the panel model's stored-snapshot contract (one input change ⇒ one filtered-tier
//  rebuild; page moves stay O(page)), lazy code classification through the version-aware
//  PanelClassificationCache, the once-per-request mask-policy resolution, and the maxHistorySize
//  read-side clamp.
//

import AppKit
import CryptoKit
import Foundation
import SQLiteData
import Testing
@testable import Clipy

@MainActor @Suite struct PanelSnapshotTests {
    /// Classifies as Swift (≥2 signature keywords + braces/indent/call-shaped structure).
    private static let swiftSnippet = """
    func load(_ id: Int) -> Row? {
        guard let row = cache[id] else { return nil }
        let value = transform(row)
        return value
    }
    """

    /// A clip row the way the coordinator now builds them: text kind, classification deferred.
    private func lazyClipRow(_ title: String, id: UUID = UUID()) -> PanelRow {
        var row = PanelRow.clip(id, title: title)
        row.updatedAt = Date(timeIntervalSince1970: 1_000)
        row.needsCodeClassification = true
        return row
    }

    // MARK: - Snapshot rebuild contract

    @Test func oneFilteredRebuildPerInputChange() {
        let model = HistoryPanelModel()
        let base = model.filteredRebuildCount
        model.reset(historyRows: [lazyClipRow("alpha"), lazyClipRow("beta")], snippetRows: [])
        #expect(model.filteredRebuildCount == base + 1, "reset batches its field mutations into ONE rebuild")
        model.searchText = "a"
        #expect(model.filteredRebuildCount == base + 2)
        model.searchText = "a" // same value — didSet fires, the equality guard must swallow it
        #expect(model.filteredRebuildCount == base + 2)
        model.searchTextDidChange() // page/selection re-base only — the query didSet already rebuilt
        #expect(model.filteredRebuildCount == base + 2)
        model.setScope(.history)
        #expect(model.filteredRebuildCount == base + 3)
        model.setCategory(.links)
        #expect(model.filteredRebuildCount == base + 4)
        model.goToPage(0) // page tier only
        #expect(model.filteredRebuildCount == base + 4)
        model.nextPage() // page tier only
        #expect(model.filteredRebuildCount == base + 4)
    }

    @Test func numberMapsAndPagingComeFromTheSnapshot() {
        let model = HistoryPanelModel()
        model.itemsPerPage = 10
        model.reset(historyRows: (0..<3).map { lazyClipRow("row \($0)") }, snippetRows: [])
        #expect(model.pageCount == 1)
        #expect(model.displayNumber(for: model.visibleRows[0]) == 1)
        #expect(model.displayNumber(for: model.visibleRows[2]) == 3)
        #expect(model.row(forNumberKey: "2")?.id == model.visibleRows[1].id)
        #expect(model.row(forNumberKey: "9") == nil)
        model.markedWithNumbers = false
        #expect(model.displayNumber(for: model.visibleRows[0]) == nil, "numbering off hides numbers")
        #expect(model.row(forNumberKey: "1")?.id == model.visibleRows[0].id, "number keys still paste")
    }

    // MARK: - Lazy classification

    @Test func visiblePageIsClassifiedLazilyAndInputsStayRaw() {
        let model = HistoryPanelModel()
        model.itemsPerPage = 5
        model.reset(historyRows: [lazyClipRow(Self.swiftSnippet), lazyClipRow("plain note text")],
                    snippetRows: [])
        #expect(model.visibleRows.first?.contentKind == .code)
        #expect(model.visibleRows.first?.codeLanguage == "Swift")
        #expect(model.visibleRows.first?.needsCodeClassification == false)
        #expect(model.visibleRows.last?.contentKind == .text)
        // The stored input keeps its unresolved shape — verdicts live in the snapshot + cache.
        let inputsStayRaw = model.historyRows.allSatisfy(\.needsCodeClassification)
        #expect(inputsStayRaw)
    }

    @Test func offPageRowsClassifyOnlyWhenCountsNeedThem() {
        let model = HistoryPanelModel()
        model.itemsPerPage = 5
        model.reset(historyRows: (0..<12).map { lazyClipRow("plain note \($0)") }, snippetRows: [])
        #expect(model.classificationCache.stats.misses == 5, "only the visible page classifies at open")
        model.isFilterBarOpen = true // chips need exact counts → the remaining rows resolve now
        #expect(model.classificationCache.stats.misses == 12)
    }

    @Test func repeatOpensServeClassificationFromTheCache() {
        let model = HistoryPanelModel()
        let rows = [lazyClipRow(Self.swiftSnippet), lazyClipRow("plain note")]
        model.reset(historyRows: rows, snippetRows: [])
        let missesAfterFirstOpen = model.classificationCache.stats.misses
        #expect(missesAfterFirstOpen == 2)
        model.reset(historyRows: rows, snippetRows: [])
        #expect(model.classificationCache.stats.misses == missesAfterFirstOpen,
                "an unchanged row re-opens without re-running the classifier")
        #expect(model.classificationCache.stats.hits == 2)
        // The HIT path must re-apply the verdict, not just skip the classifier.
        #expect(model.visibleRows.first?.contentKind == .code)
        #expect(model.visibleRows.first?.codeLanguage == "Swift")
    }

    @Test func titleDependentCategoryResolvesBeyondTheVisiblePage() {
        // The only .code row sits PAST page 1 — filtering by .code must classify the whole scope
        // (through the cache), not just the visible slice, or the row would never match.
        let model = HistoryPanelModel()
        model.itemsPerPage = 5
        var rows = (0..<11).map { lazyClipRow("plain note \($0)") }
        rows.append(lazyClipRow(Self.swiftSnippet))
        model.reset(historyRows: rows, snippetRows: [])
        model.setCategory(.code)
        #expect(model.filteredRows.count == 1)
        #expect(model.filteredRows.first?.contentKind == .code)
        model.setCategory(.text)
        #expect(model.filteredRows.count == 11, ".text must exclude the code row, not lazily include it")
    }

    @Test func atomicPolicySwapNeverServesVerdictsAcrossPolicies() {
        // Regression (review, P1): the same row id/updatedAt re-opened under a DIFFERENT policy —
        // e.g. masking turned ON between opens, so the title the classifier saw changed from raw
        // code to bullets — must re-classify, not hit the old policy's cached verdict.
        let model = HistoryPanelModel()
        let policyOff = DisplayPolicy(maskEnabled: false, maskStyleRaw: "full",
                                      classifierAlgorithmVersion: CodeClassifier.algorithmVersion)
        let policyOn = DisplayPolicy(maskEnabled: true, maskStyleRaw: "full",
                                     classifierAlgorithmVersion: CodeClassifier.algorithmVersion)
        let id = UUID()
        var raw = PanelRow.clip(id, title: Self.swiftSnippet)
        raw.updatedAt = Date(timeIntervalSince1970: 1_000)
        raw.needsCodeClassification = true
        model.reset(historyRows: [raw], snippetRows: [], policy: policyOff)
        #expect(model.visibleRows.first?.contentKind == .code)

        var masked = PanelRow.clip(id, title: "●●●●●●●●●●●●")
        masked.updatedAt = Date(timeIntervalSince1970: 1_000)
        masked.needsCodeClassification = true
        model.reset(historyRows: [masked], snippetRows: [], policy: policyOn)
        #expect(model.visibleRows.first?.contentKind == .text,
                "the raw-title verdict must not leak into the masked re-open")
    }

    @Test func snapshotRebuildIsObservable() {
        // The view's body reads the forwarders; a rebuild must invalidate that observation or the
        // panel would render a stale list until some other state poked it.
        final class Flag: @unchecked Sendable { var value = false }

        let model = HistoryPanelModel()
        model.reset(historyRows: [lazyClipRow("alpha"), lazyClipRow("beta")], snippetRows: [])
        let fired = Flag() // onChange is @Sendable; it fires synchronously on this actor's willSet
        withObservationTracking {
            _ = model.visibleRows
        } onChange: {
            fired.value = true
        }
        model.searchText = "a"
        #expect(fired.value, "reading visibleRows must be invalidated by the snapshot rebuild")
    }

    @Test func coordinatorBuildsRowsLazilyAtTheProductionBoundary() throws {
        // The lazy contract starts in ClipSelectionCoordinator.historyRows: text candidates arrive
        // UNclassified and flagged; non-text rows arrive with their metadata kind and no flag.
        let key = SymmetricKey(data: Data(repeating: 0x6F, count: 32))
        let cipher = HistoryCipher(key: key)
        let database = try TestDatabase.make()
        try withDependencies {
            $0.defaultDatabase = database
            $0.historyCipher = cipher
            $0.maskingService = .identity
        } operation: {
            let repo = ClipRepository()
            var code = Make.clip(createdAt: Make.epoch.addingTimeInterval(1))
            code.titleCipher = try cipher.seal(Data(Self.swiftSnippet.utf8))
            try repo.add(code)
            var image = Make.clip(createdAt: Make.epoch)
            image.titleCipher = try cipher.seal(Data("ignored".utf8))
            image.primaryType = NSPasteboard.PasteboardType.tiff.rawValue
            try repo.add(image)

            let rows = MainActor.assumeIsolated {
                ClipSelectionCoordinator().historyRows(
                    policy: DisplayPolicy(maskEnabled: false, maskStyleRaw: "full",
                                          classifierAlgorithmVersion: CodeClassifier.algorithmVersion))
            }
            #expect(rows.count == 2)
            #expect(rows[0].contentKind == .text, "code detection is deferred, not run at build")
            #expect(rows[0].needsCodeClassification)
            #expect(rows[0].codeLanguage == nil)
            #expect(rows[1].contentKind == .image)
            #expect(rows[1].needsCodeClassification == false, "non-text rows never classify")
        }
    }

    @Test func categoryCountsClassifyOnDemandForOffScreenCallers() {
        let model = HistoryPanelModel()
        model.reset(historyRows: [lazyClipRow(Self.swiftSnippet), lazyClipRow("plain note")],
                    snippetRows: [])
        // Chips closed — the forwarder still answers with classified counts (pre-P1 semantics).
        #expect(model.categoryCounts[.code] == 1)
        #expect(model.categoryCounts[.text] == 1)
        #expect(model.categoryCounts[.all] == 2)
    }

    @Test func policyOrRowChangeNeverServesStaleVerdicts() {
        let cache = PanelClassificationCache()
        var row = PanelRow.clip(UUID(), title: "plain note")
        row.updatedAt = Date(timeIntervalSince1970: 1_000)
        row.needsCodeClassification = true
        let versionOne = DisplayPolicy(maskEnabled: true, maskStyleRaw: "full", classifierAlgorithmVersion: 1)
        let versionTwo = DisplayPolicy(maskEnabled: true, maskStyleRaw: "full", classifierAlgorithmVersion: 2)

        _ = cache.resolve([row], policy: versionOne)
        #expect(cache.stats == PanelClassificationCache.Stats(hits: 0, misses: 1))
        _ = cache.resolve([row], policy: versionOne)
        #expect(cache.stats == PanelClassificationCache.Stats(hits: 1, misses: 1))
        // A classifier bump makes every old verdict unreachable — no stale hit.
        _ = cache.resolve([row], policy: versionTwo)
        #expect(cache.stats == PanelClassificationCache.Stats(hits: 1, misses: 2))
        // So does a mask-policy change (the masked title the verdict was computed over changed) …
        let masked = DisplayPolicy(maskEnabled: false, maskStyleRaw: "full", classifierAlgorithmVersion: 1)
        _ = cache.resolve([row], policy: masked)
        #expect(cache.stats == PanelClassificationCache.Stats(hits: 1, misses: 3))
        // … and a row mutation (updatedAt bump — dedupe/paste/sync all move it).
        var moved = row
        moved.updatedAt = Date(timeIntervalSince1970: 2_000)
        _ = cache.resolve([moved], policy: versionOne)
        #expect(cache.stats == PanelClassificationCache.Stats(hits: 1, misses: 4))
    }

    // MARK: - Once-per-request mask policy

    @Test func maskPolicyIsResolvedOncePerHistoryRequest() throws {
        final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            private var policies: [DisplayPolicy] = []
            var received: [DisplayPolicy] { lock.withLock { policies } }

            func record(_ policy: DisplayPolicy) { lock.withLock { policies.append(policy) } }
        }

        let recorder = Recorder()
        let key = SymmetricKey(data: Data(repeating: 0x6E, count: 32))
        let cipher = HistoryCipher(key: key)
        let database = try TestDatabase.make()
        // Isolated suite defaults — MenuModel must not couple this test to whatever the host
        // app's standard defaults happen to hold (sort direction, history cap).
        let suite = "PanelSnapshotTests.maskOnce"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(30, forKey: DefaultsKeys.maxHistorySize)
        defaults.set(true, forKey: DefaultsKeys.historySortNewestFirst)

        try withDependencies {
            $0.defaultDatabase = database
            $0.historyCipher = cipher
            $0.maskingService = MaskingService(
                evaluate: { MaskingResult(isSecret: false, display: $0) },
                makeEvaluator: { policy in
                    recorder.record(policy)
                    return { MaskingResult(isSecret: false, display: $0) }
                })
        } operation: {
            let repo = ClipRepository()
            for index in 0..<5 {
                var clip = Make.clip(createdAt: Make.epoch.addingTimeInterval(Double(index)))
                clip.titleCipher = try cipher.seal(Data("row \(index)".utf8))
                try repo.add(clip)
            }
            let policy = DisplayPolicy(maskEnabled: true, maskStyleRaw: "prefix2",
                                       classifierAlgorithmVersion: CodeClassifier.algorithmVersion)
            let displays = MenuModel(settings: AppSettings(defaults: defaults)).history(policy: policy)
            #expect(displays.count == 5)
            #expect(displays.allSatisfy { !$0.decryptFailed })
            #expect(recorder.received == [policy],
                    "exactly ONE resolution, of exactly the request's policy — not one per row")
        }
    }

    // MARK: - maxHistorySize read-side clamp

    @Test func maxHistorySizeIsClampedOnRead() throws {
        let suite = "PanelSnapshotTests.maxHistorySize"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)

        defaults.set(0, forKey: DefaultsKeys.maxHistorySize)
        #expect(settings.maxHistorySize == SettingsMapping.minHistorySize)
        defaults.set(-5, forKey: DefaultsKeys.maxHistorySize)
        #expect(settings.maxHistorySize == SettingsMapping.minHistorySize)
        defaults.set(999_999_999, forKey: DefaultsKeys.maxHistorySize)
        #expect(settings.maxHistorySize == SettingsMapping.maxHistorySize)
        defaults.set(30, forKey: DefaultsKeys.maxHistorySize)
        #expect(settings.maxHistorySize == 30)
    }
}
