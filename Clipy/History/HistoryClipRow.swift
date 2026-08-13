//
//  HistoryClipRow.swift
//  ClipySi — Apple Silicon rewrite
//
//  Display-ready, immutable row for the History Manager table. Built once per visible page
//  from a `Clip` + its decrypted `ClipDisplay` (see `ClipDisplayBuilder`), so the table never
//  re-decrypts on selection/hover/resize. Carries the per-row capability flags the header buttons
//  read — `canCopy` (decryptable) and `canSnippetize` (decryptable plain text).
//

import AppKit
import Foundation

struct HistoryClipRow: Identifiable, Sendable, Equatable {
    /// Display cap for `preview` (M-UI.11 P5): the table renders one line and the snippetize
    /// sheet a short excerpt, but a 10,000-char clip must not keep its whole masked title
    /// resident per row — the scan can accumulate every match. Search NEVER runs on this
    /// truncated string: the scan matches on the full `searchableTitle` first (an implicit
    /// truncated-search contract is a §12 exclusion).
    static let previewDisplayCap = 300

    let id: Clip.ID
    let preview: String
    let createdAt: Date
    let sourceBundleDisplay: String
    let typeDisplay: String
    let pinnedDisplay: String
    let decryptFailed: Bool
    let canSnippetize: Bool
    /// Raw metadata mirrors of the SQL sort keys (M-UI.11 P5): the scan's sorted merge must
    /// order by exactly what `ClipRepository.managerFetch` orders by — the raw `primaryType`,
    /// not the localized label; the pin flag, not its display string.
    let primaryType: String
    let isPinned: Bool

    /// Copy is suppressed for rows whose payload can't be decrypted (ephemeral-key fallback).
    var canCopy: Bool { !decryptFailed }

    init(clip: Clip, display: ClipDisplay) {
        id = clip.id
        preview = String(Self.searchableTitle(for: display).prefix(Self.previewDisplayCap))
        createdAt = clip.createdAt
        sourceBundleDisplay = clip.sourceBundle ?? ""
        typeDisplay = Self.typeDisplay(for: clip.primaryType)
        pinnedDisplay = clip.isPinned ? String(localized: "Pinned", comment: "History manager pinned-column value") : ""
        decryptFailed = display.decryptFailed
        // Only plain-text clips can become snippets; "String" is capture's highest-priority type, so a
        // text clip always has `primaryType == string` (SnippetMaker relies on the same fact).
        canSnippetize = !display.decryptFailed && clip.primaryType == NSPasteboard.PasteboardType.string.rawValue
        primaryType = clip.primaryType
        isPinned = clip.isPinned
    }

    /// The manager's search haystack AND the (untruncated) source of `preview`: the full masked
    /// `displayTitle`, or the type placeholder for non-text clips — so a query like "image"
    /// finds image rows exactly as it did against the 500-row window's in-memory previews.
    static func searchableTitle(for display: ClipDisplay) -> String {
        if display.decryptFailed {
            return String(localized: "(decryption failed)", comment: "History title when a clipboard item can't be decrypted")
        }
        switch display.primaryType {
        case NSPasteboard.PasteboardType.tiff.rawValue:
            return String(localized: "(Image)", comment: "Placeholder history title for an image clip")
        case NSPasteboard.PasteboardType.pdf.rawValue:
            return String(localized: "(PDF)", comment: "Placeholder history title for a PDF clip")
        case NSPasteboard.PasteboardType.fileURL.rawValue:
            return String(localized: "(Filenames)", comment: "Placeholder history title for a file clip")
        default:
            return display.displayTitle
        }
    }

    /// Internal (M-UI.11 P5): the store maps the facet query's raw `primaryType` values to
    /// these labels for the Type menu — the SAME mapping this row renders with.
    static func typeDisplay(for type: String) -> String {
        switch type {
        case NSPasteboard.PasteboardType.string.rawValue:
            return String(localized: "Text", comment: "History manager type label for text")
        case NSPasteboard.PasteboardType.rtf.rawValue:
            return "RTF"
        case NSPasteboard.PasteboardType.rtfd.rawValue:
            return "RTFD"
        case NSPasteboard.PasteboardType.pdf.rawValue:
            return "PDF"
        case NSPasteboard.PasteboardType.fileURL.rawValue:
            return String(localized: "File", comment: "History manager type label for file URLs")
        case NSPasteboard.PasteboardType.URL.rawValue:
            return "URL"
        case NSPasteboard.PasteboardType.tiff.rawValue:
            return String(localized: "Image", comment: "History manager type label for images")
        default:
            return type
        }
    }
}
