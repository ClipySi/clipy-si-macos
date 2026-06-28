//
//  SyncEngine.swift
//  ClipySi — Apple Silicon rewrite
//
//  Orchestrates one sync session over a SyncProvider (design §9 semantics):
//
//    pull   — filename-set diff against the local applied set (no cursor): tombstones FIRST
//             (unknown ones are recorded as applied-deleted = the transport-race zombie guard),
//             then unknown live records through merge_decide (sync_hash dedupe) and the
//             atomic apply paths. Decisions come from the Rust core; this actor only executes.
//    push   — never-published live clips (records are immutable once published) through the
//             double security gate, sealed under the VAULT key; then undistributed tombstones
//             (write tombs/{id}, remove records/{id}).
//    rejoin — own published records absent from BOTH listings: stale self deletes locally
//             (never re-publishes — the zombie guard), fresh self re-publishes (provider loss).
//    gc     — tombstone files past retention acked by every non-stale device are removed, and
//             only then is the local tombstone row purged (it backs dedupe-vs-wipe lookups).
//
//  Per-file failures are skipped (the next session retries — the applied set makes replay
//  idempotent); nothing here logs content, keys, or paths.
//

import ClipySiCore
import Foundation
import SQLiteData

/// What one sync session did (for tests / the Sync pane status line).
struct SyncSummary: Sendable, Equatable {
    var pulled = 0
    var tombstonesApplied = 0
    var pushed = 0
    var tombstonesPushed = 0
    var gcCount = 0
    var skippedByGate = 0
    var fileErrors = 0
}

