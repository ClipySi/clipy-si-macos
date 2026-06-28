//
//  SnippetXMLTests.swift
//  ClipyTests
//
//  Snippet XML round-trip + the original-compatibility contract: lossless title/content (incl.
//  multi-line and leading whitespace), order derived from document position, a folder with no
//  <snippets> yields no snippets, and fallback strings on missing values (design §2.8 / §6 d6).
//

import Foundation
import Testing
@testable import Clipy

@Suite struct SnippetXMLTests {
    private func detail(_ title: String, _ snippets: [(String, String)]) -> SnippetFolderDetail {
        let folder = SnippetFolder(id: UUID(), title: title, sortOrder: 0, isEnabled: true)
        let rows = snippets.enumerated().map { index, pair in
            Snippet(id: UUID(), folderID: folder.id, title: pair.0, content: pair.1,
                    sortOrder: index, isEnabled: true)
        }
        return SnippetFolderDetail(folder: folder, snippets: rows)
    }

    @Test func roundTripsTitleAndContentInOrder() throws {
        let details = [
            detail("Greetings", [("Hello", "hello\n  world"), ("Bye", "bye")]),
            detail("Empty", [])
        ]
        let drafts = try SnippetXML.decode(SnippetXML.export(details))

        #expect(drafts.map(\.title) == ["Greetings", "Empty"])
        #expect(drafts[0].snippets.map(\.title) == ["Hello", "Bye"])
        // Multi-line + leading whitespace preserved (shouldTrimWhitespace = false).
        #expect(drafts[0].snippets.map(\.content) == ["hello\n  world", "bye"])
        #expect(drafts[1].snippets.isEmpty)
    }

    @Test func escapesAndRestoresXMLSpecialCharacters() throws {
        let details = [detail("F", [("a<b & c>d", "x=\"1\" & y='2'")])]
        let drafts = try SnippetXML.decode(SnippetXML.export(details))
        #expect(drafts[0].snippets.first?.title == "a<b & c>d")
        #expect(drafts[0].snippets.first?.content == "x=\"1\" & y='2'")
    }

    @Test func folderWithoutSnippetsWrapperYieldsNoSnippets() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <folders>
        <folder><title>NoSnippets</title></folder>
        <folder><title>Has</title><snippets><snippet><title>t</title><content>c</content></snippet></snippets></folder>
        </folders>
        """
        let drafts = try SnippetXML.decode(Data(xml.utf8))
        #expect(drafts.count == 2)
        #expect(drafts[0].title == "NoSnippets")
        #expect(drafts[0].snippets.isEmpty)
        #expect(drafts[1].snippets.map(\.title) == ["t"])
    }

    @Test func fallsBackToDefaultStringsForMissingValues() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <folders>
        <folder><snippets><snippet></snippet></snippets></folder>
        </folders>
        """
        let drafts = try SnippetXML.decode(Data(xml.utf8))
        #expect(drafts.first?.title == "untitled folder")
        #expect(drafts.first?.snippets.first?.title == "untitled snippet")
        #expect(drafts.first?.snippets.first?.content == "")
    }

    @Test func throwsOnMalformedXML() {
        #expect(throws: (any Error).self) {
            try SnippetXML.decode(Data("<folders><folder>".utf8)) // unterminated
        }
    }
}
