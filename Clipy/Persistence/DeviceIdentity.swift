//
//  DeviceIdentity.swift
//  ClipySi — Apple Silicon rewrite
//
//  A stable per-device identifier, minted once and persisted in UserDefaults. Capture stamps it
//  onto each clip as `originDeviceID` so sync can attribute a record's origin and
//  break HLC ties. It is not secret — just an opaque UUID — so UserDefaults (not the Keychain) is
//  the right home, and it is intentionally NOT the vault key or the device-local history key.
//

import Foundation

enum DeviceIdentity {
    /// Serializes the read-or-mint so two concurrent captures can't both mint (and the second
    /// overwrite the first), which would give one device two ids. Not cached across calls so a
    /// test's injected defaults suite stays authoritative.
    private static let lock = NSLock()

    /// The current device's id, minting and persisting one on first use. Reads/writes the supplied
    /// defaults so tests can pass an isolated suite instead of `.standard`.
    static func current(in defaults: UserDefaults = .standard) -> String {
        lock.withLock {
            if let existing = defaults.string(forKey: DefaultsKeys.deviceID) {
                return existing
            }
            let id = UUID().uuidString
            defaults.set(id, forKey: DefaultsKeys.deviceID)
            return id
        }
    }
}
