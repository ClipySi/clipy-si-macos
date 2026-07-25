//
//  PasteService.swift
//  ClipySi — Apple Silicon rewrite
//
//  Restores a selected clip to the pasteboard and synthesizes ⌘V (CGEvent) into the frontmost app.
//  AppKit/CGEvent bound → `@MainActor`. Ports the original PasteService, with the security ordering
//  fixed per the design §6.1/§12.B: the Accessibility + R5 gates run BEFORE the pasteboard write,
//  so an aborted auto-paste never leaves the decrypted clip on the public pasteboard. After writing
//  we call `markSeen()` so our own write isn't re-captured as a copy (PasteboardMonitor self-write
//  suppression). All captured UTType representations are restored, not just the primary.
//

import AppKit
import OSLog
import Sauce
import SQLiteData // re-exports swift-dependencies (@Dependency)

@MainActor
final class PasteService {
    /// One UTType representation to place on the pasteboard.
    struct Payload: Equatable { let type: String; let data: Data }

    /// The beta modifier behaviors (original: pastePlainText / deleteHistory / pasteAndDeleteHistory).
    enum BetaAction: Equatable { case normal, plainText, delete, pasteAndDelete }

    enum PasteError: Error { case clipNotFound, snippetNotFound }

    @Dependency(\.date) private var date

    private let clips = ClipRepository()
    private let snippets = SnippetRepository()
    private let blobStore: EncryptedBlobStore
    private let settings: AppSettings
    private let accessibility: AccessibilityService
    private let frontmost: FrontmostAppGuard
    private let markSeen: @MainActor () -> Void

    /// The frontmost target captured at menu-open (R5), re-checked before posting ⌘V.
    private var frontmostAtOpen: String?

    private static let log = Logger(subsystem: "io.github.ponponusa.clipysi", category: "paste")

    init(blobStore: EncryptedBlobStore,
         settings: AppSettings = AppSettings(),
         accessibility: AccessibilityService = AccessibilityService(),
         frontmost: FrontmostAppGuard = FrontmostAppGuard(),
         markSeen: @escaping @MainActor () -> Void) {
        self.blobStore = blobStore
        self.settings = settings
        self.accessibility = accessibility
        self.frontmost = frontmost
        self.markSeen = markSeen
    }

    /// Snapshot the target app when a menu opens (R5). Wired to the menu controller's open event.
    func captureFrontmost() {
        frontmostAtOpen = frontmost.snapshot()
    }

    // MARK: - Selection → paste

    func paste(clipID: Clip.ID) {
        let action = betaAction(modifiers: NSEvent.modifierFlags)

        if action == .delete {
            deleteClip(clipID) // remove + GC blobs, no paste
            return
        }

        let payloads: [Payload]
        do {
            payloads = try pasteboardPayload(forClipID: clipID, plainTextOnly: action == .plainText)
        } catch {
            NSSound.beep()
            Self.log.error("paste payload unavailable: \(error.localizedDescription, privacy: .public)")
            return
        }

        // The history effects (delete / move-to-top) only run if the paste actually went through
        // (a gate abort must not silently destroy or reorder history).
        if writeAndPaste(payloads) {
            applyHistoryEffect(clipID: clipID, action: action)
        }
    }

    /// Pastes a snippet's plaintext content. The same Accessibility + R5 gates apply as for a clip
    /// (design §6 delta 3). `Snippet.content` is plaintext (not a cipher BLOB) — no decryption.
    func paste(snippetID: Snippet.ID) {
        let payloads: [Payload]
        do {
            payloads = try snippetPayload(forSnippetID: snippetID)
        } catch {
            NSSound.beep()
            Self.log.error("snippet payload unavailable: \(error.localizedDescription, privacy: .public)")
            return
        }
        writeAndPaste(payloads)
    }

    /// The shared paste tail: gate (Accessibility + R5) BEFORE the pasteboard write (§12.B — an
    /// aborted auto-paste must not leave the payload on the public pasteboard), write, suppress
    /// self-capture, then synthesize ⌘V. Returns whether the paste proceeded.
    @discardableResult
    private func writeAndPaste(_ payloads: [Payload]) -> Bool {
        let autoPaste = settings.inputPasteCommand
        if autoPaste {
            guard accessibility.isTrusted(prompt: false) else {
                accessibility.showDeniedAlert()
                return false
            }
            guard frontmost.stillMatches(frontmostAtOpen) else {
                NSSound.beep() // focus changed since the menu opened — don't paste into the wrong app
                return false
            }
        }

        writeToPasteboard(payloads)
        markSeen() // suppress self-capture of the write we just made

        if autoPaste {
            postPasteCommand()
        }
        return true
    }

    // MARK: - History Manager actions

