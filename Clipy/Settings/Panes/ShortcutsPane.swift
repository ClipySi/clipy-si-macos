//
//  ShortcutsPane.swift
//  ClipySi — Apple Silicon rewrite
//
//  The Shortcuts settings pane: the four global hotkeys (main menu / history menu / snippet menu /
//  clear history), each recorded with a KeyHolder `RecordView` bridged into SwiftUI. Recording or
//  clearing a combo writes through `HotKeyStore` (the verbatim `kCPYHotKey*` keys) and posts
//  `.clipySiHotKeysChanged` so AppDelegate re-registers the Magnet hotkeys live (design §2.5 / §3.6).
//
//  Clear-history is the 4th, parity-required recorder (§6 delta 2). It ships unbound and persists as
//  true-nil when cleared (§6 delta 13). Conflicts and modifier-less combos are rejected via
//  `HotKeyValidation` — an improvement over the original's rubber-stamp `canRecordKeyCombo`.
//

import AppKit
import KeyHolder
import Magnet
import SwiftUI

struct ShortcutsPane: View {
    /// Current combos keyed by type (absent = unbound). Loaded from the store on appear and kept in
    /// sync as the user records/clears each `RecordView`.
    @State private var combos: [HotKeyType: KeyComboValue] = [:]

    private let store = HotKeyStore()

    var body: some View {
        Form {
            Section {
                recorderRow("Main menu:", .mainMenu)
                recorderRow("History menu:", .history)
                recorderRow("Snippet menu:", .snippet)
            }
            Section {
                recorderRow("Clear history:", .clearHistory)
            } footer: {
                Text("Optional — leave blank for no clear-history shortcut.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsLayout.paneWidth)
        .onAppear(perform: loadCombos)
    }

    private func recorderRow(_ label: LocalizedStringKey, _ type: HotKeyType) -> some View {
        // An explicit center-aligned HStack rather than `LabeledContent`: the latter top-aligned the
        // label against the `RecordView` (whose NSView reports no text baseline), leaving the label
        // and the shortcut field on different vertical lines in a too-tall row.
        HStack(spacing: 12) {
            Text(label)
            Spacer(minLength: 0)
            RecordViewRepresentable(
                keyCombo: combos[type],
                conflictingCombos: conflicts(excluding: type),
                onChange: { update(type, to: $0) }
            )
            .frame(width: 150, height: RecordViewRepresentable.fieldHeight)
        }
    }

    /// Combos bound to the *other* hotkeys, used to reject a duplicate binding.
    private func conflicts(excluding type: HotKeyType) -> [KeyComboValue] {
        HotKeyType.allCases.filter { $0 != type }.compactMap { combos[$0] }
    }

    private func loadCombos() {
        var loaded: [HotKeyType: KeyComboValue] = [:]
        for type in HotKeyType.allCases {
            loaded[type] = store.combo(for: type)
        }
        combos = loaded
    }

    private func update(_ type: HotKeyType, to value: KeyComboValue?) {
        if let value {
            combos[type] = value
            store.setCombo(value, for: type)
        } else {
            combos[type] = nil
            store.clearCombo(for: type)
        }
        NotificationCenter.default.post(name: .clipySiHotKeysChanged, object: nil)
    }
}

/// Bridges KeyHolder's `RecordView` into SwiftUI. Parameterized on a `(KeyComboValue?) -> Void`
/// change closure rather than a `HotKeyType`, so the same bridge also fits per-folder snippet hotkeys
/// keyed by `SnippetFolder.ID` later (design §6 delta 14). Works in `Magnet.KeyCombo` at the
/// AppKit boundary, converting to/from the persisted `KeyComboValue`.
private struct RecordViewRepresentable: NSViewRepresentable {
    let keyCombo: KeyComboValue?
    let conflictingCombos: [KeyComboValue]
    let onChange: (KeyComboValue?) -> Void

    /// Fixed control height. KeyHolder's `RecordView` reports a tall intrinsic/fitting size, which
    /// let the Form row grow and top-align the `LabeledContent` label out of line with the field;
    /// pinning the size via `sizeThatFits` keeps the row a normal control height, vertically centered.
    static let fieldHeight: CGFloat = 26

    func makeNSView(context: Context) -> RecordView {
        let view = RecordView(frame: .zero)
        view.delegate = context.coordinator
        view.keyCombo = keyCombo.flatMap(Self.keyCombo(from:))
        return view
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RecordView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 150, height: Self.fieldHeight)
    }

    func updateNSView(_ view: RecordView, context: Context) {
        context.coordinator.parent = self
        // Push the model into the view only when it differs, so we don't clobber an in-progress
        // recording or fight the delegate callback that just updated us.
        let shown = view.keyCombo.map(Self.value(from:))
        if shown != keyCombo {
            view.keyCombo = keyCombo.flatMap(Self.keyCombo(from:))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    // `nonisolated` so the (non-isolated) Coordinator can use them; pure value conversions with no
    // main-actor state.
    nonisolated static func keyCombo(from value: KeyComboValue) -> KeyCombo? {
        KeyCombo(QWERTYKeyCode: value.keyCode, carbonModifiers: value.carbonModifiers)
    }

    nonisolated static func value(from combo: KeyCombo) -> KeyComboValue {
        KeyComboValue(keyCode: combo.QWERTYKeyCode, carbonModifiers: combo.modifiers)
    }

    // KeyHolder calls `RecordViewDelegate` on the main thread, but the protocol itself is not
    // `@MainActor`; a `@MainActor` coordinator would cross isolation when conforming (Swift 6 error).
    // The coordinator only reads `parent` and calls its closure synchronously from these main-thread
    // callbacks, so a plain (non-isolated) NSObject is correct and race-free.
    final class Coordinator: NSObject, RecordViewDelegate {
        var parent: RecordViewRepresentable

        init(parent: RecordViewRepresentable) { self.parent = parent }

        func recordViewShouldBeginRecording(_ recordView: RecordView) -> Bool { true }

        func recordView(_ recordView: RecordView, canRecordKeyCombo keyCombo: KeyCombo) -> Bool {
            // Reject double-tap-modifier combos: `KeyComboValue` stores only keyCode + carbon
            // modifiers, so a doubled combo (QWERTYKeyCode 0) would round-trip into a literal ⌘A.
            // The original could persist them (NSCoding); the rewrite doesn't support them.
            guard !keyCombo.doubledModifiers else { return false }
            return HotKeyValidation.canRecord(RecordViewRepresentable.value(from: keyCombo),
                                              boundElsewhere: parent.conflictingCombos)
        }

        func recordView(_ recordView: RecordView, didChangeKeyCombo keyCombo: KeyCombo?) {
            parent.onChange(keyCombo.map(RecordViewRepresentable.value(from:)))
        }

        func recordViewDidEndRecording(_ recordView: RecordView) {}
    }
}
