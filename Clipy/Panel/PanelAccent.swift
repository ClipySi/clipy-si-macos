//
//  PanelAccent.swift
//  ClipySi — Apple Silicon rewrite
//
//  The user-selectable accent for the unified FloatingPanel. Six fixed swatches, picked in
//  Settings → General → Appearance and persisted as a raw string (`DefaultsKeys.panelAccent`). The
//  panel's active scope tab (text / underline / count badge) and the row-selection fill use the chosen
//  colour, deliberately INDEPENDENT of the system accent so the panel reads the same on every Mac.
//  Unknown / legacy raw values resolve to the default (`.violet`).
//

import SwiftUI

enum PanelAccent: String, CaseIterable, Identifiable, Sendable {
    case violet, blue, teal, green, orange, pink

    /// The default accent (matches the original violet). Kept as the single source of truth for
    /// the registered UserDefaults default and every unknown-value fallback.
    static let `default` = PanelAccent.violet

    var id: String { rawValue }

    /// The swatch colour — the system palette colour of the same name: adapts to light/dark
    /// and Increase Contrast and tracks the HIG's updated system color values, while staying
    /// independent of the user's *accent colour* setting (these are fixed palette entries, so the
    /// panel still reads the same on every Mac with the same appearance).
    var color: Color {
        switch self {
        case .violet: return .purple
        case .blue:   return .blue
        case .teal:   return .teal
        case .green:  return .green
        case .orange: return .orange
        case .pink:   return .pink
        }
    }

    /// Localised display name — the swatch's accessibility label + hover tooltip in Settings.
    var label: LocalizedStringKey {
        switch self {
        case .violet: return "Violet"
        case .blue:   return "Blue"
        case .teal:   return "Teal"
        case .green:  return "Green"
        case .orange: return "Orange"
        case .pink:   return "Pink"
        }
    }

    /// Resolve a stored raw string, falling back to `.default` for an unknown / legacy / nil value.
    static func resolve(_ raw: String?) -> PanelAccent {
        raw.flatMap(PanelAccent.init(rawValue:)) ?? .default
    }
}
