//
//  LocalFolderProviderTests.swift
//  ClipyTests
//
//  The reference SyncProvider over a temp folder: layout creation with restrictive
//  permissions, atomic write/read/list/delete round-trips, UUID-only listing (conflicted-copy
//  exclusion + case normalization), and create-exclusive vault.json semantics.
//

import Foundation
import Testing
@testable import Clipy

@Suite struct LocalFolderProviderTests {
    private func withProvider(_ body: (LocalFolderProvider, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipySiVaultTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let provider = try LocalFolderProvider(rootFolder: root)
        try body(provider, root.appendingPathComponent("ClipySiVault", isDirectory: true))
    }

    @Test func recordRoundTripAndDelete() throws {
        try withProvider { provider, _ in
            let id = "01020304-0506-0708-090a-0b0c0d0e0f10"
            let before = try provider.listRecordIDs()
            #expect(before.isEmpty)

            try provider.writeRecord(id: id, bytes: Data([1, 2, 3]))
            let listed = try provider.listRecordIDs()
            #expect(listed == [id])
            let bytes = try provider.readRecord(id: id)
            #expect(bytes == Data([1, 2, 3]))

            // Overwrite is atomic and replaces content.
            try provider.writeRecord(id: id, bytes: Data([9]))
            let overwritten = try provider.readRecord(id: id)
            #expect(overwritten == Data([9]))

            try provider.deleteRecord(id: id)
            let after = try provider.listRecordIDs()
            #expect(after.isEmpty)
            try provider.deleteRecord(id: id) // idempotent
        }
    }

    @Test func tombstoneAndDeviceNamespacesAreSeparate() throws {
        try withProvider { provider, _ in
            let id = "01020304-0506-0708-090a-0b0c0d0e0f10"
            try provider.writeTombstone(id: id, bytes: Data([7]))
            let tombs = try provider.listTombstoneIDs()
            #expect(tombs == [id])
            let records = try provider.listRecordIDs()
            #expect(records.isEmpty, "tombs don't leak into records")

            try provider.writeDevice(id: id, bytes: Data("{}".utf8))
            let devices = try provider.listDeviceIDs()
            #expect(devices == [id])
            let deviceBytes = try provider.readDevice(id: id)
            #expect(deviceBytes == Data("{}".utf8))
        }
    }

    @Test func listingIgnoresNonUUIDFilesAndNormalizesCase() throws {
        try withProvider { provider, vaultDir in
            let records = vaultDir.appendingPathComponent("records", isDirectory: true)
            // Sync-tool droppings and partial files must be invisible.
            try Data([0]).write(to: records.appendingPathComponent("notes (conflicted copy).cclip"))
            try Data([0]).write(to: records.appendingPathComponent(".tmp-garbage"))
            try Data([0]).write(to: records.appendingPathComponent(".DS_Store"))
            // An uppercase-named record (other implementation / case-insensitive FS) normalizes.
            try Data([5]).write(to: records.appendingPathComponent("AABBCCDD-0506-0708-090A-0B0C0D0E0F10.cclip"))

            let ids = try provider.listRecordIDs()
            #expect(ids == ["aabbccdd-0506-0708-090a-0b0c0d0e0f10"])
            let bytes = try provider.readRecord(id: "aabbccdd-0506-0708-090a-0b0c0d0e0f10")
            #expect(bytes == Data([5]))
        }
    }

    @Test func vaultManifestIsCreateExclusive() throws {
        try withProvider { provider, _ in
            let initial = try provider.readVaultManifest()
            #expect(initial == nil)
            let created = try provider.writeVaultManifestIfAbsent(Data("first".utf8))
            #expect(created == true)
            let again = try provider.writeVaultManifestIfAbsent(Data("second".utf8))
            #expect(again == false, "an existing vault wins; the caller joins it")
            let stored = try provider.readVaultManifest()
            #expect(stored == Data("first".utf8))
        }
    }

    @Test func permissionsAreRestrictive() throws {
        try withProvider { provider, vaultDir in
            let id = "01020304-0506-0708-090a-0b0c0d0e0f10"
            try provider.writeRecord(id: id, bytes: Data([1]))

            let dirAttrs = try FileManager.default.attributesOfItem(atPath: vaultDir.path)
            #expect((dirAttrs[.posixPermissions] as? Int) == 0o700)
            let fileURL = vaultDir.appendingPathComponent("records/\(id).cclip")
            let fileAttrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            #expect((fileAttrs[.posixPermissions] as? Int) == 0o600)
        }
    }

    @Test func invalidIDIsRejectedNotPathTraversed() throws {
        try withProvider { provider, _ in
            #expect(throws: (any Error).self) {
                try provider.writeRecord(id: "../escape", bytes: Data())
            }
            #expect(throws: (any Error).self) {
                _ = try provider.readRecord(id: "not-a-uuid")
            }
        }
    }
}
