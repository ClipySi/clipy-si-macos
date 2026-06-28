//
//  SnippetXML.swift
//  ClipySi — Apple Silicon rewrite
//
//  Snippet import/export in the original Clipy's AEXML format, byte-for-byte compatible so files
//  exported by either app interoperate (design §2.8). The schema has NO attributes — every value
//  is a child element:
//
//    <folders>
//      <folder>
//        <title>…</title>                 ← written before <snippets>
//        <snippets>
//          <snippet><title>…</title><content>…</content></snippet>
//        </snippets>
//      </folder>
//    </folders>
//
//  `isEnabled`/`sortOrder` are intentionally NOT persisted (import forces enabled = true and derives
//  order from document position — round-trip is lossy by design; §6 delta 3/AC3). `Constants.Xml.type`
//  exists in the original vocab but is not part of the snippet document — we do not emit it (§6 delta 7).
//  Decode mirrors the original exactly: `shouldTrimWhitespace = false`, iterate ALL children of
//  <folders>, descend one <snippets> wrapper (`folder["snippets"]["snippet"].all`), and fall back to
//  "untitled folder"/"untitled snippet"/"" on missing values (§6 delta 6).
//

import AEXML
import Foundation

enum SnippetXML {
    // Verbatim element names from the original `Constants.Xml`.
    private static let rootElement = "folders"
    private static let folderElement = "folder"
    private static let snippetsElement = "snippets"
    private static let snippetElement = "snippet"
    private static let titleElement = "title"
    private static let contentElement = "content"

    /// Serializes folders (and their snippets) to the original AEXML format as UTF-8 data.
    static func export(_ details: [SnippetFolderDetail]) -> Data {
        let document = AEXMLDocument()
        let root = document.addChild(name: rootElement)
        for detail in details {
            let folder = root.addChild(name: folderElement)
            folder.addChild(name: titleElement, value: detail.folder.title)
            let snippets = folder.addChild(name: snippetsElement)
            for snippet in detail.snippets {
                let element = snippets.addChild(name: snippetElement)
                element.addChild(name: titleElement, value: snippet.title)
                element.addChild(name: contentElement, value: snippet.content)
            }
        }
        return Data(document.xml.utf8)
    }

    /// Parses the original AEXML format into folder drafts (for `SnippetRepository.insertFolders`).
    /// Throws on malformed XML.
    static func decode(_ data: Data) throws -> [SnippetFolderDraft] {
        var options = AEXMLOptions()
        options.parserSettings.shouldTrimWhitespace = false // preserve multi-line / leading-space content
        let document = try AEXMLDocument(xml: data, options: options)

        return document[rootElement].children.map { folder in
            let title = folder[titleElement].value ?? "untitled folder"
            let snippets = (folder[snippetsElement][snippetElement].all ?? []).map { element in
                SnippetDraft(
                    title: element[titleElement].value ?? "untitled snippet",
                    content: element[contentElement].value ?? ""
                )
            }
            return SnippetFolderDraft(title: title, snippets: snippets)
        }
    }
}
