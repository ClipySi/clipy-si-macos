//
//  DefaultsKeys.swift
//  ClipySi — Apple Silicon rewrite
//
//  Original-Clipy-compatible `UserDefaults` keys (verbatim, INCLUDING the original's
//  misspellings) and their registered default values, mirroring the original's
//  CPYUtilities.registerUserDefaultKeys. Keeping the raw key strings and defaults identical
//  lets an existing user's preferences carry over (see DESIGN.md §6).
//
//  Do NOT "fix" these strings — e.g. "Histroy" and the lowercase "paste" are intentional. Any
//  setting the rewrite newly introduces should use a fresh, correctly-spelled key instead.
//
//  Non-scalar settings are owned by their own subsystems, not by this scalar layer:
//   - storeTypes ("kCPYPrefStoreTypesKey") is a [String: Bool] dictionary read by capture;
//     its default is seeded here so capture sees all-types-enabled out of the box.
//   - the excluded-apps blob ("kCPYExcludeApplications") → ExcludeAppRepository + migration.
//   - hotkeys ("kCPYPrefHotKeysKey" / "kCPYHotKey*") → Magnet/HotKeyService.
//

import Foundation

enum DefaultsKeys {
    // General / capture
    static let maxHistorySize = "kCPYPrefMaxHistorySizeKey"
    static let storeTypes = "kCPYPrefStoreTypesKey"
    static let inputPasteCommand = "kCPYPrefInputPasteCommandKey"
    static let reorderClipsAfterPasting = "kCPYPrefReorderClipsAfterPasting"
    static let overwriteSameHistory = "kCPYPrefOverwriteSameHistroy"   // sic: "Histroy"
    static let copySameHistory = "kCPYPrefCopySameHistroy"             // sic: "Histroy"

    // Menu
    static let showStatusItem = "kCPYPrefShowStatusItemKey"            // Int: 0/1/2
    static let menuIconSize = "kCPYPrefMenuIconSizeKey"
    static let maxMenuItemTitleLength = "kCPYPrefMaxMenuItemTitleLengthKey"
    static let menuItemsTitleStartWithZero = "kCPYPrefMenuItemsTitleStartWithZeroKey"
    static let menuItemsAreMarkedWithNumbers = "menuItemsAreMarkedWithNumbers"
    // Retired with the NSMenu inline/folder history layout: no longer read by any code, but
    // the keys + their registered defaults are kept so a migrated/older profile isn't silently mutated.
    static let numberOfItemsPlaceInline = "kCPYPrefNumberOfItemsPlaceInlineKey"
    static let numberOfItemsPlaceInsideFolder = "kCPYPrefNumberOfItemsPlaceInsideFolderKey"
    static let addNumericKeyEquivalents = "addNumericKeyEquivalents"
    static let showToolTipOnMenuItem = "showToolTipOnMenuItem"
    static let maxLengthOfToolTip = "maxLengthOfToolTipKey"
    static let showImageInTheMenu = "showImageInTheMenu"
    static let showColorPreviewInTheMenu = "kCPYPrefShowColorPreviewInTheMenu"
    static let showIconInTheMenu = "kCPYPrefShowIconInTheMenuKey"
    static let addClearHistoryMenuItem = "kCPYPrefAddClearHistoryMenuItemKey"
    static let showAlertBeforeClearHistory = "kCPYPrefShowAlertBeforeClearHistoryKey"
    /// Rows shown per page in the history FloatingPanel (rewrite-only; clamped 5...20, default 10).
    /// No original equivalent — the panel paging is new.
    static let historyPanelItemsPerPage = "clipyHistoryPanelItemsPerPage"

    // Thumbnails
    static let thumbnailWidth = "thumbnailWidth"
    static let thumbnailHeight = "thumbnailHeight"

    // Login
    static let loginItem = "loginItem"
    static let suppressAlertForLoginItem = "suppressAlertForLoginItem"

    // Updates
    static let enableAutomaticCheck = "kCPYEnableAutomaticCheckKey"
    static let updateCheckInterval = "kCPYUpdateCheckIntervalKey"

    // Hotkeys (JSON-encoded KeyComboValue under the original per-combo keys; no registered default —
    // the code-level defaults are seeded once on first run, then absence = unbound). Legacy
    // archived-combo migration. `clearHistory` ships unbound (original default is nil).
    static let mainKeyCombo = "kCPYHotKeyMainKeyCombo"
    static let historyKeyCombo = "kCPYHotKeyHistoryKeyCombo"
    static let snippetKeyCombo = "kCPYHotKeySnippetKeyCombo"
    static let clearHistoryKeyCombo = "kCPYClearHistoryKeyCombo"
    /// Rewrite-internal one-shot flag: have the code-level default combos been seeded yet? Not an
    /// original key (correctly spelled) — gates seeding so a cleared hotkey isn't silently
    /// re-defaulted next launch (design §6 delta 13).
    static let hotKeysSeeded = "clipyHotKeysSeeded"

