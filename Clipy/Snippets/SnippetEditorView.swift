//
//  SnippetEditorView.swift
//  ClipySi — Apple Silicon rewrite
//
//  The snippet editor: a three-column `NavigationSplitView` (folders → snippets → detail) over live
//  `@FetchAll` queries, all edits routed through `SnippetRepository`. Hosted in an AppKit window by
//  AppDelegate (an agent app has no always-present SwiftUI scene to drive `openWindow`). See the
//  design §3.5.
//
//  Faithful to the original CPYSnippetsEditorWindowController: folder/snippet CRUD, drag-reorder,
//  enable toggles, XML import/export, and a plain-text content editor (no smart quotes/dashes/spell)
//  via an NSTextView bridge. Cross-folder drag is deferred in favor of an explicit "Move to Folder"
//  menu (§6 Q3); content commits are debounced (§6 Q5). The delete-confirm suppression checkbox
//  (`kCPYSuppressAlertForDeleteSnippet`) is a later refinement.
//

import AppKit
import OSLog
import SQLiteData
import SwiftUI
import UniformTypeIdentifiers

/// Renders a folder/snippet title: user-entered titles verbatim (never run through localization),
/// falling back to a *localized* placeholder when the title is empty.
private func displayTitle(_ raw: String, placeholder: LocalizedStringKey) -> Text {
    raw.isEmpty ? Text(placeholder) : Text(verbatim: raw)
}

/// One-shot result banner shown after an XML snippet import — success counts, an empty file, or a
/// read/parse failure. Identifiable so it can drive a SwiftUI `.alert(presenting:)`. Both fields are
/// already-localized strings (resolved at the call site), displayed verbatim.
private struct ImportAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct SnippetEditorView: View {
    @FetchAll(SnippetFolder.order(by: \.sortOrder)) private var folders
    @FetchAll(Snippet.order(by: \.sortOrder)) private var allSnippets

    @State private var selectedFolderID: SnippetFolder.ID?
    @State private var selectedSnippetID: Snippet.ID?
    @State private var showingImporter = false
    @State private var showingExporter = false
    @State private var exportDocument = SnippetsDocument(data: Data())
    @State private var confirmingFolderDelete = false
    @State private var confirmingSnippetDelete = false
    @State private var importAlert: ImportAlert?

    private let repo = SnippetRepository()
    private static let log = Logger(subsystem: "io.github.ponponusa.clipysi", category: "snippets")

    private var selectedFolderSnippets: [Snippet] {
        guard let id = selectedFolderID else { return [] }
        return allSnippets.filter { $0.folderID == id } // global sortOrder order ⇒ per-folder order
    }

