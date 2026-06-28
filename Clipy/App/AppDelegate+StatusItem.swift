//
//  AppDelegate+StatusItem.swift
//  ClipySi — Apple Silicon rewrite
//
//  The menu-bar status item, split out of AppDelegate to keep that file within the length budget.
//  The status item no longer owns an NSMenu: a left click opens the one unified panel
//  (history + snippets + management) below the item, and a right/control click shows a minimal
//  Open / Settings / Quit fallback that renders NO clip or snippet content — so this path never
//  decrypts a clip or exposes a secret (design §退役 / security invariant). AppKit-bound → `@MainActor`
//  (inherited from `AppDelegate`).
//

import AppKit

extension AppDelegate {
    /// Installs, updates, or removes the status-bar item to match the current `showStatusItem` setting
    /// (0 = None → hidden, 1 = Black → filled clipboard, 2 = White → outline clipboard; both template
    /// images the menu bar tints for light/dark, mirroring the original). Always re-applies the image so
    /// switching *between* styles 1↔2 takes effect live. Idempotent: runs at launch and whenever the
    /// General pane changes the style (`.clipySiStatusItemStyleChanged`).
    func refreshStatusItem() {
        guard let imageName = SettingsMapping.statusItemImageName(forStyle: AppSettings().showStatusItem) else {
            // Style "None": tear down any existing item.
            if let item = statusItem {
                NSStatusBar.system.removeStatusItem(item)
                statusItem = nil
            }
            return
        }
        let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(named: imageName)
        image?.isTemplate = true
        image?.accessibilityDescription = "ClipySi"
        item.button?.image = image
        // No NSMenu: route both mouse-ups through the button's action so the panel — not a menu — is
        // the content surface.
        item.menu = nil
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    /// Left click → open the unified panel below the status item; right/control click → the 3-item
    /// fallback menu. `sendAction(on:)` delivers both mouse-ups here; we read the live event to tell them
    /// apart.
    @objc
    func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)
        if isSecondary {
            showStatusFallbackMenu(from: sender)
        } else {
            historyPanel?.open(from: sender)
        }
    }

    /// The right-/control-click fallback: a minimal Open / Settings / Quit menu (no history/snippets).
    private func showStatusFallbackMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        let open = NSMenuItem(title: String(localized: "Open ClipySi", comment: "Status item fallback menu: open the panel"),
                              action: #selector(fallbackOpen), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let settings = NSMenuItem(title: String(localized: "Settings…", comment: "Status item fallback menu: open Settings"),
                                  action: #selector(fallbackSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: String(localized: "Quit ClipySi", comment: "Status menu item: quit the app"),
                              action: #selector(fallbackQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        // Pop just below the button; popUp blocks until dismissed, then the item reverts to its action.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func fallbackOpen() { historyPanel?.open() }
    @objc private func fallbackSettings() { openSettings() }
    @objc private func fallbackQuit() { NSApp.terminate(nil) }
}
