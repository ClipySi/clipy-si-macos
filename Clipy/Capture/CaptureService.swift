//
//  CaptureService.swift
//  ClipySi — Apple Silicon rewrite
//
//  The capture pipeline: given a `PasteboardContents` snapshot, decide whether to store it and,
//  if so, encrypt and persist it. This is where security requirements R1 (privacy markers) and
//  R3 (encryption at rest) are enforced, and where the original Clipy's capture gates
//  (store-types, excluded apps, dedupe, history cap) are replicated.
//
//  Order of gates (all BEFORE any content is durably stored):
//   1. privacy markers — transient/auto-generated → skip; concealed → skip (no opt-in yet).
//   2. excluded app — frontmost or source bundle on the exclude list → skip.
//   3. store-types filter — keep only user-enabled UTType representations, in priority order.
//   4. empty guard — string-only empty clip → skip.
//   5. dedupe — keyed HMAC contentHash + ClipRepository.ingest (copySameHistory / overwrite).
//   6. encrypt — title preview → titleCipher; the primary payload → its blob (Clip.dataPath); every
//      secondary representation → its own blob + clipRepresentation row (multi-rep paste fidelity).
//   7. history cap — trim to maxHistorySize.
//
//  Thumbnail generation is still deferred; all captured UTType representations are now archived so
//  the paste service can restore each type the source provided, not just the primary.
//

import AppKit
import SQLiteData // re-exports swift-dependencies

enum CaptureOutcome: Sendable, Equatable {
    case stored(Clip.ID)
    case skippedDuplicate
    case skippedPrivacy
    case skippedConcealed
    case skippedExcludedApp
    case skippedNoStorableType
    case skippedEmpty
    /// Blocked by managed (enterprise/MDM) policy. The hook is parked; no PolicySource exists yet,
    /// so this is never returned in shipping builds (PolicyResolver permits everything).
    case skippedByPolicy
}

struct CaptureService {
    @Dependency(\.historyCipher) private var cipher
    @Dependency(\.maskingService) private var masking
    @Dependency(\.date) private var date

    private let clips = ClipRepository()
    private let excludedApps = ExcludeAppRepository()
    let settings: AppSettings
    let blobStore: EncryptedBlobStore
    /// Managed-policy seam (enterprise near-hook). Default = no sources = permit everything.
    let policy: PolicyResolver

    init(settings: AppSettings = AppSettings(),
         blobStore: EncryptedBlobStore,
         policy: PolicyResolver = PolicyResolver()) {
        self.settings = settings
        self.blobStore = blobStore
        self.policy = policy
    }

    /// Pasteboard type identifiers per store-type token, in capture priority order. The token
    /// strings match the original's `storeTypes` UserDefaults keys (DefaultsKeys.storeTypeTokens).
    private static let storeTypeOrder: [(token: String, typeID: String)] = [
        ("String", NSPasteboard.PasteboardType.string.rawValue),
        ("RTF", NSPasteboard.PasteboardType.rtf.rawValue),
        ("RTFD", NSPasteboard.PasteboardType.rtfd.rawValue),
        ("PDF", NSPasteboard.PasteboardType.pdf.rawValue),
        ("Filenames", NSPasteboard.PasteboardType.fileURL.rawValue),
        ("URL", NSPasteboard.PasteboardType.URL.rawValue),
        ("TIFF", NSPasteboard.PasteboardType.tiff.rawValue)
    ]

    private static let stringTypeID = NSPasteboard.PasteboardType.string.rawValue

    private struct Representation {
        let token: String
        let typeID: String
        let data: Data
    }

