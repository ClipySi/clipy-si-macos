//
//  ClipSelectionCoordinator.swift
//  ClipySi — Apple Silicon rewrite
//
//  The framework-agnostic selection logic behind the history FloatingPanel (history-panel design
//  §1.3): build the display rows from `MenuModel` and turn a row pick into a paste, gating a masked
//  secret behind local authentication. This is the *only* clip-paste path (the
//  NSMenu no longer renders clips), so the masked-secret gate lives here, not in the menu controller.
//  Kept out of the SwiftUI view so it is unit-testable without a window. AppKit-bound (NSSound,
//  MenuModel) → `@MainActor`.
//

import AppKit

/// A stable identity for a unified-panel row, spanning the three row kinds (history clip, snippet, and
/// the non-selectable folder header that groups snippets). `Hashable` so it can drive `List(selection:)`.
enum RowID: Hashable, Sendable {
    case clip(Clip.ID)
    case snippet(Snippet.ID)
    case folderHeader(SnippetFolder.ID)
}

/// One display-ready row for the unified panel list (history clips + snippets in one List).
/// For a clip the `title` is already the masked `displayTitle` (or a bracketed placeholder for non-text)
/// — never the raw secret. Snippet/folder titles are user-authored plaintext (no masking applies).
struct PanelRow: Identifiable, Equatable, Sendable {
    /// What this row represents — drives selectability and the paste routing in `select(_:)`.
    enum Kind: Equatable, Sendable {
        /// A clipboard history clip. `isSecret`/`decryptFailed` gate the paste (masked-secret AuthGate).
        case clip(isSecret: Bool, decryptFailed: Bool)
        /// A user-authored snippet (plaintext — no AuthGate).
        case snippet
        /// A snippet-folder grouping header: rendered but NOT selectable/pasteable, skipped by nav/numbering.
        case folderHeader
    }

    /// The coarse content type of a clip row, driving its leading list glyph and the
    /// category filter / rich preview. Display-only — it never affects paste/selection.
    /// `text`/`url`/`code` are inferred from the masked title (others come from the primary
    /// UTType / color flag); `code` uses the conservative `CodeClassifier` heuristic.
    enum ContentKind: Equatable, Sendable {
        case text, code, url, image, pdf, file, color
    }

    let id: RowID
    /// The render string: clip = masked `displayTitle`/placeholder; snippet/folder = trimmed plaintext title.
    let title: String
    let kind: Kind
    /// For a clip, the coarse content type behind the leading glyph. Always `.text` for snippet/folder
    /// rows (they carry their own glyphs). A `var` with a default so the snippet/folder factories and
    /// existing call sites stay source-compatible (memberwise init keeps the parameter optional).
    var contentKind: ContentKind = .text
    /// For a `.code` clip, the classifier's language label ("Swift", "JSON", …) shown by the rich
    /// preview. Nil for everything else.
    var codeLanguage: String?
    /// When the underlying clip was captured — the preview pane's relative timestamp. Nil for
    /// snippet/folder rows (and clips synthesised in tests).
    var createdAt: Date?
    /// Bundle id of the app the clip was copied from, when known (`org.nspasteboard.source`); the preview
    /// pane resolves it to an app name. Nil for snippets/folders and most clips.
    var sourceBundle: String?

    /// Folder headers are display-only; everything else can be highlighted, numbered, and pasted.
    var isSelectable: Bool {
        if case .folderHeader = kind { return false }
        return true
    }
    /// A secret was detected in the underlying clip (only meaningful for `.clip`).
    var isSecret: Bool { if case .clip(let secret, _) = kind { return secret } else { return false } }
    /// The clip's payload couldn't be decrypted — not pasteable, shown dimmed (only for `.clip`).
    var decryptFailed: Bool { if case .clip(_, let failed) = kind { return failed } else { return false } }
}

