//
//  CodeHighlighter.swift
//  ClipySi — Apple Silicon rewrite
//
//  A small, dependency-free syntax highlighter for the rich preview's code blocks:
//  text + `CodeClassifier.Language` → AttributedString with a four-color semantic palette
//  (keyword / string / comment / number, light-dark adaptive system colors).
//
//  DELIBERATELY homemade (vs Highlightr etc.): library highlighters evaluate highlight.js inside
//  JavaScriptCore, which would push every copied clip through a bundled JS parser — an attack
//  surface this project's minimal-dependency policy rejects. A 240pt preview needs only this.
//
//  Pure and deterministic; single pass; only the first `highlightLimit` characters are styled
//  (the remainder is appended unstyled), so a pathological clip can't stall the panel.
//

import SwiftUI

enum CodeHighlighter {
    /// Only this prefix is tokenized; the rest of the text is appended plain.
    static let highlightLimit = 8_192

    /// Semantic palette (Xcode-ish), via system colors so light/dark adapt automatically.
    enum Palette {
        static let keyword = Color(nsColor: .systemPurple)
        static let string = Color(nsColor: .systemRed)
        static let comment = Color(nsColor: .secondaryLabelColor)
        static let number = Color(nsColor: .systemBlue)
    }

    /// Per-language tokenizer configuration. Keywords are exact-match on identifier tokens
    /// (uppercased first for case-insensitive languages like SQL).
    private struct Syntax {
        var keywords: Set<String>
        var lineComments: [String] = []
        var blockComment: (start: String, end: String)?
        var stringDelimiters: Set<Character> = ["\""]
        var caseInsensitiveKeywords = false
        /// HTML/XML: color whole `<...>` tags as keyword instead of word-matching.
        var highlightsTags = false
    }

    /// `text` with the first `highlightLimit` characters syntax-colored for `language`.
    static func highlight(_ text: String, language: CodeClassifier.Language) -> AttributedString {
        let head = String(text.prefix(highlightLimit))
        var result = tokenize(head, syntax: syntax(for: language))
        if text.count > highlightLimit {
            result += AttributedString(String(text.dropFirst(highlightLimit)))
        }
        return result
    }

    // MARK: - Tokenizer

