//
//  SyncCoordinator.swift
//  ClipySi — Apple Silicon rewrite
//
//  App-side glue between the Sync pane / AppDelegate and the SyncEngine (§9): owns the
//  unlocked vault key, the engine instance, and the periodic sync task. Vault setup runs here
//  (create = mint a KdfDescriptor + manifest into the folder; unlock = manifestKdf → derive →
//  verify), with the opt-in Keychain persistence of the DERIVED key (never the passphrase).
//  All content crypto stays in the engine/core — this type never sees clip plaintext, and it
//  never logs the passphrase, key, or folder path.
//

import ClipySiCore
import CryptoKit
import Foundation
import Observation
import OSLog
import SQLiteData // re-exports swift-dependencies

@MainActor
@Observable
final class SyncCoordinator {
    /// One app-wide instance (the pane and AppDelegate share state — there is exactly one engine).
    static let shared = SyncCoordinator()

    enum Status: Equatable {
        case off            // syncEnabled = false
        case needsFolder    // enabled but no folder chosen
        case needsVault     // folder has no vault.json yet (create flow)
        case locked         // vault exists; passphrase needed
        case ready          // unlocked; engine available
        case syncing
        case failed         // last session failed (next timer tick retries)
    }

    private(set) var status: Status = .off
    private(set) var lastSyncAt: Date?

    /// PBKDF2 iterations for newly created vaults (design floor).
    nonisolated static let kdfIterations: UInt32 = 600_000
    nonisolated static let minPassphraseLength = 12

    private static let logger = Logger(subsystem: "io.github.ponponusa.clipysi", category: "sync")

    private var engine: SyncEngine?
    private var timerTask: Task<Void, Never>?
    private let diagnostics: DiagnosticsRecorder

    init(diagnostics: DiagnosticsRecorder = .live) {
        self.diagnostics = diagnostics
    }

    // MARK: - State machine

    /// Re-derive the status from settings (+ Keychain, when opted in). Called at launch and after
    /// every pane action.
    func refresh() {
        let settings = AppSettings()
        guard settings.syncEnabled else {
            teardown(.off)
            return
        }
        guard let path = settings.syncFolderPath else {
            teardown(.needsFolder)
            return
        }
        // Probing must not write: creating `ClipySiVault/` here would drop a vault skeleton into
        // whatever folder happens to be configured, and would mask a vault that has gone missing
        // (unmounted volume, folder moved) as a folder that simply has no vault yet.
        guard let provider = try? LocalFolderProvider(rootFolder: URL(fileURLWithPath: path), createIfMissing: false) else {
            teardown(.failed)
            return
        }
        let existingManifest = (try? provider.readVaultManifest()).flatMap { $0 }
        guard existingManifest != nil else {
            teardown(.needsVault)
            return
        }
        if engine != nil {
            status = .ready
            startTimer()
            return
        }
        // Opt-in fast path: a previously saved derived key unlocks without a prompt.
        if settings.saveVaultKeyInKeychain, let saved = try? VaultKeyStore.load() {
            activate(vaultKey: saved, provider: provider)
            return
        }
        teardown(.locked)
    }

    /// Create a brand-new vault in the configured folder (or join a concurrently created one) and
    /// unlock with `passphrase`.
    func createVault(passphrase: String) throws {
        let provider = try currentProvider(createIfMissing: true)
        let salt = try CryptoRandom.bytes(16)
        let descriptor = KdfDescriptorFfi(
            kind: .pbkdf2HmacSha256(iterations: Self.kdfIterations), salt: salt, kdfVersion: 1
        )
        var keyBytes = try deriveVaultKey(passphrase: passphrase, kdf: descriptor)
        defer { keyBytes.resetBytes(in: 0..<keyBytes.count) } // zeroize on EVERY exit, incl. the join fallback
        let manifest = try makeVaultManifest(
            vaultKey: keyBytes,
            vaultId: UUID().uuidString.lowercased(),
            createdAt: Int64(Date().timeIntervalSince1970),
            kdf: descriptor,
            verifierNonce: try CryptoRandom.bytes()
        )
        if try provider.writeVaultManifestIfAbsent(manifest) {
            try finishUnlock(keyBytes: keyBytes, provider: provider)
        } else {
            // Another device created the vault first: join it with the same passphrase.
            try unlock(passphrase: passphrase)
        }
    }

    /// Unlock the folder's existing vault with `passphrase` (manifestKdf → derive → verify).
    func unlock(passphrase: String) throws {
        let provider = try currentProvider()
        guard let manifestJSON = try provider.readVaultManifest() else {
            throw VaultManager.VaultError.wrongPassphrase
        }
        let descriptor = try manifestKdf(manifestJson: manifestJSON)
        let keyBytes = try deriveVaultKey(passphrase: passphrase, kdf: descriptor)
        guard try verifyPassphrase(vaultKey: keyBytes, manifestJson: manifestJSON) else {
            throw VaultManager.VaultError.wrongPassphrase
        }
        try finishUnlock(keyBytes: keyBytes, provider: provider)
    }