extension PanelRow {
    static func clip(_ id: Clip.ID, title: String, isSecret: Bool = false, decryptFailed: Bool = false,
                     contentKind: ContentKind = .text, codeLanguage: String? = nil,
                     createdAt: Date? = nil, sourceBundle: String? = nil) -> PanelRow {
        PanelRow(id: .clip(id), title: title, kind: .clip(isSecret: isSecret, decryptFailed: decryptFailed),
                 contentKind: contentKind, codeLanguage: codeLanguage,
                 createdAt: createdAt, sourceBundle: sourceBundle)
    }
    static func snippet(_ id: Snippet.ID, title: String) -> PanelRow {
        PanelRow(id: .snippet(id), title: title, kind: .snippet)
    }
    static func folderHeader(_ id: SnippetFolder.ID, title: String) -> PanelRow {
        PanelRow(id: .folderHeader(id), title: title, kind: .folderHeader)
    }
}

/// The subset of settings the panel's paging/numbering needs (read per-open).
struct PanelSettings: Equatable, Sendable {
    let itemsPerPage: Int
    let startWithZero: Bool
    let markedWithNumbers: Bool
}

@MainActor
final class ClipSelectionCoordinator {
    private let model: MenuModel
    private let snippets = SnippetRepository()
    private let authGate: AuthGate

    /// Invoked with the chosen clip id; AppDelegate wires this to `PasteService.paste(clipID:)`.
    var onSelectClip: ((Clip.ID) -> Void)?
    /// Invoked with the chosen snippet id; AppDelegate wires this to `PasteService.paste(snippetID:)`.
    /// Snippets are user-authored plaintext — never gated by the masked-secret AuthGate.
    var onSelectSnippet: ((Snippet.ID) -> Void)?

    init(model: MenuModel = MenuModel(), authGate: AuthGate = .live) {
        self.model = model
        self.authGate = authGate
    }

    /// The paging-relevant settings, read live so the panel reflects changes between opens.
    var panelSettings: PanelSettings {
        let settings = model.settings
        return PanelSettings(itemsPerPage: settings.historyPanelItemsPerPage,
                             startWithZero: settings.menuItemsTitleStartWithZero,
                             markedWithNumbers: settings.menuItemsAreMarkedWithNumbers)
    }

    /// The current history rows (newest- or oldest-first per settings), decrypted + masked. Capped at
    /// `maxHistorySize`. Each carries `.clip` kind so the unified panel routes its paste through the gate.
    func historyRows() -> [PanelRow] {
        model.history().map { display in
            let body = Self.displayBody(for: display)
            var kind = Self.contentKind(for: display)
            var language: String?
            // Code detection runs only on plain-text candidates. A masked secret is all
            // bullets — no code structure — so it stays `.text` by construction.
            if kind == .text, let detected = CodeClassifier.classify(body) {
                kind = .code
                language = detected.rawValue
            }
            return PanelRow.clip(display.id,
                                 title: body,
                                 isSecret: display.isSecret,
                                 decryptFailed: display.decryptFailed,
                                 contentKind: kind,
                                 codeLanguage: language,
                                 createdAt: display.createdAt,
                                 sourceBundle: display.sourceBundle)
        }
    }

    /// The coarse content type behind a clip row's leading glyph. Reliable signals only: the
    /// primary UTType for image/PDF/file, the color flag, and an `http(s)://` prefix on the *masked*
    /// display title for a URL — a masked secret stays `.text` (its bullets never match). No
    /// command/terminal guessing. Display-only; mirrors `displayBody`'s type switch.
    static func contentKind(for display: ClipDisplay) -> PanelRow.ContentKind {
        if display.decryptFailed { return .text }
        switch display.primaryType {
        case NSPasteboard.PasteboardType.tiff.rawValue: return .image
        case NSPasteboard.PasteboardType.pdf.rawValue: return .pdf
        case NSPasteboard.PasteboardType.fileURL.rawValue: return .file
        default:
            if display.isColorCode { return .color }
            if Self.looksLikeURL(display.displayTitle) { return .url }
            return .text
        }
    }

