//
//  HistoryManagerView.swift
//  ClipySi — Apple Silicon rewrite
//
//  Read-only clipboard history manager. The window is hosted by AppDelegate in an AppKit
//  NSWindow; the table itself is SwiftUI over `HistoryManagerStore` (M-UI.11 P5): one 50-row
//  page of the filtered/sorted live history at a time — no 500-row eager-decrypt window, no
//  coverage cutoff. Sort and metadata filters push down to SQL; text search runs as a
//  progressive scan over the whole live set (the preview is an AES-GCM ciphertext, so only
//  the decrypted-and-masked title is searchable — never in SQL). All of it is display-only —
//  the only mutation here is delete (design, Q1). The Preview column is no longer sortable:
//  its ordering would need every row decrypted, which is exactly what P5 retires.
//

import AppKit
import SQLiteData
import SwiftUI

struct HistoryManagerView: View {
    @Bindable var store: HistoryManagerStore

    @State private var sortOrder = [KeyPathComparator(\HistoryClipRow.createdAt, order: .reverse)]

    private let onCopy: (Clip.ID) -> Void
    private let onDelete: (Clip.ID) -> Void
    private let onClearAll: () -> Void
    private let onSnippetize: (Clip.ID, SnippetFolder.ID) -> Void
    private let onBuildExport: () -> HistoryExportResult?
    private let onImport: (Data) -> HistoryImportOutcome
    private let onResolveImportOverflow: (HistoryImportOverflowResolution) -> Void

    @State private var pendingDelete: Clip.ID?
    @State private var confirmingClearAll = false
    @State private var snippetizing: SnippetizeTarget?

