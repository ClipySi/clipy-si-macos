//
//  DiagnosticsStoreTests.swift
//  ClipyTests
//
//  On-disk crash storage + export bundle, and the crash-ingest path of the MetricKit
//  receiver. Each test uses a private temp directory so nothing touches the real Application Support
//  store. (MetricKit delivery itself isn't unit-testable — MXDiagnosticPayload isn't constructible —
//  so the receiver is exercised via its `ingestCrashPayload` seam.)
//

import Foundation
import Testing
@testable import Clipy

@Suite struct DiagnosticsStoreTests {

    /// A store rooted in a unique temp directory.
    private func tempStore() -> DiagnosticsStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipySiDiagTests-\(UUID().uuidString)", isDirectory: true)
        return DiagnosticsStore(directory: dir)
    }

    @Test func savesAndCountsCrashPayloads() throws {
        let store = tempStore()
        #expect(store.crashCount == 0)
        try store.saveCrashPayload(Data("{\"crash\":1}".utf8))
        try store.saveCrashPayload(Data("{\"crash\":2}".utf8))
        #expect(store.crashCount == 2)
    }

    @Test func exportBundleContainsEnvelopeAndCrashes() throws {
        let store = tempStore()
        try store.saveCrashPayload(Data("{\"crash\":1}".utf8))
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipySiExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let envelope = Data("{\"level\":\"minimal\"}".utf8)
        let folder = try store.writeExportBundle(envelopeJSON: envelope, into: parent)

        let contents = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let names = contents.map(\.lastPathComponent)
        #expect(names.contains("diagnostics.json"))
        #expect(names.contains { $0.hasPrefix("crash-") })
        let writtenEnvelope = try Data(contentsOf: folder.appendingPathComponent("diagnostics.json"))
        #expect(writtenEnvelope == envelope)
    }

    @Test func exportBundleWorksWithNoCrashes() throws {
        let store = tempStore()
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipySiExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let folder = try store.writeExportBundle(envelopeJSON: Data("{}".utf8), into: parent)
        let names = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
        #expect(names == ["diagnostics.json"])
    }

    @Test func deleteStoredCrashPayloadsClearsThem() throws {
        let store = tempStore()
        try store.saveCrashPayload(Data("{}".utf8))
        try store.saveCrashPayload(Data("{}".utf8))
        #expect(store.crashCount == 2)
        store.deleteStoredCrashPayloads()
        #expect(store.crashCount == 0)
    }

    @Test func exportFolderNamesAreUnique() throws {
        let store = tempStore()
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipySiExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        // Same wall-clock second → folders must still differ (UUID suffix).
        let now = Make.epoch
        let first = try store.writeExportBundle(envelopeJSON: Data("{}".utf8), into: parent, now: now)
        let second = try store.writeExportBundle(envelopeJSON: Data("{}".utf8), into: parent, now: now)
        #expect(first != second)
    }

    @Test func receiverIngestStoresCrashAndRecordsBreadcrumb() throws {
        let store = tempStore()
        let recorder = DiagnosticsRecorder(level: { .minimal }, installationID: { nil }, now: { Make.epoch })
        let receiver = CrashDiagnosticsReceiver(store: store, recorder: recorder)

        receiver.ingestCrashPayload(Data("{\"crash\":\"x\"}".utf8))

        #expect(store.crashCount == 1)
        #expect(recorder.snapshot().events.map(\.event) == [.crashReceived])
    }

    @Test func receiverIngestAtNoneRecordsNoBreadcrumb() throws {
        // The crash file is still written, but a .crashReceived breadcrumb is dropped at .none.
        let store = tempStore()
        let recorder = DiagnosticsRecorder(level: { .none }, installationID: { nil }, now: { Make.epoch })
        let receiver = CrashDiagnosticsReceiver(store: store, recorder: recorder)
        receiver.ingestCrashPayload(Data("{}".utf8))
        #expect(store.crashCount == 1)
        #expect(recorder.snapshot().events.isEmpty)
    }
}