    func capture(_ contents: PasteboardContents) throws -> CaptureOutcome {
        // 1. Privacy markers — decided from the declared types alone, before reading content (R1).
        switch PrivacyMarkers.decision(forTypeIdentifiers: contents.typeIdentifiers) {
        case .skip: return .skippedPrivacy
        case .concealed: return .skippedConcealed // default: never store concealed content
        case .record: break
        }

        // 2. Excluded app — frontmost or declared source.
        let candidateBundles = [contents.frontmostBundleID, contents.sourceBundleID].compactMap { $0 }
        if try candidateBundles.contains(where: { try excludedApps.contains(bundleIdentifier: $0) }) {
            return .skippedExcludedApp
        }

        // 2.5 Managed policy (enterprise near-hook). No-op until a PolicySource is registered.
        guard policy.allowsCapture(frontmostBundleID: contents.frontmostBundleID,
                                   sourceBundleID: contents.sourceBundleID) else {
            return .skippedByPolicy
        }

        // 3. Store-types filter (user setting), highest priority first.
        let storable = Self.storeTypeOrder.compactMap { entry -> Representation? in
            guard settings.shouldStore(typeToken: entry.token),
                  contents.typeIdentifiers.contains(entry.typeID),
                  let data = contents.dataByType[entry.typeID]
            else { return nil }
            return Representation(token: entry.token, typeID: entry.typeID, data: data)
        }
        guard let primary = storable.first else { return .skippedNoStorableType }

        // 4. Title preview + empty guard. Prefer the plain-text representation for the preview.
        let text = contents.string(forType: Self.stringTypeID)
        let titlePreview = text.map { String($0.prefix(10_000)) } ?? "[\(primary.token)]"
        if primary.token == "String", text?.isEmpty ?? true { return .skippedEmpty }

        // 5. Keyed dedupe hash over the canonical payload (HMAC — reveals nothing without the key).
        let contentHash = cipher.contentHash(Self.canonicalPayload(storable))

        // 6. Encrypt: title preview → titleCipher; the primary payload → its blob; every secondary
        //    representation → its own encrypted blob + clipRepresentation row, so paste can restore
        //    each captured UTType (not just the primary). Track all fresh blobs for cleanup.
        let clipID = UUID()
        let titleCipher = try cipher.seal(Data(titlePreview.utf8))
        let primaryPath = try blobStore.write(primary.data)
        var freshBlobs = [primaryPath]
        var representations: [ClipRepresentation] = []
        for representation in storable.dropFirst() {
            let path = try blobStore.write(representation.data)
            freshBlobs.append(path)
            representations.append(ClipRepresentation(
                clipID: clipID, uttype: representation.typeID, dataPath: path, byteSize: representation.data.count))
        }

        let clip = Clip(
            id: clipID,
            contentHash: contentHash,
            titleCipher: titleCipher,
            primaryType: primary.typeID,
            createdAt: date.now,
            isPinned: false,
            isColorCode: ColorCode.isColorCode(titlePreview),
            dataPath: primaryPath,
            thumbnailID: nil,
            sourceBundle: contents.sourceBundleID,
            // Stamp the sync/foundation meta a fresh capture can know. `updatedAt == createdAt`
            // for a new clip; `originDeviceID` attributes it to this device for merge/tie-break.
            // `isSensitive` records the SecretDetector verdict (independent of the masking-display
            // toggle) as a UX hint — sync safety re-evaluates at upload (double gate).
            updatedAt: date.now,
            originDeviceID: DeviceIdentity.current(in: settings.defaults),
            isSensitive: masking.evaluate(titlePreview).isSecret
        )

        // 7. Ingest under the user's dedupe settings, cleaning up every fresh blob in any path that
        // doesn't end up referencing it (no orphaned ciphertext on disk).
        guard let storedID = try clips.ingest(
            clip,
            representations: representations,
            copySameHistory: settings.copySameHistory,
            overwriteSameHistory: settings.overwriteSameHistory
        ) else {
            for path in freshBlobs { try? blobStore.delete(id: path) } // dropped as duplicate
            return .skippedDuplicate
        }
        if storedID != clip.id {
            // An existing identical clip was moved to the top; our fresh blobs are unused.
            for path in freshBlobs { try? blobStore.delete(id: path) }
            return .stored(storedID)
        }

        // Enforce the history cap and GC the blobs of any trimmed clips (no orphaned ciphertext).
        for staleBlob in try clips.trim(maxHistorySize: settings.maxHistorySize) {
            try? blobStore.delete(id: staleBlob)
        }
        return .stored(storedID)
    }

    /// Deterministic canonical bytes for the dedupe HMAC. Delegates to the shared `CanonicalPayload`
    /// so capture and history import hash identically — see that type.
    private static func canonicalPayload(_ representations: [Representation]) -> Data {
        CanonicalPayload.make(representations.map { ($0.typeID, $0.data) })
    }
}