actor SyncEngine {
    private let provider: any SyncProvider
    private let vaultKey: VaultKey
    private let blobStore: EncryptedBlobStore
    private let deviceID: String // lowercase UUID

    init(provider: any SyncProvider, vaultKey: VaultKey, blobStore: EncryptedBlobStore, deviceID: String) {
        self.provider = provider
        self.vaultKey = vaultKey
        self.blobStore = blobStore
        self.deviceID = deviceID.lowercased()
    }

    /// One full session: pull → rejoin → push → device heartbeat → GC. `now` is injectable for
    /// tests (zombie/GC scenarios need to travel through time).
    @discardableResult
    func syncNow(now: Date = Date()) throws -> SyncSummary {
        var summary = SyncSummary()
        let nowMillis = Int64(now.timeIntervalSince1970 * 1000)
        let nowSecs = Int64(now.timeIntervalSince1970)

        let recordIDs = try provider.listRecordIDs()
        let tombIDs = try provider.listTombstoneIDs()

        try pull(recordIDs: recordIDs, tombIDs: tombIDs, nowMillis: nowMillis, summary: &summary)
        try rejoin(recordIDs: recordIDs, tombIDs: tombIDs, nowMillis: nowMillis, nowSecs: nowSecs, summary: &summary)
        try push(now: now, nowMillis: nowMillis, summary: &summary)
        try touchDevice(nowSecs: nowSecs)
        try gc(nowSecs: nowSecs, summary: &summary)
        return summary
    }

    // MARK: - Pull

    private func pull(recordIDs: Set<String>, tombIDs: Set<String>, nowMillis: Int64, summary: inout SyncSummary) throws {
        let store = SyncStore()
        let repo = ClipRepository()
        let gate = SyncGate()

        // Tombstones FIRST: a tombstone seen before its live file can never resurrect.
        for id in tombIDs.sorted() {
            guard let header = try? readHeader(provider.readTombstone(id: id)) else {
                summary.fileErrors += 1
                continue
            }
            let local = try localState(recordID: id, syncHash: nil, store: store, repo: repo)
            switch try mergeDecide(local: local, remoteDeleted: true, remoteHlc: header.hlc) {
            case .applyTombstone:
                if let clipID = UUID(uuidString: id) {
                    let deletedAt = Date(timeIntervalSince1970: TimeInterval(header.updatedAt))
                    for path in try store.applyRemoteTombstone(clipID: clipID, hlc: header.hlc, deletedAt: deletedAt) {
                        try? blobStore.delete(id: path)
                    }
                    summary.tombstonesApplied += 1
                    try mergeClock(remote: header.hlc, nowMillis: nowMillis, store: store)
                }
            case .recordTombstoneOnly:
                try store.recordTombstoneOnly(recordID: id, hlc: header.hlc)
                try mergeClock(remote: header.hlc, nowMillis: nowMillis, store: store)
            default:
                break
            }
        }

        // Unknown live records.
        let appliedIDs = try appliedIDs(store: store)
        for id in recordIDs.sorted() where !appliedIDs.contains(id) {
            guard let bytes = try? provider.readRecord(id: id),
                  let envelope = try? decodeEnvelope(bytes: bytes),
                  envelope.header.deleted == false,
                  let body = envelope.body
            else {
                summary.fileErrors += 1
                continue
            }
            let header = envelope.header
            let local = try localState(recordID: id, syncHash: header.syncHash, store: store, repo: repo)
            switch try mergeDecide(local: local, remoteDeleted: false, remoteHlc: header.hlc) {
            case .applyRemote:
                switch try apply(header: header, body: body, gate: gate) {
                case .inserted: summary.pulled += 1
                case .dedupedLocally: break
                case .unusable: summary.fileErrors += 1
                }
            case .skipDuplicateContent, .skip:
                try store.recordApplied(recordID: id, hlc: header.hlc, deleted: false)
            default:
                break
            }
            try mergeClock(remote: header.hlc, nowMillis: nowMillis, store: store)
        }
    }

    private enum ApplyOutcome { case inserted, dedupedLocally, unusable }

    /// Re-encrypt an incoming plaintext under the LOCAL key and insert it (one tx with the
    /// applied set).
    private func apply(header: RecordHeaderFfi, body: Data, gate: SyncGate) throws -> ApplyOutcome {
        @Dependency(\.historyCipher) var cipher
        let plaintext = try RecordCodec.open(body, with: vaultKey)
        guard let clipID = UUID(uuidString: header.recordId), !plaintext.representations.isEmpty else {
            return .unusable
        }

        // Local-content dedupe: a not-yet-pushed local capture of the same content has no
        // syncHash, so the header-level dedupe can't see it — but the canonical bytes hash to the
        // same LOCAL contentHash. Suppress the insert and mark applied (the local copy will
        // publish under its own id).
        let canonical = RecordCodec.canonicalPayload(of: plaintext)
        let localHash = cipher.contentHash(canonical)
        if try ClipRepository().latestClip(forContentHash: localHash) != nil {
            try SyncStore().recordApplied(recordID: header.recordId.lowercased(), hlc: header.hlc, deleted: false)
            return .dedupedLocally
        }

        let primary = plaintext.representations.first { $0.uttype == plaintext.primaryType }
            ?? plaintext.representations[0]
        let primaryPath = try blobStore.write(primary.data)
        var freshBlobs = [primaryPath]
        var secondaries: [ClipRepresentation] = []
        for rep in plaintext.representations where !(rep.uttype == primary.uttype && rep.data == primary.data) {
            let path = try blobStore.write(rep.data)
            freshBlobs.append(path)
            secondaries.append(ClipRepresentation(clipID: clipID, uttype: rep.uttype, dataPath: path, byteSize: rep.data.count))
        }

        let clip = Clip(
            id: clipID,
            contentHash: localHash,
            titleCipher: try cipher.seal(Data(plaintext.title.utf8)),
            primaryType: plaintext.primaryType,
            createdAt: Date(timeIntervalSince1970: TimeInterval(header.createdAt)),
            isPinned: false,
            isColorCode: plaintext.isColorCode,
            dataPath: primaryPath,
            thumbnailID: nil,
            sourceBundle: plaintext.sourceBundle,
            updatedAt: Date(timeIntervalSince1970: TimeInterval(header.updatedAt)),
            originDeviceID: header.originDeviceId,
            recordVersion: Int(header.formatVersion),
            syncState: "synced",
            syncHash: header.syncHash,
            // Re-evaluate locally; never trust the publisher's verdict.
            isSensitive: gate.isSensitiveOnApply(decryptedTitle: plaintext.title)
        )
        do {
            try SyncStore().applyRemoteInsert(clip, representations: secondaries, hlc: header.hlc)
        } catch {
            for path in freshBlobs { try? blobStore.delete(id: path) }
            throw error
        }
        return .inserted
    }

    // MARK: - Rejoin (stale device / provider loss)

    private func rejoin(recordIDs: Set<String>, tombIDs: Set<String>, nowMillis: Int64, nowSecs: Int64, summary: inout SyncSummary) throws {
        let store = SyncStore()
        let repo = ClipRepository()
        let present = recordIDs.union(tombIDs)
        let missing = try store.appliedEntries().filter { !$0.deleted && !present.contains($0.recordID) }
        guard !missing.isEmpty else { return }

        let action: RejoinActionFfi
        if let lastSeen = try ownLastSeen() {
            action = rejoinAction(selfLastSeenSecs: lastSeen, nowSecs: nowSecs)
        } else {
            // No own heartbeat but a non-empty applied set: can't prove freshness either way —
            // prefer restoring the user's data (manual tampering is the realistic cause).
            action = .repush
        }

        for entry in missing {
            guard let clipID = UUID(uuidString: entry.recordID) else { continue }
            switch action {
            case .deleteLocally:
                // Remotely deleted while we were away; never re-publish (the zombie guard).
                for path in try repo.delete(id: clipID, soft: false) {
                    try? blobStore.delete(id: path)
                }
                try store.recordApplied(
                    recordID: entry.recordID,
                    hlc: HlcFfi(wallMillis: Int64(entry.hlcWall), counter: UInt32(entry.hlcCounter), node: entry.hlcNode),
                    deleted: true
                )
            case .repush:
                if let clip = try repo.clip(id: clipID) {
                    try publish(clip, nowMillis: nowMillis, summary: &summary)
                }
            }
        }
    }

    // MARK: - Push

    private func push(now: Date, nowMillis: Int64, summary: inout SyncSummary) throws {
        let store = SyncStore()
        let repo = ClipRepository()
        let cursor = Date(timeIntervalSince1970: TimeInterval(try cursorSeconds(store: store)))
        let appliedIDs = try appliedIDs(store: store)

        // New live records (published records are immutable, so applied ids skip).
        // The cursor only advances over rows that are settled (already applied or published this
        // session): a gate-blocked clip stays BELOW the cursor so it is re-evaluated every session
        // and syncs if the verdict ever changes (integration review fix).
        var maxUpdated = 0
        for clip in try repo.pushCandidates(updatedAtAtLeast: cursor) {
            let updatedSeconds = Int(clip.updatedAt.timeIntervalSince1970)
            if appliedIDs.contains(clip.id.uuidString.lowercased()) {
                maxUpdated = max(maxUpdated, updatedSeconds)
                continue
            }
            if try publish(clip, nowMillis: nowMillis, summary: &summary) {
                maxUpdated = max(maxUpdated, updatedSeconds)
            }
        }
        if maxUpdated > 0 {
            try setCursorSeconds(maxUpdated, store: store)
        }

        // Undistributed tombstones.
        for tomb in try repo.tombstones() {
            let id = tomb.id.uuidString.lowercased()
            let entry = try storeApplied(recordID: id, store: store)
            guard entry?.deleted != true else { continue } // already distributed / received
            let hlc = try nextClock(nowMillis: nowMillis, store: store)
            let bytes = try RecordCodec.makeTombstoneEnvelope(RecordCodec.EnvelopeMeta(
                recordID: id,
                originDeviceID: tomb.originDeviceID?.lowercased() ?? deviceID,
                hlc: hlc,
                createdAt: tomb.createdAt,
                updatedAt: tomb.deletedAt ?? now,
                syncHash: tomb.syncHash ?? ""
            ))
            try provider.writeTombstone(id: id, bytes: bytes)
            try provider.deleteRecord(id: id)
            try SyncStore().completeTombstonePush(clipID: tomb.id, hlc: hlc)
            summary.tombstonesPushed += 1
        }
    }

    /// Gate → seal under the vault key → write → mark published, for one live clip.
    /// Returns true only when the record actually reached the provider.
    @discardableResult
    private func publish(_ clip: Clip, nowMillis: Int64, summary: inout SyncSummary) throws -> Bool {
        @Dependency(\.historyCipher) var cipher
        let repo = ClipRepository()
        let store = SyncStore()
        let gate = SyncGate()

        let secondaries = try repo.representations(forClipID: clip.id)
        let plaintext: RecordPlaintextFfi
        do {
            plaintext = try RecordCodec.makePlaintext(
                for: clip, secondaries: secondaries, cipher: cipher, blobStore: blobStore
            )
        } catch {
            summary.fileErrors += 1
            return false
        }

        // Double gate: full decrypted text, fresh verdict, stored flags untrusted.
        let gateText = plaintext.representations
            .first { $0.uttype == "public.utf8-plain-text" }
            .flatMap { String(data: $0.data, encoding: .utf8) } ?? plaintext.title
        guard gate.allowsPush(syncEligible: clip.syncEligible, decryptedText: gateText) else {
            if !clip.isSensitive, gate.isSensitiveOnApply(decryptedTitle: gateText) {
                try? repo.setSensitive(true, id: clip.id)
            }
            summary.skippedByGate += 1
            return false
        }

        let id = clip.id.uuidString.lowercased()
        let hlc = try nextClock(nowMillis: nowMillis, store: store)
        let syncHash = try RecordCodec.syncHash(
            forCanonicalPayload: RecordCodec.canonicalPayload(of: plaintext), with: vaultKey
        )
        let body = try RecordCodec.seal(plaintext, with: vaultKey)
        let bytes = try RecordCodec.makeLiveEnvelope(RecordCodec.EnvelopeMeta(
            recordID: id,
            originDeviceID: clip.originDeviceID?.lowercased() ?? deviceID,
            hlc: hlc,
            createdAt: clip.createdAt,
            updatedAt: clip.updatedAt,
            syncHash: syncHash
        ), body: body)
        try provider.writeRecord(id: id, bytes: bytes)
        try store.completePush(clipID: clip.id, hlc: hlc, syncHash: syncHash)
        summary.pushed += 1
        return true
    }

    // MARK: - Device heartbeat / GC

    private func touchDevice(nowSecs: Int64) throws {
        // Generic display name: never the hostname.
        let descriptor: [String: Any] = [
            "format_version": 1,
            "device_id": deviceID,
            "display_name": "Mac-\(deviceID.suffix(4))",
            "platform": "macos",
            "last_seen": nowSecs
        ]
        let bytes = try JSONSerialization.data(withJSONObject: descriptor, options: [.sortedKeys])
        try provider.writeDevice(id: deviceID, bytes: bytes)
    }

    private func gc(nowSecs: Int64, summary: inout SyncSummary) throws {
        let repo = ClipRepository()
        // Orphan sweep: a deleting device that crashed between writeTombstone and deleteRecord
        // leaves a dead records/{id} behind. Any device may clean it (idempotent).
        let tombIDs = try provider.listTombstoneIDs()
        for id in try provider.listRecordIDs() where tombIDs.contains(id) {
            try? provider.deleteRecord(id: id)
        }
        var lastSeens: [Int64] = []
        for id in try provider.listDeviceIDs() {
            if let seen = try? deviceLastSeen(id: id) {
                lastSeens.append(seen)
            }
        }
        for id in try provider.listTombstoneIDs() {
            guard let header = try? readHeader(provider.readTombstone(id: id)) else { continue }
            guard try gcEligible(tombstoneHlc: header.hlc, devicesLastSeenSecs: lastSeens, nowSecs: nowSecs) else { continue }
            try provider.deleteTombstone(id: id)
            // Only now drop the local tombstone row — it backed dedupe-vs-wipe lookups while the
            // tombstone file lived. The applied-deleted entry stays (late-file zombie guard).
            if let clipID = UUID(uuidString: id) {
                try? repo.purgeTombstone(id: clipID)
            }
            summary.gcCount += 1
        }
    }

}

