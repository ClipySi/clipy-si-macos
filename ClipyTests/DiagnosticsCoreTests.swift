//
//  DiagnosticsCoreTests.swift
//  ClipyTests
//
//  The typed diagnostics layer + recorder. These tests pin the level ordering, the
//  level-gating of `record`, the bounded ring buffer, and the JSON envelope shape. The
//  *redaction* guarantee (no body data can ever reach the envelope) is proven separately in
//  DiagnosticsRedactionTests.
//

import Foundation
import Testing
@testable import Clipy

@Suite struct DiagnosticsCoreTests {

    // MARK: - DiagnosticLevel

    @Test func levelIsOrdered() {
        #expect(DiagnosticLevel.none < .minimal)
        #expect(DiagnosticLevel.minimal < .standard)
        #expect(DiagnosticLevel.standard < .detailed)
        #expect(DiagnosticLevel.allCases == [.none, .minimal, .standard, .detailed])
    }

    @Test func unknownRawDecodesToNone() {
        #expect(DiagnosticLevel(raw: nil) == .none)
        #expect(DiagnosticLevel(raw: "bogus") == .none)
        #expect(DiagnosticLevel(raw: "detailed") == .detailed)
    }

    @Test func eventMinimumLevelsMatchPolicy() {
        #expect(DiagnosticEvent.crashReceived.minimumLevel == .minimal)
        #expect(DiagnosticEvent.launched.minimumLevel == .standard)
        #expect(DiagnosticEvent.error(.paste, .ioFailure).minimumLevel == .standard)
        #expect(DiagnosticEvent.featureUsed(.menu).minimumLevel == .detailed)
    }

    // MARK: - Recorder gating

    /// Build a recorder whose level is fixed for the test.
    private func recorder(level: DiagnosticLevel, maxEvents: Int = 50) -> DiagnosticsRecorder {
        DiagnosticsRecorder(maxEvents: maxEvents,
                            level: { level },
                            installationID: { "test-install-id" },
                            now: { Make.epoch })
    }

    @Test func noneLevelRecordsNothing() {
        let rec = recorder(level: .none)
        rec.record(.crashReceived)
        rec.record(.featureUsed(.menu))
        rec.record(.launched)
        #expect(rec.bufferedCount == 0)
        let env = rec.snapshot()
        #expect(env.level == .none)
        #expect(env.events.isEmpty)
        #expect(env.environment.installationID == nil) // never minted at .none
    }

    @Test func minimalKeepsOnlyCrashes() {
        let rec = recorder(level: .minimal)
        rec.record(.crashReceived)
        rec.record(.error(.sync, .other)) // min .standard → dropped
        rec.record(.featureUsed(.paste)) // min .detailed → dropped
        #expect(rec.bufferedCount == 1)
        #expect(rec.snapshot().events.map(\.event) == [.crashReceived])
    }

    @Test func standardKeepsCrashesAndErrorsButNotBreadcrumbs() {
        let rec = recorder(level: .standard)
        rec.record(.crashReceived)
        rec.record(.launched)
        rec.record(.error(.capture, .decodeFailure))
        rec.record(.featureUsed(.history)) // breadcrumb → dropped
        #expect(rec.snapshot().events.map(\.event) == [.crashReceived, .launched, .error(.capture, .decodeFailure)])
    }

    @Test func detailedKeepsEverything() {
        let rec = recorder(level: .detailed)
        rec.record(.crashReceived)
        rec.record(.featureUsed(.snippets))
        #expect(rec.bufferedCount == 2)
    }

    @Test func bufferIsBounded() {
        let rec = recorder(level: .detailed, maxEvents: 3)
        for _ in 0..<10 { rec.record(.featureUsed(.menu)) }
        #expect(rec.bufferedCount == 3)
    }

    @Test func snapshotIncludesInstallationIDAtMinimalAndAbove() {
        let rec = recorder(level: .minimal)
        #expect(rec.snapshot().environment.installationID == "test-install-id")
    }

    // MARK: - Envelope JSON

    @Test func envelopeRoundTripsThroughJSON() throws {
        let rec = recorder(level: .detailed)
        rec.record(.launched)
        rec.record(.error(.update, .permissionDenied))
        rec.record(.featureUsed(.hotkey))
        let data = try rec.exportJSON()
        let decoded = try JSONDecoder.iso8601.decode(DiagnosticEnvelope.self, from: data)
        #expect(decoded == rec.snapshot())
        #expect(decoded.events.count == 3)
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
