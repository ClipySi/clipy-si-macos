//
//  PanelPreviewBodyTests.swift
//  ClipyTests
//
//  The rich preview's async body preparation (M-UI.12): the render cap that bounds main-thread
//  Text layout for a big clip, the placeholder/prepare split that keeps arrow-key traversal
//  cheap, the first-line/remainder typography split, and the code path's capped highlight
//  (including the unknown-language degradation). Pure `PanelPreviewBody` only — no views.
//

import SwiftUI
import Testing
@testable import Clipy

@Suite struct PanelPreviewBodyTests {
    // MARK: - textContent: split + cap

    @Test func splitsFirstLineFromRemainder() {
        let content = PanelPreviewBody.textContent("headline\nsecond\nthird")
        #expect(content.firstLine == "headline")
        #expect(content.rest == "second\nthird")
    }

    @Test func singleLineHasNoRemainder() {
        let content = PanelPreviewBody.textContent("just one line")
        #expect(content.firstLine == "just one line")
        #expect(content.rest == nil)
    }

    @Test func capsTheBodyAtTheGivenLimit() {
        let title = "head\n" + String(repeating: "x", count: PanelPreviewBody.renderLimit * 2)
        let content = PanelPreviewBody.textContent(title)
        #expect(content.firstLine == "head")
        // first line (4) + newline (1) spent from the budget; the rest fills what remains.
        #expect(content.rest?.count == PanelPreviewBody.renderLimit - 5)
    }

    @Test func placeholderLimitRendersAShorterPrefix() {
        let title = String(repeating: "y", count: PanelPreviewBody.renderLimit)
        let placeholder = PanelPreviewBody.textContent(title, limit: PanelPreviewBody.placeholderLimit)
        #expect(placeholder.firstLine.count == PanelPreviewBody.placeholderLimit)
    }

    @Test func capNeverSplitsAGrapheme() {
        // Character-based prefix: a flag emoji (two scalars, one Character) at the cap boundary
        // survives intact instead of degrading into a broken scalar.
        let title = String(repeating: "🇯🇵", count: PanelPreviewBody.renderLimit + 10)
        let content = PanelPreviewBody.textContent(title)
        #expect(content.firstLine.count == PanelPreviewBody.renderLimit)
        #expect(content.firstLine.allSatisfy { $0 == "🇯🇵" })
    }

    // MARK: - isTruncated: the note is limit-independent (no placeholder↔prepared flicker)

    @Test func truncationFlagFlipsExactlyPastTheRenderLimit() {
        let atLimit = String(repeating: "a", count: PanelPreviewBody.renderLimit)
        #expect(!PanelPreviewBody.isTruncated(atLimit))
        #expect(PanelPreviewBody.isTruncated(atLimit + "a"))
    }

    // MARK: - needsPreparation: what goes through the async pass

    @Test func shortTextRendersSynchronously() {
        let short = String(repeating: "a", count: PanelPreviewBody.placeholderLimit)
        #expect(!PanelPreviewBody.needsPreparation(kind: .text, title: short))
        #expect(PanelPreviewBody.needsPreparation(kind: .text, title: short + "a"))
    }

    @Test func codeAlwaysPreparesAndOtherKindsNever() {
        #expect(PanelPreviewBody.needsPreparation(kind: .code, title: "let x = 1"))
        for kind: PanelRow.ContentKind in [.url, .image, .pdf, .file, .color] {
            #expect(!PanelPreviewBody.needsPreparation(kind: kind, title: "anything"))
        }
    }

    // MARK: - prepare: the detached-task payload

    @Test func preparedTextMatchesTheDirectSplit() {
        let title = "head\nbody line"
        #expect(PanelPreviewBody.prepare(kind: .text, title: title, languageLabel: nil)
            == .text(PanelPreviewBody.textContent(title)))
    }

    @Test func preparedCodeIsHighlightedAndCapped() {
        let source = "let x = 1\n" + String(repeating: "z", count: PanelPreviewBody.renderLimit * 2)
        let payload = PanelPreviewBody.prepare(kind: .code, title: source, languageLabel: "Swift")
        guard case .code(let text)? = payload else {
            Issue.record("expected a code payload")
            return
        }
        #expect(text.characters.count == PanelPreviewBody.renderLimit)
        // The capped source still went through the highlighter — "let" carries the keyword color.
        let hasKeywordRun = text.runs.contains { $0.foregroundColor == CodeHighlighter.Palette.keyword }
        #expect(hasKeywordRun)
    }

    @Test func unknownLanguageDegradesToPlainCappedCode() {
        let source = String(repeating: "q", count: PanelPreviewBody.renderLimit + 100)
        let payload = PanelPreviewBody.prepare(kind: .code, title: source, languageLabel: "NotALanguage")
        guard case .code(let text)? = payload else {
            Issue.record("expected a code payload")
            return
        }
        #expect(text.characters.count == PanelPreviewBody.renderLimit) // capped even without a highlighter
        #expect(text.runs.allSatisfy { $0.foregroundColor == nil })    // and left unstyled
    }

    @Test func nonTextualKindsPrepareNothing() {
        #expect(PanelPreviewBody.prepare(kind: .image, title: "(Image)", languageLabel: nil) == nil)
        #expect(PanelPreviewBody.prepare(kind: .url, title: "https://example.test", languageLabel: nil) == nil)
    }

    // MARK: - urlContent: BOTH lines capped (the host line must not bypass the render limit)

    @Test func shortURLKeepsHostAndBodyIntact() {
        let url = PanelPreviewBody.urlContent("  https://example.test/path?q=1\n")
        #expect(url.host == "example.test") // trimmed before parsing
        #expect(url.urlText == "https://example.test/path?q=1")
        #expect(!url.isTruncated)
    }

    @Test func pathologicalHostIsCappedLikeTheBody() {
        // URL.host() echoes a multi-KB host verbatim — the emphasized host line needs the same
        // cap as the URL body, or the unbroken-string synchronous layout comes back (review).
        let host = String(repeating: "a", count: PanelPreviewBody.renderLimit * 2)
        let url = PanelPreviewBody.urlContent("https://\(host)/path")
        #expect(url.host?.count == PanelPreviewBody.renderLimit)
        #expect(url.urlText.count == PanelPreviewBody.renderLimit)
        #expect(url.isTruncated)
    }

    @Test func longQueryCapsTheBodyButNotTheHost() {
        let title = "https://example.test/?q=" + String(repeating: "b", count: PanelPreviewBody.renderLimit * 2)
        let url = PanelPreviewBody.urlContent(title)
        #expect(url.host == "example.test")
        #expect(url.urlText.count == PanelPreviewBody.renderLimit)
        #expect(url.isTruncated)
    }

    @Test func hostlessTitleStillRendersACappedBody() {
        // A title without an authority (kind misfires are synthetic, but the helper must not
        // assume parseability): no host line, the body still renders.
        let url = PanelPreviewBody.urlContent("not a url, just text")
        #expect(url.host == nil)
        #expect(url.urlText == "not a url, just text")
        #expect(!url.isTruncated)
    }
}