    /// Forget the in-memory key (and the Keychain copy when the user opts out).
    func lock(forgetKeychain: Bool = false) {
        if forgetKeychain {
            try? VaultKeyStore.delete()
        }
        teardown(.locked)
        refresh()
    }

    /// Run one sync session now (pane button / timer).
    func syncNow() async {
        guard let engine, status == .ready || status == .failed else { return }
        status = .syncing
        do {
            _ = try await engine.syncNow(now: Date())
            lastSyncAt = Date()
            status = .ready
            diagnostics.record(.featureUsed(.sync))
        } catch {
            status = .failed
            diagnostics.record(.error(.sync, .ioFailure))
            // Log only the error TYPE: a CocoaError's localizedDescription can embed the folder path.
            Self.logger.warning("sync session failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    // MARK: - Private

    /// `createIfMissing` is true only for the create-vault flow — the one action whose whole
    /// purpose is to write the layout.
    private func currentProvider(createIfMissing: Bool = false) throws -> LocalFolderProvider {
        guard let path = AppSettings().syncFolderPath else {
            throw LocalFolderProvider.ProviderError.notFound("folder")
        }
        return try LocalFolderProvider(rootFolder: URL(fileURLWithPath: path), createIfMissing: createIfMissing)
    }

    private func finishUnlock(keyBytes: Data, provider: LocalFolderProvider) throws {
        var bytes = keyBytes
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        let vaultKey = VaultKey(SymmetricKey(data: bytes))
        if AppSettings().saveVaultKeyInKeychain {
            try? VaultKeyStore.save(vaultKey)
        }
        activate(vaultKey: vaultKey, provider: provider)
    }

    private func activate(vaultKey: VaultKey, provider: LocalFolderProvider) {
        guard let blobStore = try? EncryptedBlobStore.live() else {
            teardown(.failed)
            return
        }
        resetSyncStateIfVaultChanged(provider: provider)
        engine = SyncEngine(
            provider: provider,
            vaultKey: vaultKey,
            blobStore: blobStore,
            deviceID: DeviceIdentity.current()
        )
        status = .ready
        startTimer()
        Task { await syncNow() }
    }

    /// A different vault (new folder / recreated vault.json) must not inherit the old vault's
    /// applied set, clock, or cursor — otherwise rejoin would re-publish the old vault's records
    /// into the new one (integration review fix). Keyed by the manifest's vault_id.
    private func resetSyncStateIfVaultChanged(provider: LocalFolderProvider) {
        guard let manifestJSON = (try? provider.readVaultManifest()).flatMap({ $0 }),
              let object = try? JSONSerialization.jsonObject(with: manifestJSON) as? [String: Any],
              let vaultID = object["vault_id"] as? String
        else { return }
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: DefaultsKeys.syncVaultID)
        if previous != vaultID {
            if previous != nil {
                try? SyncStore().wipeAll()
            }
            defaults.set(vaultID, forKey: DefaultsKeys.syncVaultID)
        }
    }

    private func startTimer() {
        guard timerTask == nil else { return }
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = AppSettings().syncIntervalSeconds
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.syncNow()
            }
        }
    }

    private func teardown(_ newStatus: Status) {
        timerTask?.cancel()
        timerTask = nil
        engine = nil
        status = newStatus
    }
}

// MARK: - Folder heuristics / passphrase strength (pure, testable)

enum SyncFolderHints {
    /// Best-effort detection of folders that a cloud service syncs (the Sync pane shows a warning
    /// — never a block).
    static func looksCloudSynced(_ path: String) -> Bool {
        let markers = ["Mobile Documents", "/Dropbox", "/Google Drive", "/GoogleDrive", "/OneDrive", "/Box/"]
        return markers.contains { path.contains($0) }
    }
}

enum PassphraseStrength {
    /// 0...4 heuristic (length + character-class variety). Not zxcvbn — a coarse meter for the
    /// create-vault flow; the hard floor is `SyncCoordinator.minPassphraseLength`.
    static func score(_ passphrase: String) -> Int {
        guard !passphrase.isEmpty else { return 0 }
        var score = 0
        if passphrase.count >= SyncCoordinator.minPassphraseLength { score += 1 }
        if passphrase.count >= 20 { score += 1 }
        let hasLower = passphrase.rangeOfCharacter(from: .lowercaseLetters) != nil
        let hasUpper = passphrase.rangeOfCharacter(from: .uppercaseLetters) != nil
        if hasLower && hasUpper { score += 1 }
        let hasDigit = passphrase.rangeOfCharacter(from: .decimalDigits) != nil
        let hasOther = passphrase.rangeOfCharacter(from: .alphanumerics.inverted) != nil
        if hasDigit || hasOther { score += 1 }
        return score
    }
}