    /// Rewrite-internal: the last folder the History Manager's "Snippetize" added to, so the next
    /// snippetize pre-selects it. Stores a folder UUID string; absent / stale → default to the first
    /// folder. Not an original key (correctly spelled).
    static let snippetizeLastFolder = "clipySnippetizeLastFolderID"

    /// Rewrite-internal: this device's stable id (an opaque UUID string), minted lazily on first
    /// capture and stamped onto clips as `originDeviceID` for sync attribution. No registered
    /// default — absence means "not yet minted". Not secret. See DeviceIdentity.
    static let deviceID = "clipyDeviceID"

    /// Rewrite-internal one-shot flag: has the `isSensitive` backfill of pre-secret-detection rows run yet? Gates
    /// a single background pass (like `hotKeysSeeded`). No registered default. See IsSensitiveBackfill.
    static let isSensitiveBackfillDone = "clipyIsSensitiveBackfillDone"

    // Sync (rewrite-only, correctly-spelled keys; no original equivalent)
    /// Master switch for local-folder sync. Default OFF (the user opts in via the Sync pane).
    static let syncEnabled = "clipySyncEnabled"
    /// Absolute path of the user-chosen sync folder (the `ClipySiVault/` layout is created inside).
    /// No registered default — absence means "not configured".
    static let syncFolderPath = "clipySyncFolderPath"
    /// Periodic sync interval in seconds (clamped 60...3600 on read; default 300).
    static let syncIntervalSeconds = "clipySyncIntervalSeconds"
    /// Opt-in: keep the DERIVED vault key (never the passphrase) in the Keychain
    /// (`…ThisDeviceOnly`) so sync resumes without re-entering the passphrase each launch.
    static let saveVaultKeyInKeychain = "clipySaveVaultKeyInKeychain"
    /// The vault_id of the vault this device last synced with. A mismatch (new folder / recreated
    /// vault) wipes the local sync state so the old vault's applied set can't contaminate the new
    /// one. No registered default.
    static let syncVaultID = "clipySyncVaultID"

    // Privacy / masking (rewrite-only, correctly-spelled keys; no original equivalent)
    /// Mask detected secrets in the menu / history table. Default ON (security requirement).
    static let maskSecretsInMenu = "clipyMaskSecretsInMenu"
    /// How a masked value is rendered: "full" (default), "prefix2", or "suffix4".
    static let maskStyle = "clipyMaskStyle"
    /// Require local authentication before revealing/pasting a detected secret.
    static let requireAuthForSecretReveal = "clipyRequireAuthForSecretReveal"

    // Diagnostics (rewrite-only, correctly-spelled keys; no original equivalent)
    /// Local diagnostics collection level: "none" (default), "minimal", "standard", "detailed".
    /// Nothing is ever sent automatically — this gates *local* collection granularity. See
    /// DiagnosticTypes.swift.
    static let diagnosticsLevel = "clipyDiagnosticsLevel"
    /// One-shot flag: has the first-run Welcome/onboarding flow been shown yet? Gates a single
    /// presentation (like `hotKeysSeeded`), so dismissing it doesn't re-show next launch. Also gates
    /// the launch-time Accessibility prompt (onboarding owns it on first run; see AppDelegate).
    static let didOnboard = "clipyDidOnboard"
    /// Anonymous, on-device-generated installation ID. No registered default — minted lazily the
    /// first time a diagnostic snapshot is taken at `.minimal`+, never at `.none`.
    static let diagnosticsInstallationID = "clipyDiagnosticsInstallationID"

    // Appearance (rewrite-only, correctly-spelled key; no original equivalent)
    /// The unified panel's accent colour — one of `PanelAccent`'s raw values ("violet" default). Picked in
    /// Settings → General → Appearance; an unknown / legacy value falls back to the default.
    static let panelAccent = "clipyPanelAccentColor"
    /// Whether the unified panel's preview pane is expanded. A persisted preference —
    /// NOT reset per open — because the preview size is a steady user taste, not per-session state.
    static let panelPreviewExpanded = "clipyPanelPreviewExpanded"
    /// Which side of the panel the preview pane opens on — one of `PanelPreviewSide`'s raw values
    /// ("right" default / "left"). Picked in Settings → General → Appearance; an unknown value
    /// falls back to right.
    static let panelPreviewSide = "clipyPanelPreviewSide"
    /// Whether the preview pane may flip to the opposite side when the chosen side has no drawing
    /// room at the screen edge (default ON). Off ⇒ the whole panel shifts inward instead (the
    /// origin clamp), keeping the chosen side.
    static let panelPreviewEdgeFlip = "clipyPanelPreviewEdgeFlip"

