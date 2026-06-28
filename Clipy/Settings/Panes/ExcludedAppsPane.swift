//
//  ExcludedAppsPane.swift
//  ClipySi — Apple Silicon rewrite
//
//  The Excluded Applications settings pane: a live list of apps whose copies are never captured.
//  Add → `NSOpenPanel` (.app bundles) → read the bundle's `Info.plist` → `ExcludeAppRepository.add`;
//  Remove → `ExcludeAppRepository.remove`. No UserDefaults bindings — the list is a first-class
//  table (`ExcludedApp`), so the original's non-secure `NSCoding`-archived `[CPYAppInfo]` blob and
//  its security exposure are gone (security-guidance item 2). See the design §2.4 / §1.4.
//
//  Faithful to the original CPYExcludeAppPreferenceViewController: multi-select `.app` open panel
//  defaulting to /Applications, bundle id + display name extracted exactly as `CPYAppInfo(info:)`
//  did (`kCFBundleIdentifierKey`; name = `kCFBundleNameKey` ?? `kCFBundleExecutableKey`). The list
//  adds an app icon + bundle id subtitle the original omitted — the gate matches by bundle id, so
//  showing it disambiguates same-named apps.
//

import AppKit
import OSLog
import SQLiteData
import SwiftUI
import UniformTypeIdentifiers

struct ExcludedAppsPane: View {
    @FetchAll(ExcludedApp.order(by: \.bundleIdentifier)) private var excludedApps

    @State private var selection: String?
    @State private var iconCache: [String: NSImage] = [:]

    private let repo = ExcludeAppRepository()
    private static let log = Logger(subsystem: "io.github.ponponusa.clipysi", category: "settings")

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Copies made while one of these applications is frontmost are never saved to history.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                list
                Divider()
                buttonBar
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        }
        .padding()
        .frame(width: SettingsLayout.paneWidth, height: 320)
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(excludedApps, id: \.bundleIdentifier) { app in
                HStack(spacing: 8) {
                    icon(for: app)
                        .frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name)
                        Text(app.bundleIdentifier)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.bordered(alternatesRowBackgrounds: true))
        .overlay {
            if excludedApps.isEmpty {
                ContentUnavailableView("No Excluded Applications", systemImage: "xmark.app")
            }
        }
        // Resolve icons off the render path: only when the set of bundle ids changes (add/remove),
        // not on every selection-change re-render. Keeps `body` free of Launch Services lookups.
        .onChange(of: excludedApps.map(\.bundleIdentifier), initial: true) { _, ids in
            for id in ids where iconCache[id] == nil {
                iconCache[id] = Self.resolveIcon(bundleIdentifier: id)
            }
        }
    }

    private var buttonBar: some View {
        HStack(spacing: 0) {
            Button(action: addApps) {
                Image(systemName: "plus").frame(width: 24, height: 20)
            }
            .help("Add an application to exclude")
            Button(action: removeSelected) {
                Image(systemName: "minus").frame(width: 24, height: 20)
            }
            .help("Remove the selected application")
            .disabled(selection == nil)
            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(4)
    }

    // MARK: - Actions

    private func addApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.prompt = String(localized: "Add", comment: "Open-panel button to add an excluded application")
        panel.directoryURL = Self.applicationsDirectory
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let info = ExcludedAppInfo(appBundleURL: url) else {
                Self.log.error("could not read bundle info for \(url.path, privacy: .public)")
                continue
            }
            do {
                try repo.add(bundleIdentifier: info.bundleIdentifier, name: info.name)
            } catch {
                Self.log.error("failed to add excluded app: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func removeSelected() {
        guard let bundleIdentifier = selection else { return }
        do {
            try repo.remove(bundleIdentifier: bundleIdentifier)
        } catch {
            Self.log.error("failed to remove excluded app: \(error.localizedDescription, privacy: .public)")
        }
        selection = nil
    }

    // MARK: - Helpers

    /// `/Applications` (first local-domain application directory), falling back to home — matches the
    /// original's `NSSearchPathForDirectoriesInDomains(.applicationDirectory, .localDomainMask, …)`.
    private static var applicationsDirectory: URL {
        let paths = NSSearchPathForDirectoriesInDomains(.applicationDirectory, .localDomainMask, true)
        return URL(fileURLWithPath: paths.first ?? NSHomeDirectory())
    }

    /// The cached row icon, falling back to a generic placeholder until the cache is populated by
    /// `.onChange` (one frame). Reading from the cache keeps the row builder free of I/O.
    @ViewBuilder private func icon(for app: ExcludedApp) -> some View {
        if let image = iconCache[app.bundleIdentifier] {
            Image(nsImage: image).resizable()
        } else {
            Image(systemName: "app.dashed").foregroundStyle(.secondary)
        }
    }

    /// Best-effort app icon: resolve the bundle id to its installed `.app`, else a generic bundle
    /// icon (the excluded app may have been uninstalled — the exclusion still holds by bundle id).
    /// Runs a Launch Services lookup, so it is called off the render path (see `.onChange` above).
    private static func resolveIcon(bundleIdentifier: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }
}

/// The bundle id + display name extracted from an `.app` bundle's `Info.plist`, mirroring the
/// original `CPYAppInfo(info:)` exactly so the same apps yield the same records: bundle id from
/// `kCFBundleIdentifierKey`, name from `kCFBundleNameKey` falling back to `kCFBundleExecutableKey`.
/// Either missing yields `nil` (the app isn't excludable). Pure/value type for unit testing.
struct ExcludedAppInfo: Equatable {
    let bundleIdentifier: String
    let name: String

    init?(infoDictionary: [String: Any]) {
        guard let identifier = infoDictionary[kCFBundleIdentifierKey as String] as? String else { return nil }
        guard let name = infoDictionary[kCFBundleNameKey as String] as? String
            ?? infoDictionary[kCFBundleExecutableKey as String] as? String else { return nil }
        self.bundleIdentifier = identifier
        self.name = name
    }

    init?(appBundleURL url: URL) {
        guard let bundle = Bundle(url: url), let info = bundle.infoDictionary else { return nil }
        self.init(infoDictionary: info)
    }
}
