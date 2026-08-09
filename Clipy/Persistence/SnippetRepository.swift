//
//  SnippetRepository.swift
//  ClipySi — Apple Silicon rewrite
//
//  Folder/snippet CRUD, reordering and cross-folder moves. Behavior mirrors the original
//  Clipy snippet repository (repos/Clipy/.../Repositories/SnippetRepository.swift): new
//  items append at the end (sortOrder = max + 1), reordering rewrites `sortOrder` to the
//  0-based array position, and a folder delete removes its snippets via ON DELETE CASCADE —
//  fixing the original's orphan bug (requirements FR-SNIP-1/3).
//
//  Note: our column is named `sortOrder` (the original Realm field was `index`); the value
//  semantics — 0-based, contiguous, ascending, per-folder for snippets — are preserved, and
//  the migration maps the old `index` onto `sortOrder`.
//

import Foundation
import SQLiteData

/// A folder together with its snippets (ordered by `sortOrder`). The aggregate read by the snippet
/// menu and the snippet editor, and produced by bulk XML import.
struct SnippetFolderDetail: Identifiable, Sendable {
    let folder: SnippetFolder
    let snippets: [Snippet]
    var id: SnippetFolder.ID { folder.id }
}

/// Input for `insertFolders` (bulk import): a folder title and its ordered snippet drafts.
struct SnippetFolderDraft: Sendable {
    let title: String
    let snippets: [SnippetDraft]
}

struct SnippetDraft: Sendable {
    let title: String
    let content: String
}

struct SnippetRepository {
    @Dependency(\.defaultDatabase) private var database

    // MARK: - Folders

    /// All folders, ordered by `sortOrder`.
    func folders() throws -> [SnippetFolder] {
        try database.read { db in
            try SnippetFolder.order(by: \.sortOrder).fetchAll(db)
        }
    }

    /// Every folder (ordered by `sortOrder`) with its snippets (ordered by `sortOrder`). The snippet
    /// menu and editor read this; enabled-filtering is applied by the consumer, not here.
    /// Two bounded queries, not one per folder (M-UI.11 P1): all snippets come in one ordered read
    /// and are grouped in memory — `Dictionary(grouping:)` preserves the fetch order per folder, so
    /// each folder's snippets stay `sortOrder`-ascending exactly as the per-folder queries returned.
    func fetchFolderDetails() throws -> [SnippetFolderDetail] {
        try database.read { db in
            let folders = try SnippetFolder.order(by: \.sortOrder).fetchAll(db)
            let snippetsByFolder = Dictionary(
                grouping: try Snippet.order(by: \.sortOrder).fetchAll(db),
                by: \.folderID)
            return folders.map { folder in
                SnippetFolderDetail(folder: folder, snippets: snippetsByFolder[folder.id] ?? [])
            }
        }
    }

    /// Bulk-appends folders (and their snippets) in one transaction — used by XML import.
    /// Folders append after the current max `sortOrder`; each folder's snippets get contiguous
    /// 0-based `sortOrder`. Imported folders/snippets are enabled (the XML format carries no enabled
    /// flag — design §2.8). Returns the inserted aggregates in input order.
    @discardableResult
    func insertFolders(_ drafts: [SnippetFolderDraft]) throws -> [SnippetFolderDetail] {
        try database.write { db in
            let baseOrder = (try SnippetFolder.fetchAll(db).map(\.sortOrder).max() ?? -1) + 1
            var details: [SnippetFolderDetail] = []
            for (folderOffset, draft) in drafts.enumerated() {
                let folder = SnippetFolder(
                    id: UUID(), title: draft.title,
                    sortOrder: baseOrder + folderOffset, isEnabled: true
                )
                try SnippetFolder.insert { folder }.execute(db)
                var snippets: [Snippet] = []
                for (snippetOffset, draft) in draft.snippets.enumerated() {
                    let snippet = Snippet(
                        id: UUID(), folderID: folder.id, title: draft.title,
                        content: draft.content, sortOrder: snippetOffset, isEnabled: true
                    )
                    try Snippet.insert { snippet }.execute(db)
                    snippets.append(snippet)
                }
                details.append(SnippetFolderDetail(folder: folder, snippets: snippets))
            }
            return details
        }
    }

    /// Appends a new folder at the end of the list.
    @discardableResult
    func insertFolder(title: String = "untitled folder") throws -> SnippetFolder {
        try database.write { db in
            let maxOrder = try SnippetFolder.fetchAll(db).map(\.sortOrder).max() ?? -1
            let folder = SnippetFolder(id: UUID(), title: title, sortOrder: maxOrder + 1, isEnabled: true)
            try SnippetFolder.insert { folder }.execute(db)
            return folder
        }
    }

