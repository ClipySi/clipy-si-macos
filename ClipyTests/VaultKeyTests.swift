//
//  VaultKeyTests.swift
//  ClipyTests
//
//  The two-layer key path: VaultManager (passphrase → vault key, verified) and RecordCodec
//  (seal/open a record under the VAULT key), plus the `isSensitive` capture wiring and the one-time
//  backfill. All exercise the distinct `VaultKey` / `LocalHistoryKey` types end to end.
//

import ClipySiCore
import CryptoKit
import Foundation
import SQLiteData
import Testing
@testable import Clipy

@Suite struct VaultKeyTests {
    private static let salt = Data("0123456789abcdef".utf8)

    private static func kdf() -> KdfDescriptorFfi {
        KdfDescriptorFfi(kind: .pbkdf2HmacSha256(iterations: 4096), salt: salt, kdfVersion: 1)
    }
    /// Builds a real vault.json (manifest) for `passphrase` and returns it with the matching key.
    private static func makeVault(passphrase: String) throws -> (manifest: Data, key: VaultKey) {
        let keyData = try deriveVaultKey(passphrase: passphrase, kdf: kdf())
        let nonce = try CryptoRandom.bytes()
        let manifest = try makeVaultManifest(
            vaultKey: keyData, vaultId: UUID().uuidString, createdAt: 0, kdf: kdf(), verifierNonce: nonce
        )
        return (manifest, VaultKey(SymmetricKey(data: keyData)))
    }

    private static func plaintext(_ title: String, bundle: String? = nil) -> RecordPlaintextFfi {
        RecordPlaintextFfi(
            title: title, primaryType: "public.utf8-plain-text", sourceBundle: bundle,
            isColorCode: false, representations: [RecordRepresentationFfi(uttype: "public.utf8-plain-text", data: Data(title.utf8))]
        )
    }

    // MARK: - VaultManager

    @Test func unlocksWithRightPassphraseAndSealsRecords() async throws {
        let vault = try Self.makeVault(passphrase: "correct horse battery staple")
        let manager = VaultManager()
        let key = try await manager.unlock(passphrase: "correct horse battery staple", manifestJSON: vault.manifest, kdf: Self.kdf())
        #expect(await manager.isUnlocked)

        let body = try RecordCodec.seal(Self.plaintext("hello"), with: key)
        #expect(try RecordCodec.open(body, with: key).title == "hello")

        await manager.lock()
        #expect(await manager.current == nil)
    }

