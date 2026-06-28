//
//  SyncGate.swift
//  ClipySi — Apple Silicon rewrite
//
//  The pre-sync security double gate (design §7, the load-bearing hand-off contract):
//  push re-evaluates the SecretDetector on the FULL decrypted text every time — it never
//  trusts the stored `isSensitive` flag (which can be stale for pre-secret-detection rows or rows written by
//  another device). A clip that fails the gate is excluded from sync and flagged so the UI can
//  show why. Tombstones bypass the gate (no content). Display masking and AuthGate remain the
//  pull-side defenses; apply additionally re-evaluates `isSensitive`.
//

import Foundation
import SQLiteData // re-exports swift-dependencies (@Dependency)

struct SyncGate {
    @Dependency(\.maskingService) private var masking

    /// May this clip's content leave the device? `decryptedText` is the full decrypted string
    /// representation when one exists, else the decrypted title preview (non-text clips have a
    /// placeholder title like "[TIFF]", which trivially passes).
    func allowsPush(syncEligible: Bool, decryptedText: String) -> Bool {
        guard syncEligible else { return false }
        return !masking.evaluate(decryptedText).isSecret
    }

    /// The pull-side re-evaluation: what `isSensitive` should be for an applied record,
    /// independent of whatever the publishing device claimed.
    func isSensitiveOnApply(decryptedTitle: String) -> Bool {
        masking.evaluate(decryptedTitle).isSecret
    }
}
