//
//  ScreenshotMonitorTests.swift
//  ClipyTests
//
//  Scoping of the screenshot query: that it follows the save folder instead of pinning Desktop, and
//  that an unresolvable folder leaves it idle rather than falling through to Screeen's unscoped
//  query. Only the scope is asserted — Spotlight delivery itself is run-app, and no capture,
//  pasteboard or Keychain is touched.
//

import Foundation
import Testing
@testable import Clipy

@Suite @MainActor struct ScreenshotMonitorTests {
    /// A real directory to scope a query to (Spotlight is never asked to deliver anything from it).
    private func makeDirectory() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipySiShotDir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    @Test func watchesTheResolvedFolderOnEnable() throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(atPath: folder) }

        let monitor = ScreenshotMonitor(resolveSearchPaths: { [folder] }, onScreenshot: { _ in })
        #expect(monitor.watchedDirectoryPaths.isEmpty)
        #expect(!monitor.isWatching)

        monitor.isEnabled = true
        #expect(monitor.watchedDirectoryPaths == [folder])
        #expect(monitor.isWatching)
    }

    @Test func reScopesWhenTheSaveFolderMoves() throws {
        let first = try makeDirectory()
        let second = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(atPath: first)
            try? FileManager.default.removeItem(atPath: second)
        }

        var resolved = [first]
        let monitor = ScreenshotMonitor(resolveSearchPaths: { resolved }, onScreenshot: { _ in })
        monitor.isEnabled = true
        #expect(monitor.watchedDirectoryPaths == [first])

        // Screeen applies `searchScopes` only at init, so this has to replace the observer to
        // take effect — the bug is a monitor that keeps watching where the folder used to be.
        resolved = [second]
        monitor.refreshSearchPaths()
        #expect(monitor.watchedDirectoryPaths == [second])
    }

    @Test func staysIdleWhenNoFolderResolves() {
        // An empty scope list must not become `ScreenShotObserver()` or an observer with no
        // `searchScopes`: that is a query over the entire Spotlight index.
        let monitor = ScreenshotMonitor(resolveSearchPaths: { [] }, onScreenshot: { _ in })
        monitor.isEnabled = true
        #expect(monitor.watchedDirectoryPaths.isEmpty)
        #expect(!monitor.isWatching)

        monitor.refreshSearchPaths()
        #expect(monitor.watchedDirectoryPaths.isEmpty)
        #expect(!monitor.isWatching)
    }

    @Test func stopsWatchingWhenTheSaveFolderGoesAway() throws {
        // An unmounted volume or a deleted folder resolves to nothing. Re-scoping to an empty list
        // must tear the query down, NOT hand `[]` to Screeen — that leaves `searchScopes` unset,
        // which is a query over the entire Spotlight index.
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(atPath: folder) }

        var resolved = [folder]
        let monitor = ScreenshotMonitor(resolveSearchPaths: { resolved }, onScreenshot: { _ in })
        monitor.isEnabled = true
        #expect(monitor.isWatching)

        resolved = []
        monitor.refreshSearchPaths()
        #expect(monitor.watchedDirectoryPaths.isEmpty)
        #expect(!monitor.isWatching)
    }

    @Test func doesNotWatchAnythingWhileDisabled() throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(atPath: folder) }

        let monitor = ScreenshotMonitor(resolveSearchPaths: { [folder] }, onScreenshot: { _ in })
        monitor.refreshSearchPaths()
        #expect(monitor.watchedDirectoryPaths.isEmpty)
        #expect(!monitor.isWatching)

        // …and picks the folder up when the Type-pane toggle turns it on.
        monitor.isEnabled = true
        #expect(monitor.watchedDirectoryPaths == [folder])
    }

    @Test func keepsTheScopeAcrossADisableAndReEnable() throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(atPath: folder) }

        let monitor = ScreenshotMonitor(resolveSearchPaths: { [folder] }, onScreenshot: { _ in })
        monitor.isEnabled = true
        monitor.isEnabled = false
        #expect(monitor.watchedDirectoryPaths == [folder])

        monitor.isEnabled = true
        #expect(monitor.watchedDirectoryPaths == [folder])
    }
}
