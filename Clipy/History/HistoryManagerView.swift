//
//  HistoryManagerView.swift
//  ClipySi — Apple Silicon rewrite
//
//  Read-only clipboard history manager. The window is hosted by AppDelegate in an AppKit
//  NSWindow; the table itself is SwiftUI. It observes a bounded *recent window* of clips via
//  @FetchAll (newest `historyWindowLimit`), decrypts them once per identity change, then does
//  filter/search/sort/paging entirely in memory (`HistoryFilter`). All of that is display-only —
//  the only mutation here is delete (design, Q1). Text search must be in-memory because the
//  preview is an AES-GCM ciphertext (`Clip.titleCipher`), not searchable in SQL.
//

import AppKit
import SQLiteData
import SwiftUI

private let historyPageSize = 50
// Bounded recent window the manager loads + decrypts. Search/filter/sort operate over this window;
// with the default 30-item history cap virtually all users see their whole history here, and larger
// histories get an honest "covers the most recent N" notice rather than a silent truncation.
private let historyWindowLimit = 500

struct HistoryManagerView: View {
    /// The manager's bounded window: the newest `historyWindowLimit` LIVE clips (+1 sentinel row that
    /// only signals truncation). The single source of truth for both the initial `@FetchAll` and the
    /// explicit `loadWindow()` reload — a tombstoned row (`deletedAt` set, `titleCipher` blanked) must
    /// never surface as a decryption-failed ghost or consume a window slot on either path.
    static var liveWindow: SelectOf<Clip> {
        Clip.where { $0.deletedAt.is(nil) }.order { $0.createdAt.desc() }.limit(historyWindowLimit + 1)
    }

    /// The window's row budget (sans the truncation sentinel) — exposed so tests can pin the
    /// boundary behavior of `liveWindow` without duplicating the constant.
    static let windowLimit = historyWindowLimit

    @FetchAll(HistoryManagerView.liveWindow) private var clips
    @State private var page = 0
    @State private var selection: Clip.ID?
    @State private var loadError: String?

    // Decrypted window, then the filtered/sorted view of it. `allRows` is rebuilt only when the clip
    // identity/order changes; `displayedRows` only when `allRows` or the query changes — never per
    // body render (selection/hover would otherwise re-run the pipeline).
    @State private var allRows: [HistoryClipRow] = []
    @State private var displayedRows: [HistoryClipRow] = []
    @State private var availableTypes: [String] = []
    @State private var availableApps: [String] = []

    @State private var searchText = ""
    @State private var typeFilter: String?
    @State private var appFilter: String?
    @State private var sortOrder = HistoryQuery.defaultSort

    private let displayBuilder = ClipDisplayBuilder()

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

    init(onCopy: @escaping (Clip.ID) -> Void = { _ in },
         onDelete: @escaping (Clip.ID) -> Void = { _ in },
         onClearAll: @escaping () -> Void = {},
         onSnippetize: @escaping (Clip.ID, SnippetFolder.ID) -> Void = { _, _ in },
         onBuildExport: @escaping () -> HistoryExportResult? = { nil },
         onImport: @escaping (Data) -> HistoryImportOutcome = { _ in .failure(message: "") },
         onResolveImportOverflow: @escaping (HistoryImportOverflowResolution) -> Void = { _ in }) {
        self.onCopy = onCopy
        self.onDelete = onDelete
        self.onClearAll = onClearAll
        self.onSnippetize = onSnippetize
        self.onBuildExport = onBuildExport
        self.onImport = onImport
        self.onResolveImportOverflow = onResolveImportOverflow
    }

    private var query: HistoryQuery {
        HistoryQuery(searchText: searchText, typeDisplay: typeFilter, appDisplay: appFilter, sort: sortOrder)
    }

    private var selectedRow: HistoryClipRow? {
        guard let selection else { return nil }
        return allRows.first { $0.id == selection }
    }

    // The window is full → older clips exist beyond it and are not covered by search/filter.
    private var windowTruncated: Bool { clips.count > historyWindowLimit }

    private var pageRows: [HistoryClipRow] {
        let start = min(page * historyPageSize, displayedRows.count)
        let end = min(start + historyPageSize, displayedRows.count)
        return Array(displayedRows[start..<end])
    }

