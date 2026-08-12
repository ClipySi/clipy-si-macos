//
//  HistoryWarmCacheTests.swift
//  ClipyTests
//
//  M-UI.11 P3: the warm-open store's contracts — signature-exact matching (any change to page
//  size, cap, sort, or display policy is a cold open), the row/byte bounds with cursor
//  re-derivation on truncation, and the resident head observer keeping the cache current:
//  prewarm on start, refresh + panel ping on every write, restart on a settings change, and
//  the screen-lock purge/stop/unlock-rebuild cycle (D4). Count/Bool-shaped assertions only
//  (plan v2 §3.2).
//

import Foundation
import SQLiteData
import Testing

@testable import Clipy

@MainActor
@Suite struct HistoryWarmCacheTests {

    private func makeRequest(pageSize: Int = 10, limit: Int = 100, ascending: Bool = false,
                             maskEnabled: Bool = false) -> HistoryReadService.PageRequest {
        HistoryReadService.PageRequest(
            pageSize: pageSize,
            historyLimit: limit,
            ascending: ascending,
            policy: DisplayPolicy(maskEnabled: maskEnabled, maskStyleRaw: "full",
                                  classifierAlgorithmVersion: CodeClassifier.algorithmVersion))
    }

    private func makeRows(_ count: Int, titleLength: Int = 10) -> [PanelRow] {
        (0..<count).map { index in
            PanelRow.clip(UUID(), title: String(repeating: "x", count: titleLength),
                          createdAt: Date(timeIntervalSince1970: TimeInterval(1_000 + index)))
        }
    }

    private func makeSnapshot(rows: [PanelRow], totalCount: Int? = nil,
                              request: HistoryReadService.PageRequest) -> HistoryWarmCache.Snapshot {
        HistoryWarmCache.Snapshot(rows: rows, nextCursor: nil,
                                  totalCount: totalCount ?? rows.count, request: request)
    }

    // MARK: - Signature matching (§4.4 invalidation)

    @Test func snapshotMatchesOnlyItsOwnSignature() {
        let cache = HistoryWarmCache()
        let request = makeRequest()
        cache.store(makeSnapshot(rows: makeRows(5), request: request))

        let hit = cache.snapshot(matching: request) != nil
        #expect(hit)
        // Every contract field is part of the signature: a different page size, cap, sort
        // direction, or mask policy must be a cold open, never a served-by-luck hit.
        let pageSizeMiss = cache.snapshot(matching: makeRequest(pageSize: 20)) == nil
        #expect(pageSizeMiss)
        let limitMiss = cache.snapshot(matching: makeRequest(limit: 50)) == nil
        #expect(limitMiss)
        let sortMiss = cache.snapshot(matching: makeRequest(ascending: true)) == nil
        #expect(sortMiss)
        let policyMiss = cache.snapshot(matching: makeRequest(maskEnabled: true)) == nil
        #expect(policyMiss)
    }

    @Test func purgeDropsTheSnapshot() {
        let cache = HistoryWarmCache()
        let request = makeRequest()
        cache.store(makeSnapshot(rows: makeRows(5), request: request))
        cache.purge()
        let missAfterPurge = cache.snapshot(matching: request) == nil
        #expect(missAfterPurge)
    }

    // MARK: - Bounds (§4.4 sizing, D2)

    @Test func rowCapTracksThreePagesUpToTheHardCeiling() {
        #expect(HistoryWarmCache.rowCap(pageSize: 5) == 15)
        #expect(HistoryWarmCache.rowCap(pageSize: 10) == 30)
        // 3 × 20 would already exceed the 63-row ceiling.
        #expect(HistoryWarmCache.rowCap(pageSize: 20) == 60)
        #expect(HistoryWarmCache.rowCap(pageSize: 25) == 63)
    }

