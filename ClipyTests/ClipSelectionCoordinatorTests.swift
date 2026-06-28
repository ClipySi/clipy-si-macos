//
//  ClipSelectionCoordinatorTests.swift
//  ClipyTests
//
//  The history FloatingPanel's selection logic: builds rows from the decrypted history and applies the
//  masked-secret auth gate before pasting (history-panel design §1.3 / §3.4). Pure model logic — no
//  window — so it runs headlessly with an in-memory DB + fixed cipher, mirroring StatusMenuControllerTests.
//

import AppKit
import CryptoKit
import Foundation
import SQLiteData
import Testing
@testable import Clipy

@MainActor
@Suite struct ClipSelectionCoordinatorTests {
    private static let key = SymmetricKey(data: Data(repeating: 0x5C, count: 32))
    private var cipher: HistoryCipher { HistoryCipher(key: Self.key) }

    /// Captures the clip id passed to `onSelectClip` (a reference box so the escaping callback can write it).
    private final class Captured { var id: Clip.ID? }
    private final class CapturedSnippet { var id: Snippet.ID? }

    private func makeDefaults(mask: Bool = true, requireAuth: Bool = false) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "ClipySiCoordinator-\(UUID().uuidString)")!
        DefaultsKeys.registerDefaults(in: defaults)
        defaults.set(mask, forKey: DefaultsKeys.maskSecretsInMenu)
        defaults.set(requireAuth, forKey: DefaultsKeys.requireAuthForSecretReveal)
        return defaults
    }

    private func makeCoordinator(defaults: UserDefaults, authGate: AuthGate) -> ClipSelectionCoordinator {
        ClipSelectionCoordinator(model: MenuModel(settings: AppSettings(defaults: defaults)), authGate: authGate)
    }

    private func row(secret: Bool = false, decryptFailed: Bool = false) -> PanelRow {
        .clip(UUID(), title: "x", isSecret: secret, decryptFailed: decryptFailed)
    }
    private func snippetRow() -> PanelRow { .snippet(UUID(), title: "snip") }
    private func headerRow() -> PanelRow { .folderHeader(UUID(), title: "Folder") }

    // MARK: - historyRows

    @Test func historyRowsAreNewestFirstAndDecrypted() throws {
        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
            $0.historyCipher = cipher
            $0.maskingService = .identity // deterministic: displayTitle == title, no secret detection
        } operation: {
            let repo = ClipRepository()
            for (index, title) in ["a", "b", "c"].enumerated() {
                var clip = Make.clip(createdAt: Make.epoch.addingTimeInterval(Double(index)))
                clip.titleCipher = try cipher.seal(Data(title.utf8))
                try repo.add(clip)
            }
            let rows = makeCoordinator(defaults: makeDefaults(), authGate: .allow).historyRows()
            #expect(rows.map(\.title) == ["c", "b", "a"]) // newest-first (reorder default → desc)
            #expect(rows.allSatisfy { !$0.decryptFailed })
        }
    }

    /// Security canary (relocated from StatusMenuControllerTests when clip rendering moved to
    /// the panel): a masked secret's row title shows bullets, never the decrypted plaintext. The raw
    /// `ClipDisplay.title` must not leak into the panel row (history-panel design §9). Synthetic
    /// sentinel only — never a real copied secret.
    @Test func historyRowMasksSecretShowingBulletsNotPlaintext() throws {
        let secret = "ghp_secrettoken000000000000000000000000"
        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
            $0.historyCipher = cipher
            // Stub the core: mask anything containing "ghp_" so the row-build path is exercised.
            $0.maskingService = MaskingService { text in
                text.contains("ghp_") ? MaskingResult(isSecret: true, display: "••••••")
                                       : MaskingResult(isSecret: false, display: text)
            }
        } operation: {
            var clip = Make.clip(createdAt: Make.epoch)
            clip.titleCipher = try cipher.seal(Data(secret.utf8))
            try ClipRepository().add(clip)

            let rows = makeCoordinator(defaults: makeDefaults(mask: true), authGate: .allow).historyRows()
            let row = try #require(rows.first)
            #expect(row.title.contains("•"))      // shown masked
            #expect(!row.title.contains("ghp_"))  // the plaintext secret must never appear
            #expect(row.isSecret)                 // detected, so the paste gate applies
        }
    }

    /// `displayBody` maps non-text primaries to the original's bracketed placeholders and a failed
    /// decrypt to a fixed marker, never exposing the raw title. (Moved here from the NSMenu controller;
    /// this restores the placeholder-branch coverage that the deleted menu tests held.)
    @Test func displayBodyMapsNonTextAndFailureToPlaceholders() {
        func display(_ primaryType: String, decryptFailed: Bool = false, displayTitle: String = "raw") -> ClipDisplay {
            ClipDisplay(id: UUID(), title: "raw", primaryType: primaryType, isColorCode: false,
                        decryptFailed: decryptFailed, displayTitle: displayTitle)
        }
        let tiff = NSPasteboard.PasteboardType.tiff.rawValue
        let pdf = NSPasteboard.PasteboardType.pdf.rawValue
        let fileURL = NSPasteboard.PasteboardType.fileURL.rawValue
        let string = NSPasteboard.PasteboardType.string.rawValue
        #expect(ClipSelectionCoordinator.displayBody(for: display(tiff)) == "(Image)")
        #expect(ClipSelectionCoordinator.displayBody(for: display(pdf)) == "(PDF)")
        #expect(ClipSelectionCoordinator.displayBody(for: display(fileURL)) == "(Filenames)")
        // Text passes through as the masked displayTitle (never the raw `title`).
        #expect(ClipSelectionCoordinator.displayBody(for: display(string, displayTitle: "hello")) == "hello")
        #expect(ClipSelectionCoordinator.displayBody(for: display(string, decryptFailed: true)).contains("decryption failed"))
    }

    /// The content-kind glyph classifier: primary UTType drives image/PDF/file; the color flag
    /// → color; an `http(s)://` prefix on the (masked) display title → url; everything else → text. A
    /// failed decrypt and a masked secret both stay `.text` (no glyph leaks type, no bullets match a URL).
    @Test func contentKindClassifiesByTypeColorAndURL() {
        func display(_ primaryType: String, isColorCode: Bool = false, decryptFailed: Bool = false,
                     displayTitle: String = "raw") -> ClipDisplay {
            ClipDisplay(id: UUID(), title: "raw", primaryType: primaryType, isColorCode: isColorCode,
                        decryptFailed: decryptFailed, displayTitle: displayTitle)
        }
        let tiff = NSPasteboard.PasteboardType.tiff.rawValue
        let pdf = NSPasteboard.PasteboardType.pdf.rawValue
        let fileURL = NSPasteboard.PasteboardType.fileURL.rawValue
        let string = NSPasteboard.PasteboardType.string.rawValue
        let kind = ClipSelectionCoordinator.contentKind(for:)
        #expect(kind(display(tiff)) == .image)
        #expect(kind(display(pdf)) == .pdf)
        #expect(kind(display(fileURL)) == .file)
        #expect(kind(display(string, isColorCode: true)) == .color)
        #expect(kind(display(string, displayTitle: "https://example.com")) == .url)
        #expect(kind(display(string, displayTitle: "  http://x.test ")) == .url) // trimmed prefix
        #expect(kind(display(string, displayTitle: "hello world")) == .text)
        #expect(kind(display(string, displayTitle: "ftp://nope")) == .text)      // only http(s)
        #expect(kind(display(string, displayTitle: "••••••")) == .text)          // masked secret ≠ url
        #expect(kind(display(tiff, decryptFailed: true)) == .text)               // failure overrides type
    }

    // MARK: - select (auth gate)

    @Test func selectNonSecretPastesImmediately() async {
        let coordinator = makeCoordinator(
            defaults: makeDefaults(),
            authGate: AuthGate { _ in Issue.record("must not authenticate a non-secret"); return false })
        let captured = Captured()
        coordinator.onSelectClip = { captured.id = $0 }
        let chosen = row(secret: false)
        await coordinator.select(chosen)
        if case .clip(let id) = chosen.id { #expect(captured.id == id) }
    }

    @Test func selectMaskedSecretIsGatedOnAuthentication() async {
        let secret = row(secret: true)

        // Auth required + denied → not pasted.
        let denied = makeCoordinator(defaults: makeDefaults(mask: true, requireAuth: true),
                                     authGate: AuthGate { _ in false })
        let deniedCapture = Captured()
        denied.onSelectClip = { deniedCapture.id = $0 }
        await denied.select(secret)
        #expect(deniedCapture.id == nil)

        // Auth required + allowed → pasted.
        let allowed = makeCoordinator(defaults: makeDefaults(mask: true, requireAuth: true), authGate: .allow)
        let allowedCapture = Captured()
        allowed.onSelectClip = { allowedCapture.id = $0 }
        await allowed.select(secret)
        if case .clip(let id) = secret.id { #expect(allowedCapture.id == id) }
    }

    @Test func selectSecretPastesImmediatelyWhenAuthNotRequired() async {
        // require-auth OFF → even a detected secret pastes without a gate (matches StatusMenuController).
        let coordinator = makeCoordinator(
            defaults: makeDefaults(mask: true, requireAuth: false),
            authGate: AuthGate { _ in Issue.record("must not authenticate when require-auth is off"); return false })
        let captured = Captured()
        coordinator.onSelectClip = { captured.id = $0 }
        let secret = row(secret: true)
        await coordinator.select(secret)
        if case .clip(let id) = secret.id { #expect(captured.id == id) }
    }

    @Test func selectDoesNotPasteAnUndecryptableRow() async {
        let coordinator = makeCoordinator(defaults: makeDefaults(), authGate: .allow)
        let captured = Captured()
        coordinator.onSelectClip = { captured.id = $0 }
        await coordinator.select(row(decryptFailed: true))
        #expect(captured.id == nil)
    }

    // MARK: - snippet selection — never hits the masked-secret AuthGate

    @Test func selectSnippetRoutesToSnippetCallbackUngated() async {
        // Even with mask + require-auth ON, a snippet pastes via onSelectSnippet and NEVER the AuthGate
        // or the clip path (snippets are user-authored plaintext, not detected secrets).
        let coordinator = makeCoordinator(
            defaults: makeDefaults(mask: true, requireAuth: true),
            authGate: AuthGate { _ in Issue.record("snippets must never hit the AuthGate"); return false })
        let clip = Captured(); let snip = CapturedSnippet()
        coordinator.onSelectClip = { clip.id = $0 }
        coordinator.onSelectSnippet = { snip.id = $0 }
        let snippet = snippetRow()
        await coordinator.select(snippet)
        if case .snippet(let id) = snippet.id { #expect(snip.id == id) }
        #expect(clip.id == nil) // the clip path was not taken
    }

    @Test func selectFolderHeaderIsANoOp() async {
        let coordinator = makeCoordinator(defaults: makeDefaults(), authGate: .allow)
        let clip = Captured(); let snip = CapturedSnippet()
        coordinator.onSelectClip = { clip.id = $0 }
        coordinator.onSelectSnippet = { snip.id = $0 }
        await coordinator.select(headerRow())
        #expect(clip.id == nil)
        #expect(snip.id == nil)
    }

    // MARK: - snippetRows (flatten folders → rows)

    @Test func snippetRowsFlattenEnabledFoldersAndSkipEmptyOrDisabled() throws {
        try withDependencies {
            $0.defaultDatabase = try TestDatabase.make()
            $0.historyCipher = cipher
        } operation: {
            let repo = SnippetRepository()
            let greetings = try repo.insertFolder(title: "Greetings")
            let hello = try repo.insertSnippet(folderID: greetings.id, title: "Hello", content: "hi")
            let secret = try repo.insertSnippet(folderID: greetings.id, title: "Secret", content: "x")
            try repo.setSnippetEnabled(false, id: secret.id) // disabled snippet hidden
            let off = try repo.insertFolder(title: "Disabled")
            try repo.setFolderEnabled(false, id: off.id)     // disabled folder hidden
            _ = try repo.insertFolder(title: "Empty")        // enabled folder, no enabled snippets → skipped

            let rows = makeCoordinator(defaults: makeDefaults(), authGate: .allow).snippetRows()
            #expect(rows.map(\.title) == ["Greetings", "Hello"]) // header + its one enabled snippet only
            #expect(rows.first?.isSelectable == false)           // folder header: not selectable
            #expect(rows.last?.isSelectable == true)             // snippet: selectable
            if case .snippet(let id) = rows.last?.id { #expect(id == hello.id) }
        }
    }
}
