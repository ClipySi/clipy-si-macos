//
//  ExcludeAppRepository.swift
//  ClipySi — Apple Silicon rewrite
//
//  Apps whose copies must never be captured. Replaces the original's `NSCoding`-archived
//  `[CPYAppInfo]` blob (UserDefaults key "kCPYExcludeApplications") with a first-class table.
//  Capture checks `contains(bundleIdentifier:)` for the frontmost / copying app before
//  reading pasteboard content (requirements FR-CAP-4). The one-time import of the legacy
//  archived blob into this table is handled by the migration.
//

import Foundation
import SQLiteData

struct ExcludeAppRepository {
    @Dependency(\.defaultDatabase) private var database

    /// All excluded apps, ordered by bundle identifier.
    func all() throws -> [ExcludedApp] {
        try database.read { db in
            try ExcludedApp.order(by: \.bundleIdentifier).fetchAll(db)
        }
    }

    func contains(bundleIdentifier: String) throws -> Bool {
        try database.read { db in
            try ExcludedApp.where { $0.bundleIdentifier.eq(bundleIdentifier) }.fetchCount(db) > 0
        }
    }

    /// Adds (or updates the display name of) an excluded app. `bundleIdentifier` is the
    /// primary key, so this upserts via delete-then-insert in a single transaction.
    func add(bundleIdentifier: String, name: String) throws {
        try database.write { db in
            try ExcludedApp.delete().where { $0.bundleIdentifier.eq(bundleIdentifier) }.execute(db)
            try ExcludedApp.insert { ExcludedApp(bundleIdentifier: bundleIdentifier, name: name) }.execute(db)
        }
    }

    func remove(bundleIdentifier: String) throws {
        try database.write { db in
            try ExcludedApp.delete().where { $0.bundleIdentifier.eq(bundleIdentifier) }.execute(db)
        }
    }
}
