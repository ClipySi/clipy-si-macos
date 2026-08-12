//
//  PanelRowBuilder.swift
//  ClipySi — Apple Silicon rewrite
//
//  Non-isolated `ClipDisplay` → `PanelRow` conversion, shared by the MainActor
//  `ClipSelectionCoordinator` (sync build path, tests) and the off-main `HistoryReadService`
//  (M-UI.11 P2). Moved out of the coordinator because statics on a `@MainActor` class inherit
//  its isolation — the read service couldn't call them from its own executor. Pure functions
//  over Sendable values; `NSPasteboard.PasteboardType` is only compared as raw strings.
//

import AppKit

enum PanelRowBuilder {
    /// The display row for one history clip: masked body, coarse content kind, and the lazy
    /// classification flag. Only plain-text candidates can be upgraded to `.code` — a masked
    /// secret is all bullets (no code structure), so flagging it is harmless (cached verdict:
    /// not code); a decrypt-failed placeholder is skipped outright (M-UI.11 P1).
    static func historyRow(for display: ClipDisplay) -> PanelRow {
        let body = displayBody(for: display)
        let kind = contentKind(for: display)
        var row = PanelRow.clip(display.id,
                                title: body,
                                isSecret: display.isSecret,
                                decryptFailed: display.decryptFailed,
                                contentKind: kind,
                                createdAt: display.createdAt,
                                sourceBundle: display.sourceBundle)
        row.updatedAt = display.updatedAt
        row.needsCodeClassification = kind == .text && !display.decryptFailed
        return row
    }

    /// The coarse content type behind a clip row's leading glyph. Reliable signals only: the
    /// primary UTType for image/PDF/file, the color flag, and an `http(s)://` prefix on the
    /// *masked* display title for a URL — a masked secret stays `.text` (its bullets never
    /// match). No command/terminal guessing. Display-only; mirrors `displayBody`'s type switch.
    static func contentKind(for display: ClipDisplay) -> PanelRow.ContentKind {
        if display.decryptFailed { return .text }
        switch display.primaryType {
        case NSPasteboard.PasteboardType.tiff.rawValue: return .image
        case NSPasteboard.PasteboardType.pdf.rawValue: return .pdf
        case NSPasteboard.PasteboardType.fileURL.rawValue: return .file
        default:
            if display.isColorCode { return .color }
            if looksLikeURL(display.displayTitle) { return .url }
            return .text
        }
    }

    /// A conservative URL test for the content-kind glyph: a leading `http://`/`https://` after
    /// trimming. Intentionally narrow — it only upgrades the glyph, so a miss just shows the
    /// text glyph (no harm).
    static func looksLikeURL(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
    }

    /// The user-visible body of a clip row: the masked `displayTitle` for text, the original's
    /// bracketed placeholders for non-text primaries, and a fixed marker when decryption failed.
    /// The raw `display.title` is never returned (the §9 leakage guarantee).
    static func displayBody(for display: ClipDisplay) -> String {
        if display.decryptFailed {
            return String(localized: "(decryption failed)", comment: "Menu title when a clipboard item can't be decrypted")
        }
        switch display.primaryType {
        case NSPasteboard.PasteboardType.tiff.rawValue:
            return String(localized: "(Image)", comment: "Placeholder menu title for an image clip")
        case NSPasteboard.PasteboardType.pdf.rawValue:
            return String(localized: "(PDF)", comment: "Placeholder menu title for a PDF clip")
        case NSPasteboard.PasteboardType.fileURL.rawValue:
            return String(localized: "(Filenames)", comment: "Placeholder menu title for a file clip")
        default:
            return display.displayTitle
        }
    }
}
