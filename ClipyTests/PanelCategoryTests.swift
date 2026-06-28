//
//  PanelCategoryTests.swift
//  ClipyTests
//
//  The category filter chain: `CodeClassifier` (the conservative pure heuristic that
//  upgrades a text clip to `.code`), `PanelFilter` (chips → ContentKind narrowing + badge counts),
//  and the model wiring (scope → category → search chain, per-open reset, the Snippets-scope
//  category clear). Synthetic rows only — never real clipboard content. The security-load-bearing
//  case: a masked secret (bullets) must NEVER classify as code, so no chip can single it out.
//

import Foundation
import Testing
@testable import Clipy

// MARK: - CodeClassifier

@Suite struct CodeClassifierTests {
    @Test func detectsSwift() {
        let source = """
        import Foundation
        func greet(name: String) -> String {
            let message = "hi"
            guard !name.isEmpty else { return message }
            return message + name
        }
        """
        #expect(CodeClassifier.classify(source)?.rawValue == "Swift")
    }

    @Test func detectsRust() {
        let source = """
        fn main() {
            let mut total: u32 = 0;
            for item in 0..10 {
                total += item;
            }
            println!("{}", total);
        }
        """
        #expect(CodeClassifier.classify(source)?.rawValue == "Rust")
    }

    @Test func detectsPython() {
        let source = """
        def fib(n):
            if n < 2:
                return n
            return fib(n - 1) + fib(n - 2)

        class Runner:
            def run(self):
                print(fib(10))
        """
        #expect(CodeClassifier.classify(source)?.rawValue == "Python")
    }

    @Test func detectsJavaScript() {
        let source = """
        const items = [1, 2, 3];
        function total(list) {
            return list.reduce((acc, value) => acc + value, 0);
        }
        console.log(total(items));
        """
        #expect(CodeClassifier.classify(source)?.rawValue == "JavaScript")
    }

    @Test func detectsJSONFastPath() {
        let source = "{\"name\": \"clipy\", \"version\": 2, \"tags\": [\"macos\", \"clipboard\"]}"
        #expect(CodeClassifier.classify(source)?.rawValue == "JSON")
    }

    @Test func detectsShellByShebang() {
        let source = """
        #!/bin/bash
        set -euo pipefail
        echo "building"
        """
        #expect(CodeClassifier.classify(source)?.rawValue == "Shell")
    }

    @Test func proseIsNotCode() {
        let prose = """
        Let me know if the function works for you. If it returns an error,
        import the latest build and try again — the class of bug we saw
        last week should be gone now.
        """
        // Keyword words in prose ("function", "import", "class") must not trip the classifier:
        // the structure corroboration (braces/semicolons/indent) is missing.
        #expect(CodeClassifier.classify(prose) == nil)
    }

    @Test func shortFragmentsAndURLsAreNotCode() {
        let url = "https://github.com/ClipySi/clipy-si-macos/pull/3"
        let word = "func"
        let empty = ""
        #expect(CodeClassifier.classify(url) == nil)
        #expect(CodeClassifier.classify(word) == nil)
        #expect(CodeClassifier.classify(empty) == nil)
    }

    @Test func maskedSecretBulletsAreNeverCode() {
        // C3/§9: a masked secret renders as bullets (optionally with disclosed edges). It must stay
        // `.text` so the Code chip can never isolate or hint at secrets.
        #expect(CodeClassifier.classify("●●●●●●●●●●●●") == nil)
        #expect(CodeClassifier.classify("sk-●●●●●●●●●●●●3aF") == nil)
    }

    @Test func detectsYAMLWithDocumentMarkers() {
        let source = """
        ---
        name: clipy
        version: 2
        targets:
          - app
          - tests
        """
        #expect(CodeClassifier.classify(source)?.rawValue == "YAML")
    }

    @Test func markdownNotesAreNotYAML() {
        // Adversarial review: markdown bullet lists/headed notes share YAML's line shape; the
        // shape-only fallback that classified these as YAML was removed (markers now required).
        let todo = """
        # Today
        - groceries: milk, eggs
        - gym (6pm)
        - call mom
        """
        let agenda = """
        # Agenda
        - Review Q3 numbers (Alice)
        - Hiring update: two offers out
        - AOB
        """
        #expect(CodeClassifier.classify(todo) == nil)
        #expect(CodeClassifier.classify(agenda) == nil)
    }

    @Test func chatProseWithCommonWordsIsNotCode() {
        // Adversarial review: bare common-word markers ("fun ", "new ", lowercase "select "/
        // "from ", "let ") used to collect 2 hits from everyday chat/notes clips.
        let chat = """
        That was fun (really)!
        Let's try something new next week.
        # ideas
        - beach: Saturday
        """
        let email = """
        Please select one from the menu options (see the attached file).
        # Options
        Either works for me; let me know.
        """
        #expect(CodeClassifier.classify(chat) == nil)
        #expect(CodeClassifier.classify(email) == nil)
    }
}

// MARK: - PanelFilter

@Suite struct PanelFilterTests {
    private func clip(_ title: String, kind: PanelRow.ContentKind = .text) -> PanelRow {
        .clip(UUID(), title: title, contentKind: kind)
    }
    private func header(_ title: String) -> PanelRow { .folderHeader(UUID(), title: title) }
    private func snippet(_ title: String) -> PanelRow { .snippet(UUID(), title: title) }

