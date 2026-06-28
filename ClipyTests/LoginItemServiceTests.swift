//
//  LoginItemServiceTests.swift
//  ClipyTests
//
//  The login-item state mapping, the launch reconcile decision (§6 delta 12), and that `setEnabled`
//  routes to register/unregister. The real `SMAppService.register()` only works from a signed app in
//  /Applications (§6 R2), so the system call itself is run-app — here it's stubbed.
//

import ServiceManagement
import Testing
@testable import Clipy

@Suite struct LoginItemServiceTests {

    @Test func mapsEverySMAppServiceStatus() {
        #expect(LoginItemStatus(.enabled) == .enabled)
        #expect(LoginItemStatus(.requiresApproval) == .requiresApproval)
        #expect(LoginItemStatus(.notRegistered) == .notRegistered)
        #expect(LoginItemStatus(.notFound) == .notFound)
    }

    @Test func autoRegistersOnlyWhenWantedAndUnregistered() {
        // Self-heals every launch when wanted but unregistered; never fires for enabled/approval
        // (those don't need or wouldn't benefit from a re-register) or when the user doesn't want it.
        #expect(LoginItemService.shouldAutoRegister(intent: true, status: .notRegistered))

        #expect(LoginItemService.shouldAutoRegister(intent: false, status: .notRegistered) == false)
        #expect(LoginItemService.shouldAutoRegister(intent: true, status: .enabled) == false)
        #expect(LoginItemService.shouldAutoRegister(intent: true, status: .requiresApproval) == false)
        #expect(LoginItemService.shouldAutoRegister(intent: true, status: .notFound) == false)
    }

    @Test func setEnabledRoutesToRegisterOrUnregister() throws {
        final class Spy { var registered = 0; var unregistered = 0 }
        let spy = Spy()
        let service = LoginItemService(
            statusProvider: { .notRegistered },
            registerImpl: { spy.registered += 1 },
            unregisterImpl: { spy.unregistered += 1 },
            openSettingsImpl: {}
        )

        try service.setEnabled(true)
        #expect(spy.registered == 1)
        #expect(spy.unregistered == 0)

        try service.setEnabled(false)
        #expect(spy.registered == 1)
        #expect(spy.unregistered == 1)
    }

    @Test func statusMapsThroughTheInjectedProvider() {
        let service = LoginItemService(
            statusProvider: { .requiresApproval },
            registerImpl: {}, unregisterImpl: {}, openSettingsImpl: {}
        )
        #expect(service.status == .requiresApproval)
    }
}
