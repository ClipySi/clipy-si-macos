//
//  PanelCategoryChips.swift
//  ClipySi — Apple Silicon rewrite
//
//  The category filter chips row shown under the search field when the filter toggle is
//  open: All / Text / Code / Links / Images / Files / Colors, each with a count badge over the
//  current scope. PURE PRESENTATION + a tap callback (mirrors PanelScopeTabs); while visible it is
//  a focus-chain member (`search ↕ chips ↕ scope ↕ list`) — the focus/keyboard plumbing lives at
//  the call site in HistoryPanelView, and `barFocused` makes the focused state visible.
//

import SwiftUI

struct PanelCategoryChips: View {
    let category: PanelCategory
    let counts: [PanelCategory: Int]
    /// The user-chosen panel accent — active chip tint.
    let accent: Color
    /// Whether the chips row currently holds keyboard focus (drives the active chip's stronger
    /// ring so the "focus is on the chips now" state is visible after `↓` from search).
    var barFocused = false
    /// A chip was tapped — the parent re-bases paging via `setCategory` and pulls focus here.
    let onSelect: (PanelCategory) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(PanelCategory.allCases, id: \.self) { candidate in
                        chip(candidate).id(candidate)
                    }
                }
            }
            // As content MARGINS (not padding inside the scroll content), so the nil-anchor
            // minimal scrollTo still leaves the 14pt inset next to an end chip instead of pinning
            // it flush against the panel edge (review).
            .contentMargins(.horizontal, 14, for: .scrollContent)
            // Keep the ACTIVE chip in view: `←`/`→` walk chips that overflow the panel's width, and
            // without following the selection the focus state becomes invisible (user feedback).
            // Also runs when keyboard focus enters the row, so the ring is visible immediately.
            .onChange(of: category) { _, newValue in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(newValue) }
            }
            .onChange(of: barFocused) { _, focused in
                if focused { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(category) } }
            }
        }
        .padding(.bottom, 6)
        // The accessibility label lives at the call site (the focusable wrapper), matching the
        // scope tabs — labeling here too made VoiceOver announce the row twice (review).
    }

    private func chip(_ candidate: PanelCategory) -> some View {
        let active = candidate == category
        return HStack(spacing: 4) {
            Image(systemName: candidate.symbol).font(.caption2)
            label(for: candidate).font(.subheadline.weight(active ? .semibold : .regular))
            if candidate != .all, let count = counts[candidate], count > 0 {
                Text(verbatim: "\(count)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(active ? AnyShapeStyle(accent.opacity(0.22)) : AnyShapeStyle(.tertiary)))
            }
        }
        // Active chip text/icon in PRIMARY (review — same contrast reasoning as the scope
        // tabs); the accent stays in the capsule fill + ring, which mark the active chip.
        .foregroundStyle(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(active ? AnyShapeStyle(accent.opacity(barFocused ? 0.26 : 0.16))
                                  : AnyShapeStyle(.quinary)))
        // The active chip's ring doubles as the row's focus indicator (stronger while focused).
        .overlay(Capsule().strokeBorder(active ? AnyShapeStyle(accent.opacity(barFocused ? 0.95 : 0.55))
                                               : AnyShapeStyle(.clear),
                                        lineWidth: active && barFocused ? 1.5 : 1))
        .contentShape(Capsule())
        .onTapGesture { onSelect(candidate) }
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }

    private func label(for candidate: PanelCategory) -> Text {
        switch candidate {
        case .all: Text("All", comment: "Category filter chip: every clip type")
        case .text: Text("Text", comment: "Category filter chip: plain text clips")
        case .code: Text("Code", comment: "Category filter chip: source-code clips")
        case .links: Text("Links", comment: "Category filter chip: URL clips")
        case .images: Text("Images", comment: "Category filter chip: image clips")
        case .files: Text("Files", comment: "Category filter chip: file and PDF clips")
        case .colors: Text("Colors", comment: "Category filter chip: color-code clips")
        }
    }
}
