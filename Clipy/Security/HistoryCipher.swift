//
//  HistoryCipher.swift
//  ClipySi — Apple Silicon rewrite
//
//  Field-level encryption primitives for history at rest (R3, security-guidance.md §5):
//   - `seal`/`open`: AES-GCM over arbitrary data (clip payloads, thumbnails, the `title`
//     preview that becomes `titleCipher`).
//   - `contentHash`: keyed HMAC-SHA256 used as the dedupe key, so the DB's `contentHash`
//     can't be used to confirm whether specific content was copied without the key.
//
//  The crypto is now the SINGLE shared implementation in clipy-si-core (Rust), reached via
//  the ClipySiCore binding, so every OS shell produces the same bytes. The wire format is
//  unchanged — AES-GCM `.combined` (`nonce ‖ ciphertext ‖ tag`) byte-compatible with the prior
//  CryptoKit path — so EXISTING users' blobs keep decrypting (proven by the interop KAT, the
//  kill-switch). The core takes no RNG: this shell supplies a fresh CSPRNG nonce per seal.
//
//  Exposed as a `\.historyCipher` dependency mirroring `\.defaultDatabase`: the live value is
//  Keychain-backed (cached once); tests inject a fixed-key cipher so the real Keychain is never
//  touched. The key is held as a `LocalHistoryKey` (distinct from `VaultKey`); the `init(key:)`
//  overload keeps the many `SymmetricKey`-based call sites/tests compiling.
//

import ClipySiCore
import CryptoKit
import Foundation
import OSLog
import SQLiteData // re-exports swift-dependencies (DependencyKey / DependencyValues)

struct HistoryCipher: Sendable {
    private let localKey: LocalHistoryKey

    init(_ localKey: LocalHistoryKey) { self.localKey = localKey }
    /// Back-compat: most call sites (and tests) hold a raw device-local `SymmetricKey`.
    init(key: SymmetricKey) { self.localKey = LocalHistoryKey(key) }

    /// AES-GCM encrypt → self-describing `.combined` box (nonce ‖ ciphertext ‖ tag).
    func seal(_ plaintext: Data) throws -> Data {
        let nonce = try CryptoRandom.bytes()
        return try localKey.withKeyBytes { keyBytes in
            try ClipySiCore.localSeal(key: keyBytes, nonce: nonce, plaintext: plaintext)
        }
    }

    /// AES-GCM decrypt a `.combined` box produced by `seal` (or by the prior CryptoKit path).
    func open(_ ciphertext: Data) throws -> Data {
        try localKey.withKeyBytes { keyBytes in
            try ClipySiCore.localOpen(key: keyBytes, combined: ciphertext)
        }
    }

    /// Keyed dedupe hash (lowercase hex). HMAC-SHA256 so the stored `contentHash` reveals
    /// nothing about the content to anyone without the key.
    func contentHash(_ payload: Data) -> String {
        localKey.withKeyBytes { keyBytes in
            ClipySiCore.contentHash(key: keyBytes, payload: payload)
        }
    }
}

extension HistoryCipher {
    /// Keychain-backed cipher, resolved once. If the Keychain is unavailable we log loudly and
    /// fall back to a process-ephemeral key so the app stays up — persisted history won't
    /// survive relaunch in that (rare) degraded state, which is preferable to crashing.
    static let live: HistoryCipher = {
        do {
            return HistoryCipher(key: try HistoryKeyStore.loadOrCreate())
        } catch {
            Logger(subsystem: "io.github.ponponusa.clipysi", category: "security")
                .error("history key unavailable, using ephemeral key: \(error.localizedDescription, privacy: .public)")
            return HistoryCipher(key: SymmetricKey(size: .bits256))
        }
    }()
}

private enum HistoryCipherKey: DependencyKey {
    static var liveValue: HistoryCipher { .live }
    /// Deterministic, Keychain-free key for tests/previews.
    static var testValue: HistoryCipher {
        HistoryCipher(key: SymmetricKey(data: Data(repeating: 0x2A, count: 32)))
    }
    static var previewValue: HistoryCipher { testValue }
}

extension DependencyValues {
    var historyCipher: HistoryCipher {
        get { self[HistoryCipherKey.self] }
        set { self[HistoryCipherKey.self] = newValue }
    }
}
