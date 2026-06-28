//
//  CrashDiagnosticsReceiver.swift
//  ClipySi — Apple Silicon rewrite
//
//  The SDK-zero crash path. Subscribes to MetricKit only at `.minimal`+ and stores received
//  `MXCrashDiagnostic` payloads locally (no upload). This is intentionally thin: MetricKit delivers
//  crashes on the OS's own schedule (≈ daily, to signed/distributed apps), so we don't try to drive
//  it in tests — the unit tests cover the subscribe gate and the storage/export, not OS delivery.
//
//  MetricKit crash payloads are Apple-generated (stack traces, binary images) and contain no
//  clipboard content; they're stored verbatim and only ever surfaced via the user's manual export.
//

import Foundation
import MetricKit
import OSLog

final class CrashDiagnosticsReceiver: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    private static let log = Logger(subsystem: "io.github.ponponusa.clipysi", category: "diagnostics")

    private let store: DiagnosticsStore
    private let recorder: DiagnosticsRecorder
    private let lock = NSLock()
    private var subscribed = false // guarded by `lock`

    init(store: DiagnosticsStore = .live, recorder: DiagnosticsRecorder = .live) {
        self.store = store
        self.recorder = recorder
        super.init()
    }

    /// Subscribe at `.minimal`+, unsubscribe at `.none`. Idempotent. Call at launch and whenever the
    /// Diagnostics level changes.
    func updateSubscription(for level: DiagnosticLevel) {
        let want = level >= .minimal
        // Hold the lock across the add/remove so concurrent calls can't reorder the MetricKit
        // (un)subscribe relative to the final `subscribed` state. `add`/`remove` don't re-enter here.
        lock.lock()
        defer { lock.unlock() }
        guard want != subscribed else { return }
        subscribed = want
        if want {
            MXMetricManager.shared.add(self)
        } else {
            MXMetricManager.shared.remove(self)
        }
    }

    // MARK: - MXMetricManagerSubscriber

    /// Performance metrics — not used by ClipySi.
    func didReceive(_ payloads: [MXMetricPayload]) {}

    /// Crash (and other) diagnostics: persist each crash payload locally and drop a coarse breadcrumb.
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                ingestCrashPayload(crash.jsonRepresentation())
            }
        }
    }

    /// Persist one crash payload and record a `.crashReceived` breadcrumb. Split out of `didReceive`
    /// (which can't be exercised in tests — `MXDiagnosticPayload` isn't constructible) so the
    /// store-and-record path is unit-testable with an injected store/recorder.
    func ingestCrashPayload(_ data: Data) {
        do {
            try store.saveCrashPayload(data)
            recorder.record(.crashReceived)
        } catch {
            Self.log.error("failed to store crash payload: \(error.localizedDescription, privacy: .public)")
        }
    }
}
