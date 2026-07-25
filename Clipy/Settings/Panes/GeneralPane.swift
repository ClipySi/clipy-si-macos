//
//  GeneralPane.swift
//  ClipySi — Apple Silicon rewrite
//
//  The General settings pane, grouped top-to-bottom: the display-language picker (moved off the
//  status menu); launch-on-login and the status-bar icon style; max history size, sort order, and
//  paste-after-selection; and the modifier-gated paste actions (graduated here from the former Beta
//  pane). Two-way bound to the original-compatible UserDefaults keys via `@Shared(.appStorage)`
//  (swift-sharing) — the same store `AppSettings` reads, so a change here is immediately visible to
//  capture/menu. See the design §1.3 / §2.1.
//
//  The login toggle writes the `loginItem` Bool (user intent) AND drives the SMAppService
//  register/unregister side-effect, reflecting `.requiresApproval` with a deep-link into
//  System Settings. The status-bar style change posts `.clipySiStatusItemStyleChanged` so AppDelegate
//  installs/removes the item live (§6 delta 5). The language picker writes the per-app
//  `AppleLanguages` override (`LanguagePreference`); it only takes effect at the next process start,
//  so a "Relaunch Now" affordance appears while the pick differs from the running language.
//

import AppKit
import OSLog
import Sharing
import SwiftUI

struct GeneralPane: View {
    @Shared(.appStorage(DefaultsKeys.loginItem)) private var loginItem = false
    @Shared(.appStorage(DefaultsKeys.inputPasteCommand)) private var inputPasteCommand = true
    @Shared(.appStorage(DefaultsKeys.maxHistorySize)) private var maxHistorySize = 30
    @Shared(.appStorage(DefaultsKeys.historySortNewestFirst)) private var historySortNewestFirst = true
    @Shared(.appStorage(DefaultsKeys.moveClipToTopOnPaste)) private var moveClipToTopOnPaste = true
    @Shared(.appStorage(DefaultsKeys.showStatusItem)) private var showStatusItem = 1
    @Shared(.appStorage(DefaultsKeys.panelAccent)) private var panelAccent = PanelAccent.default.rawValue
    @Shared(.appStorage(DefaultsKeys.panelPreviewSide)) private var previewSide = PanelPreviewSide.right.rawValue
    @Shared(.appStorage(DefaultsKeys.panelPreviewEdgeFlip)) private var previewEdgeFlip = true

    // Modifier-gated paste actions (read by PasteService at selection time). Verbatim original
    // keys (incl. the intentionally lowercase `kCPYBetapasteAndDeleteHistoryModifier`).
    @Shared(.appStorage(DefaultsKeys.pastePlainText)) private var pastePlainText = true
    @Shared(.appStorage(DefaultsKeys.pastePlainTextModifier)) private var pastePlainTextModifier = 0
    @Shared(.appStorage(DefaultsKeys.deleteHistory)) private var deleteHistory = false
    @Shared(.appStorage(DefaultsKeys.deleteHistoryModifier)) private var deleteHistoryModifier = 0
    @Shared(.appStorage(DefaultsKeys.pasteAndDeleteHistory)) private var pasteAndDeleteHistory = false
    @Shared(.appStorage(DefaultsKeys.pasteAndDeleteHistoryModifier)) private var pasteAndDeleteHistoryModifier = 0

    @State private var loginStatus: LoginItemStatus = .notRegistered
    @State private var languageOverride: String?

    /// The language override active when General first appeared this session — i.e. the language the
    /// running app actually loaded (the bundle resolves localization once, at launch). Captured once
    /// so the "Relaunch Now" hint persists across tab switches that recreate the pane, and clears
    /// only after an actual relaunch. `@MainActor` since only the (main-actor) UI touches it.
    @MainActor private static var launchOverride: String?
    @MainActor private static var didCaptureLaunch = false

