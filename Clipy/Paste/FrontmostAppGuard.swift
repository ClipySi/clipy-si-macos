//
//  FrontmostAppGuard.swift
//  ClipySi — Apple Silicon rewrite
//
//  R5: record the frontmost app's bundle id when a menu opens, and re-check it right before posting
//  the synthesized ⌘V. If focus changed in between (the user Cmd-Tabbed away), the paste is aborted
//  rather than landing in the wrong app. No equivalent exists in the original (DESIGN.md §security).
//  The frontmost provider is injectable so the gate logic is testable without the real workspace.
//
//  An irreducible TOCTOU window remains between the re-check and the CGEvent landing; that is an
//  accepted limitation (design §12.B).
//

import AppKit

struct FrontmostAppGuard {
    private let provider: @MainActor () -> String?

    init(provider: @escaping @MainActor () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }) {
        self.provider = provider
    }

    /// The current frontmost bundle id, captured at menu-open.
    @MainActor
    func snapshot() -> String? {
        provider()
    }

    /// True only if the frontmost app is unchanged from `snapshot` (and both are non-nil) — the
    /// precondition for posting ⌘V into the intended target.
    @MainActor
    func stillMatches(_ snapshot: String?) -> Bool {
        guard let snapshot, let current = provider() else { return false }
        return snapshot == current
    }
}
