//
//  IsSensitiveBackfill.swift
//  ClipySi — Apple Silicon rewrite
//
//  One-shot pass that fills the `isSensitive` flag for clips captured *before* capture-time
//  secret detection was wired in. It decrypts each title preview, runs the SecretDetector, and
//  persists the verdict. The v2 migration could not do this (it can't decrypt — design §3.3), so
//  it runs once at app launch in the background.
//
//  This is a UX hint ONLY (e.g. a future "sensitive" badge). It is NOT a sync gate: sync
//  re-evaluates `isSecret` at upload regardless of this flag (the double gate),
//  so a stale `false` here can never leak a secret to a sync provider.
//

import Foundation
import OSLog
import SQLiteData

struct IsSensitiveBackfill {
    @Dependency(\.historyCipher) private var cipher
    @Dependency(\.maskingService) private var masking
    private let clips = ClipRepository()

    private static let logger = Logger(subsystem: "io.github.ponponusa.clipysi", category: "backfill")

    /// Runs the backfill once, guarded by a UserDefaults flag. Returns the number of rows flagged.
    /// The done-flag is set only on success, so a failed pass (e.g. a transient DB error) retries
    /// next launch instead of permanently stranding un-flagged rows.
    @discardableResult
    func runIfNeeded(defaults: UserDefaults = .standard) -> Int {
        guard !defaults.bool(forKey: DefaultsKeys.isSensitiveBackfillDone) else { return 0 }
        do {
            let updated = try run()
            defaults.set(true, forKey: DefaultsKeys.isSensitiveBackfillDone)
            Self.logger.info("isSensitive backfill flagged \(updated, privacy: .public) row(s)")
            return updated
        } catch {
            Self.logger.warning("isSensitive backfill failed; retrying next launch: \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }

    /// Flags every not-yet-sensitive clip whose decrypted title the detector considers a secret.
    /// Returns the number updated. The title plaintext never leaves this scope or reaches a log.
    func run() throws -> Int {
        var updated = 0
        for clip in try clips.clips() where !clip.isSensitive {
            guard let titleData = try? cipher.open(clip.titleCipher),
                  let title = String(data: titleData, encoding: .utf8)
            else { continue }
            if masking.evaluate(title).isSecret {
                try clips.setSensitive(true, id: clip.id)
                updated += 1
            }
        }
        return updated
    }
}
