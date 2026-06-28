//
//  AccentColorPicker.swift
//  ClipySi — Apple Silicon rewrite
//
//  A row of colour swatches for choosing the unified panel's accent (Settings → General → Appearance).
//  Bound to the raw `PanelAccent` string in UserDefaults via the caller's `@Shared` binding.
//  The selected swatch is double-encoded (a contrasting ring AND a checkmark) so it reads without relying
//  on colour alone, and each swatch is its own accessibility button with the colour name as its label.
//

import SwiftUI

struct AccentColorPicker: View {
    /// The stored raw `PanelAccent` value (e.g. "violet"). Two-way bound to `@Shared(.appStorage)`.
    @Binding var selection: String

    /// Visible swatch diameter; the tappable area around it is larger (`hit`) for an easier target.
    private let swatchSize: CGFloat = 24
    /// Hit-target box around each swatch. Larger than the swatch for motor accessibility (macOS colour
    /// wells are smaller than iOS's 44pt min, but a roomier target still helps trackpad/Switch users).
    private let hit: CGFloat = 34

    var body: some View {
        HStack(spacing: 6) {
            ForEach(PanelAccent.allCases) { accent in
                swatch(accent)
            }
        }
    }

    private func swatch(_ accent: PanelAccent) -> some View {
        let isSelected = selection == accent.rawValue
        return ZStack {
            Circle()
                .fill(accent.color)
                .frame(width: swatchSize, height: swatchSize)
            if isSelected {
                // Checkmark: white with a soft dark shadow so it stays legible on the lighter swatches
                // (orange/teal/green) as well as the darker ones — no per-colour luminance branching.
                Image(systemName: "checkmark")
                    .font(.callout.weight(.bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.45), radius: 1)
                // A contrasting ring just outside the swatch (a gap separates it), in the adaptive
                // primary colour so it reads in both light and dark mode and for colour-blind users.
                Circle()
                    .strokeBorder(.primary, lineWidth: 2)
                    .frame(width: swatchSize + 6, height: swatchSize + 6)
            }
        }
        .frame(width: hit, height: hit)
        .contentShape(Circle())
        .onTapGesture { selection = accent.rawValue }
        .help(Text(accent.label))
        .accessibilityElement()
        .accessibilityLabel(Text(accent.label))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
