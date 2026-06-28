//
//  Database.swift
//  ClipySi — Apple Silicon rewrite
//
//  Builds and migrates the on-disk SQLite database (a GRDB `DatabaseWriter`)
//  used as SQLiteData's `defaultDatabase`. The physical schema is raw SQL here
//  (frozen per migration); the value-type models live in Schema.swift.
//  See DESIGN.md §4.3.
//
//  At-rest encryption is per-field, not whole-database: whole-DB SQLCipher was
//  evaluated and rejected (incompatible with the SQLiteData/GRDB dependency graph).
//  Sensitive content is stored as AES-GCM ciphertext via `HistoryCipher` /
//  `EncryptedBlobStore`; only metadata and ciphertext live in this DB, so the
//  GRDB `configuration` itself applies no database-level key. See DESIGN.md §4.3
//  and security-guidance.md §5.
//

import Foundation
import OSLog
import SQLiteData

enum AppDatabase {
    static let logger = Logger(subsystem: "io.github.ponponusa.clipysi", category: "database")

    /// Creates a WAL-mode pool at the on-disk location and runs migrations.
    static func make() throws -> any DatabaseWriter {
        let url = try storeURL()
        // No database-level key: sensitive content is sealed per-field with AES-GCM
        // before it reaches the store (see file header). The DB holds only metadata
        // and ciphertext.
        let configuration = Configuration()
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        try migrator.migrate(pool)
        logger.info("database ready at \(url.path, privacy: .public)")
        return pool
    }

