//
//  VaultKeyStore.swift
//  ClipySi — Apple Silicon rewrite
//
//  Opt-in Keychain persistence for the DERIVED vault key — never the passphrase — so sync can
//  resume across launches without re-entering the passphrase every time (design;
//  the "unlock every launch" UX killer). Mirrors HistoryKeyStore: a generic-password item with
//  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (device-bound, never synced to iCloud).
//  Gated by the `clipySaveVaultKeyInKeychain` setting (default OFF); the Sync pane owns the
//  checkbox and calls `delete()` when the user opts back out.
//
//  Tests never call this — they construct VaultKey values directly (§10 / R7: no real Keychain).
//

import CryptoKit
import Foundation
import Security

enum VaultKeyStore {
    enum KeyError: Error, Equatable {
        case unexpectedStatus(OSStatus)
        case invalidData
    }

    /// Keychain service, namespaced by bundle id (like HistoryKeyStore) and distinct from the
    /// device-local history key's service — the two layers never share storage.
    static var defaultService: String {
        (Bundle.main.bundleIdentifier ?? "io.github.ponponusa.clipysi") + ".vaultKey"
    }
    static let defaultAccount = "vault-encryption-key"

    /// Persists the derived vault key (overwriting any previous one).
    static func save(_ key: VaultKey,
                     service: String = defaultService,
                     account: String = defaultAccount) throws {
        try delete(service: service, account: account)
        try key.withKeyBytes { data in
            let attributes: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecValueData as String: data
            ]
            let status = SecItemAdd(attributes as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw KeyError.unexpectedStatus(status)
            }
        }
    }

    /// The stored vault key, or nil if none was saved (or the user never opted in).
    static func load(service: String = defaultService,
                     account: String = defaultAccount) throws -> VaultKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, data.count == 32 else { throw KeyError.invalidData }
            return VaultKey(SymmetricKey(data: data))
        case errSecItemNotFound:
            return nil
        default:
            throw KeyError.unexpectedStatus(status)
        }
    }

    /// Removes the stored key (user opted out / vault reset). Missing item is not an error.
    static func delete(service: String = defaultService,
                       account: String = defaultAccount) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyError.unexpectedStatus(status)
        }
    }
}
