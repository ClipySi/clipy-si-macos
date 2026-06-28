//
//  AppSettings.swift
//  ClipySi — Apple Silicon rewrite
//
//  Typed, original-compatible read layer over the capture/menu/paste settings. The capture
//  pipeline and menu builder read through this instead of touching raw key strings.
//
//  Implementation note: this currently reads `UserDefaults` directly. The plan's eventual
//  mechanism is `@Shared(.appStorage)` (swift-sharing), whose value is two-way binding +
//  observation for the Settings UI — that lands when the UI exists and the `Sharing`
//  product is wired into the targets. The property surface below is intentionally identical to
//  what the `@Shared` version will expose, so the swap is a localized change. For now a plain
//  read layer is sufficient (capture only needs to *read* values).
//

import Foundation

struct AppSettings {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Capture / dedupe

    var maxHistorySize: Int { defaults.integer(forKey: DefaultsKeys.maxHistorySize) }
    var copySameHistory: Bool { defaults.bool(forKey: DefaultsKeys.copySameHistory) }
    var overwriteSameHistory: Bool { defaults.bool(forKey: DefaultsKeys.overwriteSameHistory) }

    /// Which pasteboard type tokens (see `DefaultsKeys.storeTypeTokens`) capture should persist.
    /// Tokens absent from the stored dictionary default to enabled, matching the all-true seed.
    func shouldStore(typeToken token: String) -> Bool {
        guard let map = defaults.dictionary(forKey: DefaultsKeys.storeTypes) else { return true }
        guard let value = map[token] else { return true }
        return (value as? Bool) ?? ((value as? NSNumber)?.boolValue ?? true)
    }

    // MARK: - Paste

    var inputPasteCommand: Bool { defaults.bool(forKey: DefaultsKeys.inputPasteCommand) }
    var reorderClipsAfterPasting: Bool { defaults.bool(forKey: DefaultsKeys.reorderClipsAfterPasting) }

    // MARK: - Menu

    var showStatusItem: Int { defaults.integer(forKey: DefaultsKeys.showStatusItem) }
    var maxMenuItemTitleLength: Int { defaults.integer(forKey: DefaultsKeys.maxMenuItemTitleLength) }
    var menuItemsTitleStartWithZero: Bool { defaults.bool(forKey: DefaultsKeys.menuItemsTitleStartWithZero) }
    var menuItemsAreMarkedWithNumbers: Bool { defaults.bool(forKey: DefaultsKeys.menuItemsAreMarkedWithNumbers) }
    var showToolTipOnMenuItem: Bool { defaults.bool(forKey: DefaultsKeys.showToolTipOnMenuItem) }
    var maxLengthOfToolTip: Int { defaults.integer(forKey: DefaultsKeys.maxLengthOfToolTip) }
    var showImageInTheMenu: Bool { defaults.bool(forKey: DefaultsKeys.showImageInTheMenu) }
    var showColorPreviewInTheMenu: Bool { defaults.bool(forKey: DefaultsKeys.showColorPreviewInTheMenu) }
    var showIconInTheMenu: Bool { defaults.bool(forKey: DefaultsKeys.showIconInTheMenu) }
    var menuIconSize: Int { defaults.integer(forKey: DefaultsKeys.menuIconSize) }
    var addClearHistoryMenuItem: Bool { defaults.bool(forKey: DefaultsKeys.addClearHistoryMenuItem) }
    var showAlertBeforeClearHistory: Bool { defaults.bool(forKey: DefaultsKeys.showAlertBeforeClearHistory) }
    /// Rows per page in the history FloatingPanel, clamped 5...20 on read.
    var historyPanelItemsPerPage: Int {
        SettingsMapping.clampHistoryPanelItemsPerPage(defaults.integer(forKey: DefaultsKeys.historyPanelItemsPerPage))
    }

    // MARK: - Beta

    /// Paste the plain-text representation only, when the modifier matches (`…Modifier` is a raw
    /// `NSEvent.ModifierFlags.rawValue` read at selection time by `PasteService`).
    var pastePlainText: Bool { defaults.bool(forKey: DefaultsKeys.pastePlainText) }
    var pastePlainTextModifier: Int { defaults.integer(forKey: DefaultsKeys.pastePlainTextModifier) }
    var deleteHistory: Bool { defaults.bool(forKey: DefaultsKeys.deleteHistory) }
    var deleteHistoryModifier: Int { defaults.integer(forKey: DefaultsKeys.deleteHistoryModifier) }
    var pasteAndDeleteHistory: Bool { defaults.bool(forKey: DefaultsKeys.pasteAndDeleteHistory) }
    var pasteAndDeleteHistoryModifier: Int { defaults.integer(forKey: DefaultsKeys.pasteAndDeleteHistoryModifier) }

    var observeScreenshot: Bool { defaults.bool(forKey: DefaultsKeys.observeScreenshot) }

    // MARK: - Privacy / masking

    /// Mask detected secrets in the menu and history table. Default ON.
    var maskSecretsInMenu: Bool { defaults.bool(forKey: DefaultsKeys.maskSecretsInMenu) }
    /// Raw mask-style token ("full" / "prefix2" / "suffix4"); mapped to the core enum by
    /// `MaskingService`. Defaults to "full" when unset.
    var maskStyleRaw: String { defaults.string(forKey: DefaultsKeys.maskStyle) ?? "full" }
    /// Require local authentication before revealing/pasting a detected secret.
    var requireAuthForSecretReveal: Bool { defaults.bool(forKey: DefaultsKeys.requireAuthForSecretReveal) }

    // MARK: - Diagnostics

    /// Local diagnostics collection level. Unknown/absent → `.none` (collect nothing).
    var diagnosticsLevel: DiagnosticLevel { DiagnosticLevel(raw: defaults.string(forKey: DefaultsKeys.diagnosticsLevel)) }

    // MARK: - Appearance

    /// The unified panel's accent, resolved from its raw string. Unknown/absent → `.default` (violet).
    var panelAccent: PanelAccent { PanelAccent.resolve(defaults.string(forKey: DefaultsKeys.panelAccent)) }

    // MARK: - Sync

    /// Master switch for local-folder sync (default OFF; the user opts in via the Sync pane).
    var syncEnabled: Bool { defaults.bool(forKey: DefaultsKeys.syncEnabled) }
    /// The user-chosen sync folder, or nil while unconfigured.
    var syncFolderPath: String? { defaults.string(forKey: DefaultsKeys.syncFolderPath) }
    /// Periodic sync interval, clamped 60...3600 seconds on read (default 300).
    var syncIntervalSeconds: Int {
        SettingsMapping.clamp(defaults.integer(forKey: DefaultsKeys.syncIntervalSeconds), to: 60...3_600)
    }
    /// Opt-in: persist the derived vault key (never the passphrase) in the Keychain.
    var saveVaultKeyInKeychain: Bool { defaults.bool(forKey: DefaultsKeys.saveVaultKeyInKeychain) }
}
