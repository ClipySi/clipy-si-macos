//
//  PanelScopeTabs.swift
//  ClipySi — Apple Silicon rewrite
//
//  The All / History / Snippets scope selector row for the unified FloatingPanel: three
//  labelled tabs (SF Symbol + localized text + a count badge) with an underline under the active scope.
//  This view is PURE PRESENTATION plus a tap callback — the parent (`HistoryPanelView`) owns keyboard
//  focus and navigation: it applies `.focusable()/.focused($focus, equals: .scope)/.onKeyPress(…)` to
//  this whole view, which is why the tabs are tappable areas (not Buttons — a Button would steal the
//  row's single focus target and break `→`-to-scope). Kept out of `HistoryPanelView` so that view stays
//  within its size budget and the tab styling is testable/previewable in isolation.
//

import SwiftUI

struct PanelScopeTabs: View {
    let scope: HistoryPanelModel.Scope
    let allCount: Int
    let historyCount: Int
    let snippetCount: Int
    /// The user-chosen panel accent (Settings → General → Appearance) for the active tab's
    /// underline, badge fill, and focus fill (text/icon stay `.primary` for contrast).
    let accent: Color
    /// Whether the tab row currently holds keyboard focus (drives the active tab's faint fill so the
    /// "focus is on the tabs now" state is visible after `→`).
    let barFocused: Bool
    /// A tab was tapped — the parent re-bases paging via `setScope` and pulls focus onto the tabs.
    let onSelect: (HistoryPanelModel.Scope) -> Void

    var body: some View {
        HStack(spacing: 2) {
            tab(.all, symbol: "square.stack",
                label: Text("All", comment: "Unified panel scope: history + snippets"), count: allCount)
            tab(.history, symbol: "clock",
                label: Text("History", comment: "Unified panel scope: clipboard history only"), count: historyCount)
            tab(.snippets, symbol: "note.text",
                label: Text("Snippets", comment: "Unified panel scope: snippets only"), count: snippetCount)
            Spacer(minLength: 0)
        }
    }

    /// One scope tab: icon + label + count badge, underlined when active and faintly filled when active
    /// AND the row holds focus.
    private func tab(_ tabScope: HistoryPanelModel.Scope, symbol: String, label: Text, count: Int) -> some View {
        let active = scope == tabScope
        return VStack(spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.subheadline)
                label.font(.callout.weight(active ? .semibold : .regular)).lineLimit(1)
                countBadge(count, active: active)
            }
            // Active tab text/icon read in PRIMARY, not the accent (review: accent text on
            // the material surface bottoms out near 2:1 for teal/green/orange) — the accent now
            // lives only in the underline, badge fill, and focus fill, the segmented-control way.
            .foregroundStyle(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(active && barFocused ? AnyShapeStyle(accent.opacity(0.3)) : AnyShapeStyle(.clear)))
            Rectangle()
                .fill(active ? AnyShapeStyle(accent) : AnyShapeStyle(.clear))
                .frame(height: 2)
                .padding(.horizontal, 4)
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect(tabScope) }
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }

    /// The small count pill on a tab (total selectable items in that scope). Filled violet on the active
    /// tab; a visible neutral pill otherwise.
    private func countBadge(_ count: Int, active: Bool) -> some View {
        Text(verbatim: "\(count)")
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(active ? AnyShapeStyle(accent.opacity(0.22)) : AnyShapeStyle(.tertiary)))
            .accessibilityHidden(true)
    }
}
