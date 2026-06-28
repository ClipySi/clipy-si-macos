//
//  PanelSearchField.swift
//  ClipySi — Apple Silicon rewrite
//
//  A borderless NSTextField wrapped for the unified panel's search field. It does two things a plain
//  SwiftUI TextField cannot inside a non-activating NSPanel:
//
//   1. IME safety. Return / Esc / ↓ / → are routed through the field editor's `doCommandBySelector`,
//      gated on `hasMarkedText()` — so a key pressed while composing (Japanese conversion) is left to the
//      IME and only acts on already-committed text. (A SwiftUI `.onKeyPress(.return)` saw the raw
//      conversion-confirm Return and pasted + closed mid-composition.)
//
//   2. Programmatic focus. The list's ↑/⌘↑ need to move the caret INTO the search field; SwiftUI's
//      `@FocusState`→field-editor bridge doesn't reliably do that in a non-activating panel. So focus is
//      DECOUPLED from `@FocusState`: this field is NOT bound with `.focused(...)`. Instead `updateNSView`
//      issues `window.makeFirstResponder` whenever `isFocused` (focus == .search) is true, and
//      `becomeFirstResponder` reports a click back so `@FocusState` follows. Two guarded one-directional
//      writes — no `.focused` on the field means no fight with SwiftUI's focus engine (which is what made
//      an earlier `.focused`-bound version un-focusable).
//
//  AppKit-bound → the Coordinator is `@MainActor` (mirrors SnippetEditorView.PlainTextEditor).
//

import AppKit
import SwiftUI

// A ⌘-modified arrow pressed while the search field is focused. The panel uses these as GLOBAL focus
// shortcuts (⌘↑ search, ⌘↓ list, ⌘←/⌘→ scope), so they are intercepted in `performKeyEquivalent` before
// the field editor would treat ⌘←/⌘→ as line-start/line-end. (`up` is intentionally 2 chars — it mirrors
// the arrow key, which reads clearer than padding the name out.)
// swiftlint:disable:next identifier_name
enum PanelArrowDirection { case up, down, left, right }

/// A handle the view keeps so the list's ↑/⌘↑ can focus the search field DIRECTLY (a synchronous AppKit
/// `makeFirstResponder` from the keypress handler — i.e. exactly what a click does, which works), rather
/// than via `updateNSView` during a SwiftUI update (which the focus engine was clobbering).
@MainActor
final class SearchFieldHandle {
    weak var field: NSTextField?

    func focus() {
        guard let field, let window = field.window else { return }
        window.makeFirstResponder(field)
    }
}

struct PanelSearchField: NSViewRepresentable {
    @Binding var text: String
    /// Captured so the list can focus the field directly (see `SearchFieldHandle`).
    let handle: SearchFieldHandle
    /// Grey placeholder shown when the field is empty (a localized "Search"). `nil` = no
    /// placeholder (the magnifier glyph alone). Static per open; applied in make/update.
    var placeholder: String?
    /// Mirrors `focus == .search` (a plain read of @FocusState). When true and the field isn't first
    /// responder, `updateNSView` claims it — the AppKit hop SwiftUI drops in the non-activating panel.
    var isFocused: Bool
    /// The field became first responder (click OR our makeFirstResponder) — sync @FocusState to `.search`.
    var onFocusBegan: () -> Void
    /// The field stopped editing (lost first responder). Drives the focus ring — `.search` is unbound in
    /// `@FocusState` (the field is decoupled), so a dedicated focused flag, not `focus == .search`, is the
    /// reliable signal. Defaults to a no-op so previews/tests don't need it.
    var onFocusEnded: () -> Void = {}
    /// Return on committed (non-IME) text → paste. Returns true to consume.
    var onReturn: () -> Bool
    /// Esc on committed text → dismiss. Returns true to consume.
    var onCancel: () -> Bool
    /// ↓ on committed text → move focus down out of the field (to the scope tabs). Returns true to consume.
    var onDown: () -> Bool
    /// A ⌘-modified arrow (global focus shortcut: ⌘↑ search / ⌘↓ list / ⌘←/⌘→ scope). Returns true to consume.
    var onCommandArrow: (PanelArrowDirection) -> Bool
    /// ⌘-modified single char (⌘1/2/3 scope, ⌘M management). Handled in `performKeyEquivalent` because
    /// SwiftUI `.onKeyPress` is unreliable over an embedded NSView. Returns true to consume.
    var onCommandKey: (Character) -> Bool
    /// ⌘↵ (Cmd+Return) → paste the top/selected result. Works regardless of IME state (a bare Return is
    /// consumed by an active composition), and is surfaced as the "⌘↵" hint. Returns true to consume.
    var onCommandReturn: () -> Bool

