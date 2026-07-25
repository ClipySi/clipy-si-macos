//
//  ScreenshotLocation.swift
//  ClipySi — Apple Silicon rewrite
//
//  Where macOS actually saves screenshots. `screencapture` writes to `~/Desktop` only until the
//  user changes it (⇧⌘5 → Options → Save to, System Settings, or `defaults write
//  com.apple.screencapture location`) — after which the Desktop-only Spotlight scope that Screeen's
//  no-argument initializer sets up matches nothing and auto-import silently stops working, with the
//  Type-pane toggle still reading as on. We resolve the same preference the system does and watch
//  that folder instead.
//
//  Desktop stays in the list alongside it, so a stale or unreadable preference can only ever add a
//  folder to the scope, never take the default one away.
//
//  Pure/Foundation-only (no AppKit) so the parsing is unit-testable with injected inputs; reading
//  another app's preference domain is the one thin wrapper at the bottom — legal here because the
//  app ships without App Sandbox (AGENTS.md), and it reads a folder path only, never file contents.
//

import Foundation

enum ScreenshotLocation {
    /// The system screenshot preference domain, and the key holding the save folder.
    /// The key is absent until the user moves the folder; absent means `~/Desktop`.
    static let domain = "com.apple.screencapture"
    static let locationKey = "location"

    /// The directories the screenshot query should be scoped to: the configured save folder first,
    /// then Desktop, deduped, with anything that isn't an existing directory dropped.
    ///
    /// Returns an empty array when neither resolves. Callers MUST treat that as "watch nothing" —
    /// `ScreenShotObserver` leaves `searchScopes` unset for an empty list, which is an unscoped
    /// Spotlight query over everything indexed, not a Desktop fallback.
    static func searchDirectoryPaths(rawLocation: String?,
                                     desktopPath: String?,
                                     directoryExists: (String) -> Bool) -> [String] {
        var paths: [String] = []
        for candidate in [rawLocation, desktopPath] {
            guard let path = normalize(candidate), directoryExists(path), !paths.contains(path) else { continue }
            paths.append(path)
        }
        return paths
    }

    /// Normalizes a raw preference value into an absolute directory path, or nil if it isn't one.
    /// Covers the shapes the setting is written in: `~`-relative (what the Screenshot app's own
    /// "Save to" menu stores), absolute (`defaults write`, "Other Location…"), and a `file://` URL.
    static func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let path: String
        if trimmed.hasPrefix("file://") {
            guard let url = URL(string: trimmed), url.isFileURL else { return nil }
            path = url.path // percent-decoded
        } else {
            path = trimmed
        }

        let expanded = (path as NSString).expandingTildeInPath
        // Refuse a relative value rather than resolving it against our own working directory, which
        // is not what `screencapture` would do with it.
        guard expanded.hasPrefix("/") else { return nil }
        return (expanded as NSString).standardizingPath
    }

    // MARK: - Live system state

    /// The watch list for the current system configuration.
    static func currentSearchDirectoryPaths() -> [String] {
        searchDirectoryPaths(
            rawLocation: systemRawLocation(),
            desktopPath: NSSearchPathForDirectoriesInDomains(.desktopDirectory, .userDomainMask, true).first,
            directoryExists: isDirectory
        )
    }

    /// Reads `com.apple.screencapture location`. Synchronizes the domain first so a change the user
    /// made after we launched isn't served from this process's cached copy of it.
    static func systemRawLocation() -> String? {
        let identifier = domain as CFString
        CFPreferencesAppSynchronize(identifier)
        return CFPreferencesCopyAppValue(locationKey as CFString, identifier) as? String
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
