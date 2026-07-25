//
//  SyncEngineE2ETests.swift
//  ClipyTests
//
//  Two devices in one process (see SyncE2EHarness). Proves the design's done-criteria end to end:
//  round-trip, delete propagation, re-copy-after-tombstone, offline catch-up, cross-device dedupe,
//  the double security gate, no plaintext in the folder, and the zombie-prevention protocol
//  (stale rejoin after GC). Rejoin's safety guards live in SyncRejoinSafetyTests.
//

import ClipySiCore
import CryptoKit
import Foundation
import SQLiteData
import Testing
@testable import Clipy

@Suite struct SyncEngineE2ETests: SyncE2EHarness {
    // MARK: - Tests

    @Test func roundTripDeliversAcrossDevices() async throws {
        let world = try makeWorld()
        defer { world.cleanUp() }
        try await capture("hello clip", on: world.deviceA, at: day(0))

        let pushSummary = try await on(world.deviceA, at: day(0)) {
            try await world.deviceA.engine.syncNow(now: self.day(0))
        }
        #expect(pushSummary.pushed == 1)

        let pullSummary = try await on(world.deviceB, at: day(0)) {
            try await world.deviceB.engine.syncNow(now: self.day(0))
        }
        #expect(pullSummary.pulled == 1)

        let bTitles = try await titles(on: world.deviceB, at: day(0))
        #expect(bTitles == ["hello clip"], "B decrypts the pulled clip under ITS OWN local key")
        // The pulled blob round-trips through B's blob store too.
        let bClip = try await on(world.deviceB, at: day(0)) { try ClipRepository().clips()[0] }
        let blob = try await on(world.deviceB, at: day(0)) { try world.deviceB.blobStore.read(id: bClip.dataPath) }
        #expect(blob == Data("hello clip".utf8))
        #expect(bClip.originDeviceID == world.deviceA.deviceID, "origin attribution survives")
        #expect(bClip.syncState == "synced")
    }

    @Test func deletePropagates() async throws {
        let world = try makeWorld()
        defer { world.cleanUp() }
        let clip = try await capture("doomed", on: world.deviceA, at: day(0))
        _ = try await on(world.deviceA, at: day(0)) { try await world.deviceA.engine.syncNow(now: self.day(0)) }
        _ = try await on(world.deviceB, at: day(0)) { try await world.deviceB.engine.syncNow(now: self.day(0)) }

        // A deletes (soft — sync is conceptually ON) and publishes the tombstone.
        try await on(world.deviceA, at: day(1)) {
            for path in try ClipRepository().delete(id: clip.id, soft: true) {
                try? world.deviceA.blobStore.delete(id: path)
            }
        }
        let aSummary = try await on(world.deviceA, at: day(1)) { try await world.deviceA.engine.syncNow(now: self.day(1)) }
        #expect(aSummary.tombstonesPushed == 1)

        let bSummary = try await on(world.deviceB, at: day(1)) { try await world.deviceB.engine.syncNow(now: self.day(1)) }
        #expect(bSummary.tombstonesApplied == 1)
        let bTitles = try await titles(on: world.deviceB, at: day(1))
        #expect(bTitles.isEmpty, "deletion propagated to B")
    }

