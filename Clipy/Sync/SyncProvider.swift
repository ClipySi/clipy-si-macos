//
//  SyncProvider.swift
//  ClipySi — Apple Silicon rewrite
//
//  The sync transport abstraction (design §6). Ships exactly one implementation
//  (LocalFolderProvider); additional providers can implement the same surface. The shape follows
//  the Rev 2 pull model: live records and tombstones live in SEPARATE namespaces whose listings
//  alone (ids, no file reads) tell the engine what changed — pull is a filename-set diff against
//  the local applied set, immune to out-of-order file arrival.
//
//  Ids are lowercase UUID strings. Providers must validate names on listing (a file that doesn't
//  parse as a UUID — e.g. a sync tool's "conflicted copy" — is not a record and is ignored).
//

import Foundation

protocol SyncProvider: Sendable {
    // MARK: Records (live)
    func listRecordIDs() throws -> Set<String>
    func readRecord(id: String) throws -> Data
    func writeRecord(id: String, bytes: Data) throws
    func deleteRecord(id: String) throws

    // MARK: Tombstones
    func listTombstoneIDs() throws -> Set<String>
    func readTombstone(id: String) throws -> Data
    func writeTombstone(id: String, bytes: Data) throws
    func deleteTombstone(id: String) throws

    // MARK: Vault manifest
    func readVaultManifest() throws -> Data?
    /// Creates `vault.json` only if none exists yet; returns false when one was already there
    /// (the caller should then read and join the existing vault).
    func writeVaultManifestIfAbsent(_ bytes: Data) throws -> Bool

    // MARK: Devices
    func listDeviceIDs() throws -> Set<String>
    func readDevice(id: String) throws -> Data
    func writeDevice(id: String, bytes: Data) throws
}
