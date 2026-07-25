//
//  SyncRejoinSafetyTests.swift
//  ClipyTests
//
//  Rejoin is the one path that deletes local history and the one path that writes records back
//  into the vault, and it decides between them from a listing that can lie (an evicted cloud
//  folder, an unmounted volume, a vault that is simply not there enumerate the same as "empty").
//  These tests pin the guards that keep it from acting on what it cannot prove.
//

import ClipySiCore
import CryptoKit
import Foundation
import SQLiteData
import Testing
@testable import Clipy

@Suite struct SyncRejoinSafetyTests: SyncE2EHarness {
    /// Rejoin's Repush exists to restore records the provider lost — but only records THIS device
    /// published. A record pulled from another device that has since vanished from the vault was,
    /// in every realistic case, deleted at its origin (with its tombstone already GC'd). Pushing it
    /// back would resurrect it into the vault and onto every device that joins later.
    @Test func rejoinNeverRepublishesAnotherDevicesRecord() async throws {
        let world = try makeWorld()
        defer { world.cleanUp() }
        let clip = try await capture("A's clip", on: world.deviceA, at: day(0))
        _ = try await on(world.deviceA, at: day(0)) { try await world.deviceA.engine.syncNow(now: self.day(0)) }
        _ = try await on(world.deviceB, at: day(0)) { try await world.deviceB.engine.syncNow(now: self.day(0)) }
        #expect(try await titles(on: world.deviceB, at: day(0)) == ["A's clip"], "B pulled it")

        // The record leaves the vault (deleted at its origin, tombstone already GC'd).
        try removeFromVault(world, "records/\(clip.id.uuidString.lowercased()).cclip")

        // B is fresh, so rejoin takes the Repush branch — and must decline: B did not publish this.
        _ = try await on(world.deviceB, at: day(1)) { try await world.deviceB.engine.syncNow(now: self.day(1)) }

        let provider = try LocalFolderProvider(rootFolder: world.folder)
        #expect(try provider.listRecordIDs().isEmpty, "B did not push another device's record back")
        #expect(try await titles(on: world.deviceB, at: day(1)) == ["A's clip"], "and did not delete it either")
    }

    /// The other half of the same branch: a device DOES restore its own published record.
    @Test func rejoinRepublishesItsOwnRecordWhenTheProviderLosesIt() async throws {
        let world = try makeWorld()
        defer { world.cleanUp() }
        let clip = try await capture("mine", on: world.deviceA, at: day(0))
        _ = try await on(world.deviceA, at: day(0)) { try await world.deviceA.engine.syncNow(now: self.day(0)) }

        try removeFromVault(world, "records/\(clip.id.uuidString.lowercased()).cclip")

        let summary = try await on(world.deviceA, at: day(1)) {
            try await world.deviceA.engine.syncNow(now: self.day(1))
        }
        #expect(summary.pushed == 1, "the origin device restores its own record")
        let provider = try LocalFolderProvider(rootFolder: world.folder)
        #expect(try provider.listRecordIDs() == [clip.id.uuidString.lowercased()])
    }

    /// Which rejoin branch is safe is decided by our own freshness, read from `devices/{id}.json`.
    /// When that file cannot be read, freshness is unknown — and the old code defaulted to Repush,
    /// which resurrected records on any device whose descriptor happened to be missing. Neither
    /// branch may run; the next session, which has written a heartbeat, decides.
    @Test func rejoinDoesNothingWhileOwnFreshnessIsUnknown() async throws {
        let world = try makeWorld()
        defer { world.cleanUp() }
        let clip = try await capture("mine", on: world.deviceA, at: day(0))
        _ = try await on(world.deviceA, at: day(0)) { try await world.deviceA.engine.syncNow(now: self.day(0)) }

        let recordFile = "records/\(clip.id.uuidString.lowercased()).cclip"
        try removeFromVault(world, recordFile)
        try removeFromVault(world, "devices/\(world.deviceA.deviceID).json")

        let blind = try await on(world.deviceA, at: day(1)) {
            try await world.deviceA.engine.syncNow(now: self.day(1))
        }
        #expect(blind.pushed == 0, "no heartbeat to prove freshness → neither branch runs")
        #expect(try await titles(on: world.deviceA, at: day(1)) == ["mine"], "and nothing is deleted")

        // That session's heartbeat restores the evidence, so the next one can act.
        let informed = try await on(world.deviceA, at: day(2)) {
            try await world.deviceA.engine.syncNow(now: self.day(2))
        }
        #expect(informed.pushed == 1, "the skip costs one session, not the record")
    }

    /// An empty listing and an unreadable vault look identical from a filename diff, and the
    /// destructive branches act on the former. `vault.json` is what tells them apart.
    @Test func sessionRefusesToRunWhenTheVaultManifestIsGone() async throws {
        let world = try makeWorld()
        defer { world.cleanUp() }
        try await capture("keep me", on: world.deviceA, at: day(0))
        _ = try await on(world.deviceA, at: day(0)) { try await world.deviceA.engine.syncNow(now: self.day(0)) }

        // The folder is still there, but it is no longer the vault we joined.
        try removeFromVault(world, "vault.json")

        await #expect(throws: Clipy.SyncEngine.SessionError.self) {
            _ = try await on(world.deviceA, at: day(40)) {
                try await world.deviceA.engine.syncNow(now: self.day(40))
            }
        }
        #expect(try await titles(on: world.deviceA, at: day(40)) == ["keep me"], "history untouched")
    }

    /// The whole-session effect of the provider's eviction guard: a vault whose files a cloud
    /// service has evicted enumerates as empty, and both destructive branches key off exactly that
    /// emptiness. The session must stop instead — history kept, tombstones not GC'd.
    @Test func evictedVaultStopsTheSessionInsteadOfDeletingHistory() async throws {
        let world = try makeWorld()
        defer { world.cleanUp() }
        let kept = try await capture("still here", on: world.deviceA, at: day(0))
        let deleted = try await capture("delete me", on: world.deviceA, at: day(0))
        _ = try await on(world.deviceA, at: day(0)) { try await world.deviceA.engine.syncNow(now: self.day(0)) }
        try await on(world.deviceA, at: day(1)) { _ = try ClipRepository().delete(id: deleted.id, soft: true) }
        _ = try await on(world.deviceA, at: day(1)) { try await world.deviceA.engine.syncNow(now: self.day(1)) }

        let provider = try LocalFolderProvider(rootFolder: world.folder)
        #expect(try provider.listRecordIDs() == [kept.id.uuidString.lowercased()])
        #expect(try provider.listTombstoneIDs().count == 1)

        // The cloud evicts every record: the real names leave the directory, placeholders remain.
        let recordsDir = world.folder.appendingPathComponent("ClipySiVault/records", isDirectory: true)
        for name in try FileManager.default.contentsOfDirectory(atPath: recordsDir.path) {
            let file = recordsDir.appendingPathComponent(name)
            try FileManager.default.moveItem(at: file, to: recordsDir.appendingPathComponent(".\(name).icloud"))
        }

        // Day 40: stale device, empty-looking vault — the exact shape that used to hard-delete the
        // local history and GC the tombstone.
        await #expect(throws: LocalFolderProvider.ProviderError.self) {
            _ = try await on(world.deviceA, at: day(40)) {
                try await world.deviceA.engine.syncNow(now: self.day(40))
            }
        }
        #expect(try await titles(on: world.deviceA, at: day(40)) == ["still here"], "history survives")
        #expect(try provider.listTombstoneIDs().count == 1, "tombstone not GC'd on a broken listing")
    }
}
