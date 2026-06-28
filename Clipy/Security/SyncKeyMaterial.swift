//
//  SyncKeyMaterial.swift
//  ClipySi — Apple Silicon rewrite
//
//  The two key layers of the foundation freeze, kept as DISTINCT types so they can never be
//  confused at a seal/open call (design §4.1, security-guidance.md §3):
//
//   - `LocalHistoryKey`: the device-bound key (Keychain `…ThisDeviceOnly`, via HistoryKeyStore).
//     Protects the local DB's `titleCipher` and the on-disk blobs. NEVER exported or synced.
//   - `VaultKey`: derived from the user's passphrase (PBKDF2, in clipy-si-core). Protects SYNC
//     records (cclip). The same passphrase derives the same key on every device; it is held in
//     memory only and zeroized on lock — never persisted.
//
//  Neither exposes its raw `SymmetricKey`. Callers reach the bytes only through `withKeyBytes`,
//  which hands a transient copy to the Rust core and zeroizes it on the way out.
//  A code path therefore can't accidentally log the key or seal a sync record with the
//  local key (the types don't unify).
//

import CryptoKit
import Foundation
import Security

/// Cryptographically-secure random bytes from the OS. AES-GCM requires a unique nonce per
/// (key, message); the Rust core takes no RNG, so the shell supplies the nonce from here.
enum CryptoRandom {
    enum RandomError: Error { case failed }

    /// `count` random bytes (default 12 = an AES-GCM nonce).
    static func bytes(_ count: Int = 12) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw RandomError.failed }
        return data
    }
}

struct LocalHistoryKey: Sendable {
    private let key: SymmetricKey

    init(_ key: SymmetricKey) { self.key = key }

    func withKeyBytes<R>(_ body: (Data) throws -> R) rethrows -> R {
        try withZeroizingKeyBytes(key, body)
    }
}

struct VaultKey: Sendable {
    private let key: SymmetricKey

    init(_ key: SymmetricKey) { self.key = key }

    func withKeyBytes<R>(_ body: (Data) throws -> R) rethrows -> R {
        try withZeroizingKeyBytes(key, body)
    }
}

/// Hands `body` a transient byte copy of `key` and overwrites it with zeros afterward. One copy is
/// made (`Data($0)` over the key's raw bytes); `resetBytes` then zeros that single buffer in place
/// (its refcount is 1 by the time the defer runs). Best-effort given Swift `Data` semantics, but no
/// extra un-zeroized copy lingers.
private func withZeroizingKeyBytes<R>(_ key: SymmetricKey, _ body: (Data) throws -> R) rethrows -> R {
    var bytes = key.withUnsafeBytes { Data($0) }
    defer { bytes.resetBytes(in: 0..<bytes.count) }
    return try body(bytes)
}
