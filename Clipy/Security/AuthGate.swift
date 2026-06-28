//
//  AuthGate.swift
//  ClipySi — Apple Silicon rewrite
//
//  Optional local-authentication gate in front of revealing/pasting a *detected secret*
//  (when "Require authentication to reveal a secret" is on in the Privacy pane). Wraps
//  LocalAuthentication so callers stay testable: the `authenticate` closure is injectable, the
//  live value evaluates `.deviceOwnerAuthentication` (Touch ID with login-password fallback), and
//  tests/previews use `.allow`.
//
//  Fail-open policy: when the device has no authentication configured at all
//  (`canEvaluatePolicy` is false — no Touch ID *and* no password), there is nothing to gate
//  against and refusing would lock the user out of their own clipboard, so we allow. A machine
//  with no login password offers no protection to begin with. This is intentional; see the
//  Privacy pane copy.
//

import Foundation
import LocalAuthentication
import OSLog

struct AuthGate: Sendable {
    /// Prompt for authentication with a user-facing reason. Returns whether the user is authorized.
    var authenticate: @Sendable (_ reason: String) async -> Bool
}

extension AuthGate {
    /// LocalAuthentication-backed gate. A fresh `LAContext` per call (a context can't be reused
    /// after one evaluation). Never logs the value being revealed.
    static let live = AuthGate { reason in
        let log = Logger(subsystem: "io.github.ponponusa.clipysi", category: "security")
        let context = LAContext()
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            log.warning("secret-paste protection cannot be enforced: no Touch ID / login password configured; allowing")
            return true // fail-open: nothing to authenticate against (see file note + Privacy pane warning)
        }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                // Log the failure reason (never a value) for diagnosability; behaviour is unchanged.
                if let error, !success {
                    log.error("auth gate evaluation failed: \(error.localizedDescription, privacy: .public)")
                }
                continuation.resume(returning: success)
            }
        }
    }

    /// Always authorizes — for tests/previews and as the value used when the feature is off.
    static let allow = AuthGate { _ in true }

    /// Whether this Mac can evaluate local authentication at all (Touch ID or a login password
    /// configured). When `false`, `live` fails open — the Privacy pane surfaces a warning so the
    /// user knows the "require authentication" setting can't actually be enforced.
    static var canAuthenticate: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }
}
