//
//  LoginItemService.swift
//  ClipySi — Apple Silicon rewrite
//
//  Launch-at-login, backed by `SMAppService.mainApp`. The original used the LoginServiceKit package
//  (a black box with NO separate helper bundle), so there is nothing to migrate — just register the
//  main app (design §3.7 / §6 delta 1). The `loginItem` UserDefaults Bool stays the user's
//  *intent*; this reconciles it with the real OS registration state. The SMAppService calls are
//  injected (struct-of-closures) so the status mapping + reconcile decision are unit-testable without
//  touching the system — the real `register()` only works from a signed app in /Applications (§6 R2).
//

import ServiceManagement

/// The login-item state surfaced to the UI, mapped 1:1 from `SMAppService.Status` so the view and
/// tests don't depend on the system enum and `@unknown` is handled in one place.
enum LoginItemStatus: Equatable {
    case enabled, requiresApproval, notRegistered, notFound

    init(_ status: SMAppService.Status) {
        switch status {
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notRegistered: self = .notRegistered
        case .notFound: self = .notFound
        @unknown default: self = .notRegistered
        }
    }
}

/// Thin wrapper over `SMAppService.mainApp` with injectable operations, so callers/tests can stub the
/// system without registering anything.
struct LoginItemService {
    var statusProvider: () -> SMAppService.Status
    var registerImpl: () throws -> Void
    var unregisterImpl: () throws -> Void
    var openSettingsImpl: () -> Void

    var status: LoginItemStatus { LoginItemStatus(statusProvider()) }

    /// Registers (enable) or unregisters (disable) the login item to match the user's intent.
    func setEnabled(_ enabled: Bool) throws {
        if enabled { try registerImpl() } else { try unregisterImpl() }
    }

    func openSystemSettings() { openSettingsImpl() }

    /// The launch-time reconcile decision: auto-(re)register whenever the user wants login-at-launch
    /// but the OS has it `.notRegistered`. This self-heals a dropped registration every launch (as the
    /// original's `reflectLoginItemState` did via LoginServiceKit) without nagging — a successful
    /// register moves the status to `.enabled`, and `.requiresApproval` (the user must act in System
    /// Settings) is excluded, so neither re-fires here. (Supersedes the design's §6 delta 12 nag-flag
    /// gate, which a review found would strand a user whose registration later drops.)
    static func shouldAutoRegister(intent: Bool, status: LoginItemStatus) -> Bool {
        intent && status == .notRegistered
    }

    /// The production wiring against the real `SMAppService.mainApp`.
    static var live: LoginItemService {
        LoginItemService(
            statusProvider: { SMAppService.mainApp.status },
            registerImpl: { try SMAppService.mainApp.register() },
            unregisterImpl: { try SMAppService.mainApp.unregister() },
            openSettingsImpl: { SMAppService.openSystemSettingsLoginItems() }
        )
    }
}