    var body: some View {
        NavigationSplitView {
            folderList
        } content: {
            snippetList
        } detail: {
            detail
        }
        .frame(minWidth: 760, minHeight: 440)
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.xml]) { importSnippets($0) }
        .fileExporter(isPresented: $showingExporter, document: exportDocument,
                      contentType: .xml, defaultFilename: "snippets") { result in
            if case .failure(let error) = result {
                Self.log.error("snippet export failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        .alert(
            importAlert?.title ?? "",
            isPresented: Binding(get: { importAlert != nil }, set: { if !$0 { importAlert = nil } }),
            presenting: importAlert
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { Text($0.message) }
    }

    // MARK: - Columns

    private var folderList: some View {
        List(selection: $selectedFolderID) {
            ForEach(folders) { folder in
                Label {
                    displayTitle(folder.title, placeholder: "untitled folder")
                } icon: {
                    Image(systemName: "folder")
                }
                    .foregroundStyle(folder.isEnabled ? .primary : .secondary)
                    .tag(folder.id)
            }
            .onMove { offsets, destination in
                var ordered = folders.map(\.id)
                ordered.move(fromOffsets: offsets, toOffset: destination)
                try? repo.reorderFolders(ordered)
            }
        }
        .navigationTitle("Folders")
        .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                // Folder-badged + note-badged icons (plus tooltips) so each button reads as a folder
                // action vs. a snippet action — not two identical ± pairs across the two columns.
                Button { addFolder() } label: { Image(systemName: "folder.badge.plus") }
                    .help("New Folder")
                Button { confirmingFolderDelete = true } label: { Image(systemName: "trash") }
                    .help("Delete Folder")
                    .disabled(selectedFolderID == nil)
                Spacer()
                Button { showingImporter = true } label: { Image(systemName: "square.and.arrow.down") }
                    .help("Import snippets from XML")
                Button { beginExport() } label: { Image(systemName: "square.and.arrow.up") }
                    .help("Export snippets to XML")
            }
        }
        .confirmationDialog("Delete this folder and all its snippets?",
                            isPresented: $confirmingFolderDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteSelectedFolder() }
        }
    }

    private var snippetList: some View {
        Group {
            if selectedFolderID != nil {
                List(selection: $selectedSnippetID) {
                    ForEach(selectedFolderSnippets) { snippet in
                        Label {
                            displayTitle(snippet.title, placeholder: "untitled snippet")
                        } icon: {
                            Image(systemName: "note.text")
                        }
                            .foregroundStyle(snippet.isEnabled ? .primary : .secondary)
                            .tag(snippet.id)
                    }
                    .onMove { offsets, destination in
                        var ordered = selectedFolderSnippets.map(\.id)
                        ordered.move(fromOffsets: offsets, toOffset: destination)
                        try? repo.reorderSnippets(ordered)
                    }
                }
            } else {
                ContentUnavailableView("No Folder Selected", systemImage: "folder")
            }
        }
        .navigationTitle("Snippets")
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button { addSnippet() } label: { Image(systemName: "note.text.badge.plus") }
                    .help("New Snippet")
                    .disabled(selectedFolderID == nil)
                Button { confirmingSnippetDelete = true } label: { Image(systemName: "trash") }
                    .help("Delete Snippet")
                    .disabled(selectedSnippetID == nil)
            }
        }
        .confirmationDialog("Delete this snippet?",
                            isPresented: $confirmingSnippetDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteSelectedSnippet() }
        }
    }

    @ViewBuilder private var detail: some View {
        if let id = selectedSnippetID, let snippet = allSnippets.first(where: { $0.id == id }) {
            SnippetDetailView(
                snippet: snippet,
                otherFolders: folders.filter { $0.id != snippet.folderID },
                repo: repo,
                onMove: { destination in move(snippet, to: destination) }
            )
            .id(snippet.id) // recreate (reload drafts) when the selection changes
        } else if let id = selectedFolderID, let folder = folders.first(where: { $0.id == id }) {
            FolderDetailView(folder: folder, repo: repo).id(folder.id)
        } else {
            ContentUnavailableView("No Selection", systemImage: "note.text")
        }
    }

    // MARK: - Actions

    private func addFolder() {
        guard let folder = try? repo.insertFolder() else { return }
        selectedFolderID = folder.id
        selectedSnippetID = nil
    }

    private func addSnippet() {
        guard let folderID = selectedFolderID, let snippet = try? repo.insertSnippet(folderID: folderID) else { return }
        selectedSnippetID = snippet.id
    }

    private func deleteSelectedFolder() {
        guard let id = selectedFolderID else { return }
        try? repo.deleteFolder(id: id)
        selectedFolderID = nil
        selectedSnippetID = nil
    }

    private func deleteSelectedSnippet() {
        guard let id = selectedSnippetID else { return }
        try? repo.deleteSnippet(id: id)
        selectedSnippetID = nil
    }

    private func move(_ snippet: Snippet, to folderID: SnippetFolder.ID) {
        let destination = allSnippets.filter { $0.folderID == folderID }.map(\.id) + [snippet.id]
        try? repo.moveSnippet(id: snippet.id, toFolder: folderID, destinationOrder: destination)
        selectedFolderID = folderID
        selectedSnippetID = snippet.id
    }

    private func beginExport() {
        let details = (try? repo.fetchFolderDetails()) ?? []
        exportDocument = SnippetsDocument(data: SnippetXML.export(details))
        showingExporter = true
    }

    private func importSnippets(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            Self.log.error("snippet import failed: \(error.localizedDescription, privacy: .public)")
            importAlert = ImportAlert(
                title: String(localized: "Import Failed", comment: "Snippet-import alert title when the file can't be opened"),
                message: error.localizedDescription)
        case .success(let url):
            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }
            do {
                let imported = try repo.insertFolders(SnippetXML.decode(try Data(contentsOf: url)))
                let snippetCount = imported.reduce(0) { $0 + $1.snippets.count }
                if imported.isEmpty {
                    importAlert = ImportAlert(
                        title: String(localized: "Nothing to Import", comment: "Snippet-import alert title when the file contains no folders"),
                        message: String(localized: "No snippet folders were found in this file.", comment: "Snippet-import alert message for an empty/childless file"))
                } else {
                    importAlert = ImportAlert(
                        title: String(localized: "Import Complete", comment: "Snippet-import alert title on success"),
                        message: String(localized: "Imported \(imported.count) folders and \(snippetCount) snippets.", comment: "Snippet-import success message with the imported folder and snippet counts"))
                }
            } catch {
                NSSound.beep()
                Self.log.error("snippet import failed: \(error.localizedDescription, privacy: .public)")
                importAlert = ImportAlert(
                    title: String(localized: "Import Failed", comment: "Snippet-import alert title when the file can't be parsed"),
                    message: error.localizedDescription)
            }
        }
    }
}

