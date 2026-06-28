//
//  HotKeyService.swift
//  ClipySi — Apple Silicon rewrite
//
//  Registers the global hotkeys (Magnet) and forwards each press to `onTrigger`. Carbon hotkeys are
//  main-thread bound → `@MainActor`. Closures replace the original's `@objc` target/action. Magnet's
//  `KeyCombo(QWERTYKeyCode:carbonModifiers:)` builds a layout-independent combo (Sauce under the
//  hood) so a binding follows the physical key across keyboard layouts. The registered HotKey is
//  retained by `HotKeyCenter`; no teardown is needed (the OS reclaims Carbon hotkeys on quit).
//

import AppKit
import Magnet
import OSLog

@MainActor
final class HotKeyService {
    private let store: HotKeyStore

    /// Invoked (on the main actor) when a registered hotkey fires; AppDelegate routes it to the menu.
    var onTrigger: ((HotKeyType) -> Void)?

    private static let log = Logger(subsystem: "io.github.ponponusa.clipysi", category: "hotkey")

    init(store: HotKeyStore = HotKeyStore()) {
        self.store = store
    }

    /// Registers all global hotkeys from their stored combos. Seeds the first-run defaults before
    /// the first registration. Idempotent, so it's safe to re-run whenever a combo changes.
    func registerAll() {
        store.seedDefaultsIfNeeded()
        for type in HotKeyType.allCases {
            register(type)
        }
    }

    /// (Re)registers one hotkey: always unregister first, then register only if a combo is bound, so
    /// it's safe to call repeatedly — recording a new combo re-registers, clearing it (nil) leaves
    /// the hotkey unregistered (design §6 delta 13).
    func register(_ type: HotKeyType) {
        HotKeyCenter.shared.unregisterHotKey(with: type.identifier)
        guard let value = store.combo(for: type) else { return }
        guard let combo = KeyCombo(QWERTYKeyCode: value.keyCode, carbonModifiers: value.carbonModifiers) else {
            Self.log.error("invalid key combo for \(type.identifier, privacy: .public)")
            return
        }
        let hotKey = HotKey(identifier: type.identifier, keyCombo: combo) { [weak self] _ in
            // Magnet dispatches the handler on the main queue (ActionQueue.main), so asserting
            // main-actor isolation here is sound.
            MainActor.assumeIsolated {
                self?.onTrigger?(type)
            }
        }
        HotKeyCenter.shared.register(with: hotKey)
    }

    func unregisterAll() {
        for type in HotKeyType.allCases {
            HotKeyCenter.shared.unregisterHotKey(with: type.identifier)
        }
    }
}
