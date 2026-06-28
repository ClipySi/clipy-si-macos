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
    let id: Clip.ID
    let preview: String
    let createdAt: Date
    let sourceBundleDisplay: String
    let typeDisplay: String
    let pinnedDisplay: String
    let decryptFailed: Bool
    let canSnippetize: Bool

    /// Copy is suppressed for rows whose payload can't be decrypted (ephemeral-key fallback).
    var canCopy: Bool { !decryptFailed }

    init(clip: Clip, display: ClipDisplay) {
        id = clip.id
        preview = Self.preview(for: display)
        createdAt = clip.createdAt
        sourceBundleDisplay = clip.sourceBundle ?? ""
        typeDisplay = Self.typeDisplay(for: clip.primaryType)
        pinnedDisplay = clip.isPinned ? String(localized: "Pinned", comment: "History manager pinned-column value") : ""
        decryptFailed = display.decryptFailed
        // Only plain-text clips can become snippets; "String" is capture's highest-priority type, so a
        // text clip always has `primaryType == string` (SnippetMaker relies on the same fact).
        canSnippetize = !display.decryptFailed && clip.primaryType == NSPasteboard.PasteboardType.string.rawValue
    }

    private static func preview(for display: ClipDisplay) -> String {
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

    private static func typeDisplay(for type: String) -> String {
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