// MARK: - Small helpers

private extension SyncEngine {
    func readHeader(_ bytes: Data) throws -> RecordHeaderFfi {
        try decodeEnvelope(bytes: bytes).header
    }

    func localState(recordID: String, syncHash: String?, store: SyncStore, repo: ClipRepository) throws -> LocalStateFfi {
        @Dependency(\.defaultDatabase) var database
        let entry = try database.read { db in try store.applied(recordID: recordID, in: db) }
        var liveDup = false
        var tombDupHlc: HlcFfi?
        if let syncHash, !syncHash.isEmpty {
            liveDup = try repo.liveClip(forSyncHash: syncHash) != nil
            for tomb in try repo.tombstonedClips(forSyncHash: syncHash) {
                let tombEntry = try database.read { db in
                    try store.applied(recordID: tomb.id.uuidString.lowercased(), in: db)
                }
                if let tombEntry {
                    let candidate = HlcFfi(
                        wallMillis: Int64(tombEntry.hlcWall),
                        counter: UInt32(tombEntry.hlcCounter),
                        node: tombEntry.hlcNode
                    )
                    if let current = tombDupHlc {
                        if try hlcCompare(a: candidate, b: current) > 0 {
                            tombDupHlc = candidate
                        }
                    } else {
                        tombDupHlc = candidate
                    }
                }
            }
        }
        return LocalStateFfi(
            applied: entry != nil,
            appliedDeleted: entry?.deleted ?? false,
            liveDuplicateSyncHash: liveDup,
            tombstonedDuplicateHlc: tombDupHlc
        )
    }

