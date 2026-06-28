//
//  KeyComboValue.swift
//  ClipySi — Apple Silicon rewrite
//
//  A layout-independent global hotkey combo, persisted under the original Clipy `kCPYHotKey*` keys
//  as a Codable value (a QWERTY/ANSI key code + a Carbon modifier mask) so an existing user's combos
//  carry over. Bridged to `Magnet.KeyCombo` in `HotKeyService`. The Carbon masks match the original's
//  defaults: 768 = cmdKey(256) + shiftKey(512); 4352 = + controlKey(4096). Key codes are ANSI
//  (kVK_ANSI_V = 9, kVK_ANSI_B = 11); Magnet/Sauce resolve them per the active keyboard layout.
//

import Foundation

struct KeyComboValue: Codable, Equatable, Sendable {
    var keyCode: Int
    var carbonModifiers: Int
}

extension KeyComboValue {
    static let mainMenu = KeyComboValue(keyCode: 9, carbonModifiers: 768)   // ⌘⇧V
    static let history = KeyComboValue(keyCode: 9, carbonModifiers: 4352)   // ⌃⌘V
    static let snippet = KeyComboValue(keyCode: 11, carbonModifiers: 768)   // ⌘⇧B
}

/// The global hotkeys. Each maps to a stored-combo UserDefaults key, an optional code-level default
/// combo (seeded once on first run — `nil` means "no default", like the original's
/// `clearHistoryKeyCombo: KeyCombo?`), and a stable identifier used to register/unregister the Magnet
/// hotkey. `clearHistory` is the 4th, parity-required combo (original `kCPYClearHistoryKeyCombo`).
enum HotKeyType: CaseIterable {
    case mainMenu, history, snippet, clearHistory

    var defaultsKey: String {
        switch self {
        case .mainMenu: return DefaultsKeys.mainKeyCombo
        case .history: return DefaultsKeys.historyKeyCombo
        case .snippet: return DefaultsKeys.snippetKeyCombo
        case .clearHistory: return DefaultsKeys.clearHistoryKeyCombo
        }
    }

    /// The factory-default combo, or `nil` for a hotkey that ships unbound (clear-history). Applied
    /// **only at first-run seeding** (`HotKeyStore.seedDefaultsIfNeeded`), never as a read-time
    /// fallback — so clearing a hotkey persists as truly unbound (design §6 delta 13).
    var defaultCombo: KeyComboValue? {
        switch self {
        case .mainMenu: return .mainMenu
        case .history: return .history
        case .snippet: return .snippet
        case .clearHistory: return nil
        }
    }

    var identifier: String {
        switch self {
        case .mainMenu: return "ClipySiMainMenu"
        case .history: return "ClipySiHistoryMenu"
        case .snippet: return "ClipySiSnippetMenu"
        case .clearHistory: return "ClipySiClearHistory"
        }
    }
}
