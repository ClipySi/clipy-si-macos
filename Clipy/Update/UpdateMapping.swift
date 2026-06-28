//
//  UpdateMapping.swift
//  ClipySi — Apple Silicon rewrite
//
//  Pure, side-effect-free helpers for the Updates pane: the version label, the last-checked label,
//  and check-interval normalization. Kept out of the SwiftUI/Sparkle layers so they're unit-testable
//  without an updater or a bundle.
//

import Foundation

enum UpdateMapping {
    /// The three intervals the picker offers (seconds): daily / weekly / monthly. Mirrors the
    /// original `CPYUpdatesPreferenceViewController.xib` dropdown tags.
    static let dailyInterval = 86_400
    static let weeklyInterval = 604_800
    static let monthlyInterval = 2_592_000

    /// "v1.0.0", or "v1.0.0 (42)" when the build number adds information. Mirrors the original's
    /// `v{appVersion}` label, with the build appended for diagnosis. Empty short version → "v—".
    static func versionLabel(shortVersion: String, buildVersion: String) -> String {
        let short = shortVersion.isEmpty ? "—" : shortVersion
        if buildVersion.isEmpty || buildVersion == shortVersion {
            return "v\(short)"
        }
        return "v\(short) (\(buildVersion))"
    }

    /// A localized "last update check" label; `nil` (never checked) → "Never".
    static func lastCheckLabel(date: Date?) -> String {
        guard let date else {
            return String(localized: "Never", comment: "Updates pane: last-checked label when the app has never checked")
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Clamps a persisted interval to one of the known choices, defaulting an unknown/corrupt value
    /// to daily. Guards the updater against a junk `kCPYUpdateCheckIntervalKey` (defensive, in the
    /// spirit of the menu-settings clamps) without overwriting what the user has stored.
    static func normalizedInterval(_ seconds: Int) -> Int {
        switch seconds {
        case dailyInterval, weeklyInterval, monthlyInterval:
            return seconds
        default:
            return dailyInterval
        }
    }
}
