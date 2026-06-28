//
//  DiagnosticsStore.swift
//  ClipySi — Apple Silicon rewrite
//
//  On-disk home for received MetricKit crash payloads and the assembly of an export bundle
//  the user can attach to a bug report. Nothing here is ever uploaded: the store writes under
//  Application Support and the export folder is built locally and revealed in Finder. The crash
//  payloads are Apple-generated (`MXCrashDiagnostic.jsonRepresentation()`) — stack traces and
//  binary metadata, never clipboard content — and the typed `DiagnosticEnvelope` is body-free by
//  construction (see DiagnosticTypes.swift). File names are content-agnostic (timestamp + UUID).
//

import Foundation

struct DiagnosticsStore: Sendable {
    /// Where received crash payloads are persisted.
    let directory: URL

    static let live = DiagnosticsStore(directory: Self.defaultDirectory())

    /// `~/Library/Application Support/<bundle id>/Diagnostics`.
    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let bundleID = Bundle.main.bundleIdentifier ?? "io.github.ponponusa.clipysi"
        return base.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
    }

    /// Persist one crash payload. Filename carries no content — just a timestamp and a UUID.
    func saveCrashPayload(_ data: Data, now: Date = Date()) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "crash-\(Int(now.timeIntervalSince1970))-\(UUID().uuidString).json"
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    /// URLs of the stored crash payloads (newest-agnostic; order is filesystem order).
    var crashPayloadURLs: [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("crash-") }
    }

    /// Number of stored crash payloads (shown in the Diagnostics pane).
    var crashCount: Int { crashPayloadURLs.count }

    /// Assemble an export folder under `parent`: the body-free `diagnostics.json` envelope plus a
    /// copy of every stored crash payload. Returns the created folder. Pure file I/O — `parent` is
    /// injectable so this is unit-testable with a temp directory. The folder name carries a UUID so
    /// two exports within the same wall-clock second don't collide and clobber each other.
    @discardableResult
    func writeExportBundle(envelopeJSON: Data, into parent: URL, now: Date = Date()) throws -> URL {
        let stamp = "\(Int(now.timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
        let folder = parent.appendingPathComponent("ClipySi-Diagnostics-\(stamp)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try envelopeJSON.write(to: folder.appendingPathComponent("diagnostics.json"), options: .atomic)
        for url in crashPayloadURLs {
            try? FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(url.lastPathComponent))
        }
        return folder
    }

    /// Delete every stored crash payload (the user's "Delete Stored Diagnostics" action). Best-effort
    /// per file; the directory itself is left in place.
    func deleteStoredCrashPayloads() {
        for url in crashPayloadURLs {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
