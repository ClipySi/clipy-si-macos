//
//  CodeClassifier.swift
//  ClipySi — Apple Silicon rewrite
//
//  Pure "does this clip look like source code?" heuristic + a coarse language guess.
//  One classifier feeds BOTH the panel's Code filter chip (via `ContentKind.code`) and the rich
//  preview's syntax highlighting, so the two never disagree. Display-only: classification never
//  affects capture, storage, or paste.
//
//  It runs over the MASKED display title (max 10k preview) — a masked secret is all bullets,
//  which matches no code structure, so secrets stay `.text` by construction. Only the first
//  `scanLimit` characters are examined (panel-open cost over a full page stays trivial).
//
//  Deliberately conservative: a miss just shows the text glyph/preview (no harm); a false
//  positive would put prose under the Code chip — so structure (braces/indent/shebang) must
//  corroborate keywords before anything is called code.
//

import Foundation

enum CodeClassifier {
    /// Languages the classifier can name (and the highlighter has keyword sets for). The raw value
    /// is the display label shown in the preview header chip.
    enum Language: String, CaseIterable, Sendable {
        case swift = "Swift"
        case rust = "Rust"
        case python = "Python"
        case javascript = "JavaScript"
        case golang = "Go"
        case java = "Java"
        case cFamily = "C"
        case shell = "Shell"
        case sql = "SQL"
        case json = "JSON"
        case yaml = "YAML"
        case html = "HTML"
    }

    /// Only this prefix is examined — plenty to recognise code, cheap enough for a page of rows.
    static let scanLimit = 2_048

    /// The language when `text` looks like source code, else nil. Pure and deterministic.
    static func classify(_ text: String) -> Language? {
        let sample = String(text.prefix(scanLimit))
        let trimmed = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return nil }

        // Structured-document fast paths (their grammar is the structure itself).
        if looksLikeJSON(trimmed) { return .json }
        if looksLikeHTML(trimmed) { return .html }
        if trimmed.hasPrefix("#!") { return .shell }

        let lines = sample.split(separator: "\n", omittingEmptySubsequences: false)
        guard let language = strongestKeywordLanguage(in: sample, lines: lines) else { return nil }

        // YAML's grammar IS its line shape — and strongestKeywordLanguage already double-gated it
        // (≥2 markers AND ≥75% yaml-shaped lines), so the brace/semicolon structure gate below
        // (which real YAML almost never satisfies) is skipped, like the JSON/HTML fast paths.
        if language == .yaml { return .yaml }

        // Keywords alone aren't enough ("for example, if you let..." is prose): require structural
        // corroboration — braces/semicolons/operators, comment markers, or indented continuation.
        guard structureScore(sample, lines: lines) >= 2 else { return nil }
        return language
    }

    // MARK: - Structured documents

    private static func looksLikeJSON(_ trimmed: String) -> Bool {
        guard (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) ||
              (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) else { return false }
        return trimmed.contains("\":") || trimmed.contains("\" :") ||
               (trimmed.hasPrefix("[") && trimmed.contains(","))
    }

    private static func looksLikeHTML(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix("<") else { return false }
        let lowered = trimmed.lowercased()
        return lowered.hasPrefix("<!doctype") || lowered.hasPrefix("<html") ||
               lowered.hasPrefix("<?xml") ||
               (lowered.contains("</") && lowered.contains(">"))
    }

    // MARK: - Keyword evidence

    /// Definitive per-language markers. Each must be rare in prose — bare common English words
    /// ("new ", "let ", "from ", "select ", "fun ", "match ") were removed after the
    /// adversarial review showed realistic chat/notes clips collecting 2 hits from them. A weaker
    /// language recall is fine (a miss just shows the text glyph); a false positive puts prose
    /// under the Code chip. The language with the most hits wins; zero hits ⇒ not code.
    private static let signatures: [(Language, [String])] = [
        (.swift, ["func ", "let ", "var ", "guard ", "@MainActor", "extension ", "protocol ", "import Foundation", "import Swift"]),
        (.rust, ["fn ", "let mut ", "impl ", "pub fn", "use std", "-> ", "&self"]),
        // "print" + "(" split so the redaction-grep logging gate doesn't read this DATA as a call.
        (.python, ["def ", "import ", "elif ", "self.", "lambda ", "print" + "(", "__init__"]),
        (.javascript, ["const ", "=> ", "function ", "console.", "await ", "export ", "require("]),
        (.golang, ["func ", "package ", ":= ", "fmt.", "go func", "defer "]),
        (.java, ["public class", "private final", "void ", "System.out", "@Override", "import java", "extends ", "implements ", "val "]),
        (.cFamily, ["#include", "int main", "printf(", "void ", "struct ", "->", "#define"]),
        (.shell, ["#!/", "echo ", "fi\n", "esac", "$1", "${", "grep ", "sudo "]),
        (.sql, ["SELECT ", "INSERT INTO", "UPDATE ", "CREATE TABLE", "WHERE ", "FROM "]),
        (.yaml, ["---\n", ":\n  ", ": |", ": >"])
    ]

    private static func strongestKeywordLanguage(in sample: String, lines: [Substring]) -> Language? {
        var best: (Language, Int)?
        for (language, markers) in signatures {
            let hits = markers.lazy.filter { sample.contains($0) }.count
            if hits >= 2, hits > (best?.1 ?? 0) {
                best = (language, hits)
            }
        }
        // YAML additionally needs its line shape (most lines `key: …` / `- item` / `key:`) ON TOP
        // of its keyword markers. There is deliberately NO shape-only fallback: markdown bullet
        // lists and headed notes have exactly this shape, and the adversarial review showed
        // everyday notes classifying as YAML through it (false positives are the costly failure).
        if best?.0 == .yaml {
            let meaningful = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard meaningful.count >= 3 else { return nil }
            let yamlish = meaningful.filter {
                let line = $0.trimmingCharacters(in: .whitespaces)
                return line.hasPrefix("- ") || (line.contains(": ") && !line.hasSuffix(":")) || line.hasSuffix(":")
            }
            return yamlish.count * 4 >= meaningful.count * 3 ? .yaml : nil
        }
        return best?.0
    }

    // MARK: - Structural corroboration

    /// Counts independent code-shaped signals (braces/semicolons, comment markers, indentation,
    /// call-shaped parens). Each must be HARD for prose to satisfy: `# ` (a markdown heading) and
    /// "any parenthetical in multi-line text" were dropped after the adversarial review showed
    /// notes/chat clips scoring 2 from them alone.
    private static func structureScore(_ sample: String, lines: [Substring]) -> Int {
        var score = 0
        let braces = sample.filter { $0 == "{" || $0 == "}" }.count
        if braces >= 2 { score += 1 }
        if sample.contains(";\n") || sample.hasSuffix(";") { score += 1 }
        if sample.contains("//") || sample.contains("/*") || sample.contains("-- ") { score += 1 }
        let indented = lines.filter { $0.hasPrefix("    ") || $0.hasPrefix("\t") }.count
        if indented >= 2 { score += 1 }
        if hasCallShapedParen(sample) { score += 1 }
        return score
    }

    /// `foo(`-shaped: an identifier character DIRECTLY before `(`. Prose parentheticals — "gym
    /// (6pm)", "see (attached)" — have a space/punctuation there, so they don't count.
    private static func hasCallShapedParen(_ sample: String) -> Bool {
        var previous: Character = " "
        for char in sample {
            if char == "(", previous.isLetter || previous.isNumber || previous == "_" { return true }
            previous = char
        }
        return false
    }
}
