//
//  AppDelegate+History.swift
//  ClipySi — Apple Silicon rewrite
//
//  The History Manager's export / import / over-limit-overflow handling, split out of AppDelegate to
//  keep that file within the length budget. These run here (not in the SwiftUI view) because they need
//  the live `blobStore` and own the `maxHistorySize` setting + history trim. No clip content is ever
//  logged — only metadata (counts, error categories). See HistoryExporter / HistoryImporter and the
//  design (Q1: history is display-only; the only deletions are trim / a cancelled import's rollback).
//

import Foundation
import OSLog

extension AppDelegate {
    /// Builds the History Manager's JSON export (whole history, decrypted) for the view's file panel.
    /// Needs the live blob store, so it runs here; returns nil (→ the view shows a failure alert) on a
    /// missing store or a read error. The error text only carries metadata, never clip content.
    func buildHistoryExport() -> HistoryExportResult? {
        guard let blobStore else { return nil }
        do {
            return try HistoryExporter(blobStore: blobStore).export()
        } catch {
            AppDelegate.logger.error("history export build failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Imports a JSON history file into the encrypted store via the live blob store. Maps the
    /// importer's typed failures to localized messages; the error text carries only metadata (version
    /// number / category), never any clip content.
    func importHistory(from data: Data) -> HistoryImportOutcome {
        guard let blobStore else {
            return .failure(message: String(localized: "The clipboard store is unavailable.",
                                            comment: "History-import failure when the blob store can't be opened"))
        }
        do {
            let (result, importedIDs) = try HistoryImporter(blobStore: blobStore).importItems(from: data)
            // Only prompt when the import actually added clips — an all-duplicate (no-op) import never
            // pushes the history past the cap, even if it was already over it.
            let overflow = result.imported > 0 ? historyOverflow() : nil
            // Stash the new ids only while the prompt is up, so "Cancel" can roll this import back.
            pendingImportedIDs = overflow != nil ? importedIDs : []
            return .success(result, overflow: overflow)
        } catch HistoryImporter.ImportError.unsupportedVersion(let version) {
            return .failure(message: String(localized: "This file uses an unsupported format version (\(version)).",
                                            comment: "History-import failure for an unknown file version"))
        } catch {
            return .failure(message: String(localized: "This file is not a valid history export.",
                                            comment: "History-import failure for a malformed file"))
        }
    }

    /// After an import, reports whether the store now holds more clips than `maxHistorySize` (so the
    /// view can prompt). Returns nil when the history still fits, or the count can't be read.
    private func historyOverflow() -> HistoryImportOverflow? {
        let limit = AppSettings().maxHistorySize
        guard let total = try? ClipRepository().count(), total > limit else { return nil }
        return HistoryImportOverflow(totalAfterImport: total,
                                     currentLimit: limit,
                                     suggestedLimit: SettingsMapping.suggestedHistoryLimit(forTotal: total))
    }

    /// Applies the user's choice from the import-overflow prompt: raise `maxHistorySize` so the imported
    /// history all fits, keep the limit and trim the oldest clips beyond it, or cancel — which rolls the
    /// just-imported clips back out. All blob deletes GC like the capture path; history stays
    /// display-only (the only deletions are trim / the cancel rollback of this same import).
    func resolveHistoryOverflow(_ resolution: HistoryImportOverflowResolution) {
        defer { pendingImportedIDs = [] }
        switch resolution {
        case .increaseLimit(let newLimit):
            let clamped = SettingsMapping.clampMaxHistorySize(newLimit)
            UserDefaults.standard.set(clamped, forKey: DefaultsKeys.maxHistorySize)
        case .removeOldest:
            guard let blobStore else { return }
            do {
                for staleBlob in try ClipRepository().trim(maxHistorySize: AppSettings().maxHistorySize) {
                    try? blobStore.delete(id: staleBlob)
                }
            } catch {
                AppDelegate.logger.error("history trim after import failed: \(error.localizedDescription, privacy: .public)")
            }
        case .cancelImport:
            guard let blobStore else { return }
            // Per-id isolation so one failure doesn't strand the rest of the rollback; log (metadata
            // only) so a partial rollback is observable, mirroring the .removeOldest arm.
            for id in pendingImportedIDs {
                do {
                    for staleBlob in try ClipRepository().delete(id: id) {
                        try? blobStore.delete(id: staleBlob)
                    }
                } catch {
                    AppDelegate.logger.error("history import cancel-rollback failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}