    @Test func recopyAfterTombstoneBecomesANewRecordEverywhere() async throws {
        let world = try makeWorld()
        defer { world.cleanUp() }
        let original = try await capture("phoenix", on: world.deviceA, at: day(0))
        _ = try await on(world.deviceA, at: day(0)) { try await world.deviceA.engine.syncNow(now: self.day(0)) }
        _ = try await on(world.deviceB, at: day(0)) { try await world.deviceB.engine.syncNow(now: self.day(0)) }

        // A deletes; both devices apply the tombstone.
        try await on(world.deviceA, at: day(1)) {
            _ = try ClipRepository().delete(id: original.id, soft: true)
        }
        _ = try await on(world.deviceA, at: day(1)) { try await world.deviceA.engine.syncNow(now: self.day(1)) }
        _ = try await on(world.deviceB, at: day(1)) { try await world.deviceB.engine.syncNow(now: self.day(1)) }

        // B re-copies the same content AFTER the tombstone applied → a brand-new record.
        let recopied = try await capture("phoenix", on: world.deviceB, at: day(2))
        #expect(recopied.id != original.id)
        _ = try await on(world.deviceB, at: day(2)) { try await world.deviceB.engine.syncNow(now: self.day(2)) }

        // A pulls: same content was wiped at day 1, but the new record post-dates the wipe → applies.
        let aSummary = try await on(world.deviceA, at: day(2)) { try await world.deviceA.engine.syncNow(now: self.day(2)) }
        #expect(aSummary.pulled == 1)
        let aTitles = try await titles(on: world.deviceA, at: day(2))
        #expect(aTitles == ["phoenix"], "the re-copy lives everywhere as a new record")
    }

    @Test func offlineBatchCatchesUp() async throws {
        let world = try makeWorld()
        defer { world.cleanUp() }
        // B captures three clips while "offline" (no sync sessions between).
        try await capture("one", on: world.deviceB, at: day(0))
        try await capture("two", on: world.deviceB, at: day(0).addingTimeInterval(60))
        try await capture("three", on: world.deviceB, at: day(0).addingTimeInterval(120))

        let bSummary = try await on(world.deviceB, at: day(1)) { try await world.deviceB.engine.syncNow(now: self.day(1)) }
        #expect(bSummary.pushed == 3)
        let aSummary = try await on(world.deviceA, at: day(1)) { try await world.deviceA.engine.syncNow(now: self.day(1)) }
        #expect(aSummary.pulled == 3)
        let aTitles = try await titles(on: world.deviceA, at: day(1))
        #expect(Set(aTitles) == ["one", "two", "three"])
    }

    @Test func independentCapturesOfSameContentDedupe() async throws {
        let world = try makeWorld()
        defer { world.cleanUp() }
        try await capture("same words", on: world.deviceA, at: day(0))
        try await capture("same words", on: world.deviceB, at: day(0))

        _ = try await on(world.deviceA, at: day(0)) { try await world.deviceA.engine.syncNow(now: self.day(0)) }
        _ = try await on(world.deviceB, at: day(0)) { try await world.deviceB.engine.syncNow(now: self.day(0)) }
        _ = try await on(world.deviceA, at: day(0)) { try await world.deviceA.engine.syncNow(now: self.day(0)) }

        let aTitles = try await titles(on: world.deviceA, at: day(0))
        let bTitles = try await titles(on: world.deviceB, at: day(0))
        #expect(aTitles == ["same words"], "A keeps exactly one visible copy")
        #expect(bTitles == ["same words"], "B keeps exactly one visible copy")
    }

    @Test func doubleGateKeepsSecretsOutOfTheFolder() async throws {
        var world = try makeWorld()
        defer { world.cleanUp() }
        world.deviceA.masker = MaskingService { MaskingResult(isSecret: $0.contains("ghp_"), display: $0) }

        let secret = try await capture("token ghp_abc123", on: world.deviceA, at: day(0))
        try await capture("public note", on: world.deviceA, at: day(0), syncEligible: false)

        let summary = try await on(world.deviceA, at: day(0)) { try await world.deviceA.engine.syncNow(now: self.day(0)) }
        #expect(summary.pushed == 0)
        #expect(summary.skippedByGate == 2, "secret + syncEligible=false both excluded")

        let recordIDs = try await on(world.deviceA, at: day(0)) {
            try LocalFolderProvider(rootFolder: world.folder).listRecordIDs()
        }
        #expect(recordIDs.isEmpty, "nothing reached the folder")
        let flagged = try await on(world.deviceA, at: day(0)) { try ClipRepository().clips().first { $0.id == secret.id } }
        #expect(flagged?.isSensitive == true, "gate hit recorded as isSensitive")
    }

