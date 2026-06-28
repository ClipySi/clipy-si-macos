//
//  DiagnosticsPane.swift
//  ClipySi — Apple Silicon rewrite
//
//  The Diagnostics settings pane. Controls the local diagnostics collection level (default
//  Off). Two-way bound to the rewrite-only `clipyDiagnosticsLevel` key via `@Shared(.appStorage)`,
//  the same store `AppSettings` / `DiagnosticsRecorder.live` read. NOTHING is ever sent
//  automatically — distribution is Developer ID direct, macOS crashes flow through Apple's
//  Organizer (OS-level opt-in, body-free), and the level only gates *local* collection that the
//  user can choose to export. The "Export…" / crash count controls are added separately.
//

import AppKit
import Sharing
import SwiftUI

/// Shared links/strings for the diagnostics UI (pane + first-run consent).
enum DiagnosticsInfo {
    /// The public privacy policy. Lives in the repo's `docs/`.
    static let privacyPolicyURL = URL(string: "https://github.com/ClipySi/clipy-si-macos/blob/main/docs/PRIVACY.md")!
}

struct DiagnosticsPane: View {
    @Shared(.appStorage(DefaultsKeys.diagnosticsLevel)) private var levelRaw = "none"

    /// Stored MetricKit crash count, refreshed on appear.
    @State private var crashCount = 0
    /// Set when an export fails (shows an alert).
    @State private var exportFailed = false

    private var level: DiagnosticLevel { DiagnosticLevel(raw: levelRaw) }

    var body: some View {
        Form {
            Section {
                Picker("Diagnostics", selection: Binding($levelRaw)) {
                    Text("Off — collect nothing").tag("none")
                    Text("Minimal — crashes only").tag("minimal")
                    Text("Standard — crashes and coarse errors").tag("standard")
                    Text("Detailed — also recent feature breadcrumbs").tag("detailed")
                }
                .pickerStyle(.inline)
                .onChange(of: levelRaw) { _, _ in
                    // AppDelegate (un)subscribes the MetricKit crash receiver to match the new level.
                    NotificationCenter.default.post(name: .clipySiDiagnosticsLevelChanged, object: nil)
                }
            } header: {
                Text("Diagnostics level")
            } footer: {
                Text("Diagnostics are collected only on your Mac and are never sent anywhere automatically. Your clipboard contents, history, snippets, and searches are never collected. Default is Off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("What each level collects") {
                LabeledContent("Minimal") {
                    Text("Crash reports, app and macOS version, CPU architecture.")
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Standard") {
                    Text("Minimal, plus a coarse feature area on errors and the sync type.")
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Detailed") {
                    Text("Standard, plus recent coarse breadcrumbs (feature names only).")
                        .multilineTextAlignment(.trailing)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .disabled(level == .none)

            Section("Crash reports") {
                LabeledContent("Stored on this Mac", value: "\(crashCount)")
                Button("Export Diagnostics…", action: exportDiagnostics)
                Button("Delete Stored Diagnostics", role: .destructive, action: deleteDiagnostics)
                    .disabled(crashCount == 0)
            }

            Section {
                Text("Never collected: clipboard contents, clip titles, snippet bodies, search queries, email addresses, tokens, encryption keys, or source-app details.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("Privacy Policy", destination: DiagnosticsInfo.privacyPolicyURL)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsLayout.paneWidth)
        .onAppear { crashCount = DiagnosticsStore.live.crashCount }
        .alert("Couldn’t export diagnostics", isPresented: $exportFailed) {
            Button("OK", role: .cancel) {}
        }
    }

    /// Build a body-free export bundle (the typed envelope + any stored crash payloads) in a temp
    /// folder and reveal it in Finder so the user can attach it to a bug report.
    private func exportDiagnostics() {
        do {
            let envelope = try DiagnosticsRecorder.live.exportJSON()
            let folder = try DiagnosticsStore.live.writeExportBundle(
                envelopeJSON: envelope, into: FileManager.default.temporaryDirectory)
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } catch {
            exportFailed = true
        }
        crashCount = DiagnosticsStore.live.crashCount // refresh in case a crash arrived meanwhile
    }

    /// Remove the locally stored crash payloads (PRIVACY.md: the user can delete stored diagnostics).
    private func deleteDiagnostics() {
        DiagnosticsStore.live.deleteStoredCrashPayloads()
        crashCount = DiagnosticsStore.live.crashCount
    }
}

#Preview {
    DiagnosticsPane()
}