    private var canGoPrevious: Bool { page > 0 }
    private var canGoNext: Bool { (page + 1) * historyPageSize < displayedRows.count }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HistoryFilterBar(searchText: $searchText,
                             typeFilter: $typeFilter,
                             appFilter: $appFilter,
                             availableTypes: availableTypes,
                             availableApps: availableApps,
                             showClear: query.isActive,
                             onClear: clearFilters)
            if windowTruncated { truncationNotice }
            Divider()
            table
            Divider()
            footer
        }
        .frame(minWidth: 820, minHeight: 460)
        .task { await loadWindow() }
        .onChange(of: clips.map(\.id), initial: true) { rebuildRows() }
        .onChange(of: query) { page = 0; applyQuery() }
        .modifier(HistoryDialogs(pendingDelete: $pendingDelete,
                                 confirmingClearAll: $confirmingClearAll,
                                 selection: $selection,
                                 onDelete: onDelete,
                                 onClearAll: onClearAll))
        .sheet(item: $snippetizing) { target in
            SnippetizeSheet(
                clipPreview: target.preview,
                onAdd: { folderID in onSnippetize(target.id, folderID); snippetizing = nil },
                onCancel: { snippetizing = nil }
            )
        }
    }

    private func snippetizeSelection() {
        guard let row = selectedRow, row.canSnippetize else { return }
        snippetizing = SnippetizeTarget(id: row.id, preview: row.preview)
    }

    private func copySelection() {
        guard let row = selectedRow, row.canCopy else { return }
        onCopy(row.id)
    }

    private func clearFilters() {
        searchText = ""
        typeFilter = nil
        appFilter = nil
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("History")
                .font(.title3.weight(.semibold))
            Spacer()
            Button { copySelection() } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .disabled(selectedRow?.canCopy != true)
            .help("Copy the selected item to the clipboard")

            Button { snippetizeSelection() } label: {
                Label("Snippetize", systemImage: "text.badge.plus")
            }
            .disabled(selectedRow?.canSnippetize != true)
            .help("Save the selected text item as a snippet")

            Button { if let selection { pendingDelete = selection } } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(selection == nil)
            .help("Delete the selected item")

            Button(role: .destructive) { confirmingClearAll = true } label: {
                Label("Clear All", systemImage: "trash.slash")
            }
            .disabled(allRows.isEmpty)
            .help("Delete all clipboard history")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var truncationNotice: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
            Text("Search and filters cover the most recent \(historyWindowLimit) items")
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    private var table: some View {
        Table(pageRows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Preview", value: \.preview, comparator: .localizedStandard) { row in
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

            TableColumn("App", value: \.sourceBundleDisplay, comparator: .localizedStandard) { row in
                Text(row.sourceBundleDisplay)
                    .lineLimit(1)
                    .foregroundStyle(row.sourceBundleDisplay.isEmpty ? .tertiary : .secondary)
            }
            .width(min: 140, ideal: 180)

            TableColumn("Type", value: \.typeDisplay, comparator: .localizedStandard) { row in
                Text(row.typeDisplay)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 120)

            TableColumn("Pinned", value: \.pinnedDisplay, comparator: .localizedStandard) { row in
                Text(row.pinnedDisplay)
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 80)
        }
        .overlay {
            if let loadError {
                ContentUnavailableView(
                    "History Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
            } else if allRows.isEmpty {
                ContentUnavailableView("No History", systemImage: "clipboard")
            } else if displayedRows.isEmpty {
                ContentUnavailableView.search
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                if canGoPrevious { selection = nil; page -= 1 }
            } label: {
                Image(systemName: "chevron.left").frame(width: 18, height: 18)
            }
            .help("Previous Page")
            .disabled(!canGoPrevious)

            Text("Page \(page + 1)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(minWidth: 72)

            Button {
                if canGoNext { selection = nil; page += 1 }
            } label: {
                Image(systemName: "chevron.right").frame(width: 18, height: 18)
            }
            .help("Next Page")
            .disabled(!canGoNext)

            Spacer()

            HistoryTransferControls(historyIsEmpty: allRows.isEmpty,
                                    onBuildExport: onBuildExport,
                                    onImport: onImport,
                                    onResolveOverflow: onResolveImportOverflow)

            Text("\(displayedRows.count) items")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// Decrypts the loaded window into rows and refreshes the derived filter option lists. Reconciles
    /// the active Type/App filters against what's still present, then re-applies the query. The mask
    /// policy is resolved ONCE for the whole window (M-UI.11 P1), not once per row.
    private func rebuildRows() {
        let window = Array(clips.prefix(historyWindowLimit))
        let displays = displayBuilder.displays(of: window, policy: .current())
        allRows = zip(window, displays).map { clip, display in
            HistoryClipRow(clip: clip, display: display)
        }
        availableTypes = Set(allRows.map(\.typeDisplay)).sorted()
        availableApps = Set(allRows.map(\.sourceBundleDisplay).filter { !$0.isEmpty }).sorted()
        if let type = typeFilter, !availableTypes.contains(type) { typeFilter = nil }
        if let app = appFilter, !availableApps.contains(app) { appFilter = nil }
        applyQuery()
    }

    /// Re-derives the displayed rows from `allRows` + the current query and clamps the page.
    private func applyQuery() {
        displayedRows = HistoryFilter.apply(query, to: allRows)
        let lastPage = displayedRows.isEmpty ? 0 : (displayedRows.count - 1) / historyPageSize
        if page > lastPage { page = lastPage }
    }

    private func loadWindow() async {
        loadError = nil
        do {
            try await $clips
                .load(Self.liveWindow)
                .task
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
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
