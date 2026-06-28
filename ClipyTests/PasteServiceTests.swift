//
//  PasteServiceTests.swift
//  ClipyTests
//
//  The unit-testable slices of paste: the beta modifier-action decision and the decrypt-for-paste
//  payload assembly (every captured UTType, or plain-text-only). The actual pasteboard write +
//  CGEvent ⌘V touch the real system pasteboard / event system and are run-app verified, not here.
//

import AppKit
import CryptoKit
import Foundation
import SQLiteData
import Testing
@testable import Clipy

@MainActor
@Suite struct PasteServiceTests {
    private static let key = SymmetricKey(data: Data(repeating: 0x5C, count: 32))
    private var cipher: HistoryCipher { HistoryCipher(key: Self.key) }

    private func freshDefaults(_ configure: (UserDefaults) -> Void = { _ in }) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "ClipySiPaste-\(UUID().uuidString)")!
        DefaultsKeys.registerDefaults(in: defaults)
        configure(defaults)
        return defaults
    }

    /// A PasteService with stub gates and a throwaway blob dir — for betaAction tests, which read
    /// neither the DB nor any blob.
    private func service(_ defaults: UserDefaults) -> PasteService {
        PasteService(
            blobStore: EncryptedBlobStore(directory: FileManager.default.temporaryDirectory),
            settings: AppSettings(defaults: defaults),
            accessibility: AccessibilityService(trustedCheck: { _ in true }),
            frontmost: FrontmostAppGuard(provider: { "test" }),
            markSeen: {}
        )
    }

    // MARK: - Beta modifier actions

    @Test func normalWithoutModifiers() {
        // Default pastePlainText=true with modifier=command(0); with NO modifier held → normal.
        #expect(service(freshDefaults()).betaAction(modifiers: []) == .normal)
    }

    @Test func plainTextOnConfiguredModifier() {
        #expect(service(freshDefaults()).betaAction(modifiers: .command) == .plainText) // default modifier 0 = ⌘
    }

    @Test func deleteTakesPriorityOverPlainText() {
        let defaults = freshDefaults {
            $0.set(true, forKey: DefaultsKeys.deleteHistory)
            $0.set(2, forKey: DefaultsKeys.deleteHistoryModifier) // control
        }
        #expect(service(defaults).betaAction(modifiers: [.command, .control]) == .delete)
    }

    @Test func disabledTogglesYieldNormal() {
        let defaults = freshDefaults { $0.set(false, forKey: DefaultsKeys.pastePlainText) }
        #expect(service(defaults).betaAction(modifiers: .command) == .normal)
    }

    // MARK: - Payload assembly (decrypt-for-paste)

    @Test func payloadRestoresEveryRepresentation() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipySiPaste-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
            $0.historyCipher = cipher
            $0.date = .constant(Make.epoch)
        } operation: {
            let stringType = NSPasteboard.PasteboardType.string.rawValue
            let rtfType = NSPasteboard.PasteboardType.rtf.rawValue
            let blob = EncryptedBlobStore(directory: dir)
            let capture = CaptureService(settings: AppSettings(defaults: freshDefaults()), blobStore: blob)
            _ = try capture.capture(PasteboardContents(
                changeCount: 1,
                typeIdentifiers: [stringType, rtfType],
                dataByType: [stringType: Data("plain".utf8), rtfType: Data("rich".utf8)],
                frontmostBundleID: nil, sourceBundleID: nil))
            let clip = try #require(try ClipRepository().clips().first)

            let paste = PasteService(blobStore: blob, settings: AppSettings(defaults: freshDefaults()),
                                     accessibility: AccessibilityService(trustedCheck: { _ in true }),
                                     frontmost: FrontmostAppGuard(provider: { "x" }), markSeen: {})

            // Normal: primary + every secondary representation, each decrypted.
            let all = try paste.pasteboardPayload(forClipID: clip.id, plainTextOnly: false)
            #expect(Set(all.map(\.type)) == [stringType, rtfType])
            #expect(all.first { $0.type == stringType }?.data == Data("plain".utf8))
            #expect(all.first { $0.type == rtfType }?.data == Data("rich".utf8))

            // Plain-text-only: just the string representation.
            let plain = try paste.pasteboardPayload(forClipID: clip.id, plainTextOnly: true)
            #expect(plain.map(\.type) == [stringType])
            #expect(plain.first?.data == Data("plain".utf8))
        }
    }

    @Test func payloadThrowsForUnknownClip() throws {
        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
            $0.historyCipher = cipher
        } operation: {
            let paste = PasteService(
                blobStore: EncryptedBlobStore(directory: FileManager.default.temporaryDirectory),
                markSeen: {})
            #expect(throws: PasteService.PasteError.self) {
                try paste.pasteboardPayload(forClipID: UUID(), plainTextOnly: false)
            }
        }
    }

    // MARK: - History Manager actions — delete + GC

    @Test func deleteRemovesClipAndGCsBlobs() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipySiPaste-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
            $0.historyCipher = cipher
            $0.date = .constant(Make.epoch)
        } operation: {
            let stringType = NSPasteboard.PasteboardType.string.rawValue
            let blob = EncryptedBlobStore(directory: dir)
            let capture = CaptureService(settings: AppSettings(defaults: freshDefaults()), blobStore: blob)
            _ = try capture.capture(PasteboardContents(
                changeCount: 1, typeIdentifiers: [stringType],
                dataByType: [stringType: Data("gone".utf8)],
                frontmostBundleID: nil, sourceBundleID: nil))
            let clip = try #require(try ClipRepository().clips().first)
            #expect((try? blob.read(id: clip.dataPath)) != nil) // blob exists before delete

            let paste = PasteService(blobStore: blob, settings: AppSettings(defaults: freshDefaults()), markSeen: {})
            paste.delete(clipID: clip.id)

            #expect(try ClipRepository().clips().isEmpty)                     // row gone
            #expect(throws: (any Error).self) { try blob.read(id: clip.dataPath) } // blob GC'd
        }
    }

    @Test func deleteAllClearsHistoryAndGCsEveryBlob() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipySiPaste-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
            $0.historyCipher = cipher
            $0.date = .constant(Make.epoch)
        } operation: {
            let stringType = NSPasteboard.PasteboardType.string.rawValue
            let blob = EncryptedBlobStore(directory: dir)
            let capture = CaptureService(settings: AppSettings(defaults: freshDefaults()), blobStore: blob)
            for body in ["one", "two"] {
                _ = try capture.capture(PasteboardContents(
                    changeCount: 1, typeIdentifiers: [stringType],
                    dataByType: [stringType: Data(body.utf8)],
                    frontmostBundleID: nil, sourceBundleID: nil))
            }
            let paths = try ClipRepository().clips().map(\.dataPath)
            #expect(paths.count == 2)

            let paste = PasteService(blobStore: blob, settings: AppSettings(defaults: freshDefaults()), markSeen: {})
            paste.deleteAll()

            #expect(try ClipRepository().clips().isEmpty)
            for path in paths {
                #expect(throws: (any Error).self) { try blob.read(id: path) } // every blob GC'd
            }
        }
    }

    // MARK: - Snippet payload — plaintext content, no decryption

    @Test func snippetPayloadReturnsPlainTextContent() throws {
        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
        } operation: {
            let repo = SnippetRepository()
            let folder = try repo.insertFolder(title: "F")
            let snippet = try repo.insertSnippet(folderID: folder.id, title: "t", content: "snippet body")

            let paste = PasteService(
                blobStore: EncryptedBlobStore(directory: FileManager.default.temporaryDirectory),
                markSeen: {})
            let payloads = try paste.snippetPayload(forSnippetID: snippet.id)

            #expect(payloads.count == 1)
            #expect(payloads.first?.type == NSPasteboard.PasteboardType.string.rawValue)
            #expect(payloads.first?.data == Data("snippet body".utf8))
        }
    }

    @Test func snippetPayloadThrowsForUnknownSnippet() throws {
        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
        } operation: {
            let paste = PasteService(
                blobStore: EncryptedBlobStore(directory: FileManager.default.temporaryDirectory),
                markSeen: {})
            #expect(throws: PasteService.PasteError.self) {
                try paste.snippetPayload(forSnippetID: UUID())
            }
        }
    }
}
