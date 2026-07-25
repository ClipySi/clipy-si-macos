//
//  LocalFolderProvider.swift
//  ClipySi — Apple Silicon rewrite
//
//  The reference SyncProvider: a user-chosen folder (NAS, local disk, or a folder a tool like
//  iCloud Drive/Syncthing already syncs — ClipySi itself never talks to a network). Layout:
//
//      <chosen folder>/ClipySiVault/
//        vault.json            # VaultManifest (KDF + verifier; no key, no passphrase)
//        records/{id}.cclip    # live record envelopes
//        tombs/{id}.cclip      # tombstone envelopes (bodyless)
//        devices/{id}.json     # DeviceDescriptor (generic display name; last_seen heartbeats)
//
//  Hardening per design: directories 0700 / files 0600 (everything inside is
//  ciphertext or non-content metadata, but the folder may be group-readable by default); writes
//  are tmp-file + atomic rename (no torn reads for other devices); there is deliberately NO lock
//  file (locks don't propagate reliably across sync tools, and the merge rules converge
//  without one). Listing accepts only names that parse as a UUID (lowercased), which structurally
//  ignores sync-tool droppings like "x (conflicted copy).cclip".
//

import Foundation

struct LocalFolderProvider: SyncProvider {
    enum ProviderError: Error {
        case notFound(String)
        case invalidID(String)
        /// The namespace could not be enumerated completely, so its listing must NOT be read as
        /// "these are all the records that exist" (that reading drives the destructive branches).
        case incompleteListing(String)
    }

    private let vaultDirectory: URL

    /// `rootFolder` is the user-chosen folder; the vault lives in `ClipySiVault/` inside it.
    ///
    /// `createIfMissing` is false for every read-only use (status probes, unlock): creating the
    /// layout as a side effect of *looking* would write into whatever folder is configured, and
    /// would silently re-create an empty skeleton when the real vault is gone (unmounted volume,
    /// moved folder) — which reads back as "an empty vault", not as "the vault is missing".
    init(rootFolder: URL, createIfMissing: Bool = true) throws {
        self.vaultDirectory = rootFolder.appendingPathComponent("ClipySiVault", isDirectory: true)
        guard createIfMissing else { return }
        for sub in ["", "records", "tombs", "devices"] {
            let dir = sub.isEmpty ? vaultDirectory : vaultDirectory.appendingPathComponent(sub, isDirectory: true)
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    // MARK: Records

    func listRecordIDs() throws -> Set<String> { try listIDs(in: "records", suffix: ".cclip") }
    func readRecord(id: String) throws -> Data { try read(file(in: "records", id: id, suffix: ".cclip")) }
    func writeRecord(id: String, bytes: Data) throws {
        try writeAtomic(bytes, to: file(in: "records", id: id, suffix: ".cclip"))
    }
    func deleteRecord(id: String) throws { try deleteIfExists(file(in: "records", id: id, suffix: ".cclip")) }

    // MARK: Tombstones

    func listTombstoneIDs() throws -> Set<String> { try listIDs(in: "tombs", suffix: ".cclip") }
    func readTombstone(id: String) throws -> Data { try read(file(in: "tombs", id: id, suffix: ".cclip")) }
    func writeTombstone(id: String, bytes: Data) throws {
        try writeAtomic(bytes, to: file(in: "tombs", id: id, suffix: ".cclip"))
    }
    func deleteTombstone(id: String) throws { try deleteIfExists(file(in: "tombs", id: id, suffix: ".cclip")) }

    // MARK: Vault manifest

    func readVaultManifest() throws -> Data? {
        let url = vaultDirectory.appendingPathComponent("vault.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func writeVaultManifestIfAbsent(_ bytes: Data) throws -> Bool {
        let url = vaultDirectory.appendingPathComponent("vault.json", isDirectory: false)
        do {
            // `.withoutOverwriting` is the create-exclusive: a concurrent creator wins, we join.
            try bytes.write(to: url, options: .withoutOverwriting)
        } catch CocoaError.fileWriteFileExists {
            return false
        }
        restrictPermissions(url)
        return true
    }

    // MARK: Devices

    func listDeviceIDs() throws -> Set<String> { try listIDs(in: "devices", suffix: ".json") }
    func readDevice(id: String) throws -> Data { try read(file(in: "devices", id: id, suffix: ".json")) }
    func writeDevice(id: String, bytes: Data) throws {
        try writeAtomic(bytes, to: file(in: "devices", id: id, suffix: ".json"))
    }

    // MARK: - Private

    /// Filenames that parse as UUIDs (normalized lowercase). Anything else — conflicted copies,
    /// .DS_Store, tmp files mid-rename — is structurally not a record and is ignored.
    ///
    /// One kind of "anything else" must NOT be ignored: a cloud service that evicts a file's
    /// contents replaces it with a placeholder (iCloud Drive: `.<name>.icloud`) and the real name
    /// disappears from the directory. A namespace whose records are all evicted therefore lists as
    /// *empty* rather than failing — and the engine reads an empty listing as "these records no
    /// longer exist in the vault", which is what makes rejoin delete live history and GC drop
    /// tombstones other devices have not applied. Surface it as an error instead.
    private func listIDs(in subdirectory: String, suffix: String) throws -> Set<String> {
        let dir = vaultDirectory.appendingPathComponent(subdirectory, isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        var ids = Set<String>()
        for name in names {
            if name.hasSuffix(suffix), let uuid = UUID(uuidString: String(name.dropLast(suffix.count))) {
                ids.insert(uuid.uuidString.lowercased())
            } else if Self.isEvictedPlaceholder(name, suffix: suffix) {
                throw ProviderError.incompleteListing(subdirectory)
            }
        }
        return ids
    }

    /// `records/abc….cclip` evicted by iCloud Drive becomes `records/.abc….cclip.icloud`.
    private static func isEvictedPlaceholder(_ name: String, suffix: String) -> Bool {
        let stub = ".icloud"
        guard name.hasPrefix("."), name.hasSuffix(stub) else { return false }
        return String(name.dropLast(stub.count)).hasSuffix(suffix)
    }

    private func file(in subdirectory: String, id: String, suffix: String) throws -> URL {
        guard let uuid = UUID(uuidString: id) else { throw ProviderError.invalidID(subdirectory) }
        return vaultDirectory
            .appendingPathComponent(subdirectory, isDirectory: true)
            .appendingPathComponent(uuid.uuidString.lowercased() + suffix, isDirectory: false)
    }

    private func read(_ url: URL) throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProviderError.notFound(url.lastPathComponent)
        }
        return try Data(contentsOf: url)
    }

    /// tmp file in the same directory + rename: other devices (and sync tools watching the
    /// folder) only ever observe complete files.
    private func writeAtomic(_ bytes: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".tmp-" + UUID().uuidString, isDirectory: false)
        try bytes.write(to: tmp, options: [])
        restrictPermissions(tmp)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    private func deleteIfExists(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func restrictPermissions(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
