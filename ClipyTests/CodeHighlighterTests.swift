//
//  CodeHighlighterTests.swift
//  ClipyTests
//
//  The homemade syntax highlighter: keyword/string/comment/number runs get their palette
//  color, everything else stays unstyled, and only the first `highlightLimit` characters are
//  tokenized (the tail is appended plain). Pure function — no window, no clipboard.
//

import SwiftUI
import Testing
@testable import Clipy

@Suite struct CodeHighlighterTests {
    /// The styled substrings of `attributed` that carry `color`.
    private func runs(of attributed: AttributedString, colored color: Color) -> [String] {
        attributed.runs.compactMap { run in
            guard run.foregroundColor == color else { return nil }
            return String(attributed.characters[run.range])
        }
    }
    private func plainRuns(of attributed: AttributedString) -> [String] {
        attributed.runs.compactMap { run in
            guard run.foregroundColor == nil else { return nil }
            return String(attributed.characters[run.range])
        }
    }

    @Test func swiftKeywordsStringsCommentsNumbersAreColored() {
        let source = "// add\nlet total = price + 42 // tail\nlet name = \"abc\""
        let highlighted = CodeHighlighter.highlight(source, language: .swift)
        let keywords = runs(of: highlighted, colored: CodeHighlighter.Palette.keyword)
        let comments = runs(of: highlighted, colored: CodeHighlighter.Palette.comment)
        let numbers = runs(of: highlighted, colored: CodeHighlighter.Palette.number)
        let strings = runs(of: highlighted, colored: CodeHighlighter.Palette.string)
        #expect(keywords == ["let", "let"])
        #expect(comments == ["// add", "// tail"])
        #expect(numbers == ["42"])
        #expect(strings == ["\"abc\""])
        // Identifiers stay unstyled — `total`/`price`/`name` are not keywords.
        #expect(plainRuns(of: highlighted).joined().contains("total"))
    }

    @Test func pythonHashCommentAndSingleQuotes() {
        let source = "# setup\ndef run():\n    return 'done'"
        let highlighted = CodeHighlighter.highlight(source, language: .python)
        #expect(runs(of: highlighted, colored: CodeHighlighter.Palette.comment) == ["# setup"])
        #expect(runs(of: highlighted, colored: CodeHighlighter.Palette.keyword) == ["def", "return"])
        #expect(runs(of: highlighted, colored: CodeHighlighter.Palette.string) == ["'done'"])
    }

    @Test func blockCommentsSpanLines() {
        let source = "/* a\n b */ int x = 1;"
        let highlighted = CodeHighlighter.highlight(source, language: .cFamily)
        #expect(runs(of: highlighted, colored: CodeHighlighter.Palette.comment) == ["/* a\n b */"])
        #expect(runs(of: highlighted, colored: CodeHighlighter.Palette.keyword) == ["int"])
    }

    @Test func stringEscapesDoNotEndTheLiteral() {
        let source = "let s = \"a\\\"b\""
        let highlighted = CodeHighlighter.highlight(source, language: .swift)
        #expect(runs(of: highlighted, colored: CodeHighlighter.Palette.string) == ["\"a\\\"b\""])
    }

    @Test func sqlKeywordsMatchCaseInsensitively() {
        let source = "select name from users where id = 7"
        let highlighted = CodeHighlighter.highlight(source, language: .sql)
        #expect(runs(of: highlighted, colored: CodeHighlighter.Palette.keyword) == ["select", "from", "where"])
        #expect(runs(of: highlighted, colored: CodeHighlighter.Palette.number) == ["7"])
    }

    @Test func jsonLiteralsAndStringsAreColored() {
        let source = "{\"ok\": true, \"count\": 3}"
        let highlighted = CodeHighlighter.highlight(source, language: .json)
        #expect(runs(of: highlighted, colored: CodeHighlighter.Palette.keyword) == ["true"])
        #expect(runs(of: highlighted, colored: CodeHighlighter.Palette.string) == ["\"ok\"", "\"count\""])
        #expect(runs(of: highlighted, colored: CodeHighlighter.Palette.number) == ["3"])
    }

    @Test func htmlTagsAreColoredAsKeyword() {
        let source = "<div class=x>hi</div>"
        let highlighted = CodeHighlighter.highlight(source, language: .html)
        let keywords = runs(of: highlighted, colored: CodeHighlighter.Palette.keyword)
        #expect(keywords.contains("<div class=x>"))
        #expect(keywords.contains("</div>"))
        #expect(plainRuns(of: highlighted).joined().contains("hi"))
    }

    @Test func tailBeyondTheLimitStaysPlain() {
        // A keyword right past the cap must NOT be styled; the whole text is still preserved.
        let filler = String(repeating: "a", count: CodeHighlighter.highlightLimit)
        let source = filler + "\nlet x = 1"
        let highlighted = CodeHighlighter.highlight(source, language: .swift)
        #expect(runs(of: highlighted, colored: CodeHighlighter.Palette.keyword).isEmpty)
        #expect(String(highlighted.characters) == source) // nothing dropped
    }

    @Test func unterminatedStringStopsAtTheLineEnd() {
        let source = "let s = \"open\nlet y = 2"
        let highlighted = CodeHighlighter.highlight(source, language: .swift)
        // The literal is colored only to the line break; the next line still tokenizes normally.
        #expect(runs(of: highlighted, colored: CodeHighlighter.Palette.string) == ["\"open"])
        #expect(runs(of: highlighted, colored: CodeHighlighter.Palette.keyword) == ["let", "let"])
    }

    @Test func crlfLineEndingsStillStopCommentsAndStrings() {
        // Adversarial review: "\r\n" is ONE Swift Character that `== "\n"` never matches, so CRLF
        // text used to run a line comment (or an unterminated string) to EOF.
        let source = "// c\r\nlet x = \"open\r\nlet y = 2"
        let highlighted = CodeHighlighter.highlight(source, language: .swift)
        #expect(runs(of: highlighted, colored: CodeHighlighter.Palette.comment) == ["// c"])
        #expect(runs(of: highlighted, colored: CodeHighlighter.Palette.string) == ["\"open"])
        #expect(runs(of: highlighted, colored: CodeHighlighter.Palette.keyword) == ["let", "let"])
    }

    @Test func decimalNumbersStopAtLettersButPrefixedLiteralsRunFull() {
        // "42foo" must not swallow letters into the number run; 0x/0o/0b admit their alphabet.
        let highlighted = CodeHighlighter.highlight("let a = 42foo + 0xFF_AB", language: .swift)
        #expect(runs(of: highlighted, colored: CodeHighlighter.Palette.number) == ["42", "0xFF_AB"])
    }
}
