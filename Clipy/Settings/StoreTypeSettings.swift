//
//  StoreTypeSettings.swift
//  ClipySi — Apple Silicon rewrite
//
//  Two-way model for the Type pane's `kCPYPrefStoreTypesKey` `[String: Bool]` dictionary. This
//  stays OFF `@Shared(.appStorage)` on purpose: swift-sharing's dictionary support would persist a
//  JSON blob, but the original (and `AppSettings.shouldStore`) read a plain plist dictionary, so we
//  keep that format. Holding the canonical dict in one retained, observable value means flipping
//  several toggles in quick succession can't lose an update via read-modify-write on
//  `UserDefaults.dictionary` (design §1.3 / §6 delta 8).
//

import Foundation
import Observation

@MainActor
@Observable
final class StoreTypeSettings {
    private let defaults: UserDefaults
    private(set) var types: [String: Bool]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.dictionary(forKey: DefaultsKeys.storeTypes) ?? [:]
        types = Dictionary(uniqueKeysWithValues: DefaultsKeys.storeTypeTokens.map { token in
            (token, StoreTypeSettings.boolValue(stored[token]))
        })
    }

    func isEnabled(_ token: String) -> Bool {
        types[token] ?? true
    }

    func setEnabled(_ enabled: Bool, for token: String) {
        types[token] = enabled
        // Write the whole retained dict — the single source of truth — so a concurrent flip of
        // another token can't be clobbered by re-reading a stale copy from `UserDefaults`.
        defaults.set(types, forKey: DefaultsKeys.storeTypes)
    }

    /// Absent ⇒ enabled; tolerates a Bool or an NSNumber-backed Bool, matching `AppSettings.shouldStore`.
    private static func boolValue(_ value: Any?) -> Bool {
        (value as? Bool) ?? ((value as? NSNumber)?.boolValue ?? true)
    }
}
