//
//  CaptureServiceTests.swift
//  ClipyTests
//
//  Exercises the security-critical capture gates with stub pasteboard contents — never touches
//  NSPasteboard.general or the real Keychain (security-guidance.md §10 / R7).
//

import AppKit
import CryptoKit
import Foundation
import SQLiteData
import Testing
@testable import Clipy

@Suite struct CaptureServiceTests {
    private static let testKey = SymmetricKey(data: Data(repeating: 0x07, count: 32))
    private var referenceCipher: HistoryCipher { HistoryCipher(key: Self.testKey) }

    /// Wires an in-memory DB, a fixed cipher, a constant clock, a fresh defaults suite, and a
    /// temp blob directory, then runs `body` inside that dependency scope.
    private func run(
        configure: (UserDefaults) -> Void = { _ in },
        body: (CaptureService, ClipRepository, EncryptedBlobStore, URL) throws -> Void
    ) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipySiCapture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = UserDefaults(suiteName: "ClipySiCapture-\(UUID().uuidString)")!
        DefaultsKeys.registerDefaults(in: defaults)
        configure(defaults)

        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
            $0.historyCipher = HistoryCipher(key: Self.testKey)
            $0.date = .constant(Make.epoch)
        } operation: {
            let blob = EncryptedBlobStore(directory: dir)
            let service = CaptureService(settings: AppSettings(defaults: defaults), blobStore: blob)
            try body(service, ClipRepository(), blob, dir)
        }
    }

    private func text(_ string: String,
                      changeCount: Int = 1,
                      extraTypes: [String] = [],
                      frontmost: String? = nil,
                      source: String? = nil) -> PasteboardContents {
        let stringType = NSPasteboard.PasteboardType.string.rawValue
        return PasteboardContents(
            changeCount: changeCount,
            typeIdentifiers: [stringType] + extraTypes,
            dataByType: [stringType: Data(string.utf8)],
            frontmostBundleID: frontmost,
            sourceBundleID: source
        )
    }

    // MARK: - Stores

    @Test func storesPlainTextWithEncryptedTitle() throws {
        try run { service, repo, _, _ in
            let outcome = try service.capture(text("hello world"))
            guard case .stored = outcome else { Issue.record("expected .stored, got \(outcome)"); return }
            let clip = try #require(try repo.clips().first)
            #expect(clip.titleCipher != Data("hello world".utf8))                          // not plaintext
            #expect(try referenceCipher.open(clip.titleCipher) == Data("hello world".utf8)) // round-trips
        }
    }

    @Test func storedBlobDecryptsToPayload() throws {
        try run { service, repo, blob, _ in
            _ = try service.capture(text("payload-bytes"))
            let clip = try #require(try repo.clips().first)
            let decrypted = try blob.read(id: clip.dataPath)
            #expect(decrypted == Data("payload-bytes".utf8))
        }
    }

    @Test func recordsSourceBundle() throws {
        try run { service, repo, _, _ in
            _ = try service.capture(text("x", source: "com.example.writer"))
            let clip = try repo.clips().first
            #expect(clip?.sourceBundle == "com.example.writer")
        }
    }

    @Test func detectsColorCode() throws {
        try run { service, repo, _, _ in
            _ = try service.capture(text("#ff0000"))
            let clip = try repo.clips().first
            #expect(clip?.isColorCode == true)
        }
    }

    // MARK: - Multi-representation archiving (paste fidelity)

    private func stringType() -> String { NSPasteboard.PasteboardType.string.rawValue }
    private func rtfType() -> String { NSPasteboard.PasteboardType.rtf.rawValue }

    /// A clip carrying a plain-text + RTF representation (string is the highest-priority → primary).
    private func stringAndRTF(_ text: String, changeCount: Int = 1) -> PasteboardContents {
        PasteboardContents(
            changeCount: changeCount,
            typeIdentifiers: [stringType(), rtfType()],
            dataByType: [stringType(): Data(text.utf8), rtfType(): Data("{\\rtf1 \(text)}".utf8)],
            frontmostBundleID: nil,
            sourceBundleID: nil
        )
    }

    @Test func storesEverySecondaryRepresentationAsItsOwnEncryptedBlob() throws {
        try run { service, repo, blob, _ in
            _ = try service.capture(stringAndRTF("hello"))
            let clip = try #require(try repo.clips().first)

            // Primary = string → Clip.dataPath.
            #expect(clip.primaryType == stringType())
            #expect(try blob.read(id: clip.dataPath) == Data("hello".utf8))

            // Secondary = RTF → a clipRepresentation row with its own (non-plaintext) blob.
            let reps = try repo.representations(forClipID: clip.id)
            #expect(reps.count == 1)
            let rtf = try #require(reps.first)
            #expect(rtf.uttype == rtfType())
            #expect(rtf.dataPath != clip.dataPath)
            #expect(try blob.read(id: rtf.dataPath) == Data("{\\rtf1 hello}".utf8))
        }
    }

    @Test func dedupeDropCleansUpAllRepresentationBlobs() throws {
        try run(configure: { $0.set(false, forKey: DefaultsKeys.copySameHistory) }, body: { service, repo, _, dir in
            _ = try service.capture(stringAndRTF("dup"))                 // stored: 2 blobs
            let outcome = try service.capture(stringAndRTF("dup", changeCount: 2)) // dropped
            #expect(outcome == .skippedDuplicate)
            #expect(try repo.count() == 1)
            // Only the first capture's 2 blobs survive — the dropped capture's primary AND rtf
            // blobs were cleaned up (no orphaned ciphertext).
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 2)
        })
    }

    @Test func trimGarbageCollectsRepresentationBlobs() throws {
        try run(configure: { $0.set(1, forKey: DefaultsKeys.maxHistorySize) }, body: { service, repo, _, dir in
            _ = try service.capture(stringAndRTF("a", changeCount: 1))   // 2 blobs
            _ = try service.capture(stringAndRTF("b", changeCount: 2))   // 2 blobs; trim to 1 drops "a"
            #expect(try repo.count() == 1)
            // "a"'s primary + rtf blobs GC'd by trim; only "b"'s 2 blobs remain.
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 2)
        })
    }

    // MARK: - Privacy gates (R1)

    @Test func skipsTransient() throws {
        try run { service, repo, _, _ in
            let outcome = try service.capture(text("secret", extraTypes: [PrivacyMarkers.transient]))
            let count = try repo.count()
            #expect(outcome == .skippedPrivacy)
            #expect(count == 0)
        }
    }

    @Test func skipsConcealed() throws {
        try run { service, repo, _, _ in
            let outcome = try service.capture(text("pw", extraTypes: [PrivacyMarkers.concealed]))
            let count = try repo.count()
            #expect(outcome == .skippedConcealed)
            #expect(count == 0)
        }
    }

    // MARK: - Other gates

    @Test func skipsExcludedApp() throws {
        try run { service, repo, _, _ in
            try ExcludeAppRepository().add(bundleIdentifier: "com.secret.app", name: "Secret")
            let outcome = try service.capture(text("x", frontmost: "com.secret.app"))
            let count = try repo.count()
            #expect(outcome == .skippedExcludedApp)
            #expect(count == 0)
        }
    }

    @Test func skipsEmptyString() throws {
        try run { service, repo, _, _ in
            let outcome = try service.capture(text(""))
            let count = try repo.count()
            #expect(outcome == .skippedEmpty)
            #expect(count == 0)
        }
    }

    @Test func skipsWhenStoreTypeDisabled() throws {
        try run(configure: { $0.set(["String": false], forKey: DefaultsKeys.storeTypes) }, body: { service, repo, _, _ in
            let outcome = try service.capture(text("hi"))
            let count = try repo.count()
            #expect(outcome == .skippedNoStorableType)
            #expect(count == 0)
        })
    }

    // MARK: - Dedupe & cap

    @Test func dedupeDefaultMovesExistingToTop() throws {
        try run { service, repo, _, _ in
            let outcome = try service.capture(text("dup"))
            guard case let .stored(first) = outcome else { Issue.record("expected .stored, got \(outcome)"); return }
            let second = try service.capture(text("dup", changeCount: 2))
            let count = try repo.count()
            #expect(second == .stored(first)) // same id reused, no duplicate
            #expect(count == 1)
        }
    }

    @Test func dedupeDropsAndDoesNotLeakBlobWhenCopySameHistoryFalse() throws {
        try run(configure: { $0.set(false, forKey: DefaultsKeys.copySameHistory) }, body: { service, repo, _, dir in
            _ = try service.capture(text("dup"))
            let second = try service.capture(text("dup", changeCount: 2))
            let count = try repo.count()
            let blobCount = try FileManager.default.contentsOfDirectory(atPath: dir.path).count
            #expect(second == .skippedDuplicate)
            #expect(count == 1)
            #expect(blobCount == 1) // dropped capture's fresh blob cleaned up
        })
    }

    @Test func enforcesHistoryCapAndGarbageCollectsBlobs() throws {
        try run(configure: { $0.set(2, forKey: DefaultsKeys.maxHistorySize) }, body: { service, repo, _, dir in
            _ = try service.capture(text("a1", changeCount: 1))
            _ = try service.capture(text("a2", changeCount: 2))
            _ = try service.capture(text("a3", changeCount: 3))
            let count = try repo.count()
            let blobCount = try FileManager.default.contentsOfDirectory(atPath: dir.path).count
            #expect(count == 2)
            #expect(blobCount == 2) // trimmed clip's blob removed, not leaked
        })
    }
}
