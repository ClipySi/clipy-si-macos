//
//  WelcomeView.swift
//  ClipySi — Apple Silicon rewrite
//
//  The first-run Welcome flow. A single window with three light steps:
//    1. Welcome     — what ClipySi is + its privacy stance, with Privacy Policy / License links.
//    2. Accessibility — why ⌘V paste needs the AX permission, with a Grant button (skippable).
//    3. Diagnostics — the optional, default-OFF diagnostics choice (absorbs the old standalone
//                     consent popup, which felt context-less on its own).
//
//  Shown once, gated by `clipyDidOnboard` (the hotKeysSeeded pattern). Defaults are all safe
//  (diagnostics OFF, AX optional), so dismissing at any step is fine. Hosted by AppDelegate as an
//  AppKit window we own (the About/Settings path) — an accessory app has no reliable responder
//  target for a SwiftUI scene.
//

import AppKit
import Sharing
import SwiftUI

struct WelcomeView: View {
    /// Called when the user finishes (or closes) onboarding; AppDelegate closes the window.
    let onFinish: () -> Void

    private enum Step: Int, CaseIterable { case welcome, accessibility, diagnostics }

    @State private var step: Step = .welcome
    @State private var axTrusted = false
    @Shared(.appStorage(DefaultsKeys.diagnosticsLevel)) private var levelRaw = "none"

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(24)
            Divider()
            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
        .frame(width: WelcomeLayout.size.width, height: WelcomeLayout.size.height)
        .onAppear { axTrusted = AccessibilityService().isTrusted(prompt: false) }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcomeStep
        case .accessibility: accessibilityStep
        case .diagnostics: diagnosticsStep
        }
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: Self.appIcon)
                    .resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to ClipySi").font(.title.weight(.semibold))
                    Text("A privacy-first clipboard manager.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                bullet("lock.fill", "Your clipboard history is encrypted and stored only on your Mac.")
                bullet("eye.slash.fill", "Passwords and tokens are detected and masked automatically.")
                bullet("hand.raised.fill", "No accounts, no ads, no tracking.")
            }
            .padding(.top, 4)
            HStack(spacing: 14) {
                Link("Privacy Policy", destination: DiagnosticsInfo.privacyPolicyURL)
                Link("License", destination: WelcomeLayout.licenseURL)
            }
            .font(.caption)
        }
    }

    private func bullet(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.tint).frame(width: 18)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }

    // MARK: - Step 2: Accessibility

    private var accessibilityStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader("keyboard", "Enable pasting")
            Text("ClipySi pastes into the frontmost app using macOS Accessibility. Grant permission so ⌘V works — you can also do this later.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label(axTrusted ? "Accessibility is enabled." : "Accessibility is not enabled yet.",
                  systemImage: axTrusted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(axTrusted ? .green : .orange)
                .font(.callout)
            HStack(spacing: 10) {
                Button("Grant Accessibility…") {
                    axTrusted = AccessibilityService().isTrusted(prompt: true)
                }
                .disabled(axTrusted)
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    // MARK: - Step 3: Diagnostics (absorbs the old consent popup)

    private var diagnosticsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepHeader("stethoscope", "Help improve ClipySi")
            Text("ClipySi can collect anonymous diagnostics on your Mac to help fix crashes and bugs. Your clipboard contents, history, snippets, and searches are never collected, and nothing is ever sent anywhere automatically.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Diagnostics", selection: Binding($levelRaw)) {
                Text("Off — collect nothing (recommended)").tag("none")
                Text("Minimal — crashes only").tag("minimal")
                Text("Standard — crashes and coarse errors").tag("standard")
                Text("Detailed — also recent feature breadcrumbs").tag("detailed")
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .onChange(of: levelRaw) { _, _ in
                NotificationCenter.default.post(name: .clipySiDiagnosticsLevelChanged, object: nil)
            }
            Link("Privacy Policy", destination: DiagnosticsInfo.privacyPolicyURL)
                .font(.caption)
        }
    }

    private func stepHeader(_ symbol: String, _ title: LocalizedStringKey) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.title).foregroundStyle(.tint)
            Text(title).font(.title2.weight(.semibold))
        }
    }

    // MARK: - Footer (page dots + navigation)

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { dot in
                    Circle()
                        .fill(dot == step ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                        .frame(width: 7, height: 7)
                }
            }
            Spacer()
            if step != .welcome {
                Button("Back") { advance(by: -1) }
            }
            if step == .diagnostics {
                Button("Get Started", action: onFinish).keyboardShortcut(.defaultAction)
            } else {
                Button("Continue") { advance(by: 1) }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func advance(by delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        // Refresh AX status when arriving on that step (the user may have just granted it).
        if next == .accessibility { axTrusted = AccessibilityService().isTrusted(prompt: false) }
        step = next
    }

    /// Read AppIcon.icns straight from the bundle — independent of the LaunchServices/named-image
    /// caches that can yield a generic placeholder for a freshly built (unregistered) app.
    private static var appIcon: NSImage {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSApp.applicationIconImage ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()
    }
}

enum WelcomeLayout {
    // Tall enough for the diagnostics step (heading + body + 4 radio rows + link) with margin for
    // verbose locales; the shorter steps top-align within it.
    static let size = CGSize(width: 520, height: 384)
    static let licenseURL = URL(string: "https://github.com/ClipySi/clipy-si-macos/blob/main/LICENSE")!
}

#Preview {
    WelcomeView(onFinish: {})
}
