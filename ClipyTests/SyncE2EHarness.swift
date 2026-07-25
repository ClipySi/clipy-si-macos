//
//  SyncE2EHarness.swift
//  ClipyTests
//
//  The two-device world the sync E2E suites run in: separate in-memory DBs, separate LOCAL
//  cipher keys and blob dirs, one shared vault key and one shared temp folder
//  (LocalFolderProvider). Lives outside the suites so each stays a readable size — conform a
//  `@Suite` to `SyncE2EHarness` and the helpers are available unqualified.
//

import ClipySiCore
import CryptoKit
import Foundation
import SQLiteData
import Testing
@testable import Clipy

struct SyncE2EDevice {
    let db: any DatabaseWriter
    let cipher: HistoryCipher
    let blobStore: EncryptedBlobStore
    let deviceID: String
    let engine: Clipy.SyncEngine // qualified: another imported module also names a SyncEngine
    var masker: MaskingService = .identity
}

struct SyncE2EWorld {
    let folder: URL
    var deviceA: SyncE2EDevice
    var deviceB: SyncE2EDevice

    func cleanUp() {
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.removeItem(at: deviceA.blobStore.directory)
        try? FileManager.default.removeItem(at: deviceB.blobStore.directory)
    }
}

protocol SyncE2EHarness {}

extension SyncE2EHarness {
    static var vaultKey: VaultKey { VaultKey(SymmetricKey(data: Data(repeating: 0x44, count: 32))) }
    static var textType: String { "public.utf8-plain-text" }

    func day(_ offset: Int) -> Date { Make.epoch.addingTimeInterval(TimeInterval(offset) * 86_400) }

    func makeDevice(folder: URL, keyByte: UInt8) throws -> SyncE2EDevice {
        let blobDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipySiE2E-\(UUID().uuidString)", isDirectory: true)
        let blobStore = EncryptedBlobStore(directory: blobDir)
        let deviceID = UUID().uuidString.lowercased()
        let engine = Clipy.SyncEngine(
            provider: try LocalFolderProvider(rootFolder: folder),
            vaultKey: Self.vaultKey,
            blobStore: blobStore,
            deviceID: deviceID
        )
        return SyncE2EDevice(
            db: try TestDatabase.make(),
            cipher: HistoryCipher(key: SymmetricKey(data: Data(repeating: keyByte, count: 32))),
            blobStore: blobStore,
            deviceID: deviceID,
            engine: engine
        )
    }

    func makeWorld() throws -> SyncE2EWorld {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipySiE2EVault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A session refuses to run against a folder with no `vault.json` (it cannot tell an empty
        // vault from a vault that is not there), so the world starts with one. The engine only
        // checks for its presence — the KDF/verifier fields are exercised by VaultKeyTests.
        _ = try LocalFolderProvider(rootFolder: folder)
            .writeVaultManifestIfAbsent(Data(#"{"format_version":1,"vault_id":"e2e"}"#.utf8))
        return SyncE2EWorld(
            folder: folder,
            deviceA: try makeDevice(folder: folder, keyByte: 0x0A),
            deviceB: try makeDevice(folder: folder, keyByte: 0x0B)
        )
    }

    /// Run `body` in `device`'s dependency world (its DB, local cipher, masker, clock).
    func on<T>(_ device: SyncE2EDevice, at now: Date, _ body: () async throws -> T) async throws -> T {
        try await withDependencies {
            $0.defaultDatabase = device.db
            $0.historyCipher = device.cipher
            $0.maskingService = device.masker
            $0.date = .constant(now)
        } operation: {
            try await body()
        }
    }

    /// Capture a text clip on a device (the minimal capture path: encrypted title + blob + row).
    @discardableResult
    func capture(_ text: String, on device: SyncE2EDevice, at now: Date,
                 syncEligible: Bool = true, sourceBundle: String? = nil) async throws -> Clip {
        try await on(device, at: now) {
            let data = Data(text.utf8)
            let blobPath = try device.blobStore.write(data)
            let clip = Clip(
                id: UUID(),
                contentHash: device.cipher.contentHash(CanonicalPayload.make([(Self.textType, data)])),
                titleCipher: try device.cipher.seal(data),
                primaryType: Self.textType,
                createdAt: now,
                isPinned: false,
                isColorCode: false,
                dataPath: blobPath,
                thumbnailID: nil,
                sourceBundle: sourceBundle,
                updatedAt: now,
                originDeviceID: device.deviceID,
                syncEligible: syncEligible
            )
            try ClipRepository().add(clip)
            return clip
        }
    }

    func titles(on device: SyncE2EDevice, at now: Date) async throws -> [String] {
        try await on(device, at: now) {
            try ClipRepository().clips().compactMap {
                String(data: try device.cipher.open($0.titleCipher), encoding: .utf8)
            }
        }
    }

    func removeFromVault(_ world: SyncE2EWorld, _ relativePath: String) throws {
        try FileManager.default.removeItem(
            at: world.folder.appendingPathComponent("ClipySiVault/\(relativePath)")
        )
    }
}
