//
//  HistoryTransferControls.swift
//  ClipySi — Apple Silicon rewrite
//
//  The History Manager's Import / Export footer controls and their whole flow, split
//  out of `HistoryManagerView` so each stays within the file/type-length budget. Export builds JSON
//  via the injected blob-store-backed closure (the file is UNENCRYPTED — confirmed first, design §5
//  R2); import reads a JSON file and ingests it idempotently. Both report their result in one alert.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct HistoryTransferControls: View {
    let historyIsEmpty: Bool
    let onBuildExport: () -> HistoryExportResult?
    let onImport: (Data) -> HistoryImportOutcome
    let onResolveOverflow: (HistoryImportOverflowResolution) -> Void

    @State private var confirmingExport = false
    @State private var showingExporter = false
    @State private var exportDocument = HistoryDocument(data: Data())
    @State private var pendingExported = 0
    @State private var pendingSkipped = 0
    @State private var showingImporter = false
    @State private var actionAlert: HistoryAlert?
    @State private var overflowPrompt: OverflowPrompt?

    var body: some View {
        HStack(spacing: 8) {
            Button { showingImporter = true } label: {
                Label("Import…", systemImage: "square.and.arrow.down")
            }
            .help("Import history from a JSON file")

            Button { confirmingExport = true } label: {
                Label("Export…", systemImage: "square.and.arrow.up")
            }
            .disabled(historyIsEmpty)
            .help("Export all history to an unencrypted JSON file")
        }
        .confirmationDialog(
            "Export history as unencrypted plain text?",
            isPresented: $confirmingExport,
            titleVisibility: .visible
        ) {
            Button("Export…") { beginExport() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The saved JSON file is NOT encrypted — anyone who can open it can read every item.")
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "clipysi-history"
        ) { result in
            switch result {
            case .success:
                presentExportSuccess()
            case .failure(let error):
                actionAlert = HistoryAlert(
                    title: String(localized: "Export Failed", comment: "History-export alert title when writing the file fails"),
                    message: error.localizedDescription)
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json]) { performImport($0) }
        .alert(
            actionAlert?.title ?? "",
            isPresented: Binding(get: { actionAlert != nil }, set: { if !$0 { actionAlert = nil } }),
            presenting: actionAlert
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { Text($0.message) }
        .alert(
            "Max History Size Exceeded",
            isPresented: Binding(get: { overflowPrompt != nil }, set: { if !$0 { overflowPrompt = nil } }),
            presenting: overflowPrompt
        ) { prompt in
            Button("Increase Limit to \(prompt.overflow.suggestedLimit)") {
                onResolveOverflow(.increaseLimit(prompt.overflow.suggestedLimit))
                overflowPrompt = nil
            }
            Button("Remove Oldest Items", role: .destructive) {
                onResolveOverflow(.removeOldest)
                overflowPrompt = nil
            }
            // Explicit cancel (not SwiftUI's synthesized one) so it can roll the import back out, and so
            // Escape maps here rather than to a destructive action.
            Button("Cancel", role: .cancel) {
                onResolveOverflow(.cancelImport)
                overflowPrompt = nil
            }
        } message: { Text(overflowMessage($0)) }
    }

    // MARK: - Export

    /// Builds the export (whole history → JSON, via the injected blob-store-backed closure), then
    /// presents the save panel. Surfaces a build failure or an all-skipped ("nothing to export")
    /// outcome as an alert instead of writing an empty file.
    private func beginExport() {
        guard let result = onBuildExport() else {
            actionAlert = HistoryAlert(
                title: String(localized: "Export Failed", comment: "History-export alert title when the history can't be read"),
                message: String(localized: "The clipboard history could not be read.", comment: "History-export failure detail"))
            return
        }
        guard result.exportedCount > 0 else {
            actionAlert = HistoryAlert(
                title: String(localized: "Nothing to Export", comment: "History-export alert title when there are no text items"),
                message: String(localized: "There are no text items to export.", comment: "History-export empty detail"))
            return
        }
        exportDocument = HistoryDocument(data: result.data)
        pendingExported = result.exportedCount
        pendingSkipped = result.skippedCount
        showingExporter = true
    }

    private func presentExportSuccess() {
        var message = String(localized: "Exported \(pendingExported) item(s).", comment: "History-export success message")
        if pendingSkipped > 0 {
            message += " " + String(localized: "Skipped \(pendingSkipped) non-text or unreadable item(s).",
                                    comment: "History-export skipped-count detail")
        }
        actionAlert = HistoryAlert(
            title: String(localized: "Export Complete", comment: "History-export success alert title"),
            message: message)
    }

    // MARK: - Import

    /// Reads the chosen JSON file and ingests it (via the injected blob-store-backed closure), then
    /// reports the imported / skipped / failed counts. The decrypt + ingest run in AppDelegate; this
    /// view only reads the file bytes and renders the outcome.
    private func performImport(_ result: Result<URL, Error>) {
        let importFailed = String(localized: "Import Failed", comment: "History-import alert title")
        switch result {
        case .failure(let error):
            actionAlert = HistoryAlert(title: importFailed, message: error.localizedDescription)
        case .success(let url):
            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                actionAlert = HistoryAlert(title: importFailed, message: error.localizedDescription)
                return
            }
            switch onImport(data) {
            case let .success(summary, overflow):
                if let overflow {
                    overflowPrompt = OverflowPrompt(overflow: overflow)
                } else {
                    actionAlert = HistoryAlert(
                        title: String(localized: "Import Complete", comment: "History-import success alert title"),
                        message: importSummaryMessage(summary))
                }
            case .failure(let message):
                actionAlert = HistoryAlert(title: importFailed, message: message)
            }
        }
    }

    private func importSummaryMessage(_ summary: HistoryImportResult) -> String {
        var message = String(localized: "Imported \(summary.imported) item(s).", comment: "History-import success message")
        if summary.skipped > 0 {
            message += " " + String(localized: "Skipped \(summary.skipped) empty or duplicate item(s).",
                                    comment: "History-import skipped-count detail")
        }
        if summary.failed > 0 {
            message += " " + String(localized: "\(summary.failed) item(s) could not be imported.",
                                    comment: "History-import failed-count detail")
        }
        return message
    }

    /// The overflow prompt's body: how far over the limit the import put the history. (No "imported N"
    /// line here — Cancel rolls the import back, so claiming it completed would be misleading.)
    private func overflowMessage(_ prompt: OverflowPrompt) -> String {
        String(localized: "Your history now has \(prompt.overflow.totalAfterImport) items, above the limit of \(prompt.overflow.currentLimit). Increase the limit to keep them all, or remove the oldest items beyond the limit?",
               comment: "History-import overflow prompt: history exceeds the max-history setting")
    }
}

/// Carries the overflow info into the "max history exceeded" prompt (`Identifiable` for `.alert`).
private struct OverflowPrompt: Identifiable {
    let id = UUID()
    let overflow: HistoryImportOverflow
}

/// An already-localized alert (title + message) for the transfer flow's success / failure feedback,
/// `Identifiable` so it can drive a SwiftUI `.alert(presenting:)` (mirrors the snippet editor).
private struct HistoryAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// A minimal `FileDocument` wrapper so `.fileExporter` can write the exporter's JSON bytes.
private struct HistoryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
