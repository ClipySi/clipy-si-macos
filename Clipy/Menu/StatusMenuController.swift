//
//  StatusMenuController.swift
//  ClipySi — Apple Silicon rewrite
//
//  Clear-history confirmation + execution. The status item and every hotkey now open the one
//  unified FloatingPanel (which owns history, snippets, and the management overlay), so this type no
//  longer builds ANY NSMenu — the popup/snippet/management rendering was retired. It
//  survives only as the owner of the "Clear History" confirm flow, reachable from the `.clearHistory`
//  global hotkey and the panel's management-overlay Clear button. (Kept under the `StatusMenuController`
//  name for now to minimize churn across this slice; a rename can follow.) AppKit-bound → `@MainActor`.
//

import AppKit
import OSLog

@MainActor
final class StatusMenuController {
    private let model: MenuModel
    private let clips = ClipRepository()
    private let blobStore: EncryptedBlobStore?

    private static let log = Logger(subsystem: "io.github.ponponusa.clipysi", category: "menu")

    init(model: MenuModel, blobStore: EncryptedBlobStore?) {
        self.model = model
        self.blobStore = blobStore
    }

    /// Shows the confirm alert (honoring `showAlertBeforeClearHistory`) and clears on confirmation.
    /// Reachable from both the `.clearHistory` global hotkey and the panel's management overlay — both
    /// MUST pop this same alert, exactly like the original's `clearAllHistory()` (whose hotkey path is
    /// named `popUpClearHistoryAlert`); routing straight to `performClearHistory` would wipe everything
    /// with no prompt. Activates first so the alert is frontmost when fired from the background
    /// (accessory) regime.
    func confirmAndClearHistory() {
        if model.settings.showAlertBeforeClearHistory {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = String(localized: "Clear all clipboard history?", comment: "Clear-history confirmation alert title")
            alert.informativeText = String(localized: "This cannot be undone.", comment: "Clear-history confirmation alert message")
            alert.addButton(withTitle: String(localized: "Clear History", comment: "Status menu item / alert button: clear all clipboard history"))
            alert.addButton(withTitle: String(localized: "Cancel", comment: "Alert cancel button"))
            alert.showsSuppressionButton = true
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            if alert.suppressionButton?.state == .on {
                model.settings.defaults.set(false, forKey: DefaultsKeys.showAlertBeforeClearHistory)
            }
        }
        do {
            try performClearHistory()
        } catch {
            Self.log.error("clear history failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Deletes all history and GCs the on-disk blobs (no orphaned ciphertext). Separated from the
    /// confirm dialog so it is unit-testable without an NSAlert modal.
    func performClearHistory() throws {
        for path in try clips.deleteAll() {
            try? blobStore?.delete(id: path)
        }
    }
}