    // Reason: a single-pass state machine over 6 token classes is clearest as one function —
    // splitting per-class would smear the shared cursor/plain-run state across helpers.
    // swiftlint:disable:next cyclomatic_complexity
    private static func tokenize(_ text: String, syntax: Syntax) -> AttributedString {
        var result = AttributedString()
        let chars = Array(text)
        var index = 0
        var plainStart = 0 // start of the pending unstyled run

        // Marker Character-arrays precomputed once (matches() runs per scanned position; building
        // them in the loop would allocate twice per position on an 8KB sample).
        let lineMarkers = syntax.lineComments.map(Array.init)
        let blockMarkers = syntax.blockComment.map { (start: Array($0.start), end: Array($0.end)) }

        func matches(_ marker: [Character], at start: Int) -> Bool {
            guard start + marker.count <= chars.count else { return false }
            for offset in 0..<marker.count where chars[start + offset] != marker[offset] { return false }
            return true
        }
        func flushPlain(upTo end: Int) {
            guard end > plainStart else { return }
            result += AttributedString(String(chars[plainStart..<end]))
        }
        func appendStyled(_ range: Range<Int>, _ color: Color) {
            var run = AttributedString(String(chars[range]))
            run.foregroundColor = color
            result += run
            plainStart = range.upperBound
        }

        while index < chars.count {
            let char = chars[index]
            // Newline stops compare via isNewline, NOT == "\n": Swift folds "\r\n" into ONE
            // grapheme Character that "\n" never equals, so CRLF text would otherwise run a line
            // comment / unterminated string to EOF (adversarial review).
            if lineMarkers.contains(where: { matches($0, at: index) }) {
                flushPlain(upTo: index)
                var end = index
                while end < chars.count && !chars[end].isNewline { end += 1 }
                appendStyled(index..<end, Palette.comment)
                index = end
                continue
            }
            if let block = blockMarkers, matches(block.start, at: index) {
                flushPlain(upTo: index)
                var end = index + block.start.count
                while end < chars.count && !matches(block.end, at: end) { end += 1 }
                end = end < chars.count ? end + block.end.count : chars.count
                appendStyled(index..<end, Palette.comment)
                index = end
                continue
            }
            if syntax.stringDelimiters.contains(char) {
                flushPlain(upTo: index)
                var end = index + 1
                while end < chars.count {
                    if chars[end] == "\\" { end += 2; continue }
                    if chars[end] == char { end += 1; break }
                    if chars[end].isNewline { break } // unterminated literal: stop at the line end
                    end += 1
                }
                end = min(end, chars.count)
                appendStyled(index..<end, Palette.string)
                index = end
                continue
            }
            if syntax.highlightsTags, char == "<" {
                flushPlain(upTo: index)
                var end = index + 1
                while end < chars.count && chars[end] != ">" { end += 1 }
                end = end < chars.count ? end + 1 : chars.count
                appendStyled(index..<end, Palette.keyword)
                index = end
                continue
            }
            if char.isLetter || char == "_" {
                var end = index + 1
                while end < chars.count && (chars[end].isLetter || chars[end].isNumber || chars[end] == "_") {
                    end += 1
                }
                let word = String(chars[index..<end])
                let key = syntax.caseInsensitiveKeywords ? word.uppercased() : word
                if syntax.keywords.contains(key) {
                    flushPlain(upTo: index)
                    appendStyled(index..<end, Palette.keyword)
                }
                index = end
                continue
            }
            if char.isNumber {
                var end = index + 1
                // The hex/binary alphabet is admitted only after a literal 0x/0o/0b prefix;
                // a plain decimal stops at the first non-digit, so "42foo"/"2em" don't get
                // letter characters swallowed into the number run (adversarial review).
                if char == "0", end < chars.count, chars[end] == "x" || chars[end] == "o" || chars[end] == "b" {
                    end += 1
                    while end < chars.count, chars[end].isHexDigit || chars[end] == "_" { end += 1 }
                } else {
                    while end < chars.count, chars[end].isNumber || chars[end] == "." || chars[end] == "_" {
                        end += 1
                    }
                }
                flushPlain(upTo: index)
                appendStyled(index..<end, Palette.number)
                index = end
                continue
            }
            index += 1
        }
        flushPlain(upTo: chars.count)
        return result
    }

    // MARK: - Language tables

