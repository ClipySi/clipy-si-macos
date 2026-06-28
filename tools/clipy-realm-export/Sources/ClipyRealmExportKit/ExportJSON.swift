//
//  ExportJSON.swift
//  ClipyRealmExportKit
//
//  The ClipySi History Manager's JSON export format (HistoryExporter / HistoryImporter).
//  This tool emits exactly this shape so the app can import it unchanged — text-only. `version` MUST
//  match the importer's `HistoryExportResult.formatVersion` (1).
//

import Foundation

/// The current export format version — keep in lockstep with the app's `HistoryExportResult.formatVersion`.
public let historyExportFormatVersion = 1

/// Plain-text pasteboard UTI written for every item (the importer is text-only and stores it as such).
public let plainTextTypeIdentifier = "public.utf8-plain-text"

public struct ExportFile: Encodable {
    public let version: Int
    public let exportedAt: Int
    public let items: [ExportItem]

    public init(exportedAt: Int, items: [ExportItem]) {
        self.version = historyExportFormatVersion
        self.exportedAt = exportedAt
        self.items = items
    }
}

public struct ExportItem: Encodable {
    public let createdAt: Int
    public let type: String
    public let app: String?
    public let pinned: Bool
    public let text: String

    public init(createdAt: Int, text: String) {
        self.createdAt = createdAt
        self.type = plainTextTypeIdentifier
        self.app = nil // CPYClip carries no source bundle
        self.pinned = false
        self.text = text
    }
}
