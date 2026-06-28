//
//  SyncPane.swift
//  ClipySi — Apple Silicon rewrite
//
//  The minimal local-folder sync UI (design §10): choose a folder (with a cloud-
//  location warning, never a block), create/unlock the vault passphrase (12-char floor + a coarse
//  strength meter), the opt-in Keychain checkbox, the master toggle, Sync Now, and a status line.
//  All real work happens in SyncCoordinator; this view never touches keys or the engine directly.
//

import AppKit
import Sharing
import SwiftUI

struct SyncPane: View {
    @Shared(.appStorage(DefaultsKeys.syncEnabled)) private var syncEnabled = false
    @Shared(.appStorage(DefaultsKeys.syncFolderPath)) private var folderPath: String?
    @Shared(.appStorage(DefaultsKeys.saveVaultKeyInKeychain)) private var saveKeyInKeychain = false

    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var unlockFailed = false

    let coordinator: SyncCoordinator

    var body: some View {
        Form {
            Section {
                Toggle("Sync clipboard history between Macs", isOn: Binding($syncEnabled))
                    .onChange(of: syncEnabled) { coordinator.refresh() }
            } footer: {
                Text("Only your clipboard history syncs. Clips detected as secrets never leave this Mac. Every Mac sharing the folder needs the same passphrase.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if syncEnabled {
                folderSection
                vaultSection
                statusSection
            }
        }
        .formStyle(.grouped)
        .onAppear { coordinator.refresh() }
        .onChange(of: saveKeyInKeychain) { _, isOn in
            // Opting out must remove the stored derived key, or it would linger in the Keychain.
            if !isOn { try? VaultKeyStore.delete() }
        }
    }

    // MARK: - Folder

    private var folderSection: some View {
        Section("Sync Folder") {
            HStack {
                Text(folderPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? String(localized: "Not configured"))
                    .truncationMode(.middle)
                    .lineLimit(1)
                    .foregroundStyle(folderPath == nil ? .secondary : .primary)
                Spacer()
                Button("Choose…") { chooseFolder() }
            }
            if let folderPath, SyncFolderHints.looksCloudSynced(folderPath) {
                Label("This folder is synced by a cloud service. Its provider can see the encrypted vault files and device metadata — use a strong passphrase.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Use This Folder")
        if panel.runModal() == .OK, let url = panel.url {
            $folderPath.withLock { $0 = url.path }
            coordinator.refresh()
        }
    }

    // MARK: - Vault

    @ViewBuilder
    private var vaultSection: some View {
        switch coordinator.status {
        case .needsVault:
            Section("Create Vault") {
                SecureField("Passphrase (12 characters or more)", text: $passphrase)
                SecureField("Confirm passphrase", text: $confirmation)
                strengthMeter
                Toggle("Remember the vault key in this Mac's Keychain", isOn: Binding($saveKeyInKeychain))
                Button("Create Vault") { createVault() }
                    .disabled(!canCreate)
            }
        case .locked:
            Section("Unlock Vault") {
                SecureField("Passphrase", text: $passphrase)
                Toggle("Remember the vault key in this Mac's Keychain", isOn: Binding($saveKeyInKeychain))
                Button("Unlock") { unlock() }
                    .disabled(passphrase.isEmpty)
                if unlockFailed {
                    Text("Wrong passphrase for this vault.")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
        default:
            EmptyView()
        }
    }

    private var canCreate: Bool {
        passphrase.count >= SyncCoordinator.minPassphraseLength && passphrase == confirmation
    }

    private var strengthMeter: some View {
        let score = PassphraseStrength.score(passphrase)
        return HStack(spacing: 6) {
            ProgressView(value: Double(score), total: 4)
                .tint(score >= 3 ? .green : (score >= 2 ? .yellow : .red))
            Text(strengthLabel(score))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func strengthLabel(_ score: Int) -> String {
        switch score {
        case ..<2: String(localized: "Weak")
        case 2: String(localized: "Fair")
        case 3: String(localized: "Good")
        default: String(localized: "Strong")
        }
    }

    private func createVault() {
        do {
            try coordinator.createVault(passphrase: passphrase)
            passphrase = ""
            confirmation = ""
            unlockFailed = false
        } catch {
            unlockFailed = true
        }
    }

    private func unlock() {
        do {
            try coordinator.unlock(passphrase: passphrase)
            passphrase = ""
            unlockFailed = false
        } catch {
            unlockFailed = true
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            HStack {
                Text(statusLabel)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Sync Now") { Task { await coordinator.syncNow() } }
                    .disabled(!(coordinator.status == .ready || coordinator.status == .failed))
            }
        } footer: {
            if let last = coordinator.lastSyncAt {
                Text("Last sync: \(last.formatted(date: .abbreviated, time: .shortened))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusLabel: String {
        switch coordinator.status {
        case .off: String(localized: "Sync is off.")
        case .needsFolder: String(localized: "Choose a sync folder to begin.")
        case .needsVault: String(localized: "No vault in this folder yet — create one.")
        case .locked: String(localized: "Vault locked — enter your passphrase.")
        case .ready: String(localized: "Ready.")
        case .syncing: String(localized: "Syncing…")
        case .failed: String(localized: "Last sync failed — will retry.")
        }
    }
}
