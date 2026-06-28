//
//  SnippetizeSheet.swift
//  ClipySi — Apple Silicon rewrite
//
//  The "Snippetize" folder-picker sheet for the History Manager. Picks the destination folder,
//  creating a new one inline when needed. Folder reads/creation go straight through `SnippetRepository`
//  (no blob/crypto here — the actual clip→snippet conversion is `SnippetMaker`, wired from AppDelegate);
//  the chosen folder is remembered so the next snippetize pre-selects it.
//

import AppKit
import SQLiteData
import SwiftUI

/// The clip being snippetized, driving the folder-picker sheet (`item:`-bound so it carries the id).
struct SnippetizeTarget: Identifiable, Equatable {
    let id: Clip.ID
    let preview: String
}

struct SnippetizeSheet: View {
    let clipPreview: String
    let onAdd: (SnippetFolder.ID) -> Void
    let onCancel: () -> Void

    @FetchAll(SnippetFolder.order(by: \.sortOrder)) private var folders
    @AppStorage(DefaultsKeys.snippetizeLastFolder) private var lastFolderID = ""
    @State private var selection: SnippetFolder.ID?
    @State private var creatingNewFolder = false
    @State private var newFolderName = ""

    private let repo = SnippetRepository()

    // No folders yet → there's nothing to pick, so force inline creation.
    private var usingNewFolder: Bool { folders.isEmpty || creatingNewFolder }

    private var canAdd: Bool {
        usingNewFolder
            ? !newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            : selection != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add to Snippets").font(.headline)
            Text(clipPreview)
                .lineLimit(2)
                .font(.callout)
                .foregroundStyle(.secondary)
            Divider()

            if usingNewFolder {
                TextField("Folder name", text: $newFolderName)
                    .textFieldStyle(.roundedBorder)
                if !folders.isEmpty {
                    Button("Choose Existing Folder") { creatingNewFolder = false }
                        .buttonStyle(.link)
                }
            } else {
                Picker("Folder", selection: $selection) {
                    ForEach(folders) { folder in
                        Text(folder.title.isEmpty
                             ? String(localized: "untitled folder", comment: "Placeholder for an unnamed snippet folder")
                             : folder.title)
                            .tag(Optional(folder.id))
                    }
                }
                Button("New Folder…") { creatingNewFolder = true; newFolderName = "" }
                    .buttonStyle(.link)
            }

            Spacer()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
        }
        .padding(20)
        .frame(width: 380, height: 240)
        .onAppear { selection = defaultSelection() }
        .onChange(of: folders.map(\.id)) { if selection == nil { selection = defaultSelection() } }
    }

    /// The last-used folder if it still exists, otherwise the first folder.
    private func defaultSelection() -> SnippetFolder.ID? {
        if let last = UUID(uuidString: lastFolderID), folders.contains(where: { $0.id == last }) {
            return last
        }
        return folders.first?.id
    }

    private func add() {
        let folderID: SnippetFolder.ID?
        if usingNewFolder {
            let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            folderID = try? repo.insertFolder(title: name).id
        } else {
            folderID = selection
        }
        guard let folderID else { NSSound.beep(); return }
        lastFolderID = folderID.uuidString
        onAdd(folderID)
    }
}
