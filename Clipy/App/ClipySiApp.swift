//
//  ClipySiApp.swift
//  ClipySi — Apple Silicon rewrite
//
//  SwiftUI App lifecycle. The AppKit core (status item, hotkeys, pasteboard
//  monitoring, accessory activation) lives in AppDelegate, bridged via
//  @NSApplicationDelegateAdaptor. See DESIGN.md §4.1.
//

import OSLog
import SQLiteData
import SwiftUI

@main
struct ClipySiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Composition root: build + migrate the database and register it as
        // SQLiteData's `defaultDatabase` before any @FetchAll runs. Non-fatal on
        // failure so the menu-bar app still launches (DESIGN.md §4.3).
        do {
            let database = try AppDatabase.make()
            prepareDependencies { $0.defaultDatabase = database }
        } catch {
            Logger(subsystem: "io.github.ponponusa.clipysi", category: "app")
                .error("database init failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    var body: some Scene {
        // The Settings scene satisfies the App's Scene requirement, but the *visible* Settings window
        // is an AppKit window AppDelegate owns (the `showSettingsWindow:` selector doesn't reliably
        // open from an accessory app — see AppDelegate.openSettings). Remove the auto-added
        // "Settings…" app-menu item so becoming `.regular` can't open a second, redundant window.
        Settings {
            SettingsRootView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) { }
        }
    }
}