    @Test func folderNeverContainsPlaintext() async throws {
        let world = try makeWorld()
        defer { world.cleanUp() }
        let marker = "UNIQUE-PLAINTEXT-MARKER-0xC0FFEE"
        try await capture(marker, on: world.deviceA, at: day(0), sourceBundle: "com.example.sourceapp")
        _ = try await on(world.deviceA, at: day(0)) { try await world.deviceA.engine.syncNow(now: self.day(0)) }

        // NSEnumerator iteration is unavailable in async contexts; collect paths synchronously.
        let allFiles = try FileManager.default.subpathsOfDirectory(atPath: world.folder.path)
            .map { world.folder.appendingPathComponent($0) }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
        var scanned = 0
        for url in allFiles {
            let bytes = try Data(contentsOf: url)
            scanned += 1
            #expect(bytes.range(of: Data(marker.utf8)) == nil, "plaintext title leaked into \(url.lastPathComponent)")
            #expect(bytes.range(of: Data("com.example.sourceapp".utf8)) == nil,
                    "source bundle leaked into \(url.lastPathComponent)")
        }
        #expect(scanned >= 2, "at least the record + device files were scanned")
    }

    @Test func gateBlockedClipSyncsOnceTheVerdictChanges() async throws {
        var world = try makeWorld()
        defer { world.cleanUp() }
        world.deviceA.masker = MaskingService { MaskingResult(isSecret: $0.contains("ghp_"), display: $0) }
        try await capture("ghp_blocked_then_cleared", on: world.deviceA, at: day(0))

        let blocked = try await on(world.deviceA, at: day(0)) { try await world.deviceA.engine.syncNow(now: self.day(0)) }
        #expect(blocked.skippedByGate == 1)
        #expect(blocked.pushed == 0)

        // The detector verdict changes (rules update / user rule removed): the cursor must NOT
        // have skipped past the blocked clip — the next session re-evaluates and pushes it.
        world.deviceA.masker = .identity
        let retried = try await on(world.deviceA, at: day(0)) { try await world.deviceA.engine.syncNow(now: self.day(0)) }
        #expect(retried.pushed == 1, "gate-blocked clip is re-considered, not skipped forever")
    }

    @Test func zombiePreventionAfterGcAndStaleRejoin() async throws {
        let world = try makeWorld()
        defer { world.cleanUp() }
        // Day 0: both devices share record X.
        let clip = try await capture("undead?", on: world.deviceA, at: day(0))
        _ = try await on(world.deviceA, at: day(0)) { try await world.deviceA.engine.syncNow(now: self.day(0)) }
        _ = try await on(world.deviceB, at: day(0)) { try await world.deviceB.engine.syncNow(now: self.day(0)) }

        // Day 1: A deletes X and publishes the tombstone. B goes offline (no more sessions).
        try await on(world.deviceA, at: day(1)) {
            _ = try ClipRepository().delete(id: clip.id, soft: true)
        }
        _ = try await on(world.deviceA, at: day(1)) { try await world.deviceA.engine.syncNow(now: self.day(1)) }

        // Day 40: A GCs the tombstone (age 39d > 35d retention; B is 40d-stale → ignored).
        let gcSummary = try await on(world.deviceA, at: day(40)) { try await world.deviceA.engine.syncNow(now: self.day(40)) }
        #expect(gcSummary.gcCount == 1, "tombstone GC'd once B no longer blocks")
        let provider = try LocalFolderProvider(rootFolder: world.folder)
        let tombsAfterGc = try provider.listTombstoneIDs()
        #expect(tombsAfterGc.isEmpty)

        // Day 40: B rejoins. X is absent from records AND tombs; B is stale → delete locally,
        // never re-publish. THE zombie test.
        _ = try await on(world.deviceB, at: day(40)) { try await world.deviceB.engine.syncNow(now: self.day(40)) }
        let bTitles = try await titles(on: world.deviceB, at: day(40))
        #expect(bTitles.isEmpty, "stale rejoin deletes the locally-held record")
        let records = try provider.listRecordIDs()
        #expect(records.isEmpty, "B did NOT resurrect the record into the folder")
    }
}
