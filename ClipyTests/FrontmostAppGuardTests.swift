//
//  FrontmostAppGuardTests.swift
//  ClipyTests
//
//  R5 gate logic: a paste proceeds only if the frontmost app is unchanged between menu-open
//  (snapshot) and the moment of paste (re-check). The frontmost provider is injected.
//

import Testing
@testable import Clipy

@MainActor
@Suite struct FrontmostAppGuardTests {
    @Test func proceedsWhenFrontmostUnchanged() {
        let guardian = FrontmostAppGuard(provider: { "com.example.editor" })
        #expect(guardian.stillMatches(guardian.snapshot()) == true)
    }

    @Test func abortsWhenFrontmostChanged() {
        var current = "com.example.editor"
        let guardian = FrontmostAppGuard(provider: { current })
        let snapshot = guardian.snapshot()
        current = "com.example.other"
        #expect(guardian.stillMatches(snapshot) == false)
    }

    @Test func abortsWhenSnapshotWasNil() {
        let guardian = FrontmostAppGuard(provider: { nil })
        #expect(guardian.stillMatches(nil) == false)
    }

    @Test func abortsWhenFrontmostBecameNil() {
        var current: String? = "com.example.editor"
        let guardian = FrontmostAppGuard(provider: { current })
        let snapshot = guardian.snapshot()
        current = nil
        #expect(guardian.stillMatches(snapshot) == false)
    }
}
