//
//  ExcludedAppInfoTests.swift
//  ClipyTests
//
//  The `Info.plist` → (bundle id, name) extraction backing the Excluded Apps "Add" flow. Mirrors
//  the original `CPYAppInfo(info:)` semantics exactly (design §2.4), so the same `.app` yields
//  the same exclusion record.
//

import Foundation
import Testing
@testable import Clipy

@Suite struct ExcludedAppInfoTests {

    @Test func extractsIdentifierAndBundleName() {
        let info = ExcludedAppInfo(infoDictionary: [
            kCFBundleIdentifierKey as String: "com.example.app",
            kCFBundleNameKey as String: "Example",
            kCFBundleExecutableKey as String: "ExampleExec"
        ])
        #expect(info == ExcludedAppInfo(infoDictionary: [
            kCFBundleIdentifierKey as String: "com.example.app",
            kCFBundleNameKey as String: "Example"
        ]))
        #expect(info?.bundleIdentifier == "com.example.app")
        // Bundle name wins over the executable name when both are present.
        #expect(info?.name == "Example")
    }

    @Test func fallsBackToExecutableNameWhenBundleNameMissing() {
        let info = ExcludedAppInfo(infoDictionary: [
            kCFBundleIdentifierKey as String: "com.example.app",
            kCFBundleExecutableKey as String: "ExampleExec"
        ])
        #expect(info?.name == "ExampleExec")
    }

    @Test func nilWhenIdentifierMissing() {
        let info = ExcludedAppInfo(infoDictionary: [
            kCFBundleNameKey as String: "Example"
        ])
        #expect(info == nil)
    }

    @Test func nilWhenBothNameKeysMissing() {
        let info = ExcludedAppInfo(infoDictionary: [
            kCFBundleIdentifierKey as String: "com.example.app"
        ])
        #expect(info == nil)
    }
}
