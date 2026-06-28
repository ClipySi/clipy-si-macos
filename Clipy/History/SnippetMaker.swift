//
//  SnippetMaker.swift
//  ClipySi — Apple Silicon rewrite
//
//  The testable core of the History Manager's "Snippetize" action: turn a captured history
//  clip into a snippet. Content is the clip's decrypted plain-text payload; the title is a short
//  label derived from the decrypted preview. Crypto lives here (not in the repository), mirroring
//  the menu's decrypt-at-display split (security-guidance.md §5 / R3).
//
//  Only plain-text clips are snippetizable. CaptureService.storeTypeOrder lists "String" first, so a
//  clip that has any plain-text representation captures it as the PRIMARY — `primaryType == string`
//  is therefore the one and only place text content lives, and a secondary-representation lookup
//  (as paste does defensively) can never apply here. Non-text / undecryptable clips yield nil so the
//  caller disables the action rather than create an empty or garbage snippet.
//

import AppKit
import Foundation
import SQLiteData

struct SnippetMaker {
    @Dependency(\.historyCipher) private var cipher
    private let clips = ClipRepository()
    private let snippets = SnippetRepository()
    private let blobStore: EncryptedBlobStore

    /// A snippet ready to insert: a short `title` label and the full plain-text `content`.
    struct Draft: Equatable {
        let title: String
        let content: String
    }

    init(blobStore: EncryptedBlobStore) {
        self.blobStore = blobStore
    }

    /// The snippet draft for `clipID`, or nil when the clip is missing, not plain text, or can't be
    /// decrypted (the title preview and the content blob share one key, so either failing disables it).
    func draft(forClipID id: Clip.ID) throws -> Draft? {
        guard let clip = try clips.clip(id: id) else { return nil }
        guard clip.primaryType == NSPasteboard.PasteboardType.string.rawValue else { return nil } // non-text
        guard let titleData = try? cipher.open(clip.titleCipher),
              let preview = String(bytes: titleData, encoding: .utf8) else { return nil } // decrypt failed
        guard let contentData = try? blobStore.read(id: clip.dataPath),
              let content = String(bytes: contentData, encoding: .utf8) else { return nil }
        return Draft(title: Self.title(fromPreview: preview), content: content)
    }

    /// Appends the clip as a new snippet in `folderID`. Returns the inserted snippet, or nil if the
    /// clip isn't snippetizable (so the caller can beep).
    @discardableResult
    func snippetize(clipID: Clip.ID, intoFolder folderID: SnippetFolder.ID) throws -> Snippet? {
        guard let draft = try draft(forClipID: clipID) else { return nil }
        return try snippets.insertSnippet(folderID: folderID, title: draft.title, content: draft.content)
    }

    /// The snippet label: the first non-empty line of the preview, trimmed and capped. Falls back to a
    /// localized placeholder when the text has no printable first line — the same empty-title guard the
    /// snippet editor applies (SnippetEditorView title `onChange`). The full text is kept as `content`;
    /// only this short label is derived, so a multi-line clip gets a sane menu title.
    static func title(fromPreview preview: String) -> String {
        let firstLine = preview.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return String(localized: "untitled snippet",
                          comment: "Snippet title when a history clip has no usable first line")
        }
        return String(trimmed.prefix(snippetTitleMaxLength))
    }
}

/// Cap for the auto-derived snippet title so a long clip doesn't produce a pathological menu label.
private let snippetTitleMaxLength = 50
