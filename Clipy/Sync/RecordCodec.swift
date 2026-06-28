//
//  RecordCodec.swift
//  ClipySi — Apple Silicon rewrite
//
//  Thin Swift bridge to the shared core's record sealing, keyed by the VAULT key (distinct from the
//  device-local `HistoryCipher`). This freezes the format and proves the round-trip from Swift; the
//  actual `Clip` ⇄ envelope mapping, HLC stamping, and provider I/O are the sync engine. This is
//  deliberately provider-free — it only turns a plaintext record into sealed bytes and back.
//

import ClipySiCore
import Foundation

enum RecordCodec {
    /// Seal a record's plaintext under the vault key with a fresh CSPRNG nonce → `.combined` body.
    static func seal(_ plaintext: RecordPlaintextFfi, with vaultKey: VaultKey) throws -> Data {
        let nonce = try CryptoRandom.bytes()
        return try vaultKey.withKeyBytes { keyBytes in
            try sealRecord(vaultKey: keyBytes, nonce: nonce, plaintext: plaintext)
        }
    }

    /// Open a sealed body back into a record plaintext.
    static func open(_ body: Data, with vaultKey: VaultKey) throws -> RecordPlaintextFfi {
        try vaultKey.withKeyBytes { keyBytes in
            try openRecord(vaultKey: keyBytes, body: body)
        }
    }

    /// Cross-device dedupe hash over the canonical payload (vault dedupe subkey, NOT the local
    /// `contentHash`). The input is the same bytes capture hashes for its local `contentHash`.
    static func syncHash(forCanonicalPayload payload: Data, with vaultKey: VaultKey) throws -> String {
        try vaultKey.withKeyBytes { keyBytes in
            try computeSyncHash(vaultKey: keyBytes, canonicalPayload: payload)
        }
    }

    // MARK: - Clip ⇄ record mapping

    /// Build the publishable plaintext for a clip: decrypt the title and every representation
    /// (primary + secondaries) from the local store, in the shared canonical order so the
    /// resulting syncHash matches an identical capture on any device.
    static func makePlaintext(
        for clip: Clip,
        secondaries: [ClipRepresentation],
        cipher: HistoryCipher,
        blobStore: EncryptedBlobStore
    ) throws -> RecordPlaintextFfi {
        let title = String(data: try cipher.open(clip.titleCipher), encoding: .utf8) ?? ""
        var reps: [(typeID: String, data: Data)] = [(clip.primaryType, try blobStore.read(id: clip.dataPath))]
        for rep in secondaries {
            reps.append((rep.uttype, try blobStore.read(id: rep.dataPath)))
        }
        let ordered = CanonicalPayload.sortedForHashing(reps)
        return RecordPlaintextFfi(
            title: title,
            primaryType: clip.primaryType,
            sourceBundle: clip.sourceBundle,
            isColorCode: clip.isColorCode,
            representations: ordered.map { RecordRepresentationFfi(uttype: $0.typeID, data: $0.data) }
        )
    }

    /// The canonical dedupe bytes for a plaintext (same layout capture hashes locally).
    static func canonicalPayload(of plaintext: RecordPlaintextFfi) -> Data {
        CanonicalPayload.make(plaintext.representations.map { ($0.uttype, $0.data) })
    }

    /// The header fields shared by live and tombstone envelopes (`updatedAt` doubles as the
    /// deletion time for tombstones).
    struct EnvelopeMeta {
        var recordID: String
        var originDeviceID: String
        var hlc: HlcFfi
        var createdAt: Date
        var updatedAt: Date
        var syncHash: String
    }

    /// Assemble and encode a LIVE record envelope.
    static func makeLiveEnvelope(_ meta: EnvelopeMeta, body: Data) throws -> Data {
        try encodeEnvelope(envelope: RecordEnvelopeFfi(header: header(from: meta, deleted: false), body: body))
    }

    /// Assemble and encode a TOMBSTONE envelope (bodyless).
    static func makeTombstoneEnvelope(_ meta: EnvelopeMeta) throws -> Data {
        try encodeEnvelope(envelope: RecordEnvelopeFfi(header: header(from: meta, deleted: true), body: nil))
    }

    private static func header(from meta: EnvelopeMeta, deleted: Bool) -> RecordHeaderFfi {
        RecordHeaderFfi(
            formatVersion: recordFormatVersion(),
            recordId: meta.recordID,
            originDeviceId: meta.originDeviceID,
            hlc: meta.hlc,
            createdAt: Int64(meta.createdAt.timeIntervalSince1970),
            updatedAt: Int64(meta.updatedAt.timeIntervalSince1970),
            deleted: deleted,
            syncHash: meta.syncHash
        )
    }
}
