//
//  PanelPreviewBody.swift
//  ClipySi — Apple Silicon rewrite
//
//  Pure, nonisolated preparation of the rich preview's text/code body (M-UI.12): the capture
//  title can be up to 10,000 characters, and laying that out synchronously in a SwiftUI `Text`
//  stalls the panel on every selection change onto a big clip (user-reported lag). The view
//  renders a cheap `placeholderLimit` prefix immediately and swaps in the prepared, capped body
//  one beat later (`.task(id:)` + detached, the established CodeHighlighter pattern) — so
//  arrow-key traversal never pays a full layout for rows it passes over.
//
//  Bounded on purpose: at most `renderLimit` characters ever reach a `Text`. The preview is for
//  identifying a clip, not reading it in full — paste delivers the complete payload regardless.
//  Everything here operates on the MASKED display string (`PanelRow.title`); no raw secrets.
//

import Foundation

enum PanelPreviewBody {
    /// Hard cap on the characters the preview body ever renders — bounds the main-thread Text
    /// layout for a pathological clip (unbroken base64 character-wraps expensively). ~70+
    /// wrapped lines in the 420pt pane: generous for a preview.
    static let renderLimit = 4_096
    /// Bodies at or under this length render synchronously (they ARE the final content); longer
    /// ones paint this prefix instantly as a placeholder and get the full capped body async.
    static let placeholderLimit = 1_024
    /// Debounce before the detached prepare spawns (the provider's image-decrypt value): a
    /// cancelled `.task(id:)` only ever aborts a sleep, so held-arrow traversal never launches a
    /// tokenization for a row it passed over — the detached work itself is not cancellable.
    static let debounceNanoseconds: UInt64 = 120_000_000

    /// The text body split the pane renders: emphasized first line + secondary remainder.
    struct TextContent: Equatable, Sendable {
        let firstLine: String
        let rest: String?
    }

    /// The URL body the pane renders: BOTH lines capped — `URL.host()` reproduces a multi-KB
    /// host verbatim from a pathological URL, so an uncapped host line would reopen the exact
    /// unbroken-string synchronous layout this file exists to bound (adversarial review).
    struct URLContent: Equatable, Sendable {
        let host: String?
        let urlText: String
        let isTruncated: Bool
    }

    /// The capped host/URL pair for a URL row. Sync-render cheap by construction: everything
    /// downstream is at most `renderLimit` characters.
    static func urlContent(_ title: String) -> URLContent {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = URL(string: trimmed)?.host()
        return URLContent(host: host.map { String($0.prefix(renderLimit)) },
                          urlText: String(trimmed.prefix(renderLimit)),
                          isTruncated: isTruncated(trimmed))
    }

    /// The async-prepared body for one row, Sendable across the detached-task boundary.
    enum Payload: Equatable, Sendable {
        case text(TextContent)
        case code(AttributedString)
    }

    /// Whether the title renders with the "(preview truncated)" note — i.e. the final body cap
    /// drops characters. Independent of the placeholder prefix, so the note never flickers
    /// between the placeholder frame and the prepared body landing.
    static func isTruncated(_ title: String) -> Bool {
        title.count > renderLimit
    }

    /// Whether `title` needs the async preparation pass for `kind`. Code always prepares (the
    /// highlight itself is the async work); text prepares only past the placeholder budget —
    /// short bodies are final on the first frame, with no placeholder swap at all.
    static func needsPreparation(kind: PanelRow.ContentKind, title: String) -> Bool {
        switch kind {
        case .code: return true
        case .text: return title.count > placeholderLimit
        default: return false
        }
    }

    /// The first-line/remainder split over at most `limit` characters. `Character`-based
    /// `prefix`, so a cap can never cut a grapheme (emoji, CRLF) in half.
    static func textContent(_ title: String, limit: Int = renderLimit) -> TextContent {
        let capped = String(title.prefix(limit))
        let lines = capped.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        return TextContent(firstLine: lines.first.map(String.init) ?? " ",
                           rest: lines.count > 1 ? String(lines[1]) : nil)
    }

    /// The prepared body for one row — runs on a detached task, off the MainActor. Code rows
    /// highlight the capped source (within `CodeHighlighter.highlightLimit`, so no unstyled tail);
    /// an unknown language label degrades to a plain capped body instead of skipping the cap.
    static func prepare(kind: PanelRow.ContentKind, title: String, languageLabel: String?) -> Payload? {
        switch kind {
        case .text:
            return .text(textContent(title))
        case .code:
            let capped = String(title.prefix(renderLimit))
            guard let language = CodeClassifier.Language(rawValue: languageLabel ?? "") else {
                return .code(AttributedString(capped))
            }
            return .code(CodeHighlighter.highlight(capped, language: language))
        default:
            return nil
        }
    }
}
