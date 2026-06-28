//
//  AccessibilityService.swift
//  ClipySi — Apple Silicon rewrite
//
//  The macOS Accessibility (AX) trust check that CGEvent paste injection requires, plus the denial
//  alert that deep-links to System Settings. The trust check is injectable so tests never touch the
//  real AX subsystem. (The original gated this behind a macOS 10.14 `#available`; min is 14 now, so
//  the check is unconditional.) See security-guidance.md §4.
//

import AppKit

struct AccessibilityService {
    private let trustedCheck: (Bool) -> Bool

    init(trustedCheck: @escaping (Bool) -> Bool = AccessibilityService.systemTrustedCheck) {
        self.trustedCheck = trustedCheck
    }

    /// Whether this process is trusted for Accessibility. `prompt: true` shows the system permission
    /// prompt when not yet trusted (used once at launch); `false` checks silently before each paste.
    @discardableResult
    func isTrusted(prompt: Bool) -> Bool {
        trustedCheck(prompt)
    }

    static func systemTrustedCheck(prompt: Bool) -> Bool {
        // `kAXTrustedCheckOptionPrompt` is imported as a non-concurrency-safe global `var` under
        // Swift 6; its value is the documented-stable string "AXTrustedCheckOptionPrompt".
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Shown when paste is attempted without Accessibility permission; opens the relevant System
    /// Settings pane on confirmation.
    @MainActor
    func showDeniedAlert() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Allow Accessibility for ClipySi",
                                   comment: "Accessibility-permission alert title")
        alert.informativeText = String(localized: "To paste into the frontmost app, enable ClipySi under Privacy & Security → Accessibility in System Settings.",
                                       comment: "Accessibility-permission alert body")
        alert.addButton(withTitle: String(localized: "Open System Settings", comment: "Alert button: open System Settings"))
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Alert cancel button"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
