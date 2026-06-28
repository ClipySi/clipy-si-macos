//
//  DiagnosticsRecorder.swift
//  ClipySi — Apple Silicon rewrite
//
//  A tiny, bounded, level-gated event recorder. Injected as `\.diagnosticsRecorder`
//  (mirroring `\.maskingService` / `\.historyCipher`): one shared `.live` instance backs the whole
//  app, tests/previews get a `.disabled` value (level `.none`, so `record` is a no-op). The recorder
//  only ever sees `DiagnosticEvent`s — enums — so there is no path for clipboard content to enter
//  the buffer (see DiagnosticTypes.swift and security-guidance.md §5).
//
//  Thread-safety: callers fire breadcrumbs from many contexts (launch, capture, menu), so the
//  buffer is guarded by an `NSLock` and the type is `@unchecked Sendable` rather than actor-isolated
//  — `record` stays synchronous so call sites don't need `await`, and the DependencyKey's nonisolated
//  `liveValue` can construct it (a `@MainActor` value type can't be built from `liveValue`).
//

import Foundation
import SQLiteData // re-exports swift-dependencies (DependencyKey / DependencyValues)

final class DiagnosticsRecorder: @unchecked Sendable {
    /// Keep only the most recent breadcrumbs — a crash investigation wants the lead-up, not history.
    private let maxEvents: Int
    private let lock = NSLock()
    private var buffer: [TimestampedEvent] = [] // guarded by `lock`

    private let level: @Sendable () -> DiagnosticLevel
    private let installationID: @Sendable () -> String?
    private let now: @Sendable () -> Date

    init(maxEvents: Int = 50,
         level: @escaping @Sendable () -> DiagnosticLevel,
         installationID: @escaping @Sendable () -> String?,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.maxEvents = maxEvents
        self.level = level
        self.installationID = installationID
        self.now = now
    }

    /// Record an event if the current level retains it. No-op at `.none`; events whose
    /// `minimumLevel` exceeds the current level are dropped (e.g. breadcrumbs at `.standard`).
    func record(_ event: DiagnosticEvent) {
        let level = level()
        guard level >= .minimal, event.minimumLevel <= level else { return }
        let stamped = TimestampedEvent(timestamp: now(), event: event)
        lock.lock()
        defer { lock.unlock() }
        buffer.append(stamped)
        if buffer.count > maxEvents {
            buffer.removeFirst(buffer.count - maxEvents)
        }
    }

    /// A point-in-time projection of what would be collected at the current level. The installation
    /// ID is included only at `.minimal`+; events are re-filtered by the current level in case it was
    /// lowered after some were recorded.
    func snapshot() -> DiagnosticEnvelope {
        let level = level()
        let id = level >= .minimal ? installationID() : nil
        let env = DiagnosticEnvironment.current(installationID: id)
        lock.lock()
        let retained = buffer.filter { $0.event.minimumLevel <= level }
        lock.unlock()
        return DiagnosticEnvelope(level: level, environment: env, events: retained)
    }

    /// The snapshot as pretty-printed, key-sorted JSON — the bytes the user exports and the
    /// redaction canary test scans.
    func exportJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(snapshot())
    }

    /// Test seam: current buffered count (after level filtering is applied on read elsewhere).
    var bufferedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffer.count
    }
}

extension DiagnosticsRecorder {
    /// Live value: reads the user's level from `AppSettings` per call (so a Diagnostics-pane change
    /// takes effect immediately) and lazily mints an anonymous installation ID the first time one is
    /// needed at `.minimal`+.
    static let live = DiagnosticsRecorder(
        level: { AppSettings().diagnosticsLevel },
        installationID: { liveInstallationID() }
    )

    /// Disabled value for tests/previews: level pinned to `.none`, so `record` never retains anything.
    static let disabled = DiagnosticsRecorder(level: { .none }, installationID: { nil })

    /// Reads (or, on first use, generates and persists) the anonymous on-device installation ID.
    /// Never called at `.none` — `snapshot()` gates on the level before asking for it.
    private static func liveInstallationID(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: DefaultsKeys.diagnosticsInstallationID) {
            return existing
        }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: DefaultsKeys.diagnosticsInstallationID)
        return fresh
    }
}

private enum DiagnosticsRecorderKey: DependencyKey {
    static var liveValue: DiagnosticsRecorder { .live }
    static var testValue: DiagnosticsRecorder { .disabled }
    static var previewValue: DiagnosticsRecorder { .disabled }
}

extension DependencyValues {
    var diagnosticsRecorder: DiagnosticsRecorder {
        get { self[DiagnosticsRecorderKey.self] }
        set { self[DiagnosticsRecorderKey.self] = newValue }
    }
}