    private let loginService = LoginItemService.live
    private static let log = Logger(subsystem: "io.github.ponponusa.clipysi", category: "login")

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: $languageOverride) {
                    Text("System (default)").tag(String?.none)
                    ForEach(LanguagePreference.supported) { language in
                        Text(language.autonym).tag(String?.some(language.code))
                    }
                }
                .onChange(of: languageOverride) { _, newValue in
                    LanguagePreference.setOverride(newValue, defaults: .standard)
                }
                if languageOverride != Self.launchOverride {
                    LabeledContent {
                        Button("Relaunch Now") {
                            NotificationCenter.default.post(name: .clipySiLanguageChanged, object: nil)
                        }
                    } label: {
                        Text("Language changes take effect after you relaunch ClipySi.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Toggle("Launch ClipySi on login", isOn: Binding($loginItem))
                if loginStatus == .requiresApproval {
                    LabeledContent {
                        Button("Open Login Items…") { loginService.openSystemSettings() }
                    } label: {
                        Text("Approve ClipySi under Login Items in System Settings to finish enabling launch at login.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Picker("Status Bar icon style:", selection: Binding($showStatusItem)) {
                    Text("Black").tag(1)
                    Text("White").tag(2)
                    Text("None").tag(0)
                }
            }

            Section {
                // A centred HStack rather than LabeledContent: the taller swatch row makes LabeledContent
                // top-align its label, so the "Accent color" text sat above the swatches' centre.
                HStack {
                    Text("Accent color")
                    Spacer(minLength: 12)
                    AccentColorPicker(selection: Binding($panelAccent))
                }
                Picker("Preview pane position:", selection: Binding($previewSide)) {
                    Text("Right").tag(PanelPreviewSide.right.rawValue)
                    Text("Left").tag(PanelPreviewSide.left.rawValue)
                }
                Toggle("Switch sides when there is no room on the screen", isOn: Binding($previewEdgeFlip))
            } header: {
                Text("Appearance")
            } footer: {
                Text("The highlight color used in the clipboard history popup, and which side its preview pane opens on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Max clipboard history size:") {
                    HStack(spacing: 6) {
                        TextField("", value: Binding($maxHistorySize), format: .number)
                            .labelsHidden()
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                        Stepper("", value: Binding($maxHistorySize),
                                in: SettingsMapping.minHistorySize...SettingsMapping.maxHistorySize)
                            .labelsHidden()
                        Text("items")
                            .foregroundStyle(.secondary)
                    }
                }
                Picker("Sort history order by:", selection: sortOrderBinding) {
                    Text("Date Created").tag(0)
                    Text("Last Used").tag(1)
                }
                Toggle("Move a pasted item to the top of the history", isOn: Binding($moveClipToTopOnPaste))
                Toggle("Input \"⌘ + V\" after menu item selection", isOn: Binding($inputPasteCommand))
            } footer: {
                Text("When on, an item you paste from the history moves back to the top. Turn it off to leave the history order unchanged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                pasteActionRow("Paste as PlainText",
                               isOn: Binding($pastePlainText), modifier: Binding($pastePlainTextModifier))
                pasteActionRow("Delete history",
                               isOn: Binding($deleteHistory), modifier: Binding($deleteHistoryModifier))
                pasteActionRow("Paste and delete history",
                               isOn: Binding($pasteAndDeleteHistory), modifier: Binding($pasteAndDeleteHistoryModifier))
            } header: {
                Text("Action")
            } footer: {
                Text("Hold the chosen modifier key while choosing an item from the clipboard menu to run that action instead of a normal paste.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsLayout.paneWidth)
        .onChange(of: maxHistorySize) { _, newValue in
            // The Stepper is bounded, but the TextField can submit any integer; re-clamp into
            // 1...100_000 (lower bound = the original's ≥ 1 minimum, design AC2; upper bound
            // keeps history trimming effective so the encrypted DB can't grow unbounded).
            let clamped = SettingsMapping.clampMaxHistorySize(newValue)
            if clamped != newValue { $maxHistorySize.withLock { $0 = clamped } }
        }
        .onChange(of: showStatusItem) { _, _ in
            NotificationCenter.default.post(name: .clipySiStatusItemStyleChanged, object: nil)
        }
        .onAppear {
            loginStatus = loginService.status
            // Capture the running language once (first appearance ≈ launch — language can only be
            // changed via this very picker), then load the current pick.
            if !Self.didCaptureLaunch {
                Self.launchOverride = LanguagePreference.currentOverride(defaults: .standard)
                Self.didCaptureLaunch = true
            }
            languageOverride = LanguagePreference.currentOverride(defaults: .standard)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Refresh after the user approves in System Settings (via "Open Login Items…") and returns,
            // so the requiresApproval hint clears instead of going stale.
            loginStatus = loginService.status
        }
        .onChange(of: loginItem) { _, isOn in
            // The stored Bool is the user's intent; apply it to the real OS login-item registration.
            // From an unsigned/DerivedData build `register()` throws (§6 R2) — log and reflect status.
            do {
                try loginService.setEnabled(isOn)
            } catch {
                Self.log.error("login item \(isOn ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
            loginStatus = loginService.status
        }
    }

    /// A paste-action toggle paired with its modifier popup (the popup is meaningful only while the
    /// action is enabled). Ported from the former Beta pane's `betaRow`.
    private func pasteActionRow(_ title: LocalizedStringKey, isOn: Binding<Bool>, modifier: Binding<Int>) -> some View {
        HStack {
            Toggle(title, isOn: isOn)
            Spacer()
            ModifierPicker(selection: modifier)
                .disabled(!isOn.wrappedValue)
        }
    }

    /// Bridges the 2-item "sort order" popup to the stored `historySortNewestFirst` Bool.
    private var sortOrderBinding: Binding<Int> {
        Binding(
            get: { SettingsMapping.sortOrderIndex(newestFirst: historySortNewestFirst) },
            set: { newIndex in
                $historySortNewestFirst.withLock { $0 = SettingsMapping.sortNewestFirst(fromIndex: newIndex) }
            }
        )
    }
}
