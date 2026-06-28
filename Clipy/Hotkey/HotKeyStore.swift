//
//  HotKeyStore.swift
//  ClipySi — Apple Silicon rewrite
//
//  Reads/writes the global hotkey combos under the original `kCPYHotKey*` keys, JSON-encoded so the
//  on-disk shape is stable. `combo(for:)` returns `nil` when a key is absent or corrupt — absence
//  means "no hotkey bound" (the original's `KeyCombo?` semantics). The code-level defaults are
//  written **once** by `seedDefaultsIfNeeded` on first run, NOT as a read-time fallback, so clearing
//  a hotkey persists as unbound instead of silently re-defaulting next launch (design §6 delta 13).
//  Legacy archived-`KeyCombo` migration (R2 secure-decode) lands with the importer; the
//  Settings recording UI (KeyHolder) writes through this same store.
//
//  Uses a plain `UserDefaults` read/write, matching `AppSettings`.
//

import Foundation

struct HotKeyStore {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The stored combo, or `nil` if the hotkey is unbound (key absent or corrupt).
    func combo(for type: HotKeyType) -> KeyComboValue? {
        guard let data = defaults.data(forKey: type.defaultsKey),
              let value = try? JSONDecoder().decode(KeyComboValue.self, from: data)
        else { return nil }
        return value
    }

    func setCombo(_ combo: KeyComboValue, for type: HotKeyType) {
        guard let data = try? JSONEncoder().encode(combo) else { return }
        defaults.set(data, forKey: type.defaultsKey)
    }

    /// Clears a hotkey binding (true-nil: removes the key so it reads back as unbound).
    func clearCombo(for type: HotKeyType) {
        defaults.removeObject(forKey: type.defaultsKey)
    }

    /// Writes each type's code-level default combo (if any) exactly once, the first time the app
    /// runs. Guarded by `hotKeysSeeded` rather than per-key absence, so a user who later clears a
    /// hotkey is not re-seeded the default on the next launch (design §6 delta 13).
    func seedDefaultsIfNeeded() {
        guard !defaults.bool(forKey: DefaultsKeys.hotKeysSeeded) else { return }
        defaults.set(true, forKey: DefaultsKeys.hotKeysSeeded)
        for type in HotKeyType.allCases {
            guard let value = type.defaultCombo else { continue }
            setCombo(value, for: type)
        }
    }
}