    func appliedIDs(store: SyncStore) throws -> Set<String> {
        @Dependency(\.defaultDatabase) var database
        return try database.read { db in try store.appliedRecordIDs(in: db) }
    }

    func storeApplied(recordID: String, store: SyncStore) throws -> SyncAppliedRecord? {
        @Dependency(\.defaultDatabase) var database
        return try database.read { db in try store.applied(recordID: recordID, in: db) }
    }

    func cursorSeconds(store: SyncStore) throws -> Int {
        @Dependency(\.defaultDatabase) var database
        return try database.read { db in try store.lastPushedAt(in: db) }
    }

    func setCursorSeconds(_ seconds: Int, store: SyncStore) throws {
        @Dependency(\.defaultDatabase) var database
        try database.write { db in try store.setLastPushedAt(seconds, in: db) }
    }

    func nextClock(nowMillis: Int64, store: SyncStore) throws -> HlcFfi {
        let current = try store.hlcState()
        return try hlcNext(prev: current, nowMillis: nowMillis, node: deviceID)
    }

    func mergeClock(remote: HlcFfi, nowMillis: Int64, store: SyncStore) throws {
        let merged = try hlcReceive(local: store.hlcState(), remote: remote, nowMillis: nowMillis, node: deviceID)
        try store.mergeClock(merged)
    }

    func ownLastSeen() throws -> Int64? {
        guard let bytes = try? provider.readDevice(id: deviceID) else { return nil }
        return try deviceLastSeen(data: bytes)
    }

    func deviceLastSeen(id: String) throws -> Int64? {
        try deviceLastSeen(data: provider.readDevice(id: id))
    }

    func deviceLastSeen(data: Data) throws -> Int64? {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (object?["last_seen"] as? NSNumber)?.int64Value
    }
}