    @Test func storeEnforcesTheRowCapAndRederivesTheCursor() {
        let cache = HistoryWarmCache()
        let request = makeRequest(pageSize: 10) // row cap 30
        cache.store(makeSnapshot(rows: makeRows(40), totalCount: 90, request: request))

        let stored = cache.snapshot(matching: request)
        #expect(stored?.rows.count == 30)
        // Truncation makes the window a strict prefix: the continuation cursor must move back
        // to the last KEPT row so a warm open pages on without a gap.
        let cursorMatchesLastKeptRow = stored?.nextCursor?.createdAt
            == Date(timeIntervalSince1970: 1_000 + 29)
        #expect(cursorMatchesLastKeptRow)
        #expect(stored?.totalCount == 90)
        let completeAfterTruncation = stored?.windowComplete ?? true
        #expect(!completeAfterTruncation)
    }

    @Test func storeEnforcesTheByteCap() {
        let cache = HistoryWarmCache()
        let request = makeRequest(pageSize: 20) // row cap 60
        // 60 rows × ~100 KB ≈ 6 MB — crosses the 4 MiB ceiling inside the row cap.
        cache.store(makeSnapshot(rows: makeRows(60, titleLength: 100_000), request: request))

        let stored = cache.snapshot(matching: request)
        let kept = stored?.rows.count ?? 0
        #expect(kept > 0)
        #expect(kept < 60)
        let bytesUnderCap = (stored?.rows ?? []).reduce(0) { $0 + $1.title.utf8.count + 64 }
            <= HistoryWarmCache.byteCap
        #expect(bytesUnderCap)
        let truncationKeepsACursor = stored?.nextCursor != nil
        #expect(truncationKeepsACursor)
    }

    @Test func aTruncationBelowOnePageIsNotServed() {
        let cache = HistoryWarmCache()
        let request = makeRequest(pageSize: 20) // row cap 60
        // ~300 KB per title (the capture cap is 10,000 CHARACTERS, so grapheme-heavy text can
        // reach this): the byte cap keeps fewer rows than one page. Committing that as page 0
        // of an incomplete window would seat snippet rows in history slots (§5.3 seam) — the
        // snapshot must be dropped, not served short.
        cache.store(makeSnapshot(rows: makeRows(60, titleLength: 300_000), request: request))
        let servedShort = cache.snapshot(matching: request) != nil
        #expect(!servedShort)
    }

    @Test func withinBoundsSnapshotsAreStoredVerbatim() {
        let cache = HistoryWarmCache()
        let request = makeRequest(pageSize: 10)
        let cursor = ClipPageCursor(createdAt: Date(timeIntervalSince1970: 999), id: UUID())
        cache.store(HistoryWarmCache.Snapshot(rows: makeRows(30), nextCursor: cursor,
                                              totalCount: 90, request: request))
        let stored = cache.snapshot(matching: request)
        #expect(stored?.rows.count == 30)
        let cursorUntouched = stored?.nextCursor == cursor
        #expect(cursorUntouched)
    }

    // MARK: - Head observer (prewarm, refresh, invalidation, lock)

    private func makeSettings(maxHistory: Int = 100) -> AppSettings {
        let defaults = UserDefaults(suiteName: "HistoryWarmCacheTests-\(UUID().uuidString)")!
        DefaultsKeys.registerDefaults(in: defaults)
        defaults.set(maxHistory, forKey: DefaultsKeys.maxHistorySize)
        return AppSettings(defaults: defaults)
    }

    private func makeObserver(cache: HistoryWarmCache, settings: AppSettings) -> HistoryHeadObserver {
        HistoryHeadObserver(cache: cache, readService: HistoryReadService(), settings: settings)
    }

    /// Await the observer's NEXT head-changed ping (one-shot rebind — no sleeping, no polling).
    /// Sound because everything here is MainActor-serial: the ping is delivered only while this
    /// test awaits, so a fire can never slip in between the trigger and this wait.
    private func nextFire(of observer: HistoryHeadObserver) async {
        await withCheckedContinuation { continuation in
            observer.onHeadChanged = {
                observer.onHeadChanged = nil
                continuation.resume()
            }
        }
    }