    func updateFolderTitle(id: SnippetFolder.ID, title: String) throws {
        try database.write { db in
            try SnippetFolder.update { $0.title = title }.where { $0.id.eq(id) }.execute(db)
        }
    }

    func setFolderEnabled(_ isEnabled: Bool, id: SnippetFolder.ID) throws {
        try database.write { db in
            try SnippetFolder.update { $0.isEnabled = isEnabled }.where { $0.id.eq(id) }.execute(db)
        }
    }

    /// Rewrites every folder's `sortOrder` to its 0-based position in `orderedIDs`.
    func reorderFolders(_ orderedIDs: [SnippetFolder.ID]) throws {
        try database.write { db in
            for (position, id) in orderedIDs.enumerated() {
                try SnippetFolder.update { $0.sortOrder = position }.where { $0.id.eq(id) }.execute(db)
            }
        }
    }

    /// Deletes a folder and (via ON DELETE CASCADE) all of its snippets — no orphans.
    func deleteFolder(id: SnippetFolder.ID) throws {
        try database.write { db in
            try SnippetFolder.delete().where { $0.id.eq(id) }.execute(db)
        }
    }

    // MARK: - Snippets

    /// A single snippet by id (for paste).
    func snippet(id: Snippet.ID) throws -> Snippet? {
        try database.read { db in
            try Snippet.where { $0.id.eq(id) }.fetchOne(db)
        }
    }

    /// Snippets in a folder, ordered by `sortOrder`.
    func snippets(inFolder folderID: SnippetFolder.ID) throws -> [Snippet] {
        try database.read { db in
            try Snippet.where { $0.folderID.eq(folderID) }.order(by: \.sortOrder).fetchAll(db)
        }
    }

    /// Appends a new snippet at the end of its folder.
    @discardableResult
    func insertSnippet(folderID: SnippetFolder.ID,
                       title: String = "untitled snippet",
                       content: String = "") throws -> Snippet {
        try database.write { db in
            let maxOrder = try Snippet
                .where { $0.folderID.eq(folderID) }
                .fetchAll(db)
                .map(\.sortOrder).max() ?? -1
            let snippet = Snippet(
                id: UUID(), folderID: folderID, title: title,
                content: content, sortOrder: maxOrder + 1, isEnabled: true
            )
            try Snippet.insert { snippet }.execute(db)
            return snippet
        }
    }

    func updateSnippetTitle(id: Snippet.ID, title: String) throws {
        try database.write { db in
            try Snippet.update { $0.title = title }.where { $0.id.eq(id) }.execute(db)
        }
    }

    func updateSnippetContent(id: Snippet.ID, content: String) throws {
        try database.write { db in
            try Snippet.update { $0.content = content }.where { $0.id.eq(id) }.execute(db)
        }
    }

    func setSnippetEnabled(_ isEnabled: Bool, id: Snippet.ID) throws {
        try database.write { db in
            try Snippet.update { $0.isEnabled = isEnabled }.where { $0.id.eq(id) }.execute(db)
        }
    }

    /// Rewrites the `sortOrder` of the given snippets to their 0-based position in `orderedIDs`
    /// (used for drag-reordering within a folder).
    func reorderSnippets(_ orderedIDs: [Snippet.ID]) throws {
        try database.write { db in
            for (position, id) in orderedIDs.enumerated() {
                try Snippet.update { $0.sortOrder = position }.where { $0.id.eq(id) }.execute(db)
            }
        }
    }

    /// Moves a snippet into `folderID`, then re-indexes the destination folder to
    /// `destinationOrder` (0-based positions).
    func moveSnippet(id: Snippet.ID,
                     toFolder folderID: SnippetFolder.ID,
                     destinationOrder: [Snippet.ID]) throws {
        try database.write { db in
            try Snippet.update { $0.folderID = folderID }.where { $0.id.eq(id) }.execute(db)
            for (position, snippetID) in destinationOrder.enumerated() {
                try Snippet.update { $0.sortOrder = position }.where { $0.id.eq(snippetID) }.execute(db)
            }
        }
    }

    func deleteSnippet(id: Snippet.ID) throws {
        try database.write { db in
            try Snippet.delete().where { $0.id.eq(id) }.execute(db)
        }
    }
}