    /// A conservative URL test for the content-kind glyph: a leading `http://`/`https://` after trimming.
    /// Intentionally narrow — it only upgrades the glyph, so a miss just shows the text glyph (no harm).
    static func looksLikeURL(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
    }

    /// The enabled snippet folders flattened into panel rows: a non-selectable folder-header row followed
    /// by its enabled snippets. Ports `StatusMenuController.addSnippetSection`'s iteration —
    /// enabled-only, titles trimmed to the menu length — into the unified list. Folders with no enabled
    /// snippet are skipped (a lone header would not be pasteable). Titles are user-authored plaintext.
    func snippetRows() -> [PanelRow] {
        let details = (try? snippets.fetchFolderDetails()) ?? []
        let maxLength = model.settings.maxMenuItemTitleLength
        var rows: [PanelRow] = []
        for detail in details where detail.folder.isEnabled {
            let enabled = detail.snippets.filter(\.isEnabled)
            guard !enabled.isEmpty else { continue }
            rows.append(.folderHeader(detail.folder.id,
                                      title: MenuNumbering.trimTitle(detail.folder.title, maxLength: maxLength)))
            for snippet in enabled {
                rows.append(.snippet(snippet.id,
                                     title: MenuNumbering.trimTitle(snippet.title, maxLength: maxLength)))
            }
        }
        return rows
    }

    /// The user-visible body of a clip row: the masked `displayTitle` for text, the original's
    /// bracketed placeholders for non-text primaries, and a fixed marker when decryption failed. The
    /// raw `display.title` is never returned (the §9 leakage guarantee). Moved here from the NSMenu
    /// controller — the panel is now the only renderer of clip bodies.
    static func displayBody(for display: ClipDisplay) -> String {
        if display.decryptFailed {
            return String(localized: "(decryption failed)", comment: "Menu title when a clipboard item can't be decrypted")
        }
        switch display.primaryType {
        case NSPasteboard.PasteboardType.tiff.rawValue:
            return String(localized: "(Image)", comment: "Placeholder menu title for an image clip")
        case NSPasteboard.PasteboardType.pdf.rawValue:
            return String(localized: "(PDF)", comment: "Placeholder menu title for a PDF clip")
        case NSPasteboard.PasteboardType.fileURL.rawValue:
            return String(localized: "(Filenames)", comment: "Placeholder menu title for a file clip")
        default:
            return display.displayTitle
        }
    }

    /// Pastes the chosen row, routed by kind. The masked-secret AuthGate lives ONLY on the clip path
    /// (the single clip-paste route). Snippets are user-authored plaintext and paste ungated. Folder
    /// headers aren't selectable, so a stray pick is a no-op. `async` so the clip auth path is awaitable
    /// in tests; callers fire it from a Task.
    func select(_ row: PanelRow) async {
        switch row.kind {
        case .folderHeader:
            return // display-only grouping row — not pasteable
        case .snippet:
            guard case .snippet(let id) = row.id else { return }
            onSelectSnippet?(id) // plaintext — never AuthGate-gated
        case let .clip(isSecret, decryptFailed):
            guard case .clip(let id) = row.id else { return }
            guard !decryptFailed else {
                NSSound.beep() // can't paste a clip we couldn't decrypt
                return
            }
            let settings = model.settings
            let needsAuth = isSecret && settings.maskSecretsInMenu && settings.requireAuthForSecretReveal
            guard needsAuth else {
                onSelectClip?(id)
                return
            }
            let reason = String(localized: "Authenticate to paste a hidden secret.",
                                comment: "LocalAuthentication reason when pasting a masked clip")
            if await authGate.authenticate(reason) {
                onSelectClip?(id)
            } else {
                NSSound.beep() // auth declined/failed — do not expose the secret
            }
        }
    }
}
