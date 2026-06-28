//
//  PanelAccentTests.swift
//  ClipyTests
//
//  The user-selectable panel accent: the six fixed swatches, raw-string round-tripping, the
//  unknown/legacy fallback, and the AppSettings read over the registered default. Pure value logic — no
//  window — so it runs headlessly.
//

import Foundation
import Testing
@testable import Clipy

@Suite struct PanelAccentTests {
    @Test func defaultIsVioletAndThereAreSixSwatches() {
        #expect(PanelAccent.default == .violet)
        #expect(PanelAccent.allCases.count == 6)
        // Raw values are stable identifiers persisted to UserDefaults — pin them.
        #expect(PanelAccent.allCases.map(\.rawValue) == ["violet", "blue", "teal", "green", "orange", "pink"])
    }

    @Test func resolveRoundTripsKnownRawValues() {
        for accent in PanelAccent.allCases {
            #expect(PanelAccent.resolve(accent.rawValue) == accent)
        }
    }

    @Test func resolveFallsBackToDefaultForUnknownOrNil() {
        #expect(PanelAccent.resolve(nil) == .violet)
        #expect(PanelAccent.resolve("") == .violet)
        #expect(PanelAccent.resolve("chartreuse") == .violet)   // unknown
        #expect(PanelAccent.resolve("VIOLET") == .violet)       // case-sensitive raw → unknown → default
    }

    @Test func appSettingsReadsRegisteredDefaultThenOverride() {
        let defaults = UserDefaults(suiteName: "ClipySiAccent-\(UUID().uuidString)")!
        DefaultsKeys.registerDefaults(in: defaults)
        let settings = AppSettings(defaults: defaults)

        // The registered default must equal PanelAccent.default (the DefaultsKeys hardcoded "violet").
        #expect(settings.panelAccent == .violet)

        defaults.set("green", forKey: DefaultsKeys.panelAccent)
        #expect(settings.panelAccent == .green)

        defaults.set("bogus", forKey: DefaultsKeys.panelAccent)
        #expect(settings.panelAccent == .violet) // unknown stored value → default
    }
}