    private static func syntax(for language: CodeClassifier.Language) -> Syntax {
        switch language {
        case .swift:
            return Syntax(keywords: ["func", "let", "var", "if", "else", "guard", "return", "for", "while",
                                     "switch", "case", "break", "continue", "import", "struct", "class", "enum",
                                     "protocol", "extension", "init", "deinit", "self", "super", "nil", "true",
                                     "false", "try", "catch", "throw", "throws", "async", "await", "in", "where",
                                     "defer", "static", "private", "public", "internal", "final", "override",
                                     "typealias", "do", "as", "is", "some", "any", "actor", "lazy", "weak"],
                          lineComments: ["//"], blockComment: ("/*", "*/"))
        case .rust:
            return Syntax(keywords: ["fn", "let", "mut", "impl", "pub", "use", "mod", "struct", "enum", "trait",
                                     "match", "if", "else", "return", "for", "while", "loop", "in", "const",
                                     "static", "ref", "self", "Self", "crate", "super", "move", "async", "await",
                                     "dyn", "where", "unsafe", "true", "false", "as", "break", "continue", "type"],
                          lineComments: ["//"], blockComment: ("/*", "*/"))
        case .python:
            return Syntax(keywords: ["def", "return", "if", "elif", "else", "for", "while", "in", "import",
                                     "from", "class", "try", "except", "finally", "with", "as", "lambda", "pass",
                                     "break", "continue", "yield", "global", "nonlocal", "raise", "not", "and",
                                     "or", "is", "None", "True", "False", "async", "await", "del", "assert"],
                          lineComments: ["#"], stringDelimiters: ["\"", "'"])
        case .javascript:
            return Syntax(keywords: ["const", "let", "var", "function", "return", "if", "else", "for", "while",
                                     "switch", "case", "break", "continue", "import", "from", "export", "default",
                                     "class", "extends", "new", "this", "typeof", "instanceof", "in", "of", "try",
                                     "catch", "finally", "throw", "async", "await", "yield", "null", "undefined",
                                     "true", "false", "delete", "void", "static", "get", "set"],
                          lineComments: ["//"], blockComment: ("/*", "*/"), stringDelimiters: ["\"", "'", "`"])
        case .golang:
            return Syntax(keywords: ["func", "package", "import", "var", "const", "type", "struct", "interface",
                                     "map", "chan", "go", "defer", "if", "else", "for", "range", "switch", "case",
                                     "break", "continue", "return", "select", "fallthrough", "nil", "true",
                                     "false", "make", "new", "len", "cap", "append", "error", "string", "int"],
                          lineComments: ["//"], blockComment: ("/*", "*/"), stringDelimiters: ["\"", "`"])
        case .java:
            return Syntax(keywords: ["public", "private", "protected", "class", "interface", "enum", "extends",
                                     "implements", "static", "final", "void", "int", "long", "double", "float",
                                     "boolean", "char", "byte", "short", "new", "return", "if", "else", "for",
                                     "while", "switch", "case", "break", "continue", "try", "catch", "finally",
                                     "throw", "throws", "import", "package", "this", "super", "null", "true",
                                     "false", "abstract", "synchronized", "volatile", "instanceof", "var",
                                     "fun", "val", "when", "object", "companion", "override", "data"],
                          lineComments: ["//"], blockComment: ("/*", "*/"))
        case .cFamily:
            return Syntax(keywords: ["int", "char", "long", "short", "unsigned", "signed", "float", "double",
                                     "void", "struct", "union", "enum", "typedef", "static", "extern", "const",
                                     "volatile", "if", "else", "for", "while", "do", "switch", "case", "break",
                                     "continue", "return", "goto", "sizeof", "include", "define", "ifdef",
                                     "ifndef", "endif", "pragma", "nullptr", "namespace", "class", "template",
                                     "typename", "public", "private", "protected", "virtual", "override", "new",
                                     "delete", "true", "false", "auto", "using", "bool"],
                          lineComments: ["//"], blockComment: ("/*", "*/"))
        case .shell:
            return Syntax(keywords: ["if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case",
                                     "esac", "in", "function", "return", "exit", "echo", "local", "export",
                                     "read", "set", "shift", "until", "break", "continue", "source", "trap"],
                          lineComments: ["#"], stringDelimiters: ["\"", "'"])
        case .sql:
            return Syntax(keywords: ["SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET",
                                     "DELETE", "CREATE", "TABLE", "INDEX", "VIEW", "DROP", "ALTER", "ADD",
                                     "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "ON", "AS", "AND", "OR", "NOT",
                                     "NULL", "IS", "IN", "EXISTS", "BETWEEN", "LIKE", "GROUP", "BY", "ORDER",
                                     "HAVING", "LIMIT", "OFFSET", "DISTINCT", "UNION", "ALL", "PRIMARY", "KEY",
                                     "FOREIGN", "REFERENCES", "DEFAULT", "CASE", "WHEN", "THEN", "ELSE", "END"],
                          lineComments: ["--"], blockComment: ("/*", "*/"), stringDelimiters: ["'"],
                          caseInsensitiveKeywords: true)
        case .json:
            return Syntax(keywords: ["true", "false", "null"])
        case .yaml:
            return Syntax(keywords: ["true", "false", "null", "yes", "no", "on", "off"],
                          lineComments: ["#"], stringDelimiters: ["\"", "'"])
        case .html:
            return Syntax(keywords: [], blockComment: ("<!--", "-->"), highlightsTags: true)
        }
    }
}
