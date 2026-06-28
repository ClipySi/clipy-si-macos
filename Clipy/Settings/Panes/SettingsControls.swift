//
//  SettingsControls.swift
//  ClipySi — Apple Silicon rewrite
//
//  Small reusable controls shared by the Settings panes: a labeled integer field + stepper with a
//  trailing unit, and the beta modifier-key popup. Kept here so the Menu/Updates/Beta panes don't
//  repeat the layout.
//

import SwiftUI

/// Shared layout constants so every Settings pane is the same width (no width jump when switching
/// tabs) and the hosting window is sized to fit them. See `AppDelegate.openSettings`.
enum SettingsLayout {
    /// Uniform content width for every pane.
    static let paneWidth: CGFloat = 480
    /// Settings window content size — pane width plus side margins, tall enough for the densest
    /// pane (Menu).
    static let windowContentSize = CGSize(width: paneWidth + 40, height: 600)
}

/// A labeled integer field + stepper with a trailing unit suffix. After a free-form text edit the
/// value is re-clamped to `range` (both bounds): the Stepper bounds only its own +/- buttons, so a
/// number typed into the TextField could otherwise land outside `range`. See `SettingsMapping`.
struct IntFieldRow: View {
    let title: LocalizedStringKey
    let unit: LocalizedStringKey
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("", value: $value, format: .number)
                    .labelsHidden()
                    .frame(width: 64)
                    .multilineTextAlignment(.trailing)
                Stepper("", value: $value, in: range)
                    .labelsHidden()
                Text(unit).foregroundStyle(.secondary)
            }
        }
        .onChange(of: value) { _, newValue in
            // The Stepper bounds only its buttons; a value typed into the TextField can be out of
            // range (esp. above the max). Re-clamp to the field's full range after every edit.
            let clamped = SettingsMapping.clamp(newValue, to: range)
            if clamped != newValue { value = clamped }
        }
    }
}

/// The beta modifier-key popup. Index order matches the original (and `PasteService.pressed`):
/// 0 = Command, 1 = Shift, 2 = Control, 3 = Alt.
struct ModifierPicker: View {
    @Binding var selection: Int

    var body: some View {
        Picker("", selection: $selection) {
            Text("Command").tag(0)
            Text("Shift").tag(1)
            Text("Control").tag(2)
            Text("Alt").tag(3)
        }
        .labelsHidden()
        .frame(width: 120)
    }
}
