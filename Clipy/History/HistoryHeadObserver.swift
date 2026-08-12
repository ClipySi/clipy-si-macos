//
//  HistoryHeadObserver.swift
//  ClipySi — Apple Silicon rewrite
//
//  M-UI.11 P3: the resident watcher that keeps `HistoryWarmCache` current. A GRDB
//  `ValueObservation` (started/cancelled from a non-View context — the P2 §4.3 PoC) tracks the
//  live history's HEAD (count + first raw rows in page order); every SQLite commit that changes
//  it re-fires, covering the mutation paths at the storage layer with no per-call-site change
//  hints to scatter or forget (the plan's §4.5 concern; recorded as a P3 adaptation of §5.5's
//  HistoryChangeHint). Coverage boundary: the observed value is COUNT + the head rows, so any
//  insert/delete/clear/trim/move-into-head fires, but an IN-PLACE edit of a row beyond the
//  observed head (pin, sensitivity backfill, ascending-sort move-to-top) does not — a deep
//  loaded prefix keeps that one row's stale slot until the next open, the same bounded
//  staleness P2 §9.2 already accepts for mid-walk moves. `removeDuplicates()` keeps unrelated
//  commits quiet, and the AsyncSequence conflates while a rebuild is in flight (§10
//  observation-storm guard).
//
//  Each fire hands the RAW fetched rows to `HistoryReadService` (decrypt + mask on the actor's
//  executor — never on the observation's reader or the MainActor), stores the display-ready
//  snapshot, and pings the panel so an OPEN panel reconciles too. The observation's first yield
//  doubles as the launch prewarm (§4.4).
//
//  Invalidation (§4.4): the observed query and the snapshot signature derive from the SAME
//  settings read (`PageRequest.current`); any settings change re-resolves it and restarts the
//  observation. Screen lock cancels + purges (D4) — with masking OFF the cached titles equal
//  raw plaintext, so nothing display-ready may survive a lock; unlock restarts from scratch.
//

import AppKit
import GRDB // explicit product link (M-UI.11 P3): ValueObservation is not re-exported by SQLiteData
import OSLog
import SQLiteData // re-exports swift-dependencies

@MainActor
final class HistoryHeadObserver: NSObject {
    private let cache: HistoryWarmCache
    private let readService: HistoryReadService
    /// The settings source the observed signature resolves from — injectable so tests pin the
    /// signature against an isolated defaults suite (production: the standard defaults).
    private let settings: AppSettings
    @Dependency(\.defaultDatabase) private var database

    /// The in-flight observation loop; replaced whole on any signature change (no partial
    /// reconfiguration — a stale loop must never write under a new signature).
    private var task: Task<Void, Never>?
    /// The settings signature the current loop observes under. A store is valid only while
    /// this still matches (the loop re-checks after every actor hop).
    private var activeRequest: HistoryReadService.PageRequest?
    /// True between screen lock and unlock: nothing display-ready may be rebuilt while the
    /// screen is locked, even though capture keeps writing.
    private var isScreenLocked = false

    /// Fired after every warm-cache refresh — the panel controller reconciles an OPEN panel
    /// against the new head (plan v2 §5.5).
    var onHeadChanged: (() -> Void)?
    /// Fired on screen lock, after the purge — the delegate hides the panel (nothing decrypted
    /// stays on screen behind the lock).
    var onScreenLock: (() -> Void)?

    private static let log = Logger(subsystem: "io.github.ponponusa.clipysi", category: "history-head")

    init(cache: HistoryWarmCache, readService: HistoryReadService,
         settings: AppSettings = AppSettings()) {
        self.cache = cache
        self.readService = readService
        self.settings = settings
    }

    /// Begin observing: subscribe to the invalidation triggers and start the loop (its first
    /// yield is the launch prewarm).
    func start() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(defaultsDidChange),
            name: UserDefaults.didChangeNotification, object: nil)
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(screenDidLock),
                                name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        distributed.addObserver(self, selector: #selector(screenDidUnlock),
                                name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        restart()
    }

    /// Re-resolve the settings signature; restart the observation only when it actually
    /// changed (UserDefaults.didChangeNotification fires for unrelated writes too).
    func refresh() {
        guard !isScreenLocked else { return }
        guard activeRequest != .current(settings: settings) else { return }
        restart()
    }

    /// Cancel the loop and forget the signature (tests; the app never stops observing). The
    /// notification subscriptions stay — a later `restart` picks them back up unchanged.
    func stop() {
        task?.cancel()
        task = nil
        activeRequest = nil
    }

    /// Purge + stop on lock (D4): the cache holds display plaintext, so it must not survive —
    /// or be rebuilt behind — a locked screen. Internal so tests can drive the transition.
    func handleScreenLock() {
        isScreenLocked = true
        task?.cancel()
        task = nil
        activeRequest = nil
        cache.purge()
        onScreenLock?()
    }

    /// Restart from scratch on unlock — the observation's initial yield rebuilds the warm
    /// cache without waiting for the next write.
    func handleScreenUnlock() {
        isScreenLocked = false
        restart()
    }

    private func restart() {
        task?.cancel()
        // The old snapshot might have been built under a signature that no longer matches
        // anything (e.g. a mask-style change) — drop it now rather than serve-by-luck later.
        cache.purge()
        let request = HistoryReadService.PageRequest.current(settings: settings)
        activeRequest = request
        let rowCap = HistoryWarmCache.rowCap(pageSize: request.pageSize)
        let database = database
        let readService = readService
        task = Task { [weak self] in
            // The observed fetch and the panel's reads share one query shape (ClipRepository).
            // +1 row: the has-more sentinel, fetched raw but never decrypted.
            let observation = ValueObservation
                .tracking { db in
                    try ClipRepository.headState(db, limit: rowCap + 1, ascending: request.ascending)
                }
                .removeDuplicates()
            do {
                for try await head in observation.values(in: database) {
                    guard !Task.isCancelled else { return }
                    let result = await readService.warmRows(from: head, request, rowCap: rowCap)
                    // Re-validate after the actor hop: a settings change or lock may have
                    // retired this loop while the rows were being built.
                    guard let self, !Task.isCancelled, self.activeRequest == request else { return }
                    self.cache.store(HistoryWarmCache.Snapshot(
                        rows: result.rows,
                        nextCursor: result.nextCursor,
                        totalCount: result.totalCount,
                        request: request))
                    self.onHeadChanged?()
                }
            } catch {
                // A dead observation can't keep the cache honest — purge so opens fall back to
                // the cold path (which reads the DB directly and stays correct). But dying for
                // good would also end open-panel reconciliation for the whole session (P3
                // review: a deleted row would stay pasteable until the next open), so pause
                // and restart — the fresh loop's initial yield re-primes everything.
                Self.log.error("head observation failed: \(error.localizedDescription, privacy: .public)")
                guard let self, self.activeRequest == request else { return }
                self.cache.purge()
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, self.activeRequest == request else { return }
                self.restart()
            }
        }
    }

    // Distributed/defaults notifications carry no main-thread delivery contract — hop, don't
    // assume (the click-monitor rule in HistoryPanelController).

    @objc private nonisolated func defaultsDidChange() {
        Task { @MainActor in self.refresh() }
    }

    @objc private nonisolated func screenDidLock() {
        Task { @MainActor in self.handleScreenLock() }
    }

    @objc private nonisolated func screenDidUnlock() {
        Task { @MainActor in self.handleScreenUnlock() }
    }
}