    @Test func rejectsWrongPassphrase() async throws {
        let vault = try Self.makeVault(passphrase: "right")
        let manager = VaultManager()
        await #expect(throws: VaultManager.VaultError.self) {
            try await manager.unlock(passphrase: "wrong", manifestJSON: vault.manifest, kdf: Self.kdf())
        }
        #expect(await !manager.isUnlocked)
    }

    // MARK: - RecordCodec / key independence

    @Test func vaultSealHidesContentAndNeedsTheVaultKey() throws {
        let vault = try Self.makeVault(passphrase: "pw")
        let body = try RecordCodec.seal(Self.plaintext("secret-token", bundle: "com.example.app"), with: vault.key)
        // The ciphertext leaks neither the title nor the source bundle.
        #expect(body.range(of: Data("secret-token".utf8)) == nil)
        #expect(body.range(of: Data("com.example".utf8)) == nil)
        // A different vault key cannot open it (vault key is independent of any local key).
        let other = VaultKey(SymmetricKey(data: Data(repeating: 0x55, count: 32)))
        #expect(throws: (any Error).self) { try RecordCodec.open(body, with: other) }
    }

    @Test func syncHashIsDeterministicAndKeyed() throws {
        let vaultA = try Self.makeVault(passphrase: "a")
        let vaultB = try Self.makeVault(passphrase: "b")
        let payload = Data("public.utf8-plain-text\nhello".utf8)
        #expect(try RecordCodec.syncHash(forCanonicalPayload: payload, with: vaultA.key)
                == RecordCodec.syncHash(forCanonicalPayload: payload, with: vaultA.key)) // deterministic
        #expect(try RecordCodec.syncHash(forCanonicalPayload: payload, with: vaultA.key)
                != RecordCodec.syncHash(forCanonicalPayload: payload, with: vaultB.key)) // keyed by vault
    }

    // MARK: - isSensitive (capture wiring + backfill)

    private static let cipherKey = SymmetricKey(data: Data(repeating: 0x07, count: 32))
    /// A masking service that flags any title containing "ghp_" as secret.
    private static let flaggingMasker = MaskingService { MaskingResult(isSecret: $0.contains("ghp_"), display: $0) }

    @Test func captureStampsIsSensitiveFromDetector() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ClipySiSens-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = UserDefaults(suiteName: "ClipySiSens-\(UUID().uuidString)")!
        DefaultsKeys.registerDefaults(in: defaults)

        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
            $0.historyCipher = HistoryCipher(key: Self.cipherKey)
            $0.maskingService = Self.flaggingMasker
            $0.date = .constant(Make.epoch)
        } operation: {
            let service = CaptureService(settings: AppSettings(defaults: defaults), blobStore: EncryptedBlobStore(directory: dir))
            let repo = ClipRepository()

            let secret = PasteboardContents(changeCount: 1, typeIdentifiers: ["public.utf8-plain-text"],
                                            dataByType: ["public.utf8-plain-text": Data("ghp_abc123".utf8)], frontmostBundleID: nil, sourceBundleID: nil)
            _ = try service.capture(secret)
            #expect(try #require(try repo.clips().first).isSensitive == true)

            let normal = PasteboardContents(changeCount: 2, typeIdentifiers: ["public.utf8-plain-text"],
                                            dataByType: ["public.utf8-plain-text": Data("just text".utf8)], frontmostBundleID: nil, sourceBundleID: nil)
            _ = try service.capture(normal)
            #expect(try repo.clips().first(where: { (try? referenceTitle($0)) == "just text" })?.isSensitive == false)
        }
    }

    private func referenceTitle(_ clip: Clip) throws -> String? {
        String(data: try HistoryCipher(key: VaultKeyTests.cipherKey).open(clip.titleCipher), encoding: .utf8)
    }

    @Test func backfillFlagsPreExistingSecretRows() throws {
        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
            $0.historyCipher = HistoryCipher(key: Self.cipherKey)
            $0.maskingService = Self.flaggingMasker
        } operation: {
            let repo = ClipRepository()
            let cipher = HistoryCipher(key: Self.cipherKey)

            var secretClip = Make.clip(contentHash: "s")
            secretClip.titleCipher = try cipher.seal(Data("ghp_secret".utf8))
            try repo.add(secretClip)

            var normalClip = Make.clip(contentHash: "n")
            normalClip.titleCipher = try cipher.seal(Data("plain".utf8))
            try repo.add(normalClip)

            let updated = try IsSensitiveBackfill().run()
            #expect(updated == 1)
            #expect(try repo.clip(id: secretClip.id)?.isSensitive == true)
            #expect(try repo.clip(id: normalClip.id)?.isSensitive == false)
        }
    }

    // MARK: - Enterprise policy seam

    private struct DenyAllPolicy: PolicySource {
        func allowsCapture(frontmostBundleID: String?, sourceBundleID: String?) -> Bool { false }
    }

    @Test func managedPolicyCanBlockCapture() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ClipySiPol-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = UserDefaults(suiteName: "ClipySiPol-\(UUID().uuidString)")!
        DefaultsKeys.registerDefaults(in: defaults)

        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
            $0.historyCipher = HistoryCipher(key: Self.cipherKey)
            $0.date = .constant(Make.epoch)
        } operation: {
            let service = CaptureService(
                settings: AppSettings(defaults: defaults),
                blobStore: EncryptedBlobStore(directory: dir),
                policy: PolicyResolver(sources: [DenyAllPolicy()])
            )
            let contents = PasteboardContents(changeCount: 1, typeIdentifiers: ["public.utf8-plain-text"],
                                              dataByType: ["public.utf8-plain-text": Data("hi".utf8)], frontmostBundleID: nil, sourceBundleID: nil)
            let outcome = try service.capture(contents)
            #expect(outcome == .skippedByPolicy)
            let count = try ClipRepository().count()
            #expect(count == 0)
        }
    }
}