    /// `~/Library/Application Support/<bundle-id>/clipy.sqlite`.
    /// Keyed by bundle id so the Debug build, a future Release build, and the
    /// shipping Clipy (`com.clipy-app.Clipy`) never share a data directory.
    static func storeURL() throws -> URL {
        let appID = Bundle.main.bundleIdentifier ?? "io.github.ponponusa.clipysi"
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        .appendingPathComponent(appID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("clipy.sqlite")
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif
        migrator.registerMigration("v1_create") { db in
            try db.execute(sql: """
                CREATE TABLE "clips"(
                  "id"           TEXT NOT NULL PRIMARY KEY,
                  "contentHash"  TEXT NOT NULL,
                  "titleCipher"  BLOB NOT NULL,
                  "primaryType"  TEXT NOT NULL,
                  "createdAt"    INTEGER NOT NULL,
                  "isPinned"     INTEGER NOT NULL DEFAULT 0,
                  "isColorCode"  INTEGER NOT NULL DEFAULT 0,
                  "dataPath"     TEXT NOT NULL,
                  "thumbnailID"  TEXT,
                  "sourceBundle" TEXT
                ) STRICT;
                -- NON-unique on purpose. `contentHash` is a fast dedupe-lookup index, not a
                -- uniqueness constraint: FR-CAP-5 requires the copySameHistory /
                -- overwriteSameHistory settings to change dedupe behavior, and the original's
                -- `overwriteSameHistory = false` mode intentionally keeps duplicate rows. The
                -- dedupe policy lives in ClipRepository.ingest, not in the schema.
                CREATE INDEX "clips_contentHash" ON "clips"("contentHash");
                CREATE INDEX "clips_createdAt" ON "clips"("createdAt" DESC);

                CREATE TABLE "clipRepresentations"(
                  "clipID"   TEXT NOT NULL REFERENCES "clips"("id") ON DELETE CASCADE,
                  "uttype"   TEXT NOT NULL,
                  "dataPath" TEXT NOT NULL,
                  "byteSize" INTEGER NOT NULL,
                  PRIMARY KEY ("clipID", "uttype")
                ) STRICT;

                CREATE TABLE "snippetFolders"(
                  "id"        TEXT NOT NULL PRIMARY KEY,
                  "title"     TEXT NOT NULL,
                  "sortOrder" INTEGER NOT NULL DEFAULT 0,
                  "isEnabled" INTEGER NOT NULL DEFAULT 1
                ) STRICT;

                CREATE TABLE "snippets"(
                  "id"        TEXT NOT NULL PRIMARY KEY,
                  "folderID"  TEXT NOT NULL REFERENCES "snippetFolders"("id") ON DELETE CASCADE,
                  "title"     TEXT NOT NULL,
                  "content"   TEXT NOT NULL,
                  "sortOrder" INTEGER NOT NULL DEFAULT 0,
                  "isEnabled" INTEGER NOT NULL DEFAULT 1
                ) STRICT;
                CREATE INDEX "snippets_folderID" ON "snippets"("folderID");

                CREATE TABLE "excludedApps"(
                  "bundleIdentifier" TEXT NOT NULL PRIMARY KEY,
                  "name"             TEXT NOT NULL
                ) STRICT;
                """)
        }
        // Foundation freeze: additive sync/foundation meta columns on `clips` (no column is
        // ever dropped/renamed/retyped — only added). GRDB runs each migration in a transaction.
        // `ADD COLUMN ... NOT NULL` requires a constant DEFAULT under SQLite (incl. STRICT), so
        // `updatedAt` is added with DEFAULT 0 then backfilled to `createdAt`. The migrator can't
        // decrypt, so decrypt-dependent columns (`isSensitive`, `syncHash`) start at their neutral
        // defaults and are filled at capture / by the upload re-evaluation, not here.
        // See the clipy-si-core repository for the shared record/vault format.
        migrator.registerMigration("v2_sync_meta") { db in
            try db.execute(sql: """
                ALTER TABLE "clips" ADD COLUMN "updatedAt"      INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE "clips" ADD COLUMN "deletedAt"      INTEGER;
                ALTER TABLE "clips" ADD COLUMN "originDeviceID" TEXT;
                ALTER TABLE "clips" ADD COLUMN "recordVersion"  INTEGER NOT NULL DEFAULT 1;
                ALTER TABLE "clips" ADD COLUMN "syncState"      TEXT NOT NULL DEFAULT 'local';
                ALTER TABLE "clips" ADD COLUMN "syncHash"       TEXT;
                ALTER TABLE "clips" ADD COLUMN "syncEligible"   INTEGER NOT NULL DEFAULT 1;
                ALTER TABLE "clips" ADD COLUMN "isSensitive"    INTEGER NOT NULL DEFAULT 0;
                -- Existing rows: a clip's "last modified" is its creation time until something edits it.
                UPDATE "clips" SET "updatedAt" = "createdAt";
                -- Sync scans by updatedAt (sync diff) and filters by syncState; add the indexes now so
                -- a later migration doesn't have to ALTER a populated table.
                CREATE INDEX "clips_updatedAt" ON "clips"("updatedAt" DESC);
                CREATE INDEX "clips_syncState" ON "clips"("syncState");
                """)
        }
        // Sync state (new tables only — no clips columns). `syncMeta` is a key-value store for
        // the device HLC clock and push cursor, kept in the DB so the engine can advance them in
        // the SAME transaction as the applies (crash-safe replay). `syncApplied` is the persistent
        // set of every record this device has applied or published (+ the stamp it knew), which is
        // what makes pull a cursor-free filename diff and survives trim.
        migrator.registerMigration("v3_sync_state") { db in
            try db.execute(sql: """
                CREATE TABLE "syncMeta"(
                  "key"   TEXT NOT NULL PRIMARY KEY,
                  "value" TEXT NOT NULL
                ) STRICT;

                CREATE TABLE "syncApplied"(
                  "recordID"   TEXT NOT NULL PRIMARY KEY,
                  "hlcWall"    INTEGER NOT NULL,
                  "hlcCounter" INTEGER NOT NULL,
                  "hlcNode"    TEXT NOT NULL,
                  "deleted"    INTEGER NOT NULL DEFAULT 0
                ) STRICT;
                """)
        }
        return migrator
    }
}