    init(store: HistoryManagerStore,
         onCopy: @escaping (Clip.ID) -> Void = { _ in },
         onDelete: @escaping (Clip.ID) -> Void = { _ in },
         onClearAll: @escaping () -> Void = {},
         onSnippetize: @escaping (Clip.ID, SnippetFolder.ID) -> Void = { _, _ in },
         onBuildExport: @escaping () -> HistoryExportResult? = { nil },
         onImport: @escaping (Data) -> HistoryImportOutcome = { _ in .failure(message: "") },
         onResolveImportOverflow: @escaping (HistoryImportOverflowResolution) -> Void = { _ in }) {
        self.store = store
        self.onCopy = onCopy
        self.onDelete = onDelete
        self.onClearAll = onClearAll
        self.onSnippetize = onSnippetize
        self.onBuildExport = onBuildExport
        self.onImport = onImport
        self.onResolveImportOverflow = onResolveImportOverflow
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HistoryFilterBar(searchText: $store.searchText,
                             typeFilter: $store.typeFilter,
                             appFilter: $store.appFilter,
                             availableTypes: store.availableTypes,
                             availableApps: store.availableApps,
                             showClear: store.isFilterActive,
                             onClear: { store.clearFilters() })
            Divider()
            table
            Divider()
            footer
        }
        .frame(minWidth: 820, minHeight: 460)
        .task { await store.run() }
        .onChange(of: sortOrder) { store.apply(tableSort: sortOrder) }
        .modifier(HistoryDialogs(pendingDelete: $pendingDelete,
                                 confirmingClearAll: $confirmingClearAll,
                                 selection: $store.selection,
                                 // Optimistic prune: a delete issued HERE disappears immediately;
                                 // the write's reconcile converges counts/cursors afterwards.
                                 onDelete: { [store] id in store.pruneRow(id); onDelete(id) },
                                 onClearAll: { [store] in store.pruneAllRows(); onClearAll() }))
        .sheet(item: $snippetizing) { target in
            SnippetizeSheet(
                clipPreview: target.preview,
                onAdd: { folderID in onSnippetize(target.id, folderID); snippetizing = nil },
                onCancel: { snippetizing = nil }
            )
        }
    }

    private func snippetizeSelection() {
        guard let row = store.selectedRow, row.canSnippetize else { return }
        snippetizing = SnippetizeTarget(id: row.id, preview: row.preview)
    }

    private func copySelection() {
        guard let row = store.selectedRow, row.canCopy else { return }
        onCopy(row.id)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("History")
                .font(.title3.weight(.semibold))
            Spacer()
            Button { copySelection() } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .disabled(store.selectedRow?.canCopy != true)
            .help("Copy the selected item to the clipboard")

            Button { snippetizeSelection() } label: {
                Label("Snippetize", systemImage: "text.badge.plus")
            }
            .disabled(store.selectedRow?.canSnippetize != true)
            .help("Save the selected text item as a snippet")

            Button { if let selection = store.selection { pendingDelete = selection } } label: {
                Label("Delete", systemImage: "trash")
            }
            // selectedRow (not bare selection): a selection whose row left the visible page
            // must not leave Delete armed against an invisible/gone row (review).
            .disabled(store.selectedRow == nil)
            .help("Delete the selected item")

            Button(role: .destructive) { confirmingClearAll = true } label: {
                Label("Clear All", systemImage: "trash.slash")
            }
            .disabled(store.historyIsEmpty)
            .help("Delete all clipboard history")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var table: some View {
        Table(store.displayedRows, selection: $store.selection, sortOrder: $sortOrder) {
            // Not sortable: ordering by preview would require decrypting the whole history.
            TableColumn("Preview") { row in
                Text(row.preview)
                    .lineLimit(1)
                    .foregroundStyle(row.decryptFailed ? .secondary : .primary)
            }
            .width(min: 260, ideal: 420)

            TableColumn("Date", value: \.createdAt) { row in
                Text(row.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(.secondary)
            }
            .width(min: 150, ideal: 170)

            TableColumn("App", value: \.sourceBundleDisplay) { row in
                Text(row.sourceBundleDisplay)
                    .lineLimit(1)
                    .foregroundStyle(row.sourceBundleDisplay.isEmpty ? .tertiary : .secondary)
            }
            .width(min: 140, ideal: 180)

            TableColumn("Type", value: \.typeDisplay) { row in
                Text(row.typeDisplay)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 120)

            TableColumn("Pinned", value: \.pinnedDisplay) { row in
                Text(row.pinnedDisplay)
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 80)
        }
        .overlay { tableOverlay }
    }

    @ViewBuilder private var tableOverlay: some View {
        // Order matters: the error plate never covers live rows; before the first commit a
        // spinner shows (a reopen must not flash "No History"/"No Results" while loading).
        if store.displayedRows.isEmpty {
            if store.loadFailed {
                ContentUnavailableView(
                    "History Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("The history database could not be read.")
                )
            } else if !store.hasLoaded || store.isScanning {
                ProgressView()
            } else if store.isFilterActive {
                ContentUnavailableView.search
            } else if store.historyIsEmpty {
                ContentUnavailableView("No History", systemImage: "clipboard")
            } else {
                ProgressView() // transitional: rows exist but none committed yet
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                store.goToPreviousPage()
            } label: {
                Image(systemName: "chevron.left").frame(width: 18, height: 18)
            }
            .help("Previous Page")
            .disabled(!store.canGoPrevious)

            // While scanning, no settled page count exists to promise (§3.1) — the label
            // drops the "of N" and the items count yields to the live tally in the indicator.
            Text(store.isScanning
                ? "Page \(store.pageIndex + 1)"
                : "Page \(store.pageIndex + 1) of \(store.lastPageIndex + 1)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(minWidth: 90)

            Button {
                store.goToNextPage()
            } label: {
                Image(systemName: "chevron.right").frame(width: 18, height: 18)
            }
            .help("Next Page")
            .disabled(!store.canGoNext)

            if store.isScanning {
                scanIndicator
            }

            Spacer()

            HistoryTransferControls(historyIsEmpty: store.historyIsEmpty,
                                    onBuildExport: onBuildExport,
                                    onImport: onImport,
                                    onResolveOverflow: onResolveImportOverflow)

            if !store.isScanning {
                Text("\(store.displayedTotal) items")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// Search progress: determinate once the scan knows its denominator, a compact spinner
    /// before that (the first batch carries the total). The tally is explicitly "so far" —
    /// a partial count must not pose as exact (§3.1).
    @ViewBuilder private var scanIndicator: some View {
        if store.scanTotal > 0 {
            ProgressView(value: Double(min(store.scanProcessed, store.scanTotal)),
                         total: Double(store.scanTotal))
                .progressViewStyle(.linear)
                .frame(width: 120)
        } else {
            ProgressView()
                .controlSize(.small)
        }
        Text("\(store.scanMatches.count) found so far")
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}

/// The delete / clear-all confirmation dialogs, factored out to keep the view body within budget.
private struct HistoryDialogs: ViewModifier {
    @Binding var pendingDelete: Clip.ID?
    @Binding var confirmingClearAll: Bool
    @Binding var selection: Clip.ID?
    let onDelete: (Clip.ID) -> Void
    let onClearAll: () -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Delete this item?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let pendingDelete { onDelete(pendingDelete) }
                    pendingDelete = nil
                    selection = nil
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            }
            .confirmationDialog(
                "Clear all clipboard history?",
                isPresented: $confirmingClearAll,
                titleVisibility: .visible
            ) {
                Button("Clear All", role: .destructive) {
                    onClearAll()
                    selection = nil
                }
                Button("Cancel", role: .cancel) {}
            }
    }
}
