//
//  EncryptedBlobStore.swift
//  ClipySi — Apple Silicon rewrite
//
//  On-disk store for encrypted clip payloads / thumbnails (R3, security-guidance.md §5). Each
//  blob is AES-GCM ciphertext (via `\.historyCipher`); only metadata lives in the DB. The DB's
//  `dataPath`/`thumbnailID` reference blobs here.
//
//  At-rest protection on macOS is the AES-GCM ciphertext itself, plus directory 0700 / file
//  0600 and backup exclusion. (`URLFileProtection.complete` is an iOS-style attribute that a
//  Developer-ID Mac app generally can't apply; the encryption is what guarantees no plaintext
//  on disk.)
//

import Foundation
import SQLiteData // re-exports swift-dependencies (@Dependency)

struct EncryptedBlobStore: Sendable {
    enum BlobError: Error { case notFound }

    @Dependency(\.historyCipher) private var cipher
    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// `<App Support>/<bundle-id>/blobs`, isolated per bundle id like the database.
    static func defaultDirectory() throws -> URL {
        let appID = Bundle.main.bundleIdentifier ?? "io.github.ponponusa.clipysi"
        return try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        .appendingPathComponent(appID, isDirectory: true)
        .appendingPathComponent("blobs", isDirectory: true)
    }

    static func live() throws -> EncryptedBlobStore {
        EncryptedBlobStore(directory: try defaultDirectory())
    }

    /// Encrypts and writes `plaintext` under `id`; returns `id` (the value to store in `dataPath`
    /// / `thumbnailID`). `id` must be a single path component (e.g. a UUID string).
    @discardableResult
    func write(_ plaintext: Data, id: String = UUID().uuidString) throws -> String {
        try ensureDirectory()
        let url = directory.appendingPathComponent(id, isDirectory: false)
        try cipher.seal(plaintext).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        excludeFromBackup(url)
        return id
    }

    /// Reads and decrypts the blob stored under `id`.
    func read(id: String) throws -> Data {
        let url = directory.appendingPathComponent(id, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { throw BlobError.notFound }
        return try cipher.open(try Data(contentsOf: url))
    }

    /// Size in bytes of the stored ciphertext file, or nil when absent — read WITHOUT decrypting.
    /// AES-GCM framing adds a small constant (nonce + tag), so callers can approximate the plaintext
    /// size for display (preview metadata) with zero key use.
    func ciphertextSize(id: String) -> Int? {
        let url = directory.appendingPathComponent(id, isDirectory: false)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue
    }

    /// Deletes the blob under `id` if present (no-op otherwise).
    func delete(id: String) throws {
        let url = directory.appendingPathComponent(id, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - Private

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
