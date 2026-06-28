//
//  EncryptedBlobStoreTests.swift
//  ClipyTests
//

import CryptoKit
import Foundation
import SQLiteData
import Testing
@testable import Clipy

@Suite struct EncryptedBlobStoreTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipySiBlobs-\(UUID().uuidString)", isDirectory: true)
    }

    private func withStore(_ body: (EncryptedBlobStore, URL) throws -> Void) throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try withDependencies {
            $0.historyCipher = HistoryCipher(key: SymmetricKey(data: Data(repeating: 0x33, count: 32)))
        } operation: {
            try body(EncryptedBlobStore(directory: dir), dir)
        }
    }

    @Test func writeReadRoundTrips() throws {
        try withStore { store, _ in
            let identifier = try store.write(Data("hello".utf8))
            #expect(try store.read(id: identifier) == Data("hello".utf8))
        }
    }

    @Test func diskBytesAreCiphertextNotPlaintext() throws {
        try withStore { store, dir in
            let secret = Data("ON-DISK-SECRET-XYZ".utf8)
            let identifier = try store.write(secret)
            let onDisk = try Data(contentsOf: dir.appendingPathComponent(identifier))
            #expect(onDisk.range(of: secret) == nil)
            #expect(onDisk != secret)
        }
    }

    @Test func deleteRemovesBlob() throws {
        try withStore { store, _ in
            let identifier = try store.write(Data("bye".utf8))
            try store.delete(id: identifier)
            #expect(throws: EncryptedBlobStore.BlobError.self) { try store.read(id: identifier) }
        }
    }

    @Test func readingMissingBlobThrows() throws {
        try withStore { store, _ in
            #expect(throws: EncryptedBlobStore.BlobError.self) { try store.read(id: "does-not-exist") }
        }
    }

    @Test func deletingMissingBlobIsNoOp() throws {
        try withStore { store, _ in
            try store.delete(id: "does-not-exist") // must not throw
        }
    }
}
