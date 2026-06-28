//
//  SnippetRepositoryTests.swift
//  ClipyTests
//

import Foundation
import SQLiteData
import Testing
@testable import Clipy

@Suite struct SnippetRepositoryTests {

    @Test func insertFolderAppendsWithIncreasingSortOrder() throws {
        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
        } operation: {
            let repo = SnippetRepository()
            let folderA = try repo.insertFolder(title: "A")
            let folderB = try repo.insertFolder(title: "B")

            #expect(folderA.sortOrder == 0)
            #expect(folderB.sortOrder == 1)
            #expect(try repo.folders().map(\.title) == ["A", "B"])
        }
    }

    @Test func insertSnippetUsesPerFolderSortOrder() throws {
        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
        } operation: {
            let repo = SnippetRepository()
            let folderA = try repo.insertFolder(title: "A")
            let folderB = try repo.insertFolder(title: "B")

            let snipA0 = try repo.insertSnippet(folderID: folderA.id, title: "a0")
            let snipA1 = try repo.insertSnippet(folderID: folderA.id, title: "a1")
            let snipB0 = try repo.insertSnippet(folderID: folderB.id, title: "b0")

            #expect(snipA0.sortOrder == 0)
            #expect(snipA1.sortOrder == 1)
            #expect(snipB0.sortOrder == 0) // per-folder, not global
            #expect(try repo.snippets(inFolder: folderA.id).map(\.title) == ["a0", "a1"])
        }
    }

    @Test func reorderFoldersRewritesSortOrder() throws {
        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
        } operation: {
            let repo = SnippetRepository()
            let folderA = try repo.insertFolder(title: "A")
            let folderB = try repo.insertFolder(title: "B")
            let folderC = try repo.insertFolder(title: "C")

            try repo.reorderFolders([folderC.id, folderA.id, folderB.id])
            #expect(try repo.folders().map(\.title) == ["C", "A", "B"])
        }
    }

    @Test func reorderSnippetsRewritesSortOrder() throws {
        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
        } operation: {
            let repo = SnippetRepository()
            let folder = try repo.insertFolder()
            let snip0 = try repo.insertSnippet(folderID: folder.id, title: "s0")
            let snip1 = try repo.insertSnippet(folderID: folder.id, title: "s1")

            try repo.reorderSnippets([snip1.id, snip0.id])
            #expect(try repo.snippets(inFolder: folder.id).map(\.title) == ["s1", "s0"])
        }
    }

    @Test func moveSnippetAcrossFoldersAndReindexes() throws {
        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
        } operation: {
            let repo = SnippetRepository()
            let src = try repo.insertFolder(title: "src")
            let dst = try repo.insertFolder(title: "dst")
            let moving = try repo.insertSnippet(folderID: src.id, title: "moving")
            let existing = try repo.insertSnippet(folderID: dst.id, title: "existing")

            try repo.moveSnippet(id: moving.id, toFolder: dst.id, destinationOrder: [moving.id, existing.id])

            #expect(try repo.snippets(inFolder: src.id).isEmpty)
            #expect(try repo.snippets(inFolder: dst.id).map(\.title) == ["moving", "existing"])
        }
    }

    @Test func deleteFolderCascadesAndLeavesNoOrphans() throws {
        let db = try TestDatabase.make()
        try withDependencies {
            $0.defaultDatabase = db
        } operation: {
            let repo = SnippetRepository()
            let folder = try repo.insertFolder()
            try repo.insertSnippet(folderID: folder.id, title: "s0")
            try repo.insertSnippet(folderID: folder.id, title: "s1")
            #expect(try db.read { try Snippet.fetchCount($0) } == 2)

            try repo.deleteFolder(id: folder.id)

            #expect(try repo.snippets(inFolder: folder.id).isEmpty)
            #expect(try db.read { try Snippet.fetchCount($0) } == 0) // no orphans anywhere
            #expect(try repo.folders().isEmpty)
        }
    }

    @Test func updatesTitleContentAndEnabled() throws {
        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
        } operation: {
            let repo = SnippetRepository()
            let folder = try repo.insertFolder()
            let snippet = try repo.insertSnippet(folderID: folder.id)

            try repo.updateSnippetTitle(id: snippet.id, title: "renamed")
            try repo.updateSnippetContent(id: snippet.id, content: "body")
            try repo.setSnippetEnabled(false, id: snippet.id)
            try repo.updateFolderTitle(id: folder.id, title: "folder!")
            try repo.setFolderEnabled(false, id: folder.id)

            let stored = try repo.snippets(inFolder: folder.id).first
            #expect(stored?.title == "renamed")
            #expect(stored?.content == "body")
            #expect(stored?.isEnabled == false)
            #expect(try repo.folders().first?.title == "folder!")
            #expect(try repo.folders().first?.isEnabled == false)
        }
    }

    // MARK: - Bulk insert + folder-detail aggregate

    @Test func insertFoldersBulkAppendsWithContiguousOrders() throws {
        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
        } operation: {
            let repo = SnippetRepository()
            try repo.insertFolder(title: "existing") // sortOrder 0

            let details = try repo.insertFolders([
                SnippetFolderDraft(title: "F1", snippets: [
                    SnippetDraft(title: "s0", content: "a"),
                    SnippetDraft(title: "s1", content: "b")
                ]),
                SnippetFolderDraft(title: "F2", snippets: [])
            ])

            #expect(details.map(\.folder.title) == ["F1", "F2"])
            #expect(details[0].folder.sortOrder == 1) // appended after the existing folder
            #expect(details[1].folder.sortOrder == 2)
            #expect(details[0].snippets.map(\.sortOrder) == [0, 1]) // contiguous, per-folder
            #expect(details[0].snippets.map(\.content) == ["a", "b"])
            #expect(details[0].folder.isEnabled == true) // imports are enabled
            #expect(try repo.folders().map(\.title) == ["existing", "F1", "F2"])
        }
    }

    @Test func fetchFolderDetailsGroupsSnippetsByFolderInOrder() throws {
        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
        } operation: {
            let repo = SnippetRepository()
            let folderA = try repo.insertFolder(title: "A")
            let folderB = try repo.insertFolder(title: "B")
            try repo.insertSnippet(folderID: folderA.id, title: "a0")
            try repo.insertSnippet(folderID: folderA.id, title: "a1")
            try repo.insertSnippet(folderID: folderB.id, title: "b0")

            let details = try repo.fetchFolderDetails()
            #expect(details.map(\.folder.title) == ["A", "B"])
            #expect(details[0].snippets.map(\.title) == ["a0", "a1"])
            #expect(details[1].snippets.map(\.title) == ["b0"])
        }
    }
}