    @Test func startPrewarmsTheCacheFromTheObservationsFirstYield() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 47)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
        } operation: {
            let cache = HistoryWarmCache()
            let settings = makeSettings()
            let observer = makeObserver(cache: cache, settings: settings)
            defer { observer.stop() }
            observer.start()
            await nextFire(of: observer)

            let request = HistoryReadService.PageRequest.current(settings: settings)
            let stored = cache.snapshot(matching: request)
            // Prewarmed to the full resident-head size (3 pages), not just page one.
            #expect(stored?.rows.count == HistoryWarmCache.rowCap(pageSize: request.pageSize))
            #expect(stored?.totalCount == 47)
            let hasContinuation = stored?.nextCursor != nil
            #expect(hasContinuation)
        }
    }

    @Test func aWriteRefreshesTheCacheAndPingsThePanel() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 12)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
        } operation: {
            let cache = HistoryWarmCache()
            let settings = makeSettings()
            let observer = makeObserver(cache: cache, settings: settings)
            defer { observer.stop() }
            observer.start()
            await nextFire(of: observer)

            var clip = Make.clip(title: "fresh capture", contentHash: "warm-write-1")
            clip.titleCipher = try PerfFixture.cipher.seal(Data("fresh capture".utf8))
            try ClipRepository().add(clip)
            await nextFire(of: observer)

            let request = HistoryReadService.PageRequest.current(settings: settings)
            #expect(cache.snapshot(matching: request)?.totalCount == 13)
        }
    }

    @Test func aSettingsChangeRestartsUnderTheNewSignature() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 47)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
        } operation: {
            let cache = HistoryWarmCache()
            let settings = makeSettings()
            let observer = makeObserver(cache: cache, settings: settings)
            defer { observer.stop() }
            observer.start()
            await nextFire(of: observer)

            settings.defaults.set(20, forKey: DefaultsKeys.historyPanelItemsPerPage)
            observer.refresh()
            await nextFire(of: observer)

            let newRequest = HistoryReadService.PageRequest.current(settings: settings)
            #expect(newRequest.pageSize == 20)
            let rebuiltUnderNewSignature = cache.snapshot(matching: newRequest) != nil
            #expect(rebuiltUnderNewSignature)
            // An unchanged-signature refresh is a no-op (UserDefaults fires for unrelated keys).
            let requestBeforeNoOp = cache.snapshot(matching: newRequest)?.request
            observer.refresh()
            let unchanged = cache.snapshot(matching: newRequest)?.request == requestBeforeNoOp
            #expect(unchanged)
        }
    }

    @Test func screenLockPurgesAndUnlockRebuilds() async throws {
        let corpus = try PerfFixture.makeCorpus(liveCount: 12)
        try await withDependencies {
            $0.defaultDatabase = corpus.database
            $0.historyCipher = PerfFixture.cipher
            $0.maskingService = .identity
        } operation: {
            let cache = HistoryWarmCache()
            let settings = makeSettings()
            let observer = makeObserver(cache: cache, settings: settings)
            defer { observer.stop() }
            var lockFired = false
            observer.onScreenLock = { lockFired = true }
            observer.start()
            await nextFire(of: observer)
            let request = HistoryReadService.PageRequest.current(settings: settings)

            observer.handleScreenLock()
            #expect(lockFired)
            let purgedOnLock = cache.snapshot(matching: request) == nil
            #expect(purgedOnLock)

            // A write behind the lock must NOT rebuild display plaintext: the loop is retired.
            var clip = Make.clip(title: "locked-out capture", contentHash: "warm-lock-1")
            clip.titleCipher = try PerfFixture.cipher.seal(Data("locked-out capture".utf8))
            try ClipRepository().add(clip)
            for _ in 0..<20 { await Task.yield() }
            let stillPurgedBehindLock = cache.snapshot(matching: request) == nil
            #expect(stillPurgedBehindLock)

            observer.handleScreenUnlock()
            await nextFire(of: observer)
            // Rebuilt from scratch — including the write that happened behind the lock.
            #expect(cache.snapshot(matching: request)?.totalCount == 13)
        }
    }
}