    /// One row of every selectable flavor + a folder header, for the matrix tests.
    private var mixedRows: [PanelRow] {
        [clip("plain"), clip("source", kind: .code), clip("https://x.test", kind: .url),
         clip("(Image)", kind: .image), clip("(PDF)", kind: .pdf), clip("(Filenames)", kind: .file),
         clip("#a1b2c3", kind: .color), header("Folder"), snippet("greeting")]
    }

    @Test func allPassesEverythingUnchanged() {
        let rows = mixedRows
        #expect(PanelFilter.filter(rows, category: .all).map(\.id) == rows.map(\.id))
    }

    @Test func categoriesNarrowToTheirKind() {
        let rows = mixedRows
        #expect(PanelFilter.filter(rows, category: .text).map(\.title) == ["plain"])
        #expect(PanelFilter.filter(rows, category: .code).map(\.title) == ["source"])
        #expect(PanelFilter.filter(rows, category: .links).map(\.title) == ["https://x.test"])
        #expect(PanelFilter.filter(rows, category: .images).map(\.title) == ["(Image)"])
        #expect(PanelFilter.filter(rows, category: .colors).map(\.title) == ["#a1b2c3"])
    }

    @Test func filesCategorySpansFileAndPDF() {
        let hits = PanelFilter.filter(mixedRows, category: .files)
        #expect(hits.map(\.title) == ["(PDF)", "(Filenames)"])
    }

    @Test func nonAllHidesSnippetsAndFolderHeaders() {
        // Snippets carry no content kind: every non-All chip is clips-only, so the snippet and its
        // folder header disappear (the chips row is hidden in the Snippets scope for the same reason).
        for category in PanelCategory.allCases where category != .all {
            let hits = PanelFilter.filter(mixedRows, category: category)
            #expect(hits.allSatisfy { if case .clip = $0.kind { true } else { false } })
        }
    }

    @Test func countsSkipHeadersAndCountSnippetsOnlyUnderAll() {
        let counts = PanelFilter.counts(mixedRows)
        #expect(counts[.all] == 8) // 7 clips + 1 snippet; the folder header is not an item
        #expect(counts[.text] == 1)
        #expect(counts[.code] == 1)
        #expect(counts[.links] == 1)
        #expect(counts[.images] == 1)
        #expect(counts[.files] == 2) // file + pdf
        #expect(counts[.colors] == 1)
    }
}

// MARK: - Model wiring (scope → category → search chain)

@MainActor
@Suite struct PanelCategoryModelTests {
    private func makeModel() -> HistoryPanelModel {
        let model = HistoryPanelModel()
        model.reset(historyRows: [.clip(UUID(), title: "alpha notes"),
                                  .clip(UUID(), title: "let x = 1;", contentKind: .code, codeLanguage: "Swift"),
                                  .clip(UUID(), title: "https://example.test", contentKind: .url)],
                    snippetRows: [.folderHeader(UUID(), title: "Folder"),
                                  .snippet(UUID(), title: "sig alpha")])
        return model
    }

    @Test func setCategoryNarrowsAndRebasesSelection() {
        let model = makeModel()
        model.setCategory(.code)
        #expect(model.filteredRows.map(\.title) == ["let x = 1;"])
        #expect(model.selection == model.firstSelectableVisibleID)
        #expect(model.currentPage == 0)
        #expect(model.isCategoryFiltering)
    }

    @Test func categoryComposesWithSearch() {
        let model = makeModel()
        model.searchText = "alpha"
        model.searchTextDidChange()
        // The matching snippet keeps its folder header (filterCombined's header-aware retention).
        #expect(model.filteredRows.map(\.title) == ["alpha notes", "Folder", "sig alpha"])
        model.setCategory(.text)
        #expect(model.filteredRows.map(\.title) == ["alpha notes"]) // chain: scope → category → search
    }

    @Test func resetClearsCategoryAndFilterBar() {
        let model = makeModel()
        model.setCategory(.links)
        model.isFilterBarOpen = true
        model.reset(historyRows: [], snippetRows: [])
        #expect(model.category == .all)
        #expect(model.isFilterBarOpen == false)
    }

    @Test func enteringSnippetsScopeClearsTheCategory() {
        let model = makeModel()
        model.setCategory(.code)
        model.setScope(.snippets)
        #expect(model.category == .all) // a non-All chip would blank the snippet list confusingly
        #expect(model.filteredRows.map(\.title) == ["Folder", "sig alpha"])
    }

    @Test func categoryCountsCoverTheCurrentScope() {
        let model = makeModel()
        #expect(model.categoryCounts[.all] == 4) // 3 clips + 1 snippet (header not counted)
        #expect(model.categoryCounts[.code] == 1)
        model.setScope(.history)
        #expect(model.categoryCounts[.all] == 3)
    }

    @Test func categoryCountsRespectTheActiveSearch() {
        // Badges count the search-narrowed rows, so a chip never promises items the live query
        // then hides (adversarial review): with "alpha" typed, the URL clip must not be badged.
        let model = makeModel()
        model.searchText = "alpha"
        model.searchTextDidChange()
        #expect(model.categoryCounts[.text] == 1) // "alpha notes"
        #expect(model.categoryCounts[.links] == 0)
        #expect(model.categoryCounts[.code] == 0)
    }
}
