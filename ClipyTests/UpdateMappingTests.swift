//
//  UpdateMappingTests.swift
//  ClipyTests
//
//  The pure Updates-pane mappings: version label, last-checked label, interval normalization.
//  The Sparkle updater itself is run-app only; this is the unit-testable logic around it.
//

import Foundation
import Testing
@testable import Clipy

@Suite struct UpdateMappingTests {
    // MARK: - Version label

    @Test func versionLabelShowsShortVersion() {
        #expect(UpdateMapping.versionLabel(shortVersion: "2.0.0", buildVersion: "") == "v2.0.0")
    }

    @Test func versionLabelAppendsBuildWhenItDiffers() {
        #expect(UpdateMapping.versionLabel(shortVersion: "2.0.0", buildVersion: "42") == "v2.0.0 (42)")
    }

    @Test func versionLabelOmitsBuildWhenSameAsShort() {
        #expect(UpdateMapping.versionLabel(shortVersion: "2.0.0", buildVersion: "2.0.0") == "v2.0.0")
    }

    @Test func versionLabelFallsBackWhenShortVersionEmpty() {
        #expect(UpdateMapping.versionLabel(shortVersion: "", buildVersion: "") == "v—")
    }

    // MARK: - Last-checked label

    @Test func lastCheckLabelIsNeverWhenNil() {
        #expect(UpdateMapping.lastCheckLabel(date: nil) == "Never")
    }

    @Test func lastCheckLabelFormatsADate() {
        let label = UpdateMapping.lastCheckLabel(date: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(label != "Never")
        #expect(!label.isEmpty)
    }

    // MARK: - Interval normalization

    @Test func normalizedIntervalKeepsKnownChoices() {
        #expect(UpdateMapping.normalizedInterval(UpdateMapping.dailyInterval) == UpdateMapping.dailyInterval)
        #expect(UpdateMapping.normalizedInterval(UpdateMapping.weeklyInterval) == UpdateMapping.weeklyInterval)
        #expect(UpdateMapping.normalizedInterval(UpdateMapping.monthlyInterval) == UpdateMapping.monthlyInterval)
    }

    @Test func normalizedIntervalDefaultsUnknownToDaily() {
        #expect(UpdateMapping.normalizedInterval(0) == UpdateMapping.dailyInterval)
        #expect(UpdateMapping.normalizedInterval(-1) == UpdateMapping.dailyInterval)
        #expect(UpdateMapping.normalizedInterval(12_345) == UpdateMapping.dailyInterval)
    }
}
