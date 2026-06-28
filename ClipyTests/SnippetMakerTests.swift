//
//  SnippetMakerTests.swift
//  ClipyTests
//
//  The pure core of the History Manager's "Snippetize" action: clip → snippet draft (title +
//  plaintext content), non-text / decrypt-failure exclusion, the title-label guard, and the insert
//  path (including a brand-new folder). The folder-picker sheet and last-used-folder persistence are
//  run-app verified, not here.
//

import AppKit
import CryptoKit
import Foundation
import SQLiteData
import Testing
@testable import Clipy

@Suite struct SnippetMakerTests {
    private static let key = SymmetricKey(data: Data(repeating: 0x7A, count: 32))
    private var cipher: HistoryCipher { HistoryCipher(key: Self.key) }

    private func freshDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "ClipySiSnippet-\(UUID().uuidString)")!
        DefaultsKeys.registerDefaults(in: defaults)
        return defaults
    }

    /// Captures a single clip (real sealed title + encrypted blob) and returns its id + the maker.
    private func seed(_ contents: PasteboardContents,
                      blobDir: URL) throws -> (clipID: Clip.ID, maker: SnippetMaker) {
        let blob = EncryptedBlobStore(directory: blobDir)
        let capture = CaptureService(settings: AppSettings(defaults: freshDefaults()), blobStore: blob)
        _ = try capture.capture(contents)
        let clip = try #require(try ClipRepository().clips().first)
        return (clip.id, SnippetMaker(blobStore: blob))
    }

    private func textContents(_ body: String) -> PasteboardContents {
        let stringType = NSPasteboard.PasteboardType.string.rawValue
        return PasteboardContents(changeCount: 1, typeIdentifiers: [stringType],
                                  dataByType: [stringType: Data(body.utf8)],
                                  frontmostBundleID: nil, sourceBundleID: nil)
    }

    // MARK: - Title label (pure)

    @Test func titleUsesTrimmedFirstLine() {
        #expect(SnippetMaker.title(fromPreview: "  Hello World  \nsecond line") == "Hello World")
    }

    @Test func titleFallsBackWhenFirstLineIsBlank() {
        // A leading blank line (whitespace only) has no printable label → localized placeholder.
        #expect(SnippetMaker.title(fromPreview: "   \nbody") == "untitled snippet")
        #expect(SnippetMaker.title(fromPreview: "") == "untitled snippet")
    }

    @Test func titleIsCappedAtFiftyCharacters() {
        let long = String(repeating: "x", count: 200)
        #expect(SnippetMaker.title(fromPreview: long).count == 50)
    }

    // MARK: - Draft extraction

    @Test func draftExtractsFirstLineTitleAndFullContent() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipySiSnippet-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
            $0.historyCipher = cipher
            $0.date = .constant(Make.epoch)
        } operation: {
            let (clipID, maker) = try seed(textContents("Hello World\nsecond line"), blobDir: dir)
            let draft = try #require(try maker.draft(forClipID: clipID))
            #expect(draft.title == "Hello World")            // first line only
            #expect(draft.content == "Hello World\nsecond line") // full body preserved
        }
    }

    @Test func nonTextClipIsNotSnippetizable() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipySiSnippet-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
            $0.historyCipher = cipher
            $0.date = .constant(Make.epoch)
        } operation: {
            let tiff = NSPasteboard.PasteboardType.tiff.rawValue
            let contents = PasteboardContents(changeCount: 1, typeIdentifiers: [tiff],
                                              dataByType: [tiff: Data([0x4D, 0x4D, 0x00, 0x2A])],
                                              frontmostBundleID: nil, sourceBundleID: nil)
            let (clipID, maker) = try seed(contents, blobDir: dir)
            let draft = try maker.draft(forClipID: clipID)
            #expect(draft == nil)
            let snippet = try maker.snippetize(clipID: clipID, intoFolder: UUID())
            #expect(snippet == nil)
        }
    }

    @Test func undecryptableClipIsNotSnippetizable() throws {
        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
            $0.historyCipher = cipher
        } operation: {
            // Make.clip stores plaintext bytes in `titleCipher` (not a real seal), so the cipher can't
            // open it → decrypt failure → not snippetizable (and the missing blob is never read).
            let clip = Make.clip(title: "plaintext stand-in")
            try ClipRepository().add(clip)
            let maker = SnippetMaker(blobStore: EncryptedBlobStore(directory: FileManager.default.temporaryDirectory))
            let draft = try maker.draft(forClipID: clip.id)
            #expect(draft == nil)
        }
    }

    @Test func missingClipIsNotSnippetizable() throws {
        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
            $0.historyCipher = cipher
        } operation: {
            let maker = SnippetMaker(blobStore: EncryptedBlobStore(directory: FileManager.default.temporaryDirectory))
            let draft = try maker.draft(forClipID: UUID())
            #expect(draft == nil)
        }
    }

    // MARK: - Insert path

    @Test func snippetizeAppendsToExistingFolder() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipySiSnippet-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
            $0.historyCipher = cipher
            $0.date = .constant(Make.epoch)
        } operation: {
            let repo = SnippetRepository()
            let folder = try repo.insertFolder(title: "Saved")
            _ = try repo.insertSnippet(folderID: folder.id, title: "existing", content: "x") // pre-existing

            let (clipID, maker) = try seed(textContents("Captured body"), blobDir: dir)
            let snippet = try #require(try maker.snippetize(clipID: clipID, intoFolder: folder.id))

            #expect(snippet.title == "Captured body")
            #expect(snippet.content == "Captured body")
            let inFolder = try repo.snippets(inFolder: folder.id)
            #expect(inFolder.count == 2)
            #expect(inFolder.last?.id == snippet.id) // appended at the end
        }
    }

    @Test func snippetizeIntoNewlyCreatedFolder() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipySiSnippet-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
            $0.historyCipher = cipher
            $0.date = .constant(Make.epoch)
        } operation: {
            let repo = SnippetRepository()
            let (clipID, maker) = try seed(textContents("Body for new folder"), blobDir: dir)

            // Mirrors the sheet's "New folder…" path: create the folder, then snippetize into it.
            let folder = try repo.insertFolder(title: "Fresh Folder")
            let snippet = try #require(try maker.snippetize(clipID: clipID, intoFolder: folder.id))

            let inFolder = try repo.snippets(inFolder: folder.id)
            #expect(inFolder.map(\.id) == [snippet.id])
            #expect(inFolder.first?.content == "Body for new folder")
        }
    }
}
