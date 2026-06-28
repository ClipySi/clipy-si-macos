//
//  AboutView.swift
//  ClipySi — Apple Silicon rewrite
//
//  The standalone About window, carved out of the former Settings "Updates" tab. A centered,
//  macOS-style about panel — app icon, name, version, copyright, a source link — followed by the
//  Sparkle update controls (version / last-checked / Check Now / auto-check toggle + interval).
//
//  The update controls persist under the verbatim original kCPY keys
//  (`kCPYEnableAutomaticCheckKey` / `kCPYUpdateCheckIntervalKey`) and are pushed into the live
//  Sparkle `UpdaterService`, which AppDelegate injects into the environment when it opens the
//  window. The updater is optional so previews and a key-less dev build still render (no updater →
//  the controls render inert). See AppDelegate.openAbout and DESIGN.md §4.6.
//

import Sharing
import SwiftUI

struct AboutView: View {
    // Defaults mirror DefaultsKeys.registeredDefaults (auto-check ON since the first public
    // release ships a real appcast). See UpdatesPane history — these moved here verbatim with the tab.
    @Shared(.appStorage(DefaultsKeys.enableAutomaticCheck)) private var autoCheck = true
    @Shared(.appStorage(DefaultsKeys.updateCheckInterval)) private var interval = 86_400
    @Environment(UpdaterService.self) private var updater: UpdaterService?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            updateForm
        }
        .frame(width: AboutLayout.width)
    }

    // MARK: - About header

    private var header: some View {
        VStack(spacing: 6) {
            Image(nsImage: Self.appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)

            Text(Self.appName)
                .font(.title2.weight(.semibold))

            Text(UpdateMapping.versionLabel(shortVersion: Self.shortVersion, buildVersion: Self.buildVersion))
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if let copyright = Self.copyright {
                Text(copyright)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)
            }

            HStack(spacing: 14) {
                Link("GitHub", destination: Self.repositoryURL)
                Link("Privacy Policy", destination: DiagnosticsInfo.privacyPolicyURL)
            }
            .font(.callout)
            .padding(.top, 4)
        }
        .padding(.top, 28)
        .padding(.bottom, 20)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Update controls (moved verbatim from the former UpdatesPane)

    private var updateForm: some View {
        Form {
            Section {
                LabeledContent("Version", value: UpdateMapping.versionLabel(
                    shortVersion: Self.shortVersion,
                    buildVersion: Self.buildVersion
                ))
                LabeledContent("Last check", value: UpdateMapping.lastCheckLabel(date: updater?.lastUpdateCheckDate))
                Button("Check for Updates Now…") {
                    updater?.checkForUpdates()
                }
                .disabled(!(updater?.canCheckForUpdates ?? false))
            }

            Section {
                Toggle("Automatically check for updates", isOn: Binding($autoCheck))
                    .onChange(of: autoCheck) { _, enabled in
                        updater?.setAutomaticallyChecks(enabled)
                    }
                Picker("Check interval:", selection: Binding($interval)) {
                    Text("Daily").tag(UpdateMapping.dailyInterval)
                    Text("Weekly").tag(UpdateMapping.weeklyInterval)
                    Text("Monthly").tag(UpdateMapping.monthlyInterval)
                }
                .disabled(!autoCheck)
                .onChange(of: interval) { _, seconds in
                    updater?.setCheckInterval(seconds: seconds)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Bundle metadata

    private static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "ClipySi"
    }

    private static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    private static var buildVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    private static var copyright: String? {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
    }

    /// The app's own bundle icon (the asset-catalog AppIcon at runtime) — no separate logo asset.
    private static var appIcon: NSImage {
        NSApp.applicationIconImage ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()
    }

    private static let repositoryURL = URL(string: "https://github.com/ClipySi/clipy-si-macos")!
}

/// About-window layout constants (kept beside `SettingsLayout`'s rationale: a fixed content size so
/// the AppKit host window doesn't auto-resize and trip Auto Layout — see AppDelegate.openAbout).
enum AboutLayout {
    static let width: CGFloat = 420
    static let windowContentSize = CGSize(width: width, height: 480)
}

#Preview {
    AboutView()
}
