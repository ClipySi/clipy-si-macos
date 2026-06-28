//
//  PolicyResolver.swift
//  ClipySi — Apple Silicon rewrite
//
//  A single, deliberately-minimal seam for FUTURE managed (enterprise / MDM) policy, parked here
//  so later policy checks don't scatter across the codebase (a near-hook only, not a feature
//  today). Capture consults it before storing a clip; today there are no policy
//  sources, so it always permits — behavior is unchanged.
//
//  When enterprise lands (parking-lot), a concrete `PolicySource` (a managed UserDefaults domain,
//  an MDM configuration profile, …) plugs in here, and `CaptureOutcome.skippedByPolicy` is already
//  wired. This is intentionally NOT a 3-layer wrapper over AppSettings — just the hook.
//

import Foundation

/// A source of managed capture policy. A conformer returns `false` to block capture.
protocol PolicySource: Sendable {
    /// Whether capturing from these bundles is permitted under managed policy.
    func allowsCapture(frontmostBundleID: String?, sourceBundleID: String?) -> Bool
}

/// Resolves capture policy across zero or more sources. With no sources (the default), capture
/// is always allowed. When sources exist, a single deny wins (managed-forced "do not capture").
struct PolicyResolver: Sendable {
    private let sources: [any PolicySource]

    init(sources: [any PolicySource] = []) {
        self.sources = sources
    }

    func allowsCapture(frontmostBundleID: String?, sourceBundleID: String?) -> Bool {
        sources.allSatisfy {
            $0.allowsCapture(frontmostBundleID: frontmostBundleID, sourceBundleID: sourceBundleID)
        }
    }
}