    /// Copy a clip's representations to the pasteboard WITHOUT pasting — no Accessibility/R5 gate and
    /// no ⌘V. Used by the read-only History Manager (copy-only). `markSeen()` keeps our own write from
    /// being re-captured as a new copy, so copying never reorders/duplicates history.
    func copyOnly(clipID: Clip.ID) {
        do {
            let payloads = try pasteboardPayload(forClipID: clipID, plainTextOnly: false)
            writeToPasteboard(payloads)
            markSeen()
        } catch {
            NSSound.beep()
            Self.log.error("copy unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Delete a single clip and GC its blobs (History Manager row delete) — same path as the
    /// paste-and-delete beta action, so blob cleanup stays in one place.
    func delete(clipID: Clip.ID) {
        deleteClip(clipID)
    }

    /// Delete all history and GC every blob (History Manager "Clear All").
    func deleteAll() {
        do {
            for path in try clips.deleteAll() { try? blobStore.delete(id: path) }
        } catch {
            Self.log.error("clear-all failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Testable core

    /// Maps the live modifier flags + beta settings to an action (priority: delete > paste-and-delete
    /// > plain-text > normal), mirroring the original's three beta toggles.
    func betaAction(modifiers: NSEvent.ModifierFlags) -> BetaAction {
        if settings.deleteHistory, pressed(settings.deleteHistoryModifier, modifiers) { return .delete }
        if settings.pasteAndDeleteHistory, pressed(settings.pasteAndDeleteHistoryModifier, modifiers) {
            return .pasteAndDelete
        }
        if settings.pastePlainText, pressed(settings.pastePlainTextModifier, modifiers) { return .plainText }
        return .normal
    }

    /// What a **successful** paste does to the history row it came from: `.pasteAndDelete` removes it,
    /// otherwise `moveClipToTopOnPaste` (default ON) moves it back to the top so the history reads
    /// most-recently-used first. Split out of `paste(clipID:)` — which writes the real pasteboard and
    /// synthesizes ⌘V — so the decision is unit-testable.
    ///
    /// Off ⇒ the clip stays where it is, the original Clipy behaviour. Note this bumps `createdAt`
    /// (the history's order key) and `updatedAt`, so the reorder is a normal modification for sync,
    /// exactly like a re-copy under `overwriteSameHistory` (design §3.1).
    func applyHistoryEffect(clipID: Clip.ID, action: BetaAction) {
        switch action {
        case .pasteAndDelete:
            deleteClip(clipID)
        case .normal, .plainText:
            guard settings.moveClipToTopOnPaste else { return }
            do {
                try clips.moveToTop(id: clipID, date: date.now)
            } catch {
                Self.log.error("move-to-top after paste failed: \(error.localizedDescription, privacy: .public)")
            }
        case .delete:
            break // handled before the paste — the clip is already gone
        }
    }

    /// The representations to restore: every captured UTType (primary + secondaries), or just the
    /// plain-text string when `plainTextOnly`. Decrypts each blob.
    func pasteboardPayload(forClipID id: Clip.ID, plainTextOnly: Bool) throws -> [Payload] {
        guard let clip = try clips.clip(id: id) else { throw PasteError.clipNotFound }
        let stringType = NSPasteboard.PasteboardType.string.rawValue

        if plainTextOnly {
            if clip.primaryType == stringType {
                return [Payload(type: stringType, data: try blobStore.read(id: clip.dataPath))]
            }
            if let stringRep = try clips.representations(forClipID: id).first(where: { $0.uttype == stringType }) {
                return [Payload(type: stringType, data: try blobStore.read(id: stringRep.dataPath))]
            }
            return [Payload(type: clip.primaryType, data: try blobStore.read(id: clip.dataPath))] // no string rep
        }

        var payloads = [Payload(type: clip.primaryType, data: try blobStore.read(id: clip.dataPath))]
        for representation in try clips.representations(forClipID: id) {
            if let data = try? blobStore.read(id: representation.dataPath) {
                payloads.append(Payload(type: representation.uttype, data: data))
            }
        }
        return payloads
    }

    /// The single plain-text payload for a snippet (its `content`). Throws if the snippet is gone.
    func snippetPayload(forSnippetID id: Snippet.ID) throws -> [Payload] {
        guard let snippet = try snippets.snippet(id: id) else { throw PasteError.snippetNotFound }
        let stringType = NSPasteboard.PasteboardType.string.rawValue
        return [Payload(type: stringType, data: Data(snippet.content.utf8))]
    }

    // MARK: - Private

    private func pressed(_ flag: Int, _ modifiers: NSEvent.ModifierFlags) -> Bool {
        switch flag {
        case 0: return modifiers.contains(.command)
        case 1: return modifiers.contains(.shift)
        case 2: return modifiers.contains(.control)
        case 3: return modifiers.contains(.option)
        default: return false
        }
    }

    private func writeToPasteboard(_ payloads: [Payload]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes(payloads.map { NSPasteboard.PasteboardType($0.type) }, owner: nil)
        for payload in payloads {
            pasteboard.setData(payload.data, forType: NSPasteboard.PasteboardType(payload.type))
        }
    }

    private func deleteClip(_ id: Clip.ID) {
        do {
            for path in try clips.delete(id: id) { try? blobStore.delete(id: path) }
        } catch {
            Self.log.error("delete-on-paste failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func postPasteCommand() {
        let vKey = Sauce.shared.keyCode(for: .v, cocoaModifiers: .command)
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            Self.log.error("no CGEventSource; cannot synthesize ⌘V")
            return
        }
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
