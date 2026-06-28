//
//  AccessibilityServiceTests.swift
//  ClipyTests
//
//  The AX trust check is injectable so the gate logic is testable without touching the real
//  Accessibility subsystem (the system check + the deny alert are run-app verified).
//

import Testing
@testable import Clipy

@Suite struct AccessibilityServiceTests {
    @Test func isTrustedReflectsTheInjectedCheck() {
        #expect(AccessibilityService(trustedCheck: { _ in true }).isTrusted(prompt: false) == true)
        #expect(AccessibilityService(trustedCheck: { _ in false }).isTrusted(prompt: false) == false)
    }

    @Test func passesThePromptFlagThrough() {
        var seen: Bool?
        let service = AccessibilityService(trustedCheck: { prompt in seen = prompt; return true })
        _ = service.isTrusted(prompt: true)
        #expect(seen == true)
    }
}
