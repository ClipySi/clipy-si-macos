//
//  ScreenshotLocationTests.swift
//  ClipyTests
//
//  Resolving the folder macOS saves screenshots to. The regression these pin down: the save
//  location is user-configurable, and watching Desktop alone means auto-import matches nothing for
//  anyone who moved it. Pure input → output; the live `com.apple.screencapture` read is exercised
//  only through its invariants, never by writing to the system domain.
//

import Foundation
import Testing
@testable import Clipy

@Suite struct ScreenshotLocationTests {
    private static let desktop = "/Users/someone/Desktop"
    private static let configured = "/Users/someone/Pictures/ScreenCapture"

    /// Every path in `existing` (and nothing else) is an existing directory.
    private func exists(_ existing: String...) -> (String) -> Bool {
        let set = Set(existing)
        return { set.contains($0) }
    }

    @Test func watchesDesktopWhenNoLocationIsSet() {
        // The key is absent until the user moves the folder — that means Desktop, the system default.
        let paths = ScreenshotLocation.searchDirectoryPaths(
            rawLocation: nil, desktopPath: Self.desktop, directoryExists: exists(Self.desktop)
        )
        #expect(paths == [Self.desktop])
    }

    @Test func watchesConfiguredFolderAheadOfDesktop() {
        let paths = ScreenshotLocation.searchDirectoryPaths(
            rawLocation: Self.configured, desktopPath: Self.desktop,
            directoryExists: exists(Self.configured, Self.desktop)
        )
        #expect(paths == [Self.configured, Self.desktop])
    }

    @Test func expandsTheTildeTheScreenshotAppWrites() {
        // ⇧⌘5 → Options → Save to stores the value `~`-relative.
        let home = NSHomeDirectory()
        let paths = ScreenshotLocation.searchDirectoryPaths(
            rawLocation: "~/Pictures/ScreenCapture", desktopPath: Self.desktop,
            directoryExists: exists("\(home)/Pictures/ScreenCapture", Self.desktop)
        )
        #expect(paths == ["\(home)/Pictures/ScreenCapture", Self.desktop])
    }

    @Test func acceptsAFileURLValue() {
        #expect(ScreenshotLocation.normalize("file:///Users/someone/Screen%20Shots")
            == "/Users/someone/Screen Shots")
    }

    @Test func normalizesTrailingSlashesAndDotSegments() {
        #expect(ScreenshotLocation.normalize("/Users/someone/Pictures/") == "/Users/someone/Pictures")
        #expect(ScreenshotLocation.normalize("/Users/someone/Pictures/../Desktop") == "/Users/someone/Desktop")
    }

    @Test func ignoresBlankAndRelativeValues() {
        #expect(ScreenshotLocation.normalize("") == nil)
        #expect(ScreenshotLocation.normalize("   ") == nil)
        // Not resolved against our working directory — that is not where screencapture would write.
        #expect(ScreenshotLocation.normalize("Pictures/ScreenCapture") == nil)
    }

    @Test func dropsAConfiguredFolderThatIsNotThere() {
        // A moved or unmounted folder falls back to Desktop rather than scoping the query to a
        // path that cannot match.
        let paths = ScreenshotLocation.searchDirectoryPaths(
            rawLocation: "/Volumes/Gone/Shots", desktopPath: Self.desktop, directoryExists: exists(Self.desktop)
        )
        #expect(paths == [Self.desktop])
    }

    @Test func dedupesWhenTheConfiguredFolderIsDesktop() {
        let paths = ScreenshotLocation.searchDirectoryPaths(
            rawLocation: "\(Self.desktop)/", desktopPath: Self.desktop, directoryExists: exists(Self.desktop)
        )
        #expect(paths == [Self.desktop])
    }

    @Test func resolvesToNothingRatherThanAnUnscopedQuery() {
        // Screeen leaves `searchScopes` unset for an empty list, which searches the entire Spotlight
        // index. Nothing resolving must therefore stay empty, and ScreenshotMonitor must not build
        // an observer from it (see `staysIdleWhenNoFolderResolves`).
        let paths = ScreenshotLocation.searchDirectoryPaths(
            rawLocation: nil, desktopPath: nil, directoryExists: { _ in true }
        )
        #expect(paths.isEmpty)
    }

    @Test func liveSystemLookupYieldsUsableDirectories() {
        // Reads the real `com.apple.screencapture` domain (no App Sandbox, so this is readable) —
        // asserts only the invariants, so it holds whatever this machine's save folder is set to.
        let paths = ScreenshotLocation.currentSearchDirectoryPaths()
        #expect(paths.count <= 2)
        #expect(Set(paths).count == paths.count)
        for path in paths {
            #expect(path.hasPrefix("/"))
            #expect(ScreenshotLocation.isDirectory(path))
        }
    }
}
