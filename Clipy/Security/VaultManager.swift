//
//  VaultManager.swift
//  ClipySi — Apple Silicon rewrite
//
//  Holds the unlocked vault key in memory (never persisted) and derives/verifies it from the user's
//  passphrase via the shared core. This provides the mechanism only — there is no Settings unlock UI
//  and nothing calls this in the running app yet; the unlock flow and sync wiring come later. Kept as
//  an `actor` so the in-memory key has a single owner across concurrency domains.
//

import ClipySiCore
import CryptoKit
import Foundation

actor VaultManager {
    enum VaultError: Error { case wrongPassphrase }

    private var unlockedKey: VaultKey?

    /// The unlocked vault key, or nil while locked.
    var current: VaultKey? { unlockedKey }
    var isUnlocked: Bool { unlockedKey != nil }

    /// Derive the vault key from `passphrase` + `kdf`, verify it against `manifestJSON`
    /// (the `vault.json` bytes), cache it in memory, and return it. A wrong passphrase derives a
    /// key whose subkey can't open the verifier → `wrongPassphrase`. The transient derived bytes are
    /// zeroized after they are wrapped into the `SymmetricKey`.
    ///
    /// A later change will extract `kdf` from the manifest (today the caller passes it explicitly)
    /// and drive this from the Settings passphrase field.
    @discardableResult
    func unlock(passphrase: String, manifestJSON: Data, kdf: KdfDescriptorFfi) throws -> VaultKey {
        var keyBytes = try deriveVaultKey(passphrase: passphrase, kdf: kdf)
        defer { keyBytes.resetBytes(in: 0..<keyBytes.count) }
        guard try verifyPassphrase(vaultKey: keyBytes, manifestJson: manifestJSON) else {
            throw VaultError.wrongPassphrase
        }
        let key = VaultKey(SymmetricKey(data: keyBytes))
        unlockedKey = key
        return key
    }

    /// Forget the in-memory vault key.
    func lock() { unlockedKey = nil }
}