// MARK: - Folder detail

private struct FolderDetailView: View {
    let folder: SnippetFolder
    let repo: SnippetRepository

    @State private var title: String
    @State private var isEnabled: Bool

    init(folder: SnippetFolder, repo: SnippetRepository) {
        self.folder = folder
        self.repo = repo
        _title = State(initialValue: folder.title)
        _isEnabled = State(initialValue: folder.isEnabled)
    }

    var body: some View {
        Form {
            TextField("Folder Name", text: $title)
                .onChange(of: title) { _, newValue in
                    // Non-empty guard (design §3.5): don't persist a blank folder name, and store
                    // the trimmed value so stray leading/trailing whitespace isn't saved.
                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    try? repo.updateFolderTitle(id: folder.id, title: trimmed)
                }
            Toggle("Enabled", isOn: $isEnabled)
                .onChange(of: isEnabled) { _, newValue in try? repo.setFolderEnabled(newValue, id: folder.id) }
        }
        .formStyle(.grouped)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Snippet detail

private struct SnippetDetailView: View {
    let snippet: Snippet
    let otherFolders: [SnippetFolder]
    let repo: SnippetRepository
    let onMove: (SnippetFolder.ID) -> Void

    @State private var title: String
    @State private var content: String
    @State private var isEnabled: Bool

    init(snippet: Snippet, otherFolders: [SnippetFolder], repo: SnippetRepository,
         onMove: @escaping (SnippetFolder.ID) -> Void) {
        self.snippet = snippet
        self.otherFolders = otherFolders
        self.repo = repo
        self.onMove = onMove
        _title = State(initialValue: snippet.title)
        _content = State(initialValue: snippet.content)
        _isEnabled = State(initialValue: snippet.isEnabled)
    }

    var body: some View {
        Form {
            TextField("Title", text: $title)
                .onChange(of: title) { _, newValue in
                    // Mirror the folder-name guard (and the original, which rejected empty titles for
                    // both folders and snippets): skip persisting a blank/whitespace title, store trimmed.
                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    try? repo.updateSnippetTitle(id: snippet.id, title: trimmed)
                }
            Toggle("Enabled", isOn: $isEnabled)
                .onChange(of: isEnabled) { _, newValue in try? repo.setSnippetEnabled(newValue, id: snippet.id) }
            if !otherFolders.isEmpty {
                Menu("Move to Folder") {
                    ForEach(otherFolders) { folder in
                        Button { onMove(folder.id) } label: {
                            displayTitle(folder.title, placeholder: "untitled folder")
                        }
                    }
                }
            }
            Section("Content") {
                PlainTextEditor(text: $content)
                    .frame(minHeight: 220)
            }
        }
        .formStyle(.grouped)
        // Debounced content commit (§6 Q5): each edit restarts the task, persisting after a pause.
        .task(id: content) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            try? repo.updateSnippetContent(id: snippet.id, content: content)
        }
        .onDisappear {
            // Flush the latest content if the debounce hasn't fired (selection change / window close).
            try? repo.updateSnippetContent(id: snippet.id, content: content)
        }
    }
}

// MARK: - Plain-text editor (NSTextView bridge)

/// A plain-text editor with smart quotes/dashes, text replacement, spell- and grammar-checking all
/// disabled — snippet content must paste verbatim. Mirrors the original editor's NSTextView config.
private struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.string = text
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}

// MARK: - Export document

/// A minimal `FileDocument` wrapper so `.fileExporter` can write the codec's bytes.
struct SnippetsDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.xml] }

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