    // Beta
    static let pastePlainText = "kCPYBetaPastePlainText"
    static let pastePlainTextModifier = "kCPYBetaPastePlainTextModifier"
    static let deleteHistory = "kCPYBetaDeleteHistory"
    static let deleteHistoryModifier = "kCPYBetaDeleteHistoryModifier"
    static let pasteAndDeleteHistory = "kCPYBetaPasteAndDeleteHistory"
    static let pasteAndDeleteHistoryModifier = "kCPYBetapasteAndDeleteHistoryModifier"  // sic: lowercase "paste"
    static let observeScreenshot = "kCPYBetaObserveScreenshot"
}

extension DefaultsKeys {
    /// Tokens for the `storeTypes` dictionary (CPYClipData.availableTypesString in the original).
    static let storeTypeTokens = ["String", "RTF", "RTFD", "PDF", "Filenames", "URL", "TIFF"]

    /// The registration-domain defaults, matching the original's registerUserDefaultKeys.
    /// Registered defaults are fallbacks only (they don't persist to disk and never override a
    /// user-set value), so this is safe to call on every launch.
    static var registeredDefaults: [String: Any] {
        [
            maxHistorySize: 30,
            inputPasteCommand: true,
            reorderClipsAfterPasting: true,
            overwriteSameHistory: true,
            copySameHistory: true,
            showStatusItem: 1,
            menuIconSize: 16,
            numberOfItemsPlaceInline: 0,
            numberOfItemsPlaceInsideFolder: 10,
            maxMenuItemTitleLength: 20,
            menuItemsTitleStartWithZero: false,
            menuItemsAreMarkedWithNumbers: true,
            addNumericKeyEquivalents: false,
            showToolTipOnMenuItem: true,
            maxLengthOfToolTip: 200,
            showImageInTheMenu: true,
            showColorPreviewInTheMenu: true,
            showIconInTheMenu: true,
            addClearHistoryMenuItem: true,
            showAlertBeforeClearHistory: true,
            historyPanelItemsPerPage: 10,
            thumbnailWidth: 100,
            thumbnailHeight: 32,
            loginItem: false,
            suppressAlertForLoginItem: false,
            // ON by default since the first public release (v1.0.0) ships a real appcast on GitHub
            // Releases (SUFeedURL/SUPublicEDKey are real in Info.plist). Keep in sync with
            // AboutView's @Shared default.
            enableAutomaticCheck: true,
            updateCheckInterval: 86_400,
            pastePlainText: true,
            pastePlainTextModifier: 0,
            deleteHistory: false,
            deleteHistoryModifier: 0,
            pasteAndDeleteHistory: false,
            pasteAndDeleteHistoryModifier: 0,
            observeScreenshot: false,
            // Masking ON by default with full masking (security-guidance.md: a clipboard
            // manager captures passwords/tokens, so hide them out of the box).
            maskSecretsInMenu: true,
            maskStyle: "full",
            requireAuthForSecretReveal: false,
            // Diagnostics OFF by default (collect nothing): the user opts in via the first-run
            // Welcome flow / Diagnostics pane. didOnboard=false so onboarding is shown once.
            diagnosticsLevel: "none",
            didOnboard: false,
            // Panel accent — must equal `PanelAccent.default.rawValue` ("violet"). Hardcoded here to keep
            // this scalar layer free of the SwiftUI/PanelAccent dependency.
            panelAccent: "violet",
            // Preview pane on the right by default ("right" must equal PanelPreviewSide.right.rawValue —
            // hardcoded for the same layer-purity reason as the accent), edge-flip enabled.
            panelPreviewSide: "right",
            panelPreviewEdgeFlip: true,
            // Sync OFF by default; the user opts in via the Sync pane.
            syncEnabled: false,
            syncIntervalSeconds: 300,
            saveVaultKeyInKeychain: false,
            storeTypes: Dictionary(uniqueKeysWithValues: storeTypeTokens.map { ($0, true) })
        ]
    }

    /// Seeds the registration-domain defaults. Call once at launch before any setting is read.
    static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: registeredDefaults)
    }
}
