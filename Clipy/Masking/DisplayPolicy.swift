//
//  DisplayPolicy.swift
//  ClipySi — Apple Silicon rewrite
//
//  The display-affecting policy snapshot for ONE history read request (M-UI.11 P1). Resolved once
//  per panel open / manager reload — not once per row — so a Privacy-pane toggle mid-request can't
//  produce a half-masked list, and derived-value caches (classification today, more later) can key
//  on a stable value instead of re-reading UserDefaults.
//

import Foundation

/// What the current settings say about turning a decrypted title into display state. `Hashable` so
/// it can be part of cache keys: two requests with equal policies may share derived values; any
/// policy change makes every old key unreachable (no explicit invalidation to forget).
struct DisplayPolicy: Sendable, Hashable {
    /// Mask detected secrets for display (Privacy pane).
    let maskEnabled: Bool
    /// Raw mask-style token ("full" / "prefix2" / "suffix4") as persisted; mapped to the core
    /// enum by `MaskingService`.
    let maskStyleRaw: String
    /// `CodeClassifier.algorithmVersion` frozen into the key, so bumping the classifier
    /// invalidates cached verdicts without any cache knowing why.
    let classifierAlgorithmVersion: UInt16

    /// The policy under the CURRENT settings — the one settings read of a request.
    static func current(settings: AppSettings = AppSettings()) -> DisplayPolicy {
        DisplayPolicy(maskEnabled: settings.maskSecretsInMenu,
                      maskStyleRaw: settings.maskStyleRaw,
                      classifierAlgorithmVersion: CodeClassifier.algorithmVersion)
    }
}
