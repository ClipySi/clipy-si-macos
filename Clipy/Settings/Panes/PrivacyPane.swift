//
//  PrivacyPane.swift
//  ClipySi — Apple Silicon rewrite
//
//  The Privacy settings pane: controls for the on-device secret-masking feature backed by
//  the shared Rust core (`ClipySiCore`). Masking is ON by default (a clipboard manager captures
//  passwords/tokens, so they're hidden out of the box). Two-way bound to the rewrite-only
//  `clipyMask*` UserDefaults keys via `@Shared(.appStorage)` — the same store `AppSettings` /
//  `MaskingService` read, so a change here takes effect on the next menu open.
//

import Sharing
import SwiftUI

struct PrivacyPane: View {
    @Shared(.appStorage(DefaultsKeys.maskSecretsInMenu)) private var maskSecrets = true
    @Shared(.appStorage(DefaultsKeys.maskStyle)) private var maskStyle = "full"
    @Shared(.appStorage(DefaultsKeys.requireAuthForSecretReveal)) private var requireAuth = false

    /// Whether this Mac can evaluate local auth (Touch ID / login password). Resolved once on
    /// appear; when false the reveal-auth setting can't be enforced and we say so.
    @State private var canAuthenticate = true

    var body: some View {
        Form {
            Section {
                Toggle("Mask detected secrets", isOn: Binding($maskSecrets))
                Picker("Mask style", selection: Binding($maskStyle)) {
                    Text("Hide entirely").tag("full")
                    Text("Show first 2 characters").tag("prefix2")
                    Text("Show last 4 characters").tag("suffix4")
                }
                .disabled(!maskSecrets)
            } header: {
                Text("Masking")
            } footer: {
                Text("Passwords, API keys, and tokens detected in copied text are hidden in the menu and history list. Detection runs entirely on-device — nothing is ever sent anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Require authentication to reveal a secret", isOn: Binding($requireAuth))
                    .disabled(!maskSecrets)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ask for Touch ID or your login password before a masked value is shown or pasted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if maskSecrets, requireAuth, !canAuthenticate {
                        Text("This Mac has no Touch ID or login password set, so this protection can’t be enforced.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsLayout.paneWidth)
        .onAppear { canAuthenticate = AuthGate.canAuthenticate }
    }
}

#Preview {
    PrivacyPane()
}
