//
//  PanelManagement.swift
//  ClipySi — Apple Silicon rewrite
//
//  The management overlay shown over the unified FloatingPanel: a small rounded card with
//  the six app actions that used to live in the NSMenu's "Manage" submenu — Edit Snippets / History /
//  Settings / About / Clear History / Quit. It is neither an NSMenu nor a window; it's a SwiftUI scrim +
//  card inside the panel, so the panel stays a single surface. Opened by the gear button or ⌘M; Esc (or
//  a scrim click) closes only the overlay, leaving the panel up. Each action carries a single-letter
//  mnemonic (E/H/S/A/C/Q). Pure SwiftUI → no AppKit here; side effects are injected via `PanelActions`.
//

import SwiftUI

/// The closures the overlay invokes. The controller builds these so each one first hides the panel
/// (window-opening actions must not appear behind the floating panel) before running the app action.
/// `clearHistory` and `quit` are likewise routed through the controller. Empty defaults make previews
/// and the no-op initial wiring safe.
struct PanelActions {
    var editSnippets: () -> Void = {}
    var openHistory: () -> Void = {}
    var openSettings: () -> Void = {}
    var openAbout: () -> Void = {}
    var clearHistory: () -> Void = {}
    var quit: () -> Void = {}
}

/// One management action. Order, glyph, title, and the keyboard mnemonic live here so the card and the
/// key handling stay in sync.
enum ManagementAction: CaseIterable, Hashable {
    case editSnippets, history, settings, about, clearHistory, quit

    /// The lowercase keyboard mnemonic (also shown, uppercased, at the trailing edge of the row).
    var mnemonic: Character {
        switch self {
        case .editSnippets: return "e"
        case .history: return "h"
        case .settings: return "s"
        case .about: return "a"
        case .clearHistory: return "c"
        case .quit: return "q"
        }
    }

    var mnemonicLabel: String { String(mnemonic).uppercased() }

    var glyph: String {
        switch self {
        case .editSnippets: return "note.text"
        case .history: return "clock"
        case .settings: return "gearshape"
        case .about: return "info.circle"
        case .clearHistory: return "trash"
        case .quit: return "power"
        }
    }

    var title: Text {
        switch self {
        case .editSnippets: return Text("Edit Snippets", comment: "Panel management: open the snippet editor")
        case .history: return Text("History…", comment: "Panel management: open the history manager")
        case .settings: return Text("Settings…", comment: "Panel management: open Settings")
        case .about: return Text("About ClipySi", comment: "Panel management: open the About window")
        case .clearHistory: return Text("Clear History", comment: "Panel management: clear all clipboard history")
        case .quit: return Text("Quit ClipySi", comment: "Panel management: quit the app")
        }
    }
}

/// A scrim + a top-trailing card of the six management actions. Self-contained focus: it grabs key
/// focus on appear so ↑/↓ move the highlight, Return runs it, a mnemonic letter runs that action, and
/// Esc closes the overlay (handled here, so it never reaches the panel's own Esc → the panel stays).
struct ManagementOverlay: View {
    let actions: PanelActions
    /// Clear History is drawn but disabled (and skipped by nav/mnemonic) when there is no history.
    let historyEmpty: Bool
    /// Close just the overlay (Esc / scrim click / after an action that doesn't hide the panel).
    let onClose: () -> Void

    @FocusState private var focused: Bool
    @State private var selection: ManagementAction = .editSnippets

    /// Actions reachable by keyboard nav — Clear History drops out while disabled.
    private var navigable: [ManagementAction] {
        ManagementAction.allCases.filter { isEnabled($0) }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Scrim: dims the list and swallows clicks; a click closes only the overlay (panel stays).
            Rectangle()
                .fill(.black.opacity(0.14))
                .contentShape(Rectangle())
                .onTapGesture { onClose() }
            card
                .padding(.top, 4)
                .padding(.trailing, 8)
        }
        // Esc anywhere in the overlay closes the overlay (not the panel).
        .onKeyPress(.escape) { onClose(); return .handled }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 1) {
            row(.editSnippets)
            row(.history)
            Divider().padding(.vertical, 3)
            row(.settings)
            row(.about)
            Divider().padding(.vertical, 3)
            row(.clearHistory)
            row(.quit)
        }
        .padding(6)
        .frame(width: 232)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 14, y: 4)
        .focusable()
        .focusEffectDisabled() // no system focus ring around the card (the "weird frame")
        .focused($focused)
        .onAppear {
            selection = navigable.first ?? .editSnippets
            focused = true
        }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.return) { run(selection); return .handled }
        .onKeyPress(characters: .letters) { press in
            guard let action = ManagementAction.allCases.first(where: {
                String($0.mnemonic) == press.characters.lowercased()
            }), isEnabled(action) else { return .ignored }
            run(action)
            return .handled
        }
    }

    private func row(_ action: ManagementAction) -> some View {
        let enabled = isEnabled(action)
        let highlighted = enabled && action == selection
        return HStack(spacing: 8) {
            Image(systemName: action.glyph).frame(width: 16)
            action.title.lineLimit(1)
            Spacer(minLength: 8)
            Text(verbatim: action.mnemonicLabel)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlighted ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { if $0, enabled { selection = action } }
        .onTapGesture { if enabled { run(action) } }
    }

    private func isEnabled(_ action: ManagementAction) -> Bool {
        action != .clearHistory || !historyEmpty
    }

    /// Move the highlight by `delta` within the enabled actions, wrapping at the ends.
    private func move(_ delta: Int) {
        let items = navigable
        guard !items.isEmpty else { return }
        let index = items.firstIndex(of: selection) ?? 0
        selection = items[(index + delta + items.count) % items.count]
    }

    private func run(_ action: ManagementAction) {
        switch action {
        case .editSnippets: actions.editSnippets()
        case .history: actions.openHistory()
        case .settings: actions.openSettings()
        case .about: actions.openAbout()
        case .clearHistory: actions.clearHistory()
        case .quit: actions.quit()
        }
    }
}