    func makeNSView(context: Context) -> PanelNSTextField {
        let field = PanelNSTextField()
        handle.field = field
        field.delegate = context.coordinator
        field.onFocusBegan = { context.coordinator.parent.onFocusBegan() }
        field.onCommandKey = { context.coordinator.parent.onCommandKey($0) }
        field.onCommandReturn = { context.coordinator.parent.onCommandReturn() }
        field.onCommandArrow = { context.coordinator.parent.onCommandArrow($0) }
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        // Semantic body font so the field tracks system text sizing like the SwiftUI styles around
        // it. Inside the panel's popover material the field inherits the VIBRANT
        // appearance variant — accepted as-is (review): it is exactly how search fields inside
        // system popovers render, which is the look this surface adopts.
        field.font = NSFont.preferredFont(forTextStyle: .body)
        field.placeholderString = placeholder
        field.usesSingleLineMode = true
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.stringValue = text
        // An NSTextField uses its (small) intrinsic width unless told to stretch — without this it
        // collapses to a near-zero-width sliver in the HStack and there's nothing to click/focus.
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: PanelNSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
        guard let window = field.window else { return }
        let isFirstResponder = field.currentEditor() != nil && window.firstResponder === field.currentEditor()
        if isFocused, !isFirstResponder {
            window.makeFirstResponder(field) // SwiftUI .search → AppKit first responder (no app activation)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PanelSearchField

        init(_ parent: PanelSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        // Editing ended (field resigned first responder, or Return committed) — clear the focus ring.
        func controlTextDidEndEditing(_ notification: Notification) {
            parent.onFocusEnded()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // While composing (IME marked text), never hijack the key — let the field editor convert/commit.
            guard !textView.hasMarkedText() else { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                return parent.onReturn()
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.onCancel()
            case #selector(NSResponder.moveDown(_:)):
                return parent.onDown()
            default:
                return false
            }
        }
    }
}

/// An NSTextField that reports when it becomes first responder (so a click syncs @FocusState) and handles
/// the panel's ⌘ shortcuts before the field editor (so ⌘1/2/3 / ⌘M work while the field is focused).
final class PanelNSTextField: NSTextField {
    var onFocusBegan: (() -> Void)?
    var onCommandKey: ((Character) -> Bool)?
    var onCommandReturn: (() -> Bool)?
    var onCommandArrow: ((PanelArrowDirection) -> Bool)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusBegan?() }
        return became
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // `performKeyEquivalent` is sent down the whole view tree, not just to the first responder — so
        // guard on `currentEditor() != nil` (true only while THIS field is the focused one) to avoid
        // double-firing the shortcuts alongside the list's own handlers.
        guard currentEditor() != nil, event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        if event.keyCode == 36, onCommandReturn?() == true { // 36 = Return → ⌘↵ pastes
            return true
        }
        // ⌘-arrows are global focus shortcuts — intercept BEFORE the single-char branch below (an arrow's
        // `charactersIgnoringModifiers` is a 1-char function key that would otherwise hit `onCommandKey`).
        if let direction = Self.arrowDirection(forKeyCode: event.keyCode), onCommandArrow?(direction) == true {
            return true
        }
        if let characters = event.charactersIgnoringModifiers, characters.count == 1,
           onCommandKey?(Character(characters)) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Maps the macOS arrow virtual key codes to a direction (left 123 / right 124 / down 125 / up 126).
    private static func arrowDirection(forKeyCode keyCode: UInt16) -> PanelArrowDirection? {
        switch keyCode {
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        default: return nil
        }
    }
}
