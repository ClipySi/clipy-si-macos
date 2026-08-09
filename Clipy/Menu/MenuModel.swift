//
//  MenuModel.swift
//  ClipySi — Apple Silicon rewrite
//
//  Source of the history data the FloatingPanel renders. Reads clips **imperatively** at build time
//  (no held `@FetchAll` — the panel takes a snapshot on each open, so a live subscription would be
//  redundant work; see the design §4.1) and decrypts the visible titles via `\.historyCipher`. The
//  repository stays storage-only / crypto-free — decryption lives here (security-guidance.md §5 / R3).
//  The consumer is `ClipSelectionCoordinator` (the panel), not the NSMenu.
//

import Foundation
import OSLog
import SQLiteData // re-exports swift-dependencies (@Dependency)

/// Display-ready data for one history clip.
///
/// `title` is the **decrypted** preview (full and untrimmed); the panel renders the masked
/// `displayTitle` and truncates with `lineLimit`. When decryption fails — e.g. a clip captured while
/// the ephemeral-key fallback was active (`HistoryCipher.live`; see design §12.E) — `decryptFailed`
/// is `true` and `title` is empty, so the controller can show a placeholder and refuse to paste it.
struct ClipDisplay: Identifiable, Sendable, Equatable {
    let id: UUID
    /// The **raw** decrypted preview (full, untrimmed). NEVER render this directly — it may
    /// contain a secret; use `displayTitle`. Retained as the source for masking and for the
    /// authenticated reveal path.
    let title: String
    /// The render string: bullets/partial when masking is enabled and a secret is present,
    /// otherwise equal to `title`. All display surfaces (menu body, tooltip, history
    /// table) use this.
    let displayTitle: String
    /// A secret was detected in `title` (independent of whether masking display is enabled).
    let isSecret: Bool
    let primaryType: String
    let isColorCode: Bool
    let decryptFailed: Bool
    /// When the clip was captured — drives the preview pane's relative timestamp. Defaults
    /// to the epoch for synthetic/test displays that don't care about time.
    let createdAt: Date
    /// Bundle id of the app the copy came from, when it self-declared `org.nspasteboard.source` (often
    /// nil). Drives the preview pane's source-app label; nil → no app shown.
    let sourceBundle: String?
    /// The record's last-modified stamp — part of derived-value cache keys (M-UI.11 P1): any
    /// mutation path that could change a row (sync merge included) bumps it, so cached
    /// classification for the old row can never be served for the new one.
    let updatedAt: Date

    init(id: UUID, title: String, primaryType: String, isColorCode: Bool, decryptFailed: Bool,
         displayTitle: String? = nil, isSecret: Bool = false,
         createdAt: Date = Date(timeIntervalSince1970: 0), sourceBundle: String? = nil,
         updatedAt: Date = Date(timeIntervalSince1970: 0)) {
        self.id = id
        self.title = title
        self.displayTitle = displayTitle ?? title
        self.isSecret = isSecret
        self.primaryType = primaryType
        self.isColorCode = isColorCode
        self.decryptFailed = decryptFailed
        self.createdAt = createdAt
        self.sourceBundle = sourceBundle
        self.updatedAt = updatedAt
    }
}

struct ClipDisplayBuilder {
    @Dependency(\.historyCipher) private var cipher
    @Dependency(\.maskingService) private var masking

    /// Single-clip convenience — resolves the mask policy per call. Request-shaped reads (the
    /// panel open, the manager window) should use `displays(of:policy:)` instead (M-UI.11 P1).
    func display(of clip: Clip) -> ClipDisplay {
        display(of: clip, evaluate: masking.evaluate)
    }

    /// Builds the whole request's displays under ONE resolved mask policy — one settings read per
    /// open, and every row consistent with it even if the user flips a Privacy toggle mid-read.
    func displays(of clips: [Clip], policy: DisplayPolicy) -> [ClipDisplay] {
        let evaluate = masking.makeEvaluator(policy)
        return clips.map { display(of: $0, evaluate: evaluate) }
    }

    private func display(of clip: Clip, evaluate: (String) -> MaskingResult) -> ClipDisplay {
        guard let data = try? cipher.open(clip.titleCipher),
              let title = String(bytes: data, encoding: .utf8) else {
            return ClipDisplay(id: clip.id, title: "", primaryType: clip.primaryType,
                               isColorCode: clip.isColorCode, decryptFailed: true,
                               createdAt: clip.createdAt, sourceBundle: clip.sourceBundle,
                               updatedAt: clip.updatedAt)
        }
        // Run the shared redaction core over the decrypted title. `displayTitle` is what every
        // surface renders; `title` stays raw for the (auth-gated) reveal path.
        let result = evaluate(title)
        return ClipDisplay(id: clip.id, title: title, primaryType: clip.primaryType,
                           isColorCode: clip.isColorCode, decryptFailed: false,
                           displayTitle: result.display, isSecret: result.isSecret,
                           createdAt: clip.createdAt, sourceBundle: clip.sourceBundle,
                           updatedAt: clip.updatedAt)
    }
}

struct MenuModel {
    private let clips = ClipRepository()
    private let displayBuilder = ClipDisplayBuilder()
    let settings: AppSettings

    private static let log = Logger(subsystem: "io.github.ponponusa.clipysi", category: "menu")

    init(settings: AppSettings = AppSettings()) {
        self.settings = settings
    }

    /// The history clips to display — newest- or oldest-first per `historySortNewestFirst`, capped
    /// at `maxHistorySize`, each with its title decrypted under the request's ONE resolved mask
    /// `policy` (M-UI.11 P1). A DB failure degrades to an empty result rather than throwing into
    /// the build path. (The full unlimited count, once needed for the NSMenu "lo - hi" folder
    /// labels, is gone with that layout; the panel pages instead.)
    func history(policy: DisplayPolicy) -> [ClipDisplay] {
        let ascending = !settings.historySortNewestFirst
        do {
            let clipRows = try PanelSignpost.measureCounted(.historyFetch) {
                try clips.recentClips(limit: settings.maxHistorySize, ascending: ascending)
            }
            return PanelSignpost.measure(.historyDecryptMask, rows: clipRows.count) {
                displayBuilder.displays(of: clipRows, policy: policy)
            }
        } catch {
            Self.log.error("history read failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func history() -> [ClipDisplay] {
        history(policy: .current(settings: settings))
    }
}
