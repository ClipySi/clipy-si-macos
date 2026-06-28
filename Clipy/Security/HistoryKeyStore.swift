//
//  HistoryKeyStore.swift
//  ClipySi — Apple Silicon rewrite
//
//  The 256-bit symmetric key that protects history at rest (R3, security-guidance.md §5).
//  Stored in the Keychain as a generic-password item with
//  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: device-bound (never synced to iCloud)
//  and readable from the background pasteboard poll after first unlock.
//
//  Tests never call this — they inject a fixed key via `\.historyCipher` so the real Keychain
//  is never touched (§10 / R7).
//

import CryptoKit
import Foundation
import Security

enum HistoryKeyStore {
    enum KeyError: Error, Equatable {
        case unexpectedStatus(OSStatus)
        case invalidData
    }

    /// Keychain service, namespaced by bundle id so the Debug build, a future Release build, and
    /// the shipping Clipy never share a key (mirrors the per-bundle data directory).
    static var defaultService: String {
        (Bundle.main.bundleIdentifier ?? "io.github.ponponusa.clipysi") + ".historyKey"
    }
    static let defaultAccount = "history-encryption-key"

    /// Returns the stored key, generating and persisting a fresh 256-bit key on first use.
    static func loadOrCreate(service: String = defaultService,
                             account: String = defaultAccount) throws -> SymmetricKey {
        if let existing = try load(service: service, account: account) {
            return existing
        }
        let key = SymmetricKey(size: .bits256) // CryptoKit uses a CSPRNG
        do {
            try store(key, service: service, account: account)
        } catch KeyError.unexpectedStatus(errSecDuplicateItem) {
            // Lost a race with another launch; read the winner.
            if let existing = try load(service: service, account: account) {
                return existing
            }
            throw KeyError.unexpectedStatus(errSecDuplicateItem)
        }
        return key
    }

    private static func load(service: String, account: String) throws -> SymmetricKey? {
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
            guard let data = item as? Data else { throw KeyError.invalidData }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        default:
            throw KeyError.unexpectedStatus(status)
        }
    }

    private static func store(_ key: SymmetricKey, service: String, account: String) throws {
        let data = key.withUnsafeBytes { Data($0) }
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
