//
//  Schema.swift
//  ClipySi — Apple Silicon rewrite
//
//  SQLiteData (`@Table`) value-type models. The physical schema (CREATE TABLE
//  with STRICT / PRIMARY KEY / FOREIGN KEY … ON DELETE CASCADE) is defined as
//  raw SQL in the DatabaseMigrator; these structs map columns for type-safe
//  queries. See DESIGN.md §4.3.
//

import Foundation
import SQLiteData

// MARK: - Clipboard history

/// One captured clipboard item. The rich payload lives in an encrypted blob on
/// disk (referenced by `dataPath`); only metadata is stored in the DB.
///
/// `titleCipher` is the content preview — sensitive, so it is stored as an AES-GCM
/// ciphertext BLOB (not plaintext). Capture encrypts it via `HistoryCipher`; reads decrypt
/// at display time, one keyset page at a time for the panel (`HistoryReadService`, M-UI.11
/// P2) and as a bounded window for search and the History Manager. The repository treats
/// it as opaque `Data` (security-guidance.md §5 / R3).
@Table("clips")
struct Clip: Identifiable, Sendable {
    let id: UUID
    var contentHash: String
    var titleCipher: Data
    var primaryType: String
    // Stored as an integer count of whole seconds since the unix epoch. A bare `Date`
    // would bind as an ISO-8601 TEXT string, which fails the STRICT `INTEGER` column in
    // the v1 migration; `UnixTimeRepresentation` binds as `Int` and matches the original's
    // `Int(timeIntervalSince1970)` update-time semantics. See Database.swift.
    @Column(as: Date.UnixTimeRepresentation.self)
    var createdAt: Date
    var isPinned = false
    var isColorCode = false
    var dataPath: String
    var thumbnailID: String?
    var sourceBundle: String?

    // MARK: - sync/foundation meta (additive only)
    //
    // All have Swift defaults so the existing `Clip(...)` call sites (and `Make.clip`) keep
    // compiling; the v2 migration backfills them on existing rows. Sync writes most of
    // these; the foundation only freezes the columns and stamps `updatedAt`/`originDeviceID`/`isSensitive`
    // at capture. `syncHash`/`deletedAt`/`originDeviceID` are nullable (no meaningful value for
    // a pre-sync row). `updatedAt` mirrors `createdAt` for migrated rows.
    @Column(as: Date.UnixTimeRepresentation.self)
    var updatedAt: Date = Date(timeIntervalSince1970: 0)
    @Column(as: Date.UnixTimeRepresentation?.self)
    var deletedAt: Date?
    /// The device that created this clip (nil = local-origin, pre-sync). Sync tie-break.
    var originDeviceID: String?
    /// Which record-format generation this row maps to (frozen at 1).
    var recordVersion: Int = 1
    /// `local` / `pendingUpload` / `synced` (string for forward-compat; sync transitions it).
    var syncState: String = "local"
    /// Cross-device dedupe HMAC under the vault dedupe subkey — NOT the local `contentHash`.
    /// nil until computed (needs the vault key, which the foundation has no UI for). Sync fills it.
    var syncHash: String?
    /// May this clip be synced? Default true; opt-outs (e.g. concealed) set false. Sync honors it.
    var syncEligible: Bool = true
    /// `SecretDetector` verdict at capture time. UX hint only — sync safety re-evaluates at
    /// upload (double gate). Existing rows default false.
    var isSensitive: Bool = false
}

/// Synthesized member-wise equality, so the head-of-history observation (M-UI.11 P3) can
/// `removeDuplicates()` — only a commit that actually changes a watched row/count reaches the
/// warm-cache rebuild.
extension Clip: Equatable {}

/// A secondary UTType representation of a clip (child of `Clip`). The *primary* representation lives
/// in `Clip.dataPath` / `Clip.primaryType`; these rows hold every *other* captured representation so
/// the paste service can restore all UTTypes (not just the primary). `dataPath` is that
/// representation's AES-GCM blob on disk (GC'd alongside the clip's primary blob on delete/trim).
@Table("clipRepresentations")
struct ClipRepresentation: Sendable {
    var clipID: Clip.ID
    var uttype: String
    var dataPath: String
    var byteSize: Int
}

// MARK: - Snippets

@Table("snippetFolders")
struct SnippetFolder: Identifiable, Sendable {
    let id: UUID
    var title: String
    var sortOrder: Int
    var isEnabled = true
}

@Table("snippets")
struct Snippet: Identifiable, Sendable {
    let id: UUID
    var folderID: SnippetFolder.ID
    var title: String
    var content: String
    var sortOrder: Int
    var isEnabled = true
}

// MARK: - Excluded applications

/// Apps whose copies must never be captured. Replaces the original's
/// `NSCoding`-archived `excludeApplications` UserDefaults blob.
@Table("excludedApps")
struct ExcludedApp: Sendable {
    var bundleIdentifier: String
    var name: String
}

// MARK: - Sync state

/// Key-value store for the sync engine's device state (HLC clock, push cursor). Lives in the DB —
/// not UserDefaults — so the engine can advance it in the SAME transaction as record applies.
@Table("syncMeta")
struct SyncMetaRow: Sendable {
    var key: String
    var value: String
}

/// The persistent set of every record this device has applied or published, with the HLC stamp it
/// knew and whether it is tombstoned. This is what makes pull a cursor-free filename diff (immune
/// to out-of-order file arrival) and prevents trim from re-importing evicted records.
@Table("syncApplied")
struct SyncAppliedRecord: Sendable {
    var recordID: String
    var hlcWall: Int
    var hlcCounter: Int
    var hlcNode: String
    var deleted = false
}
